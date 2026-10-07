// 恢复码 PDF：把账号信息与恢复码填入 HTML 模板（assets/recovery_sheet.html）。
import 'crypto.dart';

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 填充模板。恢复码分两行，每组一个 span，组间的短横由模板样式绘制。
String fillRecoverySheet(
  String template, {
  required String email,
  required String server,
  required List<int> code,
  required DateTime date,
}) {
  final groups = formatRecoveryCode(code).split('-');
  String line(Iterable<String> gs) =>
      '<div>${gs.map((g) => '<span class="g">$g</span>').join()}</div>';
  final values = {
    'EMAIL': _escape(email),
    'SERVER': _escape(server),
    'DATE': _date(date),
    'CODE': line(groups.take(4)) + line(groups.skip(4)),
  };
  // 一次替换，避免填入的内容里恰好含有占位符时被再次替换。
  return template.replaceAllMapped(
      RegExp(r'\{\{(\w+)\}\}'), (m) => values[m[1]] ?? m[0]!);
}

/// 保存时建议的文件名。
String recoverySheetFileName(DateTime date) => 'Harmonia-恢复码-${_date(date)}.pdf';
