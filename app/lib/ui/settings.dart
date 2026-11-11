// 设置：账号、本机保护、恢复码、更新、退出。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/appearance.dart';
import '../core/push.dart';
import '../app/updater.dart';
import '../core/update_info.dart';
import '../core/api.dart' show appVersion;
import 'about.dart';
import 'page_debug.dart';
import 'app_scope.dart';
import 'devices.dart' show platformIcon;
import 'lock.dart';
import 'recovery_pages.dart';
import 'theme.dart';
import 'glass_overlays.dart';
import 'glass.dart';
import 'glass_transparency.dart';
import 'widgets.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.c, this.section});
  final AppController c;
  final String? section;
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _bioAvailable = false;
  bool _bioEnabled = false;
  bool _changingAppearance = false;
  bool _changingPush = false;

  AppController get c => widget.c;

  @override
  void initState() {
    super.initState();
    _loadBio();
  }

  Future<void> _loadBio() async {
    final available = await c.identity.bioAvailable();
    final enabled = await c.identity.bioEnabled();
    if (mounted) {
      setState(() {
        _bioAvailable = available;
        _bioEnabled = enabled;
      });
    }
  }

  Future<void> _toggleBio(bool v) async {
    final key = await verifyIdentity(context, '验证身份以${v ? '开启' : '关闭'}${c.identity.bio('解锁')}');
    if (key == null || !mounted) return;
    if (v) {
      var enabled = false;
      if (await runBusy(context, () async => enabled = await c.identity.enableBio(key)) && enabled && mounted) {
        toast(context, '已开启${c.identity.bio('解锁')}');
      }
    } else {
      await c.identity.disableBio();
    }
    await _loadBio();
  }

  Future<void> _changePin() async {
    final key = await verifyIdentity(context, '验证身份以修改 App PIN');
    if (key == null || !mounted) return;
    final pin = await askNewPin(context);
    if (pin == null || !mounted) return;
    await runBusy(context, () => c.identity.keyring.changePin(key, pin), done: 'App PIN 已修改');
  }

  Future<void> _pickChannel() async {
    final picked = await showAppDialog<UpdateChannel>(
      context: context,
      builder: (ctx) => AppSimpleDialog(
        title: const Text('更新渠道'),
        children: [
          for (final ch in UpdateChannel.values)
            ListTile(
              leading: Icon(ch == c.updateChannel ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(ch.label),
              subtitle: Text(ch.description),
              onTap: () => Navigator.pop(ctx, ch),
            ),
        ],
      ),
    );
    if (picked == null || picked == c.updateChannel) return;
    await c.setUpdateChannel(picked);
    if (!mounted) return;
    toast(
      context,
      picked == UpdateChannel.stable && isPrerelease(appVersion)
          ? '已切换到正式版渠道。正式版发布更高的版本后会提示升级'
          : '已切换到${picked.label}渠道',
    );
  }

  Future<void> _logout() async {
    final last = c.vault.isLastManager;
    final ok = await confirmDialog(
      context,
      title: '退出登录？',
      body: last ? '这是账号里唯一的管理设备。\n退出后，只能用恢复码在新手机上找回账号。\n请确认恢复码还在。' : '这台手机将从账号中移除，并清除本机保存的数据。',
      ok: '退出',
      danger: true,
    );
    if (!ok || !mounted) return;
    if (!await confirmIdentity(context, '验证身份以退出登录')) return;
    if (!mounted) return;
    await runBusy(context, () => c.logout(confirmLast: last));
  }

  Future<void> _togglePush(bool enabled) => _pushAction(() => c.setPushEnabled(enabled));

  Future<void> _pushAction(Future<void> Function() fn) async {
    setState(() => _changingPush = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _changingPush = false);
    }
  }

  Future<void> _pickColorMode() async {
    final picked = await showAppDialog<AppColorMode>(
      context: context,
      builder: (ctx) => AppSimpleDialog(
        title: const Text('颜色模式'),
        children: [
          for (final mode in AppColorMode.values)
            ListTile(
              title: Text(colorModeLabel(mode)),
              trailing: c.appearance.colorMode == mode ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, mode),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _changingAppearance = true);
    try {
      await c.setColorMode(picked);
    } catch (_) {
      if (mounted) toast(context, '颜色模式未能切换，请重试。');
    } finally {
      if (mounted) setState(() => _changingAppearance = false);
    }
  }

  Future<void> _closeDeveloperOptions() async {
    try {
      await c.setDeveloperOptions(false);
      if (mounted) toast(context, '已关闭开发者选项。');
    } catch (_) {
      if (mounted) toast(context, '开发者选项未能关闭，请重试。');
    }
  }

  Future<void> _openPageDebug() async {
    c.beginPageDebug();
    try {
      final route = MaterialPageRoute<void>(
        builder: (_) =>
            PageDebug(initialColorMode: c.appearance.colorMode, initialGlassOpacity: c.appearance.glassOpacity),
      );
      final closed = Navigator.push(context, route);
      // 转场结束、调试页完全盖住之后才停止绘制真实页面；开始返回时立刻恢复。
      route.animation?.addStatusListener((status) => c.setPageDebugCovers(status == AnimationStatus.completed));
      await closed;
    } finally {
      c.endPageDebug();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = c.vault.config!;
    final p = context.palette;
    final allSections = <Widget>[
      const SectionTitle('账号'),
      Card(
        child: Column(
          children: [
            ListTile(leading: const Icon(Icons.alternate_email), title: Text(cfg.email), subtitle: const Text('账号')),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(cfg.server),
              subtitle: Text(c.online ? '已连接' : '离线，显示的是上次同步的数据'),
              trailing: Icon(Icons.circle, size: 10, color: c.online ? p.ok : p.mute),
            ),
            const Divider(),
            ListTile(leading: Icon(platformIcon(c.platform)), title: Text(cfg.deviceName), subtitle: const Text('本机')),
          ],
        ),
      ),
      const SectionTitle('外观'),
      if (c.appearanceError != null) Banner2(c.appearanceError!, warn: true),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('颜色模式'),
              subtitle: Text(colorModeLabel(c.appearance.colorMode)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _changingAppearance ? null : _pickColorMode,
            ),
            const Divider(),
            GlassTransparencyControl(
              value: c.appearance.glassOpacity,
              onChanged: c.setGlassOpacity,
              onPreview: c.previewGlassOpacity,
            ),
          ],
        ),
      ),
      const SectionTitle('通知'),
      Card(
        child: Column(
          children: [
            AppSwitchTile(
              icon: const Icon(Icons.notifications_outlined),
              title: const Text('后台通知'),
              subtitle: Text(pushStatusText(c.pushStatus)),
              value: c.pushEnabled,
              onChanged: _changingPush ? null : _togglePush,
            ),
            if (c.pushStatus == PushStatus.needsPermission) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('允许通知'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _changingPush ? null : () => _pushAction(c.requestPushPermission),
              ),
            ],
            if (c.pushStatus == PushStatus.systemOff) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('打开系统设置'),
                subtitle: const Text('允许 Harmonia 发送通知后回到这里'),
                trailing: const Icon(Icons.open_in_new),
                onTap: c.openNotificationSettings,
              ),
            ],
          ],
        ),
      ),
      const SectionTitle('安全'),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('修改 App PIN'),
              subtitle: const Text('离开 App 超过 5 分钟后，需输入 App PIN'),
              onTap: _changePin,
            ),
            if (_bioAvailable || _bioEnabled) ...[
              const Divider(),
              AppSwitchTile(
                icon: Icon(bioIcon(c.identity)),
                value: _bioEnabled,
                onChanged: _toggleBio,
                title: Text(c.identity.bio('解锁')),
                subtitle: Text('可以用${c.identity.bio('代替')} App PIN'),
              ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('更换恢复码'),
              subtitle: const Text('保存并核对新恢复码后，旧恢复码失效'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RotationPage(c: c))),
            ),
          ],
        ),
      ),
      const SectionTitle('关于'),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('检查更新'),
              subtitle: Text('当前版本 $appVersion'),
              onTap: () => checkForUpdate(context, manual: true, channel: c.updateChannel),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.alt_route_outlined),
              title: const Text('更新渠道'),
              subtitle: Text(c.updateChannel.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickChannel,
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于 Harmonia'),
              subtitle: const Text('版本信息和开源项目的版权说明'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AboutPage(c: c))),
            ),
          ],
        ),
      ),
      const SizedBox(height: Space.xl),
      OutlinedButton(
        style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
        onPressed: _logout,
        child: const Text('退出登录'),
      ),
      if (c.prefs.developerOptions && !AppScope.isSimulated(context)) ...[
        const SectionTitle('开发者选项'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.developer_mode),
                title: const Text('页面调试'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openPageDebug,
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: const Text('关闭开发者选项'),
                subtitle: const Text('在“关于”页连点 5 次版本号可以再次打开'),
                onTap: _closeDeveloperOptions,
              ),
            ],
          ),
        ),
      ],
    ];
    if (widget.section case final section?) {
      var include = false;
      final selected = <Widget>[];
      for (final child in allSections) {
        if (child is SectionTitle) {
          include = child.text == section;
          continue;
        }
        if (include) selected.add(child);
      }
      return AppPage(
        appBar: AppBarSurface(title: Text(section)),
        body: (context) =>
            ListView(padding: pagePadding(context, const EdgeInsets.fromLTRB(16, 12, 16, 96)), children: selected),
      );
    }
    return AppTabPage(title: '设置', padding: const EdgeInsets.fromLTRB(16, 0, 16, 96), children: allSections);
  }
}

/// “后台通知”开关下方的说明（设计文档 18.4）。
String pushStatusText(PushStatus s) => switch (s) {
  PushStatus.checking => '正在检查…',
  PushStatus.ok => '有新的请求时通知你',
  PushStatus.off => '已关闭。打开 App 时仍会看到待批准的请求',
  PushStatus.needsPermission => '还没有允许 Harmonia 发送通知',
  PushStatus.systemOff => '通知已在系统设置中关闭',
  PushStatus.unavailable => '这台手机暂时收不到后台通知，打开 App 时会看到待批准的请求',
  PushStatus.serverOff => '这台服务器关闭了后台通知',
};
