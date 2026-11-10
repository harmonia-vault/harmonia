// 环境详情：最终的变量（来自哪个变量库，点一个弹出变量面板）、同名被遮住和引用失效的提示、引用的变量库、可访问的电脑。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/crypto.dart' show VarEntry;
import '../core/models.dart';
import 'env_editor.dart';
import 'env_var_sheet.dart';
import 'glass.dart';
import 'glass_overlays.dart';
import 'list_row.dart';
import 'theme.dart';
import 'vaults.dart';
import 'widgets.dart';

/// 引用的范围说明，例如“全部变量”。
String refSummary(EnvRef r) => r.all ? '全部变量' : '选中 ${r.items.length} 个变量';

/// 环境里需要处理的问题：同名变量被遮住、引用的变量库已删除。
List<String> envProblems(AppController c, String envId) {
  final env = c.vault.environment(envId);
  final def = c.vault.envDef(envId);
  String vault(String id) => '“${c.vault.vaultName(id) ?? '已删除的变量库'}”';
  final used = {for (final i in env.items) i.name: i.vaultId};
  return [
    for (final s in env.shadowed)
      '${s.name} 用的是${vault(used[s.name] ?? '')}里的，${vault(s.vaultId)}里的同名变量没有生效。调整引用顺序或给其中一个改名。',
    if (def != null && def.refs.any((r) => r.missing))
      '有 ${def.refs.where((r) => r.missing).length} 个引用的变量库已被删除，不再提供变量。编辑引用后移除。',
  ];
}

class EnvironmentPage extends StatefulWidget {
  const EnvironmentPage({super.key, required this.c, required this.envId});
  final AppController c;
  final String envId;
  @override
  State<EnvironmentPage> createState() => _EnvironmentPageState();
}

class _EnvironmentPageState extends State<EnvironmentPage> with LeaveWhenGone {
  @override
  AppController get c => widget.c;

  @override
  bool get exists => c.vault.environments.any((e) => e.id == widget.envId);

  void _editRefs() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => EnvEditorPage(c: c, envId: widget.envId),
    ),
  );

  Future<void> _menu(String action, Environment env) async {
    if (action == 'refs') {
      _editRefs();
    } else if (action == 'rename') {
      final name = await askName(context, title: '重命名环境', initial: env.name);
      final def = c.vault.envDef(env.id);
      if (name == null || def == null || !mounted) return;
      await runBusy(context, () => c.guard(() => c.vault.saveEnvironment(env.id, name, def.refs)));
    } else if (action == 'delete') {
      final ok = await confirmDialog(
        context,
        title: '删除环境“${env.name}”？',
        body: '变量库和其中的变量不受影响。已授权这个环境的电脑会失去它，下次同步时移除这些变量。',
        ok: '删除',
        danger: true,
      );
      if (!ok || !mounted) return;
      await runDelete(() => c.vault.deleteEnvironment(env.id), '已删除环境');
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = c.vault.environments.where((e) => e.id == widget.envId).firstOrNull;
    if (env == null) return const Scaffold();
    final def = c.vault.envDef(env.id);
    final p = context.palette;
    Map<String, VarEntry> values;
    final broken = <String>{};
    String? error;
    try {
      values = c.vault.envEntries(env.id);
      for (final i in env.items) {
        if (c.vault.brokenVariables(i.vaultId).contains(i.source)) broken.add(i.name);
      }
    } catch (e) {
      values = {};
      error = errorText(e);
    }
    String origin(EnvItem i) {
      final from = '来自 ${c.vault.vaultName(i.vaultId) ?? '已删除的变量库'}';
      return i.name == i.source ? from : '$from · 原名 ${i.source}';
    }

    final devices = c.vault.devices.where((d) => !d.isManager && d.grants.any((g) => g.envId == env.id)).toList();
    return AppPage(
      appBar: AppBarSurface(
        title: Text(env.name),
        actions: [
          AppMenuButton(
            onSelected: (a) => _menu(a, env),
            items: const [
              (value: 'refs', label: '编辑引用', icon: Icons.tune, danger: false),
              (value: 'rename', label: '重命名', icon: Icons.edit_outlined, danger: false),
              (value: 'delete', label: '删除环境', icon: Icons.delete_outline, danger: true),
            ],
          ),
        ],
      ),
      body: (context) => ListView(
        padding: pagePadding(context, const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96)),
        children: [
          if (error != null) Banner2(error, warn: true),
          for (final msg in envProblems(c, env.id))
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Banner2(msg, warn: true),
            ),
          SectionTitle('变量（${env.items.length}）'),
          if (env.items.isEmpty)
            EmptyState(
              icon: Icons.key_off_outlined,
              title: '这个环境还没有变量',
              body: '编辑引用，选择要用的变量库和变量。',
              action: FilledButton(onPressed: _editRefs, child: const Text('编辑引用')),
            )
          else
            VariableList(
              rows: [
                for (final i in env.items)
                  (
                    name: i.name,
                    entry: broken.contains(i.name) ? null : values[i.name],
                    origin: origin(i),
                    onTap: () => showEnvVariableSheet(
                      context,
                      c: c,
                      envId: env.id,
                      item: i,
                      entry: broken.contains(i.name) ? null : values[i.name],
                    ),
                  ),
              ],
            ),
          if (env.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.xs, Space.sm, Space.xs, 0),
              child: Text(tidy('点一个变量可以改名、移除或修改值。新增变量请到变量库里添加。'), style: TextStyle(color: p.mute, fontSize: 13)),
            ),
          SectionTitle(
            '引用的变量库（${def?.refs.length ?? 0}）',
            trailing: TextButton(onPressed: _editRefs, child: const Text('编辑')),
          ),
          if (def == null || def.refs.isEmpty)
            Text('还没有引用变量库。', style: TextStyle(color: p.mute))
          else
            Card(
              child: Column(
                children: [
                  for (final (i, r) in def.refs.indexed) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      contentPadding: listRowPadding,
                      leading: Icon(r.missing ? Icons.link_off : Icons.inventory_2_outlined),
                      title: Text(r.missing ? '已删除的变量库' : c.vault.vaultName(r.vaultId) ?? ''),
                      subtitle: Text(r.missing ? '不再提供变量，编辑引用后移除' : refSummary(r)),
                      trailing: r.missing ? null : const ListRowChevron(),
                      onTap: r.missing
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => VaultPage(c: c, vaultId: r.vaultId),
                              ),
                            ),
                    ),
                  ],
                ],
              ),
            ),
          SectionTitle('可访问的电脑（${devices.length}）'),
          if (devices.isEmpty)
            Text(tidy('还没有电脑可以访问这个环境。在“设备”中添加电脑或调整权限。'), style: TextStyle(color: p.mute))
          else
            Card(
              child: Column(
                children: [
                  for (final (i, d) in devices.indexed) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      leading: const Icon(Icons.laptop_mac_outlined),
                      title: Text(d.name),
                      subtitle: Text(() {
                        final g = d.grants.firstWhere((g) => g.envId == env.id);
                        return [
                          roleNames[g.role],
                          if (g.localDecrypt || g.expiresAt != 0) formatExpiry(g.expiresAt),
                          g.localDecrypt ? '无人值守（本机解密）' : '需手机批准',
                        ].join(' · ');
                      }()),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
