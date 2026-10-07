// 添加设备（扫码 / 核对码 → 核对 → 选择权限 → 批准），以及收到配对请求时弹出的批准页。
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/controller.dart';
import '../core/api.dart';
import '../core/crypto.dart';
import '../core/models.dart';
import 'devices.dart' show GrantEditor, expiryFrom, platformIcon, platformName;
import 'lock.dart';
import 'theme.dart';
import 'widgets.dart';

class AddDevicePage extends StatefulWidget {
  const AddDevicePage({super.key, required this.c});
  final AppController c;
  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  final _scanner = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _handling = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _found(Future<PairingRequest> Function() lookup, {required bool scanned}) async {
    if (_handling) return;
    _handling = true;
    PairingRequest? p;
    await runBusy(context, () async => p = await widget.c.guard(lookup));
    if (p != null && mounted) {
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ReviewPairingPage(c: widget.c, request: p!, scanned: scanned),
        ),
      );
    }
    _handling = false;
  }

  Future<void> _manual() async {
    final ctl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('输入核对码'),
        content: TextField(
          controller: ctl,
          autofillHints: null,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 18),
          decoration: const InputDecoration(hintText: 'XXXX-XXXX-XXXX-XXXX'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('查找')),
        ],
      ),
    );
    if (code == null || !mounted) return;
    await _found(() => widget.c.vault.pairingFromCode(code), scanned: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('添加设备')),
    body: ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        const Text('扫描电脑终端或另一台手机上显示的二维码。'),
        const SizedBox(height: Space.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: 1,
            child: MobileScanner(
              controller: _scanner,
              errorBuilder: (context, error) => Container(
                color: context.palette.card,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(Space.xl),
                child: const Text('无法打开相机。请在系统设置中允许 Harmonia 使用相机，或改用核对码。', textAlign: TextAlign.center),
              ),
              onDetect: (capture) {
                final raw = capture.barcodes.firstOrNull?.rawValue;
                if (raw != null) _found(() => widget.c.vault.pairingFromQr(raw), scanned: true);
              },
            ),
          ),
        ),
        const SizedBox(height: Space.lg),
        OutlinedButton.icon(
          onPressed: _manual,
          icon: const Icon(Icons.keyboard_outlined),
          label: const Text('无法扫码？输入核对码'),
        ),
      ],
    ),
  );
}

class ReviewPairingPage extends StatefulWidget {
  const ReviewPairingPage({super.key, required this.c, required this.request, required this.scanned});
  final AppController c;
  final PairingRequest request;
  final bool scanned;
  @override
  State<ReviewPairingPage> createState() => _ReviewPairingPageState();
}

class _ReviewPairingPageState extends State<ReviewPairingPage> {
  late bool _manager = widget.request.canManage;
  late bool _matched = widget.scanned;
  final _roles = <String, String?>{};
  final _expiry = <String, String>{};

  /// 请求曾出现在待批准列表中；之后从列表消失，说明对方已离开或请求已被处理。
  late bool _listed = _inList;
  bool _gone = false;

  PairingRequest get p => widget.request;
  bool get _inList => widget.c.pairings.any((x) => x.id == p.id);

  @override
  void initState() {
    super.initState();
    widget.c.addListener(_onChange);
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

  /// 执行批准或拒绝；服务端说请求已失效时切换到失效状态。
  Future<bool> _submit(Future<void> Function() fn, String done) => runBusy(context, () async {
    try {
      await widget.c.guard(fn);
    } on ApiException catch (e) {
      if (e.code == 'conflict' || e.code == 'not_found') setState(() => _gone = true);
      rethrow;
    }
  }, done: done);

  Future<void> _approve() async {
    final grants = [
      for (final e in widget.c.vault.environments)
        if (_roles[e.id] != null) Grant(e.id, _roles[e.id]!, expiryFrom(_expiry[e.id] ?? '长期有效')),
    ];
    if (!_manager && grants.isEmpty) {
      final ok = await confirmDialog(context, title: '不授权任何环境？', body: '这台设备接入后暂时无法访问任何变量，之后可以在设备详情中调整。', ok: '仍然批准');
      if (!ok) return;
    }
    if (!mounted || !await confirmIdentity(context, '验证身份以批准“${p.name}”')) return;
    if (!mounted) return;
    final nav = Navigator.of(context);
    final ok = await _submit(
      () => widget.c.vault.approvePairing(p, asManager: _manager, grants: grants),
      '已批准“${p.name}”',
    );
    if (ok) nav.pop();
  }

  Future<void> _reject() async {
    var block = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('拒绝“${p.name}”？'),
          content: CheckboxListTile(
            value: block,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (v) => set(() => block = v ?? false),
            title: const Text('30 分钟内阻止这个网络再次发起请求'),
            subtitle: Text('不是你本人发起时勾选。来自 ${p.ip}'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('拒绝')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final nav = Navigator.of(context);
    if (await _submit(() => widget.c.vault.rejectPairing(p.id, block: block), block ? '已拒绝并阻止这个网络' : '已拒绝')) {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('批准设备')),
      body: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Card(
            child: ListTile(
              leading: Icon(platformIcon(p.platform), size: 32),
              title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(p.ip.isEmpty ? platformName(p.platform) : '${platformName(p.platform)} · 来自 ${p.ip}'),
            ),
          ),
          if (_gone) ...[
            const SizedBox(height: Space.lg),
            const Banner2('这次请求已失效：对方已取消或离开了等待页面，也可能已在另一台管理设备上处理。需要接入时，请在那台设备上重新发起。', warn: true),
            const SizedBox(height: Space.xl),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          ] else
            ..._review(),
        ],
      ),
    );
  }

  List<Widget> _review() {
    final code = pairingCode(pairingFingerprint(p.id, p.signPub, p.boxPub, p.rootPub));
    final envs = widget.c.vault.environments;
    return [
      const SizedBox(height: Space.lg),
      Text(widget.scanned ? '核对码' : '请确认设备上显示的核对码与下面完全一致：'),
      const SizedBox(height: Space.sm),
      CodeBox(code, copyable: false),
      if (!widget.scanned) ...[
        const SizedBox(height: Space.md),
        Card(
          child: CheckboxListTile(
            value: _matched,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (v) => setState(() => _matched = v ?? false),
            title: const Text('核对码一致，这是我自己的设备'),
          ),
        ),
        const SizedBox(height: Space.sm),
        const Banner2('如果你此刻没有在电脑或其他手机上登录 Harmonia，请点“拒绝”，并尽快修改账号密码。', warn: true),
      ],
      // 只有具备管理功能的客户端（目前只有 App）才能作为管理设备。
      if (p.canManage) ...[
        const SizedBox(height: Space.md),
        Card(
          child: SwitchListTile(
            value: _manager,
            onChanged: (v) => setState(() => _manager = v),
            title: const Text('作为管理设备'),
            subtitle: const Text('管理设备可以访问全部环境，并能批准其他设备。只给你自己的设备开启。'),
          ),
        ),
      ],
      if (!_manager) ...[
        const SectionTitle('允许访问的环境'),
        if (envs.isEmpty)
          const Banner2('还没有任何环境，批准后可以随时在设备详情中授权。')
        else
          GrantEditor(envs: envs, roles: _roles, expiry: _expiry, onChanged: () => setState(() {})),
      ],
      const SizedBox(height: Space.xl),
      FilledButton(onPressed: _matched ? _approve : null, child: const Text('批准')),
      const SizedBox(height: Space.sm),
      OutlinedButton(onPressed: _reject, child: const Text('拒绝')),
    ];
  }
}
