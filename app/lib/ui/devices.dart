// 设备列表、设备详情与权限调整。添加和批准设备见 pairing.dart。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/models.dart';
import 'activation.dart';
import 'environments.dart' show askName;
import 'lock.dart';
import 'pairing.dart';
import 'theme.dart';
import 'glass.dart';
import 'glass_controls.dart';
import 'widgets.dart';
import 'list_row.dart';

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

  @override
  Widget build(BuildContext context) {
    if (_seenCount != c.pendingPairingCount) {
      _seenCount = c.pendingPairingCount;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPending());
    }
    final devices = [...c.vault.devices]..sort((a, b) => (a.isManager ? 0 : 1).compareTo(b.isManager ? 0 : 1));
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
      floatingActionButton: AddDeviceMenu(
        c: c,
        onDone: _refreshAfterAdd,
        trigger: (context, open) =>
            FloatingActionButton.extended(onPressed: open, icon: const Icon(Icons.add), label: const Text('添加设备')),
      ),
      onRefresh: () async {
        await c.syncNow();
        await _loadPending();
      },
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
                  contentPadding: listRowPadding,
                  leading: Icon(platformIcon(p.platform)),
                  title: Text(p.name),
                  subtitle: Text('${platformName(p.platform)} · 请求接入'),
                  trailing: const ListRowChevron(),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReviewPairingPage(c: c, request: p, scanned: false),
                      ),
                    );
                    _loadPending();
                  },
                ),
              ),
            ),
        ],
        const SectionTitle('已授权的设备'),
        Card(
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
                        ? '管理设备 · ${formatTime(d.lastSeenAt)}活动'
                        : '${d.grants.length} 个环境 · ${formatTime(d.lastSeenAt)}活动',
                  ),
                  trailing: const ListRowChevron(),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DevicePage(c: c, deviceId: d.id),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Space.md),
        Text(
          tidy('在电脑上运行 harmonia login 后，点击“添加设备”扫描终端里的二维码；也可以先在“添加设备”中生成配对码，用配对码发起的请求会出现在上面的“等待批准”中。'),
          style: TextStyle(color: context.palette.mute, height: 1.5),
        ),
      ],
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
  const GrantEditor({
    super.key,
    required this.envs,
    required this.roles,
    required this.expiry,
    required this.onChanged,
  });
  final List<Environment> envs;
  final Map<String, String?> roles;
  final Map<String, String> expiry;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, e) in envs.indexed) ...[
          if (i > 0) const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: Space.sm),
                AppSegmented<String>(
                  options: const [
                    (value: 'none', label: '无'),
                    (value: 'ro', label: '只读'),
                    (value: 'rw', label: '读写'),
                    (value: 'admin', label: '管理'),
                  ],
                  value: roles[e.id] ?? 'none',
                  onChanged: (v) {
                    roles[e.id] = v == 'none' ? null : v;
                    onChanged();
                  },
                ),
                if (roles[e.id] != null) ...[
                  const SizedBox(height: Space.sm),
                  AppSelect<String>(
                    semanticLabel: '“${e.name}”的有效期',
                    value: expiry[e.id] ?? '长期有效',
                    options: [
                      for (final k in {..._expiryChoices.keys, if (expiry[e.id] != null) expiry[e.id]!})
                        (value: k, label: k),
                    ],
                    onChanged: (v) {
                      expiry[e.id] = v;
                      onChanged();
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    ),
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
    if (_roles == null) _reset(d);
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
            if (d.grants.isNotEmpty) ActivationEditor(c: c, device: d),
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
              child: Banner2('管理设备可以访问全部环境，并能批准和移除其他设备。'),
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
