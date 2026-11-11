// 批准页：电脑请求使用或写入没有开启本机解密的环境里的变量（设计文档 17.4），以及设备详情里“正在生效的授权”。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/api.dart';
import '../core/approval_choice.dart';
import '../core/models.dart';
import '../core/vault.dart';
import 'devices.dart' show platformIcon, platformName;
import 'glass.dart';
import 'glass_controls.dart';
import 'glass_overlays.dart';
import 'lock.dart';
import 'theme.dart';
import 'widgets.dart';
import 'window_layout.dart';
import 'workspace_scope.dart';

class ApprovalPage extends StatefulWidget {
  const ApprovalPage({super.key, required this.c, required this.request});
  final AppController c;
  final ApprovalRequest request;
  @override
  State<ApprovalPage> createState() => _ApprovalPageState();
}

class _ApprovalPageState extends State<ApprovalPage> {
  ApprovalRequest get a => widget.request;
  Vault get v => widget.c.vault;
  late final DeviceInfo? _device = v.approvalDevice(a);
  late ApprovalChoice _choice = _device == null ? ApprovalChoice.initial : widget.c.approvalChoice(_device);
  late final String? _problem = v.approvalProblem(a);
  List<ApprovalWrite>? _writes;
  String? _writeError;
  bool _showValues = false;
  bool _gone = false;

  /// 请求出现在待处理列表里；之后从列表消失，说明电脑已取消、超时，或已在另一台管理设备上处理。
  late bool _listed = _inList;
  bool get _inList => widget.c.approvals.any((x) => x.id == a.id);

  @override
  void initState() {
    super.initState();
    widget.c.addListener(_onChange);
    if (a.isWrite && _problem == null) {
      try {
        _writes = v.approvalWrites(a);
      } on VaultException catch (e) {
        _writeError = e.message;
      }
    }
  }

  @override
  void dispose() {
    widget.c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (_inList) {
      _listed = true;
    } else if (_listed && !_gone && mounted) {
      setState(() => _gone = true);
    }
  }

  bool get _windows => _device?.platform == 'windows';

  Future<bool> _submit(Future<void> Function() fn, String done) => runBusy(context, () async {
    try {
      await widget.c.guard(fn);
    } on ApiException catch (e) {
      if (e.code == 'conflict' || e.code == 'not_found') setState(() => _gone = true);
      rethrow;
    }
  }, done: done);

  Future<void> _approve() async {
    if (!await confirmIdentity(context, '验证身份以批准“${_device?.name ?? '电脑'}”的请求')) return;
    if (!mounted) return;
    final nav = Navigator.of(context);
    final choice = _choice;
    final ok = await _submit(() async {
      if (a.isWrite) {
        await v.approveWrite(a);
      } else {
        await v.approveRead(
          a,
          scope: choice.submitScope,
          expiresAt: choice.duration.expiresAt(DateTime.now().millisecondsSinceEpoch),
        );
        await widget.c.rememberApprovalChoice(a.deviceId, choice);
      }
      await widget.c.refreshApprovals();
    }, a.isWrite ? '已批准并写入' : '已批准');
    if (ok) nav.pop();
  }

  Future<void> _reject() async {
    final nav = Navigator.of(context);
    if (await _submit(() async {
      await v.rejectApproval(a.id);
      await widget.c.refreshApprovals();
    }, '已拒绝')) {
      nav.pop();
    }
  }

  Future<void> _pickDuration(int minutes) async {
    if (minutes != -2) {
      setState(() => _choice = ApprovalChoice(ApprovalDuration.decode('$minutes'), _choice.scope));
      return;
    }
    final picked = await askCustomDuration(context);
    if (picked != null) setState(() => _choice = ApprovalChoice(picked, _choice.scope));
  }

  @override
  Widget build(BuildContext context) {
    final d = _device;
    final tabletop = WindowLayoutScope.maybeOf(context)?.tabletop == true && WorkspaceScope.maybeOf(context) == null;
    return AppPage(
      appBar: AppBarSurface(title: Text(a.isWrite ? '批准写入变量' : '批准使用变量')),
      controls: tabletop ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _controls()) : null,
      body: (context) => ListView(
        padding: pagePadding(context, const EdgeInsets.all(Space.lg)),
        children: [
          Card(
            child: ListTile(
              leading: Icon(platformIcon(d?.platform ?? ''), size: 32),
              title: Text(d?.name ?? '未知设备', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(d == null ? '不在这个账号里' : platformName(d.platform)),
            ),
          ),
          if (_gone) ...[
            const SizedBox(height: Space.lg),
            const Banner2('请求已失效：电脑已取消或超时，或已在其他管理设备上处理。需要时在电脑上重新运行命令。', warn: true),
            const SizedBox(height: Space.xl),
            if (!tabletop) ..._controls(),
          ] else
            ..._review(tabletop),
        ],
      ),
    );
  }

