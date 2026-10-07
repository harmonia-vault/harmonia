// 设备详情中的“使用顺序”：开关某台设备上的环境、拖动调整顺序，并显示同名变量由哪个环境提供。
// 激活只是使用上的便利，不是安全边界（docs/protocol.md 第 4 节），所以修改时不要求验证身份。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import '../core/vault.dart';
import 'theme.dart';
import 'widgets.dart';

class ActivationEditor extends StatefulWidget {
  const ActivationEditor({super.key, required this.c, required this.device});
  final AppController c;
  final DeviceInfo device;
  @override
  State<ActivationEditor> createState() => _ActivationEditorState();
}

class _ActivationEditorState extends State<ActivationEditor> {
  /// 正在提交的顺序；提交完成前先按它显示，失败时恢复为服务端的状态。
  List<Grant>? _pending;

  List<Grant> get _grants => _pending ?? widget.device.grants;

  Future<void> _submit(List<Grant> next) async {
    setState(() => _pending = next);
    try {
      await widget.c.guard(() => widget.c.vault.setActivation(widget.device.id, next));
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  void _toggle(int i, bool active) {
    final next = [..._grants];
    next[i] = next[i].copyWith(active: active);
    _submit(next);
  }

  /// [to] 已按移除原位置后的列表换算好（onReorderItem 的约定）。
  void _move(int from, int to) {
    final next = [..._grants];
    next.insert(to, next.removeAt(from));
    _submit(next);
  }

  /// 激活的环境中同名的变量：变量名 → 按顺序排列的环境名，第一个生效。
  Map<String, List<String>> _conflicts() {
    final by = <String, List<String>>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final g in _grants) {
      if (!g.active || (g.expiresAt != 0 && g.expiresAt <= now)) continue;
      final name = widget.c.vault.environment(g.envId).name;
      for (final v in widget.c.vault.cache.variables[g.envId]?.keys ?? const <String>[]) {
        by.putIfAbsent(v, () => []).add(name);
      }
    }
    return Map.fromEntries(
      by.entries.where((e) => e.value.length > 1).toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grants = _grants;
    final palette = context.palette;
    final now = DateTime.now().millisecondsSinceEpoch;
    final conflicts = _conflicts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('使用顺序'),
        Text('开启的环境会写入这台设备的环境变量。拖动调整顺序，同名变量由排在前面的环境提供。', style: TextStyle(color: palette.mute, height: 1.5)),
        const SizedBox(height: Space.sm),
        Card(
          child: ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: _move,
            children: [
              for (final (i, g) in grants.indexed)
                ListTile(
                  key: ValueKey(g.envId),
                  leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                  title: Text(widget.c.vault.environment(g.envId).name),
                  subtitle: g.expiresAt != 0 && g.expiresAt <= now ? const Text('授权已到期') : null,
                  trailing: Switch(value: g.active, onChanged: (v) => _toggle(i, v)),
                ),
            ],
          ),
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          Banner2(
            [
              '同名变量：',
              for (final e in conflicts.entries)
                '${e.key} 使用“${e.value.first}”中的值（同时出现在“${e.value.skip(1).join('”“')}”）',
            ].join('\n'),
          ),
        ],
      ],
    );
  }
}
