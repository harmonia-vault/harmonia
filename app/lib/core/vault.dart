// 手机端核心：本机状态、同步，以及管理设备的全部操作。纯 Dart，可脱离界面运行。
import 'dart:convert';
import 'dart:typed_data';

import 'api.dart';
import 'crypto.dart';
import 'models.dart';
import 'store.dart';

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 本机保存的账号与设备信息（存放在安全存储中）。
class LocalConfig {
  LocalConfig({
    required this.server,
    required this.accountId,
    required this.email,
    required this.rootPub,
    required this.deviceId,
    required this.deviceName,
    required this.signSeed,
    required this.boxSeed,
  });
  final String server, accountId, email, rootPub, deviceId, deviceName, signSeed, boxSeed;

  Map<String, dynamic> toJson() => {
        'server': server,
        'accountId': accountId,
        'email': email,
        'rootPub': rootPub,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'signSeed': signSeed,
        'boxSeed': boxSeed,
      };

  factory LocalConfig.fromJson(Map<String, dynamic> j) => LocalConfig(
        server: j['server'] as String,
        accountId: j['accountId'] as String,
        email: j['email'] as String,
        rootPub: j['rootPub'] as String,
        deviceId: j['deviceId'] as String,
        deviceName: j['deviceName'] as String,
        signSeed: j['signSeed'] as String,
        boxSeed: j['boxSeed'] as String,
      );
}

/// 一次恢复码轮换的结果；网络中断时可凭 [key] 查询。
class RotationAttempt {
  RotationAttempt(this.key, this.generation);
  final String key;
  final int generation;
}

class Vault {
  Vault(this.crypto, this.secure, this.files);

  final HCrypto crypto;
  final LocalStore secure;
  final LocalStore files;

  LocalConfig? config;
  ApiClient? api;
  SignKey? signKey;
  BoxKey? boxKey;
  SignKey? root;
  SyncCache cache = SyncCache();
  final Map<String, Uint8List> _envKeys = {};

  static const _configKey = 'config';
  static const _cacheKey = 'cache';

  bool get paired => config != null;
  bool get isManager => cache.self['kind'] == 'manager';
  List<Environment> get environments => cache.environments;
  List<DeviceInfo> get devices => cache.devices;

  // ---- 本机状态 ----

  /// 读取本机保存的状态。返回是否已接入账号。
  Future<bool> load() async {
    final raw = await secure.read(_configKey);
    if (raw == null) return false;
    final c = LocalConfig.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    _attach(c);
    final cached = await files.read(_cacheKey);
    if (cached != null) {
      try {
        cache = SyncCache.fromJson((jsonDecode(cached) as Map).cast<String, dynamic>());
        _unlockKeys();
      } catch (_) {
        cache = SyncCache();
      }
    }
    return true;
  }

  void _attach(LocalConfig c) {
    config = c;
    signKey = crypto.signKeyFromSeed(unb64(c.signSeed));
    boxKey = crypto.boxKeyFromSeed(unb64(c.boxSeed));
    api = ApiClient(c.server)
      ..accountId = c.accountId
      ..deviceId = c.deviceId
      ..signer = (nonce) => b64(crypto.sign(signKey!, authMsg(c.deviceId, nonce)));
  }

  /// 保存新接入的设备并完成首次同步。
  Future<void> adopt(LocalConfig c) async {
    await secure.write(_configKey, jsonEncode(c.toJson()));
    _attach(c);
    cache = SyncCache();
    _envKeys.clear();
    root = null;
    await sync();
  }

  /// 清除本机全部账号数据（保留服务器地址由调用方处理）。
  Future<void> wipe() async {
    await secure.delete(_configKey);
    await files.delete(_cacheKey);
    config = null;
    api = null;
    signKey = null;
    boxKey = null;
    root = null;
    cache = SyncCache();
    _envKeys.clear();
  }

  // ---- 同步 ----