  List<Widget> _review(bool tabletop) {
    final blocked = _problem ?? _writeError;
    return [
      const SizedBox(height: Space.lg),
      const Text('请求码'),
      const SizedBox(height: Space.sm),
      CodeBox(a.code, copyable: false, big: true, centered: true),
      const SizedBox(height: Space.sm),
      const Banner2('确认是你刚在电脑上发起的、请求码一致，再批准。', warn: true),
      const SectionTitle('请求'),
      Card(
        child: Column(
          children: [
            ListTile(title: const Text('命令'), subtitle: SelectableText(a.command.isEmpty ? '（没有）' : a.command)),
            ListTile(title: const Text('目录'), subtitle: SelectableText(a.cwd.isEmpty ? '（没有）' : a.cwd)),
          ],
        ),
      ),
      if (blocked != null) ...[const SizedBox(height: Space.md), Banner2(blocked, warn: true)],
      ...a.isWrite ? _writeList() : _readList(),
      if (!tabletop) ..._controls(),
    ];
  }

  List<Widget> _controls() {
    if (_gone) return [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))];
    final blocked = _problem ?? _writeError;
    return [
      const SizedBox(height: Space.sm),
      FilledButton(onPressed: blocked == null ? _approve : null, child: const Text('批准')),
      const SizedBox(height: Space.sm),
      OutlinedButton(onPressed: _reject, child: const Text('拒绝')),
      if (!a.isWrite && blocked == null) ..._options(),
    ];
  }

  String _origin(ApprovalItem it) {
    final src = v.approvalSource(it);
    if (src == null) return '';
    final vault = v.vaultName(src.vaultId) ?? '已删除的变量库';
    return src.source == it.name ? '来自 $vault' : '来自 $vault / ${src.source}';
  }

  String _envName(String id) => v.envDef(id)?.name ?? '未知环境';

  List<Widget> _readList() {
    final byEnv = <String, List<ApprovalItem>>{};
    for (final it in a.items) {
      byEnv.putIfAbsent(it.envId, () => []).add(it);
    }
    return [
      for (final e in byEnv.entries) ...[
        SectionTitle('环境“${_envName(e.key)}”'),
        Card(
          child: Column(
            children: [
              for (final it in e.value)
                ListTile(
                  title: Text(it.name, style: _mono),
                  subtitle: Text(_origin(it)),
                ),
            ],
          ),
        ),
      ],
    ];
  }

  List<Widget> _writeList() {
    final writes = _writes ?? [for (final it in a.items) ApprovalWrite(it, const {})];
    return [
      SectionTitle('写入${a.deletes.isEmpty ? '' : '和删除'}'),
      Card(
        child: Column(
          children: [
            for (final w in writes)
              ListTile(
                title: Text(w.item.name, style: _mono),
                subtitle: Text(
                  [
                    if (w.item.vaultId != null)
                      '新增到变量库“${v.vaultName(w.item.vaultId!) ?? '未知'}”'
                    else
                      '修改，${_origin(w.item)}',
                    if (w.plain['value'] is String) '值：${_showValues ? w.plain['value'] : '••••••'}' else '值不变',
                    if (w.plain['note'] is String) '备注：${w.plain['note']}',
                  ].join('\n'),
                ),
              ),
            for (final it in a.deletes)
              ListTile(
                title: Text(it.name, style: _mono),
                subtitle: Text('删除，${_origin(it)}'),
              ),
          ],
        ),
      ),
      if (_writes != null && _writes!.any((w) => w.plain['value'] is String))
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _showValues = !_showValues),
            child: Text(_showValues ? '隐藏值' : '显示值'),
          ),
        ),
      const SizedBox(height: Space.sm),
      Text('改的是变量库里的原变量，引用它的环境都会受影响。', style: _muted(context)),
    ];
  }

  List<Widget> _options() {
    final current = _choice.duration;
    return [
      const SizedBox(height: Space.lg),
      Card(
        child: ListTile(
          title: const Text('多久内不再询问'),
          trailing: AppSelect<int>(
            semanticLabel: '多久内不再询问',
            value: current.minutes,
            options: [
              for (final p in ApprovalDuration.presets) (value: p.minutes, label: p.label),
              if (!current.isPreset) (value: current.minutes, label: current.label),
              (value: -2, label: '自定义…'),
            ],
            onChanged: _pickDuration,
          ),
          subtitle: Text(current.isForever ? '到电脑重启或退出登录为止' : (current.isOnce ? '只用于这一次运行' : '期间不再询问')),
        ),
      ),
      if (!current.isOnce) ...[
        const SectionTitle('授权范围'),
        if (_windows)
          const Banner2('Windows 上只能授权给这台电脑上的所有程序。')
        else
          AppSegmented<String>(
            options: const [(value: scopeTerminal, label: '仅这个终端'), (value: scopeAll, label: '这台电脑上的所有程序')],
            value: _choice.scope,
            onChanged: (s) => setState(() => _choice = ApprovalChoice(current, s)),
          ),
        const SizedBox(height: Space.sm),
        Text(_choice.scope == scopeAll ? '这台电脑上的程序都能用，适合 IDE、AI 工具。' : '只在发起请求的终端里有效，关闭终端即结束。', style: _muted(context)),
      ],
    ];
  }
}

