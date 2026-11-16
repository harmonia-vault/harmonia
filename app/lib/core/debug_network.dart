import 'package:http/http.dart' as http;

class DebugNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => throw StateError('页面调试不能访问网络');
}
