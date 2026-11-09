// 页面调试专用保险库：所有数据仅存在内存，不持有真实网络客户端或设备密钥。
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'crypto.dart';
import 'debug_approvals.dart';
import 'models.dart';
import 'refs.dart';
import 'store.dart';
import 'vault.dart';

class DebugNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => throw StateError('页面调试不能访问网络');
}

enum DebugScenario { normal, empty, offline, failure }

/// 页面调试里更新源的最新版本：带后缀的版本走测试版渠道。
String debugCliLatest(String version) => version.contains('-') ? '0.10.1-rc.1' : '0.10.0';

class DebugVault extends Vault with DebugApprovals {
  DebugVault(HCrypto crypto) : super(crypto, MemoryStore(), MemoryStore()) {
    api = ApiClient('https://debug.invalid', client: DebugNetworkClient());
    reset();
  }

  DebugScenario scenario = DebugScenario.normal;
  final _listening = Completer<void>();

  /// 模拟数据在后台变化（例如电脑完成更新）时通知界面刷新，由调试会话设置。
  void Function()? onSimulatedChange;

  /// 后台服务没有连上服务器的示例电脑。
  final offlineDevices = <String>{};

  /// 模拟电脑完成更新所用的时间。
  Duration cliUpdateDelay = const Duration(seconds: 3);
  final requests = <PairingRequest>[];
  final _rotations = <String>{};
  int _nextId = 0;

  LocalConfig get sampleConfig => LocalConfig(
    server: 'https://debug.invalid',
    accountId: 'debug-account',
    email: 'demo@example.invalid',
    rootPub: 'debug-root',
    deviceId: 'debug-phone',
    deviceName: '示例 iPhone',
    signSeed: '',
    boxSeed: '',
  );

  @override
  void check() {
    if (scenario == DebugScenario.offline) throw ApiException(0, 'network', '当前为模拟离线，请切换到正常场景后重试。');
    if (scenario == DebugScenario.failure) throw VaultException('模拟操作失败，请切换到正常场景后重试。');
  }

  Map<String, dynamic> _device(
    String id,
    String name,
    String platform,
    String kind,
    List<Grant> grants, {
    String version = '',
  }) => {
    'id': id,
    'name': name,
    'platform': platform,
    'kind': kind,
    'signPub': 'debug-sign',
    'boxPub': 'debug-box',
    'cert': '',
    'createdAt': 1791763200000,
    'lastSeenAt': 1791792000000,
    'version': version,
    'grants': grants.map((g) => {...g.toJson(), 'active': g.active, 'position': g.position}).toList(),
  };

