// “设备”页上的待批准请求列表，以及升级后一次性的“本机解密”提示（设计文档 17.3、17.4）。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'approval.dart';
import 'devices.dart' show platformIcon, platformName;
import 'list_row.dart';
import 'theme.dart';
import 'widgets.dart';

/// 电脑发来的、还在等待的批准请求；点开进入批准页。
class PendingApprovals extends StatelessWidget {
  const PendingApprovals({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final a in c.approvals)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Card(
              color: context.palette.yellow.withValues(alpha: 0.35),
              child: ListTile(
                contentPadding: listRowPadding,
                leading: Icon(platformIcon(c.vault.approvalDevice(a)?.platform ?? '')),
                title: Text(c.vault.approvalDevice(a)?.name ?? '未知设备'),
                subtitle: Text(
                  '${platformName(c.vault.approvalDevice(a)?.platform ?? '')} · '
                  '${a.isWrite ? '请求写入' : '请求使用'} ${a.items.length + a.deletes.length} 个变量 · 请求码 ${a.code}',
                ),
                trailing: const ListRowChevron(),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ApprovalPage(c: c, request: a),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 列出开启了本机解密的电脑和环境，说明默认的手机批准方式更安全。看过一次后不再显示，不自动关闭任何授权。
class LocalDecryptHint extends StatelessWidget {
  const LocalDecryptHint({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    if (c.prefs.localDecryptHintSeen) return const SizedBox.shrink();
    final lines = <String>[];
    for (final d in c.vault.devices.where((d) => !d.isManager)) {
      final envs = [
        for (final g in d.grants)
          if (g.localDecrypt) c.vault.envDef(g.envId)?.name ?? '未知环境',
      ];
      if (envs.isNotEmpty) lines.add('${d.name}：${envs.join('、')}');
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('这些电脑开启了本机解密', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: Space.sm),
              Text(lines.join('\n')),
              const SizedBox(height: Space.sm),
              Text(
                tidy(
                  '开启本机解密的电脑保存着变量库的钥匙。现在默认改为每次在手机上批准，电脑上不保存任何能解开变量的东西，更安全。'
                  '服务器、CI 这类无法等待批准的电脑可以保持开启；其他的可以在设备详情里逐个关闭。',
                ),
                style: TextStyle(color: context.palette.mute, height: 1.5),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: c.markLocalDecryptHintSeen, child: const Text('知道了')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
