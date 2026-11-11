// 路由交给 Flutter，玻璃转场复用组件库，避免 Opacity 隔断背景采样。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'adaptive_presentation.dart';
import 'window_layout.dart';
import 'workspace_scope.dart';

RawDialogRoute<T> appDialogRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  CapturedThemes? themes,
  WorkspaceScope? workspace,
  bool barrierDismissible = true,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  if (!reduceMotion) {
    return _AppGlassDialogRoute<T>(
      barrierColor: glassBarrierColor(context),
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      pageBuilder: (context, _, _) => AdaptivePresentation(
        workspace: workspace,
        child: themes?.wrap(Builder(builder: builder)) ?? Builder(builder: builder),
      ),
    );
  }
  return RawDialogRoute<T>(
    pageBuilder: (context, _, _) => AdaptivePresentation(
      workspace: workspace,
      child: themes?.wrap(Builder(builder: builder)) ?? Builder(builder: builder),
    ),
    barrierColor: glassBarrierColor(context),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: barrierDismissible,
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    transitionDuration: Duration.zero,
    transitionBuilder: (context, animation, secondary, child) => child,
  );
}

class _AppGlassDialogRoute<T> extends RawDialogRoute<T> {
  _AppGlassDialogRoute({required super.pageBuilder, super.barrierColor, super.barrierDismissible, super.barrierLabel})
    : super(
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
        transitionDuration: GlassDefaults.materializeDuration,
        // 与系统提醒框相同（Flutter 的 CupertinoDialogRoute 照此实现）：出现时从 1.3 倍收拢并淡入，
        // 关闭时原地淡出、不缩放。淡入淡出交给组件库在着色器里做，玻璃不会在动画首尾突然出现。
        transitionBuilder: (context, animation, _, child) => GlassMaterializeTransition(
          animation: animation,
          scaleFrom: animation.status == AnimationStatus.reverse ? 1 : 1.3,
          child: child,
        ),
      );

  @override
  Duration get reverseTransitionDuration => GlassDefaults.dematerializeDuration;
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  // 使用本次会话自己的根导航器；页面调试不会把弹窗放进真实账号的导航器。
  final navigator = WindowLayoutScope.navigatorOf(context);
  return navigator.push<T>(
    appDialogRoute<T>(
      context: context,
      builder: builder,
      workspace: WorkspaceScope.maybeOf(context),
      barrierDismissible: barrierDismissible,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}
