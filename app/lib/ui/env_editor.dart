// 新建环境、编辑环境引用：选变量库、全部或勾选的变量、改名、引用顺序，下方实时预览最终名字。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'env_page.dart' show EnvironmentPage;
import 'glass.dart';
import 'glass_controls.dart';
import 'glass_overlays.dart';
import 'theme.dart';
import 'variable_edit.dart' show validateVarName;
import 'widgets.dart';
import 'workspace_scope.dart';

/// 编辑中的一条引用。勾选范围下 [items] 是勾选的变量（按勾选顺序）；全部变量范围下只记改了名的变量。
class _Draft {
  _Draft(this.vaultId) : scope = 'all', items = [], missing = false;
  _Draft.of(EnvRef r) : vaultId = r.vaultId, scope = r.scope, items = [...r.items], missing = r.missing;

  final String vaultId;
  String scope;
  final List<RefItem> items;
  final bool missing;

  bool get all => scope == 'all';
  RefItem? item(String name) => items.where((i) => i.name == name).firstOrNull;
  String? alias(String name) => item(name)?.as;
  bool picked(String name) => item(name) != null;

  void setAlias(String name, String? as) {
    final i = items.indexWhere((i) => i.name == name);
    if (i >= 0) {
      items[i] = RefItem(name, as);
    } else {
      items.add(RefItem(name, as));
    }
    // 全部变量范围下不改名的变量不需要记。
    if (all && as == null) items.removeWhere((i) => i.name == name);
  }

  EnvRef toRef() =>
      EnvRef(vaultId, scope, items: all ? items.where((i) => i.as != null).toList() : items, missing: missing);
}

/// 询问变量库里的 [source] 在环境里的名字。返回 null 表示取消，空字符串表示用回原名。
Future<String?> askAlias(BuildContext context, String source, String? current) async {
  final ctl = TextEditingController(text: current ?? '');
  final form = GlobalKey<FormState>();
  final result = await showAppDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        if (form.currentState!.validate()) Navigator.pop(ctx, ctl.text.trim());
      }

      return AppAlertDialog(
        title: Text('$source 在环境里的名字'),
        content: Form(
          key: form,
          child: TextFormField(
            controller: ctl,
            autofocus: true,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(labelText: '新名字', hintText: source, helperText: '留空表示用原名'),
            validator: (v) => (v ?? '').trim().isEmpty ? null : validateVarName(v),
            onFieldSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: submit, child: const Text('确定')),
        ],
      );
    },
  );
  return result == source ? '' : result;
}

class EnvEditorPage extends StatefulWidget {
  /// [envId] 为 null 时新建环境。
  const EnvEditorPage({super.key, required this.c, this.envId});
  final AppController c;
  final String? envId;
  @override
  State<EnvEditorPage> createState() => _EnvEditorPageState();
}

class _EnvEditorPageState extends State<EnvEditorPage> {
  AppController get c => widget.c;
  late final _def = widget.envId == null ? null : c.vault.envDef(widget.envId!);
  late final _name = TextEditingController(text: _def?.name ?? '');
  late final List<_Draft> _refs = [for (final r in _def?.refs ?? const <EnvRef>[]) _Draft.of(r)];

  List<EnvRef> get _built => [for (final r in _refs) r.toRef()];

