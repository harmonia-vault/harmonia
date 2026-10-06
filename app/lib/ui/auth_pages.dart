// 未接入账号时的页面：连接服务器、登录、注册、验证邮箱、找回密码、重置账号。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/api.dart';
import 'recovery_pages.dart';
import 'theme.dart';
import 'widgets.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.c});
  final AppController c;
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _url = TextEditingController();

  Future<void> _connect() async {
    if (_url.text.trim().isEmpty) {
      toast(context, '请输入服务器地址');
      return;
    }
    await runBusy(context, () => widget.c.connect(_url.text));
  }

  @override
  Widget build(BuildContext context) => AuthScaffold(
        title: '连接服务器',
        subtitle: '输入你部署的 Harmonia 服务地址。环境变量在手机上加密后才会上传，服务器只保存密文。',
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'vault.example.com',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: Space.xl),
          FilledButton(onPressed: _connect, child: const Text('连接')),
        ],
      );
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.c});
  final AppController c;
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.c.prefs.email ?? '');
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _register = false;
  bool _show = false;

  AppController get c => widget.c;

  @override
  void initState() {
    super.initState();
    // 实例上还没有任何账号时，默认显示注册。
    final inst = c.instance;
    if (inst != null && inst.registrationOpen && c.prefs.email == null) _register = true;
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final email = _email.text.trim(), password = _password.text;
    await runBusy(context, () async {
      try {
        if (_register) {
          await c.register(email, password);
        } else {
          await c.login(email, password);
        }
      } on ApiException catch (e) {
        if (e.code == 'email_unverified') {
          await c.startVerification(email, password);
          return;
        }
        rethrow;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final inst = c.instance;
    final canRegister = inst?.registrationOpen ?? true;
    return AuthScaffold(
      title: _register ? '创建账号' : '登录',
      subtitle: _register ? '用邮箱注册一个 Harmonia 账号。' : '登录你的 Harmonia 账号。',
      children: [
        if (c.notice != null) ...[Banner2(c.notice!, warn: true), const SizedBox(height: Space.lg)],
        Row(children: [
          Icon(Icons.dns_outlined, size: 16, color: context.palette.mute),
          const SizedBox(width: Space.sm),
          Expanded(child: Text(c.prefs.server ?? '', style: TextStyle(color: context.palette.mute))),
          TextButton(onPressed: c.changeServer, child: const Text('更换')),
        ]),
        const SizedBox(height: Space.md),
        Form(
          key: _form,
          child: Column(children: [
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: '邮箱'),
              validator: validateEmail,
            ),
            const SizedBox(height: Space.md),
            TextFormField(
              controller: _password,
              obscureText: !_show,
              autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
              decoration: InputDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
              validator: _register ? validatePassword : (v) => (v ?? '').isEmpty ? '请输入密码' : null,
            ),
            if (_register) ...[
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _confirm,
                obscureText: !_show,
                decoration: const InputDecoration(labelText: '再次输入密码'),
                validator: (v) => v != _password.text ? '两次输入的密码不一致' : null,
              ),
              const SizedBox(height: Space.md),
              Banner2(
                inst?.emailVerification ?? true
                    ? '注册后需要输入邮件中的验证码。密码只用于登录，不能用来解密数据；数据由手机上的密钥和恢复码保护。'
                    : '密码只用于登录，不能用来解密数据；数据由手机上的密钥和恢复码保护。',
              ),
            ],
          ]),
        ),
        const SizedBox(height: Space.xl),
        FilledButton(onPressed: _submit, child: Text(_register ? '注册' : '登录')),
        const SizedBox(height: Space.md),
        if (_register)
          OutlinedButton(onPressed: () => setState(() => _register = false), child: const Text('已有账号？登录'))
        else if (canRegister)
          OutlinedButton(onPressed: () => setState(() => _register = true), child: const Text('注册新账号')),
        if (!_register) ...[
          const SizedBox(height: Space.lg),
          Wrap(alignment: WrapAlignment.center, spacing: Space.sm, children: [
            TextButton(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => ForgotPasswordPage(c: c, email: _email.text))),
              child: const Text('忘记密码'),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => RecoverPage(c: c, email: _email.text))),
              child: const Text('用恢复码恢复'),
            ),
            TextButton(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => AccountResetPage(c: c, email: _email.text))),
              child: const Text('重置账号'),
            ),
          ]),
        ],
      ],
    );
  }
}

