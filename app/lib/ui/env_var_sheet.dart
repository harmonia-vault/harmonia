// 环境详情里点一个变量弹出的面板：改名（只影响这个环境）、从环境中移除、编辑值和备注（设计文档 19.4）。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/crypto.dart' show VarEntry;
import '../core/models.dart';
import '../core/refs.dart' show removeFromRefs, renameInRefs;
import 'app_sheet.dart';
import 'env_editor.dart' show askAlias;
import 'glass.dart';
import 'list_row.dart';
import 'theme.dart';
import 'variable_edit.dart';
import 'widgets.dart';

/// 打开 [envId] 里变量 [item] 的面板；[entry] 为 null 表示解不开。
Future<void> showEnvVariableSheet(
  BuildContext context, {
  required AppController c,
  required String envId,
  required EnvItem item,
  required VarEntry? entry,
}) {
  final nav = Navigator.of(context);
  return showAppSheet<void>(
    context,
    builder: (sheet) => _EnvVariableSheet(c: c, envId: envId, item: item, entry: entry, pageNav: nav),
  );
}

class _EnvVariableSheet extends StatelessWidget {
  const _EnvVariableSheet({
    required this.c,
    required this.envId,
    required this.item,
    required this.entry,
    required this.pageNav,
  });
  final AppController c;
  final String envId;
  final EnvItem item;
  final VarEntry? entry;

  /// 环境详情页所在的导航，“编辑值和备注”在面板关闭后从这里打开。
  final NavigatorState pageNav;

  String get _vault => c.vault.vaultName(item.vaultId) ?? '已删除的变量库';

  /// 用改过的引用保存环境，成功后关闭面板。
  Future<void> _saveRefs(BuildContext context, List<EnvRef> refs, String done) async {
    final def = c.vault.envDef(envId);
    if (def == null) return;
    final nav = Navigator.of(context);
    final ok = await runBusy(context, () => c.guard(() => c.vault.saveEnvironment(envId, def.name, refs)), done: done);
    if (ok) nav.pop();
  }

  Future<void> _rename(BuildContext context) async {
    final def = c.vault.envDef(envId);
    if (def == null) return;
    final alias = await askAlias(context, item.source, item.name == item.source ? null : item.name);
    if (alias == null || !context.mounted) return;
    final as = alias.isEmpty ? null : alias;
    if ((as ?? item.source) == item.name) return;
    await _saveRefs(context, renameInRefs(def.refs, item.vaultId, item.source, as), '已改名为 ${as ?? item.source}');
  }

  Future<void> _remove(BuildContext context, List<EnvRef> refs) async {
    final ok = await confirmDialog(
      context,
      title: '从环境中移除 ${item.name}？',
      body: '变量库“$_vault”里的变量不受影响。已授权这个环境的电脑下次同步后不再拿到它。',
      ok: '移除',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    await _saveRefs(context, refs, '已从环境中移除 ${item.name}');
  }

  void _editValue(BuildContext context) {
    Navigator.of(context).pop();
    pageNav.push(
      MaterialPageRoute(
        builder: (_) => VariableEditPage(c: c, vaultId: item.vaultId, name: item.source),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glass = usesGlass(context);
    final def = c.vault.envDef(envId);
    final removed = def == null ? null : removeFromRefs(def.refs, item.vaultId, item.source);
    final note = entry?.note ?? '';
    final from = item.name == item.source ? '来自“$_vault”' : '来自“$_vault” · 原名 ${item.source}';
    return SafeArea(
      top: false,
      bottom: !glass,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, glass ? 4 : 0, 24, glass ? 24 : Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              item.name,
              style: TextStyle(
                color: p.ink,
                fontSize: glass ? 22 : 20,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 4),
            Text(from, style: TextStyle(color: p.mute, fontSize: 13)),
            if (entry == null) ...[
              const SizedBox(height: Space.sm),
              Text('无法解密，可以在“编辑值和备注”里重新填写或删除', style: TextStyle(color: p.accent, fontSize: 13)),
            ] else if (note.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Text(note, style: TextStyle(color: p.ink, fontSize: 14)),
            ],
            const SizedBox(height: Space.lg),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    contentPadding: listRowPadding,
                    leading: const Icon(Icons.drive_file_rename_outline),
                    title: const Text('改名'),
                    subtitle: const Text('只改这个环境里的名字'),
                    trailing: const ListRowChevron(),
                    onTap: () => _rename(context),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: listRowPadding,
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('编辑值和备注'),
                    subtitle: Text(tidy('改的是变量库里的原变量，所有用到它的环境都会看到')),
                    trailing: const ListRowChevron(),
                    onTap: () => _editValue(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.md),
            if (removed != null)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: () => _remove(context, removed),
                child: const Text('从环境中移除'),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                child: Text(tidy('这个变量来自“全部变量”，要单独移除，请在编辑引用里改为选中的变量。'), style: TextStyle(color: p.mute, fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }
}
