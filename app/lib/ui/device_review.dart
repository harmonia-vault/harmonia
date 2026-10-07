// 恢复后检查其他设备：恢复不会让已有设备失效，在这里勾选丢失的设备，验证一次身份后一并移除。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/api.dart';
import '../core/models.dart';
import 'devices.dart' show platformIcon, platformName;
import 'lock.dart';
import 'theme.dart';
import 'widgets.dart';

/// 账号中除本机以外的设备，管理手机在前。
List<DeviceInfo> otherDevices(AppController c) {
  final me = c.vault.config!.deviceId;
  final others = c.vault.devices.where((d) => d.id != me);
  return [...others.where((d) => d.isManager), ...others.where((d) => !d.isManager)];
}

class DeviceReviewView extends StatefulWidget {
  const DeviceReviewView({super.key, required this.c, required this.onDone});
  final AppController c;
  final VoidCallback onDone;
  @override
  State<DeviceReviewView> createState() => _DeviceReviewViewState();
}

class _DeviceReviewViewState extends State<DeviceReviewView> {
  final _selected = <String>{};

  /// 上次没能移除的设备及原因。
  Map<String, String> _failed = {};

  AppController get c => widget.c;

  Future<void> _remove() async {
    final picked = otherDevices(c).where((d) => _selected.contains(d.id)).toList();
    final ok = await confirmDialog(context,
        title: '移除 ${picked.length} 台设备？',
        body: '${picked.map((d) => '“${d.name}”').join('、')}将立即失去访问权限，联网后会自动清除本机保存的变量。'
            '已经被复制或正在运行的程序中的变量无法收回，必要时请在服务商处更换相应的密钥。',
        ok: '移除',
        danger: true);
    if (!ok || !mounted) return;
    if (!await confirmIdentity(context, '验证身份以移除所选的 ${picked.length} 台设备')) return;
    if (!mounted) return;
    final failed = <String, String>{};
    await runBusy(context, () => c.guard(() async {
          for (final d in picked) {
            try {
              await c.vault.revokeDevice(d.id);
            } on ApiException catch (e) {
              failed[d.id] = e.message;
            }
          }
        }));
    if (!mounted) return;
    final left = otherDevices(c).map((d) => d.id).toSet().intersection(_selected);
    if (left.isEmpty) return widget.onDone();
    setState(() {
      _selected.retainAll(left);
      _failed = {for (final id in left) id: failed[id] ?? '没有移除成功'};
    });
    toast(context, '有 ${left.length} 台设备没有移除，请检查网络后重试');
  }

  Widget _tile(DeviceInfo d) {
    final reason = _failed[d.id];
    return Card(
      child: CheckboxListTile(
        value: _selected.contains(d.id),
        onChanged: (v) => setState(() {
          if (v == true) {
            _selected.add(d.id);
          } else {
            _selected.remove(d.id);
          }
        }),
        secondary: Icon(platformIcon(d.platform)),
        title: Text(d.name),
        subtitle: Text(
          '${platformName(d.platform)} · 最近活动 ${formatTime(d.lastSeenAt)}${reason == null ? '' : '\n$reason'}',
          style: reason == null ? null : TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = otherDevices(c);
    final managers = devices.where((d) => d.isManager);
    final clients = devices.where((d) => !d.isManager);
    return AuthScaffold(
      title: '检查其他设备',
      subtitle: '恢复不会让账号中的其他设备失效。旧手机仍然可以访问全部环境，也能批准和移除设备。',
      children: [
        const Banner2('已丢失或不再使用的设备，请勾选后移除；还在使用的设备不用勾选。', warn: true),
        if (managers.isNotEmpty) ...[const SectionTitle('管理手机'), ...managers.map(_tile)],
        if (clients.isNotEmpty) ...[const SectionTitle('电脑'), ...clients.map(_tile)],
        const SizedBox(height: Space.xl),
        if (_selected.isEmpty)
          FilledButton(onPressed: widget.onDone, child: const Text('完成'))
        else ...[
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: _remove,
            child: Text('移除所选（${_selected.length} 台）'),
          ),
          const SizedBox(height: Space.md),
          TextButton(onPressed: widget.onDone, child: const Text('不移除，直接完成')),
        ],
      ],
    );
  }
}
