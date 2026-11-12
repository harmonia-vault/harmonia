import 'package:flutter/material.dart';

import 'window_layout.dart';

/// 同一条详情路由在单栏使用原生转场，在双栏只淡入内容。
class WorkspaceDetailPage<T> extends MaterialPage<T> {
  const WorkspaceDetailPage({
    required super.key,
    required super.child,
    this.selection = false,
    super.canPop,
    super.onPopInvoked,
  });
  final bool selection;

  @override
  Route<T> createRoute(BuildContext context) => _WorkspaceDetailRoute<T>(this);
}

class _WorkspaceDetailRoute<T> extends PageRoute<T> with MaterialRouteTransitionMixin<T> {
  _WorkspaceDetailRoute(WorkspaceDetailPage<T> page) : super(settings: page);

  @override
  bool get maintainState => true;

  @override
  Widget buildContent(BuildContext context) => (settings as WorkspaceDetailPage).child;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (WindowLayoutScope.maybeOf(context)?.twoPanes != true) {
      return super.buildTransitions(context, animation, secondaryAnimation, child);
    }
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
      child: child,
    );
  }
}
