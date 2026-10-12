// 登录后设置 App PIN；手机支持指纹（iOS 上是面容 ID / 触控 ID）时接着直接开启，可以跳过。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/keyring.dart';
import 'lock.dart';
import 'theme.dart';
import 'widgets.dart';

class SetPinPage extends StatefulWidget {
  const SetPinPage({super.key, required this.c});
  final AppController c;
  @override
  State<SetPinPage> createState() => _SetPinPageState();
}

class _SetPinPageState extends State<SetPinPage> {
  final _a = TextEditingController(), _b = TextEditingController();
  String? _error;
  bool _offerBio = false;

  AppController get c => widget.c;

  Future<void> _submit() async {
    final e = newPinError(_a.text, _b.text);
    setState(() => _error = e);
    if (e != null) return;
    if (!await runBusy(context, () => c.setPin(_a.text))) return;
    if (!await c.identity.bioAvailable()) return _finish();
    if (!mounted) return;
    setState(() => _offerBio = true);
    // 不先询问，直接弹出系统验证；取消或失败时留在这一页，可以重试或跳过。
    await pagePainted();
    if (mounted) await _enableBio();
  }

  Future<void> _enableBio() async {
    var enabled = false;
    final ok = await runBusy(
        context, () async => enabled = await c.identity.enableBio(c.vault.localKey!, cancel: '跳过'));
    if (!ok || !enabled || !mounted) return;
    toast(context, '已开启${c.identity.bio('解锁')}');
    await _finish();
  }

  Future<void> _finish() async {
    if (mounted) await runBusy(context, c.pinDone);
  }

  @override
  Widget build(BuildContext context) => _offerBio
      ? AuthScaffold(
          title: '开启${c.identity.bio('解锁')}',
          subtitle: '验证通过后，可以用${c.identity.bio('代替')} App PIN 打开 Harmonia。',
          children: [
            Banner2('手机上的${c.identity.bio('有变化后')}，${c.identity.bio('解锁')}会自动关闭。\n用 PIN 解锁后，可以在设置中重新开启。'),
            const SizedBox(height: Space.xl),
            FilledButton.icon(
              onPressed: _enableBio,
              icon: Icon(bioIcon),
              label: Text('开启${c.identity.bio('解锁')}'),
            ),
            const SizedBox(height: Space.sm),
            TextButton(onPressed: _finish, child: const Text('跳过')),
          ],
        )
      : AuthScaffold(
          title: '设置 App PIN',
          subtitle: '每次打开 Harmonia 都需要输入 App PIN。\n'
              '这台手机上保存的密钥由它加密，与手机锁屏密码无关。',
          onBack: c.cancelToSignIn,
          children: [
            PinField(controller: _a, autofocus: true, label: 'App PIN（${Keyring.minPin}–${Keyring.maxPin} 位数字）'),
            const SizedBox(height: Space.md),
            PinField(controller: _b, label: '再次输入', error: _error, onSubmitted: (_) => _submit()),
            const SizedBox(height: Space.lg),
            Banner2('忘记 PIN 时，如果没有开启${c.identity.bio('解锁')}，只能清除本机数据并重新接入账号。', warn: true),
            const SizedBox(height: Space.xl),
            FilledButton(onPressed: _submit, child: const Text('下一步')),
          ],
        );
}
