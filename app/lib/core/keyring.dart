// 本机密钥保护（docs/protocol.md 2.5）：本机数据密钥只能由 App PIN 或指纹解开。
// 这里实现 PIN 槽和输错限制（本机配置的加解密在 Vault）；指纹槽的内容由 Keystore 生成，这里只负责保存。
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'store.dart';

/// Keystore 中不可导出的密钥。App 用 Android Keystore 实现，测试用软件实现。
abstract class HardwareKeys {
  /// 用 PIN 专用的 HMAC 密钥计算 HMAC-SHA256；密钥不存在时创建。
  Future<Uint8List> pinMac(Uint8List input);

  /// 删除全部本机密钥（PIN 的 HMAC 密钥和指纹密钥）。
  Future<void> deleteAll();
}

class PinResult {
  PinResult._(this.key, this.remaining, this.waitSeconds);
  factory PinResult.ok(Uint8List key) => PinResult._(key, 0, 0);
  factory PinResult.wrong(int remaining) => PinResult._(null, remaining, 0);
  factory PinResult.blocked(int seconds) => PinResult._(null, 0, seconds);

  /// 解开的本机数据密钥；PIN 不对或需要等待时为 null。
  final Uint8List? key;
  final int remaining;
  final int waitSeconds;
  bool get ok => key != null;
}

class Keyring {
  Keyring(this.crypto, this.secure, this.hw,
      {Future<Uint8List> Function(String, Uint8List)? derive, DateTime Function()? now})
      : _derive = derive ?? passwordKeyInIsolate,
        _now = now ?? DateTime.now;

  final HCrypto crypto;
  final LocalStore secure;
  final HardwareKeys hw;
  final Future<Uint8List> Function(String, Uint8List) _derive;
  final DateTime Function() _now;

  static const minPin = 6, maxPin = 16, freeTries = 5;
  static const maxWait = Duration(minutes: 30);
  static const _pinSlot = 'pinSlot', _bioSlot = 'bioSlot', _failures = 'pinFailures';
  static final _slotAad = canonical(['harmonia.local-slot', 'pin']);

  static bool validPin(String pin) =>
      pin.length >= minPin && pin.length <= maxPin && RegExp(r'^\d+$').hasMatch(pin);

  Future<bool> hasPin() async => await secure.read(_pinSlot) != null;

  /// 生成新的本机数据密钥，并用 PIN 保护。旧的 PIN 槽和指纹槽一并作废。
  Future<Uint8List> create(String pin) async {
    final key = crypto.random(32);
    await secure.delete(_bioSlot);
    await secure.delete(_failures);
    await _writePinSlot(key, pin);
    return key;
  }

  Future<void> changePin(Uint8List key, String pin) => _writePinSlot(key, pin);

  Future<void> _writePinSlot(Uint8List key, String pin) async {
    if (!validPin(pin)) throw ArgumentError('PIN 需要 $minPin–$maxPin 位数字');
    final salt = crypto.random(16);
    final kek = await _kek(pin, salt);
    final box = crypto.aeadSeal(kek, key, _slotAad);
    await secure.write(_pinSlot, jsonEncode({'salt': b64(salt), 'box': b64(box)}));
  }

  Future<Uint8List> _kek(String pin, Uint8List salt) async =>
      hw.pinMac(await _derive(pin, salt));

  /// 用 PIN 解开本机数据密钥。连续输错 [freeTries] 次后需要等待，等待时间逐次翻倍。
  Future<PinResult> unlock(String pin) async {
    final wait = await _waitLeft();
    if (wait > Duration.zero) return PinResult.blocked(_ceilSeconds(wait));
    final raw = await secure.read(_pinSlot);
    if (raw == null) throw StateError('还没有设置 App PIN');
    final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
    try {
      final kek = await _kek(pin, unb64(j['salt'] as String));
      final key = crypto.aeadOpen(kek, unb64(j['box'] as String), _slotAad);
      await secure.delete(_failures);
      return PinResult.ok(key);
    } on DecryptException {
      return _recordFailure();
    }
  }

  Future<PinResult> _recordFailure() async {
    final n = (await _readFailures()).$1 + 1;
    if (n < freeTries) {
      await secure.write(_failures, jsonEncode({'n': n, 'until': 0}));
      return PinResult.wrong(freeTries - n);
    }
    var wait = Duration(seconds: 30 * (1 << (n - freeTries).clamp(0, 10)));
    if (wait > maxWait) wait = maxWait;
    final until = _now().add(wait).millisecondsSinceEpoch;
    await secure.write(_failures, jsonEncode({'n': n, 'until': until}));
    return PinResult.blocked(wait.inSeconds);
  }

  Future<(int, int)> _readFailures() async {
    final raw = await secure.read(_failures);
    if (raw == null) return (0, 0);
    final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
    return (j['n'] as int, j['until'] as int);
  }

  Future<Duration> _waitLeft() async {
    final until = (await _readFailures()).$2;
    return Duration(milliseconds: until - _now().millisecondsSinceEpoch);
  }

  static int _ceilSeconds(Duration d) => (d.inMilliseconds + 999) ~/ 1000;

  // ---- 指纹槽：内容由 Keystore 加密生成，这里只保存 ----

  Future<String?> bioSlot() => secure.read(_bioSlot);
  Future<void> saveBioSlot(String slot) => secure.write(_bioSlot, slot);
  Future<void> deleteBioSlot() => secure.delete(_bioSlot);

  /// 删除 PIN 槽、指纹槽、输错记录和 Keystore 中的密钥。
  Future<void> wipe() async {
    await secure.delete(_pinSlot);
    await secure.delete(_bioSlot);
    await secure.delete(_failures);
    await hw.deleteAll();
  }
}
