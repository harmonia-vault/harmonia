// 一次性配对码：管理设备生成并显示剩余时间；新手机发起接入时可以填写（docs/rewrite-plan.md 5.10）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'glass_overlays.dart';
import 'theme.dart';
import 'widgets.dart';

/// 在管理设备上生成配对码并显示，到期后可以重新生成。重新生成会作废上一个。
Future<void> showPairingCode(BuildContext context, AppController c) async {
  PairingCode? code;
  final ok = await runBusy(context, () async => code = await c.guard(c.vault.createPairingCode));
  if (!ok || code == null || !context.mounted) return;
  await showAppDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _PairingCodeDialog(c: c, initial: code!),
  );
}

class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog({required this.c, required this.initial});
  final AppController c;
  final PairingCode initial;
  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  late PairingCode _code = widget.initial;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Duration get _left => _code.expiresAt.difference(DateTime.now());

  Future<void> _regenerate() async {
    PairingCode? fresh;
    final ok = await runBusy(context, () async => fresh = await widget.c.guard(widget.c.vault.createPairingCode));
    if (ok && fresh != null && mounted) setState(() => _code = fresh!);
  }

  @override
  Widget build(BuildContext context) {
    final left = _left;
    final expired = left <= Duration.zero;
    final mmss = '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
    return AppAlertDialog(
      title: const Text('配对码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tidy('在要接入的电脑（harmonia login）或手机（接入这台手机）上输入这个配对码。')),
          const SizedBox(height: Space.md),
          Opacity(opacity: expired ? 0.4 : 1, child: CodeBox(_code.formatted, big: true)),
          const SizedBox(height: Space.sm),
          Text(
            expired ? '配对码已过期，请重新生成。' : '剩余 $mmss，只能用一次',
            style: TextStyle(color: expired ? Theme.of(context).colorScheme.error : context.palette.mute),
          ),
          const SizedBox(height: Space.md),
          const Banner2('对方发起后，这里会直接弹出批准页。批准前仍要核对两边显示的核对码一致。'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        if (expired) FilledButton(onPressed: _regenerate, child: const Text('重新生成')),
      ],
    );
  }
}

/// 新手机发起接入前询问配对码。返回 null 表示取消，空字符串表示不用配对码（扫码方式）。
Future<String?> askPairingCode(BuildContext context) {
  final ctl = TextEditingController();
  return showAppDialog<String>(
    context: context,
    useRootNavigator: false,
    builder: (c) => AppAlertDialog(
      title: const Text('接入这台手机'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tidy('有配对码时填写，管理设备会直接弹出批准页；没有时留空，用管理设备扫描这台手机显示的二维码。')),
          const SizedBox(height: Space.md),
          TextField(
            controller: ctl,
            autofillHints: null,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 18),
            decoration: const InputDecoration(
              labelText: '配对码（可以留空）',
              hintText: 'XXXX-XXXX',
              helperText: '在管理设备的“设备 → 添加设备 → 生成配对码”中获取',
            ),
            onSubmitted: (v) => Navigator.pop(c, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('继续')),
      ],
    ),
  );
}
