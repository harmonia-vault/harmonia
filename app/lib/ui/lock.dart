// App 锁页面、敏感操作前的身份确认，以及 PIN 输入框和对话框。
// 验证通过 = 用生物识别或 App PIN 解开了本机数据密钥（docs/protocol.md 2.5）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/identity.dart';
import '../core/keyring.dart';
import 'theme.dart';
import 'app_scope.dart';
import 'glass_overlays.dart';
import 'widgets.dart';

String bioInvalidatedText(Identity identity) => '手机${identity.bio('有变化')}，${identity.bio('解锁')}已关闭，可以在设置中重新开启';

/// 等当前页面真正显示到屏幕上。弹系统验证之前调用：iOS 在面容 ID 出现时会暂停 App 的绘制，
/// 弹得太早，屏幕会停在页面画出来之前的那一帧，看起来是空白。
Future<void> pagePainted() async {
  for (var i = 0; i < 2; i++) {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(const Duration(milliseconds: 120));
}

IconData bioIcon(Identity identity) => identity.bioIsFace ? Icons.face_unlock_outlined : Icons.fingerprint;

/// 敏感操作前确认身份：开启了生物识别时先用它，取消或失败时改输 PIN。返回解开的本机数据密钥。
Future<Uint8List?> verifyIdentity(BuildContext context, String reason) async {
  final identity = AppScope.of(context).identity;
  final key = await identity.unlockWithBio(reason);
  if (key != null) return key;
  if (!context.mounted) return null;
  if (identity.bioInvalidated) {
    identity.bioInvalidated = false;
    toast(context, bioInvalidatedText(identity));
  }
  return showAppDialog<Uint8List>(
    context: context,
    useRootNavigator: false,
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
  const PinField({
    super.key,
    required this.controller,
    this.label,
    this.helper,
    this.error,
    this.autofocus = false,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String? label, helper, error;
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
    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(Keyring.maxPin)],
    decoration: InputDecoration(labelText: label, helperText: helper, errorText: error),
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
    final r = await AppScope.of(context).identity.keyring.unlock(_pin.text);
    if (!mounted) return;
    if (r.ok) return Navigator.pop(context, r.key);
    _pin.clear();
    setState(() {
      _busy = false;
      _error = pinErrorText(r);
    });
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: const Text('输入 App PIN'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.reason),
        const SizedBox(height: Space.md),
        PinField(controller: _pin, autofocus: true, error: _error, onSubmitted: (_) => _submit()),
      ],
    ),
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
  return showAppDialog<String>(
    context: context,
    useRootNavigator: false,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AppAlertDialog(
        title: const Text('设置新的 App PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PinField(controller: a, autofocus: true, label: '新 PIN', helper: '${Keyring.minPin}–${Keyring.maxPin} 位数字'),
            const SizedBox(height: Space.lg),
            PinField(controller: b, label: '再次输入', error: error),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final e = newPinError(a.text, b.text);
              if (e != null) return setState(() => error = e);
              Navigator.pop(c, a.text);
            },
            child: const Text('保存'),
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
  bool _ready = false, _autoAttempted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.c.addListener(_onController);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    widget.c.removeListener(_onController);
    _pin.dispose();
    super.dispose();
  }

  void _onController() {
    if (!widget.c.foreground) _autoAttempted = false;
    _autoUnlock();
  }

  Future<void> _start() async {
    final bio = await widget.c.identity.bioEnabled();
    if (!mounted) return;
    setState(() {
      _bio = bio;
      _ready = true;
    });
    await _autoUnlock();
  }

  Future<void> _autoUnlock() async {
    if (!_ready ||
        !_bio ||
        _busy ||
        _autoAttempted ||
        !widget.c.foreground ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive) {
      return;
    }
    _autoAttempted = true;
    await pagePainted();
    if (mounted && widget.c.foreground) await _useBio();
  }

  bool _acceptResult(int generation, Uint8List? key) {
    if (mounted && widget.c.foreground && generation == widget.c.lockGeneration) return true;
    key?.fillRange(0, key.length, 0);
    if (mounted) setState(() => _busy = false);
    return false;
  }

  Future<void> _useBio() async {
    if (_busy || !widget.c.foreground) return;
    final generation = widget.c.lockGeneration;
    setState(() => _busy = true);
    final key = await widget.c.identity.unlockWithBio('解锁 Harmonia');
    if (!_acceptResult(generation, key)) return;
    if (key != null) return _done(key);
    final bio = await widget.c.identity.bioEnabled();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _bio = bio;
    });
  }

  Future<void> _submit() async {
    if (_pin.text.isEmpty || _busy || !widget.c.foreground) return;
    final generation = widget.c.lockGeneration;
    setState(() => _busy = true);
    final r = await widget.c.identity.keyring.unlock(_pin.text);
    if (!_acceptResult(generation, r.key)) return;
    if (r.ok) return _done(r.key!);
    _pin.clear();
    setState(() {
      _busy = false;
      _error = pinErrorText(r);
    });
  }

  Future<void> _done(Uint8List key) async {
    if (widget.c.identity.bioInvalidated) {
      widget.c.identity.bioInvalidated = false;
      toast(context, bioInvalidatedText(widget.c.identity));
    }
    try {
      await widget.c.unlock(key);
      if (mounted && widget.c.stage == Stage.locked) setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '本机数据无法读取。请选择“忘记 PIN”清除本机数据后重新登录';
      });
    }
  }

  Future<void> _forgot() async {
    final ok = await confirmDialog(
      context,
      title: '清除本机数据？',
      body:
          '${_bio ? '如果只是忘记了 PIN，可以先用${widget.c.identity.bio('解锁')}，再到“设置”中修改 PIN。\n' : ''}'
          '清除后，账号和云端数据不受影响，但这台手机需要重新登录，并由管理设备批准或用恢复码恢复。\n'
          '这台手机原来的设备记录需要在管理设备上移除。',
      ok: '清除本机数据',
      danger: true,
    );
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                    icon: Icon(bioIcon(widget.c.identity)),
                    label: Text('用${widget.c.identity.bio('解锁')}'),
                  ),
                ],
                const SizedBox(height: Space.md),
                TextButton(onPressed: _busy ? null : _forgot, child: const Text('忘记 PIN？')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
