// 仅推进内存中的下载状态；不接触真实网络、文件、安装器或分享面板。
import 'package:flutter/material.dart';

import '../ui/app_scope.dart';
import '../ui/download_progress.dart';
import '../ui/widgets.dart';

Future<void> simulateUpdateDownload(BuildContext context, {bool fail = false}) async {
  if (!AppScope.isSimulated(context)) throw StateError('模拟下载只能在页面调试中运行');
  const total = 48 * 1024 * 1024;
  final progress = ValueNotifier(const DownloadProgress(total: total));
  try {
    await runBusy(
      context,
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        for (var step = 0; step <= 20; step++) {
          if (!context.mounted) return;
          if (fail && step == 12) throw Exception('模拟下载中断，请重试。不会下载真实安装包。');
          progress.value = DownloadProgress(total: total, received: total * step ~/ 20, phase: DownloadPhase.receiving);
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        if (!context.mounted) return;
        progress.value = const DownloadProgress(total: total, received: total, phase: DownloadPhase.verifying);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      },
      done: '模拟下载与校验完成，未安装或分享真实文件',
      progressBuilder: (_) => DownloadProgressDialog(progress: progress),
    );
  } finally {
    progress.dispose();
  }
}
