import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/update_download.dart';
import 'package:http/http.dart' as http;

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function() respond;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => respond();

  @override
  void close() => closed = true;
}

final _url = Uri.parse('https://example.invalid/synthetic.apk');

void main() {
  test('无 Content-Length 时按实际分块报告进度并返回完整数据', () async {
    final client = _Client(
      () async => http.StreamedResponse(
        Stream.fromIterable([
          [1, 2],
          [3, 4, 5],
          [6],
        ]),
        200,
      ),
    );
    final progress = <int>[];
    final bytes = await downloadUpdatePackage(_url, expectedSize: 6, onProgress: progress.add, client: client);
    expect(bytes, [1, 2, 3, 4, 5, 6]);
    expect(progress, [0, 2, 5, 6]);
    expect(client.closed, isTrue);
  });

  test('服务器返回错误时不报告成功进度并关闭连接', () async {
    final client = _Client(() async => http.StreamedResponse(Stream.value([1]), 503));
    final progress = <int>[];
    await expectLater(
      downloadUpdatePackage(_url, expectedSize: 1, onProgress: progress.add, client: client),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('暂时无法下载'))),
    );
    expect(progress, isEmpty);
    expect(client.closed, isTrue);
  });

  test('拒绝短包与超大包，超大分块不产生超过总大小的进度', () async {
    for (final size in [2, 4]) {
      final client = _Client(() async => http.StreamedResponse(Stream.value([1, 2, 3]), 200));
      final progress = <int>[];
      await expectLater(
        downloadUpdatePackage(_url, expectedSize: size, onProgress: progress.add, client: client),
        throwsA(isA<Exception>()),
      );
      expect(progress.every((received) => received <= size), isTrue);
      expect(client.closed, isTrue);
    }
  });

  test('无效清单大小不发起请求', () async {
    var requested = false;
    final client = _Client(() async {
      requested = true;
      return http.StreamedResponse(const Stream.empty(), 200);
    });
    await expectLater(
      downloadUpdatePackage(_url, expectedSize: 0, onProgress: (_) {}, client: client),
      throwsA(isA<Exception>()),
    );
    expect(requested, isFalse);
    expect(client.closed, isTrue);
  });

  test('接收途中断线给出可重试提示并关闭连接', () async {
    final client = _Client(
      () async => http.StreamedResponse(Stream.error(http.ClientException('synthetic failure')), 200),
    );
    await expectLater(
      downloadUpdatePackage(_url, expectedSize: 1, onProgress: (_) {}, client: client),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('连接中断'))),
    );
    expect(client.closed, isTrue);
  });

  test('请求超时后迟到的响应不再通知进度', () async {
    final response = Completer<http.StreamedResponse>();
    final client = _Client(() => response.future);
    final progress = <int>[];
    await expectLater(
      downloadUpdatePackage(
        _url,
        expectedSize: 1,
        onProgress: progress.add,
        client: client,
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('下载超时'))),
    );
    expect(client.closed, isTrue);
    response.complete(http.StreamedResponse(Stream.value([1]), 200));
    await Future<void>.delayed(Duration.zero);
    expect(progress, isEmpty);
  });

  test('接收超时后迟到的数据不再通知已关闭的界面', () async {
    final stream = StreamController<List<int>>();
    final client = _Client(() async => http.StreamedResponse(stream.stream, 200));
    final progress = <int>[];
    await expectLater(
      downloadUpdatePackage(
        _url,
        expectedSize: 2,
        onProgress: progress.add,
        client: client,
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<Exception>()),
    );
    expect(client.closed, isTrue);
    expect(progress, [0]);
    stream.add([1, 2]);
    await stream.close();
    expect(progress, [0]);
  });
}
