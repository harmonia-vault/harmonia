// 一个环境的授权面板（权限；“高级”里是无人值守使用和它的期限），以及“添加环境”时选择环境的面板（设计文档 5.9、17.2、19.3）。
// 设备详情和扫码批准设备共用；保存时做什么由调用方决定。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'app_sheet.dart';
import 'glass.dart';
import 'glass_controls.dart';
import 'list_row.dart';
import 'theme.dart';
import 'widgets.dart';

const _forever = '长期有效';

const _expiryChoices = <String, Duration?>{
  _forever: null,
  '1 天': Duration(days: 1),
  '7 天': Duration(days: 7),
  '30 天': Duration(days: 30),
  '90 天': Duration(days: 90),
};

int expiryFrom(String label) {
  final d = _expiryChoices[label];
  return d == null ? 0 : DateTime.now().add(d).millisecondsSinceEpoch;
}

/// 新授权的环境默认不开启无人值守使用（本机解密）：电脑每次用变量时在手机上批准（设计文档 17.2）。
const defaultLocalDecrypt = false;

/// “无人值守使用（本机解密）”开关下方的说明，以及开启时确认框里的风险说明（设计文档 17.2、19.3）。
const localDecryptOn = '无需手机批准，仅建议在服务器或 CI 上开启';
const localDecryptOff = '每次使用需在手机上批准';
const localDecryptRisk = '开启后，相关变量库的密钥将保存在此设备上，能访问此设备文件的人员或程序均可解密其中的变量。';

/// 一个环境的授权设置。期限是选项文字；已有授权的到期时间不在选项里时，是它的到期说明。
/// 期限只对无人值守使用有意义：需手机批准的授权一直有效（设计文档 19.3）。
typedef GrantDraft = ({String role, String expiry, bool local});

/// 新添加的环境：只读、不开启无人值守使用。
const newGrantDraft = (role: 'ro', expiry: _forever, local: defaultLocalDecrypt);

GrantDraft draftOf(Grant g) => (role: g.role, expiry: formatExpiry(g.expiresAt), local: g.localDecrypt);

/// 按面板里的设置生成授权：期限没改时沿用原来的到期时间，激活状态和顺序不变；
/// 没有开启无人值守使用时一直有效（以前设过期限的，这次保存后改为一直有效）。
Grant grantFrom(String envId, GrantDraft d, Grant? old) {
  int expiresAt = 0;
  if (d.local) expiresAt = _expiryChoices.containsKey(d.expiry) ? expiryFrom(d.expiry) : (old?.expiresAt ?? 0);
  return Grant(
    envId,
    d.role,
    expiresAt,
    localDecrypt: d.local,
    active: old?.active ?? true,
    position: old?.position ?? 0,
  );
}

/// 行上的说明，例如“读写”；开启无人值守使用时带期限和醒目的标记，未激活时注明。
/// 需手机批准的授权一直有效，只有以前设过期限的才显示到期时间。
Widget grantSummary(BuildContext context, GrantDraft d, {bool active = true}) {
  final p = context.palette;
  final text = [
    roleNames[d.role] ?? d.role,
    if (d.local || d.expiry != _forever) d.expiry,
    if (!active) '未激活',
  ].join(' · ');
  if (!d.local) return Text(text);
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(text: '$text  '),
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: p.warnBox, borderRadius: BorderRadius.circular(6)),
            child: Text(
              '本机解密',
              style: TextStyle(color: p.onWarnBox, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    ),
  );
}

/// 打开一个环境的授权面板。[onSave] 在面板之上执行（可以再验证身份），返回 true 时关闭面板；
/// [onRemove] 为 null 表示这是新添加的环境，不显示“取消对这个环境的授权”。
Future<void> showGrantSheet(
  BuildContext context, {
  required String envName,
  required String deviceName,
  required GrantDraft initial,
  required Future<bool> Function(BuildContext, GrantDraft) onSave,
  Future<bool> Function(BuildContext)? onRemove,
}) => showAppSheet<void>(
  context,
  builder: (_) =>
      _GrantSheet(envName: envName, deviceName: deviceName, initial: initial, onSave: onSave, onRemove: onRemove),
);

class _GrantSheet extends StatefulWidget {
  const _GrantSheet({
    required this.envName,
    required this.deviceName,
    required this.initial,
    required this.onSave,
    required this.onRemove,
  });
  final String envName, deviceName;
  final GrantDraft initial;
  final Future<bool> Function(BuildContext, GrantDraft) onSave;
  final Future<bool> Function(BuildContext)? onRemove;

  @override
  State<_GrantSheet> createState() => _GrantSheetState();
}

class _GrantSheetState extends State<_GrantSheet> {
  late GrantDraft _d = widget.initial;

  /// “高级”默认收起；已经开启无人值守使用的授权默认展开（设计文档 19.3）。
  late bool _advanced = widget.initial.local;

