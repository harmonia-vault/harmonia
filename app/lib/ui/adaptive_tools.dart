import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass.dart';
import 'theme.dart';
import 'window_layout.dart';

/// 页面操作与标签导航共用窗口边缘，分栏时也只保留一条工具区。
class AdaptiveTools extends StatelessWidget {
  const AdaptiveTools({super.key, required this.layout, required this.tools, this.withNavigation = false});
  final WindowLayout layout;
  final List<Widget> tools;
  final bool withNavigation;

  @override
  Widget build(BuildContext context) {
    final bar = verticalBarData(layout)!;
    final left = layout.navigation == NavigationEdge.left;
    final navExtent = withNavigation ? (bar.collapsesTabBar ? 60.0 : 224.0) : 0.0;
    return Stack(
      children: [
        if (tools.isNotEmpty)
          Positioned(
            left: left ? 12 : null,
            right: left ? null : 24,
            top: bar.top,
            width: 48,
            height: math.max(0, layout.height - bar.top - bar.bottom - navExtent - 12),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final tool in tools)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: AppSurface(
                        color: context.palette.card,
                        radius: 24,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Material(
                            type: MaterialType.transparency,
                            child: IconButtonTheme(
                              data: IconButtonThemeData(
                                style: IconButton.styleFrom(foregroundColor: context.palette.ink),
                              ),
                              child: tool,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
