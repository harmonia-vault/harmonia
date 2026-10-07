// App 锁页面、敏感操作前的身份确认，以及 App PIN 的设置。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/identity.dart';
import 'theme.dart';
import 'widgets.dart';

late Identity identity;

/// 敏感操作前确认身份。设备既没有锁屏也没有 PIN 时直接通过。
Future<bool> confirmIdentity(BuildContext context, String reason) async {
  switch (await identity.method()) {
    case IdentityMethod.system:
      final r = await identity.system(reason);
      if (r != null) return r;
      if (!await identity.hasPin()) return true;
      if (!context.mounted) return false;
      return enterPin(context, reason);
    case IdentityMethod.pin:
      if (!context.mounted) return false;
      return enterPin(context, reason);
    case IdentityMethod.none:
      return true;
  }
}

Future<bool> enterPin(BuildContext context, String reason) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PinDialog(reason: reason),
  );
  return ok ?? false;
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.reason});
  final String reason;
  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    final r = await identity.checkPin(_pin.text);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, true);
      return;
    }
    _pin.clear();
    setState(() {
      _busy = false;
      _error = r.waitSeconds > 0 ? '输错次数过多，请 ${r.waitSeconds} 秒后再试' : 'PIN 不对，还可以再试 ${r.remaining} 次';
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('输入 App PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.reason),
          const SizedBox(height: Space.md),
          TextField(
            autofillHints: null,
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(errorText: _error, hintText: '至少 6 位数字'),
            onSubmitted: (_) => _submit(),
          ),
        ]),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: _busy ? null : _submit, child: const Text('确认')),
        ],
      );
}

/// 设置 App PIN（设备没有锁屏时使用）。返回是否设置成功。
Future<bool> setupPin(BuildContext context) async {
  final a = TextEditingController(), b = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('设置 App PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('这台手机没有设置锁屏密码。设置一个至少 6 位的数字 PIN，用来打开 Harmonia。忘记 PIN 后只能清除本机数据并重新接入。'),
          const SizedBox(height: Space.md),
          TextField(
              autofillHints: null,
              controller: a,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'PIN')),
          const SizedBox(height: Space.sm),
          TextField(
              autofillHints: null,
              controller: b,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: '再次输入', errorText: error)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (a.text.length < 6) {
                setState(() => error = 'PIN 至少 6 位');
              } else if (a.text != b.text) {
                setState(() => error = '两次输入不一致');
              } else {
                Navigator.pop(c, true);
              }
            },
            child: const Text('设置'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return false;
  return runBusy(context, () => identity.setPin(a.text), done: '已设置 App PIN');
}

class LockPage extends StatefulWidget {
  const LockPage({super.key, required this.c});
  final AppController c;
  @override
  State<LockPage> createState() => _LockPageState();
}

class _LockPageState extends State<LockPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await confirmIdentity(context, '验证身份以打开 Harmonia');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.c.unlocked();
  }

  Future<void> _forgot() async {
    final ok = await confirmDialog(context,
        title: '清除本机数据？',
        body: '将清除这台手机上的 Harmonia 数据，账号和云端数据不受影响。之后需要重新登录，并通过另一台手机批准或恢复码恢复。',
        ok: '清除',
        danger: true);
    if (!ok || !mounted) return;
    await identity.clearPin();
    await widget.c.vault.wipe();
    widget.c.notice = '已清除本机数据，请重新登录。';
    widget.c.cancelToSignIn();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline_rounded, size: 56, color: p.ink),
              const SizedBox(height: Space.lg),
              Text('Harmonia 已锁定', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Space.sm),
              Text(widget.c.vault.config?.email ?? '', style: TextStyle(color: p.mute)),
              const SizedBox(height: Space.xxl),
              FilledButton.icon(
                onPressed: _busy ? null : _unlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text('解锁'),
              ),
              const SizedBox(height: Space.md),
              TextButton(onPressed: _forgot, child: const Text('无法解锁？')),
            ]),
          ),
        ),
      ),
    );
  }
}
