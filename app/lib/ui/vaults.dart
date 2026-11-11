// 变量库详情（变量）、新建变量库，以及环境详情和变量库详情共用的变量列表。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../core/crypto.dart' show VarEntry;
import 'app_scope.dart';
import 'env_page.dart' show EnvironmentPage, refSummary;
import 'glass.dart';
import 'glass_overlays.dart';
import 'list_row.dart';
import 'theme.dart';
import 'variable_edit.dart';
import 'widgets.dart';

Future<String?> askName(BuildContext context, {required String title, String initial = '', String label = '名称'}) {
  final ctl = TextEditingController(text: initial);
  return showAppDialog<String>(
    context: context,
    useRootNavigator: false,
    builder: (c) => AppAlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofillHints: null,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(c, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(c, ctl.text.trim().isEmpty ? null : ctl.text.trim()),
          child: Text(initial.isEmpty ? '创建' : '保存'),
        ),
      ],
    ),
  );
}

/// 新建变量库，成功后打开它。
Future<void> createVaultFlow(BuildContext context, AppController c) async {
  final name = await askName(context, title: '新建变量库', label: '变量库名称');
  if (name == null || !context.mounted) return;
  String? id;
  final ok = await runBusy(context, () async {
    await c.guard(() async => id = await c.vault.createVault(name));
  }, done: '已创建变量库');
  if (ok && id != null && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VaultPage(c: c, vaultId: id!),
      ),
    );
  }
}

/// 列表里的一个变量。[entry] 为 null 表示解不开；[origin] 是附加说明（例如“来自 OpenAI”）。
typedef VarRow = ({String name, VarEntry? entry, String? origin, VoidCallback onTap});

/// 变量列表：值默认隐藏，可以显示和复制。
class VariableList extends StatefulWidget {
  const VariableList({super.key, required this.rows});
  final List<VarRow> rows;
  @override
  State<VariableList> createState() => _VariableListState();
}

