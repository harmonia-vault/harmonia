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
    WidgetsBinding.instance.addPostFrameCallback((_) => checkForUpdate(context, manual: false, channel: widget.c.updateChannel));
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
      bottomNavigationBar: _NavBar(
        selected: _tab,
        onSelect: (i) => setState(() => _tab = i),
        items: [
          const _NavItem(Icons.inventory_2_outlined, Icons.inventory_2, '环境'),
          _NavItem(Icons.devices_outlined, Icons.devices, '设备', badge: c.pendingPairingCount),
          const _NavItem(Icons.settings_outlined, Icons.settings, '设置'),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label, {this.badge = 0});
  final IconData icon, selectedIcon;
  final String label;
  final int badge;
}

// 底部导航：选中项的黄色底同时包住图标和文字。
class _NavBar extends StatelessWidget {
  const _NavBar({required this.selected, required this.onSelect, required this.items});
  final int selected;
  final ValueChanged<int> onSelect;
  final List<_NavItem> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.card,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
          child: Row(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(child: _tile(context, items[i], i == selected, () => onSelect(i))),
          ]),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, _NavItem item, bool on, VoidCallback onTap) {
    final p = context.palette;
    // 黄色底上深浅模式都用深色。
    final fg = on ? Palette.light.ink : p.mute;
    Widget icon = Icon(on ? item.selectedIcon : item.icon, color: fg);
    if (item.badge > 0) icon = Badge(label: Text('${item.badge}'), child: icon);
    return Semantics(
      selected: on,
      button: true,
      // heightFactor: 1：只占按钮自身的高度。底部栏的高度上限是整个屏幕，不加会撑满全屏、挤掉页面内容。
      child: Center(
        heightFactor: 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            width: 88,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: on ? p.yellow : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              icon,
              const SizedBox(height: 2),
              Text(item.label,
                  style: TextStyle(
                      fontSize: 12, color: fg, fontWeight: on ? FontWeight.w600 : FontWeight.w500)),
            ]),
          ),
        ),
      ),
    );
  }
}
