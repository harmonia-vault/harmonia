// 手机端核心：本机状态、同步，以及管理设备的全部操作。纯 Dart，可脱离界面运行。
import 'dart:convert';
import 'dart:typed_data';

import 'api.dart';
import 'crypto.dart';
import 'models.dart';
import 'refs.dart';
import 'store.dart';

part 'vault_approvals.dart';
part 'vault_devices.dart';
part 'vault_envs.dart';
part 'vault_recovery.dart';

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 本机保存的账号与设备信息（用本机数据密钥加密后存放，见 protocol 2.5）。
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

class Vault with VaultDevices, VaultApprovals, VaultEnvironments, VaultRecovery {
  Vault(this.crypto, this.secure, this.files);

  @override
  final HCrypto crypto;
  final LocalStore secure;
  final LocalStore files;

  @override
  LocalConfig? config;
  @override
  ApiClient? api;
  SignKey? signKey;
  @override
  BoxKey? boxKey;
  SignKey? root;
  @override
  SyncCache cache = SyncCache();
  final Map<String, Uint8List> _vaultKeys = {};

  /// 本机数据密钥：由 App PIN 或指纹解开后设置，锁定时清除。
  Uint8List? localKey;
  int _lockGeneration = 0;

  static const _configKey = 'account';
  static const _cacheKey = 'cache';
  static final _configAad = canonical(['harmonia.local', 'config']);

  bool get paired => config != null;
  bool get isManager => cache.self['kind'] == 'manager';
  @override
  List<Environment> get environments => cache.environments;
  @override
  List<VaultInfo> get vaults => cache.vaults;
  @override
  List<EnvDef> get envDefs => cache.envDefs;
  @override
  List<DeviceInfo> get devices => cache.devices;

  // ---- 本机状态 ----

  /// 本机是否保存了已接入的账号（不需要解锁）。
  Future<bool> hasAccount() async => await secure.read(_configKey) != null;

