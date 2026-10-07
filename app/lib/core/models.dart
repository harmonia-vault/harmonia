// 同步数据模型（docs/protocol.md 3.4）。
class Environment {
  Environment(this.id, this.name, this.keyVersion, this.role, this.expiresAt);
  final String id;
  final String name;
  final int keyVersion;
  final String role;
  final int expiresAt;

  factory Environment.fromJson(Map<String, dynamic> j) => Environment(
        j['id'] as String,
        j['name'] as String,
        int.parse(j['keyVersion'] as String),
        j['role'] as String,
        j['expiresAt'] as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'keyVersion': '$keyVersion',
        'role': role,
        'expiresAt': expiresAt,
      };
}

class Envelope {
  Envelope(this.envId, this.keyVersion, this.sealed, this.sig);
  final String envId;
  final int keyVersion;
  final String sealed;
  final String sig;

  factory Envelope.fromJson(Map<String, dynamic> j) => Envelope(
        j['envId'] as String,
        int.parse(j['keyVersion'] as String),
        j['sealed'] as String,
        j['sig'] as String,
      );

  Map<String, dynamic> toJson() =>
      {'envId': envId, 'keyVersion': '$keyVersion', 'sealed': sealed, 'sig': sig};
}

class CachedVariable {
  CachedVariable(this.value, this.keyVersion);
  final String value;
  final int keyVersion;
}

class Grant {
  Grant(this.envId, this.role, this.expiresAt, {this.active = true, this.position = 0});
  final String envId;
  final String role;
  final int expiresAt;

  /// 激活状态和顺序：排在前面（position 小）的环境提供同名变量。只由服务端下发，修改授权时不提交。
  final bool active;
  final int position;

  Grant copyWith({bool? active}) => Grant(envId, role, expiresAt, active: active ?? this.active, position: position);

  factory Grant.fromJson(Map<String, dynamic> j) => Grant(j['envId'] as String, j['role'] as String, j['expiresAt'] as int,
      active: j['active'] as bool? ?? true, position: j['position'] as int? ?? 0);

  Map<String, dynamic> toJson() => {'envId': envId, 'role': role, 'expiresAt': expiresAt};
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
  /// 按激活顺序排列。
  List<Grant> get grants => (json['grants'] as List).map((g) => Grant.fromJson((g as Map).cast<String, dynamic>())).toList()
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
  int get expiresAt => json['expiresAt'] as int;
}

/// 本机持久化的同步缓存（只含密文与封装，没有明文）。
class SyncCache {
  int seq = 0;
  Map<String, dynamic> self = {};
  List<Environment> environments = [];
  List<Envelope> envelopes = [];
  Map<String, Map<String, CachedVariable>> variables = {};
  Map<String, dynamic>? manager;

  bool get rotationRequired => self['rotationRequired'] == true;

  List<DeviceInfo> get devices => ((manager?['devices'] as List?) ?? [])
      .map((d) => DeviceInfo((d as Map).cast<String, dynamic>()))
      .toList();

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'self': self,
        'environments': environments.map((e) => e.toJson()).toList(),
        'envelopes': envelopes.map((e) => e.toJson()).toList(),
        'variables': variables.map((env, vars) => MapEntry(env,
            vars.map((n, v) => MapEntry(n, {'value': v.value, 'keyVersion': v.keyVersion})))),
        'manager': manager,
      };

  static SyncCache fromJson(Map<String, dynamic> j) {
    final c = SyncCache()
      ..seq = j['seq'] as int
      ..self = (j['self'] as Map).cast<String, dynamic>()
      ..environments = (j['environments'] as List)
          .map((e) => Environment.fromJson((e as Map).cast<String, dynamic>()))
          .toList()
      ..envelopes = (j['envelopes'] as List)
          .map((e) => Envelope.fromJson((e as Map).cast<String, dynamic>()))
          .toList()
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
