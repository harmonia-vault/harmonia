import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/app/controller.dart';
import 'package:harmonia/app/debug_session.dart';
import 'package:harmonia/core/api.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/store.dart';
import 'package:harmonia/core/vault.dart';

class DelayedStore extends MemoryStore {
  Completer<void>? readGate;
  @override
  Future<String?> read(String key) async {
    final value = await super.read(key);
    await readGate?.future;
    return value;
  }
}

class DelayedApi extends ApiClient {
  DelayedApi() : super('https://example.invalid');
  final response = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> device(String method, String path, {Object? body, Map<String, String>? headers}) =>
      response.future;
}

void main() {
  test('锁定后到达的同步响应不会恢复会话缓存', () async {
    final api = DelayedApi();
    final vault = Vault(await HCrypto.init(), MemoryStore(), MemoryStore())..api = api;
    final syncing = vault.sync();
    vault.lock();
    api.response.complete({'seq': 1, 'self': {}, 'environments': [], 'envelopes': [], 'variables': []});
    await syncing;
    expect(vault.cache.seq, 0);
    expect(vault.config, isNull);
    expect(vault.api, isNull);
    expect(vault.localKey, isNull);
  });

  test('短暂切后台再返回保留会话，手动锁定仍须重新解锁', () async {
    final s = await DebugSession.create(prepareGlass: () async {});
    addTearDown(s.dispose);
    s.c.onLifecycle(foreground: false);
    expect(s.c.stage, Stage.home);
    expect(s.vault.localKey, isNotNull);
    s.c.onLifecycle(foreground: true);
    expect(s.c.stage, Stage.home);
    expect(s.vault.localKey, isNotNull);
    s.c.onLifecycle(foreground: false);
    s.c.lockNow();
    expect(s.c.stage, Stage.locked);
    expect(s.vault.localKey, isNull);
    expect(s.c.foreground, isFalse);
    s.c.onLifecycle(foreground: true);
    expect(s.c.stage, Stage.locked);
    await s.c.unlock(Uint8List(32));
    expect(s.c.stage, Stage.home);
  });

  test('解锁读取期间锁定，迟到的完成不能切回首页', () async {
    final s = await DebugSession.create(prepareGlass: () async {});
    addTearDown(s.dispose);
    s.c.lockNow();
    final unlocking = s.c.unlock(Uint8List(32));
    s.c.lockNow();
    await unlocking;
    expect(s.c.stage, Stage.locked);
    expect(s.vault.localKey, isNull);
    s.c.onLifecycle(foreground: false);
    await s.c.unlock(Uint8List(32));
    expect(s.vault.localKey, isNull);
  });

  test('解锁读取期间切后台，未完成的解锁不保留密钥', () async {
    final s = await DebugSession.create(prepareGlass: () async {});
    addTearDown(s.dispose);
    s.c.lockNow();
    final unlocking = s.c.unlock(Uint8List(32));
    s.c.onLifecycle(foreground: false);
    await unlocking;
    expect(s.c.stage, Stage.locked);
    expect(s.vault.localKey, isNull);
  });

  for (final delayedConfig in [true, false]) {
    test('锁定阻止迟到的${delayedConfig ? '配置' : '缓存'}读取重新装入密钥', () async {
      final crypto = await HCrypto.init();
      final secure = DelayedStore(), files = DelayedStore();
      final key = crypto.random(32);
      final config = LocalConfig(
        server: 'https://example.invalid',
        accountId: 'synthetic-account',
        email: 'demo@example.invalid',
        rootPub: b64(crypto.random(32)),
        deviceId: 'synthetic-device',
        deviceName: '测试手机',
        signSeed: b64(crypto.random(32)),
        boxSeed: b64(crypto.random(32)),
      );
      await secure.write(
        'account',
        b64(
          crypto.aeadSeal(
            key,
            Uint8List.fromList(utf8.encode(jsonEncode(config.toJson()))),
            canonical(['harmonia.local', 'config']),
          ),
        ),
      );
      await files.write('cache', '{}');
      final gate = Completer<void>();
      (delayedConfig ? secure : files).readGate = gate;
      final vault = Vault(crypto, secure, files)..localKey = key;
      final loading = vault.load();
      await Future<void>.delayed(Duration.zero);
      vault.lock();
      gate.complete();
      expect(await loading, isFalse);
      expect(vault.localKey, isNull);
      expect(vault.config, isNull);
      expect(vault.signKey, isNull);
      expect(vault.boxKey, isNull);
      expect(vault.environments, isEmpty);
    });
  }
}
