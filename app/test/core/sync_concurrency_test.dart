import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/api.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/store.dart';
import 'package:harmonia/core/vault.dart';

class QueuedApi extends ApiClient {
  QueuedApi() : super('https://example.invalid');
  final calls = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> device(String method, String path, {Object? body, Map<String, String>? headers}) {
    final c = Completer<Map<String, dynamic>>();
    calls.add(c);
    return c.future;
  }
}

void main() {
  test('同一个键并发写入不会出错', () async {
    final dir = await Directory.systemTemp.createTemp('harmonia-store');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileStore(dir);
    await Future.wait([for (var i = 0; i < 8; i++) store.write('cache', '$i')]);
    expect(int.parse((await store.read('cache'))!), inInclusiveRange(0, 7));
  });

  test('同时发起的同步依次执行', () async {
    final api = QueuedApi();
    final vault = Vault(await HCrypto.init(), MemoryStore(), MemoryStore())..api = api;
    final first = vault.sync();
    final second = vault.sync();
    await pumpEventQueue();
    expect(api.calls, hasLength(1));
    api.calls[0].completeError(ApiException(0, 'network', '断开'));
    await expectLater(first, throwsA(isA<ApiException>()));
    await pumpEventQueue();
    expect(api.calls, hasLength(2));
    api.calls[1].completeError(ApiException(0, 'network', '断开'));
    await expectLater(second, throwsA(isA<ApiException>()));
  });
}
