import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/recovery_sheet.dart';

void main() {
  final code = Uint8List.fromList(List.generate(16, (i) => i * 17));
  final date = DateTime(2026, 3, 7);

  test('填入全部占位符，恢复码按组分两行', () {
    final template = File('assets/recovery_sheet.html').readAsStringSync();
    final html = fillRecoverySheet(template,
        email: 'demo@example.com', server: 'https://harmonia.example.com', code: code, date: date);
    expect(html, isNot(contains('{{')));
    expect(html, contains('demo@example.com'));
    expect(html, contains('生成于 2026-03-07'));
    final groups = formatRecoveryCode(code).split('-');
    expect(RegExp('<span class="g">').allMatches(html).length, groups.length);
    expect(html, contains('<div>${groups.take(4).map((g) => '<span class="g">$g</span>').join()}</div>'));
  });

  test('转义填入的内容，不会二次替换', () {
    final html = fillRecoverySheet('{{EMAIL}}|{{SERVER}}',
        email: '<a>&"{{SERVER}}', server: 'x', code: code, date: date);
    expect(html, '&lt;a&gt;&amp;&quot;{{SERVER}}|x');
  });

  test('文件名带日期', () {
    expect(recoverySheetFileName(date), 'Harmonia-恢复码-2026-03-07.pdf');
  });
}
