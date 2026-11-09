// 底部面板：普通外观是 Material 底部面板，液态玻璃外观是一块浮起的玻璃面板。发现新版本、环境授权等共用。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';

/// 打开底部面板。内容自己处理底部安全区：普通外观下要留出，玻璃外观下面板已经离开了屏幕边缘。
Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final contentKey = GlobalKey();
  final glass = usesGlass(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    // 内容多的时候面板会很高，留出状态栏的位置。
    useSafeArea: true,
    showDragHandle: !glass,
    backgroundColor: glass ? Colors.transparent : context.palette.paper,
    barrierColor: glass ? glassBarrierColor(context) : null,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context) ? AnimationStyle.noAnimation : null,
    builder: (c) {
      final content = builder(c);
      if (!usesGlass(c)) return content;
      return GlassMaterializeTransition(
        animation: ModalRoute.of(c)!.animation!,
        // 面板已由系统路由滑入，不再叠加缩放；材质与内容同步渐显。
        scaleFrom: 1,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.paddingOf(c).bottom + 12),
          child: AppSurface(
            color: c.palette.card,
            radius: 36,
            panel: true,
            child: RepaintBoundary(
              key: contentKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.palette.mute.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Flexible(child: content),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
