// 同步数据模型（docs/protocol.md 3.4）。
import 'refs.dart';

export 'refs.dart' show EnvItem, EnvRef, RefItem;

/// 这台设备被授权的一个环境；管理设备能看到全部环境。[items] 是服务端按引用展开的最终名字。
class Environment {
  Environment(
    this.id,
    this.name,
    this.role,
    this.expiresAt, {
    this.localDecrypt = true,
    this.items = const [],
    this.shadowed = const [],
  });
  final String id;
  final String name;
  final String role;
  final int expiresAt;
  final bool localDecrypt;
  final List<EnvItem> items;

  /// 被遮住的同名变量：“全部变量”引用的变量库后来新增了重名的变量（设计文档 17.1）。
  final List<EnvItem> shadowed;

  factory Environment.fromJson(Map<String, dynamic> j) => Environment(
    j['id'] as String,
    j['name'] as String,
    j['role'] as String,
    j['expiresAt'] as int,
    localDecrypt: j['localDecrypt'] as bool? ?? true,
    items: _items(j['items']),
    shadowed: _items(j['shadowed']),
  );

  static List<EnvItem> _items(Object? raw) =>
      ((raw as List?) ?? []).map((i) => EnvItem.fromJson((i as Map).cast<String, dynamic>())).toList();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role,
    'expiresAt': expiresAt,
    'localDecrypt': localDecrypt,
    'items': items.map((i) => i.toJson()).toList(),
    'shadowed': shadowed.map((i) => i.toJson()).toList(),
  };
}

/// 账号里的一个变量库（只有管理设备能看到全部）。
class VaultInfo {
  VaultInfo(this.id, this.name, this.keyVersion);
  final String id;
  final String name;
  final int keyVersion;

  factory VaultInfo.fromJson(Map<String, dynamic> j) =>
      VaultInfo(j['id'] as String, j['name'] as String, int.parse(j['keyVersion'] as String));
}

/// 环境的定义：名字和对变量库的引用（只有管理设备能看到）。
class EnvDef {
  EnvDef(this.id, this.name, this.refs);
  final String id;
  final String name;
  final List<EnvRef> refs;

  factory EnvDef.fromJson(Map<String, dynamic> j) => EnvDef(
    j['id'] as String,
    j['name'] as String,
    (j['refs'] as List).map((r) => EnvRef.fromJson((r as Map).cast<String, dynamic>())).toList(),
  );
}

class Envelope {
  Envelope(this.vaultId, this.keyVersion, this.sealed, this.sig);
  final String vaultId;
  final int keyVersion;
  final String sealed;
  final String sig;

  factory Envelope.fromJson(Map<String, dynamic> j) =>
      Envelope(j['vaultId'] as String, int.parse(j['keyVersion'] as String), j['sealed'] as String, j['sig'] as String);

  Map<String, dynamic> toJson() => {'vaultId': vaultId, 'keyVersion': '$keyVersion', 'sealed': sealed, 'sig': sig};
}

class CachedVariable {
  CachedVariable(this.value, this.keyVersion);
  final String value;
  final int keyVersion;
}

/// 一台设备对一个环境的授权。[localDecrypt] 开启时设备持有环境引用到的变量库的钥匙，可以在本机解密。
class Grant {
  Grant(this.envId, this.role, this.expiresAt, {this.localDecrypt = true, this.active = true, this.position = 0});
  final String envId;
  final String role;
  final int expiresAt;
  final bool localDecrypt;

  /// 激活状态和顺序：排在前面（position 小）的环境提供同名变量。只由服务端下发，修改授权时不提交。
  final bool active;
  final int position;

  Grant copyWith({bool? active}) =>
      Grant(envId, role, expiresAt, localDecrypt: localDecrypt, active: active ?? this.active, position: position);

