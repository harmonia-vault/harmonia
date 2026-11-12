import 'package:flutter/material.dart';

import 'window_layout.dart';

/// 栏外的导航菜单与固定工具栏共用窗口浮层，菜单不再落到工具栏下面。
/// 这里只搬运控件和锚点；菜单的开合、命中和焦点仍由组件库处理。
class WindowChrome extends StatefulWidget {
  const WindowChrome({super.key, required this.size, required this.child});
  final Size size;
  final Widget child;

  @override
  State<WindowChrome> createState() => _WindowChromeState();
}

class _WindowChromeState extends State<WindowChrome> {
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  @override
  Widget build(BuildContext context) {
    final current = ModalRoute.isCurrentOf(context) ?? true;
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context, info) {
        if (!current) return const SizedBox.shrink();
        final rect = MatrixUtils.transformRect(info.childPaintTransform, Offset.zero & info.childSize);
        return WindowMenuViewport(
          child: Overlay.wrap(
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: Listener(onPointerDown: (_) => _portal.show(), child: widget.child),
                ),
              ],
            ),
          ),
        );
      },
      child: SizedBox.fromSize(size: widget.size),
    );
  }
}
