// 系统锁屏独立于应用切后台；原生层保留标记，避免 Dart 暂停期间丢失事件。
import 'package:flutter/services.dart';

class ScreenLock {
  static const _channel = MethodChannel('harmonia/lock');

  static void listen(void Function() onLocked) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'locked') onLocked();
    });
  }

  static void stop() => _channel.setMethodCallHandler(null);

  static Future<({bool locked, bool wasLocked})> check() async {
    try {
      final state = await _channel.invokeMapMethod<String, bool>('consumeLock');
      return (locked: state?['locked'] ?? true, wasLocked: state?['wasLocked'] ?? true);
    } catch (_) {
      // 平台检查失败时要求重新验证，不沿用可能已经失效的解锁状态。
      return (locked: false, wasLocked: true);
    }
  }
}
