// 批准页上的有效时长和授权范围（设计文档 17.4），以及按设备记住上次的选择。

/// 有效时长：仅这一次、若干分钟，或长期（直到电脑重启或退出登录）。
class ApprovalDuration {
  const ApprovalDuration._(this.minutes);

  /// 仅这一次为 0，长期为 -1，其余为分钟数。
  final int minutes;

  static const once = ApprovalDuration._(0);
  static const forever = ApprovalDuration._(-1);

  /// 自定义时长的范围：1 分钟到 30 天。
  static const minMinutes = 1, maxMinutes = 30 * 24 * 60;

  factory ApprovalDuration.of(int minutes) {
    if (minutes < minMinutes || minutes > maxMinutes) throw ArgumentError.value(minutes, 'minutes', '超出 1 分钟到 30 天');
    return ApprovalDuration._(minutes);
  }

  /// 批准页列出的固定选项（另有“自定义”）。
  static final presets = [once, ApprovalDuration._(30), ApprovalDuration._(120), ApprovalDuration._(480), forever];

  bool get isOnce => minutes == 0;
  bool get isForever => minutes < 0;
  bool get isPreset => presets.contains(this);

  String get label {
    if (isOnce) return '仅这一次';
    if (isForever) return '长期';
    if (minutes % (24 * 60) == 0) return '${minutes ~/ (24 * 60)} 天';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时';
    return '$minutes 分钟';
  }

  /// 授权的到期时间（毫秒）；长期为 0，仅这一次也为 0（不记录授权）。
  int expiresAt(int nowMs) => minutes > 0 ? nowMs + minutes * 60000 : 0;

  String encode() => '$minutes';

  /// 读取保存的选择；读不懂时为“仅这一次”。
  static ApprovalDuration decode(String? raw) {
    final m = int.tryParse(raw ?? '');
    if (m == null || m == 0) return once;
    if (m < 0) return forever;
    return m <= maxMinutes ? ApprovalDuration._(m) : once;
  }

  @override
  bool operator ==(Object other) => other is ApprovalDuration && other.minutes == minutes;

  @override
  int get hashCode => minutes.hashCode;
}

/// 一台设备上次的选择：有效时长和授权范围（terminal 或 all）。第一次为“仅这一次”“仅这个终端”。
class ApprovalChoice {
  const ApprovalChoice(this.duration, this.scope);
  final ApprovalDuration duration;
  final String scope;

  static const initial = ApprovalChoice(ApprovalDuration.once, 'terminal');

  String encode() => '${duration.encode()}|$scope';

  static ApprovalChoice decode(String? raw) {
    final parts = (raw ?? '').split('|');
    if (parts.length != 2) return initial;
    return ApprovalChoice(ApprovalDuration.decode(parts[0]), parts[1] == 'all' ? 'all' : 'terminal');
  }

  /// 授权给 Windows 电脑时只能选“这台电脑上的所有程序”（设计文档 17.5）。
  ApprovalChoice forPlatform(String platform) => platform == 'windows' ? ApprovalChoice(duration, 'all') : this;

  /// 提交给服务端的范围：仅这一次时为 once。
  String get submitScope => duration.isOnce ? 'once' : scope;
}
