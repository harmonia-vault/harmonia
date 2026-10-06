import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/app/updater.dart';
import 'package:harmonia/core/crypto.dart';

void main() {
  test('minisign 签名校验与版本比较', () async {
    final c = await HCrypto.init();
    final v = (jsonDecode(File('../vectors/crypto.json').readAsStringSync()) as Map)['minisign'] as Map;
    final msg = Uint8List.fromList(utf8.encode(v['message'] as String));
    expect(verifyMinisign(c, v['publicKey'] as String, msg, v['signature'] as String), isTrue);
    expect(verifyMinisign(c, v['publicKey'] as String, Uint8List.fromList([...msg, 32]), v['signature'] as String),
        isFalse);
    expect(isNewer('0.1.1', '0.1.0'), isTrue);
    expect(isNewer('0.10.0', '0.9.9'), isTrue);
    expect(isNewer('v0.1.0', '0.1.0'), isFalse);
  });
}
