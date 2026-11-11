// 设备列表、设备详情与权限调整。添加和批准设备见 pairing.dart。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'approval.dart' show AuthorizationsSection;
import 'approval_list.dart';
import 'device_grants.dart';
import 'device_update.dart';
import 'vaults.dart' show askName;
import 'lock.dart';
import 'pairing.dart';
import 'theme.dart';
import 'glass.dart';
import 'widgets.dart';
import 'list_row.dart';
import 'workspace_scope.dart';

IconData platformIcon(String p) => switch (p) {
  'android' => Icons.phone_android,
  'ios' => Icons.phone_iphone,
  'darwin' => Icons.laptop_mac_outlined,
  'linux' => Icons.computer_outlined,
  'windows' => Icons.desktop_windows_outlined,
  _ => Icons.devices_other_outlined,
};

String platformName(String p) =>
    {'android': 'Android 手机', 'ios': 'iPhone', 'darwin': 'macOS', 'linux': 'Linux', 'windows': 'Windows'}[p] ?? p;

class DevicesTab extends StatefulWidget {
  const DevicesTab({super.key, required this.c});
  final AppController c;
  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<DevicesTab> {
  List<PairingRequest> _pending = [];
  int _seenCount = -1;

  AppController get c => widget.c;

  Future<void> _loadPending() async {
    try {
      c.pairings = await c.vault.pendingPairings();
      c.refresh();
      // 匿名请求不列出：只能扫码或手输核对码取到。
      if (mounted) setState(() => _pending = c.authorizedPairings);
    } catch (_) {
      // 离线时不显示待处理请求。
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  void _refreshAfterAdd() {
    if (mounted) _loadPending();
  }

  Widget _deviceList(List<DeviceInfo> devices, String me) => Card(
    child: Column(
      children: [
        for (final (i, d) in devices.indexed) ...[
          if (i > 0) const Divider(),
          ListTile(
            contentPadding: listRowPadding,
            leading: Icon(platformIcon(d.platform)),
            title: Text(d.id == me ? '${d.name}（本机）' : d.name),
            subtitle: Text(
              d.isManager
                  ? '${platformName(d.platform)} · ${formatTime(d.lastSeenAt)}活动'
                  : '${d.grants.length} 个环境 · ${formatTime(d.lastSeenAt)}活动',
            ),
            trailing: const ListRowChevron(),
            selected: WorkspaceScope.maybeOf(context)?.selected[2]?.id == 'device:${d.id}',
            onTap: () => openWorkspaceEntry(
              context,
              WorkspaceEntry(
                tab: 2,
                id: 'device:${d.id}',
                title: d.name,
                page: (_) => DevicePage(c: c, deviceId: d.id),
              ),
            ),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_seenCount != c.pendingPairingCount) {
      _seenCount = c.pendingPairingCount;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPending());
    }
    final managers = [
      for (final d in c.vault.devices)
        if (d.isManager) d,
    ];
    final clients = [
      for (final d in c.vault.devices)
        if (!d.isManager) d,
    ];
    final me = c.vault.config!.deviceId;
    return AppTabPage(
      title: '设备',
      actions: [
        AddDeviceMenu(
          c: c,
          onDone: _refreshAfterAdd,
          trigger: (context, open) => IconButton(tooltip: '添加设备', onPressed: open, icon: const Icon(Icons.add)),
        ),
      ],

      onRefresh: () async {
        await c.syncNow();
        await _loadPending();
        await c.refreshApprovals();
      },
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96),
      children: [
        if (_pending.isNotEmpty || c.approvals.isNotEmpty) ...[
          const SectionTitle('等待批准'),
          PendingApprovals(c: c),
          for (final p in _pending)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Card(
                color: context.palette.yellow.withValues(alpha: 0.35),
                child: ListTile(
                  contentPadding: listRowPadding,
                  leading: Icon(platformIcon(p.platform)),
                  title: Text(p.name),
                  subtitle: Text('${platformName(p.platform)} · 请求接入'),
                  trailing: const ListRowChevron(),
                  onTap: () async {
                    await openWorkspaceEntry(
                      context,
                      WorkspaceEntry(
                        tab: 2,
                        id: 'pairing:${p.id}',
                        title: p.name,
                        page: (_) => ReviewPairingPage(c: c, request: p, scanned: false),
                      ),
                    );
                    _loadPending();
                  },
                ),
              ),
            ),
        ],
        const SectionTitle('管理设备'),
        _deviceList(managers, me),
        if (clients.isNotEmpty) ...[const SectionTitle('CLI'), _deviceList(clients, me)],
        const SizedBox(height: Space.md),
        Text(
          tidy('在电脑上运行 harmonia login 后，点击“添加设备”扫描终端里的二维码；也可以先在“添加设备”中生成配对码，用配对码发起的请求会出现在上面的“等待批准”中。'),
          style: TextStyle(color: context.palette.mute, height: 1.5),
        ),
      ],
    );
  }
}

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.c, required this.deviceId});
  final AppController c;
  final String deviceId;
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  AppController get c => widget.c;

