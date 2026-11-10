// 一个调试入口对应一个内存会话，退出后整体销毁。
import 'dart:typed_data';

import '../core/account.dart';
import '../core/crypto.dart';
import '../core/debug_account.dart';
import '../core/debug_push.dart';
import '../core/debug_vault.dart';
import '../core/push.dart';
import '../core/store.dart';
import 'controller.dart';
import 'debug_identity.dart';

class DebugSession {
  DebugSession._(this.c, this.vault, this.account, this.pushDevice, this.pushInstance);
  final AppController c;
  final DebugVault vault;
  final DebugAccount account;
  final DebugPushDevice pushDevice;
  final DebugPushInstance pushInstance;

  static Future<DebugSession> create({required Future<void> Function() prepareGlass}) async {
    final crypto = await HCrypto.init();
    final vault = DebugVault(crypto);
    final account = DebugAccount(crypto, vault);
    final pushDevice = DebugPushDevice();
    final pushInstance = DebugPushInstance();
    final c = AppController(
      crypto: crypto,
      secure: vault.secure,
      files: MemoryStore(),
      account: account,
      vault: vault,
      push: PushRegistrar(device: pushDevice, relay: DebugPushRelay(), store: MemoryStore(), platform: 'ios'),
      pushInstance: pushInstance,
      identity: DebugIdentity(crypto),
      deviceName: '示例手机',
      platform: 'ios',
      prepareGlass: prepareGlass,
    );
    vault.onSimulatedChange = c.refresh;
    final session = DebugSession._(c, vault, account, pushDevice, pushInstance);
    session.reset();
    return session;
  }

  void reset({DebugScenario scenario = DebugScenario.normal}) {
    cancelPendingFlow();
    c.cancelToSignIn();
    vault.reset(scenario: scenario);
    (c.identity.keyring as DebugKeyring).pin = '123456';
    (c.identity.keyring as DebugKeyring).biometric = false;
    account.reset();
    c.prefs = Prefs(server: 'https://debug.invalid', email: 'demo@example.invalid');
    c.stage = Stage.home;
    c.online = scenario != DebugScenario.offline;
    c.pairings = [...vault.requests];
    prepareAccount();
    c.instance = InstanceInfo('https://debug.invalid', '0.0.0', true, false, true);
    _resetPush(DebugPushScenario.ok);
    c.pendingEmail = 'demo@example.invalid';
    c.verifyFlow = 'debug-verification';
    c.setupDraft = account.prepareSetup();
    c.setupCompleted = false;
    c.pendingPairing = PendingPairing(
      c.session!,
      'debug-wait',
      'debug-secret',
      Uint8List(32),
      Uint8List(32),
      pairingQr('debug-wait', Uint8List(32)),
      '0000 0000 0000 0000',
      DateTime.now().add(const Duration(minutes: 5)),
      '示例手机',
    );
    c.refresh();
  }

  /// 切换“后台通知”的模拟状态：系统权限、推送令牌和实例开关都只在内存里。
  Future<void> setPush(DebugPushScenario scenario, {bool enabled = true}) async {
    _resetPush(scenario, enabled: enabled);
    await c.push.sync(pushInstance, force: true);
    c.refresh();
  }

  void _resetPush(DebugPushScenario scenario, {bool enabled = true}) {
    pushDevice
      ..perm = switch (scenario) {
        DebugPushScenario.needsPermission => PushPermission.notDetermined,
        DebugPushScenario.systemOff => PushPermission.denied,
        _ => PushPermission.granted,
      }
      ..hasToken = scenario != DebugPushScenario.unavailable
      ..opened = false;
    pushInstance.allows = scenario != DebugPushScenario.serverOff;
    c.push.state = PushState()
      ..enabled = enabled
      ..asked = scenario != DebugPushScenario.needsPermission;
    c.push.status = PushStatus.checking;
    c.staleNotification = false;
  }

  void prepareAccount({bool initialized = true}) {
    final config = vault.sampleConfig;
    c.session = AccountSession(
      config.server,
      config.email,
      config.accountId,
      initialized,
      initialized ? config.rootPub : null,
      token: initialized ? null : 'debug-registration',
    );
  }

  void cancelPendingFlow() {
    c.pendingPairing?.cancel();
    c.pendingPairing = null;
  }

  void dispose() {
    cancelPendingFlow();
    c.dispose();
    vault.close();
  }
}
