import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/appearance.dart';
import 'package:harmonia/core/store.dart';

Future<void> _prepared() async {}

void main() {
  test('透明度只在标记附近吸附，其他位置保持无级', () {
    expect(snapGlassOpacity(0.02), 0);
    expect(snapGlassOpacity(0.48), 0.5);
    expect(snapGlassOpacity(0.52), 0.5);
    expect(snapGlassOpacity(0.23), 0.25);
    expect(snapGlassOpacity(0.73), 0.75);
    expect(snapGlassOpacity(0.98), 1);
    expect(snapGlassOpacity(0.18), 0.18);
    expect(snapGlassOpacity(0.66), 0.66);
  });

  test('首次使用准备玻璃材质，不写入尚未修改的偏好', () async {
    final store = MemoryStore();
    var prepared = false;
    final settings = AppearanceSettings(store, prepareGlass: () async => prepared = true);
    await settings.load();
    expect(prepared, isTrue);
    expect(settings.colorMode, AppColorMode.system);
    expect(settings.glassOpacity, 0.5);
    expect(await store.read('appearance'), isNull);
  });

  test('颜色和透明度重启后恢复，另一台设备的偏好独立', () async {
    final directory = await Directory.systemTemp.createTemp('harmonia-appearance-');
    addTearDown(() => directory.delete(recursive: true));
    final first = AppearanceSettings(FileStore(directory), prepareGlass: _prepared);
    await first.setColorMode(AppColorMode.dark);
    await first.setGlassOpacity(0.73);
    final restarted = AppearanceSettings(FileStore(directory), prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.colorMode, AppColorMode.dark);
    expect(restarted.glassOpacity, 0.73);
    final anotherDevice = AppearanceSettings(MemoryStore(), prepareGlass: _prepared);
    await anotherDevice.load();
    expect(anotherDevice.colorMode, AppColorMode.system);
    expect(anotherDevice.glassOpacity, 0.5);
  });

  test('连续调整透明度和颜色不会覆盖彼此的修改', () async {
    final store = MemoryStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    for (final level in [0.0, 0.18, 0.5, 0.73, 1.0]) {
      await Future.wait([settings.setGlassOpacity(level), settings.setColorMode(AppColorMode.dark)]);
      final restarted = AppearanceSettings(store, prepareGlass: _prepared);
      await restarted.load();
      expect(restarted.glassOpacity, level);
      expect(restarted.colorMode, AppColorMode.dark);
    }
  });

  test('保存失败保留当前外观，下一次调整仍能成功', () async {
    final store = _FailingStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    await settings.setColorMode(AppColorMode.dark);
    await settings.setGlassOpacity(0.75);
    store.failWrites = true;
    await expectLater(settings.setGlassOpacity(0.25), throwsA(isA<FileSystemException>()));
    await expectLater(settings.setColorMode(AppColorMode.light), throwsA(isA<FileSystemException>()));
    expect(settings.glassOpacity, 0.75);
    expect(settings.colorMode, AppColorMode.dark);
    store.failWrites = false;
    await settings.setGlassOpacity(1);
    final restarted = AppearanceSettings(store, prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.glassOpacity, 1);
    expect(restarted.colorMode, AppColorMode.dark);
  });

  test('拒绝越界和非数值透明度，不写入偏好', () async {
    final store = MemoryStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    for (final value in [-0.1, 1.1, double.nan, double.infinity]) {
      await expectLater(settings.setGlassOpacity(value), throwsArgumentError);
    }
    expect(await store.read('appearance'), isNull);
  });

  test('损坏的持久化内容不会覆盖已加载的偏好', () async {
    final store = MemoryStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    await settings.setColorMode(AppColorMode.dark);
    await settings.setGlassOpacity(0.75);
    for (final raw in [
      '{"colorMode":"invalid","glassOpacity":0.5}',
      '{"colorMode":"light","glassOpacity":1.5}',
      '{"colorMode":"light","glassOpacity":"0.5"}',
      '{"colorMode":"light"}',
      '[]',
    ]) {
      await store.write('appearance', raw);
      await expectLater(settings.load(), throwsFormatException);
      expect(settings.colorMode, AppColorMode.dark);
      expect(settings.glassOpacity, 0.75);
    }
  });
}

class _FailingStore extends MemoryStore {
  bool failWrites = false;

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw const FileSystemException('无法写入');
    await super.write(key, value);
  }
}
