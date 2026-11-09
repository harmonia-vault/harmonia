// 管理设备处理电脑发来的批准请求（docs/protocol.md 3.9，设计文档 17.4）：核对后只解开请求的变量交给电脑，
// 或者替电脑写入；以及查看和结束正在生效的授权。
part of 'vault.dart';

/// 批准请求里的一个变量：环境 ID 和环境里的名字；新增变量时带变量库。
class ApprovalItem {
  const ApprovalItem(this.envId, this.name, [this.vaultId]);
  final String envId;
  final String name;
  final String? vaultId;

  factory ApprovalItem.fromJson(Map<String, dynamic> j) =>
      ApprovalItem(j['environmentId'] as String, j['name'] as String, j['vaultId'] as String?);
}

/// 一个等待批准的请求。[detail] 是原文，签名和请求码都按它计算。
class ApprovalRequest {
  ApprovalRequest(this.json) : _d = (jsonDecode(json['detail'] as String) as Map).cast<String, dynamic>();
  final Map<String, dynamic> json;
  final Map<String, dynamic> _d;

  String get id => json['id'] as String;
  String get deviceId => json['deviceId'] as String;
  String get detail => json['detail'] as String;
  String get payload => json['payload'] as String? ?? '';
  String get sig => json['sig'] as String;
  int get expiresAt => json['expiresAt'] as int;

  bool get isWrite => _d['kind'] == 'write';
  String get command => _d['command'] as String? ?? '';
  String get cwd => _d['cwd'] as String? ?? '';
  String get ephPub => _d['ephPub'] as String? ?? '';
  int get createdAt => _d['createdAt'] as int? ?? 0;
  String get detailDeviceId => _d['deviceId'] as String? ?? '';
  List<ApprovalItem> get items => _list(_d['items']);
  List<ApprovalItem> get deletes => _list(_d['delete']);

  /// 请求码：电脑上显示同一个，供用户核对。
  String get code => approvalCode(detail);

  static List<ApprovalItem> _list(Object? raw) =>
      ((raw as List?) ?? []).map((i) => ApprovalItem.fromJson((i as Map).cast<String, dynamic>())).toList();
}

/// 写入请求里要写的一个变量：[plain] 中省略的字段沿用原值（协议 3.9）。
class ApprovalWrite {
  const ApprovalWrite(this.item, this.plain);
  final ApprovalItem item;
  final Map<String, dynamic> plain;
}

