// “变量库”标签页：变量实际保存的地方，打开 App 时的默认页。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'glass.dart';
import 'list_row.dart';
import 'theme.dart';
import 'vaults.dart';
import 'widgets.dart';

class VaultsTab extends StatelessWidget {
  const VaultsTab({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final vaults = c.vault.vaults;
    String subtitle(String vaultId) {
      final used = [
        for (final e in c.vault.envDefs)
          if (e.refs.any((r) => r.vaultId == vaultId)) e.name,
      ];
      final n = '${c.vault.variableNames(vaultId).length} 个变量';
      return used.isEmpty ? '$n · 没有环境用到' : '$n · 用在 ${used.join('、')}';
    }

    return AppTabPage(
      title: '变量库',
      actions: [
        IconButton(tooltip: '新建变量库', onPressed: () => createVaultFlow(context, c), icon: const Icon(Icons.add)),
      ],

      onRefresh: c.syncNow,
      padding: vaults.isEmpty ? EdgeInsets.zero : const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96),
      children: vaults.isEmpty
          ? [
              EmptyState(
                icon: Icons.inventory_2_outlined,
                title: '还没有变量库',
                body: '变量保存在变量库里，例如“OpenAI”“博客生产”。',
                action: FilledButton(onPressed: () => createVaultFlow(context, c), child: const Text('新建变量库')),
              ),
            ]
          : [
              const SizedBox(height: Space.md),
              Card(
                child: Column(
                  children: [
                    for (final (i, v) in vaults.indexed) ...[
                      if (i > 0) const Divider(),
                      ListTile(
                        contentPadding: listRowPadding.copyWith(top: Space.xs, bottom: Space.xs),
                        leading: const Icon(Icons.inventory_2_outlined),
                        title: Text(v.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(subtitle(v.id), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const ListRowChevron(),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VaultPage(c: c, vaultId: v.id),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
    );
  }
}
