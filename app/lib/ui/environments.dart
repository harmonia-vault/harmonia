// 环境列表、环境详情（变量）与变量编辑。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'theme.dart';
import 'widgets.dart';

final _varName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');

String? validateVarName(String? v) {
  final s = (v ?? '').trim();
  if (!_varName.hasMatch(s)) return '只能包含字母、数字和下划线，且不能以数字开头';
  if (s.toUpperCase().startsWith('__HARMONIA_')) return '以 __HARMONIA_ 开头的名称为保留名称';
  return null;
}

Future<String?> askName(BuildContext context, {required String title, String initial = '', String label = '名称'}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
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
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

class EnvironmentsTab extends StatelessWidget {
  const EnvironmentsTab({super.key, required this.c});
  final AppController c;

  Future<void> _create(BuildContext context) async {
    final name = await askName(context, title: '新建环境', label: '环境名称，例如 OpenAI、生产环境');
    if (name == null || !context.mounted) return;
    await runBusy(context, () => c.guard(() => c.vault.createEnvironment(name)), done: '已创建环境“$name”');
  }

  @override
  Widget build(BuildContext context) {
    final envs = c.vault.environments;
    return Scaffold(
      appBar: AppBar(title: const Text('环境')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context),
        icon: const Icon(Icons.add),
        label: const Text('新建环境'),
      ),
      body: RefreshIndicator(
        onRefresh: c.syncNow,
        child: envs.isEmpty
            ? ListView(children: const [
                EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: '还没有环境',
                  body: '环境是一组变量，例如“OpenAI”或“生产环境”。创建环境后添加变量，再授权给电脑使用。',
                ),
              ])
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 96),
                itemCount: envs.length,
                separatorBuilder: (_, _) => const SizedBox(height: Space.md),
                itemBuilder: (context, i) {
                  final e = envs[i];
                  final count = c.vault.cache.variables[e.id]?.length ?? 0;
                  final devices = c.vault.devices
                      .where((d) => !d.isManager && d.grants.any((g) => g.envId == e.id))
                      .length;
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                      leading: CircleAvatar(
                        backgroundColor: i.isEven ? context.palette.yellow : context.palette.sage,
                        foregroundColor: context.palette.ink,
                        child: Text(e.name.characters.first.toUpperCase()),
                      ),
                      title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('$count 个变量 · $devices 台电脑可访问'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => EnvironmentPage(c: c, envId: e.id))),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class EnvironmentPage extends StatefulWidget {
  const EnvironmentPage({super.key, required this.c, required this.envId});
  final AppController c;
  final String envId;
  @override
  State<EnvironmentPage> createState() => _EnvironmentPageState();
}

class _EnvironmentPageState extends State<EnvironmentPage> {
  final _revealed = <String>{};

  AppController get c => widget.c;

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
    if (!c.vault.environments.any((e) => e.id == widget.envId)) {
      Navigator.pop(context);
      return;
    }
    setState(() {});
  }

  Future<void> _menu(String action, Environment env) async {
    if (action == 'rename') {
      final name = await askName(context, title: '重命名环境', initial: env.name);
      if (name == null || !mounted) return;
      await runBusy(context, () => c.guard(() => c.vault.renameEnvironment(env.id, name)));
    } else if (action == 'delete') {
      final ok = await confirmDialog(context,
          title: '删除环境“${env.name}”？',
          body: '其中的全部变量会被删除，所有已授权的电脑在下次同步时都会移除这些变量。此操作无法撤销。',
          ok: '删除',
          danger: true);
      if (!ok || !mounted) return;
      final nav = Navigator.of(context);
      final done = await runBusy(context, () => c.guard(() => c.vault.deleteEnvironment(env.id)),
          done: '已删除环境');
      if (done) nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = c.vault.environments.where((e) => e.id == widget.envId).firstOrNull;
    if (env == null) return const Scaffold();
    Map<String, String> values;
    String? error;
    try {
      values = c.vault.values(env.id);
    } catch (e) {
      values = {};
      error = errorText(e);
    }
    final names = values.keys.toList()..sort();
    final devices = c.vault.devices
        .where((d) => !d.isManager && d.grants.any((g) => g.envId == env.id))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(env.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (a) => _menu(a, env),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'delete', child: Text('删除环境')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => VariableEditPage(c: c, envId: env.id))),
        icon: const Icon(Icons.add),
        label: const Text('添加变量'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96),
        children: [
          if (error != null) Banner2(error, warn: true),
          SectionTitle('变量（${names.length}）'),
          if (names.isEmpty)
            const EmptyState(
                icon: Icons.key_off_outlined,
                title: '还没有变量',
                body: '添加 API Key 等变量后，获授权的电脑会自动同步。')
          else
            Card(
              child: Column(children: [
                for (final (i, n) in names.indexed) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    title: Text(n, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      _revealed.contains(n) ? values[n]! : '••••••••',
                      maxLines: _revealed.contains(n) ? 6 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => VariableEditPage(c: c, envId: env.id, name: n))),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: _revealed.contains(n) ? '隐藏' : '显示',
                        icon: Icon(_revealed.contains(n) ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        onPressed: () => setState(() => _revealed.contains(n) ? _revealed.remove(n) : _revealed.add(n)),
                      ),
                      IconButton(
                        tooltip: '复制',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: values[n]!));
                          toast(context, '已复制 $n');
                        },
                      ),
                    ]),
                  ),
                ],
              ]),
            ),
          SectionTitle('可访问的电脑（${devices.length}）'),
          if (devices.isEmpty)
            Text('还没有电脑可以访问这个环境。在“设备”中添加电脑或调整权限。',
                style: TextStyle(color: context.palette.mute))
          else
            Card(
              child: Column(children: [
                for (final (i, d) in devices.indexed) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    leading: const Icon(Icons.laptop_mac_outlined),
                    title: Text(d.name),
                    subtitle: Text(() {
                      final g = d.grants.firstWhere((g) => g.envId == env.id);
                      return '${roleNames[g.role]} · ${formatExpiry(g.expiresAt)}';
                    }()),
                  ),
                ],
              ]),
            ),
        ],
      ),
    );
  }
}

