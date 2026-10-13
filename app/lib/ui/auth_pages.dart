// 未接入账号时的页面：连接服务器、输入邮箱（注册或接入）、验证邮箱、重置账号。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/account.dart';
import 'recovery_pages.dart';
import 'scanner.dart';
import 'theme.dart';
import 'widgets.dart';
import 'app_scope.dart';

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

  Future<void> _scan() async {
    final server = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanServerPage()));
    if (server == null || !mounted) return;
    _url.text = server;
    await _connect();
  }

  @override
  Widget build(BuildContext context) => AuthScaffold(
    title: '连接服务器',
    subtitle: '输入你部署的 Harmonia 服务地址，或者扫描服务器首页上的二维码。\n环境变量在手机上加密后才会上传，服务器只保存密文。',
    children: [
      TextField(
        autofillHints: null,
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
      const SizedBox(height: Space.sm),
      OutlinedButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('扫码填写')),
    ],
  );
}

/// 输入邮箱：按查询结果注册新账号、重新开始未完成的设置，或接入已有账号。账号没有密码。
class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.c});
  final AppController c;
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.c.prefs.email ?? '');

  AppController get c => widget.c;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final email = _email.text.trim();
    // 先收起键盘：否则下一页换成数字键盘时，页面会被顶上去一截，标题被遮住。
    FocusManager.instance.primaryFocus?.unfocus();
    AccountSession? found;
    if (!await runBusy(context, () async => found = await c.findAccount(email)) || !mounted) return;
    final info = found;
    if (info != null && info.initialized) {
      await runBusy(context, () => c.useAccount(info));
      return;
    }
    if (info == null && c.instance?.registrationOpen == false) {
      toast(context, '这个邮箱还没有注册，这台服务器也没有开放注册。请检查邮箱是否输错，或联系服务器管理员。');
      return;
    }
    final ok = info == null
        ? await confirmDialog(context, title: '创建新账号？', body: '$email 还没有注册。要用它在这台服务器上创建一个新账号吗？\n请先确认邮箱没有输错。', ok: '创建')
        : await confirmDialog(context, title: '重新开始设置？', body: '$email 已经注册，但还没有完成设置，账号里没有任何数据。要从头开始设置吗？', ok: '重新设置');
    if (!ok || !mounted) return;
    await runBusy(context, () => c.register(email));
  }

  @override
  Widget build(BuildContext context) {
    final first = c.instance?.firstAccount ?? false;
    return AuthScaffold(
      title: first ? '创建账号' : '输入邮箱',
      subtitle: first
          ? '这台服务器上还没有账号，输入邮箱创建第一个账号。\nHarmonia 没有密码，数据由手机上的密钥和恢复码保护。'
          : '新邮箱会创建账号；已有账号时，这台手机由管理设备批准接入，或者用恢复码恢复。\nHarmonia 没有密码。',
      children: [
        if (c.notice != null) ...[Banner2(c.notice!, warn: true), const SizedBox(height: Space.lg)],
        Row(
          children: [
            Icon(Icons.dns_outlined, size: 16, color: context.palette.mute),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(c.prefs.server ?? '', style: TextStyle(color: context.palette.mute)),
            ),
            TextButton(onPressed: c.changeServer, child: const Text('更换')),
          ],
        ),
        const SizedBox(height: Space.md),
        AutofillGroup(
          onDisposeAction: AppScope.isSimulated(context) ? AutofillContextAction.cancel : AutofillContextAction.commit,
          child: Form(
            key: _form,
            child: TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofillHints: AppScope.isSimulated(context) ? null : const [AutofillHints.email],
              decoration: const InputDecoration(labelText: '邮箱'),
              validator: validateEmail,
              onFieldSubmitted: (_) => _submit(),
            ),
          ),
        ),
        if (c.instance?.emailVerification ?? false) ...[
          const SizedBox(height: Space.md),
          const Banner2('注册新账号时需要输入邮件中的验证码。'),
        ],
        const SizedBox(height: Space.xl),
        FilledButton(onPressed: _submit, child: const Text('继续')),
        const SizedBox(height: Space.lg),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: Space.sm,
          children: [
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RecoverPage(c: c, email: _email.text),
                ),
              ),
              child: const Text('用恢复码恢复'),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AccountResetPage(c: c, email: _email.text),
                ),
              ),
              child: const Text('重置账号'),
            ),
          ],
        ),
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
        autofillHints: null,
        maxLength: 9,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 22, letterSpacing: 3),
        decoration: const InputDecoration(labelText: '8 位验证码', counterText: ''),
      ),
      const SizedBox(height: Space.xl),
      FilledButton(onPressed: () => runBusy(context, () => widget.c.verifyEmail(_code.text)), child: const Text('验证')),
      const SizedBox(height: Space.md),
      TextButton(
        onPressed: () => runBusy(context, widget.c.resendVerification, done: '已重新发送验证码'),
        child: const Text('没有收到？重新发送'),
      ),
    ],
  );
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

  /// 验证码绑定的流程凭证，发送验证码时由服务端返回。
  String? _flow;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return AuthScaffold(
      title: '重置账号',
      subtitle: '只有在恢复码和所有管理设备都丢失时才需要重置。',
      onBack: () => Navigator.pop(context),
      children: [
        const Banner2('重置会永久删除这个账号的全部环境、变量和已授权设备，无法撤销，也无法找回数据。\n之后可以用同一个邮箱重新注册。', warn: true),
        const SizedBox(height: Space.lg),
        TextField(
          autofillHints: AppScope.isSimulated(context) ? null : const [AutofillHints.email],
          controller: _email,
          enabled: !_sent,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: '邮箱'),
        ),
        if (_sent) ...[
          const SizedBox(height: Space.md),
          TextField(
            autofillHints: null,
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: '邮件中的 8 位验证码'),
          ),
          const SizedBox(height: Space.md),
          TextField(
            autofillHints: null,
            controller: _confirm,
            decoration: const InputDecoration(labelText: '输入“删除全部数据”以确认'),
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: Space.xl),
        if (!_sent)
          FilledButton(
            onPressed: () async {
              final ok = await runBusy(
                context,
                () async => _flow = await c.account.requestAccountReset(c.server, _email.text),
                done: '验证码已发送',
              );
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
                      context,
                      () => c.account.completeAccountReset(c.server, _email.text, _flow!, _code.text),
                      done: '账号已重置，可以重新注册',
                    );
                    if (ok && context.mounted) Navigator.pop(context);
                  },
            child: const Text('永久删除并重置'),
          ),
      ],
    );
  }
}
