// 本机身份确认：App PIN（必有）和生物识别（可选）都用来解开本机数据密钥（docs/protocol.md 2.5）。
// 系统部分由 harmonia/keys 通道实现：Android 是 LocalKeys.kt（Keystore），iOS 是 LocalKeys.swift
// （Secure Enclave 与钥匙串）。

import 'dart:io';

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

  /// 生物识别的叫法：Android 上是“指纹”，iOS 上按机型是“面容 ID”或“触控 ID”。
  String bioName = '指纹';

  bool get bioIsFace => bioName == '面容 ID';

  /// [bioName] 后面接一段话；名称以拉丁字母结尾时中间加空格，例如“面容 ID 解锁”“指纹解锁”。
  String bio(String rest) => bioName.endsWith('ID') ? '$bioName $rest' : '$bioName$rest';

  /// 启动时读取一次本机的生物识别类型（只有 iOS 需要区分）。
  Future<void> loadBioName() async {
    if (!Platform.isIOS) return;
    try {
      bioName = await _channel.invokeMethod<String>('bioKind') == 'touch' ? '触控 ID' : '面容 ID';
    } catch (_) {}
  }

  /// 刚才解锁时发现生物识别密钥已被系统作废（录入的指纹或面容有变化）；界面提示一次后清除。
  bool bioInvalidated = false;

  Future<bool> bioAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('bioAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> bioEnabled() async => await keyring.bioSlot() != null;

  /// 开启生物识别解锁：验证一次，把本机数据密钥交给系统保护（Android 用指纹密钥加密，
  /// iOS 存为只有面容 ID / 触控 ID 能读出的钥匙串条目）。返回是否开启。
  /// [cancel] 是系统验证界面上取消按钮的文字。
  Future<bool> enableBio(Uint8List key, {String cancel = '取消'}) async {
    try {
      final slot = await _channel.invokeMethod<Uint8List>(
          'bioEnable', {'key': key, 'title': '开启${bio('解锁')}', 'cancel': cancel});
      await keyring.saveBioSlot(b64(slot!));
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'canceled') return false;
      throw Exception('没能开启${bio('解锁')}，请稍后重试。');
    }
  }

  Future<void> disableBio() => keyring.deleteBioSlot();

  /// 用生物识别解开本机数据密钥。没开启、取消、失败时返回 null，由调用方改用 PIN。
  Future<Uint8List?> unlockWithBio(String title) async {
    final slot = await keyring.bioSlot();
    if (slot == null) return null;
    try {
      return await _channel.invokeMethod<Uint8List>(
          'bioUnlock', {'slot': unb64(slot), 'title': title, 'cancel': '改用 PIN'});
    } on PlatformException catch (e) {
      if (e.code == 'invalidated') {
        await keyring.deleteBioSlot();
        bioInvalidated = true;
      }
      return null;
    }
  }
}
