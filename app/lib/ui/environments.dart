// “环境”标签页：上面是环境（电脑使用的变量集合），下面是变量库（变量实际保存的地方）。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'env_editor.dart';
import 'env_page.dart';
import 'glass.dart';
import 'glass_overlays.dart';
import 'list_row.dart';
import 'theme.dart';
import 'vaults.dart';
import 'widgets.dart';

export 'vaults.dart' show askName;

class EnvironmentsTab extends StatelessWidget {
  const EnvironmentsTab({super.key, required this.c});
  final AppController c;

  void _create(BuildContext context, String what) {
    if (what == 'vault') {
      createVaultFlow(context, c);
    } else if (c.vault.vaults.isEmpty) {
      toast(context, '先新建一个变量库，环境里的变量来自变量库');
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => EnvEditorPage(c: c)));
    }
  }

  static const _createItems = [
    (value: 'env', label: '新建环境', icon: Icons.layers_outlined, danger: false),
    (value: 'vault', label: '新建变量库', icon: Icons.inventory_2_outlined, danger: false),
  ];

  @override
  Widget build(BuildContext context) {
    final envs = c.vault.environments;
    final vaults = c.vault.vaults;
    final empty = envs.isEmpty && vaults.isEmpty;
    final p = context.palette;
    int computers(String envId) =>
        c.vault.devices.where((d) => !d.isManager && d.grants.any((g) => g.envId == envId)).length;
    Widget envSubtitle(Environment e) {
      if (envProblems(c, e.id).isNotEmpty) {
        return Text('${e.items.length} 个变量 · 有问题需要处理', style: TextStyle(color: p.accent));
      }
      return Text('${e.items.length} 个变量 · ${computers(e.id)} 台电脑可访问');
    }

    return AppTabPage(
      title: '环境',
      actions: [
        AppMenuButton(
          semanticLabel: '新建',
          items: _createItems,
          onSelected: (v) => _create(context, v),
          trigger: (context, open) => IconButton(tooltip: '新建', onPressed: open, icon: const Icon(Icons.add)),
        ),
      ],
      floatingActionButton: empty
          ? null
          : AppMenuButton(
              semanticLabel: '新建',
              items: _createItems,
              onSelected: (v) => _create(context, v),
              trigger: (context, open) =>
                  FloatingActionButton.extended(onPressed: open, icon: const Icon(Icons.add), label: const Text('新建')),
            ),
      onRefresh: c.syncNow,
      padding: empty ? EdgeInsets.zero : const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96),
      children: empty
          ? [
              EmptyState(
                icon: Icons.inventory_2_outlined,
                title: '还没有变量',
                body: '变量保存在变量库里，例如“OpenAI”。\n电脑通过环境使用变量：一个环境可以引用一个或多个变量库，再授权给电脑。',
                action: FilledButton(onPressed: () => createVaultFlow(context, c), child: const Text('新建变量库')),
              ),
            ]
          : [
              SectionTitle('环境（${envs.length}）'),
              if (envs.isEmpty)
                Text(tidy('还没有环境。新建一个环境，选择要用的变量库，再在“设备”里授权给电脑。'), style: TextStyle(color: p.mute))
              else
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
                          subtitle: envSubtitle(e),
                          trailing: const ListRowChevron(),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => EnvironmentPage(c: c, envId: e.id),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              SectionTitle('变量库（${vaults.length}）'),
              if (vaults.isEmpty)
                Text('还没有变量库。', style: TextStyle(color: p.mute))
              else
                Card(
                  child: Column(
                    children: [
                      for (final (i, v) in vaults.indexed) ...[
                        if (i > 0) const Divider(),
                        ListTile(
                          contentPadding: listRowPadding.copyWith(top: Space.xs, bottom: Space.xs),
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(v.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            () {
                              final used = [
                                for (final e in c.vault.envDefs)
                                  if (e.refs.any((r) => r.vaultId == v.id)) e.name,
                              ];
                              final n = '${c.vault.variableNames(v.id).length} 个变量';
                              return used.isEmpty ? '$n · 没有环境用到' : '$n · 用在 ${used.join('、')}';
                            }(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
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
