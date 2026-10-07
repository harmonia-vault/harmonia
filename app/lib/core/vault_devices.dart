// 管理设备的操作：处理配对请求、调整其他设备的授权与激活、改名和移除。
part of 'vault.dart';

extension VaultDevices on Vault {
  // ---- 配对 ----

  Future<List<PairingRequest>> pendingPairings() async {
    final res = await api!.device('GET', '/api/v1/pairings');
    return (res['pairings'] as List)
        .map((p) => PairingRequest((p as Map).cast<String, dynamic>()))
        .toList();
  }

  void _checkPairing(PairingRequest p) {
    if (p.rootPub != config!.rootPub) {
      throw VaultException('这台设备连接的服务器返回了不同的账号密钥，可能被篡改，已拒绝。');
    }
  }

  /// 根据扫描到的二维码找到配对请求，并核对指纹。
  Future<PairingRequest> pairingFromQr(String qr) async {
    final parsed = parsePairingQr(qr);
    if (parsed == null) throw VaultException('这不是 Harmonia 的配对二维码。');
    final (id, fp) = parsed;
    Map<String, dynamic> res;
    try {
      res = await api!.device('GET', '/api/v1/pairings/$id');
    } on ApiException catch (e) {
      if (e.code == 'not_found' || e.code == 'conflict') {
        throw VaultException('配对请求不存在或已过期，请在电脑上重新发起。');
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

  /// 根据手输的核对码在待处理请求中查找。
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
    throw VaultException('没有找到匹配的配对请求。请确认核对码正确，并且电脑上的配对还没有过期。');
  }

  /// 批准配对。asManager=true 时新设备成为管理设备，拥有全部环境。
  Future<void> approvePairing(PairingRequest p,
      {required bool asManager, List<Grant> grants = const []}) async {
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
    await api!.device('POST', '/api/v1/pairings/${p.id}/approve', body: {
      'kind': kind,
      'cert': cert,
      'envelopes': envelopes,
      if (!asManager) 'grants': grants.map((g) => g.toJson()).toList(),
      if (asManager) 'rootSealed': b64(crypto.seal(r.seed, boxPub)),
    });
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
    await api!.device('PUT', '/api/v1/devices/${d.id}/grants', body: {
      'grants': grants.map((g) => g.toJson()).toList(),
      'envelopes': [
        for (final g in added)
          _envelope(g.envId, environment(g.envId).keyVersion, d.id, boxPub!, _envKeys[g.envId]!)
            ..remove('recipient'),
      ],
    });
    await sync();
  }

  Future<void> renameDevice(String id, String name) async {
    await api!.device('PATCH', '/api/v1/devices/$id', body: {'name': name.trim()});
    await sync();
  }

  /// 按顺序设置某台设备各环境的激活状态，排在前面的环境提供同名变量（docs/protocol.md 3.2）。
  Future<void> setActivation(String deviceId, List<Grant> ordered) async {
    await api!.device('PUT', '/api/v1/devices/$deviceId/activation', body: {
      'envs': [
        for (final g in ordered) {'envId': g.envId, 'active': g.active},
      ],
    });
    await sync();
  }

  Future<void> revokeDevice(String id) async {
    await api!.device('POST', '/api/v1/devices/$id/revoke', body: {});
    await sync();
  }
}
