// 更新包按流接收，进度与大小校验都以已签名清单为准，不依赖服务器的 Content-Length。
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 独占并关闭本次连接；注入客户端仅用于使用合成响应验证下载逻辑。
Future<Uint8List> downloadUpdatePackage(
  Uri url, {
  required int expectedSize,
  required void Function(int received) onProgress,
  http.Client? client,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final connection = client ?? http.Client();
  var active = true;

  Future<Uint8List> receive() async {
    if (expectedSize <= 0) throw Exception('安装包大小无效，请稍后重新检查更新。');
    final response = await connection.send(http.Request('GET', url));
    if (!active) throw TimeoutException('下载已结束');
    if (response.statusCode != 200) throw Exception('暂时无法下载安装包，请稍后重试。');
    final bytes = BytesBuilder(copy: false);
    onProgress(0);
    await for (final chunk in response.stream) {
      if (!active) throw TimeoutException('下载已结束');
      if (bytes.length + chunk.length > expectedSize) {
        throw Exception('安装包大小与更新信息不一致，请重新检查更新。');
      }
      bytes.add(chunk);
      onProgress(bytes.length);
    }
    if (bytes.length != expectedSize) throw Exception('安装包未下载完整，请检查网络后重试。');
    return bytes.takeBytes();
  }

  try {
    return await receive().timeout(timeout);
  } on TimeoutException {
    throw Exception('下载超时，请检查网络后重试。');
  } on http.ClientException {
    throw Exception('下载连接中断，请检查网络后重试。');
  } finally {
    // 超时会先返回；阻止迟到的数据继续通知已经关闭的进度界面。
    active = false;
    connection.close();
  }
}
