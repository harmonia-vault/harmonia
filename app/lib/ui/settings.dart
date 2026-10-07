// 设置：账号、本机保护、密码与恢复码、更新、退出。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/updater.dart';
import 'lock.dart';
import 'recovery_pages.dart';
import 'theme.dart';
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

  AppController get c => widget.c;

  @override
  void initState() {
    super.initState();
    _loadBio();
  }

  Future<void> _loadBio() async {
    final available = await identity.bioAvailable();
    final enabled = await identity.bioEnabled();
    if (mounted) {
      setState(() {
        _bioAvailable = available;
        _bioEnabled = enabled;
      });
    }
  }

  Future<void> _toggleBio(bool v) async {
    final key = await verifyIdentity(context, v ? '验证身份以开启指纹解锁' : '验证身份以关闭指纹解锁');
    if (key == null || !mounted) return;
    if (v) {
      var enabled = false;
      if (await runBusy(context, () async => enabled = await identity.enableBio(key)) && enabled && mounted) {
        toast(context, '已开启指纹解锁');
      }
    } else {
      await identity.disableBio();
    }
    await _loadBio();
  }

  Future<void> _changePin() async {
    final key = await verifyIdentity(context, '验证身份以修改 App PIN');
    if (key == null || !mounted) return;
    final pin = await askNewPin(context);
    if (pin == null || !mounted) return;
    await runBusy(context, () => identity.keyring.changePin(key, pin), done: 'App PIN 已修改');
  }

  Future<void> _changePassword() async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改登录密码'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('登录密码只用于在新设备上登录，修改后已授权的设备不受影响。'),
          const SizedBox(height: Space.md),
          TextField(
              controller: a,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: '新密码（至少 8 位）')),
          const SizedBox(height: Space.sm),
          TextField(controller: b, obscureText: true, autofillHints: null, decoration: const InputDecoration(labelText: '再次输入')),
        ]),
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
    final picked = await showDialog<UpdateChannel>(
      context: context,
      builder: (ctx) => SimpleDialog(
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
            : '已切换到${picked.label}渠道');
  }

  Future<void> _logout() async {
    final last = c.vault.isLastManager;
    final ok = await confirmDialog(context,
        title: '退出登录？',
        body: last
            ? '这是账号里唯一的管理手机。退出后，只能用恢复码在新手机上找回账号。请确认恢复码还在。'
            : '这台手机将从账号中移除，并清除本机保存的数据。',
        ok: '退出',
        danger: true);
    if (!ok || !mounted) return;
    if (!await confirmIdentity(context, '验证身份以退出登录')) return;
    if (!mounted) return;
    await runBusy(context, () => c.logout(confirmLast: last));
  }

  @override
  Widget build(BuildContext context) {
    final cfg = c.vault.config!;
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xxl), children: [
        const SectionTitle('账号'),
        Card(
          child: Column(children: [
            ListTile(leading: const Icon(Icons.alternate_email), title: Text(cfg.email), subtitle: const Text('账号')),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(cfg.server),
              subtitle: Text(c.online ? '已连接' : '离线，显示的是上次同步的数据'),
              trailing: Icon(Icons.circle, size: 10, color: c.online ? p.ok : p.mute),
            ),
            const Divider(),
            ListTile(leading: const Icon(Icons.phone_android), title: Text(cfg.deviceName), subtitle: const Text('本机')),
          ]),
        ),
        const SectionTitle('安全'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('修改 App PIN'),
              subtitle: const Text('打开 App 或离开超过 5 分钟后，需要输入 App PIN'),
              onTap: _changePin,
            ),
            if (_bioAvailable || _bioEnabled) ...[
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.fingerprint),
                value: _bioEnabled,
                onChanged: _toggleBio,
                title: const Text('指纹解锁'),
                subtitle: const Text('可以用指纹代替 App PIN'),
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
          ]),
        ),
        const SectionTitle('关于'),
        Card(
          child: Column(children: [
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
          ]),
        ),
        const SizedBox(height: Space.xl),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: _logout,
          child: const Text('退出登录'),
        ),
      ]),
    );
  }
}
