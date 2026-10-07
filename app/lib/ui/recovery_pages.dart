// 首次初始化、作为新手机配对、用恢复码恢复、更换恢复码。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/controller.dart';
import '../core/crypto.dart';
import 'lock.dart';
import 'recovery_actions.dart';
import 'theme.dart';
import 'widgets.dart';

/// 两步确认恢复码：先展示让用户抄写，再要求完整重新输入。
class RecoveryCodeConfirm extends StatefulWidget {
  const RecoveryCodeConfirm({super.key, required this.code, required this.onConfirmed, this.extra});
  final Uint8List code;
  final Future<void> Function() onConfirmed;
  final Widget? extra;
  @override
  State<RecoveryCodeConfirm> createState() => _RecoveryCodeConfirmState();
}

class _RecoveryCodeConfirmState extends State<RecoveryCodeConfirm> {
  bool _written = false;
  bool _reenter = false;
  final _input = TextEditingController();
  String? _error;

  @override
  Widget build(BuildContext context) {
    final formatted = formatRecoveryCode(widget.code);
    if (!_reenter) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CodeBox(formatted, copyable: false),
        const SizedBox(height: Space.md),
        CopyRecoveryCode(code: widget.code),
        const SizedBox(height: Space.lg),
        const Banner2(
          '请把恢复码抄在纸上或存进密码管理器，妥善保管；提交成功后还可以下载 PDF 打印。丢失所有手机时，只能用它找回数据；它不会再次显示，服务器也没有副本。',
          warn: true,
        ),
        const SizedBox(height: Space.md),
        Card(
          child: CheckboxListTile(
            value: _written,
            onChanged: (v) => setState(() => _written = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('我已经妥善保存了恢复码'),
          ),
        ),
        const SizedBox(height: Space.lg),
        FilledButton(
          onPressed: _written ? () => setState(() => _reenter = true) : null,
          child: const Text('下一步'),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('为确认已经保存，请完整输入一遍恢复码：'),
      const SizedBox(height: Space.md),
      TextField(
        autofillHints: null,
        controller: _input,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 17),
        decoration: InputDecoration(labelText: '恢复码', errorText: _error),
      ),
      if (widget.extra != null) ...[const SizedBox(height: Space.md), widget.extra!],
      const SizedBox(height: Space.xl),
      FilledButton(
        onPressed: () async {
          final parsed = parseRecoveryCode(_input.text);
          if (parsed == null || b64(parsed) != b64(widget.code)) {
            setState(() => _error = '与刚才显示的恢复码不一致，请检查');
            return;
          }
          setState(() => _error = null);
          await widget.onConfirmed();
        },
        child: const Text('确认'),
      ),
      TextButton(onPressed: () => setState(() => _reenter = false), child: const Text('再看一次恢复码')),
    ]);
  }
}

class SetupPage extends StatelessWidget {
  const SetupPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => c.setupCompleted
      ? RecoveryDoneView(
          c: c,
          code: c.setupDraft!.code,
          title: '恢复码已生效',
          subtitle: '账号已经创建，刚才保存的恢复码从现在起可以使用。',
          onDone: c.finishSetup,
        )
      : AuthScaffold(
          title: '保存恢复码',
          subtitle: '这是账号的第一台手机。Harmonia 会在本机生成加密密钥，并给你一个恢复码。',
          onBack: c.cancelToSignIn,
          children: [
            RecoveryCodeConfirm(
              code: c.setupDraft!.code,
              onConfirmed: () => runBusy(context, c.completeSetup),
            ),
          ],
        );
}

class UnpairedPage extends StatelessWidget {
  const UnpairedPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => AuthScaffold(
        title: '这台手机还没有授权',
        subtitle: '账号 ${c.session?.email ?? ''} 已在其他手机上使用。请选择一种方式让这台手机获得访问权限。',
        onBack: c.cancelToSignIn,
        children: [
          if (c.notice != null) ...[Banner2(c.notice!, warn: true), const SizedBox(height: Space.lg)],
          _Choice(
            icon: Icons.phonelink_lock_outlined,
            title: '让另一台手机批准',
            body: '在已授权的手机上扫描这台手机显示的二维码。',
            onTap: () => runBusy(context, c.startPairing),
          ),
          const SizedBox(height: Space.md),
          _Choice(
            icon: Icons.key_outlined,
            title: '用恢复码恢复',
            body: '旧手机已经丢失或无法使用时选择。恢复后需要更换新的恢复码。',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => RecoverPage(c: c, email: c.session?.email ?? ''))),
          ),
        ],
      );
}

class _Choice extends StatelessWidget {
  const _Choice({required this.icon, required this.title, required this.body, required this.onTap});
  final IconData icon;
  final String title, body;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Row(children: [
              Icon(icon, size: 30),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Space.xs),
                  Text(body, style: TextStyle(color: context.palette.mute, height: 1.4)),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
      );
}

class PairingWaitPage extends StatelessWidget {
  const PairingWaitPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final p = c.pendingPairing!;
    final palette = context.palette;
    return AuthScaffold(
      title: '等待批准',
      subtitle: '在已授权的手机上打开 Harmonia，进入“设备 → 添加设备”，扫描下面的二维码。',
      onBack: c.cancelPairing,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: palette.ink, width: 1.4),
            ),
            child: QrImageView(data: p.qr, size: 220, backgroundColor: Colors.white),
          ),
        ),
        const SizedBox(height: Space.xl),
        const Text('无法扫码时，在另一台手机上手动输入核对码：'),
        const SizedBox(height: Space.sm),
        CodeBox(p.code, copyable: false),
        const SizedBox(height: Space.lg),
        Row(children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              '正在等待批准，请求在 ${p.expiresAt.hour.toString().padLeft(2, '0')}:${p.expiresAt.minute.toString().padLeft(2, '0')} 前有效。',
              style: TextStyle(color: palette.mute),
            ),
          ),
        ]),
      ],
    );
  }
}

