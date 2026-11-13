import 'dart:ui' show DisplayFeature, DisplayFeatureType, DisplayFeatureState;

import 'package:flutter/material.dart';

import 'adaptive_page.dart';
import 'window_layout.dart';
import 'workspace_scope.dart';

/// 对话框只选择所在屏区；居中与键盘避让由 Dialog 自己处理，不扣除页面工具栏。
class AdaptiveDialogPresentation extends StatelessWidget {
  const AdaptiveDialogPresentation({super.key, required this.child, this.workspace});
  final Widget child;
  final WorkspaceScope? workspace;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final layout = WindowLayoutScope.maybeOf(context);
    final region = layout?.presentation;
    final fold = layout?.fold;
    final features = [
      for (final feature in media.displayFeatures)
        if (feature.type != DisplayFeatureType.fold && feature.type != DisplayFeatureType.hinge) feature,
      if (fold != null)
        DisplayFeature(
          bounds: flutterRect(fold),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureHalfOpened,
        ),
    ];
    Widget content = PresentationScope(
      child: WorkspacePane(master: false, active: false, navigationHeight: 0, child: child),
    );
    if (workspace case final scope?) {
      content = WorkspaceScope(
        open: scope.open,
        select: scope.select,
        selected: scope.selected,
        openEditor: scope.openEditor,
        child: content,
      );
    }
    return MediaQuery(
      // 系统键盘切换曾瞬间上报负高度；在进入 Dialog 的 AnimatedPadding 前归一化。
      data: media.copyWith(
        displayFeatures: features,
        viewInsets: media.viewInsets.copyWith(bottom: media.viewInsets.bottom.clamp(0.0, media.size.height)),
      ),
      child: DisplayFeatureSubScreen(anchorPoint: region == null ? null : flutterRect(region).center, child: content),
    );
  }
}

/// 路由和表单身份不变，只调整面板所在的可用区域。
class AdaptivePresentation extends StatelessWidget {
  const AdaptivePresentation({super.key, required this.child, this.workspace});
  final Widget child;
  final WorkspaceScope? workspace;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final layout =
          WindowLayoutScope.maybeOf(context) ??
          WindowLayout(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            keyboard: media.viewInsets.bottom,
            insets: (
              left: media.viewPadding.left,
              top: media.viewPadding.top,
              right: media.viewPadding.right,
              bottom: media.viewPadding.bottom,
            ),
          );
      final region = layout.presentation;
      Widget content = PresentationScope(
        child: WorkspacePane(master: false, active: false, navigationHeight: 0, child: child),
      );
      if (workspace case final scope?) {
        content = WorkspaceScope(
          open: scope.open,
          select: scope.select,
          selected: scope.selected,
          openEditor: scope.openEditor,
          child: content,
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          AnimatedLayoutRegion(
            viewport: Size(constraints.maxWidth, constraints.maxHeight - media.viewInsets.bottom),
            rect: flutterRect(region),
            builder: (context, frame) => MediaQuery(
              data: media.copyWith(
                size: frame.size,
                padding: EdgeInsets.zero,
                viewPadding: EdgeInsets.zero,
                viewInsets: EdgeInsets.zero,
                displayFeatures: const [],
              ),
              child: content,
            ),
          ),
        ],
      );
    },
  );
}

/// 编辑页进入当前页面栈，开合只改变栏宽，保持表单及调试会话。
Future<T?> openEditorPage<T>(BuildContext context, WidgetBuilder page) {
  final workspace = WorkspaceScope.maybeOf(context);
  return workspace?.openEditor<T>(page) ??
      WindowLayoutScope.navigatorOf(context).push<T>(MaterialPageRoute(builder: page));
}