  /// 用 [localKey] 解开本机保存的状态。返回是否已接入账号。
  Future<bool> load() async {
    final generation = _lockGeneration;
    final raw = await secure.read(_configKey);
    if (raw == null || generation != _lockGeneration || localKey == null) return false;
    final json = utf8.decode(crypto.aeadOpen(localKey!, unb64(raw), _configAad));
    final c = LocalConfig.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());
    _attach(c);
    final cached = await files.read(_cacheKey);
    if (generation != _lockGeneration) return false;
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
    final json = Uint8List.fromList(utf8.encode(jsonEncode(c.toJson())));
    await secure.write(_configKey, b64(crypto.aeadSeal(localKey!, json, _configAad)));
    _attach(c);
    cache = SyncCache();
    _vaultKeys.clear();
    root = null;
    await sync();
  }

  /// 清除本机全部账号数据（保留服务器地址由调用方处理）。
  Future<void> wipe() async {
    await secure.delete(_configKey);
    await files.delete(_cacheKey);
    lock();
  }

  /// 清除内存中的全部密钥和状态；本机保存的数据不变，解锁后可再 [load]。
  void lock() {
    _lockGeneration++;
    localKey = null;
    config = null;
    api = null;
    signKey = null;
    boxKey = null;
    root = null;
    cache = SyncCache();
    _vaultKeys.clear();
  }

  // ---- 同步 ----

  Future<void>? _syncing;

  /// 推送和操作完成后的同步可能同时发生；排队执行，避免并发改写缓存和本机文件。
  @override
  Future<void> sync({bool full = false}) {
    final prev = _syncing;
    final run = () async {
      if (prev != null) await prev.catchError((_) {});
      await _sync(full: full);
    }();
    _syncing = run;
    return run.whenComplete(() {
      if (identical(_syncing, run)) _syncing = null;
    });
  }

  Future<void> _sync({bool full = false}) async {
    final generation = _lockGeneration;
    final since = full ? 0 : cache.seq;
    Map<String, dynamic> res;
    try {
      res = await api!.device('GET', '/api/v1/sync?since=$since');
    } on RevokedException {
      if (generation != _lockGeneration) return;
      await wipe();
      rethrow;
    }
    if (generation != _lockGeneration) return;
    if ((res['seq'] as int) < since) return _sync(full: true);
    final next = since == 0 ? SyncCache() : cache;
    // 能看到的变量范围变了时服务端下发完整列表，整体替换（docs/protocol.md 3.4）。
    if (since == 0 || res['full'] == true) next.variables = {};
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
    final visible = ((res['vaults'] as List?) ?? []).map((v) => (v as Map)['id'] as String).toSet();
    next.variables.removeWhere((vault, _) => !visible.contains(vault));
    for (final v in (res['variables'] as List).cast<Map>()) {
      final vaultId = v['vaultId'] as String;
      if (!visible.contains(vaultId)) continue;
      final m = next.variables.putIfAbsent(vaultId, () => {});
      if (v['deleted'] == true) {
        m.remove(v['name']);
      } else {
        m[v['name'] as String] = CachedVariable(v['value'] as String, int.parse(v['keyVersion'] as String));
      }
    }
    cache = next;
    _unlockKeys();
    await files.write(_cacheKey, jsonEncode(cache.toJson()));
  }

  /// 校验并解开库钥与（管理设备的）账号根密钥。
  void _unlockKeys() {
    final rootPub = unb64(config!.rootPub);
    _vaultKeys.clear();
    for (final e in cache.envelopes) {
      final sealed = unb64(e.sealed);
      if (!crypto.verify(rootPub, envelopeMsg(e.vaultId, e.keyVersion, config!.deviceId, sealed), unb64(e.sig))) {
        throw VaultException('服务器下发的变量库密钥签名无效，已停止。请确认服务器地址是否正确。');
      }
      _vaultKeys[e.vaultId] = crypto.open(boxKey!, sealed);
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

  @override
  @override
  Environment environment(String id) =>
      cache.environments.firstWhere((e) => e.id == id, orElse: () => throw VaultException('环境不存在，可能已被删除。'));

  /// 变量库的名字；已被删除时返回 null。
  String? vaultName(String id) => vaults.where((v) => v.id == id).firstOrNull?.name;

  @override
  EnvDef? envDef(String id) => envDefs.where((e) => e.id == id).firstOrNull;

  /// 变量库里现存的变量名，按名称排序。
  @override
  List<String> variableNames(String vaultId) => (cache.variables[vaultId]?.keys.toList() ?? [])..sort();

  /// 解密一个变量库的全部变量（值和备注），键是变量库里的原名。解不开的变量不在其中，见 [brokenVariables]。
  @override
  Map<String, VarEntry> entries(String vaultId) => _decryptAll(vaultId).entries;

  /// 解不开的变量名，按名称排序。它们仍然可以删除或重新写入。
  List<String> brokenVariables(String vaultId) => _decryptAll(vaultId).broken;

  /// 解密一个环境里的变量，键是环境里的名字（改名后的）。解不开的变量不在其中。
  Map<String, VarEntry> envEntries(String envId) {
    final decrypted = <String, Map<String, VarEntry>>{};
    final out = <String, VarEntry>{};
    for (final it in environment(envId).items) {
      final vals = decrypted.putIfAbsent(
        it.vaultId,
        () => _vaultKeys.containsKey(it.vaultId) ? entries(it.vaultId) : {},
      );
      final e = vals[it.source];
      if (e != null) out[it.name] = e;
    }
    return out;
  }

  ({Map<String, VarEntry> entries, List<String> broken}) _decryptAll(String vaultId) {
    final key = _vaultKey(vaultId);
    final entries = <String, VarEntry>{};
    final broken = <String>[];
    for (final v in (cache.variables[vaultId] ?? {}).entries) {
      try {
        entries[v.key] = crypto.decryptVar(key, vaultId, v.value.keyVersion, v.key, v.value.value);
      } on DecryptException {
        broken.add(v.key);
      }
    }
    return (entries: entries, broken: broken..sort());
  }

  @override
  Uint8List _vaultKey(String vaultId) {
    final key = _vaultKeys[vaultId];
    if (key == null) throw VaultException('这台设备没有这个变量库的密钥。');
    return key;
  }

  @override
  int _keyVersion(String vaultId) =>
      vaults.where((v) => v.id == vaultId).firstOrNull?.keyVersion ??
      cache.envelopes
          .firstWhere((e) => e.vaultId == vaultId, orElse: () => throw VaultException('变量库不存在，可能已被删除。'))
          .keyVersion;

  // ---- 环境与变量 ----

  @override
  SignKey _root() {
    final r = root;
    if (r == null) throw VaultException('只有管理设备可以执行这个操作。');
    return r;
  }

  /// 校验设备证书后返回它的加密公钥。
  @override
  Uint8List _verifiedBoxPub(String deviceId, String kind, String signPub, String boxPub, String cert) {
    if (!crypto.verify(unb64(config!.rootPub), deviceCertMsg(deviceId, kind, signPub, boxPub), unb64(cert))) {
      throw VaultException('设备“$deviceId”的证书无效，已拒绝为它发放密钥。');
    }
    return unb64(boxPub);
  }

  @override
  Map<String, dynamic> _envelope(String vaultId, int keyVersion, String recipient, Uint8List boxPub, Uint8List key) {
    final sealed = crypto.seal(key, boxPub);
    return {
      'vaultId': vaultId,
      'recipient': recipient,
      'keyVersion': '$keyVersion',
      'sealed': b64(sealed),
      'sig': b64(crypto.sign(_root(), envelopeMsg(vaultId, keyVersion, recipient, sealed))),
    };
  }

  /// 为一台设备封装这些变量库的库钥（已删除的跳过）。
  @override
  List<Map<String, dynamic>> _sealVaults(Iterable<String> vaultIds, String recipient, Uint8List boxPub) => [
    for (final id in vaultIds.toSet())
      if (vaults.any((v) => v.id == id)) _envelope(id, _keyVersion(id), recipient, boxPub, _vaultKey(id)),
  ];

  /// 这些授权里开启了本机解密的环境引用到的变量库（设计文档 17.2）。
  @override
  Set<String> _localVaults(Iterable<Grant> grants) => {
    for (final g in grants.where((g) => g.localDecrypt))
      for (final r in envDef(g.envId)?.refs ?? const <EnvRef>[])
        if (!r.missing) r.vaultId,
  };

  /// 新建变量库：生成库钥，封装给全部管理设备（先校验设备证书）和恢复码。[withEnv] 时同时新建一个同名环境，
  /// 引用它的全部变量并允许修改（设计文档 17.1）。返回变量库 ID 和环境 ID。
  Future<({String vaultId, String? envId})> createVault(String name, {bool withEnv = true}) async {
    _root();
    final id = crypto.newId();
    final key = crypto.random(32);
    final envelopes = <Map<String, dynamic>>[];
    for (final d in devices.where((d) => d.isManager)) {
      envelopes.add(_envelope(id, 1, d.id, _verifiedBoxPub(d.id, d.kind, d.signPub, d.boxPub, d.cert), key));
    }
    final rec = cache.manager!['recovery'] as Map;
    envelopes.add(_envelope(id, 1, 'recovery', unb64(rec['boxPub'] as String), key));
    await api!.device('POST', '/api/v1/vaults', body: {'id': id, 'name': name.trim(), 'envelopes': envelopes});
    String? envId;
    if (withEnv) {
      envId = crypto.newId();
      await api!.device(
        'POST',
        '/api/v1/environments',
        body: {
          'id': envId,
          'name': name.trim(),
          'refs': [EnvRef(id, 'all', writable: true).toJson()],
        },
      );
    }
    await sync();
    return (vaultId: id, envId: envId);
  }

  Future<void> renameVault(String id, String name) async {
    await api!.device('PATCH', '/api/v1/vaults/$id', body: {'name': name.trim()});
    await sync();
  }

  /// 删除变量库和其中的变量；引用它的环境里，这条引用变成“已失效”。
  Future<void> deleteVault(String id) async {
    await api!.device('DELETE', '/api/v1/vaults/$id');
    await sync();
  }

  /// 写入变量库里的一个变量（值和备注）；已有变量里本版本不认识的内容原样保留。
  Future<void> setVariable(String vaultId, String name, String value, String note) async {
    final key = _vaultKey(vaultId);
    final kv = _keyVersion(vaultId);
    final old = cache.variables[vaultId]?[name];
    var entry = VarEntry(value, note: note.trim());
    if (old != null) {
      try {
        entry = crypto
            .decryptVar(key, vaultId, old.keyVersion, name, old.value)
            .copyWith(value: value, note: note.trim());
      } on DecryptException {
        // 原来的内容解不开时直接覆盖。
      }
    }
    final ct = crypto.encryptVar(key, vaultId, kv, name, entry);
    await api!.device(
      'PUT',
      '/api/v1/vaults/$vaultId/variables/$name',
      body: {'value': ct, 'keyVersion': '$kv'},
      headers: {'idempotency-key': crypto.newId()},
    );
    await sync();
  }

  Future<void> deleteVariable(String vaultId, String name) async {
    await api!.device(
      'DELETE',
      '/api/v1/vaults/$vaultId/variables/$name',
      headers: {'idempotency-key': crypto.newId()},
    );
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

  // ---- 推送 ----

  /// 保持推送连接；收到变化时同步并回调，收到配对请求、批准请求时分别回调。连接断开时返回或抛出。
  Future<void> listen(void Function() onChanged, void Function() onPairing, void Function() onApproval) async {
    await api!.listen((ev) async {
      if (ev['type'] == 'pairing') onPairing();
      if (ev['type'] == 'approval') onApproval();
      if (ev['type'] == 'changed') {
        await sync();
        onChanged();
      }
    });
  }
}
