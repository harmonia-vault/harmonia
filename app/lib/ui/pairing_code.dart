// 一次性配对码：管理设备选好有效期后生成，并显示剩余时间；新手机发起接入时可以填写（docs/rewrite-plan.md 5.10）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'glass_controls.dart';
import 'glass_overlays.dart';
import 'theme.dart';
import 'widgets.dart';

/// 配对码可选的有效期（分钟），默认 10 分钟（协议 3.2）。
const _minuteChoices = [5, 10, 15, 30, 60];

/// 生成配对码前选择有效期的一行。
class PairingExpiryRow extends StatelessWidget {
  const PairingExpiryRow({super.key, required this.minutes, required this.onChanged});
  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text('有效期', style: TextStyle(color: context.palette.ink)),
      ),
      AppSelect<int>(
        semanticLabel: '配对码的有效期',
        value: minutes,
        options: [for (final m in _minuteChoices) (value: m, label: '$m 分钟')],
        onChanged: onChanged,
      ),
    ],
  );
}

/// 剩余时间，例如 9:58。
String formatLeft(DateTime expiresAt) {
  final left = expiresAt.difference(DateTime.now());
  return '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// 在管理设备上选好有效期后生成配对码并显示，到期后可以重新生成。已有的配对码不受影响。
Future<void> showPairingCode(BuildContext context, AppController c) => showAppDialog<void>(
  context: context,
  useRootNavigator: false,
  builder: (_) => _PairingCodeDialog(c: c),
);

class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog({required this.c});
  final AppController c;
  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  int _minutes = 10;
  PairingCode? _code;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    PairingCode? fresh;
    final c = widget.c;
    final ok = await runBusy(
      context,
      () async => fresh = await c.guard(() => c.vault.createPairingCode(minutes: _minutes)),
    );
    if (!ok || fresh == null || !mounted) return;
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() => _code = fresh);
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final valid = code != null && code.expiresAt.isAfter(DateTime.now());
    return AppAlertDialog(
      title: const Text('配对码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tidy('在要接入的电脑（harmonia login）或手机（接入这台手机）上输入这个配对码。')),
          const SizedBox(height: Space.md),
          if (valid) ...[
            CodeBox(code.formatted, big: true),
            const SizedBox(height: Space.sm),
            Text('剩余 ${formatLeft(code.expiresAt)}，只能用一次', style: TextStyle(color: context.palette.mute)),
            const SizedBox(height: Space.md),
            const Banner2('对方发起后，这里会直接弹出批准页。批准前仍要核对两边显示的核对码一致。'),
          ] else ...[
            if (code != null) ...[
              Text('配对码已过期', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: Space.sm),
            ],
            PairingExpiryRow(minutes: _minutes, onChanged: (m) => setState(() => _minutes = m)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        if (!valid) FilledButton(onPressed: _generate, child: Text(code == null ? '生成' : '重新生成')),
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
