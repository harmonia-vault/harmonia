import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';
import 'window_layout.dart';
import 'workspace_scope.dart';

class PresentationScope extends InheritedWidget {
  const PresentationScope({super.key, required super.child});
  static bool contains(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PresentationScope>() != null;
  @override
  bool updateShouldNotify(PresentationScope oldWidget) => false;
}

class AdaptivePageFrame extends StatefulWidget {
  const AdaptivePageFrame({
    super.key,
    this.appBar,
    required this.body,
    this.avoidKeyboard,
    this.controls,
    this.header,
    this.headerScrollController,
  });
  final AppBarSurface? appBar;
  final WidgetBuilder body;
  final bool? avoidKeyboard;
  final Widget? controls;
  final Widget? header;
  final ScrollController? headerScrollController;

  @override
  State<AdaptivePageFrame> createState() => _AdaptivePageFrameState();
}

class _AdaptivePageFrameState extends State<AdaptivePageFrame> {
  final _contentKey = GlobalKey();

  Widget _content() => KeyedSubtree(
    key: _contentKey,
    child: Builder(builder: widget.body),
  );

  @override
  Widget build(BuildContext context) {
    final pane = WorkspacePane.maybeOf(context);
    final presentation = PresentationScope.contains(context);
    Widget frame(BuildContext context) {
      final media = MediaQuery.of(context);
      final bar = widget.appBar?.bar(context);
      final barHeight = widget.appBar?.preferredSize.height ?? kToolbarHeight;
      final vertical = GlassVerticalBar.maybeOf(context);
      final layout = WindowLayoutScope.maybeOf(context);
      final navigation = presentation ? 0.0 : pane?.navigationHeight ?? 0;
      final top = bar == null
          ? media.padding.top
          : vertical == null
          ? media.padding.top + barHeight + Space.xl
          : vertical.rowTop + GlassVerticalBarMetrics.rowHeight + Space.xl;
      final scaffoldMedia = vertical == null ? media : media.copyWith(padding: media.padding.copyWith(top: 0));
      return MediaQuery(
        data: scaffoldMedia,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: GlassScaffold(
            appBar: bar,
            header: widget.header,
            headerScrollController: widget.headerScrollController,
            headerFadeDistance: 52,
            settings: glassSettings(context),
            enableBackgroundSampling: false,
            backgroundColor: presentation ? Colors.transparent : context.palette.paper,
            statusBarStyle: GlassStatusBarStyle.auto,
            resizeToAvoidBottomInset: widget.avoidKeyboard ?? true,
            appBarHeight: vertical == null ? barHeight : vertical.rowTop + GlassVerticalBarMetrics.rowHeight,
            topEdgeFadeExtent: Space.xl,
            // 与外层的纸色渐隐叠加，滚动内容在标题后方逐渐磨砂，不使用实色遮板。
            body: GlassScrollEdgeEffect(
              fadeTop: bar != null,
              fadeBottom: false,
              topFadeHeight: top,
              style: GlassScrollEdgeStyle.blur,
              child: Padding(
                padding: EdgeInsets.only(left: media.padding.left, right: media.padding.right),
                child: MediaQuery(
                  data: media.copyWith(
                    padding: EdgeInsets.only(
                      top: top,
                      bottom:
                          (widget.avoidKeyboard == false ? media.viewPadding.bottom : media.padding.bottom) +
                          navigation,
                    ),
                    viewPadding: media.viewPadding.copyWith(left: 0, right: 0),
                  ),
                  child: widget.controls != null && layout?.tabletop == true && WorkspaceScope.maybeOf(context) == null
                      ? _tabletop(context, layout!)
                      : _content(),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return pane?.master == true || presentation
        ? GlassVerticalBar.disabled(child: Builder(builder: frame))
        : Builder(builder: frame);
  }

  Widget _tabletop(BuildContext context, WindowLayout layout) {
    final media = MediaQuery.of(context);
    return Stack(
      children: [
        Positioned.fromRect(
          rect: Rect.fromLTWH(0, 0, layout.width, layout.fold!.top),
          child: MediaQuery(
            data: media.copyWith(
              size: Size(layout.width, layout.fold!.top),
              padding: media.padding.copyWith(bottom: 0),
              viewPadding: media.viewPadding.copyWith(bottom: 0),
            ),
            child: _content(),
          ),
        ),
        Positioned.fromRect(
          rect: flutterRect(layout.tabletopControls),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: widget.controls),
          ),
        ),
        Positioned.fromRect(
          rect: flutterRect(layout.fold!),
          child: ColoredBox(color: context.palette.line),
        ),
      ],
    );
  }
}
