// 无界面的“管理设备”，供端到端测试使用：与 App 共用 lib/core 的全部逻辑。
// ignore_for_file: avoid_print
// 用法：dart run tool/manager.dart --home <目录> <命令> [参数...]
import 'dart:convert';
import 'dart:io';

import 'package:harmonia/core/account.dart';
import 'package:harmonia/core/api.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/models.dart';
import 'package:harmonia/core/push.dart';
import 'package:harmonia/core/store.dart';
import 'package:harmonia/core/vault.dart';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  String opt(String name, [String? def]) {
    final i = args.indexOf('--$name');
    if (i < 0) {
      if (def != null) return def;
      throw ArgumentError('缺少 --$name');
    }
    final v = args[i + 1];
    args.removeRange(i, i + 2);
    return v;
  }

  final home = opt('home');
  final crypto = await HCrypto.init();
  final store = FileStore(Directory(home));
  final vault = Vault(crypto, store, store);
  // App 里本机数据密钥由 PIN 或指纹解开；无界面脚本直接把它存在测试目录中。
  final localKey = await store.read('localKey');
  vault.localKey = localKey != null ? unb64(localKey) : crypto.random(32);
  if (localKey == null) await store.write('localKey', b64(vault.localKey!));
  final account = AccountService(crypto);
  final cmd = args.removeAt(0);

  Future<Vault> loaded() async {
    if (!await vault.load()) throw StateError('还没有接入账号');
    await vault.sync();
    return vault;
  }

  String envId(String name) => vault.environments.firstWhere((e) => e.name == name || e.id == name).id;
  String vaultId(String name) => vault.vaults.firstWhere((v) => v.name == name || v.id == name).id;
  // 授权写成 环境:权限[:nolocal]，nolocal 表示不开启本机解密。
  Grant grant(String spec) {
    final p = spec.split(':');
    return Grant(envId(p[0]), p[1], 0, localDecrypt: !p.contains('nolocal'));
  }

  // 引用写成 变量库:all|pick[:rw][:原名=新名,原名...]，例如 共享:pick:OPENAI_API_KEY=LLM_KEY。
  EnvRef ref(String spec) {
    final p = spec.split(':');
    final items = <RefItem>[];
    for (final part in p.skip(2).where((x) => x != 'rw' && x.isNotEmpty)) {
      for (final it in part.split(',')) {
        final kv = it.split('=');
        items.add(RefItem(kv[0], kv.length > 1 ? kv[1] : null));
      }
    }
    return EnvRef(vaultId(p[0]), p[1], writable: p.contains('rw'), items: items);
  }

  // 变量：先按变量库找，找不到再按环境（用环境里的名字）。
  Map<String, VarEntry> values(String target) => vault.vaults.any((v) => v.name == target || v.id == target)
      ? vault.entries(vaultId(target))
      : vault.envEntries(envId(target));
  DeviceInfo device(String name) => vault.devices.firstWhere((d) => d.name == name || d.id == name);

  // 注册会话在 register / verify 与 setup 之间保存在测试目录中。
  Future<void> saveRegistration(AccountSession s) => store.write(
    'registration',
    jsonEncode({'server': s.server, 'email': s.email, 'accountId': s.accountId, 'token': s.token}),
  );
  Future<AccountSession> loadRegistration() async {
    final j = (jsonDecode((await store.read('registration'))!) as Map).cast<String, dynamic>();
    return AccountSession(
      j['server'] as String,
      j['email'] as String,
      j['accountId'] as String,
      false,
      null,
      token: j['token'] as String,
    );
  }

  switch (cmd) {
    case 'register':
      // 需要验证邮箱时同时输出验证码绑定的流程凭证，供 verify 使用。
      final r = await account.register(opt('server'), opt('email'));
      if (r.session != null) await saveRegistration(r.session!);
      print(r.flow != null ? 'verification-required\t${r.flow}' : 'registered');
    case 'verify':
      await saveRegistration(await account.verifyEmail(opt('server'), opt('email'), opt('flow'), opt('code')));
      print('verified');
    case 'lookup':
      final a = await account.lookup(opt('server'), opt('email'));
      print(a == null ? 'not-registered' : (a.initialized ? 'initialized' : 'uninitialized'));
    case 'setup':
      final draft = account.prepareSetup();
      await vault.adopt(await account.completeSetup(await loadRegistration(), draft, opt('name', '测试手机')));
      print(draft.formattedCode);
    case 'env-create':
      // 新建变量库和引用它全部变量、可以修改的同名环境，测试里常用的一步准备。
      final v = await loaded();
      final id = await v.createVault(args[0]);
      print(await v.createEnvironment(args[0], [EnvRef(id, 'all', writable: true)]));
    case 'vault-create':
      // 只建变量库。
      print(await (await loaded()).createVault(args[0]));
    case 'env-define':
      // env-define <环境名> <引用...>：环境不存在时新建，存在时整体替换引用。
      final v = await loaded();
      final refs = [for (final spec in args.sublist(1)) ref(spec)];
      final existing = v.environments.where((e) => e.name == args[0]).firstOrNull;
      if (existing == null) {
        print(await v.createEnvironment(args[0], refs));
      } else {
        await v.saveEnvironment(existing.id, args[0], refs);
        print(existing.id);
      }
    case 'env-delete':
      await (await loaded()).deleteEnvironment(envId(args[0]));
      print('ok');
    case 'vault-delete':
      await (await loaded()).deleteVault(vaultId(args[0]));
      print('ok');
    case 'var-set':
      await (await loaded()).setVariable(vaultId(args[0]), args[1], args[2], args.length > 3 ? args[3] : '');
      print('ok');
    case 'var-get':
      await loaded();
      print(values(args[0])[args[1]]?.value ?? '');
    case 'var-note':
      await loaded();
      print(values(args[0])[args[1]]?.note ?? '');
    case 'pairing-code':
      // 生成配对码，输出 8 位码。
      print((await (await loaded()).createPairingCode()).code);
    case 'pending':
      // 列出发起方仍在等待的请求：名称和是否由配对码创建。
      for (final p in await (await loaded()).pendingPairings()) {
        print('${p.name}\t${p.authorized ? 'authorized' : 'anonymous'}');
      }
    case 'approve':
      // approve <核对码> <manager|环境:权限...>
      final v = await loaded();
      final p = await v.pairingFromCode(args[0]);
      if (args[1] == 'manager') {
        await v.approvePairing(p, asManager: true);
      } else {
        await v.approvePairing(p, asManager: false, grants: [for (final g in args.sublist(1)) grant(g)]);
      }
      print(p.id);
    case 'grants':
      final v = await loaded();
      await v.updateGrants(device(args[0]), [for (final g in args.sublist(1)) grant(g)]);
      print('ok');
    case 'activation':
      // 按给定顺序设置某台设备的激活状态，环境名后加 :off 表示停用。
      final v = await loaded();
      final d = device(args[0]);
      final byEnv = {for (final g in d.grants) g.envId: g};
      await v.setActivation(d.id, [
        for (final a in args.sublist(1)) byEnv[envId(a.split(':')[0])]!.copyWith(active: !a.endsWith(':off')),
      ]);
      print('ok');
    case 'system-vars':
      // 修改某台设备的“写入系统变量”开关：system-vars <设备名> on|off。
      final v = await loaded();
      await v.setSystemVars(device(args[0]).id, args[1] == 'on');
      print('ok');
    case 'auto-update':
      // 修改某台电脑的“自动更新”开关：auto-update <设备名> on|off。
      final v = await loaded();
      await v.setAutoUpdate(device(args[0]).id, args[1] == 'on');
      print('ok');
    case 'cli-update':
      // 让某台电脑现在检查更新并升级：cli-update <设备名>。
      final v = await loaded();
      await v.requestCliUpdate(device(args[0]).id);
      print('ok');
    case 'revoke':
      final v = await loaded();
      await v.revokeDevice(device(args[0]).id);
      print('ok');
    case 'approvals':
      // 列出电脑发来的、等待批准的请求：请求码、读取或写入、变量名。
      for (final a in await (await loaded()).pendingApprovals()) {
        print(
          '${a.code}\t${a.isWrite ? 'write' : 'read'}\t${[...a.items.map((i) => i.name), ...a.deletes.map((i) => '-${i.name}')].join(',')}',
        );
      }
    case 'approval-approve':
      // approval-approve <请求码> [once|terminal:<分钟>|all:<分钟>|terminal:forever|all:forever]
      final v = await loaded();
      final a = (await v.pendingApprovals()).firstWhere((x) => x.code == args[0]);
      final problem = v.approvalProblem(a);
      if (problem != null) throw StateError(problem);
      if (a.isWrite) {
        await v.approveWrite(a);
      } else {
        final spec = (args.length > 1 ? args[1] : 'once').split(':');
        final minutes = spec.length > 1 && spec[1] != 'forever' ? int.parse(spec[1]) : 0;
        final expiresAt = minutes == 0 ? 0 : DateTime.now().add(Duration(minutes: minutes)).millisecondsSinceEpoch;
        await v.approveRead(a, scope: spec[0], expiresAt: expiresAt);
      }
      print('ok');
    case 'approval-reject':
      final v = await loaded();
      final a = (await v.pendingApprovals()).firstWhere((x) => x.code == args[0]);
      await v.rejectApproval(a.id);
      print('ok');
    case 'authorizations':
      // 正在生效的授权：设备名、范围、变量名。
      final v = await loaded();
      for (final x in await v.authorizations()) {
        print('${device(x.deviceId).name}\t${x.scope}\t${x.items.map((i) => i.name).join(',')}\t${x.id}');
      }
    case 'authorization-end':
      final v = await loaded();
      await v.endAuthorization(args[0]);
      print('ok');
    case 'devices':
      final v = await loaded();
      for (final d in v.devices) {
        final grants = d.grants.map(
          (g) => '${v.environment(g.envId).name}:${g.role}${g.active ? '' : ':off'}${g.localDecrypt ? '' : ':nolocal'}',
        );
        print(
          '${d.name}\t${d.kind}\t${grants.join(',')}\t${d.systemVars ? 'system-vars' : ''}\t${d.version}'
          '\t${d.autoUpdate ? 'auto-update' : ''}',
        );
      }
    case 'pair':
      // 作为新的管理设备发起配对（可选带配对码），等待管理设备批准。
      final s = await account.lookup(opt('server'), opt('email'));
      if (s == null || !s.initialized) throw StateError('账号不存在或还没有初始化');
      final code = args.contains('--code') ? opt('code') : null;
      final p = await account.startPairing(s, opt('name', '第二台手机'), code: code);
      await vault.adopt(await account.waitPairing(p, onReady: () => stderr.writeln('核对码：${p.code}')));
      print(vault.isManager ? 'manager' : 'client');
    case 'recover':
      await vault.adopt(await account.recover(opt('server'), opt('email'), opt('code'), opt('name', '恢复手机')));
      print(vault.cache.rotationRequired ? 'rotation-required' : 'ok');
    case 'rotate':
      final v = await loaded();
      final code = crypto.random(16);
      await v.rotateRecovery(code);
      print(formatRecoveryCode(code));
    case 'push-register':
      // 后台通知的登记（设计文档 18.4）：用给定的假推送令牌向中继登记，把句柄交给实例。
      final relay = RelayClient(ApiClient(opt('relay')));
      final token = opt('token');
      final v = await loaded();
      final push = PushRegistrar(device: _FixedPushDevice(token), relay: relay, store: store, platform: 'android');
      await push.load();
      print((await push.sync(VaultPushInstance(v, account), force: true)).name);
    case 'sync':
      await loaded();
      print('seq=${vault.cache.seq}');
    default:
      stderr.writeln('未知命令：$cmd');
      exit(2);
  }
  exit(0);
}

/// 无界面脚本没有系统通知：权限视为已允许，令牌由参数给出。
class _FixedPushDevice implements PushDevice {
  _FixedPushDevice(this.value);
  final String value;
  @override
  Future<PushPermission> permission() async => PushPermission.granted;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<PushToken?> token() async => PushToken(value);
  @override
  Future<void> openSettings() async {}
  @override
  Future<bool> takeOpened() async => false;
}
