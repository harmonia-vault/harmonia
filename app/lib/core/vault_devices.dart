// 管理设备的操作：处理配对请求、调整其他设备的授权与激活、改名和移除。
part of 'vault.dart';

mixin VaultDevices {
  HCrypto get crypto;
  ApiClient? get api;
  LocalConfig? get config;
  List<Environment> get environments;
  Map<String, Uint8List> get _envKeys;
  SignKey _root();
  Environment environment(String id);
  Future<void> sync({bool full = false});
  Uint8List _verifiedBoxPub(String deviceId, String kind, String signPub, String boxPub, String cert);
  Map<String, dynamic> _envelope(String envId, int keyVersion, String recipient, Uint8List boxPub, Uint8List envKey);
  // ---- 配对 ----

  Future<List<PairingRequest>> pendingPairings() async {
    final res = await api!.device('GET', '/api/v1/pairings');
    return (res['pairings'] as List).map((p) => PairingRequest((p as Map).cast<String, dynamic>())).toList();
  }

  void _checkPairing(PairingRequest p) {
    if (p.rootPub != config!.rootPub) {
      throw VaultException('这台设备连接的服务器返回了不同的账号密钥，可能被篡改，已拒绝。');
    }
  }

  /// 生成配对码（协议 3.2）：新设备带上它发起的请求会出现在待批准列表中。有效期 [minutes] 分钟，已有的配对码不受影响。
  Future<PairingCode> createPairingCode({int minutes = 10}) async {
    final res = await api!.device('POST', '/api/v1/pairing-codes', body: {'minutes': minutes});
    return PairingCode(res['code'] as String, DateTime.fromMillisecondsSinceEpoch(res['expiresAt'] as int));
  }

  /// 根据扫描到的二维码找到配对请求（匿名请求也可以），并核对指纹。
  Future<PairingRequest> pairingFromQr(String qr) async {
    final parsed = parsePairingQr(qr);
    if (parsed == null) throw VaultException('这不是 Harmonia 的配对二维码。');
    final (id, fp) = parsed;
    Map<String, dynamic> res;
    try {
      res = await api!.device('GET', '/api/v1/pairings/$id');
    } on ApiException catch (e) {
      if (e.code == 'not_found' || e.code == 'conflict') {
        throw VaultException('配对请求不存在或已过期，请在要接入的设备上重新发起。');
      }
      rethrow;
    }
    final p = PairingRequest(res);
    final actual = pairingFingerprint(p.id, p.signPub, p.boxPub, p.rootPub);
    if (b64(actual) != b64(fp)) {
      throw VaultException('二维码与服务器上的配对请求不一致，已拒绝。请在电脑上重新发起配对。');
    }
    _checkPairing(p);
    return p;
  }

  /// 根据手输的核对码在全部等待中的请求（包括匿名请求）中查找。
  Future<PairingRequest> pairingFromCode(String code) async {
    final want = normalizeCode(code);
    if (want.length != 16) throw VaultException('核对码是 16 位，请检查后重新输入。');
    for (final p in await pendingPairings()) {
      final fp = pairingFingerprint(p.id, p.signPub, p.boxPub, p.rootPub);
      if (normalizeCode(pairingCode(fp)) == want) {
        _checkPairing(p);
        return p;
      }
    }
    throw VaultException('没有找到匹配的配对请求。请确认核对码正确，并且对方的配对还没有过期（5 分钟）。');
  }

  /// 批准配对。asManager=true 时新设备成为管理设备，拥有全部环境。
  Future<void> approvePairing(PairingRequest p, {required bool asManager, List<Grant> grants = const []}) async {
    final r = _root();
    _checkPairing(p);
    final kind = asManager ? 'manager' : 'client';
    final cert = b64(crypto.sign(r, deviceCertMsg(p.id, kind, p.signPub, p.boxPub)));
    final boxPub = unb64(p.boxPub);
    final envIds = asManager ? environments.map((e) => e.id).toList() : grants.map((g) => g.envId).toList();
    final envelopes = [
      for (final id in envIds)
        _envelope(id, environment(id).keyVersion, p.id, boxPub, _envKeys[id]!)..remove('recipient'),
    ];
    await api!.device(
      'POST',
      '/api/v1/pairings/${p.id}/approve',
      body: {
        'kind': kind,
        'cert': cert,
        'envelopes': envelopes,
        if (!asManager) 'grants': grants.map((g) => g.toJson()).toList(),
        if (asManager) 'rootSealed': b64(crypto.seal(r.seed, boxPub)),
      },
    );
    await sync();
  }

  /// 拒绝配对；[block] 为 true 时 30 分钟内阻止该网络再次发起请求。
  Future<void> rejectPairing(String id, {bool block = false}) async {
    await api!.device('POST', '/api/v1/pairings/$id/reject', body: {'block': block});
  }

  // ---- 设备管理 ----

  Future<void> updateGrants(DeviceInfo d, List<Grant> grants) async {
    final current = d.grants.map((g) => g.envId).toSet();
    final added = grants.where((g) => !current.contains(g.envId)).toList();
    Uint8List? boxPub;
    if (added.isNotEmpty) boxPub = _verifiedBoxPub(d.id, d.kind, d.signPub, d.boxPub, d.cert);
    await api!.device(
      'PUT',
      '/api/v1/devices/${d.id}/grants',
      body: {
        'grants': grants.map((g) => g.toJson()).toList(),
        'envelopes': [
          for (final g in added)
            _envelope(g.envId, environment(g.envId).keyVersion, d.id, boxPub!, _envKeys[g.envId]!)..remove('recipient'),
        ],
      },
    );
    await sync();
  }

  Future<void> renameDevice(String id, String name) async {
    await api!.device('PATCH', '/api/v1/devices/$id', body: {'name': name.trim()});
    await sync();
  }

  /// 修改某台设备的“写入系统变量”开关（docs/protocol.md 3.2）。
  Future<void> setSystemVars(String id, bool on) async {
    try {
      await api!.device('PATCH', '/api/v1/devices/$id', body: {'systemVars': on});
    } on ApiException catch (e) {
      // 较旧的服务端把这个请求当成改名，因为没有名字而拒绝。
      if (e.status != 400) rethrow;
      throw ApiException(e.status, e.code, '服务器还不支持这个开关，请先把服务端更新到最新版本。');
    }
    await sync();
  }

  /// 修改某台电脑的“自动更新”开关（docs/protocol.md 3.2）。
  Future<void> setAutoUpdate(String id, bool on) async {
    try {
      await api!.device('PATCH', '/api/v1/devices/$id', body: {'autoUpdate': on});
    } on ApiException catch (e) {
      if (e.status != 400) rethrow;
      throw ApiException(e.status, e.code, '服务器还不支持这个开关，请先把服务端更新到最新版本。');
    }
    await sync();
  }

  /// 让某台电脑的后台服务现在检查更新并升级（docs/protocol.md 3.2）。升级完成后电脑上报新版本，
  /// 服务端推送 changed，设备列表随下一次同步更新。
  Future<void> requestCliUpdate(String id) async {
    try {
      await api!.device('POST', '/api/v1/devices/$id/update');
    } on ApiException catch (e) {
      // 较旧的服务端没有这个接口；设备不存在时同样是 404，但说明不同。
      if (e.status != 404 || !e.message.startsWith('接口不存在')) rethrow;
      throw ApiException(e.status, e.code, '服务器还不支持在手机上更新电脑，请先把服务端更新到最新版本。');
    }
  }

  /// 按顺序设置某台设备各环境的激活状态，排在前面的环境提供同名变量（docs/protocol.md 3.2）。
  Future<void> setActivation(String deviceId, List<Grant> ordered) async {
    await api!.device(
      'PUT',
      '/api/v1/devices/$deviceId/activation',
      body: {
        'envs': [
          for (final g in ordered) {'envId': g.envId, 'active': g.active},
        ],
      },
    );
    await sync();
  }

  Future<void> revokeDevice(String id) async {
    await api!.device('POST', '/api/v1/devices/$id/revoke', body: {});
    await sync();
  }
}
