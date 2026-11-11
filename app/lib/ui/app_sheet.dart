// 环境授权、变量操作和更新等共用的自适应玻璃面板。
import 'package:flutter/material.dart';

import 'glass.dart';
import 'glass_overlays.dart';

Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final contentKey = GlobalKey();
  return showAppDialog<T>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxWidth: 560),
      child: AppSurface(
        color: Theme.of(context).colorScheme.surface,
        radius: 36,
        panel: true,
        child: RepaintBoundary(
          key: contentKey,
          child: Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Flexible(child: Builder(builder: builder))],
            ),
          ),
        ),
      ),
    ),
  );
}
