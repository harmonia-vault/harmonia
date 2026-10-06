// 本机身份确认：优先使用系统验证（指纹、锁屏密码），设备没有设置锁屏时使用 App PIN。
// 它只控制界面能否进入，不和任何密钥绑定（见 docs/rewrite-plan.md 4.2）。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

import '../core/crypto.dart';
import '../core/store.dart';

enum IdentityMethod { system, pin, none }

class Identity {
  Identity(this.secure);
  final LocalStore secure;
  final _auth = LocalAuthentication();

  int _failures = 0;
  DateTime? _blockedUntil;

  static const _pinKey = 'pin';

  Future<bool> _systemAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasPin() async => await secure.read(_pinKey) != null;

  Future<IdentityMethod> method() async {
    if (await _systemAvailable()) return IdentityMethod.system;
    if (await hasPin()) return IdentityMethod.pin;
    return IdentityMethod.none;
  }

  /// 系统验证。返回 null 表示系统验证不可用（应改用 PIN）。
  Future<bool?> system(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        authMessages: const [
          AndroidAuthMessages(signInTitle: 'Harmonia 身份验证', cancelButton: '取消', signInHint: ''),
        ],
      );
    } on LocalAuthException catch (e) {
      if (e.code == LocalAuthExceptionCode.noCredentialsSet ||
          e.code == LocalAuthExceptionCode.noBiometricHardware) {
        return null;
      }
      return false;
    }
  }

  Future<void> setPin(String pin) async {
    final rng = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
    final hash = await passwordKeyInIsolate(pin, salt);
    await secure.write(_pinKey, jsonEncode({'salt': b64(salt), 'hash': b64(hash)}));
  }

  Future<void> clearPin() => secure.delete(_pinKey);

  /// 校验 PIN；连续输错后需要等待。
  Future<PinResult> checkPin(String pin) async {
    final until = _blockedUntil;
    if (until != null && until.isAfter(DateTime.now())) {
      return PinResult.blocked(until.difference(DateTime.now()).inSeconds + 1);
    }
    final raw = await secure.read(_pinKey);
    if (raw == null) return PinResult.ok();
    final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
    final hash = await passwordKeyInIsolate(pin, unb64(j['salt'] as String));
    if (b64(hash) == j['hash']) {
      _failures = 0;
      return PinResult.ok();
    }
    _failures++;
    if (_failures >= 5) {
      final wait = Duration(seconds: 30 * (1 << (_failures - 5).clamp(0, 6)));
      _blockedUntil = DateTime.now().add(wait);
      return PinResult.blocked(wait.inSeconds);
    }
    return PinResult.wrong(5 - _failures);
  }
}

class PinResult {
  PinResult._(this.ok, this.remaining, this.waitSeconds);
  factory PinResult.ok() => PinResult._(true, 0, 0);
  factory PinResult.wrong(int remaining) => PinResult._(false, remaining, 0);
  factory PinResult.blocked(int seconds) => PinResult._(false, 0, seconds);
  final bool ok;
  final int remaining;
  final int waitSeconds;
}
