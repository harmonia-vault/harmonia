import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';
import 'window_layout.dart';

class AdaptiveNavigation extends StatelessWidget {
  const AdaptiveNavigation({super.key, required this.selected, required this.onSelected, this.badge = 0});
  final int selected, badge;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final layout = WindowLayoutScope.maybeOf(context)!;
    final p = context.palette;
    const icons = [
      CupertinoIcons.archivebox,
      CupertinoIcons.square_stack_3d_up,
      CupertinoIcons.device_laptop,
      CupertinoIcons.gear_alt,
    ];
    const labels = ['变量库', '环境', '设备', '设置'];
    final height = 60 + (MediaQuery.textScalerOf(context).scale(11) - 11).clamp(0, 40) * 1.5;
    final bar = GlassTabBar.bottom(
      tabs: [
        for (var i = 0; i < 4; i++)
          GlassTab(
            icon: Badge(isLabelVisible: i == 2 && badge > 0, label: Text('$badge'), child: Icon(icons[i])),
            label: labels[i],
          ),
      ],
      selectedIndex: selected,
      onTabSelected: onSelected,
      horizontalPadding: 24,
      verticalPadding: 4,
      barHeight: height,
      barBorderRadius: height / 2,
      indicatorBorderRadius: 999,
      settings: glassSettings(context),
      quality: glassQuality(context),
      selectedIconColor: p.accent,
      selectedLabelColor: p.accent,
      unselectedIconColor: p.ink,
      unselectedLabelColor: p.ink,
      indicatorColor: p.ink.withValues(alpha: .06),
      indicatorExpansion: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      iconLabelSpacing: 3,
      showIndicator: !MediaQuery.disableAnimationsOf(context),
      interactionBehavior: MediaQuery.disableAnimationsOf(context)
          ? GlassInteractionBehavior.none
          : GlassInteractionBehavior.full,
    );
    return GlassVerticalBar(
      data: verticalBarData(layout),
      child: layout.verticalNavigation
          ? bar
          : Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(top: false, minimum: const EdgeInsets.only(bottom: 8), child: bar),
            ),
    );
  }
}
