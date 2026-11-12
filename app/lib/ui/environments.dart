// “环境”标签页：电脑使用的变量集合，引用变量库里的变量。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'env_editor.dart';
import 'env_page.dart';
import 'glass.dart';
import 'list_row.dart';
import 'theme.dart';
import 'widgets.dart';
import 'workspace_scope.dart';
import 'adaptive_presentation.dart';

class EnvironmentsTab extends StatelessWidget {
  const EnvironmentsTab({super.key, required this.c});
  final AppController c;

  void _create(BuildContext context) {
    if (c.vault.vaults.isEmpty) {
      toast(context, '先在“变量库”里新建一个变量库，环境里的变量来自变量库');
    } else {
      openEditorPage(context, (_) => EnvEditorPage(c: c));
    }
  }

  @override
  Widget build(BuildContext context) {
    final envs = c.vault.environments;
    final p = context.palette;
    int computers(String envId) =>
        c.vault.devices.where((d) => !d.isManager && d.grants.any((g) => g.envId == envId)).length;
    Widget subtitle(Environment e) {
      if (envProblems(c, e.id).isNotEmpty) {
        return Text('${e.items.length} 个变量 · 有问题需要处理', style: TextStyle(color: p.accent));
      }
      return Text('${e.items.length} 个变量 · ${computers(e.id)} 台电脑可访问');
    }

    return AppTabPage(
      title: '环境',
      actions: [
        GlassBarItem.icon(id: '新建环境', label: '新建环境', onTap: () => _create(context), icon: const Icon(Icons.add)),
      ],

      onRefresh: c.syncNow,
      padding: envs.isEmpty ? EdgeInsets.zero : const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96),
      children: envs.isEmpty
          ? [
              EmptyState(
                icon: Icons.layers_outlined,
                title: '还没有环境',
                body: '环境引用变量库里的变量，在“设备”里授权给电脑后，电脑就能使用。',
                action: FilledButton(onPressed: () => _create(context), child: const Text('新建环境')),
              ),
            ]
          : [
              Card(
                child: Column(
                  children: [
                    for (final (i, e) in envs.indexed) ...[
                      if (i > 0) const Divider(),
                      ListTile(
                        contentPadding: listRowPadding.copyWith(top: Space.xs, bottom: Space.xs),
                        leading: CircleAvatar(
                          backgroundColor: i.isEven ? p.yellow : p.sage,
                          foregroundColor: Palette.light.ink,
                          child: Text(e.name.characters.first.toUpperCase()),
                        ),
                        title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: subtitle(e),
                        trailing: const ListRowChevron(),
                        selected: WorkspaceScope.maybeOf(context)?.selected[1]?.id == 'env:${e.id}',
                        onTap: () => selectWorkspaceEntry(
                          context,
                          WorkspaceEntry(
                            tab: 1,
                            id: 'env:${e.id}',

                            page: (_) => EnvironmentPage(c: c, envId: e.id),
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