  Future<void> sync({bool full = false}) async {
    final since = full ? 0 : cache.seq;
    Map<String, dynamic> res;
    try {
      res = await api!.device('GET', '/api/v1/sync?since=$since');
    } on RevokedException {
      await wipe();
      rethrow;
    }
    if ((res['seq'] as int) < since) return sync(full: true);
    final next = since == 0 ? SyncCache() : cache;
    if (since == 0) next.variables = {};
    next
      ..seq = res['seq'] as int
      ..self = (res['self'] as Map).cast<String, dynamic>()
      ..environments = (res['environments'] as List)
          .map((e) => Environment.fromJson((e as Map).cast<String, dynamic>()))
          .toList()
      ..envelopes = (res['envelopes'] as List)
          .map((e) => Envelope.fromJson((e as Map).cast<String, dynamic>()))
          .toList()
      ..manager = (res['manager'] as Map?)?.cast<String, dynamic>();
    final visible = next.environments.map((e) => e.id).toSet();
    next.variables.removeWhere((env, _) => !visible.contains(env));
    for (final v in (res['variables'] as List).cast<Map>()) {
      final envId = v['envId'] as String;
      if (!visible.contains(envId)) continue;
      final m = next.variables.putIfAbsent(envId, () => {});
      if (v['deleted'] == true) {
        m.remove(v['name']);
      } else {
        m[v['name'] as String] =
            CachedVariable(v['value'] as String, int.parse(v['keyVersion'] as String));
      }
    }
    cache = next;
    _unlockKeys();
    await files.write(_cacheKey, jsonEncode(cache.toJson()));
  }

  /// 校验并解开环境钥与（管理设备的）账号根密钥。
  void _unlockKeys() {
    final rootPub = unb64(config!.rootPub);
    _envKeys.clear();
    for (final e in cache.envelopes) {
      final sealed = unb64(e.sealed);
      if (!crypto.verify(rootPub, envelopeMsg(e.envId, e.keyVersion, config!.deviceId, sealed),
          unb64(e.sig))) {
        throw VaultException('服务器下发的环境密钥签名无效，已停止。请确认服务器地址是否正确。');
      }
      _envKeys[e.envId] = crypto.open(boxKey!, sealed);
    }
    final sealedRoot = cache.manager?['rootSealed'] as String?;
    if (sealedRoot != null) {
      final seed = crypto.open(boxKey!, unb64(sealedRoot));
      final r = crypto.signKeyFromSeed(seed);
      if (b64(r.pub) != config!.rootPub) {
        throw VaultException('账号密钥与本机记录不一致，已停止。请确认服务器地址是否正确。');
      }
      root = r;
    } else {
      root = null;
    }
  }

  Environment environment(String id) => cache.environments.firstWhere((e) => e.id == id,
      orElse: () => throw VaultException('环境不存在，可能已被删除。'));

  /// 解密一个环境的全部变量。
  Map<String, String> values(String envId) {
    final key = _envKeys[envId];
    if (key == null) throw VaultException('这台设备没有这个环境的密钥。');
    final out = <String, String>{};
    for (final entry in (cache.variables[envId] ?? {}).entries) {
      out[entry.key] =
          crypto.decryptValue(key, envId, entry.value.keyVersion, entry.key, entry.value.value);
    }
    return out;
  }

  // ---- 环境与变量 ----

  SignKey _root() {
    final r = root;
    if (r == null) throw VaultException('只有管理手机可以执行这个操作。');
    return r;
  }

  /// 校验设备证书后返回它的加密公钥。
  Uint8List _verifiedBoxPub(String deviceId, String kind, String signPub, String boxPub,
      String cert) {
    if (!crypto.verify(unb64(config!.rootPub), deviceCertMsg(deviceId, kind, signPub, boxPub),
        unb64(cert))) {
      throw VaultException('设备“$deviceId”的证书无效，已拒绝为它发放密钥。');
    }
    return unb64(boxPub);
  }

  Map<String, dynamic> _envelope(
      String envId, int keyVersion, String recipient, Uint8List boxPub, Uint8List envKey) {
    final sealed = crypto.seal(envKey, boxPub);
    return {
      'envId': envId,
      'recipient': recipient,
      'keyVersion': '$keyVersion',
      'sealed': b64(sealed),
      'sig': b64(crypto.sign(_root(), envelopeMsg(envId, keyVersion, recipient, sealed))),
    };
  }

  Future<void> createEnvironment(String name) async {
    _root();
    final id = crypto.newId();
    final key = crypto.random(32);
    final envelopes = <Map<String, dynamic>>[];
    for (final d in devices.where((d) => d.isManager)) {
      envelopes.add(_envelope(
          id, 1, d.id, _verifiedBoxPub(d.id, d.kind, d.signPub, d.boxPub, d.cert), key));
    }
    final rec = cache.manager!['recovery'] as Map;
    envelopes.add(_envelope(id, 1, 'recovery', unb64(rec['boxPub'] as String), key));
    await api!.device('POST', '/api/v1/environments',
        body: {'id': id, 'name': name.trim(), 'envelopes': envelopes});
    await sync();
  }

  Future<void> renameEnvironment(String id, String name) async {
    await api!.device('PATCH', '/api/v1/environments/$id', body: {'name': name.trim()});
    await sync();
  }

  Future<void> deleteEnvironment(String id) async {
    await api!.device('DELETE', '/api/v1/environments/$id');
    await sync();
  }

