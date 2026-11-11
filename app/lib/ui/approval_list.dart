// “设备”页上的待批准请求列表（设计文档 17.4）。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'approval.dart';
import 'devices.dart' show platformIcon, platformName;
import 'list_row.dart';
import 'theme.dart';
import 'workspace_scope.dart';

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
                selected: WorkspaceScope.maybeOf(context)?.selected[2]?.id == 'approval:${a.id}',
                onTap: () => openWorkspaceEntry(
                  context,
                  WorkspaceEntry(
                    tab: 2,
                    id: 'approval:${a.id}',

                    page: (_) => ApprovalPage(c: c, request: a),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