  DeviceInfo? get _device => c.vault.devices.where((d) => d.id == widget.deviceId).firstOrNull;

  Future<void> _revoke(DeviceInfo d) async {
    final me = d.id == c.vault.config!.deviceId;
    if (me) return;
    final ok = await confirmDialog(
      context,
      title: '移除“${d.name}”？',
      body:
          '这台设备将立即失去访问权限，联网后会自动清除本机保存的变量。\n'
          '已经被复制或正在运行的程序中的变量无法收回，必要时请在服务商处更换相应的密钥。',
      ok: '移除',
      danger: true,
    );
    if (!ok || !mounted) return;
    if (!await confirmIdentity(context, '验证身份以移除“${d.name}”')) return;
    if (!mounted) return;
    final nav = Navigator.of(context);
    final done = await runBusy(context, () => c.guard(() => c.vault.revokeDevice(d.id)), done: '已移除');
    if (done) nav.pop();
  }

  Future<void> _setSystemVars(DeviceInfo d, bool on) async {
    if (on) {
      final ok = await confirmDialog(
        context,
        title: '写入系统变量？',
        body:
            '开启后，账号里名为 Path、TEMP 之类的变量会写入“${d.name}”的用户环境变量。\n'
            '写错会影响这台电脑上的所有程序。原来的值会先记下，关闭后恢复。',
        ok: '开启',
      );
      if (!ok || !mounted) return;
    }
    await runBusy(context, () => c.guard(() => c.vault.setSystemVars(d.id, on)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final d = _device;
    if (d == null) return const Scaffold(body: Center(child: Text('设备已被移除')));
    final me = d.id == c.vault.config!.deviceId;
    return AppPage(
      appBar: AppBarSurface(
        title: Text(d.name),
        actions: [
          IconButton(
            tooltip: '重命名',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final name = await askName(context, title: '重命名设备', initial: d.name);
              if (name == null || !context.mounted) return;
              await runBusy(context, () => c.guard(() => c.vault.renameDevice(d.id, name)));
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: (context) => ListView(
        padding: pagePadding(context, const EdgeInsets.all(Space.lg)),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(platformIcon(d.platform)),
                  title: Text(platformName(d.platform)),
                  subtitle: Text(d.isManager ? '管理设备' : '电脑'),
                ),
                const Divider(),
                ListTile(title: const Text('接入时间'), trailing: Text(formatTime(d.createdAt))),
                const Divider(),
                ListTile(title: const Text('最近活动'), trailing: Text(formatTime(d.lastSeenAt))),
                const Divider(),
                ListTile(title: const Text('版本'), trailing: Text(d.version.isEmpty ? '未知' : d.version)),
              ],
            ),
          ),
          if (!d.isManager) ...[
            DeviceGrants(c: c, deviceId: d.id),
            AuthorizationsSection(c: c, device: d),
            CliUpdateSection(c: c, deviceId: d.id),
            if (d.platform == 'windows') ...[
              const SectionTitle('系统变量'),
              Card(
                child: AppSwitchTile(
                  title: const Text('写入系统变量'),
                  subtitle: Text(tidy('Path、TEMP 这类 Windows 自身使用的变量，默认不写入这台电脑。')),
                  value: d.systemVars,
                  onChanged: (on) => _setSystemVars(d, on),
                ),
              ),
            ],
          ] else
            const Padding(
              padding: EdgeInsets.only(top: Space.lg),
              child: Banner2('管理设备可以访问全部变量库和环境，并能批准和移除其他设备。'),
            ),
          if (!me) ...[
            const SizedBox(height: Space.xl),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => _revoke(d),
              child: const Text('移除这台设备'),
            ),
          ],
        ],
      ),
    );
  }
}
