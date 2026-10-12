// 外观只属于本机，不进入账号配置或同步缓存。
import 'dart:convert';

import 'store.dart';

enum AppColorMode { system, light, dark }

class AppearanceSettings {
  AppearanceSettings(this._store, {required this.prepareGlass});

  final LocalStore _store;
  final Future<void> Function() prepareGlass;
  static const _key = 'appearance';
  bool _liquidGlass = false;
  AppColorMode _colorMode = AppColorMode.system;
  AppColorMode get colorMode => _colorMode;

  bool get liquidGlass => _liquidGlass;

  Future<void> load() async {
    final raw = await _store.read(_key);
    if (raw == null) return;
    final data = jsonDecode(raw);
    if (data is! Map || data['liquidGlass'] is! bool || !AppColorMode.values.any((m) => m.name == data['colorMode'])) {
      throw const FormatException('外观设置无法读取，请重新设置。');
    }
    final enabled = data['liquidGlass'] as bool;
    if (enabled) await prepareGlass();
    _liquidGlass = enabled;
    _colorMode = AppColorMode.values.byName(data['colorMode'] as String);
  }

  Future<void> setColorMode(AppColorMode mode) async {
    if (mode == _colorMode) return;
    await _save(liquidGlass: _liquidGlass, colorMode: mode);
    _colorMode = mode;
  }

  Future<void> _save({required bool liquidGlass, required AppColorMode colorMode}) =>
      _store.write(_key, jsonEncode({'liquidGlass': liquidGlass, 'colorMode': colorMode.name}));

  Future<void> setLiquidGlass(bool enabled) async {
    if (enabled == _liquidGlass) return;
    if (enabled) await prepareGlass();
    // 写入成功再改变界面，保存失败时保持原来的选择。
    await _save(liquidGlass: enabled, colorMode: _colorMode);
    _liquidGlass = enabled;
  }
}
