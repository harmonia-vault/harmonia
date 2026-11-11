import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'adaptive_tools.dart';
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
  const AdaptivePageFrame({super.key, this.appBar, required this.body, this.overlay, this.avoidKeyboard});
  final AppBarSurface? appBar;
  final WidgetBuilder body;
  final WidgetBuilder? overlay;
  final bool? avoidKeyboard;

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
    final appBar = widget.appBar, overlay = widget.overlay;
    final layout = WindowLayoutScope.maybeOf(context);
    final pane = WorkspacePane.maybeOf(context);
    final presentation = PresentationScope.contains(context);
    final side = !presentation && layout?.verticalNavigation == true && pane?.master != true;
    final tabletop = !presentation && pane?.tabletop == true && pane?.master == false;
    final nav = Navigator.of(context);
    final leading =
        appBar?.leading ??
        (nav.canPop()
            ? IconButton(tooltip: '返回', icon: const Icon(CupertinoIcons.chevron_back), onPressed: nav.maybePop)
            : null);
    final toolbar = WorkspaceToolReporter(
      title: appBar?.title,
      leading: leading,
      actions: appBar?.actions,
      child: GlassBackdropGroup(
        child: Scaffold(
          backgroundColor: presentation ? Colors.transparent : null,
          resizeToAvoidBottomInset: widget.avoidKeyboard ?? true,
          extendBodyBehindAppBar: !side && appBar != null,
          appBar: side
              ? null
              : tabletop
              ? AppBarSurface(title: appBar?.title, leading: const SizedBox.shrink())
              : appBar,
          body: side
              ? _side(context, layout!, leading)
              : Builder(
                  builder: (context) {
                    final media = MediaQuery.of(context);
                    final bottom = presentation ? 0.0 : pane?.navigationHeight ?? 0;
                    return Padding(
                      padding: EdgeInsets.only(left: media.padding.left, right: media.padding.right),
                      child: MediaQuery(
                        data: media.copyWith(
                          padding: media.padding.copyWith(left: 0, right: 0, bottom: media.padding.bottom + bottom),
                        ),
                        child: Builder(
                          builder: (context) {
                            final content = _content();
                            if (appBar == null) return content;
                            final fadeHeight = MediaQuery.paddingOf(context).top + 24;
                            final faded = GlassScrollEdgeEffect(
                              fadeBottom: false,
                              topFadeHeight: fadeHeight,
                              fadeColor: context.palette.paper,
                              child: GlassScrollEdgeEffect(
                                fadeBottom: false,
                                topFadeHeight: fadeHeight,
                                style: GlassScrollEdgeStyle.blur,
                                child: content,
                              ),
                            );
                            return overlay == null ? faded : Stack(children: [faded, overlay(context)]);
                          },
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
    return toolbar;
  }

  Widget _side(BuildContext context, WindowLayout layout, Widget? leading) {
    final appBar = widget.appBar;
    final media = MediaQuery.of(context);
    final workspace = WorkspaceScope.maybeOf(context);
    final left = layout.navigation == NavigationEdge.left;
    final tools = [?leading, ...?appBar?.actions];
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            left && workspace == null ? math.max(media.padding.left, 84) : media.padding.left,
            media.padding.top,
            !left && workspace == null ? math.max(media.padding.right, 84) : media.padding.right,
            media.padding.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (appBar?.title case final title?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w600),
                    child: title,
                  ),
                ),
              Expanded(
                child: MediaQuery(
                  data: media.copyWith(padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
                  child: _content(),
                ),
              ),
            ],
          ),
        ),
        if (workspace == null)
          Positioned.fill(
            child: AdaptiveTools(layout: layout, tools: tools),
          ),
      ],
    );
  }
}
