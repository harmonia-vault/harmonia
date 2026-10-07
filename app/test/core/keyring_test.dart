import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/keyring.dart';
import 'package:harmonia/core/store.dart';
import 'package:harmonia/core/vault.dart';

/// 软件实现的“Keystore”：不同实例代表不同手机上的硬件密钥。
class FakeHardware implements HardwareKeys {
  FakeHardware(this.secret);
  final List<int> secret;
  int deleted = 0;
  @override
  Future<Uint8List> pinMac(Uint8List input) async =>
      Uint8List.fromList(hash.Hmac(hash.sha256, secret).convert(input).bytes);
  @override
  Future<void> deleteAll() async => deleted++;
}

void main() {
  late HCrypto c;
  late MemoryStore store;
  late FakeHardware hw;
  late DateTime now;

  setUpAll(() async => c = await HCrypto.init());
  setUp(() {
    store = MemoryStore();
    hw = FakeHardware(utf8.encode('phone-a'));
    now = DateTime(2026, 10, 7, 12);
  });

  // 测试中直接同步计算 Argon2id，不开 isolate。
  Keyring ring([HardwareKeys? h]) =>
      Keyring(c, store, h ?? hw, derive: (p, s) async => c.passwordKey(p, s), now: () => now);

  test('PIN 格式', () {
    expect(Keyring.validPin('123456'), isTrue);
    expect(Keyring.validPin('1234567890123456'), isTrue);
    expect(Keyring.validPin('12345'), isFalse);
    expect(Keyring.validPin('12345678901234567'), isFalse);
    expect(Keyring.validPin('12345a'), isFalse);
  });

  test('正确的 PIN 解开同一把本机数据密钥', () async {
    final key = await ring().create('246810');
    expect(await ring().hasPin(), isTrue);
    final r = await ring().unlock('246810');
    expect(r.ok, isTrue);
    expect(r.key, key);
  });

  test('不保存可以离线核对 PIN 的哈希，只保存封装后的密钥', () async {
    await ring().create('246810');
    final slot = jsonDecode((await store.read('pinSlot'))!) as Map;
    expect(slot.keys.toSet(), {'salt', 'box'});
  });

  test('换一台手机的硬件密钥，即使 PIN 正确也解不开', () async {
    await ring().create('246810');
    final other = await ring(FakeHardware(utf8.encode('phone-b'))).unlock('246810');
    expect(other.ok, isFalse);
  });

  test('输错 5 次后需要等待，等待时间翻倍，重新创建实例也不清零', () async {
    await ring().create('246810');
    for (var left = 4; left >= 1; left--) {
      final r = await ring().unlock('000000');
      expect(r.ok, isFalse);
      expect(r.remaining, left);
      expect(r.waitSeconds, 0);
    }
    expect((await ring().unlock('000000')).waitSeconds, 30);
    // 等待期间，正确的 PIN 也不会被尝试。
    expect((await ring().unlock('246810')).waitSeconds, 30);
    now = now.add(const Duration(seconds: 31));
    expect((await ring().unlock('000000')).waitSeconds, 60);
    now = now.add(const Duration(seconds: 61));
    final ok = await ring().unlock('246810');
    expect(ok.ok, isTrue);
    // 成功后计数清零。
    expect((await ring().unlock('000000')).remaining, 4);
  });

  test('等待时间最长 30 分钟', () async {
    await ring().create('246810');
    var last = 0;
    for (var i = 0; i < 15; i++) {
      final r = await ring().unlock('000000');
      last = r.waitSeconds;
      now = now.add(Duration(seconds: r.waitSeconds + 1));
    }
    expect(last, 1800);
  });

  test('修改 PIN 后旧 PIN 失效，密钥不变', () async {
    final key = await ring().create('246810');
    await ring().changePin(key, '13579135');
    expect((await ring().unlock('246810')).ok, isFalse);
    expect((await ring().unlock('13579135')).key, key);
  });

  test('重新创建会作废指纹槽', () async {
    await ring().create('246810');
    await ring().saveBioSlot('slot');
    expect(await ring().bioSlot(), 'slot');
    await ring().create('112233');
    expect(await ring().bioSlot(), isNull);
  });

  test('清除删除全部槽和硬件密钥', () async {
    await ring().create('246810');
    await ring().saveBioSlot('slot');
    await ring().wipe();
    expect(await ring().hasPin(), isFalse);
    expect(await ring().bioSlot(), isNull);
    expect(hw.deleted, 1);
  });

  test('本机配置用本机数据密钥加密保存，换密钥解不开', () async {
    final files = MemoryStore();
    final vault = Vault(c, store, files)..localKey = c.random(32);
    final cfg = LocalConfig(
      server: 'https://example.test',
      accountId: c.newId(),
      email: 'a@example.test',
      rootPub: b64(c.random(32)),
      deviceId: c.newId(),
      deviceName: '测试手机',
      signSeed: b64(c.random(32)),
      boxSeed: b64(c.random(32)),
    );
    final key = vault.localKey!;
    await store.write('account', b64(c.aeadSeal(key, Uint8List.fromList(utf8.encode(jsonEncode(cfg.toJson()))),
        canonical(['harmonia.local', 'config']))));
    expect(await vault.hasAccount(), isTrue);
    expect((await store.read('account'))!.contains(cfg.signSeed), isFalse);

    vault.lock();
    expect(vault.config, isNull);
    vault.localKey = key;
    expect(await vault.load(), isTrue);
    expect(vault.config!.signSeed, cfg.signSeed);

    vault.lock();
    vault.localKey = c.random(32);
    expect(vault.load, throwsA(isA<DecryptException>()));
  });
}
