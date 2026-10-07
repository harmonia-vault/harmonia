// 设备列表、设备详情与权限调整。添加和批准设备见 pairing.dart。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'environments.dart' show askName;
import 'lock.dart';
import 'pairing.dart';
import 'theme.dart';
import 'widgets.dart';

IconData platformIcon(String p) => switch (p) {
      'android' => Icons.phone_android,
      'darwin' => Icons.laptop_mac_outlined,
      'linux' => Icons.computer_outlined,
      _ => Icons.devices_other_outlined,
    };

String platformName(String p) =>
    {'android': 'Android 手机', 'darwin': 'macOS', 'linux': 'Linux'}[p] ?? p;

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
      final list = await c.vault.pendingPairings();
      c.pairings = list;
      c.refresh();
      if (mounted) setState(() => _pending = list);
    } catch (_) {
      // 离线时不显示待处理请求。
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  @override
  Widget build(BuildContext context) {
    if (_seenCount != c.pendingPairingCount) {
      _seenCount = c.pendingPairingCount;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPending());
    }
    final devices = [...c.vault.devices]..sort((a, b) => (a.isManager ? 0 : 1).compareTo(b.isManager ? 0 : 1));
    final me = c.vault.config!.deviceId;
    return Scaffold(
      appBar: AppBar(title: const Text('设备')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => AddDevicePage(c: c)));
          _loadPending();
        },
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('添加设备'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await c.syncNow();
          await _loadPending();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 96),
          children: [
            if (_pending.isNotEmpty) ...[
              const SectionTitle('等待批准'),
              for (final p in _pending)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: Card(
                    color: context.palette.yellow.withValues(alpha: 0.35),
                    child: ListTile(
                      leading: Icon(platformIcon(p.platform)),
                      title: Text(p.name),
                      subtitle: Text('${platformName(p.platform)} · 请求接入'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.push(context,
                            MaterialPageRoute(builder: (_) => ReviewPairingPage(c: c, request: p, scanned: false)));
                        _loadPending();
                      },
                    ),
                  ),
                ),
            ],
            const SectionTitle('已授权的设备'),
            Card(
              child: Column(children: [
                for (final (i, d) in devices.indexed) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    leading: Icon(platformIcon(d.platform)),
                    title: Text(d.id == me ? '${d.name}（本机）' : d.name),
                    subtitle: Text(d.isManager
                        ? '管理手机 · ${formatTime(d.lastSeenAt)}活动'
                        : '${d.grants.length} 个环境 · ${formatTime(d.lastSeenAt)}活动'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => DevicePage(c: c, deviceId: d.id))),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: Space.md),
            Text('在电脑上运行 harmonia login 后，点击“添加设备”扫描终端里的二维码。',
                style: TextStyle(color: context.palette.mute, height: 1.5)),
          ],
        ),
      ),
    );
  }
}

const _expiryChoices = <String, Duration?>{
  '长期有效': null,
  '1 天': Duration(days: 1),
  '7 天': Duration(days: 7),
  '30 天': Duration(days: 30),
  '90 天': Duration(days: 90),
};

int expiryFrom(String label) {
  final d = _expiryChoices[label];
  return d == null ? 0 : DateTime.now().add(d).millisecondsSinceEpoch;
}

