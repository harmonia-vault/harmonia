import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'adaptive_page.dart';
import 'glass.dart';
import 'window_layout.dart';
import 'workspace_scope.dart';

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
        content = WorkspaceScope(open: scope.open, selected: scope.selected, tools: scope.tools, child: content);
      }
      return Padding(
        padding: EdgeInsets.fromLTRB(
          region.left,
          region.top,
          math.max(0, constraints.maxWidth - region.left - region.width),
          math.max(0, constraints.maxHeight - region.top - region.height),
        ),
        child: MediaQuery(
          data: media.copyWith(
            size: Size(region.width, region.height),
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
            viewInsets: EdgeInsets.zero,
            displayFeatures: const [],
          ),
          child: content,
        ),
      );
    },
  );
}

Widget adaptiveEditor(BuildContext context, WidgetBuilder page) => Dialog(
  backgroundColor: Colors.transparent,
  insetPadding: const EdgeInsets.all(12),
  constraints: const BoxConstraints(maxWidth: 560),
  child: ClipRRect(
    borderRadius: BorderRadius.circular(36),
    child: AppSurface(
      color: Theme.of(context).colorScheme.surface,
      radius: 36,
      panel: true,
      child: SizedBox(
        height: math.max(0, math.min(680, MediaQuery.sizeOf(context).height - 24)),
        child: Builder(builder: page),
      ),
    ),
  ),
);
