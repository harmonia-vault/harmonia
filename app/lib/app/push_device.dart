// 系统通知能力的平台通道（实现见 Android 的 PushChannel、iOS 的 PushChannel）。
import 'package:flutter/services.dart';

import '../core/push.dart';

class HostPushDevice implements PushDevice {
  static const _channel = MethodChannel('harmonia/push');

  @override
  Future<PushPermission> permission() async => switch (await _channel.invokeMethod<String>('permission')) {
    'granted' => PushPermission.granted,
    'notDetermined' => PushPermission.notDetermined,
    _ => PushPermission.denied,
  };

  @override
  Future<bool> requestPermission() async => await _channel.invokeMethod<bool>('requestPermission') ?? false;

  @override
  Future<PushToken?> token() async {
    final res = await _channel.invokeMapMethod<String, String>('token');
    final token = res?['token'];
    if (token == null || token.isEmpty) return null;
    return PushToken(token, apnsEnvironment: res!['apnsEnvironment']);
  }

  @override
  Future<void> openSettings() => _channel.invokeMethod('openSettings');

  @override
  Future<bool> takeOpened() async => await _channel.invokeMethod<bool>('takeOpened') ?? false;
}
