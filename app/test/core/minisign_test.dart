import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/app/updater.dart';
import 'package:harmonia/core/crypto.dart';

void main() {
  test('minisign 签名校验、版本顺序与渠道', () async {
    final c = await HCrypto.init();
    final v = (jsonDecode(File('../vectors/crypto.json').readAsStringSync()) as Map)['minisign'] as Map;
    final msg = Uint8List.fromList(utf8.encode(v['message'] as String));
    expect(verifyMinisign(c, v['publicKey'] as String, msg, v['signature'] as String), isTrue);
    expect(verifyMinisign(c, v['publicKey'] as String, Uint8List.fromList([...msg, 32]), v['signature'] as String),
        isFalse);
    const order = [
      '0.1.1', 'v0.1.2-alpha.1', '0.1.2-beta.1', '0.1.2-beta.2', '0.1.2-beta.10',
      '0.1.2-rc.1', '0.1.2-rc.2', 'v0.1.2', '0.1.3-beta.1', '0.2.0', '1.0.0-rc.1', '1.0.0',
    ];
    for (var i = 0; i < order.length; i++) {
      for (var j = 0; j < order.length; j++) {
        expect(compareVersions(order[i], order[j]).sign, (i - j).sign, reason: '${order[i]} vs ${order[j]}');
      }
    }
    expect(isPrerelease('0.1.2-rc.1'), isTrue);
    expect(isPrerelease('0.1.2'), isFalse);
  });
}