  void reset({DebugScenario scenario = DebugScenario.normal}) {
    this.scenario = scenario;
    _nextId = 10;
    _rotations.clear();
    config = sampleConfig;
    localKey = Uint8List(32);
    cache = SyncCache()..self = {'kind': 'manager'};
    _defs.clear();
    cache.manager = {
      'devices': [
        _device('debug-phone', '示例 iPhone', 'ios', 'manager', [], version: '0.4.5'),
        // 测试版渠道，有新版本可以更新。
        // 一个开启本机解密的环境，一个 30 天后到期、没有激活的环境。
        _device('debug-computer', '开发电脑', 'windows', 'client', [
          Grant('debug-env-1', 'rw', 0),
          Grant(
            'debug-env-4',
            'ro',
            DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
            localDecrypt: false,
            active: false,
            position: 1,
          ),
        ], version: '0.10.1-beta.1'),
        // 没有版本：还没升级到会上报版本的命令行，也不支持在手机上更新。没有开启本机解密。
        _device('debug-mac', '个人 Mac', 'darwin', 'client', [
          Grant('debug-env-2', 'ro', 0, localDecrypt: false),
          Grant('debug-env-3', 'rw', 0, localDecrypt: false, position: 1),
        ]),
        // 已是最新版本，开着自动更新；后台服务不在线。
        _device('debug-linux', '构建服务器', 'linux', 'client', [Grant('debug-env-2', 'ro', 0)], version: '0.10.0')
          ..['autoUpdate'] = true,
      ],
    };
    offlineDevices
      ..clear()
      ..add('debug-linux');
    requests.clear();
    resetApprovals();
    _notes
      ..clear()
      ..['debug-vault-1/API_KEY'] = '示例备注：只用于页面调试\n第二行说明';
    _broken
      ..clear()
      ..add('debug-vault-1/OLD_TOKEN');
    cache.manager!['vaults'] = <Map<String, dynamic>>[];
    cache.manager!['environments'] = <Map<String, dynamic>>[];
    if (scenario == DebugScenario.empty) {
      cache.manager!['devices'] = <dynamic>[];
      _rebuild();
      return;
    }
    cache.manager!['vaults'] = <Map<String, dynamic>>[
      for (final (id, name) in [
        ('debug-vault-1', '开发密钥'),
        ('debug-vault-2', '共享模型'),
        ('debug-vault-3', '个人服务'),
        ('debug-vault-4', '备用模型'),
      ])
        <String, dynamic>{'id': id, 'name': name, 'keyVersion': '1'},
    ];
    _defs.addAll([
      EnvDef('debug-env-1', '开发环境', [const EnvRef('debug-vault-1', 'all', writable: true)]),
      EnvDef('debug-env-2', '自动化工具', [
        const EnvRef('debug-vault-2', 'pick', items: [RefItem('OPENAI_API_KEY', 'LLM_KEY'), RefItem('MODEL')]),
      ]),
      EnvDef('debug-env-3', '个人服务', [const EnvRef('debug-vault-3', 'all', writable: true)]),
      // 名字冲突（被遮住的 MODEL）和已失效的引用。
      EnvDef('debug-env-4', '合并示例', [
        const EnvRef('debug-vault-2', 'all'),
        const EnvRef('debug-vault-4', 'all'),
        const EnvRef('debug-vault-gone', 'all'),
      ]),
    ]);
    cache.variables = {
      'debug-vault-1': {
        'API_KEY': CachedVariable('demo-key-not-a-secret', 1),
        'API_URL': CachedVariable('https://api.example.invalid', 1),
        // 模拟解不开的变量，用来检查“无法解密”的显示和删除。
        'OLD_TOKEN': CachedVariable('', 1),
      },
      'debug-vault-2': {
        'MODEL': CachedVariable('demo-model', 1),
        'OPENAI_API_KEY': CachedVariable('demo-openai-not-a-secret', 1),
      },
      'debug-vault-4': {'MODEL': CachedVariable('demo-backup-model', 1)},
    };
    _rebuild();
    requests.add(
      PairingRequest({
        'id': 'debug-pairing',
        'name': '待批准的电脑',
        'platform': 'linux',
        'signPub': 'debug-sign',
        'boxPub': 'debug-box',
        'rootPub': 'debug-root',
        'ip': '192.0.2.10',
        'canManage': false,
        'authorized': true,
        'expiresAt': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }),
    );
    // 没有用配对码的请求：不出现在待批准列表，只能扫码或手输核对码找到。
    requests.add(
      PairingRequest({
        'id': 'debug-anonymous',
        'name': '只能扫码找到的电脑',
        'platform': 'darwin',
        'signPub': 'debug-sign-2',
        'boxPub': 'debug-box-2',
        'rootPub': 'debug-root',
        'ip': '198.51.100.20',
        'canManage': false,
        'authorized': false,
        'expiresAt': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }),
    );
  }

  void close() {
    if (!_listening.isCompleted) _listening.complete();
  }

  @override
  Future<void> listen(void Function() onChanged, void Function() onPairing, void Function() onApproval) =>
      _listening.future;
  @override
  Future<void> sync({bool full = false}) async => check();
  @override
  Future<bool> hasAccount() async => config != null;
  @override
  Future<bool> load() async {
    config ??= sampleConfig;
    return true;
  }

  @override
  Future<void> adopt(LocalConfig c) async {
    if (config == null) reset();
    config = c;
  }

  @override
  void lock() {
    localKey = null;
  }

  @override
  Future<void> wipe() async {
    config = null;
    cache = SyncCache();
    requests.clear();
  }

  @override
  Future<bool> logout({bool confirmLast = false}) async {
    check();
    await wipe();
    return true;
  }

