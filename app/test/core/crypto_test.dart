import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/crypto.dart';

void main() {
  late HCrypto c;
  late Map<String, dynamic> v;

  setUpAll(() async {
    c = await HCrypto.init();
    v = jsonDecode(File('../vectors/crypto.json').readAsStringSync());
  });

  String s(String sec, String key) => v[sec][key] as String;
  Uint8List b(String sec, String key) => unb64(s(sec, key));

  test('规范数组', () {
    final items = (v['canonical']['items'] as List).cast<String>();
    expect(hex.encode(canonical(items)), s('canonical', 'hex'));
  });

  test('签名', () {
    final k = c.signKeyFromSeed(b('sign', 'seed'));
    final msg = Uint8List.fromList(hex.decode(s('sign', 'msgHex')));
    expect(b64(k.pub), s('sign', 'pub'));
    expect(b64(c.sign(k, msg)), s('sign', 'sig'));
    expect(c.verify(k.pub, msg, b('sign', 'sig')), isTrue);
    expect(c.verify(k.pub, Uint8List.fromList([...msg, 1]), b('sign', 'sig')),
        isFalse);
  });

  test('封装', () {
    final k = c.boxKeyFromSeed(b('box', 'seed'));
    expect(b64(k.pub), s('box', 'pub'));
    expect(utf8.decode(c.open(k, b('box', 'sealed'))), s('box', 'plain'));
    final sealed = c.seal(Uint8List.fromList([1, 2, 3]), k.pub);
    expect(c.open(k, sealed), [1, 2, 3]);
  });

  test('变量值', () {
    final key = b('value', 'key');
    final kv = v['value']['keyVersion'] as int;
    expect(
        c.decryptValue(key, s('value', 'envId'), kv, s('value', 'name'),
            s('value', 'ciphertext')),
        s('value', 'plain'));
    expect(
        () => c.decryptValue(
            key, s('value', 'envId'), kv, 'OTHER', s('value', 'ciphertext')),
        throwsA(isA<DecryptException>()));
    final ct = c.encryptValue(key, 'E', 1, 'N', 'hello');
    expect(c.decryptValue(key, 'E', 1, 'N', ct), 'hello');
  });

  test('密码', () {
    expect(
        b64(c.passwordKey(s('password', 'password'), b('password', 'salt'))),
        s('password', 'key'));
  });

  test('恢复码', () {
    final code = b('recovery', 'code');
    expect(formatRecoveryCode(code), s('recovery', 'formatted'));
    expect(b64(parseRecoveryCode(' ${s('recovery', 'formatted')}\n')!),
        s('recovery', 'code'));
    expect(parseRecoveryCode('ABCD'), isNull);
    final r = c.deriveRecovery(code);
    expect(b64(r.sign.pub), s('recovery', 'signPub'));
    expect(b64(r.box.pub), s('recovery', 'boxPub'));
  });

  test('配对', () {
    final fp = pairingFingerprint(s('pairing', 'pairingId'),
        s('pairing', 'signPub'), s('pairing', 'boxPub'), s('pairing', 'rootPub'));
    expect(b64(fp), s('pairing', 'fingerprint'));
    expect(pairingCode(fp), s('pairing', 'code'));
    expect(pairingQr(s('pairing', 'pairingId'), fp), s('pairing', 'qr'));
    final parsed = parsePairingQr(s('pairing', 'qr'))!;
    expect(parsed.$1, s('pairing', 'pairingId'));
  });

  test('签名原文', () {
    final m = v['messages'];
    expect(hex.encode(envelopeMsg('BBBBBBBBBBBBBBBBBBBBBB', 1, 'recovery',
        utf8.encode('sealed'))), m['envelope']);
    expect(hex.encode(rootRecoveryMsg(2, utf8.encode('sealed'))),
        m['rootRecovery']);
    expect(hex.encode(authMsg('AAAAAAAAAAAAAAAAAAAAAA', 'nonce-1')), m['auth']);
    expect(hex.encode(recoveryAuthMsg('nonce-2')), m['recoveryAuth']);
  });
}
