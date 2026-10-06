// 已接入后的主界面：环境 / 设备 / 设置。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/updater.dart';
import 'devices.dart';
import 'environments.dart';
import 'settings.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.c});
  final AppController c;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => checkForUpdate(context, manual: false));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final pages = [EnvironmentsTab(c: c), DevicesTab(c: c), SettingsTab(c: c)];
    return Scaffold(
      body: Column(children: [
        if (!c.online)
          Material(
            color: context.palette.warnBox,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                child: Row(children: [
                  Icon(Icons.cloud_off_outlined, size: 18, color: context.palette.onWarnBox),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text('离线：显示的是上次同步的数据，修改需要联网。',
                        style: TextStyle(color: context.palette.onWarnBox, fontSize: 13)),
                  ),
                ]),
              ),
            ),
          ),
        Expanded(child: IndexedStack(index: _tab, children: pages)),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: '环境'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: c.pendingPairingCount > 0,
              label: Text('${c.pendingPairingCount}'),
              child: const Icon(Icons.devices_outlined),
            ),
            selectedIcon: const Icon(Icons.devices),
            label: '设备',
          ),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