  /// 合成数据不加密：变量的值直接存在缓存里，备注和“解不开”的标记另外存放。
  final _notes = <String, String>{};
  final _broken = <String>{};

  /// 环境的定义；每次修改后由 [_rebuild] 按引用展开成 cache.environments，和服务端的同步结果一致。
  final _defs = <EnvDef>[];

  List<Map<String, dynamic>> get _vaultList => (cache.manager!['vaults'] as List).cast<Map<String, dynamic>>();

  void _rebuild() {
    final ids = _vaultList.map((v) => v['id']).toSet();
    cache.manager!['environments'] = [
      for (final e in _defs)
        {
          'id': e.id,
          'name': e.name,
          'refs': [
            for (final r in e.refs) {...r.toJson(), 'missing': !ids.contains(r.vaultId)},
          ],
        },
    ];
    cache.environments = [
      for (final e in _defs)
        () {
          final r = expandRefs(e.refs, variableNames);
          return Environment(e.id, e.name, 'rw', 0, items: r.items, shadowed: r.shadowed);
        }(),
    ];
  }

  int _defIndex(String id) {
    final i = _defs.indexWhere((e) => e.id == id);
    if (i < 0) throw VaultException('环境不存在，可能已被删除。');
    return i;
  }

  @override
  Map<String, VarEntry> entries(String vaultId) => {
    for (final e in (cache.variables[vaultId] ?? {}).entries)
      if (!_broken.contains('$vaultId/${e.key}'))
        e.key: VarEntry(e.value.value, note: _notes['$vaultId/${e.key}'] ?? ''),
  };

  @override
  List<String> brokenVariables(String vaultId) => [
    for (final n in (cache.variables[vaultId] ?? {}).keys)
      if (_broken.contains('$vaultId/$n')) n,
  ]..sort();

  @override
  Map<String, VarEntry> envEntries(String envId) {
    final out = <String, VarEntry>{};
    for (final it in environment(envId).items) {
      final e = entries(it.vaultId)[it.source];
      if (e != null) out[it.name] = e;
    }
    return out;
  }

  @override
  Future<String> createVault(String name) async {
    check();
    final id = 'debug-vault-${++_nextId}';
    _vaultList.add({'id': id, 'name': name.trim(), 'keyVersion': '1'});
    _rebuild();
    return id;
  }

  @override
  Future<void> renameVault(String id, String name) async {
    check();
    _vaultList.firstWhere((v) => v['id'] == id)['name'] = name.trim();
  }

  @override
  Future<void> deleteVault(String id) async {
    check();
    _vaultList.removeWhere((v) => v['id'] == id);
    cache.variables.remove(id);
    _rebuild();
  }

  @override
  Future<String> createEnvironment(String name, List<EnvRef> refs) async {
    check();
    final dup = duplicateNames(refs, variableNames);
    if (dup.isNotEmpty) throw VaultException('环境里有重名的变量：${dup.join('、')}。请给其中一个改名，或取消勾选。');
    final id = 'debug-env-${++_nextId}';
    _defs.add(EnvDef(id, name.trim(), refs));
    _rebuild();
    return id;
  }

  @override
  Future<void> saveEnvironment(String id, String name, List<EnvRef> refs) async {
    check();
    final dup = duplicateNames(refs, variableNames);
    if (dup.isNotEmpty) throw VaultException('环境里有重名的变量：${dup.join('、')}。请给其中一个改名，或取消勾选。');
    _defs[_defIndex(id)] = EnvDef(id, name.trim(), refs);
    _rebuild();
  }

  @override
  Future<void> deleteEnvironment(String id) async {
    check();
    _defs.removeAt(_defIndex(id));
    for (final d in devices) {
      (d.json['grants'] as List).removeWhere((g) => g['environmentId'] == id);
    }
    _rebuild();
  }

  @override
  Future<void> setVariable(String vaultId, String name, String value, String note) async {
    check();
    if (!_vaultList.any((v) => v['id'] == vaultId)) throw VaultException('变量库不存在，可能已被删除。');
    (cache.variables[vaultId] ??= {})[name] = CachedVariable(value, 1);
    _notes['$vaultId/$name'] = note.trim();
    _broken.remove('$vaultId/$name');
    _rebuild();
  }

