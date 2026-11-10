// 后台通知（设计文档 18.4）：首次进入主页时请求权限、回到前台时确认登记、点开通知后的提示。
part of 'controller.dart';

/// 点开通知进来，请求已经处理或过期时的提示。
const staleNotificationText = '这个请求已处理或已过期';

extension Notifications on AppController {
  PushInstance get _pushInstance => _pushInstanceOverride ?? VaultPushInstance(vault, account);

  PushStatus get pushStatus => push.status;
  bool get pushEnabled => push.state.enabled;

  Future<void> _loadPush() async {
    try {
      await push.load();
    } catch (_) {
      // 本机状态读不出来时按全新安装处理，下次回到前台重新登记。
    }
  }

  /// 解锁或回到前台后：先同步，再处理点开的通知和登记。
  Future<void> _syncThenNotifications() async {
    final opened = await _takeOpened();
    final generation = lockGeneration;
    await syncNow();
    if (_disposed || generation != lockGeneration || stage != Stage.home || !vault.isManager) return;
    if (opened && online && approvals.isEmpty && authorizedPairings.isEmpty) {
      staleNotification = true;
      refresh();
    }
    try {
      await push.askOnce();
      if (generation != lockGeneration) return;
      await push.sync(_pushInstance);
    } on RevokedException {
      if (generation == lockGeneration) await _handleRevoked();
      return;
    } catch (_) {
      // 通知只是提醒，登记失败不影响其他流程。
    }
    if (!_disposed && generation == lockGeneration) refresh();
  }

  Future<bool> _takeOpened() async {
    try {
      return await push.device.takeOpened();
    } catch (_) {
      return false;
    }
  }

  Future<void> setPushEnabled(bool enabled) => guard(() => push.setEnabled(enabled, _pushInstance));

  /// 设置页里的“允许通知”。
  Future<void> requestPushPermission() => guard(() async {
    await push.requestPermission();
    await push.sync(_pushInstance, force: true);
  });

  Future<void> openNotificationSettings() => push.device.openSettings();

  /// 退出登录、被撤销、清除本机数据时调用；不等中继答复。
  void _forgetPush() => unawaited(push.forget().catchError((_) {}));
}
