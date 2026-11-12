import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'window_layout.dart';
import 'theme.dart';

/// 外壳保持窗口尺寸，菜单和工具条共用完整窗口的坐标系。
class AppNavigationShell extends StatelessWidget {
  const AppNavigationShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = glassSettings(context);
    final variant = GlassThemeVariant(
      settings: GlassThemeSettings(
        glassColor: settings.glassColor,
        blur: settings.blur,
        thickness: settings.thickness,
        frost: settings.frost,
        bodyShade: settings.bodyShade,
      ),
      quality: glassQuality(context),
    );
    return DefaultTextStyle(
      style: Theme.of(context).textTheme.labelLarge!.copyWith(color: context.palette.ink, fontSize: 17),
      child: GlassTheme(
        data: GlassThemeData(light: variant, dark: variant),
        // 这里必须保留系统 View 的祖先关系；LookupBoundary 会使玻璃控件的 View.of 失败。
        child: Overlay.wrap(
          child: GlassNavigationShell(
            swipeCommitTransition: GlassSwipeCommitTransition.crossFade,
            child: Builder(
              builder: (context) {
                final layout = WindowLayoutScope.maybeOf(context)!;
                // Android 没有 UIKit 的竖向栏通道，使用库公开的竖向栏布局数据。
                return GlassVerticalBar.maybeOf(context) != null || !layout.verticalNavigation
                    ? child
                    : GlassVerticalBar(data: verticalBarData(layout), child: child);
              },
            ),
          ),
        ),
      ),
    );
  }
}