  @override
  Future<void> deleteVariable(String vaultId, String name) async {
    check();
    cache.variables[vaultId]?.remove(name);
    _notes.remove('$vaultId/$name');
    _broken.remove('$vaultId/$name');
    _rebuild();
  }

  @override
  Future<List<PairingRequest>> pendingPairings() async {
    check();
    return [...requests];
  }

  @override
  Future<PairingCode> createPairingCode({int minutes = 10}) async {
    check();
    return PairingCode('7K3M9Q2P', DateTime.now().add(Duration(minutes: minutes)));
  }

  @override
  Future<PairingRequest> pairingFromQr(String qr) async {
    check();
    final id = parsePairingQr(qr)?.$1;
    return requests.firstWhere((p) => p.id == id, orElse: () => throw VaultException('没有找到模拟配对请求，请重置示例数据。'));
  }

  @override
  Future<PairingRequest> pairingFromCode(String code) async {
    check();
    return requests.firstWhere(
      (p) =>
          normalizeCode(pairingCode(pairingFingerprint(p.id, p.signPub, p.boxPub, p.rootPub))) == normalizeCode(code),
      orElse: () => throw VaultException('核对码不匹配，请使用调试目录中的示例核对码。'),
    );
  }

  @override
  Future<void> approvePairing(PairingRequest p, {required bool asManager, List<Grant> grants = const []}) async {
    check();
    (cache.manager!['devices'] as List).add(
      _device(p.id, p.name, p.platform, asManager ? 'manager' : 'client', grants),
    );
    requests.removeWhere((r) => r.id == p.id);
  }

  @override
  Future<void> rejectPairing(String id, {bool block = false}) async {
    check();
    requests.removeWhere((r) => r.id == id);
  }

  DeviceInfo _findDevice(String id) => devices.firstWhere((d) => d.id == id);
  @override
  Future<void> updateGrants(DeviceInfo d, List<Grant> grants) async {
    check();
    // 与服务端一致：原有授权保留激活状态和顺序，新授权排在最后。
    _findDevice(d.id).json['grants'] = [
      for (final (i, g) in grants.indexed) {...g.toJson(), 'active': g.active, 'position': i},
    ];
  }

  @override
  Future<void> renameDevice(String id, String name) async {
    check();
    _findDevice(id).json['name'] = name.trim();
  }

  @override
  Future<void> setSystemVars(String id, bool on) async {
    check();
    _findDevice(id).json['systemVars'] = on;
  }

  @override
  Future<void> setAutoUpdate(String id, bool on) async {
    check();
    _findDevice(id).json['autoUpdate'] = on;
  }

  /// 模拟电脑收到更新请求：过一会儿上报新版本，不请求更新源、不发推送。
  @override
  Future<void> requestCliUpdate(String id) async {
    check();
    if (offlineDevices.contains(id)) {
      throw ApiException(409, 'device_offline', '这台电脑的后台服务现在没有连上服务器。请确认电脑开机并联网，或在电脑上运行 harmonia update。');
    }
    final device = _findDevice(id);
    final target = debugCliLatest(device.version);
    Future<void>.delayed(cliUpdateDelay, () {
      if (!devices.any((d) => d.id == id)) return;
      device.json['version'] = target;
      onSimulatedChange?.call();
    });
  }

  @override
  Future<void> setActivation(String deviceId, List<Grant> ordered) async {
    check();
    _findDevice(deviceId).json['grants'] = [
      for (final (i, g) in ordered.indexed) {...g.toJson(), 'active': g.active, 'position': i},
    ];
  }

  @override
  Future<void> revokeDevice(String id) async {
    check();
    (cache.manager!['devices'] as List).removeWhere((d) => d['id'] == id);
  }

  @override
  Future<RotationAttempt> rotateRecovery(Uint8List newCode, {String? key}) async {
    check();
    final rotation = key ?? 'debug-rotation-${++_nextId}';
    _rotations.add(rotation);
    cache.self['rotationRequired'] = false;
    return RotationAttempt(rotation, _rotations.length);
  }

  @override
  Future<bool> rotationCompleted(String key) async => _rotations.contains(key);
}