  Future<void> setVariable(String envId, String name, String value) async {
    final env = environment(envId);
    final key = _envKeys[envId];
    if (key == null) throw VaultException('这台设备没有这个环境的密钥。');
    final ct = crypto.encryptValue(key, envId, env.keyVersion, name, value);
    await api!.device('PUT', '/api/v1/environments/$envId/variables/$name',
        body: {'value': ct, 'keyVersion': '${env.keyVersion}'},
        headers: {'idempotency-key': crypto.newId()});
    await sync();
  }

  Future<void> deleteVariable(String envId, String name) async {
    await api!.device('DELETE', '/api/v1/environments/$envId/variables/$name',
        headers: {'idempotency-key': crypto.newId()});
    await sync();
  }

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
    final want = normalizePairingCode(code);
    if (want.length != 16) throw VaultException('核对码是 16 位，请检查后重新输入。');
    for (final p in await pendingPairings()) {
      final fp = pairingFingerprint(p.id, p.signPub, p.boxPub, p.rootPub);
      if (normalizePairingCode(pairingCode(fp)) == want) {
        _checkPairing(p);
        return p;
      }
    }
    throw VaultException('没有找到匹配的配对请求。请确认核对码正确，并且电脑上的配对还没有过期。');
  }

  /// 批准配对。asManager=true 时新设备成为管理手机，拥有全部环境。
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

  Future<void> rejectPairing(String id) async {
    await api!.device('POST', '/api/v1/pairings/$id/reject', body: {});
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

  Future<void> revokeDevice(String id) async {
    await api!.device('POST', '/api/v1/devices/$id/revoke', body: {});
    await sync();
  }

  /// 本机退出：从账号中移除并清除本机数据。离线时只清除本机数据，返回 false。
  Future<bool> logout({bool confirmLast = false}) async {
    var online = true;
    try {
      await api!.device('POST', '/api/v1/devices/self/revoke', body: {'confirmLast': confirmLast});
    } on RevokedException {
      // 已被移除，直接清除。
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      online = false;
    }
    await wipe();
    return online;
  }

  bool get isLastManager => devices.where((d) => d.isManager).length <= 1;

  Future<void> changePassword(String newPassword) async {
    final salt = crypto.random(16);
    final authKey = await passwordKeyInIsolate(newPassword, salt);
    await api!.device('PUT', '/api/v1/account/password',
        body: {'kdfSalt': b64(salt), 'authKey': b64(authKey)});
  }

  // ---- 恢复码轮换 ----

  /// 用新恢复码轮换。全部环境钥与账号根密钥重新封装给新恢复钥，提交成功后旧恢复码失效。
  Future<RotationAttempt> rotateRecovery(Uint8List newCode, {String? newPassword}) async {
    final r = _root();
    final rec = crypto.deriveRecovery(newCode);
    final generation = int.parse((cache.manager!['recovery'] as Map)['generation'] as String) + 1;
    final rootSealed = crypto.seal(r.seed, rec.box.pub);
    final attempt = RotationAttempt(crypto.newId(), generation);
    final body = <String, dynamic>{
      'idempotencyKey': attempt.key,
      'generation': '$generation',
      'signPub': b64(rec.sign.pub),
      'boxPub': b64(rec.box.pub),
      'rootEnvelope': {
        'sealed': b64(rootSealed),
        'sig': b64(crypto.sign(rec.sign, rootRecoveryMsg(generation, rootSealed))),
      },
      'envelopes': [
        for (final e in environments)
          _envelope(e.id, e.keyVersion, 'recovery', rec.box.pub, _envKeys[e.id]!)..remove('recipient'),
      ],
    };
    if (newPassword != null) {
      final salt = crypto.random(16);
      body['password'] = {
        'kdfSalt': b64(salt),
        'authKey': b64(await passwordKeyInIsolate(newPassword, salt)),
      };
    }
    await api!.device('POST', '/api/v1/recovery/rotate', body: body);
    await sync();
    return attempt;
  }

  /// 查询一次轮换是否已在服务器生效（网络中断后使用）。
  Future<bool> rotationCompleted(String key) async {
    final res = await api!.device('GET', '/api/v1/recovery/rotate/$key');
    final done = res['state'] == 'complete';
    if (done) await sync();
    return done;
  }

  // ---- 推送 ----

  /// 保持推送连接；收到变化时同步并回调。连接断开时返回或抛出。
  Future<void> listen(void Function() onChanged, void Function() onPairing) async {
    await api!.listen((ev) async {
      if (ev['type'] == 'pairing') onPairing();
      if (ev['type'] == 'changed') {
        await sync();
        onChanged();
      }
    });
  }
}
