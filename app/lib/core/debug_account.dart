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
  bool _initialized = true;
  bool requireCode = false;
  void reset() {
    _initialized = true;
    requireCode = false;
  }

  void _code(String code) {
    if (code.replaceAll('-', '').trim() != '12345678') throw VaultException('模拟验证码不正确，请输入 12345678。');
  }

  PasswordSession _session(String email) => PasswordSession(
    'https://debug.invalid',
    email.trim(),
    'debug-token',
    'debug-account',
    _initialized,
    'debug-root',
  );

  @override
  Future<InstanceInfo> instance(String rawServer) async {
    vault.check();
    return InstanceInfo('https://debug.invalid', '0.0.0', true, false, true);
  }

  @override
  Future<String?> register(String server, String email, String password) async {
    vault.check();
    _initialized = false;
    vault.password = password;
    return 'debug-verification';
  }

  @override
  Future<void> verifyEmail(String server, String email, String flow, String code) async {
    vault.check();
    _code(code);
  }

  @override
  Future<String> resendVerification(String server, String email) async {
    vault.check();
    return 'debug-verification';
  }

  @override
  Future<PasswordSession> login(
    String server,
    String email,
    String password, {
    Future<String?> Function(String)? askCode,
  }) async {
    vault.check();
    if (password != vault.password) throw VaultException('模拟密码不正确，请重试或重置示例。');
    if (requireCode && askCode != null) {
      final code = await askCode('请输入模拟验证码 12345678。');
      if (code == null) throw VaultException('已取消模拟登录。');
      _code(code);
    }
    return _session(email);
  }

  @override
  Future<String> requestPasswordReset(String server, String email) async {
    vault.check();
    return 'debug-password-reset';
  }

  @override
  Future<void> completePasswordReset(String server, String email, String flow, String code, String newPassword) async {
    vault.check();
    _code(code);
    vault.password = newPassword;
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
  Future<LocalConfig> completeSetup(PasswordSession s, SetupDraft d, String deviceName) async {
    vault.check();
    _initialized = true;
    return vault.sampleConfig;
  }

  @override
  Future<PendingPairing> startPairing(PasswordSession s, String deviceName) async {
    vault.check();
    return PendingPairing(
      s,
      'debug-wait',
      'debug-secret',
      Uint8List(32),
      Uint8List(32),
      pairingQr('debug-wait', Uint8List(32)),
      '0000 0000 0000 0000',
      DateTime.now().add(const Duration(minutes: 10)),
      '示例手机',
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