class RecoverPage extends StatefulWidget {
  const RecoverPage({super.key, required this.c, required this.email});
  final AppController c;
  final String email;
  @override
  State<RecoverPage> createState() => _RecoverPageState();
}

class _RecoverPageState extends State<RecoverPage> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();

  @override
  Widget build(BuildContext context) => AuthScaffold(
        title: '用恢复码恢复',
        subtitle: '输入注册邮箱和恢复码。恢复后这台手机会成为管理手机，并需要立即更换新的恢复码。',
        onBack: () => Navigator.pop(context),
        children: [
          TextField(
            autofillHints: const [AutofillHints.email],
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: '邮箱'),
          ),
          const SizedBox(height: Space.md),
          TextField(
            autofillHints: null,
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            maxLines: 2,
            minLines: 1,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 17),
            decoration: const InputDecoration(labelText: '恢复码', hintText: 'XXXX-XXXX-XXXX-…'),
          ),
          const SizedBox(height: Space.xl),
          FilledButton(
            onPressed: () async {
              final nav = Navigator.of(context);
              final ok = await runBusy(context, () => widget.c.recover(_email.text, _code.text));
              if (ok) nav.popUntil((r) => r.isFirst);
            },
            child: const Text('恢复'),
          ),
        ],
      );
}

/// 更换恢复码。恢复后强制进入；也可以在设置中主动进入（push 打开）。
class RotationPage extends StatefulWidget {
  const RotationPage({super.key, required this.c, this.forced = false});
  final AppController c;
  final bool forced;
  @override
  State<RotationPage> createState() => _RotationPageState();
}

class _RotationPageState extends State<RotationPage> {
  late final Uint8List _code = widget.c.newRecoveryCode();
  final _password = TextEditingController();
  bool _changePassword = false;
  bool _started = false;
  bool _done = false;

  Future<void> _submit() async {
    final pw = _changePassword ? _password.text : null;
    if (pw != null && validatePassword(pw) != null) {
      toast(context, '新密码至少 8 位');
      return;
    }
    if (!widget.forced && !await confirmIdentity(context, '验证身份以更换恢复码')) return;
    if (!mounted) return;
    final ok = await runBusy(context, () => widget.c.rotateRecovery(_code, newPassword: pw));
    if (ok && mounted) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) => _done
      ? RecoveryDoneView(
          c: widget.c,
          code: _code,
          title: '恢复码已更换',
          subtitle: '新恢复码已经生效，旧恢复码已作废。',
          onDone: widget.forced ? widget.c.finishRotation : () => Navigator.pop(context),
        )
      : _started
          ? _codeStep()
          : _introStep();

  /// 开始前的说明：新恢复码在核对提交前不会生效。
  Widget _introStep() => AuthScaffold(
        title: '更换恢复码',
        subtitle: widget.forced ? '恢复还差最后一步：换一个新的恢复码。保存并核对新恢复码后，恢复才算完成。' : '开始前请先了解：',
        onBack: widget.forced ? null : () => Navigator.pop(context),
        children: [
          const _Point(Icons.edit_note_outlined, '准备好纸笔或密码管理器。新恢复码只显示这一次，服务器也没有副本。'),
          const _Point(Icons.fact_check_outlined, '抄好后需要完整输入一遍，核对无误才能提交。'),
          const _Point(Icons.key_outlined, '提交成功后旧恢复码才作废；在此之前旧恢复码仍然有效。'),
          if (widget.forced) ...[
            const _Point(Icons.block_outlined, '完成前无法管理设备或修改数据。'),
            const _Point(Icons.replay_outlined, '中途退出也没关系，下次打开 Harmonia 会回到这里继续。'),
            const _Point(Icons.password_outlined, '如果忘记了原来的登录密码，可以在这一步同时设置新密码。'),
          ] else ...[
            const _Point(Icons.undo_outlined, '提交前随时可以返回，不会有任何改变。'),
            const _Point(Icons.fingerprint, '提交时需要再验证一次身份。'),
          ],
          const SizedBox(height: Space.lg),
          FilledButton(
            onPressed: () => setState(() => _started = true),
            child: const Text('生成新恢复码'),
          ),
        ],
      );

  // 返回键和左上角箭头都回到说明页，而不是直接离开。
  Widget _codeStep() => PopScope(
        canPop: false,
        child: AuthScaffold(
          title: '保存新恢复码',
          subtitle: '新恢复码还没有生效，旧恢复码仍然可用。保存并核对后提交，才会替换旧恢复码。',
          onBack: () => setState(() => _started = false),
          children: [
            RecoveryCodeConfirm(
              code: _code,
              onConfirmed: _submit,
              extra: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Card(
                  child: SwitchListTile(
                    value: _changePassword,
                    onChanged: (v) => setState(() => _changePassword = v),
                    title: const Text('同时设置新的登录密码'),
                    subtitle: widget.forced ? const Text('如果忘记了原来的密码，可以在这里重新设置') : null,
                  ),
                ),
                if (_changePassword) ...[
                  const SizedBox(height: Space.md),
                  TextField(
                    autofillHints: const [AutofillHints.newPassword],
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
                  ),
                ],
              ]),
            ),
          ],
        ),
      );
}

class _Point extends StatelessWidget {
  const _Point(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Space.lg),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 24, color: context.palette.mute),
          const SizedBox(width: Space.md),
          Expanded(child: Text(text, style: const TextStyle(height: 1.5))),
        ]),
      );
}