  factory Grant.fromJson(Map<String, dynamic> j) => Grant(
    j['environmentId'] as String,
    j['role'] as String,
    j['expiresAt'] as int,
    localDecrypt: j['localDecrypt'] as bool? ?? true,
    active: j['active'] as bool? ?? true,
    position: j['position'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'environmentId': envId,
    'role': role,
    'expiresAt': expiresAt,
    'localDecrypt': localDecrypt,
  };
}

class DeviceInfo {
  DeviceInfo(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get platform => json['platform'] as String;
  String get kind => json['kind'] as String;
  String get signPub => json['signPub'] as String;
  String get boxPub => json['boxPub'] as String;
  String get cert => json['cert'] as String;
  int get createdAt => json['createdAt'] as int;
  int get lastSeenAt => json['lastSeenAt'] as int;
  bool get isManager => kind == 'manager';

  /// 设备最近一次同步时上报的版本；还没有上报过，或服务端较旧时为空。
  String get version => json['version'] as String? ?? '';

  /// “写入系统变量”开关，只有 Windows 上的命令行使用；较旧的服务端没有这个字段。
  bool get systemVars => json['systemVars'] as bool? ?? false;

  /// “自动更新”开关，只有电脑上的命令行使用，由它的后台服务执行。
  bool get autoUpdate => json['autoUpdate'] as bool? ?? false;

  /// 按激活顺序排列。
  List<Grant> get grants =>
      (json['grants'] as List).map((g) => Grant.fromJson((g as Map).cast<String, dynamic>())).toList()
        ..sort((a, b) => a.position.compareTo(b.position));
}

class PairingRequest {
  PairingRequest(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get platform => json['platform'] as String;
  String get signPub => json['signPub'] as String;
  String get boxPub => json['boxPub'] as String;
  String get rootPub => json['rootPub'] as String;

  /// 发起请求的网络地址，用于判断是否本人发起和“阻止这个网络”。
  String get ip => json['ip'] as String? ?? '';

  /// 发起方的客户端具备管理功能，才能被批准为管理设备。
  bool get canManage => json['canManage'] as bool? ?? false;

  /// 由配对码创建：出现在待批准列表中，前台时自动弹出批准页。匿名请求只能扫码或手输核对码取到（协议 3.2）。
  bool get authorized => json['authorized'] as bool? ?? false;
  int get expiresAt => json['expiresAt'] as int;
}

/// 管理设备生成的一次性配对码：8 位，有效期 5 到 60 分钟，用一次即作废（协议 3.2）。
class PairingCode {
  PairingCode(this.code, this.expiresAt);
  final String code;
  final DateTime expiresAt;

  /// 按 4 位一组显示。
  String get formatted => code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;
}

/// 本机持久化的同步缓存（只含密文与封装，没有明文）。变量按变量库 ID、再按变量库里的原名保存。
class SyncCache {
  int seq = 0;
  Map<String, dynamic> self = {};
  List<Environment> environments = [];
  List<Envelope> envelopes = [];
  Map<String, Map<String, CachedVariable>> variables = {};
  Map<String, dynamic>? manager;

  bool get rotationRequired => self['rotationRequired'] == true;

  List<DeviceInfo> get devices =>
      ((manager?['devices'] as List?) ?? []).map((d) => DeviceInfo((d as Map).cast<String, dynamic>())).toList();

  /// 全部变量库，按创建先后（只有管理设备有）。
  List<VaultInfo> get vaults =>
      ((manager?['vaults'] as List?) ?? []).map((v) => VaultInfo.fromJson((v as Map).cast<String, dynamic>())).toList();

  /// 全部环境的定义，按创建先后（只有管理设备有）。
  List<EnvDef> get envDefs => ((manager?['environments'] as List?) ?? [])
      .map((e) => EnvDef.fromJson((e as Map).cast<String, dynamic>()))
      .toList();

  Map<String, dynamic> toJson() => {
    'seq': seq,
    'self': self,
    'environments': environments.map((e) => e.toJson()).toList(),
    'envelopes': envelopes.map((e) => e.toJson()).toList(),
    'variables': variables.map(
      (vault, vars) => MapEntry(vault, vars.map((n, v) => MapEntry(n, {'value': v.value, 'keyVersion': v.keyVersion}))),
    ),
    'manager': manager,
  };

  static SyncCache fromJson(Map<String, dynamic> j) {
    final c = SyncCache()
      ..seq = j['seq'] as int
      ..self = (j['self'] as Map).cast<String, dynamic>()
      ..environments = (j['environments'] as List)
          .map((e) => Environment.fromJson((e as Map).cast<String, dynamic>()))
          .toList()
      ..envelopes = (j['envelopes'] as List).map((e) => Envelope.fromJson((e as Map).cast<String, dynamic>())).toList()
      ..manager = (j['manager'] as Map?)?.cast<String, dynamic>();
    final vars = (j['variables'] as Map).cast<String, dynamic>();
    for (final entry in vars.entries) {
      c.variables[entry.key] = (entry.value as Map).cast<String, dynamic>().map((n, v) {
        final m = (v as Map).cast<String, dynamic>();
        return MapEntry(n, CachedVariable(m['value'] as String, m['keyVersion'] as int));
      });
    }
    return c;
  }
}
