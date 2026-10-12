// 设置：账号、本机保护、密码与恢复码、更新、退出。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/appearance.dart';
import '../app/updater.dart';
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
  const SettingsTab({super.key, required this.c});
  final AppController c;
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _bioAvailable = false;
  bool _bioEnabled = false;
  bool _changingAppearance = false;

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

  Future<void> _changePassword() async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showAppDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AppAlertDialog(
        title: const Text('修改登录密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('登录密码只用于在新设备上登录，修改后已授权的设备不受影响。'),
            const SizedBox(height: Space.md),
            TextField(
              controller: a,
              obscureText: true,
              autofillHints: AppScope.isSimulated(context) ? null : const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: '新密码', helperText: '至少 8 位'),
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: b,
              obscureText: true,
              autofillHints: null,
              decoration: const InputDecoration(labelText: '再次输入'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('修改')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (validatePassword(a.text) != null) return toast(context, '新密码至少 8 位');
    if (a.text != b.text) return toast(context, '两次输入的密码不一致');
    if (!await confirmIdentity(context, '验证身份以修改登录密码')) return;
    if (!mounted) return;
    await runBusy(context, () => c.guard(() => c.vault.changePassword(a.text)), done: '登录密码已修改');
  }

  Future<void> _pickChannel() async {
    final picked = await showAppDialog<UpdateChannel>(
      context: context,
      useRootNavigator: false,
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

  Future<void> _toggleGlass(bool enabled) async {
    setState(() => _changingAppearance = true);
    try {
      await c.setLiquidGlass(enabled);
    } catch (_) {
      if (mounted) toast(context, '外观未能切换，请重试。');
    } finally {
      if (mounted) setState(() => _changingAppearance = false);
    }
  }

  Future<void> _pickColorMode() async {
    final picked = await showAppDialog<AppColorMode>(
      context: context,
      useRootNavigator: false,
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

  Future<void> _openPageDebug() async {
    final glass = usesGlass(context);
    c.beginPageDebug();
    try {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PageDebug(
            initialGlass: glass,
            initialColorMode: c.appearance.colorMode,
            initialGlassOpacity: c.appearance.glassOpacity,
          ),
        ),
      );
    } finally {
      c.endPageDebug();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = c.vault.config!;
    final p = context.palette;
    return AppPage(
      appBar: AppBarSurface(title: const Text('设置'), largeTitle: usesGlass(context)),
      body: (context) => ListView(
        padding: pagePadding(context, EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, usesGlass(context) ? 96 : Space.xxl)),
        children: [
          const SectionTitle('账号'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.alternate_email),
                  title: Text(cfg.email),
                  subtitle: const Text('账号'),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(cfg.server),
                  subtitle: Text(c.online ? '已连接' : '离线，显示的是上次同步的数据'),
                  trailing: Icon(Icons.circle, size: 10, color: c.online ? p.ok : p.mute),
                ),
                const Divider(),
                ListTile(
                  leading: Icon(platformIcon(c.platform)),
                  title: Text(cfg.deviceName),
                  subtitle: const Text('本机'),
                ),
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
                AppSwitchTile(
                  icon: const Icon(Icons.blur_on_outlined),
                  title: const Text('液态玻璃'),
                  value: c.appearance.liquidGlass,
                  onChanged: _changingAppearance ? null : _toggleGlass,
                ),
                if (c.appearance.liquidGlass) ...[
                  const Divider(),
                  GlassTransparencyControl(
                    value: c.appearance.glassOpacity,
                    onChanged: c.setGlassOpacity,
                    onPreview: c.previewGlassOpacity,
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
                  subtitle: const Text('锁屏或离开 App 超过 5分钟后，需输入 App PIN'),
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
                  leading: const Icon(Icons.password_outlined),
                  title: const Text('修改登录密码'),
                  onTap: _changePassword,
                ),
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
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage())),
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
          if (!AppScope.isSimulated(context)) ...[
            const SectionTitle('开发者选项'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.developer_mode),
                title: const Text('页面调试'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openPageDebug,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
