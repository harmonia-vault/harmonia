// 玻璃浮层共用的出现和收起动效；由现有路由或通知动画驱动，不在内容刷新时重新播放。
import 'package:flutter/material.dart';

import 'glass.dart';

const _enterDuration = Duration(milliseconds: 380);
const _exitDuration = Duration(milliseconds: 200);

class GlassPopupTransition extends StatelessWidget {
  const GlassPopupTransition({
    super.key,
    required this.animation,
    required this.child,
    this.beginScale = 0.88,
    this.verticalOffset = 12,
    this.alignment = Alignment.center,
  });
  final Animation<double> animation;
  final Widget child;
  final double beginScale, verticalOffset;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (!usesGlass(context) || MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (_, child) {
        final t = animation.value.clamp(0.0, 1.0);
        final closing = animation.status == AnimationStatus.reverse;
        final eased = closing ? Curves.easeOutCubic.transform(t) : Curves.easeOutBack.transform(t);
        final opacity = closing ? t : const Interval(0, 0.55, curve: Curves.easeOut).transform(t);
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, verticalOffset * (1 - eased)),
            child: Transform.scale(scale: beginScale + (1 - beginScale) * eased, alignment: alignment, child: child),
          ),
        );
      },
    );
  }
}

/// 保留 DialogRoute 的焦点循环、安全区、遮罩与返回行为，只调整玻璃模式的转场。
class AppDialogRoute<T> extends DialogRoute<T> {
  AppDialogRoute({required super.context, required super.builder, super.themes, super.barrierDismissible = true})
    : _glass = usesGlass(context),
      _reduceMotion = MediaQuery.disableAnimationsOf(context),
      super(
        barrierColor: usesGlass(context)
            ? Colors.black.withValues(alpha: 0.24)
            : DialogTheme.of(context).barrierColor ?? Colors.black54,
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      );

  final bool _glass, _reduceMotion;

  @override
  Duration get transitionDuration =>
      _reduceMotion ? Duration.zero : (_glass ? _enterDuration : super.transitionDuration);

  @override
  Duration get reverseTransitionDuration =>
      _reduceMotion ? Duration.zero : (_glass ? _exitDuration : super.reverseTransitionDuration);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_reduceMotion) return child;
    if (!_glass) return super.buildTransitions(context, animation, secondaryAnimation, child);
    return GlassPopupTransition(animation: animation, child: child);
  }
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(
    AppDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

AnimationStyle? glassSheetAnimationStyle(BuildContext context) {
  if (MediaQuery.disableAnimationsOf(context)) return AnimationStyle.noAnimation;
  if (!usesGlass(context)) return null;
  return const AnimationStyle(
    duration: Duration(milliseconds: 420),
    reverseDuration: Duration(milliseconds: 240),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic,
  );
}

AnimationStyle notificationAnimationStyle(BuildContext context) => MediaQuery.disableAnimationsOf(context)
    ? AnimationStyle.noAnimation
    : AnimationStyle(
        duration: usesGlass(context) ? _enterDuration : const Duration(milliseconds: 250),
        reverseDuration: usesGlass(context) ? _exitDuration : const Duration(milliseconds: 250),
      );

/// ScaffoldMessenger 注入同一条动画，出现、自动消失和主动关闭都与玻璃表面同步。
class GlassSnackBar extends SnackBar {
  GlassSnackBar({super.key, required Widget content, super.animation})
    : _body = content,
      super(
        content: animation == null
            ? content
            : GlassPopupTransition(
                animation: animation,
                beginScale: 0.94,
                verticalOffset: 8,
                alignment: Alignment.bottomCenter,
                child: content,
              ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.none,
      );
  final Widget _body;

  @override
  SnackBar withAnimation(Animation<double> newAnimation, {Key? fallbackKey}) =>
      GlassSnackBar(key: key ?? fallbackKey, content: _body, animation: newAnimation);
}