class _VariableListState extends State<VariableList> {
  final _revealed = <String>{};

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Card(
      child: Column(
        children: [
          for (final (i, r) in widget.rows.indexed) ...[
            // 这一组没有行首图标，分隔线与文字左缘对齐。
            if (i > 0) Divider(indent: usesGlass(context) ? listRowPadding.start : null),
            ListTile(
              contentPadding: listRowPadding,
              title: Text(
                r.name,
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (r.entry == null)
                    Text('无法解密，点按后可以删除或重新填写', style: TextStyle(color: p.accent))
                  else ...[
                    Text(
                      _revealed.contains(r.name) ? r.entry!.value : '••••••••',
                      maxLines: _revealed.contains(r.name) ? 6 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    if (r.entry!.note.isNotEmpty)
                      Text(
                        r.entry!.note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.mute, fontSize: 13),
                      ),
                  ],
                  if (r.origin != null) Text(r.origin!, style: TextStyle(color: p.mute, fontSize: 13)),
                ],
              ),
              onTap: r.onTap,
              trailing: r.entry == null
                  ? const ListRowChevron()
                  : ListRowActions(
                      children: [
                        IconButton(
                          tooltip: _revealed.contains(r.name) ? '隐藏' : '显示',
                          icon: Icon(
                            _revealed.contains(r.name) ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          ),
                          onPressed: () => setState(
                            () => _revealed.contains(r.name) ? _revealed.remove(r.name) : _revealed.add(r.name),
                          ),
                        ),
                        IconButton(
                          tooltip: '复制',
                          icon: const Icon(Icons.copy_rounded),
                          onPressed: () {
                            if (!AppScope.isSimulated(context)) {
                              Clipboard.setData(ClipboardData(text: r.entry!.value));
                            }
                            toast(context, '已复制 ${r.name}');
                          },
                        ),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 变量库页底部复制变量库 ID 的一行和用法说明。
List<Widget> idSection(BuildContext context, {required String label, required String id, required String usage}) {
  void copy() {
    if (!AppScope.isSimulated(context)) Clipboard.setData(ClipboardData(text: id));
    toast(context, '已复制$label');
  }

  return [
    const SectionTitle('在命令行中使用'),
    Card(
      child: ListTile(
        contentPadding: listRowPadding,
        title: Text(label),
        subtitle: Text(id, style: const TextStyle(fontFamily: 'monospace')),
        onTap: copy,
        trailing: ListRowActions(
          children: [IconButton(tooltip: '复制 ID', icon: const Icon(Icons.copy_rounded), onPressed: copy)],
        ),
      ),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.sm, Space.xs, 0),
      child: Text(tidy(usage), style: TextStyle(color: context.palette.mute, fontSize: 13)),
    ),
  ];
}

/// 页面对应的对象被删除（本机或其他设备）后自动关闭页面；本页自己删除时等进度弹窗关闭后再离开。
mixin LeaveWhenGone<T extends StatefulWidget> on State<T> {
  AppController get c;
  bool get exists;
  bool deleting = false;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!exists) {
      if (!deleting) leave();
      return;
    }
    setState(() {});
  }

  /// 关掉本页及其上层页面，只执行一次。
  void leave() {
    if (_left || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _left = true;
    Navigator.of(context)
      ..popUntil((r) => r == route)
      ..pop();
  }

  /// 执行删除；成功后离开本页。
  Future<void> runDelete(Future<void> Function() delete, String done) async {
    deleting = true;
    try {
      await runBusy(context, () => c.guard(delete), done: done);
    } finally {
      deleting = false;
    }
    if (!exists) leave();
  }
}

class VaultPage extends StatefulWidget {
  const VaultPage({super.key, required this.c, required this.vaultId});
  final AppController c;
  final String vaultId;
  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> with LeaveWhenGone {
  @override
  AppController get c => widget.c;

  @override
  bool get exists => c.vault.vaultName(widget.vaultId) != null;

  void _edit([String? name]) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => VariableEditPage(c: c, vaultId: widget.vaultId, name: name),
    ),
  );

  Future<void> _menu(String action, String name, List<String> usedBy) async {
    if (action == 'rename') {
      final next = await askName(context, title: '重命名变量库', initial: name);
      if (next == null || !mounted) return;
      await runBusy(context, () => c.guard(() => c.vault.renameVault(widget.vaultId, next)));
    } else if (action == 'delete') {
      final ok = await confirmDialog(
        context,
        title: '删除变量库“$name”？',
        body: [
          '其中的全部变量会被删除，电脑在下次同步时移除这些变量。',
          if (usedBy.isNotEmpty) '用到它的环境（${usedBy.join('、')}）会显示引用已失效，需要编辑后移除。',
          '此操作无法撤销。',
        ].join('\n'),
        ok: '删除',
        danger: true,
      );
      if (!ok || !mounted) return;
      await runDelete(() => c.vault.deleteVault(widget.vaultId), '已删除变量库');
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = c.vault.vaultName(widget.vaultId);
    if (name == null) return const Scaffold();
    Map<String, VarEntry> values;
    List<String> broken;
    String? error;
    try {
      values = c.vault.entries(widget.vaultId);
      broken = c.vault.brokenVariables(widget.vaultId);
    } catch (e) {
      values = {};
      broken = [];
      error = errorText(e);
    }
    final names = [...values.keys, ...broken]..sort();
    final envs = c.vault.envDefs.where((e) => e.refs.any((r) => r.vaultId == widget.vaultId)).toList();
    return AppPage(
      appBar: AppBarSurface(
        title: Text(name),
        actions: [
          if (usesGlass(context)) IconButton(tooltip: '添加变量', icon: const Icon(Icons.add), onPressed: _edit),
          AppMenuButton(
            semanticLabel: '变量库操作',
            onSelected: (a) => _menu(a, name, [for (final e in envs) e.name]),
            items: const [
              (value: 'rename', label: '重命名', icon: Icons.edit_outlined, danger: false),
              (value: 'delete', label: '删除变量库', icon: Icons.delete_outline, danger: true),
            ],
          ),
        ],
      ),
      floatingActionButton: usesGlass(context)
          ? null
          : FloatingActionButton.extended(onPressed: _edit, icon: const Icon(Icons.add), label: const Text('添加变量')),
      body: (context) => ListView(
        padding: pagePadding(context, const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96)),
        children: [
          if (error != null) Banner2(error, warn: true),
          SectionTitle('变量（${names.length}）'),
          if (names.isEmpty)
            const EmptyState(icon: Icons.key_off_outlined, title: '还没有变量', body: '添加 API Key 等变量后，用到这个变量库的环境会自动包含它们。')
          else
            VariableList(
              rows: [for (final n in names) (name: n, entry: values[n], origin: null, onTap: () => _edit(n))],
            ),
          SectionTitle('用到它的环境（${envs.length}）'),
          if (envs.isEmpty)
            Text(tidy('还没有环境引用这个变量库。电脑只能通过环境使用变量，可以在“环境”里新建或编辑环境。'), style: TextStyle(color: context.palette.mute))
          else
            Card(
              child: Column(
                children: [
                  for (final (i, e) in envs.indexed) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      contentPadding: listRowPadding,
                      leading: const Icon(Icons.layers_outlined),
                      title: Text(e.name),
                      subtitle: Text(refSummary(e.refs.firstWhere((r) => r.vaultId == widget.vaultId))),
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
          ...idSection(
            context,
            label: '变量库 ID',
            id: widget.vaultId,
            usage: '电脑上用 harmonia var set --vault ${widget.vaultId} 变量名 新增或修改变量。',
          ),
        ],
      ),
    );
  }
}
