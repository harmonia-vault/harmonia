import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/appearance.dart';
import 'package:harmonia/core/store.dart';

Future<void> _prepared() async {}

void main() {
  test('透明度只在五个标记附近吸附，其他位置保持无级', () {
    expect(snapGlassOpacity(0.02), 0);
    expect(snapGlassOpacity(0.48), 0.5);
    expect(snapGlassOpacity(0.52), 0.5);
    expect(snapGlassOpacity(0.23), 0.25);
    expect(snapGlassOpacity(0.73), 0.75);
    expect(snapGlassOpacity(0.98), 1);
    expect(snapGlassOpacity(0.18), 0.18);
    expect(snapGlassOpacity(0.66), 0.66);
  });
  test('首次使用默认关闭，不准备玻璃资源', () async {
    final settings = AppearanceSettings(MemoryStore(), prepareGlass: () => throw StateError('不应加载'));
    await settings.load();
    expect(settings.liquidGlass, isFalse);
    expect(settings.colorMode, AppColorMode.system);
    expect(settings.glassOpacity, 0.5);
  });

  test('系统默认开启时先准备资源，关闭的明确选择在重启后优先', () async {
    final store = MemoryStore();
    var prepared = 0;
    final settings = AppearanceSettings(store, defaultLiquidGlass: true, prepareGlass: () async => prepared++);
    await settings.load();
    expect(settings.liquidGlass, isTrue);
    expect(prepared, 1);
    expect(await store.read('appearance'), isNull);
    await settings.setLiquidGlass(false);
    final restarted = AppearanceSettings(
      store,
      defaultLiquidGlass: true,
      prepareGlass: () => throw StateError('明确关闭时不加载资源'),
    );
    await restarted.load();
    expect(restarted.liquidGlass, isFalse);
  });

  test('系统默认开启但资源准备失败时不显示未准备好的玻璃', () async {
    final settings = AppearanceSettings(
      MemoryStore(),
      defaultLiquidGlass: true,
      prepareGlass: () => throw StateError('模拟资源加载失败'),
    );
    await expectLater(settings.load(), throwsStateError);
    expect(settings.liquidGlass, isFalse);
  });

  test('新实例恢复已保存的选择，另一台设备保持自己的选择', () async {
    final directory = await Directory.systemTemp.createTemp('harmonia-appearance-');
    addTearDown(() => directory.delete(recursive: true));
    final first = AppearanceSettings(FileStore(directory), prepareGlass: _prepared);
    await first.setLiquidGlass(true);
    final restarted = AppearanceSettings(FileStore(directory), prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.liquidGlass, isTrue);

    final anotherDevice = AppearanceSettings(MemoryStore(), prepareGlass: _prepared);
    await anotherDevice.load();
    expect(anotherDevice.liquidGlass, isFalse);

    await restarted.setLiquidGlass(false);
    final closed = AppearanceSettings(FileStore(directory), prepareGlass: () => throw StateError('不应加载'));
    await closed.load();
    expect(closed.liquidGlass, isFalse);
  });

  test('资源准备完成前不改变选择，准备失败不保存开启状态', () async {
    final store = MemoryStore();
    final ready = Completer<void>();
    final settings = AppearanceSettings(store, prepareGlass: () => ready.future);
    final change = settings.setLiquidGlass(true);
    expect(settings.liquidGlass, isFalse);
    final failed = expectLater(change, throwsStateError);
    ready.completeError(StateError('资源不可用'));
    await failed;
    expect(settings.liquidGlass, isFalse);
    final restarted = AppearanceSettings(store, prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.liquidGlass, isFalse);
  });

  test('写入失败保持当前外观，重启后仍为上次成功保存的选择', () async {
    final store = _FailingStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    store.failWrites = true;
    await expectLater(settings.setLiquidGlass(true), throwsA(isA<FileSystemException>()));
    expect(settings.liquidGlass, isFalse);
    store.failWrites = false;
    await settings.setLiquidGlass(true);
    store.failWrites = true;
    await expectLater(settings.setLiquidGlass(false), throwsA(isA<FileSystemException>()));
    expect(settings.liquidGlass, isTrue);
    final restarted = AppearanceSettings(store, prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.liquidGlass, isTrue);
  });

  test('清除账号配置与缓存不清除外观，也不改写其他本机设置', () async {
    final store = MemoryStore();
    await store.write('prefs', '{"server":"https://example.invalid"}');
    await store.write('cache', '{}');
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    await settings.setLiquidGlass(true);
    expect(await store.read('prefs'), '{"server":"https://example.invalid"}');
    await store.delete('prefs');
    await store.delete('cache');
    final restarted = AppearanceSettings(store, prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.liquidGlass, isTrue);
  });

  test('颜色模式与玻璃独立保存，跟随系统可以从手动颜色恢复', () async {
    final store = MemoryStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    await settings.setColorMode(AppColorMode.dark);
    await settings.setLiquidGlass(true);
    final restarted = AppearanceSettings(store, prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.colorMode, AppColorMode.dark);
    expect(restarted.liquidGlass, isTrue);
    await restarted.setColorMode(AppColorMode.light);
    await restarted.setLiquidGlass(false);
    await settings.load();
    expect(settings.colorMode, AppColorMode.light);
    expect(settings.liquidGlass, isFalse);
    await settings.setColorMode(AppColorMode.system);
    await restarted.load();
    expect(restarted.colorMode, AppColorMode.system);
  });

  test('颜色写入失败不改变当前选择，损坏值不覆盖已加载状态', () async {
    final store = _FailingStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    await settings.setColorMode(AppColorMode.dark);
    store.failWrites = true;
    await expectLater(settings.setColorMode(AppColorMode.light), throwsA(isA<FileSystemException>()));
    expect(settings.colorMode, AppColorMode.dark);
    store.failWrites = false;
    await store.write('appearance', '{"liquidGlass":true,"colorMode":"invalid"}');
    await expectLater(settings.load(), throwsFormatException);
    expect(settings.colorMode, AppColorMode.dark);
    expect(settings.liquidGlass, isFalse);
  });

  test('无级透明度重启后保留，快速调整不会覆盖颜色和开关', () async {
    final store = MemoryStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    for (final level in [0.0, 0.18, 0.5, 0.73, 1.0]) {
      await Future.wait([
        settings.setGlassOpacity(level),
        settings.setColorMode(AppColorMode.dark),
        settings.setLiquidGlass(true),
      ]);
      final restarted = AppearanceSettings(store, prepareGlass: _prepared);
      await restarted.load();
      expect(restarted.glassOpacity, level);
      expect(restarted.colorMode, AppColorMode.dark);
      expect(restarted.liquidGlass, isTrue);
    }
  });

  test('透明度保存失败不改变界面，后续调整仍可保存', () async {
    final store = _FailingStore();
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    store.failWrites = true;
    await expectLater(settings.setGlassOpacity(0.0), throwsA(isA<FileSystemException>()));
    expect(settings.glassOpacity, 0.5);
    store.failWrites = false;
    await settings.setGlassOpacity(1.0);
    final restarted = AppearanceSettings(store, prepareGlass: _prepared);
    await restarted.load();
    expect(restarted.glassOpacity, 1.0);
  });

  test('没有指定透明度时使用中档，损坏值不覆盖内存状态', () async {
    final store = MemoryStore();
    await store.write('appearance', '{"liquidGlass":true,"colorMode":"dark"}');
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    await settings.load();
    expect(settings.glassOpacity, 0.5);
    await store.write('appearance', '{"liquidGlass":false,"colorMode":"light","glassOpacity":1.5}');
    await expectLater(settings.load(), throwsFormatException);
    expect(settings.liquidGlass, isTrue);
    expect(settings.colorMode, AppColorMode.dark);
    expect(settings.glassOpacity, 0.5);
  });

  test('拒绝无效的持久化值，不能把字符串当作开启', () async {
    final store = MemoryStore();
    await store.write('appearance', '{"liquidGlass":"true"}');
    final settings = AppearanceSettings(store, prepareGlass: _prepared);
    await expectLater(settings.load(), throwsFormatException);
    expect(settings.liquidGlass, isFalse);
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
