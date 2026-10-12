// 复用 Flutter 标准对话框路由与动效，只适配主题、安全区和焦点循环。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'glass.dart';

RawDialogRoute<T> appDialogRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  CapturedThemes? themes,
  bool barrierDismissible = true,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  if (usesGlass(context) && !reduceMotion) {
    return _AppCupertinoDialogRoute<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (context) => SafeArea(
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

class _AppCupertinoDialogRoute<T> extends CupertinoDialogRoute<T> {
  _AppCupertinoDialogRoute({required super.context, required super.builder, super.barrierDismissible});

  @override
  TraversalEdgeBehavior get traversalEdgeBehavior => TraversalEdgeBehavior.closedLoop;
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