class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({super.key, required this.c});
  final AppController c;
  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  final _code = TextEditingController();

  @override
  Widget build(BuildContext context) => AuthScaffold(
        title: '验证邮箱',
        subtitle: '验证码已发送到 ${widget.c.pendingEmail}，15 分钟内有效。',
        onBack: widget.c.cancelToSignIn,
        children: [
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            autofillHints: const [AutofillHints.oneTimeCode],
            maxLength: 9,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 22, letterSpacing: 3),
            decoration: const InputDecoration(labelText: '8 位验证码', counterText: ''),
          ),
          const SizedBox(height: Space.xl),
          FilledButton(
            onPressed: () => runBusy(context, () => widget.c.verifyEmail(_code.text)),
            child: const Text('验证'),
          ),
          const SizedBox(height: Space.md),
          TextButton(
            onPressed: () => runBusy(context, widget.c.resendVerification, done: '已重新发送验证码'),
            child: const Text('没有收到？重新发送'),
          ),
        ],
      );
}

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key, required this.c, required this.email});
  final AppController c;
  final String email;
  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return AuthScaffold(
      title: '找回密码',
      subtitle: '通过邮件验证码设置新密码。保险库中的数据和已授权的设备不受影响。',
      onBack: () => Navigator.pop(context),
      children: [
        Form(
          key: _form,
          child: Column(children: [
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: '邮箱'),
              validator: validateEmail,
              enabled: !_sent,
            ),
            if (_sent) ...[
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: '邮件中的 8 位验证码'),
                validator: (v) => (v ?? '').trim().length < 8 ? '请输入 8 位验证码' : null,
              ),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码'),
                validator: validatePassword,
              ),
            ],
          ]),
        ),
        const SizedBox(height: Space.xl),
        if (!_sent)
          FilledButton(
            onPressed: () async {
              if (!_form.currentState!.validate()) return;
              final ok = await runBusy(context, () => c.account.requestPasswordReset(c.server, _email.text),
                  done: '验证码已发送');
              if (ok) setState(() => _sent = true);
            },
            child: const Text('发送验证码'),
          )
        else
          FilledButton(
            onPressed: () async {
              if (!_form.currentState!.validate()) return;
              final ok = await runBusy(context,
                  () => c.account.completePasswordReset(c.server, _email.text, _code.text, _password.text),
                  done: '密码已更新，请用新密码登录');
              if (ok && context.mounted) Navigator.pop(context);
            },
            child: const Text('设置新密码'),
          ),
      ],
    );
  }
}

class AccountResetPage extends StatefulWidget {
  const AccountResetPage({super.key, required this.c, required this.email});
  final AppController c;
  final String email;
  @override
  State<AccountResetPage> createState() => _AccountResetPageState();
}

class _AccountResetPageState extends State<AccountResetPage> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _confirm = TextEditingController();
  bool _sent = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return AuthScaffold(
      title: '重置账号',
      subtitle: '只有在密码、恢复码和所有手机都丢失时才需要重置。',
      onBack: () => Navigator.pop(context),
      children: [
        const Banner2('重置会永久删除这个账号的全部环境、变量和已授权设备，无法撤销，也无法找回数据。之后可以用同一个邮箱重新注册。',
            warn: true),
        const SizedBox(height: Space.lg),
        TextField(
          controller: _email,
          enabled: !_sent,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: '邮箱'),
        ),
        if (_sent) ...[
          const SizedBox(height: Space.md),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: '邮件中的 8 位验证码'),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _confirm,
            decoration: const InputDecoration(labelText: '输入“删除全部数据”以确认'),
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: Space.xl),
        if (!_sent)
          FilledButton(
            onPressed: () async {
              final ok = await runBusy(context, () => c.account.requestAccountReset(c.server, _email.text),
                  done: '验证码已发送');
              if (ok) setState(() => _sent = true);
            },
            child: const Text('发送验证码'),
          )
        else
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: _confirm.text.trim() != '删除全部数据'
                ? null
                : () async {
                    final ok = await runBusy(
                        context, () => c.account.completeAccountReset(c.server, _email.text, _code.text),
                        done: '账号已重置，可以重新注册');
                    if (ok && context.mounted) Navigator.pop(context);
                  },
            child: const Text('永久删除并重置'),
          ),
      ],
    );
  }
}
