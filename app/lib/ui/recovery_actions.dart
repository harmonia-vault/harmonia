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

/// 恢复码提交成功后的完成页：此时恢复码已经生效，才提供下载 PDF；保存 PDF 之后才能继续。
class RecoveryDoneView extends StatefulWidget {
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

  @override
  State<RecoveryDoneView> createState() => _RecoveryDoneViewState();
}

class _RecoveryDoneViewState extends State<RecoveryDoneView> {
  bool _saved = false;

  Future<void> _download() async {
    var saved = false;
    await runBusy(context, () async {
      final now = DateTime.now();
      final html = fillRecoverySheet(
        await rootBundle.loadString('assets/recovery_sheet.html'),
        email: widget.c.prefs.email ?? '',
        server: widget.c.server,
        code: widget.code,
        date: now,
      );
      saved = await saveFile(recoverySheetFileName(now), 'application/pdf', await htmlToPdf(html));
    });
    if (!saved || !mounted) return;
    setState(() => _saved = true);
    toast(context, '已保存。打印后请删除这个 PDF 文件');
  }

  // 保存 PDF 之前，返回手势也不能离开这一页。
  @override
  Widget build(BuildContext context) => PopScope(
        canPop: _saved,
        child: AuthScaffold(
          title: widget.title,
          subtitle: widget.subtitle,
          children: [
            Banner2(
              _saved
                  ? 'PDF 已保存。打印后请删除文件，并把纸质备份放在安全的地方。'
                  : '请下载包含这个恢复码的 PDF 并保存，保存后才能继续。PDF 只在这里提供一次。',
              warn: !_saved,
            ),
            const SizedBox(height: Space.lg),
            OutlinedButton.icon(
              onPressed: _download,
              icon: Icon(_saved ? Icons.check : Icons.picture_as_pdf_outlined),
              label: Text(_saved ? '已保存，再次下载' : '下载 PDF'),
            ),
            const SizedBox(height: Space.md),
            FilledButton(onPressed: _saved ? widget.onDone : null, child: const Text('完成')),
          ],
        ),
      );
}