/// 一项正在生效的授权。[expiresAt] 为 0 表示长期。
class AuthorizationInfo {
  AuthorizationInfo(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get deviceId => json['deviceId'] as String;
  String get scope => json['scope'] as String;
  int get expiresAt => json['expiresAt'] as int;
  List<ApprovalItem> get items => ApprovalRequest._list(json['items']);
}

/// 授权范围。
const scopeOnce = 'once', scopeTerminal = 'terminal', scopeAll = 'all';

mixin VaultApprovals {
  HCrypto get crypto;
  ApiClient? get api;
  LocalConfig? get config;
  BoxKey? get boxKey;
  SyncCache get cache;
  List<DeviceInfo> get devices;
  SignKey _root();
  Environment environment(String id);
  EnvDef? envDef(String id);
  List<String> variableNames(String vaultId);
  Map<String, VarEntry> entries(String vaultId);
  Future<void> sync({bool full = false});
  Uint8List _vaultKey(String vaultId);
  int _keyVersion(String vaultId);

  /// 等待处理的请求（发起方还在等待），按发起先后。
  Future<List<ApprovalRequest>> pendingApprovals() async {
    final res = await api!.device('GET', '/api/v1/approvals');
    return (res['approvals'] as List).map((a) => ApprovalRequest((a as Map).cast<String, dynamic>())).toList();
  }

  /// 发起请求的设备；不在这个账号里时为 null。
  DeviceInfo? approvalDevice(ApprovalRequest a) => devices.where((d) => d.id == a.deviceId).firstOrNull;

  /// 按自己同步到的数据核对请求（协议 3.9）：设备证书和请求签名、环境已授权给这台设备、没有到期、
  /// 没有开启本机解密、变量在环境里；写入请求还要求读写权限和可以修改。有问题时返回原因，没有时返回 null。
  String? approvalProblem(ApprovalRequest a, {int? nowMs}) {
    const tampered = '服务器上的数据可能有误，请拒绝这个请求。';
    final d = approvalDevice(a);
    if (d == null || d.isManager) return '发起请求的设备不在这个账号里。$tampered';
    final root = unb64(config!.rootPub);
    if (!crypto.verify(root, deviceCertMsg(d.id, d.kind, d.signPub, d.boxPub), unb64(d.cert)) ||
        !crypto.verify(unb64(d.signPub), approvalRequestMsg(a.id, d.id, a.detail, a.payload), unb64(a.sig)) ||
        a.detailDeviceId != d.id) {
      return '请求的签名不对。$tampered';
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final grants = {for (final g in d.grants) g.envId: g};
    final all = [...a.items, ...a.deletes];
    if (all.isEmpty) return '请求里没有变量。$tampered';
    for (final it in all) {
      final g = grants[it.envId];
      if (g == null || (g.expiresAt != 0 && g.expiresAt <= now)) return '请求的环境没有授权给这台设备，或者授权已到期。$tampered';
      if (g.localDecrypt) return '请求的环境开启了本机解密，不需要批准。$tampered';
      if (a.isWrite && g.role != 'rw') return '这台设备对请求的环境只有只读权限。$tampered';
    }
    for (final it in a.items) {
      final existing = _item(it.envId, it.name);
      if (!a.isWrite) {
        if (existing == null) return '环境里没有 ${it.name}。$tampered';
      } else if (it.vaultId != null) {
        final creatable =
            envDef(it.envId)?.refs.any((r) => r.vaultId == it.vaultId && r.all && r.writable && !r.missing) ?? false;
        if (!creatable || existing != null || variableNames(it.vaultId!).contains(it.name)) {
          return '不能在这个变量库里新增 ${it.name}。$tampered';
        }
      } else if (existing == null || !existing.writable) {
        return '${it.name} 不允许修改。$tampered';
      }
    }
    for (final it in a.deletes) {
      if (_item(it.envId, it.name)?.writable != true) return '${it.name} 不允许删除。$tampered';
    }
    return null;
  }

  EnvItem? _item(String envId, String name) {
    try {
      return environment(envId).items.where((i) => i.name == name).firstOrNull;
    } on VaultException {
      return null;
    }
  }

  /// 变量的来源：变量库 ID 和原名。新增的变量用请求里的变量库和名字。
  ({String vaultId, String source})? approvalSource(ApprovalItem it) {
    if (it.vaultId != null) return (vaultId: it.vaultId!, source: it.name);
    final e = _item(it.envId, it.name);
    return e == null ? null : (vaultId: e.vaultId, source: e.source);
  }

  void _check(ApprovalRequest a) {
    final p = approvalProblem(a);
    if (p != null) throw VaultException(p);
  }

  /// 批准读取请求：只解开请求的变量，加密给电脑的临时公钥，root 签名后提交。
  /// [expiresAt] 为 0 表示长期（[scope] 为 once 时忽略）。
  Future<void> approveRead(ApprovalRequest a, {required String scope, required int expiresAt}) async {
    _check(a);
    final values = <Map<String, dynamic>>[];
    for (final it in a.items) {
      final src = approvalSource(it)!;
      final e = entries(src.vaultId)[src.source];
      if (e == null) throw VaultException('变量 ${it.name} 无法解密，请先在变量库里重新写入它，再让电脑重新发起。');
      values.add({
        'environmentId': it.envId,
        'name': it.name,
        'vaultId': src.vaultId,
        'source': src.source,
        'plain': {'value': e.value, if (e.note.isNotEmpty) 'note': e.note},
      });
    }
    final exp = scope == scopeOnce ? 0 : expiresAt;
    final plain = utf8.encode(jsonEncode({'requestId': a.id, 'scope': scope, 'expiresAt': exp, 'values': values}));
    final sealed = crypto.seal(Uint8List.fromList(plain), unb64(a.ephPub));
    final sig = crypto.sign(_root(), approvalGrantMsg(a.id, sealed));
    await api!.device(
      'POST',
      '/api/v1/approvals/${a.id}/approve',
      body: {'sealed': b64(sealed), 'sig': b64(sig), 'scope': scope, 'expiresAt': exp},
    );
  }

  /// 解开写入请求里加密给这台手机的内容，核对请求 ID 和变量与请求一致。
  List<ApprovalWrite> approvalWrites(ApprovalRequest a) {
    const bad = '写入内容和请求不一致，服务器上的数据可能有误，请拒绝这个请求。';
    final copies = ((jsonDecode(a.payload) as Map)['sealed'] as List).cast<Map>();
    final mine = copies.where((c) => c['managerId'] == config!.deviceId).firstOrNull;
    if (mine == null) throw VaultException('这个请求没有加密给这台手机，请在其他管理设备上处理，或让电脑同步后重新发起。');
    final Map<String, dynamic> content;
    try {
      content = (jsonDecode(utf8.decode(crypto.open(boxKey!, unb64(mine['sealed'] as String)))) as Map)
          .cast<String, dynamic>();
    } on Exception {
      throw VaultException(bad);
    }
    if (content['requestId'] != a.id) throw VaultException(bad);
    final writes = [
      for (final s in (content['set'] as List).cast<Map>())
        ApprovalWrite(ApprovalItem.fromJson(s.cast<String, dynamic>()), (s['plain'] as Map).cast<String, dynamic>()),
    ];
    String key(ApprovalItem i) => '${i.envId}\n${i.name}\n${i.vaultId}';
    final want = a.items.map(key).toList()..sort();
    final got = writes.map((w) => key(w.item)).toList()..sort();
    if (want.join('\n\n') != got.join('\n\n')) throw VaultException(bad);
    for (final w in writes) {
      if (w.item.vaultId != null && w.plain['value'] is! String) throw VaultException(bad);
    }
    return writes;
  }

  /// 批准写入请求：用库钥加密后按变量库批量写入、删除，全部成功后标记已批准。修改已有变量时把新内容
  /// 合并到原来的明文上。
  Future<void> approveWrite(ApprovalRequest a) async {
    _check(a);
    final writes = approvalWrites(a);
    final byVault = <String, ({List<Map<String, String>> set, List<String> delete})>{};
    ({List<Map<String, String>> set, List<String> delete}) batch(String vaultId) =>
        byVault.putIfAbsent(vaultId, () => (set: [], delete: []));
    for (final w in writes) {
      final src = approvalSource(w.item)!;
      final key = _vaultKey(src.vaultId);
      final kv = _keyVersion(src.vaultId);
      var entry = entries(src.vaultId)[src.source] ?? const VarEntry('');
      entry = entry.copyWith(
        value: w.plain['value'] as String? ?? entry.value,
        note: (w.plain['note'] as String?)?.trim() ?? entry.note,
      );
      batch(src.vaultId).set
          .add({'name': src.source, 'value': crypto.encryptVar(key, src.vaultId, kv, src.source, entry)});
    }
    for (final it in a.deletes) {
      final src = approvalSource(it)!;
      batch(src.vaultId).delete.add(src.source);
    }
    // 批量写入一次最多 100 项（协议 3.1）。
    for (final e in byVault.entries) {
      var set = e.value.set, delete = e.value.delete;
      while (set.isNotEmpty || delete.isNotEmpty) {
        final n = set.length < 100 ? set.length : 100;
        final m = delete.length < 100 - n ? delete.length : 100 - n;
        await api!.device(
          'PATCH',
          '/api/v1/vaults/${e.key}/variables',
          body: {'keyVersion': '${_keyVersion(e.key)}', 'set': set.sublist(0, n), 'delete': delete.sublist(0, m)},
          headers: {'idempotency-key': crypto.newId()},
        );
        set = set.sublist(n);
        delete = delete.sublist(m);
      }
    }
    await api!.device('POST', '/api/v1/approvals/${a.id}/approve', body: {});
    await sync();
  }

  Future<void> rejectApproval(String id) async {
    await api!.device('POST', '/api/v1/approvals/$id/reject', body: {});
  }

  /// 正在生效的授权；[deviceId] 不为空时只列出这台设备的。
  Future<List<AuthorizationInfo>> authorizations({String? deviceId}) async {
    final res = await api!.device('GET', '/api/v1/authorizations');
    return [
      for (final a in (res['authorizations'] as List).cast<Map>())
        if (deviceId == null || a['deviceId'] == deviceId) AuthorizationInfo(a.cast<String, dynamic>()),
    ];
  }

  Future<void> endAuthorization(String id) async {
    await api!.device('POST', '/api/v1/authorizations/$id/end', body: {});
  }
}
