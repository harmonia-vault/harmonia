// 一台电脑已授权的环境（设计文档 5.9）：一行一个，带激活开关和拖动排序，点一行修改这个环境的授权，
// 末尾“添加环境”。设备详情立即提交；扫码批准设备时只记下设置，批准时一起提交。
// 激活只是使用上的便利，不是安全边界（docs/protocol.md 第 4 节），所以开关和排序不要求验证身份。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'glass.dart';
import 'glass_controls.dart';
import 'grant_sheet.dart';
import 'list_row.dart';
import 'lock.dart';
import 'theme.dart';
import 'widgets.dart';

/// 还没授权给这台电脑的环境；没有可添加的环境时提示原因并返回空列表。
List<Environment> _addable(BuildContext context, AppController c, Iterable<String> granted) {
  final all = c.vault.environments;
  final envs = [
    for (final e in all)
      if (!granted.contains(e.id)) e,
  ];
  if (all.isEmpty) {
    toast(context, '还没有环境，先在“环境”里新建一个');
  } else if (envs.isEmpty) {
    toast(context, '所有环境都已授权给这台电脑');
  }
  return envs;
}

DeviceInfo? _deviceOf(AppController c, String id) => c.vault.devices.where((d) => d.id == id).firstOrNull;

/// 提交这台电脑的全部授权；先验证身份。
Future<bool> _commit(BuildContext ctx, AppController c, DeviceInfo d, List<Grant> grants, String done) async {
  if (!await confirmIdentity(ctx, '验证身份以修改“${d.name}”的权限')) return false;
  if (!ctx.mounted) return false;
  return runBusy(ctx, () => c.guard(() => c.vault.updateGrants(d, grants)), done: done);
}

/// 修改设备上一个环境的授权，或取消对它的授权。
Future<void> editDeviceGrant(BuildContext context, AppController c, String deviceId, String envId) async {
  final d = _deviceOf(c, deviceId);
  final old = d?.grants.where((g) => g.envId == envId).firstOrNull;
  if (d == null || old == null) return;
  final name = c.vault.environment(envId).name;
  await showGrantSheet(
    context,
    envName: name,
    deviceName: d.name,
    initial: draftOf(old),
    onSave: (ctx, draft) =>
        _commit(ctx, c, d, [for (final g in d.grants) g.envId == envId ? grantFrom(envId, draft, g) : g], '权限已更新'),
    onRemove: (ctx) async {
      final ok = await confirmDialog(
        ctx,
        title: '取消对“$name”的授权？',
        body: '“${d.name}”将不能再使用这个环境里的变量，下次同步时从这台电脑上移除。',
        ok: '取消授权',
        danger: true,
      );
      if (!ok || !ctx.mounted) return false;
      return _commit(ctx, c, d, [
        for (final g in d.grants)
          if (g.envId != envId) g,
      ], '已取消授权');
    },
  );
}

/// 选一个还没授权的环境，设置后授权给这台电脑。
Future<void> addDeviceGrant(BuildContext context, AppController c, String deviceId) async {
  final d = _deviceOf(c, deviceId);
  if (d == null) return;
  final envs = _addable(context, c, d.grants.map((g) => g.envId));
  if (envs.isEmpty) return;
  final e = await pickEnvironment(context, envs);
  if (e == null || !context.mounted) return;
  await showGrantSheet(
    context,
    envName: e.name,
    deviceName: d.name,
    initial: newGrantDraft,
    onSave: (ctx, draft) => _commit(ctx, c, d, [...d.grants, grantFrom(e.id, draft, null)], '已授权“${e.name}”'),
  );
}

class DeviceGrants extends StatefulWidget {
  const DeviceGrants({super.key, required this.c, required this.deviceId});
  final AppController c;
  final String deviceId;
  @override
  State<DeviceGrants> createState() => _DeviceGrantsState();
}

class _DeviceGrantsState extends State<DeviceGrants> {
  /// 正在提交的激活状态和顺序；提交完成前先按它显示，失败时恢复为服务端的状态。
  List<Grant>? _pending;

  AppController get c => widget.c;
  List<Grant> get _grants => _pending ?? _deviceOf(c, widget.deviceId)?.grants ?? const [];

