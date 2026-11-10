// 页面调试专用的后台通知：不申请真实权限、不取推送令牌、不访问中继和实例（AGENTS.md 第 12 条）。
import 'push.dart';

enum DebugPushScenario { ok, needsPermission, systemOff, unavailable, serverOff }

class DebugPushDevice implements PushDevice {
  PushPermission perm = PushPermission.granted;
  bool hasToken = true;
  bool opened = false;

  @override
  Future<PushPermission> permission() async => perm;

  /// 模拟用户在系统弹窗里点了“允许”。
  @override
  Future<bool> requestPermission() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    perm = PushPermission.granted;
    return true;
  }

  @override
  Future<PushToken?> token() async => hasToken ? const PushToken('debug-token') : null;

  @override
  Future<void> openSettings() async => perm = PushPermission.granted;

  @override
  Future<bool> takeOpened() async {
    final o = opened;
    opened = false;
    return o;
  }
}

class DebugPushRelay implements PushRelay {
  int _next = 0;
  @override
  Future<String> register(String platform, PushToken token) async => 'debug-handle-${++_next}';
  @override
  Future<bool> confirm(String handle, PushToken token) async => true;
  @override
  Future<void> remove(String handle) async {}
}

class DebugPushInstance implements PushInstance {
  bool allows = true;
  @override
  Future<bool> allowsPush() async => allows;
  @override
  Future<void> setHandle(String handle) async {}
  @override
  Future<void> clearHandle() async {}
}
