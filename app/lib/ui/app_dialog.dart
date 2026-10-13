// 路由交给 Flutter，玻璃转场复用组件库，避免 Opacity 隔断背景采样。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';

RawDialogRoute<T> appDialogRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  CapturedThemes? themes,
  bool barrierDismissible = true,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  if (usesGlass(context) && !reduceMotion) {
    return _AppGlassDialogRoute<T>(
      barrierColor: glassBarrierColor(context),
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      pageBuilder: (context, _, _) => SafeArea(
        child: themes?.wrap(Builder(builder: builder)) ?? Builder(builder: builder),
      ),
    );
  }
  return DialogRoute<T>(
    context: context,
    builder: builder,
    themes: themes,
    barrierDismissible: barrierDismissible,
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    animationStyle: reduceMotion ? AnimationStyle.noAnimation : null,
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
  bool useRootNavigator = true,
  bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(
    appDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}
