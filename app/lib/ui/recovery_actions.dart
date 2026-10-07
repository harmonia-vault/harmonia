// 恢复码的复制与下载 PDF。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/platform.dart';
import '../core/crypto.dart';
import '../core/recovery_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

class RecoveryCodeActions extends StatelessWidget {
  const RecoveryCodeActions({super.key, required this.c, required this.code});
  final AppController c;
  final List<int> code;

  Future<void> _copy(BuildContext context) async {
    await copySensitive(formatRecoveryCode(code));
    if (context.mounted) toast(context, '已复制。为了安全，1 分钟后会自动清空剪贴板');
  }

  Future<void> _download(BuildContext context) async {
    var saved = false;
    await runBusy(context, () async {
      final now = DateTime.now();
      final html = fillRecoverySheet(
        await rootBundle.loadString('assets/recovery_sheet.html'),
        email: c.prefs.email ?? '',
        server: c.server,
        code: code,
        date: now,
      );
      saved = await saveFile(recoverySheetFileName(now), 'application/pdf', await htmlToPdf(html));
    });
    if (saved && context.mounted) toast(context, '已保存。打印后请删除这个 PDF 文件');
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制'),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _download(context),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('下载 PDF'),
            ),
          ),
        ]),
        const SizedBox(height: Space.sm),
        Text('复制后 1 分钟会自动清空剪贴板。',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: context.palette.mute)),
      ]);
}
