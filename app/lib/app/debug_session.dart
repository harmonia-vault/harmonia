// 一个调试入口对应一个内存会话，退出后整体销毁。
import 'dart:typed_data';

import '../core/account.dart';
import '../core/crypto.dart';
import '../core/debug_account.dart';
import '../core/debug_vault.dart';
import '../core/store.dart';
import 'controller.dart';
import 'debug_identity.dart';

class DebugSession {
  DebugSession._(this.c, this.vault, this.account);
  final AppController c;
  final DebugVault vault;
  final DebugAccount account;

  static Future<DebugSession> create({required Future<void> Function() prepareGlass}) async {
    final crypto = await HCrypto.init();
    final vault = DebugVault(crypto);
    final account = DebugAccount(crypto, vault);
    final c = AppController(
      crypto: crypto,
      secure: vault.secure,
      files: MemoryStore(),
      account: account,
      vault: vault,
      identity: DebugIdentity(crypto),
      deviceName: '示例手机',
      platform: 'ios',
      prepareGlass: prepareGlass,
    );
    vault.onSimulatedChange = c.refresh;
    final session = DebugSession._(c, vault, account);
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