class VariableEditPage extends StatefulWidget {
  const VariableEditPage({super.key, required this.c, required this.envId, this.name});
  final AppController c;
  final String envId;
  final String? name;
  @override
  State<VariableEditPage> createState() => _VariableEditPageState();
}

class _VariableEditPageState extends State<VariableEditPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name ?? '');
  late final _value = TextEditingController(
      text: widget.name == null ? '' : (widget.c.vault.values(widget.envId)[widget.name] ?? ''));
  bool _show = false;

  bool get _editing => widget.name != null;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final c = widget.c;
    final name = _name.text.trim();
    if (!_editing && c.vault.values(widget.envId).containsKey(name)) {
      final ok = await confirmDialog(context, title: '覆盖 $name？', body: '这个环境中已经有同名变量，保存会覆盖原来的值。', ok: '覆盖');
      if (!ok || !mounted) return;
    }
    final nav = Navigator.of(context);
    final ok = await runBusy(context, () => c.guard(() => c.vault.setVariable(widget.envId, name, _value.text)),
        done: '已保存 $name');
    if (ok) nav.pop();
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(context,
        title: '删除 ${widget.name}？', body: '所有已授权的电脑会在下次同步时移除这个变量。', ok: '删除', danger: true);
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    final done = await runBusy(
        context, () => widget.c.guard(() => widget.c.vault.deleteVariable(widget.envId, widget.name!)),
        done: '已删除');
    if (done) nav.pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(_editing ? '编辑变量' : '添加变量'),
          actions: [
            if (_editing) IconButton(tooltip: '删除', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          ],
        ),
        body: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(Space.lg), children: [
            TextFormField(
              autofillHints: null,
              controller: _name,
              enabled: !_editing,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(labelText: '变量名', hintText: 'OPENAI_API_KEY'),
              validator: validateVarName,
            ),
            const SizedBox(height: Space.md),
            TextFormField(
              autofillHints: null,
              controller: _value,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 1,
              maxLines: _show ? 6 : 1,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: '值',
                suffixIcon: IconButton(
                  icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
              validator: (v) => (v ?? '').length > 65536 ? '值不能超过 64 KB' : null,
            ),
            const SizedBox(height: Space.md),
            const Banner2('值在本机加密后才会上传。保存需要联网，成功后会同步到所有获授权的电脑。'),
            const SizedBox(height: Space.xl),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ]),
        ),
      );
}
