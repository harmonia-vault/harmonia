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
  return _AppDialogRoute<T>(
    reduceMotion: reduceMotion,
    pageBuilder: (context, _, _) => AdaptiveDialogPresentation(
      workspace: workspace,
      child: themes?.wrap(Builder(builder: builder)) ?? Builder(builder: builder),
    ),
    barrierColor: glassBarrierColor(context),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: barrierDismissible,
  );
}

class _AppDialogRoute<T> extends RawDialogRoute<T> {
  _AppDialogRoute({
    required super.pageBuilder,
    required this.reduceMotion,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
  }) : _pageBuilder = pageBuilder,
       super(
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         transitionDuration: reduceMotion ? Duration.zero : GlassDefaults.materializeDuration,
         // 与系统提醒框相同（Flutter 的 CupertinoDialogRoute 照此实现）：出现时从 1.3 倍收拢并淡入，
         // 关闭时原地淡出、不缩放。淡入淡出交给组件库在着色器里做，玻璃不会在动画首尾突然出现。
         transitionBuilder: (context, animation, _, child) => reduceMotion
             ? child
             : GlassMaterializeTransition(
                 animation: animation,
                 scaleFrom: animation.status == AnimationStatus.reverse ? 1 : 1.3,
                 child: child,
               ),
       );

  final RoutePageBuilder _pageBuilder;
  final bool reduceMotion;

  // 分区由 AdaptiveDialogPresentation 随窗口变化选择，避免 RawDialogRoute 再套一层分区。
  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        child: _pageBuilder(context, animation, secondaryAnimation),
      );

  @override
  Duration get reverseTransitionDuration => reduceMotion ? Duration.zero : GlassDefaults.dematerializeDuration;
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
