// 外观只属于本机，不进入账号配置或同步缓存。
import 'dart:convert';

import 'store.dart';

enum AppColorMode { system, light, dark }

/// 只在五个等距标记附近吸附，其余位置保留连续值。
double snapGlassOpacity(double value) {
  for (final stop in const [0.0, 0.25, 0.5, 0.75, 1.0]) {
    if ((value - stop).abs() <= 0.035) return stop;
  }
  return value;
}

class AppearanceSettings {
  AppearanceSettings(this._store, {required this.prepareGlass});

  final LocalStore _store;
  final Future<void> Function() prepareGlass;
  static const _key = 'appearance';
  AppColorMode _colorMode = AppColorMode.system;
  AppColorMode get colorMode => _colorMode;
  double _glassOpacity = 0.5;
  double get glassOpacity => _glassOpacity;
  Future<void> _pending = Future.value();

  // 透明度拖动结束后可能立即切换明暗，串行保存以免覆盖彼此的选择。
  Future<void> _update(Future<void> Function() change) {
    final result = _pending.then((_) => change());
    _pending = result.catchError((Object _) {});
    return result;
  }

  Future<void> load() async {
    await prepareGlass();
    final raw = await _store.read(_key);
    if (raw == null) return;
    final data = jsonDecode(raw);
    if (data is! Map || !AppColorMode.values.any((m) => m.name == data['colorMode'])) {
      throw const FormatException('外观设置无法读取，请重新设置。');
    }
    final opacity = data['glassOpacity'];
    if (opacity is! num || !opacity.isFinite || opacity < 0 || opacity > 1) {
      throw const FormatException('透明度设置无法读取，请重新设置。');
    }
    _colorMode = AppColorMode.values.byName(data['colorMode'] as String);
    _glassOpacity = opacity.toDouble();
  }

  Future<void> setColorMode(AppColorMode mode) => _update(() async {
    if (mode == _colorMode) return;
    await _save(colorMode: mode, glassOpacity: _glassOpacity);
    _colorMode = mode;
  });

  Future<void> _save({required AppColorMode colorMode, required double glassOpacity}) =>
      _store.write(_key, jsonEncode({'colorMode': colorMode.name, 'glassOpacity': glassOpacity}));

  Future<void> setGlassOpacity(double opacity) => _update(() async {
    if (!opacity.isFinite || opacity < 0 || opacity > 1) throw ArgumentError.value(opacity, 'opacity');
    if (opacity == _glassOpacity) return;
    await _save(colorMode: _colorMode, glassOpacity: opacity);
    _glassOpacity = opacity;
  });
}
