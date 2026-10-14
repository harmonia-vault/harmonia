// 无界面的“管理设备”，供端到端测试使用：与 App 共用 lib/core 的全部逻辑。
// ignore_for_file: avoid_print
// 用法：dart run tool/manager.dart --home <目录> <命令> [参数...]
import 'dart:convert';
import 'dart:io';

import 'package:harmonia/core/account.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/models.dart';
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

  String envId(String name) =>
      vault.environments.firstWhere((e) => e.name == name || e.id == name).id;
  DeviceInfo device(String name) =>
      vault.devices.firstWhere((d) => d.name == name || d.id == name);

  // 注册会话在 register / verify 与 setup 之间保存在测试目录中。
  Future<void> saveRegistration(AccountSession s) => store.write(
      'registration', jsonEncode({'server': s.server, 'email': s.email, 'accountId': s.accountId, 'token': s.token}));
  Future<AccountSession> loadRegistration() async {
    final j = (jsonDecode((await store.read('registration'))!) as Map).cast<String, dynamic>();
    return AccountSession(j['server'] as String, j['email'] as String, j['accountId'] as String, false, null,
        token: j['token'] as String);
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
      await (await loaded()).createEnvironment(args[0]);
      print(envId(args[0]));
    case 'var-set':
      await (await loaded()).setVariable(envId(args[0]), args[1], args[2]);
      print('ok');
    case 'var-get':
      print((await loaded()).values(envId(args[0]))[args[1]] ?? '');
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
        await v.approvePairing(p, asManager: false, grants: [
          for (final g in args.sublist(1))
            Grant(envId(g.split(':')[0]), g.split(':')[1], 0),
        ]);
      }
      print(p.id);
    case 'grants':
      final v = await loaded();
      await v.updateGrants(device(args[0]), [
        for (final g in args.sublist(1)) Grant(envId(g.split(':')[0]), g.split(':')[1], 0),
      ]);
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
    case 'revoke':
      final v = await loaded();
      await v.revokeDevice(device(args[0]).id);
      print('ok');
    case 'devices':
      final v = await loaded();
      for (final d in v.devices) {
        final grants = d.grants.map((g) => '${v.environment(g.envId).name}:${g.role}${g.active ? '' : ':off'}');
        print('${d.name}\t${d.kind}\t${grants.join(',')}\t${d.systemVars ? 'system-vars' : ''}\t${d.version}');
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
    case 'sync':
      await loaded();
      print('seq=${vault.cache.seq}');
    default:
      stderr.writeln('未知命令：$cmd');
      exit(2);
  }
  exit(0);
}
