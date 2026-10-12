// 按词折行：分词结果与 BudouX 参考实现一致，同一个词的汉字之间不能断行。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/phrases.dart';

void main() {
  final breaker = PhraseBreaker.fromJson(File('assets/budoux/zh-hans.json').readAsStringSync());
  const j = PhraseBreaker.joiner;

  test('分词结果与 BudouX 参考实现一致', () {
    expect(breaker.words('只有在密码、恢复码和所有管理设备都丢失时才需要重置。').join('/'),
        '只/有/在/密码、/恢复码/和/所有/管理/设备/都/丢失/时/才/需要/重置。');
    expect(breaker.words('这台手机上保存的密钥由它加密，与手机锁屏密码无关。').join('/'),
        '这/台/手机/上/保存/的/密钥/由/它/加密，/与/手机/锁/屏/密码/无关。');
    expect(breaker.words(''), isEmpty);
  });

  test('同一个词的汉字之间不能断行，词与词之间可以', () {
    final out = breaker.glue('都丢失时才需要重置。');
    expect(out, contains('需$j要'));
    expect(out, contains('重$j置'));
    expect(out, contains('才需'));
    expect(out.replaceAll(j, ''), '都丢失时才需要重置。');
  });

  test('模型拆开的常用词仍然连在一起', () {
    final out = breaker.glue('这台手机只能用它找回数据。');
    for (final word in ['这$j台', '只$j能', '找$j回', '数$j据']) {
      expect(out, contains(word));
    }
  });

  test('英文、数字和标点不动，每一行单独处理', () {
    expect(breaker.glue('App'), 'App');
    final out = breaker.glue('打开 Harmonia 之后再输入密码。\n输入 App PIN。');
    expect(out.split('\n'), hasLength(2));
    expect(out.replaceAll(j, ''), '打开 Harmonia 之后再输入密码。\n输入 App PIN。');
    expect(out, isNot(contains('H$j')));
  });

  test('每一行末尾的四个字连在一起，短行不处理', () {
    expect(breaker.glue('无法撤销，也无法找回。'), endsWith('法$j找$j回$j。'));
    expect(breaker.glue('已保存。'), isNot(contains('$j。')));
  });
}