  void _setLocal(bool on) => setState(() {
    // 新开启时期限从“长期有效”开始，不沿用以前需手机批准时留下的到期时间。
    final expiry = on && !widget.initial.local ? _forever : _d.expiry;
    _d = (role: _d.role, expiry: expiry, local: on);
  });

  bool get _adding => widget.onRemove == null;

  Future<void> _save() async {
    // 新开启本机解密时先说明风险（设计文档 17.2）。
    if (_d.local && !widget.initial.local) {
      final ok = await confirmDialog(
        context,
        title: '允许“${widget.deviceName}”无人值守使用？',
        body: localDecryptRisk,
        ok: '允许',
      );
      if (!ok || !mounted) return;
    }
    if (await widget.onSave(context, _d) && mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    if (await widget.onRemove!(context) && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glass = usesGlass(context);
    final expiryOptions = {..._expiryChoices.keys, _d.expiry, if (widget.initial.local) widget.initial.expiry};
    return SafeArea(
      top: false,
      bottom: !glass,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, glass ? 4 : 0, 24, glass ? 24 : Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.envName,
              style: TextStyle(color: p.ink, fontSize: glass ? 22 : 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('授权给“${widget.deviceName}”', style: TextStyle(color: p.mute, fontSize: 13)),
            const SizedBox(height: Space.xl),
            const Text('权限'),
            const SizedBox(height: Space.sm),
            AppSegmented<String>(
              options: const [(value: 'ro', label: '只读'), (value: 'rw', label: '读写')],
              value: _d.role,
              onChanged: (v) => setState(() => _d = (role: v, expiry: _d.expiry, local: _d.local)),
            ),
            const SizedBox(height: Space.lg),
            Semantics(
              button: true,
              expanded: _advanced,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _advanced = !_advanced),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('高级', style: TextStyle(color: p.mute)),
                      ),
                      AnimatedRotation(
                        turns: _advanced ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.expand_more, color: p.mute),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: !_advanced
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: Space.sm),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('无人值守使用（本机解密）'),
                                  const SizedBox(height: 2),
                                  Text(
                                    tidy(_d.local ? localDecryptOn : localDecryptOff),
                                    style: TextStyle(color: p.mute, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: Space.md),
                            AppSwitch(value: _d.local, onChanged: _setLocal),
                          ],
                        ),
                        if (_d.local) ...[
                          const SizedBox(height: Space.lg),
                          SizedBox(
                            height: 32,
                            child: Row(
                              children: [
                                const Expanded(child: Text('期限')),
                                // 玻璃菜单的触发处左右各有 8 的按压余量，向右挪回，让文字与开关的右边缘对齐。
                                Transform.translate(
                                  offset: Offset(glass ? 8 : 0, 0),
                                  child: AppSelect<String>(
                                    semanticLabel: '“${widget.envName}”无人值守使用的期限',
                                    value: _d.expiry,
                                    options: [for (final k in expiryOptions) (value: k, label: k)],
                                    onChanged: (v) => setState(() => _d = (role: _d.role, expiry: v, local: _d.local)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text('到期后这台电脑不能再使用这个环境', style: TextStyle(color: p.mute, fontSize: 13)),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: Space.xl),
            FilledButton(onPressed: _adding || _d != widget.initial ? _save : null, child: Text(_adding ? '添加' : '保存')),
            if (!_adding) ...[
              const SizedBox(height: Space.sm),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: _remove,
                child: const Text('取消对这个环境的授权'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 从还没授权的环境中选一个；取消时返回 null。
Future<Environment?> pickEnvironment(BuildContext context, List<Environment> envs) => showAppSheet<Environment>(
  context,
  builder: (c) {
    final p = c.palette;
    final glass = usesGlass(c);
    return SafeArea(
      top: false,
      bottom: !glass,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(24, glass ? 4 : 0, 24, Space.sm),
              child: Text(
                '添加环境',
                style: TextStyle(color: p.ink, fontSize: glass ? 22 : 20, fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, glass ? Space.lg : Space.sm),
                children: [
                  for (final e in envs)
                    ListTile(
                      contentPadding: listRowPadding,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      leading: Icon(glass ? CupertinoIcons.square_stack_3d_up : Icons.layers_outlined),
                      title: Text(e.name),
                      subtitle: Text('${e.items.length} 个变量'),
                      trailing: const ListRowChevron(),
                      onTap: () => Navigator.pop(c, e),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  },
);

/// 卡片末尾的“添加环境”一行。
class AddEnvironmentRow extends StatelessWidget {
  const AddEnvironmentRow({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return ListTile(
      contentPadding: listRowPadding,
      leading: Icon(usesGlass(context) ? CupertinoIcons.add : Icons.add, color: accent),
      title: Text(
        '添加环境',
        style: TextStyle(color: accent, fontWeight: FontWeight.w600),
      ),
      onTap: onTap,
    );
  }
}
