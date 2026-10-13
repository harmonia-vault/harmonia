import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/app/controller.dart';
import 'package:harmonia/app/debug_session.dart';
import 'package:harmonia/core/appearance.dart';
import 'package:harmonia/core/crypto.dart';

void main() {
  late DebugSession session;
  setUp(() async => session = await DebugSession.create(prepareGlass: () async {}));
  tearDown(() => session.dispose());

  test('模拟查询账号、注册、验证码、PIN 和初始化可完整走到首页', () async {
    final c = session.c;
    expect(await c.findAccount('new@example.invalid'), isNull);
    expect((await c.findAccount('setup@example.invalid'))!.initialized, isFalse);
    await c.register('new@example.invalid');
    expect(c.stage, Stage.verifyEmail);
    await c.verifyEmail('12345678');
    expect(c.stage, Stage.setPin);
    await c.setPin('654321');
    await c.pinDone();
    expect(c.stage, Stage.setup);
    await c.completeSetup();
    expect(c.setupCompleted, isTrue);
    c.finishSetup();
    await Future<void>.delayed(Duration.zero);
    expect(c.stage, Stage.home);
    expect(c.vault.paired, isTrue);
    expect((await c.identity.keyring.unlock('654321')).key, Uint8List(32));
  });

  test('已设置的账号进入“接入这台手机”，配对码不对时提示，正确时管理设备会直接弹出', () async {
    final c = session.c;
    c.cancelToSignIn();
    final found = await c.findAccount('demo@example.invalid');
    expect(found!.initialized, isTrue);
    await c.useAccount(found);
    expect(c.stage, Stage.setPin);
    await c.setPin('654321');
    await c.pinDone();
    expect(c.stage, Stage.unpaired);
    await expectLater(c.startPairing(code: 'AAAA-AAAA'), throwsA(isA<Exception>()));
    await c.startPairing(code: '7k3m-9q2p');
    expect(c.stage, Stage.pairing);
    expect(c.pendingPairing!.authorized, isTrue);
    session.cancelPendingFlow();
  });

  test('只有用配对码发起的请求进入待批准列表和角标', () async {
    final c = session.c;
    expect(c.pairings, hasLength(2));
    expect(c.authorizedPairings.map((p) => p.id), ['debug-pairing']);
    expect(c.pendingPairingCount, 1);
    final anonymous = c.pairings.firstWhere((p) => !p.authorized);
    expect((await c.vault.pairingFromQr(pairingQr(anonymous.id, Uint8List(32)))).id, anonymous.id);
    expect((await c.vault.createPairingCode()).formatted, '7K3M-9Q2P');
  });

  test('离开目录取消模拟等待，迟到的批准不能改变当前页面', () async {
    final c = session.c;
    await c.startPairing();
    expect(c.stage, Stage.pairing);
    session.cancelPendingFlow();
    await c.changeServer();
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    expect(c.stage, Stage.connect);
    expect(c.pendingPairing, isNull);
  });

  test('两次调试会话不共享数据、PIN 或外观，重置恢复示例', () async {
    final other = await DebugSession.create(prepareGlass: () async {});
    addTearDown(other.dispose);
    await session.vault.deleteEnvironment('debug-env-1');
    await session.c.identity.keyring.changePin(Uint8List(32), '654321');
    await session.c.setColorMode(AppColorMode.dark);
    await session.c.setLiquidGlass(true);
    expect(other.vault.environments.any((e) => e.id == 'debug-env-1'), isTrue);
    expect((await other.c.identity.keyring.unlock('123456')).key, Uint8List(32));
    expect(other.c.appearance.colorMode, AppColorMode.system);
    expect(other.c.appearance.liquidGlass, isFalse);
    session.reset();
    expect(session.vault.environments.any((e) => e.id == 'debug-env-1'), isTrue);
    expect((await session.c.identity.keyring.unlock('123456')).key, Uint8List(32));
  });
}
