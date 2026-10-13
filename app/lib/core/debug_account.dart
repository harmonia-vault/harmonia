// 接入流程的模拟结果；所有输入只用于这次调试会话。
import 'dart:typed_data';

import 'account.dart';
import 'api.dart';
import 'crypto.dart';
import 'debug_vault.dart';
import 'vault.dart';

class DebugAccount extends AccountService {
  DebugAccount(super.crypto, this.vault)
    : super(clientFactory: (base) => ApiClient(base, client: DebugNetworkClient()));
  final DebugVault vault;

  /// 模拟的已设置账号；[unfinishedEmail] 是注册了但还没有完成设置的账号，其他邮箱按未注册处理。
  static const readyEmail = 'demo@example.invalid';
  static const unfinishedEmail = 'setup@example.invalid';

  /// 模拟配对码，按 4 位一组显示为 7K3M-9Q2P。
  static const pairingCode = '7K3M9Q2P';

  bool _initialized = true;
  void reset() => _initialized = true;

  void _code(String code) {
    if (code.replaceAll('-', '').trim() != '12345678') throw VaultException('模拟验证码不正确，请输入 12345678。');
  }

  AccountSession _session(String email, {bool? initialized, String? token}) => AccountSession(
    'https://debug.invalid',
    email.trim().toLowerCase(),
    'debug-account',
    initialized ?? _initialized,
    (initialized ?? _initialized) ? 'debug-root' : null,
    token: token,
  );

  @override
  Future<InstanceInfo> instance(String rawServer) async {
    vault.check();
    return InstanceInfo('https://debug.invalid', '0.0.0', true, false, true);
  }

  @override
  Future<AccountSession?> lookup(String server, String email) async {
    vault.check();
    return switch (email.trim().toLowerCase()) {
      readyEmail => _session(email),
      unfinishedEmail => _session(email, initialized: false),
      _ => null,
    };
  }

  @override
  Future<Registration> register(String server, String email) async {
    vault.check();
    _initialized = false;
    return Registration(flow: 'debug-verification');
  }

  @override
  Future<AccountSession> verifyEmail(String server, String email, String flow, String code) async {
    vault.check();
    _code(code);
    return _session(email, token: 'debug-registration');
  }

  @override
  Future<String> resendVerification(String server, String email) async {
    vault.check();
    return 'debug-verification';
  }

  @override
  Future<String> requestAccountReset(String server, String email) async {
    vault.check();
    return 'debug-account-reset';
  }

  @override
  Future<void> completeAccountReset(String server, String email, String flow, String code) async {
    vault.check();
    _code(code);
    await vault.wipe();
    _initialized = false;
  }

  @override
  SetupDraft prepareSetup() => SetupDraft(Uint8List(16), Uint8List(32), Uint8List(32), Uint8List(32), 'debug-phone');
  @override
  Future<LocalConfig> completeSetup(AccountSession s, SetupDraft d, String deviceName) async {
    vault.check();
    _initialized = true;
    return vault.sampleConfig;
  }

  @override
  Future<PendingPairing> startPairing(AccountSession s, String deviceName, {String? code}) async {
    vault.check();
    final withCode = code != null && code.trim().isNotEmpty;
    if (withCode && normalizeCode(code) != pairingCode) {
      throw VaultException('模拟配对码不对，请输入 7K3M-9Q2P，或者留空改用扫码。');
    }
    return PendingPairing(
      s,
      'debug-wait',
      'debug-secret',
      Uint8List(32),
      Uint8List(32),
      pairingQr('debug-wait', Uint8List(32)),
      '0000 0000 0000 0000',
      DateTime.now().add(const Duration(minutes: 5)),
      '示例手机',
      authorized: withCode,
    );
  }

  @override
  Future<LocalConfig> waitPairing(PendingPairing p, {required void Function() onReady}) async {
    onReady();
    await Future<void>.delayed(const Duration(seconds: 3));
    vault.check();
    return vault.sampleConfig;
  }

  @override
  Future<LocalConfig> recover(String server, String email, String codeInput, String deviceName) async {
    vault.check();
    if (codeInput.trim().isEmpty) throw VaultException('请输入任意模拟恢复码后重试。');
    vault.cache.self['rotationRequired'] = true;
    return vault.sampleConfig;
  }
}