/// 编辑一台电脑对各环境的权限。null 表示无权限。
class GrantEditor extends StatelessWidget {
  const GrantEditor({super.key, required this.envs, required this.roles, required this.expiry, required this.onChanged});
  final List<Environment> envs;
  final Map<String, String?> roles;
  final Map<String, String> expiry;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, e) in envs.indexed) ...[
            if (i > 0) const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: Space.sm),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'none', label: Text('无')),
                    ButtonSegment(value: 'ro', label: Text('只读')),
                    ButtonSegment(value: 'rw', label: Text('读写')),
                    ButtonSegment(value: 'admin', label: Text('管理')),
                  ],
                  selected: {roles[e.id] ?? 'none'},
                  onSelectionChanged: (s) {
                    roles[e.id] = s.first == 'none' ? null : s.first;
                    onChanged();
                  },
                ),
                if (roles[e.id] != null) ...[
                  const SizedBox(height: Space.sm),
                  DropdownButton<String>(
                    value: expiry[e.id] ?? '长期有效',
                    isDense: true,
                    items: [
                      for (final k in {..._expiryChoices.keys, if (expiry[e.id] != null) expiry[e.id]!})
                        DropdownMenuItem(value: k, child: Text(k)),
                    ],
                    onChanged: (v) {
                      expiry[e.id] = v!;
                      onChanged();
                    },
                  ),
                ],
              ]),
            ),
          ],
        ]),
      );
}

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.c, required this.deviceId});
  final AppController c;
  final String deviceId;
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  Map<String, String?>? _roles;
  final _expiry = <String, String>{};
  bool _dirty = false;

  AppController get c => widget.c;

  DeviceInfo? get _device => c.vault.devices.where((d) => d.id == widget.deviceId).firstOrNull;

  void _reset(DeviceInfo d) {
    _roles = {for (final g in d.grants) g.envId: g.role};
    _expiry.clear();
    for (final g in d.grants) {
      if (g.expiresAt != 0) _expiry[g.envId] = formatExpiry(g.expiresAt);
    }
    _dirty = false;
  }

  Future<void> _save(DeviceInfo d) async {
    final grants = <Grant>[];
    for (final e in c.vault.environments) {
      final role = _roles![e.id];
      if (role == null) continue;
      final label = _expiry[e.id] ?? '长期有效';
      final old = d.grants.where((g) => g.envId == e.id).firstOrNull;
      final expiresAt = _expiryChoices.containsKey(label) ? expiryFrom(label) : (old?.expiresAt ?? 0);
      grants.add(Grant(e.id, role, expiresAt));
    }
    if (!await confirmIdentity(context, '验证身份以修改“${d.name}”的权限')) return;
    if (!mounted) return;
    final ok = await runBusy(context, () => c.guard(() => c.vault.updateGrants(d, grants)), done: '权限已更新');
    if (ok && mounted) setState(() => _reset(_device!));
  }

  Future<void> _revoke(DeviceInfo d) async {
    final me = d.id == c.vault.config!.deviceId;
    if (me) return;
    final ok = await confirmDialog(context,
        title: '移除“${d.name}”？',
        body: '这台设备将立即失去访问权限，联网后会自动清除本机保存的变量。已经被复制或正在运行的程序中的变量无法收回，必要时请在服务商处更换相应的密钥。',
        ok: '移除',
        danger: true);
    if (!ok || !mounted) return;
    if (!await confirmIdentity(context, '验证身份以移除“${d.name}”')) return;
    if (!mounted) return;
    final nav = Navigator.of(context);
    final done = await runBusy(context, () => c.guard(() => c.vault.revokeDevice(d.id)), done: '已移除');
    if (done) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final d = _device;
    if (d == null) return const Scaffold(body: Center(child: Text('设备已被移除')));
    if (_roles == null) _reset(d);
    final me = d.id == c.vault.config!.deviceId;
    return Scaffold(
      appBar: AppBar(
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
      body: ListView(padding: const EdgeInsets.all(Space.lg), children: [
        Card(
          child: Column(children: [
            ListTile(leading: Icon(platformIcon(d.platform)), title: Text(platformName(d.platform)),
                subtitle: Text(d.isManager ? '管理手机' : '电脑')),
            const Divider(),
            ListTile(title: const Text('接入时间'), trailing: Text(formatTime(d.createdAt))),
            const Divider(),
            ListTile(title: const Text('最近活动'), trailing: Text(formatTime(d.lastSeenAt))),
          ]),
        ),
        if (!d.isManager) ...[
          const SectionTitle('环境权限'),
          if (c.vault.environments.isEmpty)
            const Banner2('还没有环境。')
          else
            GrantEditor(
              envs: c.vault.environments,
              roles: _roles!,
              expiry: _expiry,
              onChanged: () => setState(() => _dirty = true),
            ),
          const SizedBox(height: Space.lg),
          FilledButton(onPressed: _dirty ? () => _save(d) : null, child: const Text('保存权限')),
        ] else
          const Padding(
            padding: EdgeInsets.only(top: Space.lg),
            child: Banner2('管理手机可以访问全部环境，并能批准和移除其他设备。'),
          ),
        if (!me) ...[
          const SizedBox(height: Space.xl),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => _revoke(d),
            child: const Text('移除这台设备'),
          ),
        ],
      ]),
    );
  }
}
