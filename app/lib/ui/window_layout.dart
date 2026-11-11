import 'dart:ui' show DisplayFeatureType, DisplayFeatureState;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app/window_geometry.dart';
import '../core/window_layout.dart';

export '../core/window_layout.dart';

Rect flutterRect(LayoutRect box) => Rect.fromLTWH(box.left, box.top, box.width, box.height);

class WindowLayoutScope extends InheritedWidget {
  const WindowLayoutScope({super.key, required this.layout, required this.navigator, required super.child});
  final WindowLayout layout;
  final GlobalKey<NavigatorState> navigator;

  static WindowLayout? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowLayoutScope>()?.layout;
  static NavigatorState navigatorOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowLayoutScope>()?.navigator.currentState ?? Navigator.of(context);

  @override
  bool updateShouldNotify(WindowLayoutScope oldWidget) => layout != oldWidget.layout;
}

/// 正式入口跟随系统；页面调试直接提供自己的 WindowLayoutScope，不订阅真实窗口通道。
class AppWindowLayout extends StatefulWidget {
  const AppWindowLayout({super.key, required this.navigator, required this.child});
  final GlobalKey<NavigatorState> navigator;
  final Widget child;
  @override
  State<AppWindowLayout> createState() => _AppWindowLayoutState();
}

class _AppWindowLayoutState extends State<AppWindowLayout> {
  final _geometry = WindowGeometry();
  @override
  void initState() {
    super.initState();
    _geometry.start();
  }

  @override
  void dispose() {
    _geometry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _geometry,
    builder: (context, _) {
      final media = MediaQuery.of(context);
      final padding = media.viewPadding;
      final folds = media.displayFeatures.where(
        (f) =>
            (f.type == DisplayFeatureType.fold || f.type == DisplayFeatureType.hinge) &&
            (f.state == DisplayFeatureState.postureHalfOpened || f.bounds.width > 0 && f.bounds.height > 0),
      );
      final fold = folds.firstOrNull?.bounds;
      final layout = WindowLayout(
        width: media.size.width,
        height: media.size.height,
        insets: (left: padding.left, top: padding.top, right: padding.right, bottom: padding.bottom),
        keyboard: media.viewInsets.bottom,
        fold: _geometry.fold ?? (fold == null ? null : layoutRect(fold.left, fold.top, fold.width, fold.height)),
        occlusions: _geometry.occlusions,
        navigation: _geometry.navigation,
        regularWidth: _geometry.regularWidth,
      );
      return WindowLayoutScope(layout: layout, navigator: widget.navigator, child: widget.child);
    },
  );
}

GlassVerticalBarData? verticalBarData(WindowLayout layout) {
  if (!layout.verticalNavigation) return null;
  var top = layout.insets.top + 12;
  var bottom = layout.insets.bottom + 12;
  final left = layout.navigation == NavigationEdge.left;
  for (final area in layout.occlusions) {
    if (left ? area.left > 84 : area.left + area.width < layout.width - 84) continue;
    if (area.top < layout.height / 2) {
      top = (area.top + area.height + 12).clamp(top, layout.height);
    } else {
      bottom = (layout.height - area.top + 12).clamp(bottom, layout.height);
    }
  }
  return GlassVerticalBarData(
    edge: left ? GlassVerticalBarEdge.leading : GlassVerticalBarEdge.trailing,
    width: 84,
    top: top,
    bottom: bottom,
    rowTop: layout.insets.top + 12,
    collapsesTabBar: layout.compactNavigation,
    systemInset: false,
  );
}
