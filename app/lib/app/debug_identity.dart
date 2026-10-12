// 模拟身份验证不触发 Keystore、钥匙串或生物识别系统弹窗。
import 'dart:typed_data';

import '../core/crypto.dart';
import '../core/keyring.dart';
import '../core/store.dart';
import 'identity.dart';

class _DebugHardwareKeys implements HardwareKeys {
  @override
  Future<Uint8List> pinMac(Uint8List input) async => Uint8List(32);
  @override
  Future<void> deleteAll() async {}
}

class DebugKeyring extends Keyring {
  DebugKeyring(HCrypto crypto) : super(crypto, MemoryStore(), _DebugHardwareKeys());
  String pin = '123456';
  bool biometric = false;
  @override
  Future<bool> hasPin() async => true;
  @override
  Future<Uint8List> create(String pin) async {
    this.pin = pin;
    return Uint8List(32);
  }

  @override
  Future<void> changePin(Uint8List key, String pin) async {
    this.pin = pin;
  }

  @override
  Future<PinResult> unlock(String pin) async => pin == this.pin ? PinResult.ok(Uint8List(32)) : PinResult.wrong(5);
  @override
  Future<void> wipe() async {
    pin = '123456';
    biometric = false;
  }
}

class DebugIdentity extends Identity {
  DebugIdentity(HCrypto crypto) : super(DebugKeyring(crypto)) {
    bioName = '模拟指纹';
  }
  DebugKeyring get _keys => keyring as DebugKeyring;
  @override
  Future<void> loadBioName() async {}
  @override
  Future<bool> bioAvailable() async => true;
  @override
  Future<bool> bioEnabled() async => _keys.biometric;
  @override
  Future<bool> enableBio(Uint8List key, {String cancel = '取消'}) async {
    _keys.biometric = true;
    return true;
  }

  @override
  Future<void> disableBio() async {
    _keys.biometric = false;
  }

  @override
  Future<Uint8List?> unlockWithBio(String title) async => _keys.biometric ? Uint8List(32) : null;
}
