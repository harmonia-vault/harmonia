import 'package:flutter/material.dart';

import 'device_shell.dart';
import 'devices.dart';
import 'page_debug_catalog.dart';

List<DebugPageEntry> shellDebugPages() => [
  for (final (name, enabled, pending, error) in [
    ('已关闭', false, false, null),
    ('已开启', true, false, null),
    ('等待设备同步', true, true, null),
    ('配置失败', true, false, '请在电脑上运行 harmonia shell install 完成配置，再运行 harmonia sync。'),
  ])
    DebugPageEntry('Shell 集成：$name', (s) {
      final d = s.vault.devices.where((d) => d.id == 'debug-mac').firstOrNull;
      if (d == null) return const Center(child: Text('当前没有示例设备，请切换到正常数据。'));
      d.json['shellEnabled'] = enabled;
      d.json['shellState'] = pending ? null : {'enabled': enabled, 'error': error};
      if (pending) {
        s.vault.offlineDevices.add(d.id);
      } else {
        s.vault.offlineDevices.remove(d.id);
      }
      return DevicePage(c: s.c, deviceId: d.id);
    }),
  DebugPageEntry('Shell 集成：开启确认', (s) {
    final d = s.vault.devices.where((d) => d.id == 'debug-mac').firstOrNull;
    if (d == null) return const Center(child: Text('当前没有示例设备，请切换到正常数据。'));
    return DebugOverlay(
      background: DevicePage(c: s.c, deviceId: d.id),
      show: (context) => confirmShellEnabled(context, d),
    );
  }),
  DebugPageEntry('写入用户环境变量：Windows 开关与开启确认', (s) => DevicePage(c: s.c, deviceId: 'debug-computer')),
];
