// Android 和 iOS 共用的更新下载反馈；仅显示状态，不访问网络或文件。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'glass_overlays.dart';
import 'theme.dart';

enum DownloadPhase { connecting, receiving, verifying }

class DownloadProgress {
  const DownloadProgress({required this.total, this.received = 0, this.phase = DownloadPhase.connecting});
  final int total, received;
  final DownloadPhase phase;

  double get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
}

class DownloadProgressDialog extends StatelessWidget {
  const DownloadProgressDialog({super.key, required this.progress});
  final ValueListenable<DownloadProgress> progress;

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: const Text('下载更新'),
    content: SizedBox(
      width: 320,
      child: ValueListenableBuilder<DownloadProgress>(
        valueListenable: progress,
        builder: (context, value, _) {
          final receiving = value.phase == DownloadPhase.receiving;
          final percent = '${(value.fraction * 100).floor()}%';
          final label = switch (value.phase) {
            DownloadPhase.connecting => '正在连接下载服务器…',
            DownloadPhase.receiving => '正在下载安装包',
            DownloadPhase.verifying => '正在校验安装包…',
          };
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label),
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: receiving ? value.fraction : null,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                semanticsLabel: label,
                semanticsValue: receiving ? percent : null,
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 16,
                runSpacing: 8,
                children: [
                  Text(
                    '${_size(value.received)} / ${_size(value.total)}',
                    style: TextStyle(color: context.palette.mute),
                  ),
                  if (receiving) Text(percent, style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          );
        },
      ),
    ),
  );
}

String _size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