  Future<void> _addVault() async {
    final used = {for (final r in _refs) r.vaultId};
    final left = c.vault.vaults.where((v) => !used.contains(v.id)).toList();
    if (left.isEmpty) {
      toast(context, c.vault.vaults.isEmpty ? '还没有变量库，请先在“环境”页新建变量库' : '所有变量库都已添加');
      return;
    }
    final id = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AppSimpleDialog(
        title: const Text('添加变量库'),
        children: [
          for (final v in left)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, v.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Text('${v.name}（${c.vault.variableNames(v.id).length} 个变量）'),
              ),
            ),
        ],
      ),
    );
    if (id != null) setState(() => _refs.add(_Draft(id)));
  }

  Future<void> _rename(_Draft r, String source) async {
    final result = await askAlias(context, source, r.alias(source));
    if (result == null) return;
    setState(() => r.setAlias(source, result.isEmpty ? null : result));
  }

  void _toggle(_Draft r, String name, bool on) => setState(() {
    if (on) {
      r.items.add(RefItem(name));
    } else {
      r.items.removeWhere((i) => i.name == name);
    }
  });

  void _setScope(_Draft r, String scope) => setState(() {
    if (scope == r.scope) return;
    final existing = c.vault.variableNames(r.vaultId);
    if (scope == 'pick') {
      // 改成勾选时先勾上全部现有变量，保留已改的名字。
      final aliases = {for (final i in r.items) i.name: i.as};
      r.items
        ..clear()
        ..addAll([for (final n in existing) RefItem(n, aliases[n])]);
    }
    r.scope = scope;
    if (scope == 'all') r.items.removeWhere((i) => i.as == null);
  });

  void _move(int i, int d) => setState(() => _refs.insert(i + d, _refs.removeAt(i)));

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      toast(context, '请填写环境名称');
      return;
    }
    final refs = _built;
    final nav = Navigator.of(context);
    final workspace = WorkspaceScope.maybeOf(context);
    String? created;
    final ok = await runBusy(context, () async {
      await c.guard(() async {
        if (widget.envId == null) {
          created = await c.vault.createEnvironment(name, refs);
        } else {
          await c.vault.saveEnvironment(widget.envId!, name, refs);
        }
      });
    }, done: widget.envId == null ? '已创建环境“$name”' : '已保存');
    if (!ok || !mounted) return;
    if (created != null) {
      nav.pop();
      final entry = WorkspaceEntry(
        tab: 1,
        id: 'env:$created',

        page: (_) => EnvironmentPage(c: c, envId: created!),
      );
      if (workspace != null) {
        workspace.open(entry);
      } else {
        nav.push(MaterialPageRoute(builder: entry.page));
      }
    } else {
      nav.pop();
    }
  }

  /// 变量行的说明：已不存在，或改名前的原名。
  Widget? _itemNote(_Draft r, String name, bool gone) {
    if (gone) return const Text('变量库里已没有这个变量');
    if (r.alias(name) == null) return null;
    return Text('原名 $name');
  }

  Widget _refCard(BuildContext context, int index) {
    final r = _refs[index];
    final p = context.palette;
    final head = Row(
      children: [
        Expanded(
          child: Text(
            r.missing ? '已删除的变量库' : c.vault.vaultName(r.vaultId) ?? '',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        IconButton(
          tooltip: '往前移',
          icon: const Icon(Icons.arrow_upward),
          onPressed: index == 0 ? null : () => _move(index, -1),
        ),
        IconButton(
          tooltip: '往后移',
          icon: const Icon(Icons.arrow_downward),
          onPressed: index == _refs.length - 1 ? null : () => _move(index, 1),
        ),
        IconButton(
          tooltip: '移除这个变量库',
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _refs.removeAt(index)),
        ),
      ],
    );
    if (r.missing) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              head,
              Text('这个变量库已被删除，不再提供变量。移除这条引用。', style: TextStyle(color: p.mute)),
            ],
          ),
        ),
      );
    }
    final existing = c.vault.variableNames(r.vaultId);
    // 勾选了但变量库里已经没有的变量也列出来，方便取消勾选。
    final gone = r.all
        ? <String>[]
        : [
            for (final i in r.items)
              if (!existing.contains(i.name)) i.name,
          ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, Space.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            head,
            Padding(
              padding: const EdgeInsets.only(right: Space.sm),
              child: AppSegmented<String>(
                value: r.scope,
                options: const [(value: 'all', label: '全部变量'), (value: 'pick', label: '选中的变量')],
                onChanged: (s) => _setScope(r, s),
              ),
            ),
            const SizedBox(height: Space.xs),
            Text(
              tidy(r.all ? '包含这个变量库现在和以后新增的全部变量。' : '只包含勾选的变量，以后新增的不会自动加入。'),
              style: TextStyle(color: p.mute, fontSize: 13),
            ),
            if (existing.isEmpty && gone.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: Text('这个变量库还没有变量。', style: TextStyle(color: p.mute)),
              ),
            for (final n in [...existing, ...gone])
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: r.all
                    ? null
                    : Checkbox.adaptive(value: r.picked(n), onChanged: (v) => _toggle(r, n, v ?? false)),
                title: Text(
                  r.alias(n) ?? n,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: gone.contains(n) ? p.mute : null,
                    decoration: gone.contains(n) ? TextDecoration.lineThrough : null,
                  ),
                ),
                subtitle: _itemNote(r, n, gone.contains(n)),
                trailing: gone.contains(n) ? null : TextButton(onPressed: () => _rename(r, n), child: const Text('改名')),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = c.vault.previewEnvironment(_built);
    final p = context.palette;
    return AppPage(
      appBar: AppBarSurface(
        title: Text(widget.envId == null ? '新建环境' : '编辑引用'),
        actions: [TextButton(onPressed: preview.duplicates.isEmpty ? _save : null, child: const Text('保存'))],
      ),
      body: (context) => ListView(
        padding: pagePadding(context, const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 96)),
        children: [
          TextField(
            controller: _name,
            autofillHints: null,
            maxLength: 64,
            decoration: const InputDecoration(labelText: '环境名称', hintText: '例如 生产环境'),
          ),
          SectionTitle(
            '引用的变量库（${_refs.length}）',
            trailing: TextButton.icon(onPressed: _addVault, icon: const Icon(Icons.add), label: const Text('添加')),
          ),
          if (_refs.isEmpty)
            Text(tidy('还没有引用变量库。点“添加”选择这个环境要用的变量库。'), style: TextStyle(color: p.mute))
          else ...[
            for (var i = 0; i < _refs.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: _refCard(context, i),
              ),
          ],
          SectionTitle('最终的变量（${preview.items.length}）'),
          if (preview.duplicates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Banner2('有重名的变量：${preview.duplicates.join('、')}。请给其中一个改名，或取消勾选。', warn: true),
            ),
          if (preview.items.isEmpty)
            Text('环境里还没有变量。', style: TextStyle(color: p.mute))
          else
            Card(
              child: Column(
                children: [
                  for (final (i, it) in preview.items.indexed) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      dense: true,
                      title: Text(it.name, style: const TextStyle(fontFamily: 'monospace')),
                      subtitle: Text(
                        [
                          '来自 ${c.vault.vaultName(it.vaultId) ?? ''}',
                          if (it.name != it.source) '原名 ${it.source}',
                        ].join(' · '),
                      ),
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
