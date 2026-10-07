// docs/protocol.md 第 2 节的 Dart 实现，与 cli/internal/crypto 保持一致。
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:sodium/sodium_sumo.dart';

const kdfOpsLimit = 3;
const kdfMemLimit = 64 * 1024 * 1024;
const maxValueLen = 65536;

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64(String s) {
  final pad = (4 - s.length % 4) % 4;
  return base64Url.decode(s + '=' * pad);
}

/// 规范数组：字符串数组的紧凑 JSON 的 UTF-8 字节。
Uint8List canonical(List<String> items) =>
    Uint8List.fromList(utf8.encode(jsonEncode(items)));

Uint8List sha256(List<int> data) =>
    Uint8List.fromList(hash.sha256.convert(data).bytes);

/// Crockford Base32 字母表：不含 I、L、O、U，避免手抄时混淆。
const _b32Alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String base32Encode(List<int> data) {
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_b32Alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  if (bits > 0) out.write(_b32Alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List? base32Decode(String s) {
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final c in s.split('')) {
    final v = _b32Alphabet.indexOf(c);
    if (v < 0) return null;
    buffer = ((buffer << 5) | v) & 0xFFFF;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }
  return Uint8List.fromList(out);
}

String group4(String s) {
  final parts = <String>[];
  for (var i = 0; i < s.length; i += 4) {
    parts.add(s.substring(i, i + 4 > s.length ? s.length : i + 4));
  }
  return parts.join('-');
}

class SignKey {
  SignKey(this.seed, this.pub, this._secret);
  final Uint8List seed;
  final Uint8List pub;
  final SecureKey _secret;
}

class BoxKey {
  BoxKey(this.seed, this.pub, this._secret);
  final Uint8List seed;
  final Uint8List pub;
  final SecureKey _secret;
}

class RecoveryKeys {
  RecoveryKeys(this.sign, this.box);
  final SignKey sign;
  final BoxKey box;
}

class DecryptException implements Exception {
  @override
  String toString() => '解密失败';
}

/// 全部密码学操作的入口；需要先 [HCrypto.init]。
class HCrypto {
  HCrypto(this.sodium);
  final SodiumSumo sodium;

  static Future<HCrypto> init() async => HCrypto(await SodiumSumoInit.init());

  Uint8List random(int n) => sodium.randombytes.buf(n);
  String newId() => b64(random(16));

  SignKey signKeyFromSeed(Uint8List seed) {
    final kp = sodium.crypto.sign.seedKeyPair(sodium.secureCopy(seed));
    return SignKey(seed, kp.publicKey, kp.secretKey);
  }

  Uint8List sign(SignKey key, Uint8List msg) =>
      sodium.crypto.sign.detached(message: msg, secretKey: key._secret);

  bool verify(Uint8List pub, Uint8List msg, Uint8List sig) {
    if (pub.length != 32 || sig.length != 64) return false;
    return sodium.crypto.sign
        .verifyDetached(message: msg, signature: sig, publicKey: pub);
  }

  BoxKey boxKeyFromSeed(Uint8List seed) {
    final kp = sodium.crypto.box.seedKeyPair(sodium.secureCopy(seed));
    return BoxKey(seed, kp.publicKey, kp.secretKey);
  }

  Uint8List seal(Uint8List msg, Uint8List recipientPub) =>
      sodium.crypto.box.seal(message: msg, publicKey: recipientPub);

  Uint8List open(BoxKey key, Uint8List sealed) {
    try {
      return sodium.crypto.box.sealOpen(
          cipherText: sealed, publicKey: key.pub, secretKey: key._secret);
    } catch (_) {
      throw DecryptException();
    }
  }

  Uint8List hkdf(Uint8List ikm, String info) {
    final h = sodium.crypto.kdfHkdfSha256;
    final prk = h.extract(ikm: ikm);
    return h.expand(masterKey: prk, context: info, outLen: 32).extractBytes();
  }

  Uint8List passwordKey(String password, Uint8List salt) => sodium.crypto.pwhash
      .callStr(
        outLen: 32,
        password: password,
        salt: salt,
        opsLimit: kdfOpsLimit,
        memLimit: kdfMemLimit,
        alg: CryptoPwhashAlgorithm.argon2id13,
      )
      .extractBytes();

  Uint8List _valueAad(String envId, int keyVersion, String name) =>
      canonical(['harmonia.value', envId, '$keyVersion', name]);

  String encryptValue(
      Uint8List envKey, String envId, int keyVersion, String name, String value) {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = random(aead.nonceBytes);
    final ct = aead.encrypt(
      message: Uint8List.fromList(utf8.encode(value)),
      nonce: nonce,
      key: sodium.secureCopy(envKey),
      additionalData: _valueAad(envId, keyVersion, name),
    );
    return b64([...nonce, ...ct]);
  }

  String decryptValue(Uint8List envKey, String envId, int keyVersion,
      String name, String ciphertext) {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    try {
      final raw = unb64(ciphertext);
      final plain = aead.decrypt(
        cipherText: raw.sublist(aead.nonceBytes),
        nonce: raw.sublist(0, aead.nonceBytes),
        key: sodium.secureCopy(envKey),
        additionalData: _valueAad(envId, keyVersion, name),
      );
      return utf8.decode(plain);
    } catch (_) {
      throw DecryptException();
    }
  }

  /// XChaCha20-Poly1305：返回 nonce ‖ 密文。用于本机密钥保护（protocol 2.5）。
  Uint8List aeadSeal(Uint8List key, Uint8List msg, Uint8List aad) {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = random(aead.nonceBytes);
    final ct = aead.encrypt(
        message: msg, nonce: nonce, key: sodium.secureCopy(key), additionalData: aad);
    return Uint8List.fromList([...nonce, ...ct]);
  }

  Uint8List aeadOpen(Uint8List key, Uint8List box, Uint8List aad) {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    try {
      return aead.decrypt(
        cipherText: box.sublist(aead.nonceBytes),
        nonce: box.sublist(0, aead.nonceBytes),
        key: sodium.secureCopy(key),
        additionalData: aad,
      );
    } catch (_) {
      throw DecryptException();
    }
  }

  RecoveryKeys deriveRecovery(Uint8List code) => RecoveryKeys(
        signKeyFromSeed(hkdf(code, 'harmonia.recovery.sign')),
        boxKeyFromSeed(hkdf(code, 'harmonia.recovery.box')),
      );
}

// ---- 签名原文 ----

Uint8List deviceCertMsg(
        String deviceId, String kind, String signPub, String boxPub) =>
    canonical(['harmonia.device', deviceId, kind, signPub, boxPub]);

Uint8List envelopeMsg(
        String envId, int keyVersion, String recipient, List<int> sealed) =>
    canonical(
        ['harmonia.envelope', envId, '$keyVersion', recipient, b64(sha256(sealed))]);

Uint8List rootRecoveryMsg(int generation, List<int> sealed) =>
    canonical(['harmonia.root-recovery', '$generation', b64(sha256(sealed))]);

Uint8List authMsg(String deviceId, String nonce) =>
    canonical(['harmonia.auth', deviceId, nonce]);

Uint8List recoveryAuthMsg(String nonce) =>
    canonical(['harmonia.recovery-auth', nonce]);

// ---- 恢复码 ----

String formatRecoveryCode(List<int> code) => group4(base32Encode(code));

/// 解析用户输入的恢复码；格式不对时返回 null。
Uint8List? parseRecoveryCode(String input) {
  final s = normalizeCode(input);
  if (s.length != 26) return null;
  final b = base32Decode(s);
  return b != null && b.length == 16 ? b : null;
}

// ---- 配对 ----

Uint8List pairingFingerprint(
        String pairingId, String signPub, String boxPub, String rootPub) =>
    sha256(canonical(['harmonia.pairing', pairingId, signPub, boxPub, rootPub]));

String pairingCode(List<int> fp) => group4(base32Encode(fp.sublist(0, 10)));

String pairingQr(String pairingId, List<int> fp) =>
    'harmonia-pair:$pairingId:${b64(fp)}';

/// 解析二维码内容，返回 (pairingId, fingerprint)。
(String, Uint8List)? parsePairingQr(String s) {
  final parts = s.trim().split(':');
  if (parts.length != 3 || parts[0] != 'harmonia-pair') return null;
  try {
    final fp = unb64(parts[2]);
    return fp.length == 32 ? (parts[1], fp) : null;
  } catch (_) {
    return null;
  }
}

/// 规范化用户手输的恢复码或核对码：去掉分隔符和空白，转为大写，O 视为 0，I、L 视为 1。
String normalizeCode(String input) => input
    .toUpperCase()
    .replaceAll(RegExp(r'[\s-]'), '')
    .replaceAll('O', '0')
    .replaceAll(RegExp('[IL]'), '1');

/// 在后台 isolate 中计算密码派生密钥，避免界面卡顿。
Future<Uint8List> passwordKeyInIsolate(String password, Uint8List salt) =>
    Isolate.run(() async {
      final c = await HCrypto.init();
      return c.passwordKey(password, salt);
    });
