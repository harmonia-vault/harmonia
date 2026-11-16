import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'widgets.dart';
import 'glass.dart';

String shellLabel(DeviceInfo d) => d.platform == 'windows' ? '写入用户环境变量' : 'Shell 集成';

Future<bool> confirmShellEnabled(BuildContext context, DeviceInfo d) => confirmDialog(
  context,
  title: '开启${shellLabel(d)}？',
  body: '开启无人值守使用的环境中的变量会保存在“${d.name}”上，并自动提供给这台电脑运行的程序。',
  ok: '开启',
);

class DeviceShellSection extends StatefulWidget {
  const DeviceShellSection({super.key, required this.c, required this.device});
  final AppController c;
  final DeviceInfo device;

  @override
  State<DeviceShellSection> createState() => _DeviceShellSectionState();
}

class _DeviceShellSectionState extends State<DeviceShellSection> {
  Future<void> _set(bool on) async {
    if (on && !await confirmShellEnabled(context, widget.device)) return;
    if (!mounted) return;
    await runBusy(context, () => widget.c.guard(() => widget.c.vault.setShellEnabled(widget.device.id, on)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.c,
    builder: (context, _) {
      final d = widget.c.vault.devices.where((d) => d.id == widget.device.id).firstOrNull;
      if (d == null) return const SizedBox.shrink();
      final status = d.shellPending ? '等待设备同步' : d.shellError ?? (d.shellEnabled ? '已开启' : '已关闭');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('自动加载变量'),
          Card(
            child: AppSwitchTile(
              title: Text(shellLabel(d)),
              subtitle: Text(status),
              value: d.shellEnabled,
              onChanged: _set,
            ),
          ),
        ],
      );
    },
  );
}
