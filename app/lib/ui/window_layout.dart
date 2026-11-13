import 'dart:ui' show DisplayFeatureType, DisplayFeatureState;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app/window_geometry.dart';
import '../core/window_layout.dart';

export '../core/window_layout.dart';

Rect flutterRect(LayoutRect box) => Rect.fromLTWH(box.left, box.top, box.width, box.height);

/// 同一窗口内从当前帧调整区域；旋转交给系统，不在两套坐标系间插值。
class AnimatedLayoutRegion extends StatefulWidget {
  const AnimatedLayoutRegion({super.key, required this.viewport, required this.rect, required this.builder});
  final Size viewport;
  final Rect rect;
  final Widget Function(BuildContext, Rect) builder;

  @override
  State<AnimatedLayoutRegion> createState() => _AnimatedLayoutRegionState();
}

class _AnimatedLayoutRegionState extends State<AnimatedLayoutRegion> {
  Size? _viewport;

  @override
  Widget build(BuildContext context) {
    final animate = _viewport == widget.viewport && !MediaQuery.disableAnimationsOf(context);
    _viewport = widget.viewport;
    return AnimatedPositioned.fromRect(
      rect: widget.rect,
      duration: animate ? const Duration(milliseconds: 360) : Duration.zero,
      curve: Curves.easeInOutCubic,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) => widget.builder(
            context,
            Rect.fromLTWH(widget.rect.left, widget.rect.top, constraints.maxWidth, constraints.maxHeight),
          ),
        ),
      ),
    );
  }
}

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
      final current = _geometry.width == media.size.width && _geometry.height == media.size.height;
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
        fold:
            (current ? _geometry.fold : null) ??
            (fold == null ? null : layoutRect(fold.left, fold.top, fold.width, fold.height)),
        occlusions: current ? _geometry.occlusions : const [],
        navigation: current ? _geometry.navigation : null,
        regularWidth: current ? _geometry.regularWidth : null,
      );
      return WindowLayoutScope(layout: layout, navigator: widget.navigator, child: widget.child);
    },
  );
}

GlassVerticalBarData? verticalBarData(WindowLayout layout) {
  if (!layout.verticalNavigation) return null;
  final left = layout.navigation == NavigationEdge.left;
  return GlassVerticalBarData(
    edge: left ? GlassVerticalBarEdge.leading : GlassVerticalBarEdge.trailing,
    width: 84,
    top: layout.navigationTop,
    bottom: layout.navigationBottom,
    rowTop: layout.insets.top + 12,
    collapsesTabBar: layout.compactNavigation,
    systemInset: false,
  );
}

/// 菜单的屏幕边界与全局锚点使用同一坐标系，不使用详情栏的局部尺寸。
class WindowMenuViewport extends StatelessWidget {
  const WindowMenuViewport({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final layout = WindowLayoutScope.maybeOf(context)!;
    final insets = EdgeInsets.fromLTRB(
      layout.insets.left,
      layout.insets.top,
      layout.insets.right,
      layout.insets.bottom,
    );
    return MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(size: Size(layout.width, layout.height), padding: insets, viewPadding: insets),
      child: child,
    );
  }
}
