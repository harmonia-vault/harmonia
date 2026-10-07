// 无界面的“管理手机”，供端到端测试使用：与 App 共用 lib/core 的全部逻辑。
// ignore_for_file: avoid_print
// 用法：dart run tool/manager.dart --home <目录> <命令> [参数...]
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

  switch (cmd) {
    case 'register':
      final v = await account.register(opt('server'), opt('email'), opt('password'));
      print(v ? 'verification-required' : 'registered');
    case 'verify':
      await account.verifyEmail(opt('server'), opt('email'), opt('code'));
      print('verified');
    case 'setup':
      final s = await account.login(opt('server'), opt('email'), opt('password'));
      final draft = account.prepareSetup();
      await vault.adopt(await account.completeSetup(s, draft, opt('name', '测试手机')));
      print(draft.formattedCode);
    case 'env-create':
      await (await loaded()).createEnvironment(args[0]);
      print(envId(args[0]));
    case 'var-set':
      await (await loaded()).setVariable(envId(args[0]), args[1], args[2]);
      print('ok');
    case 'var-get':
      print((await loaded()).values(envId(args[0]))[args[1]] ?? '');
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
    case 'revoke':
      final v = await loaded();
      await v.revokeDevice(device(args[0]).id);
      print('ok');
    case 'devices':
      for (final d in (await loaded()).devices) {
        print('${d.name}\t${d.kind}\t${d.grants.map((g) => '${g.envId}:${g.role}').join(',')}');
      }
    case 'pair':
      // 作为新的管理手机发起配对，等待另一台手机批准。
      final s = await account.login(opt('server'), opt('email'), opt('password'));
      final p = await account.startPairing(s, opt('name', '第二台手机'));
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