const _mono = TextStyle(fontFamily: 'monospace');

TextStyle _muted(BuildContext context) => TextStyle(color: context.palette.mute, fontSize: 13);

/// 自定义“多久内不再询问”：1 分钟到 30 天。
Future<ApprovalDuration?> askCustomDuration(BuildContext context) async {
  final ctrl = TextEditingController(text: '1');
  var unit = 60;
  String? error;
  final result = await showAppDialog<ApprovalDuration>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AppAlertDialog(
        title: const Text('自定义时长'),
        content: Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(errorText: error),
              ),
            ),
            const SizedBox(width: Space.md),
            AppSelect<int>(
              semanticLabel: '单位',
              value: unit,
              options: const [(value: 1, label: '分钟'), (value: 60, label: '小时'), (value: 1440, label: '天')],
              onChanged: (u) => set(() => unit = u),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim()) ?? 0;
              final minutes = n * unit;
              if (minutes < ApprovalDuration.minMinutes || minutes > ApprovalDuration.maxMinutes) {
                set(() => error = '请填写 1 分钟到 30 天之间的时长');
                return;
              }
              Navigator.pop(ctx, ApprovalDuration.of(minutes));
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
  return result;
}

/// 设备详情里“正在生效的授权”：环境和变量、授权范围、剩余时间，可以结束。
class AuthorizationsSection extends StatefulWidget {
  const AuthorizationsSection({super.key, required this.c, required this.device});
  final AppController c;
  final DeviceInfo device;
  @override
  State<AuthorizationsSection> createState() => _AuthorizationsSectionState();
}

class _AuthorizationsSectionState extends State<AuthorizationsSection> {
  List<AuthorizationInfo>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.c.vault.authorizations(deviceId: widget.device.id);
      if (mounted) setState(() => _list = list);
    } catch (_) {
      // 离线时不显示这一节。
    }
  }

  Future<void> _end(AuthorizationInfo x) async {
    final ok = await runBusy(context, () => widget.c.guard(() => widget.c.vault.endAuthorization(x.id)), done: '已结束');
    if (ok) await _load();
  }

  String _label(AuthorizationInfo x) {
    final names = [for (final it in x.items) '${widget.c.vault.envDef(it.envId)?.name ?? '未知环境'}：${it.name}'];
    final scope = x.scope == scopeTerminal ? '仅发起请求的终端' : '这台电脑上的所有程序';
    final until = x.expiresAt == 0 ? '长期' : '到 ${formatTime(x.expiresAt)}';
    return '${names.join('、')}\n$scope · $until';
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list == null || list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('正在生效的授权'),
        Card(
          child: Column(
            children: [
              for (final x in list)
                ListTile(
                  title: Text(_label(x)),
                  trailing: TextButton(onPressed: () => _end(x), child: const Text('结束')),
                ),
            ],
          ),
        ),
        const SizedBox(height: Space.sm),
        Text('电脑离线时，要等它重新联网才会结束。', style: _muted(context)),
      ],
    );
  }
}
