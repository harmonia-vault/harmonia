// App 锁页面、敏感操作前的身份确认，以及 PIN 输入框和对话框。
// 验证通过 = 用指纹或 App PIN 解开了本机数据密钥（docs/protocol.md 2.5）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/identity.dart';
import '../core/keyring.dart';
import 'theme.dart';
import 'widgets.dart';

late Identity identity;

const bioInvalidatedText = '手机指纹有变化，指纹解锁已关闭，可以在设置中重新开启';

/// 敏感操作前确认身份：开启了指纹时先用指纹，取消或失败时改输 PIN。返回解开的本机数据密钥。
Future<Uint8List?> verifyIdentity(BuildContext context, String reason) async {
  final key = await identity.unlockWithBio(reason);
  if (key != null) return key;
  if (!context.mounted) return null;
  if (identity.bioInvalidated) {
    identity.bioInvalidated = false;
    toast(context, bioInvalidatedText);
  }
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PinDialog(reason: reason),
  );
}

Future<bool> confirmIdentity(BuildContext context, String reason) async =>
    await verifyIdentity(context, reason) != null;

String pinErrorText(PinResult r) {
  if (r.waitSeconds <= 0) return 'PIN 不对，还可以再试 ${r.remaining} 次';
  final wait = r.waitSeconds >= 60 ? '${(r.waitSeconds + 59) ~/ 60} 分钟' : '${r.waitSeconds} 秒';
  return '输错次数过多，请 $wait后再试';
}

class PinField extends StatelessWidget {
  const PinField(
      {super.key, required this.controller, this.label, this.error, this.autofocus = false, this.onSubmitted});
  final TextEditingController controller;
  final String? label, error;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
        autofillHints: null,
        controller: controller,
        autofocus: autofocus,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(Keyring.maxPin),
        ],
        decoration: InputDecoration(labelText: label, errorText: error),
        onSubmitted: onSubmitted,
      );
}

/// 检查两次输入的新 PIN，返回错误提示；没有问题时返回 null。
String? newPinError(String a, String b) {
  if (!Keyring.validPin(a)) return 'PIN 需要 ${Keyring.minPin}–${Keyring.maxPin} 位数字';
  if (a != b) return '两次输入不一致';
  return null;
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
    if (_pin.text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final r = await identity.keyring.unlock(_pin.text);
    if (!mounted) return;
    if (r.ok) return Navigator.pop(context, r.key);
    _pin.clear();
    setState(() {
      _busy = false;
      _error = pinErrorText(r);
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('输入 App PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.reason),
          const SizedBox(height: Space.md),
          PinField(controller: _pin, autofocus: true, error: _error, onSubmitted: (_) => _submit()),
        ]),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? '验证中…' : '确认')),
        ],
      );
}

/// 输入两次新 PIN。返回新 PIN；取消时返回 null。
Future<String?> askNewPin(BuildContext context) {
  final a = TextEditingController(), b = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('设置新的 App PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          PinField(controller: a, autofocus: true, label: '新 PIN（${Keyring.minPin}–${Keyring.maxPin} 位数字）'),
          const SizedBox(height: Space.sm),
          PinField(controller: b, label: '再次输入', error: error),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final e = newPinError(a.text, b.text);
              if (e != null) return setState(() => error = e);
              Navigator.pop(c, a.text);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

class LockPage extends StatefulWidget {
  const LockPage({super.key, required this.c});
  final AppController c;
  @override
  State<LockPage> createState() => _LockPageState();
}

class _LockPageState extends State<LockPage> {
  final _pin = TextEditingController();
  bool _busy = false;
  bool _bio = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final bio = await identity.bioEnabled();
    if (!mounted) return;
    setState(() => _bio = bio);
    if (bio) await _useBio();
  }

  Future<void> _useBio() async {
    if (_busy) return;
    setState(() => _busy = true);
    final key = await identity.unlockWithBio('解锁 Harmonia');
    if (!mounted) return;
    if (key != null) return _done(key);
    final bio = await identity.bioEnabled();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _bio = bio;
    });
  }

  Future<void> _submit() async {
    if (_pin.text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final r = await identity.keyring.unlock(_pin.text);
    if (!mounted) return;
    if (r.ok) return _done(r.key!);
    _pin.clear();
    setState(() {
      _busy = false;
      _error = pinErrorText(r);
    });
  }

  Future<void> _done(Uint8List key) async {
    if (identity.bioInvalidated) {
      identity.bioInvalidated = false;
      toast(context, bioInvalidatedText);
    }
    try {
      await widget.c.unlock(key);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '本机数据无法读取。请选择“忘记 PIN”清除本机数据后重新登录';
      });
    }
  }

  Future<void> _forgot() async {
    final ok = await confirmDialog(context,
        title: '清除本机数据？',
        body: '${_bio ? '如果只是忘记了 PIN，可以先用指纹解锁，再到“设置”中修改 PIN。\n\n' : ''}'
            '清除后，账号和云端数据不受影响，但这台手机需要重新登录，并通过另一台手机批准或用恢复码恢复。'
            '这台手机原来的设备记录需要在其他手机上移除。',
        ok: '清除本机数据',
        danger: true);
    if (!ok || !mounted) return;
    await runBusy(context, widget.c.forgetDevice);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline_rounded, size: 56, color: p.ink),
              const SizedBox(height: Space.lg),
              Text('Harmonia 已锁定', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Space.sm),
              Text(widget.c.prefs.email ?? '', style: TextStyle(color: p.mute)),
              const SizedBox(height: Space.xxl),
              PinField(
                controller: _pin,
                label: 'App PIN',
                error: _error,
                autofocus: !_bio,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: Space.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? '正在解锁…' : '解锁')),
              ),
              if (_bio) ...[
                const SizedBox(height: Space.sm),
                TextButton.icon(
                  onPressed: _busy ? null : _useBio,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('用指纹解锁'),
                ),
              ],
              const SizedBox(height: Space.md),
              TextButton(onPressed: _busy ? null : _forgot, child: const Text('忘记 PIN？')),
            ]),
          ),
        ),
      ),
    );
  }
}