  Future<void> _submit(List<Grant> next) async {
    setState(() => _pending = next);
    try {
      await c.guard(() => c.vault.setActivation(widget.deviceId, next));
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

  Future<void> _edit(String envId) async {
    await editDeviceGrant(context, c, widget.deviceId, envId);
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    await addDeviceGrant(context, c, widget.deviceId);
    if (mounted) setState(() {});
  }

  /// 激活的环境中同名的变量：变量名 → 按顺序排列的环境名，第一个生效。
  Map<String, List<String>> _conflicts() {
    final by = <String, List<String>>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final g in _grants) {
      if (!g.active || (g.expiresAt != 0 && g.expiresAt <= now)) continue;
      final env = c.vault.environment(g.envId);
      for (final v in env.items.map((i) => i.name)) {
        by.putIfAbsent(v, () => []).add(env.name);
      }
    }
    return Map.fromEntries(
      by.entries.where((e) => e.value.length > 1).toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  /// 玻璃布局下拖动中的那一行是一块浮起的玻璃面板：随拖动略微放大，圆角与卡片一致。
  Widget _glassProxy(Widget child, int index, Animation<double> animation) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) => Transform.scale(
      scale: 1 + 0.03 * Curves.easeOut.transform(animation.value),
      child: AppSurface(
        color: context.palette.card,
        radius: 24,
        panel: true,
        child: Material(type: MaterialType.transparency, child: child),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final grants = _grants;
    final p = context.palette;

    final conflicts = _conflicts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('已授权的环境'),
        Card(
          child: Column(
            children: [
              if (grants.isNotEmpty) ...[
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorderItem: _move,
                  proxyDecorator: _glassProxy,
                  children: [
                    for (final (i, g) in grants.indexed)
                      ListTile(
                        key: ValueKey(g.envId),
                        contentPadding: const EdgeInsetsDirectional.fromSTEB(4, 3, 16, 3),
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: SizedBox.square(dimension: 44, child: Icon(CupertinoIcons.line_horizontal_3)),
                        ),
                        minLeadingWidth: 44,
                        horizontalTitleGap: 4,
                        title: Text(c.vault.environment(g.envId).name),
                        subtitle: grantSummary(context, draftOf(g), active: g.active),
                        trailing: AppSwitch(value: g.active, onChanged: (v) => _toggle(i, v)),
                        onTap: () => _edit(g.envId),
                      ),
                  ],
                ),
                const Divider(),
              ],
              AddEnvironmentRow(onTap: _add),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, Space.sm, Space.xs, 0),
          child: Text(
            tidy(grants.isEmpty ? '还没有授权任何环境。授权后，这台电脑就能使用环境里的变量。' : '点一行修改权限。开关决定这台电脑是否使用这个环境；拖动调整顺序，同名变量用排在前面的。'),
            style: TextStyle(color: p.mute, fontSize: 13, height: 1.5),
          ),
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          Banner2(
            [for (final e in conflicts.entries) '${e.key} 在“${e.value.join('”“')}”里都有，用的是“${e.value.first}”的']
                .join('\n'),
          ),
        ],
      ],
    );
  }
}

/// 扫码批准设备时选择的环境：批准时一起提交，所以面板里只记下设置，不在这里验证身份。
class PairingGrants extends StatelessWidget {
  const PairingGrants({
    super.key,
    required this.c,
    required this.deviceName,
    required this.drafts,
    required this.onChanged,
  });
  final AppController c;
  final String deviceName;

  /// 环境 ID → 设置，按添加顺序排列。
  final Map<String, GrantDraft> drafts;
  final VoidCallback onChanged;

  Future<void> _edit(BuildContext context, String envId) => showGrantSheet(
    context,
    envName: c.vault.environment(envId).name,
    deviceName: deviceName,
    initial: drafts[envId]!,
    onSave: (_, d) async {
      drafts[envId] = d;
      onChanged();
      return true;
    },
    onRemove: (_) async {
      drafts.remove(envId);
      onChanged();
      return true;
    },
  );

  Future<void> _add(BuildContext context) async {
    final envs = _addable(context, c, drafts.keys);
    if (envs.isEmpty) return;
    final e = await pickEnvironment(context, envs);
    if (e == null || !context.mounted) return;
    await showGrantSheet(
      context,
      envName: e.name,
      deviceName: deviceName,
      initial: newGrantDraft,
      onSave: (_, d) async {
        drafts[e.id] = d;
        onChanged();
        return true;
      },
    );
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        for (final MapEntry(key: id, value: d) in drafts.entries) ...[
          ListTile(
            contentPadding: listRowPadding,
            title: Text(c.vault.environment(id).name),
            subtitle: grantSummary(context, d),
            trailing: const ListRowChevron(),
            onTap: () => _edit(context, id),
          ),
          const Divider(),
        ],
        AddEnvironmentRow(onTap: () => _add(context)),
      ],
    ),
  );
}
