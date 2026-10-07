// 本机身份确认：App PIN（必有）和指纹（可选）都用来解开本机数据密钥（docs/protocol.md 2.5）。
// Keystore 部分由 MainActivity 的 harmonia/keys 通道（LocalKeys.kt）实现。

import 'package:flutter/services.dart';

import '../core/crypto.dart';
import '../core/keyring.dart';

const _channel = MethodChannel('harmonia/keys');

class KeystoreKeys implements HardwareKeys {
  @override
  Future<Uint8List> pinMac(Uint8List input) async =>
      (await _channel.invokeMethod<Uint8List>('pinMac', {'input': input}))!;

  @override
  Future<void> deleteAll() => _channel.invokeMethod('deleteAll');
}

class Identity {
  Identity(this.keyring);
  final Keyring keyring;

  /// 刚才解锁时发现指纹密钥已被系统作废（指纹有变化）；界面提示一次后清除。
  bool bioInvalidated = false;

  Future<bool> bioAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('bioAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> bioEnabled() async => await keyring.bioSlot() != null;

  /// 开启指纹解锁：验证一次指纹，用指纹密钥加密本机数据密钥。返回是否开启。
  Future<bool> enableBio(Uint8List key) async {
    try {
      final slot = await _channel.invokeMethod<Uint8List>('bioEnable', {'key': key, 'title': '开启指纹解锁'});
      await keyring.saveBioSlot(b64(slot!));
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'canceled') return false;
      throw Exception('没能开启指纹解锁，请稍后重试。');
    }
  }

  Future<void> disableBio() => keyring.deleteBioSlot();

  /// 用指纹解开本机数据密钥。没开启、取消、失败时返回 null，由调用方改用 PIN。
  Future<Uint8List?> unlockWithBio(String title) async {
    final slot = await keyring.bioSlot();
    if (slot == null) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('bioUnlock', {'slot': unb64(slot), 'title': title});
    } on PlatformException catch (e) {
      if (e.code == 'invalidated') {
        await keyring.deleteBioSlot();
        bioInvalidated = true;
      }
      return null;
    }
  }
}
