// 恢复码的复制，以及提交成功后的完成页（下载 PDF）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/platform.dart';
import '../core/crypto.dart';
import '../core/recovery_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

/// 复制恢复码：剪贴板预览中隐藏，1 分钟后自动清空。
class CopyRecoveryCode extends StatelessWidget {
  const CopyRecoveryCode({super.key, required this.code});
  final List<int> code;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        OutlinedButton.icon(
          onPressed: () async {
            await copySensitive(formatRecoveryCode(code));
            if (context.mounted) toast(context, '已复制。为了安全，1 分钟后会自动清空剪贴板');
          },
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制'),
        ),
        const SizedBox(height: Space.sm),
        Text('复制后 1 分钟会自动清空剪贴板。',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: context.palette.mute)),
      ]);
}

/// 恢复码提交成功后的完成页：此时恢复码已经生效，才提供下载 PDF。
class RecoveryDoneView extends StatelessWidget {
  const RecoveryDoneView({
    super.key,
    required this.c,
    required this.code,
    required this.title,
    required this.subtitle,
    required this.onDone,
  });
  final AppController c;
  final List<int> code;
  final String title, subtitle;
  final VoidCallback onDone;

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
  Widget build(BuildContext context) => AuthScaffold(
        title: title,
        subtitle: subtitle,
        children: [
          const Text('需要纸质备份的话，可以下载包含这个恢复码的 PDF 打印。PDF 只在这里提供一次。'),
          const SizedBox(height: Space.lg),
          OutlinedButton.icon(
            onPressed: () => _download(context),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('下载 PDF'),
          ),
          const SizedBox(height: Space.md),
          FilledButton(onPressed: onDone, child: const Text('完成')),
        ],
      );
}
