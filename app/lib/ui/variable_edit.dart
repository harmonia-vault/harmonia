// 添加、编辑变量库里的变量。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/crypto.dart' show maxNoteLen;
import 'glass.dart';
import 'theme.dart';
import 'widgets.dart';

final _varName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');

String? validateVarName(String? v) {
  final s = (v ?? '').trim();
  if (!_varName.hasMatch(s)) return '只能包含字母、数字和下划线，且不能以数字开头';
  if (s.toUpperCase().startsWith('__HARMONIA_')) return '以 __HARMONIA_ 开头的名称为保留名称';
  return null;
}

class VariableEditPage extends StatefulWidget {
  const VariableEditPage({super.key, required this.c, required this.vaultId, this.name});
  final AppController c;
  final String vaultId;
  final String? name;
  @override
  State<VariableEditPage> createState() => _VariableEditPageState();
}

class _VariableEditPageState extends State<VariableEditPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name ?? '');
  late final _old = widget.name == null ? null : widget.c.vault.entries(widget.vaultId)[widget.name];
  late final _broken = widget.name != null && _old == null;
  late final _value = TextEditingController(text: _old?.value ?? '');
  late final _note = TextEditingController(text: _old?.note ?? '');
  bool _show = false;

  bool get _editing => widget.name != null;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final c = widget.c;
    final name = _name.text.trim();
    if (!_editing && c.vault.variableNames(widget.vaultId).contains(name)) {
      final ok = await confirmDialog(context, title: '覆盖 $name？', body: '这个变量库中已经有同名变量，保存会覆盖原来的值。', ok: '覆盖');
      if (!ok || !mounted) return;
    }
    final nav = Navigator.of(context);
    final ok = await runBusy(
      context,
      () => c.guard(() => c.vault.setVariable(widget.vaultId, name, _value.text, _note.text)),
      done: '已保存 $name',
    );
    if (ok) nav.pop();
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(
      context,
      title: '删除 ${widget.name}？',
      body: '用到这个变量库的环境都会失去这个变量，电脑在下次同步时移除它。',
      ok: '删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    final done = await runBusy(
      context,
      () => widget.c.guard(() => widget.c.vault.deleteVariable(widget.vaultId, widget.name!)),
      done: '已删除',
    );
    if (done) nav.pop();
  }

  @override
  Widget build(BuildContext context) => AppPage(
    appBar: AppBarSurface(
      title: Text(_editing ? '编辑变量' : '添加变量'),
      actions: [if (_editing) IconButton(tooltip: '删除', icon: const Icon(Icons.delete_outline), onPressed: _delete)],
    ),
    body: (context) => Form(
      key: _form,
      child: ListView(
        padding: pagePadding(context, const EdgeInsets.all(Space.lg)),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Text(
              '变量库：${widget.c.vault.vaultName(widget.vaultId) ?? ''}',
              style: TextStyle(color: context.palette.mute),
            ),
          ),
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
          TextFormField(
            controller: _note,
            minLines: 1,
            maxLines: 4,
            maxLength: maxNoteLen,
            decoration: const InputDecoration(labelText: '备注（可选）', hintText: '例如：用途、从哪里申请、什么时候到期'),
            validator: (v) => (v ?? '').trim().runes.length > maxNoteLen ? '备注最长 $maxNoteLen 个字' : null,
          ),
          const SizedBox(height: Space.md),
          if (_broken) ...[
            const Banner2('原来的内容无法解密。可以点右上角删除这个变量，或者重新填写值和备注，保存后覆盖。', warn: true),
            const SizedBox(height: Space.md),
          ],
          const Banner2('值和备注在本机加密后才会上传。\n保存需要联网，成功后会同步到用到这个变量库的电脑。'),
          const SizedBox(height: Space.xl),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
    ),
  );
}
