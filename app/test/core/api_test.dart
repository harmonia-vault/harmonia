import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/api.dart';

void main() {
  test('服务器首页的二维码就是服务器地址', () {
    expect(
      serverFromQr('https://vault.example.com'),
      'https://vault.example.com',
    );
    expect(
      serverFromQr(' https://vault.example.com/ \n'),
      'https://vault.example.com',
    );
    expect(serverFromQr('http://127.0.0.1:8787'), 'http://127.0.0.1:8787');
  });

  test('别的二维码不会被当成服务器地址', () {
    for (final raw in [
      'vault.example.com',
      'harmonia-pair:abc',
      'WIFI:S:home;;',
      '',
      'http://vault.example.com',
      'https://user@vault.example.com',
      'https://vault.example.com/?a=1',
    ]) {
      expect(
        () => serverFromQr(raw),
        throwsA(isA<ApiException>()),
        reason: raw,
      );
    }
  });
}
