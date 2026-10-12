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
  AppearanceSettings(this._store, {required this.prepareGlass, this.defaultLiquidGlass = false});

  final LocalStore _store;
  final Future<void> Function() prepareGlass;
  final bool defaultLiquidGlass;
  static const _key = 'appearance';
  bool _liquidGlass = false;
  AppColorMode _colorMode = AppColorMode.system;
  AppColorMode get colorMode => _colorMode;
  double _glassOpacity = 0.5;
  double get glassOpacity => _glassOpacity;
  Future<void> _pending = Future.value();

  // 透明度拖动结束后可能立即切换明暗或开关，串行保存以免覆盖彼此的选择。
  Future<void> _update(Future<void> Function() change) {
    final result = _pending.then((_) => change());
    _pending = result.catchError((Object _) {});
    return result;
  }

  bool get liquidGlass => _liquidGlass;

  Future<void> load() async {
    final raw = await _store.read(_key);
    if (raw == null) {
      if (defaultLiquidGlass) await prepareGlass();
      _liquidGlass = defaultLiquidGlass;
      return;
    }
    final data = jsonDecode(raw);
    if (data is! Map || data['liquidGlass'] is! bool || !AppColorMode.values.any((m) => m.name == data['colorMode'])) {
      throw const FormatException('外观设置无法读取，请重新设置。');
    }
    final enabled = data['liquidGlass'] as bool;
    final opacity = data['glassOpacity'] ?? 0.5;
    if (opacity is! num || !opacity.isFinite || opacity < 0 || opacity > 1) {
      throw const FormatException('透明度设置无法读取，请重新设置。');
    }
    if (enabled) await prepareGlass();
    _liquidGlass = enabled;
    _colorMode = AppColorMode.values.byName(data['colorMode'] as String);
    _glassOpacity = opacity.toDouble();
  }

  Future<void> setColorMode(AppColorMode mode) => _update(() async {
    if (mode == _colorMode) return;
    await _save(liquidGlass: _liquidGlass, colorMode: mode, glassOpacity: _glassOpacity);
    _colorMode = mode;
  });

  Future<void> _save({required bool liquidGlass, required AppColorMode colorMode, required double glassOpacity}) =>
      _store.write(
        _key,
        jsonEncode({'liquidGlass': liquidGlass, 'colorMode': colorMode.name, 'glassOpacity': glassOpacity}),
      );

  Future<void> setGlassOpacity(double opacity) => _update(() async {
    if (!opacity.isFinite || opacity < 0 || opacity > 1) throw ArgumentError.value(opacity, 'opacity');
    if (opacity == _glassOpacity) return;
    await _save(liquidGlass: _liquidGlass, colorMode: _colorMode, glassOpacity: opacity);
    _glassOpacity = opacity;
  });

  Future<void> setLiquidGlass(bool enabled) => _update(() async {
    if (enabled == _liquidGlass) return;
    if (enabled) await prepareGlass();
    // 写入成功再改变界面，保存失败时保持原来的选择。
    await _save(liquidGlass: enabled, colorMode: _colorMode, glassOpacity: _glassOpacity);
    _liquidGlass = enabled;
  });
}
