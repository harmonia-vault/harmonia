// 设备详情里电脑的“版本与更新”：当前版本、可更新到的版本、让电脑现在更新、自动更新开关（docs/rewrite-plan.md 5.11）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/updater.dart';
import '../core/debug_vault.dart' show debugCliLatest;
import '../core/models.dart';
import 'app_scope.dart';
import 'glass.dart';
import 'theme.dart';
import 'widgets.dart';

/// 从这个版本起，命令行支持在手机上更新和自动更新。
const cliRemoteUpdateSince = '0.10.0';

/// 点“更新”后等待电脑上报新版本的时间，超过后提示去电脑上查看。
const _waitLimit = Duration(minutes: 2);

class CliUpdateSection extends StatefulWidget {
  const CliUpdateSection({super.key, required this.c, required this.deviceId});
  final AppController c;
  final String deviceId;

  @override
  State<CliUpdateSection> createState() => _CliUpdateSectionState();
}

class _CliUpdateSectionState extends State<CliUpdateSection> {
  Future<String>? _latest;
  UpdateChannel? _latestChannel;

  /// 点“更新”时电脑的版本；电脑上报的版本变了即视为完成。
  String? _waitingFrom;
  bool _waitTooLong = false;
  Timer? _waitTimer;

  AppController get c => widget.c;

  DeviceInfo? get _device => c.vault.devices.where((d) => d.id == widget.deviceId).firstOrNull;

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  Future<String> _latestFor(DeviceInfo d) {
    final channel = cliChannelFor(d.version);
    if (_latest == null || _latestChannel != channel) {
      _latestChannel = channel;
      _latest = AppScope.isSimulated(context)
          ? Future.delayed(const Duration(milliseconds: 400), () => debugCliLatest(d.version))
          : fetchLatestCliVersion(updaterCrypto, channel);
    }
    return _latest!;
  }

  void _retryLatest() => setState(() => _latest = null);

  /// [newer] 表示已知有新版本：这时等电脑上报新版本号；否则只是让电脑按自己的渠道检查一次。
  Future<void> _requestUpdate(DeviceInfo d, {required bool newer}) async {
    final ok = await runBusy(
      context,
      () => c.guard(() => c.vault.requestCliUpdate(d.id)),
      done: newer ? null : '已通知电脑检查更新，有新版本时它会自动换上',
    );
    if (!ok || !mounted || !newer) return;
    _waitTimer?.cancel();
    _waitTimer = Timer(_waitLimit, () {
      if (mounted && _waitingFrom != null) setState(() => _waitTooLong = true);
    });
    setState(() {
      _waitingFrom = d.version;
      _waitTooLong = false;
    });
  }

  Future<void> _setAuto(DeviceInfo d, bool on) async {
    await runBusy(context, () => c.guard(() => c.vault.setAutoUpdate(d.id, on)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final d = _device;
      if (d == null) return const SizedBox.shrink();
      if (_waitingFrom != null && d.version != _waitingFrom) {
        // 电脑已经上报了新版本。
        _waitingFrom = null;
        _waitTimer?.cancel();
      }
      final supported = d.version.isNotEmpty && compareVersions(d.version, cliRemoteUpdateSince) >= 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('版本与更新'),
          if (!supported)
            Banner2(
              tidy(
                d.version.isEmpty
                    ? '不知道这台电脑的命令行版本，它可能还不支持在手机上更新。请在电脑上运行 harmonia update 升级一次，之后就可以在这里更新。'
                    : '这台电脑的命令行（${d.version}）还不支持在手机上更新。请在电脑上运行 harmonia update 升级一次，之后就可以在这里更新。',
              ),
            )
          else ...[
            Card(
              child: Column(
                children: [
                  _status(context, d),
                  const Divider(),
                  AppSwitchTile(
                    title: const Text('自动更新'),
                    subtitle: Text(tidy('后台服务每天检查一次，发现新版本直接升级。需要电脑上安装了后台服务。')),
                    value: d.autoUpdate,
                    onChanged: (on) => _setAuto(d, on),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.md),
            _action(context, d),
          ],
        ],
      );
    },
  );

  Widget _status(BuildContext context, DeviceInfo d) => FutureBuilder<String>(
    future: _latestFor(d),
    builder: (context, snap) {
      final channel = cliChannelFor(d.version);
      final String title;
      final String subtitle;
      Widget? trailing;
      if (_waitingFrom != null) {
        title = _waitTooLong ? '电脑还没有完成更新' : '已通知电脑更新';
        subtitle = _waitTooLong ? '可以稍后回来查看，或在电脑上运行 harmonia update 看看原因。' : '电脑下载并换上新版本后，这里会显示新的版本号，通常不到一分钟。';
        if (!_waitTooLong)
          trailing = const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
      } else if (snap.connectionState != ConnectionState.done) {
        title = '当前 ${d.version}';
        subtitle = '正在检查${channel.label}的最新版本…';
      } else if (snap.hasError) {
        title = '当前 ${d.version}';
        subtitle = '暂时无法获取最新版本，点右侧重试。仍然可以让电脑自己检查更新。';
        trailing = IconButton(tooltip: '重试', icon: const Icon(Icons.refresh), onPressed: _retryLatest);
      } else if (isNewer(snap.data!, d.version)) {
        title = '可以更新到 ${snap.data}';
        subtitle = '当前 ${d.version}（${channel.label}）';
      } else {
        title = '已是最新版本';
        subtitle = '${d.version}（${channel.label}）';
      }
      return ListTile(title: Text(title), subtitle: Text(tidy(subtitle)), trailing: trailing);
    },
  );

  Widget _action(BuildContext context, DeviceInfo d) {
    if (_waitingFrom != null && !_waitTooLong) {
      return const OutlinedButton(onPressed: null, child: Text('正在等待电脑更新'));
    }
    return FutureBuilder<String>(
      future: _latestFor(d),
      builder: (context, snap) {
        final newer = snap.hasData && isNewer(snap.data!, d.version);
        void onPressed() => _requestUpdate(d, newer: newer);
        return newer
            ? FilledButton(onPressed: onPressed, child: const Text('更新这台电脑'))
            : OutlinedButton(onPressed: onPressed, child: const Text('让这台电脑检查更新'));
      },
    );
  }
}
