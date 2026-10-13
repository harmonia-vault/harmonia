import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/account.dart';
import 'package:harmonia/core/api.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/debug_account.dart';
import 'package:harmonia/core/debug_vault.dart';
import 'package:harmonia/core/models.dart';
import 'package:harmonia/core/vault.dart';

void main() {
  late HCrypto crypto;
  late DebugVault vault;
  setUpAll(() async => crypto = await HCrypto.init());
  setUp(() => vault = DebugVault(crypto));
  tearDown(() => vault.close());

  test('环境与变量的增改删跨次读取一致，删除环境同时撤销设备引用', () async {
    await vault.createEnvironment('新的示例');
    final id = vault.environments.last.id;
    await vault.setVariable(id, 'TOKEN', 'demo-only');
    await vault.setVariable(id, 'TOKEN', 'changed');
    await vault.renameEnvironment(id, '已改名');
    final device = vault.devices.last;
    await vault.updateGrants(device, [Grant(id, 'rw', 0)]);
    await vault.sync();
    expect(vault.environment(id).name, '已改名');
    expect(vault.values(id), {'TOKEN': 'changed'});
    expect(vault.devices.last.grants.single.envId, id);
    await vault.deleteVariable(id, 'TOKEN');
    expect(vault.values(id), isEmpty);
    await vault.setVariable(id, 'OTHER', 'temporary');
    await vault.deleteEnvironment(id);
    expect(vault.environments.where((e) => e.id == id), isEmpty);
    expect(vault.cache.variables.containsKey(id), isFalse);
    expect(vault.devices.last.grants, isEmpty);
  });

  test('设备管理通过 Vault 类型调用仍然只修改模拟状态', () async {
    final Vault operations = vault;
    final request = (await operations.pendingPairings()).singleWhere((p) => p.authorized);
    final qr = pairingQr(request.id, pairingFingerprint(request.id, request.signPub, request.boxPub, request.rootPub));
    expect((await operations.pairingFromQr(qr)).id, request.id);
    await operations.approvePairing(request, asManager: false, grants: [Grant('debug-env-1', 'ro', 0)]);
    expect((await operations.pendingPairings()).where((p) => p.authorized), isEmpty);
    await operations.renameDevice(request.id, '已批准电脑');
    await operations.setSystemVars(request.id, true);
    await operations.setActivation(request.id, [Grant('debug-env-1', 'ro', 0, active: false)]);
    final device = operations.devices.last;
    expect(device.name, '已批准电脑');
    expect(device.systemVars, isTrue);
    expect(device.grants.single.active, isFalse);
    await operations.revokeDevice(request.id);
    expect(operations.devices.where((d) => d.id == request.id), isEmpty);
  });

  test('离线和失败操作不改变已有数据，重置与新会话恢复样例', () async {
    final original = vault.values('debug-env-1');
    vault.scenario = DebugScenario.offline;
    await expectLater(vault.setVariable('debug-env-1', 'API_KEY', 'wrong'), throwsA(isA<ApiException>()));
    vault.scenario = DebugScenario.failure;
    await expectLater(vault.deleteEnvironment('debug-env-1'), throwsA(isA<VaultException>()));
    expect(vault.values('debug-env-1'), original);
    vault.reset(scenario: DebugScenario.empty);
    expect(vault.environments, isEmpty);
    vault.reset();
    expect(vault.values('debug-env-1'), original);
    final other = DebugVault(crypto);
    addTearDown(other.close);
    await vault.deleteEnvironment('debug-env-1');
    expect(other.values('debug-env-1'), original);
  });

  test('任意服务器地址都只产生模拟账号结果，验证码和重置产生内存变化', () async {
    final AccountService account = DebugAccount(crypto, vault);
    const server = 'https://must-not-be-contacted.example.com';
    expect((await account.instance(server)).server, 'https://debug.invalid');
    expect(await account.lookup(server, 'test@example.invalid'), isNull);
    expect((await account.register(server, 'test@example.invalid')).flow, isNotNull);
    await expectLater(
      account.verifyEmail(server, 'test@example.invalid', 'flow', 'bad'),
      throwsA(isA<VaultException>()),
    );
    final session = await account.verifyEmail(server, 'test@example.invalid', 'flow', '12345678');
    expect(session.initialized, isFalse);
    expect(session.token, isNotNull);
    final rotation = await vault.rotateRecovery(Uint8List(16));
    expect(await vault.rotationCompleted(rotation.key), isTrue);
    await account.completeAccountReset(server, session.email, 'flow', '12345678');
    expect(vault.paired, isFalse);
    expect(vault.environments, isEmpty);
  });

  test('未模拟的请求在发送边界被拒绝', () async {
    final client = ApiClient('https://must-not-be-contacted.example.com', client: DebugNetworkClient());
    await expectLater(client.public('GET', '/'), throwsStateError);
    await expectLater(vault.api!.public('POST', '/'), throwsStateError);
  });
}
