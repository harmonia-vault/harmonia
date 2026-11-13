import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';
import 'window_chrome.dart';

/// 低高度窗口用库的锚定菜单切换标签，保留完整的开合转场。
class CompactTabs extends StatefulWidget {
  const CompactTabs({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.icons,
    required this.labels,
    required this.badge,
  });
  final int selected, badge;
  final ValueChanged<int> onSelected;
  final List<IconData> icons;
  final List<String> labels;

  @override
  State<CompactTabs> createState() => _CompactTabsState();
}

class _CompactTabsState extends State<CompactTabs> {
  GlassNavigationShellState? _shell;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = GlassNavigationShell.maybeOf(context);
    if (shell != _shell) _shell?.releaseVerticalBarBottom(this);
    _shell = shell;
    final bar = GlassVerticalBar.maybeOf(context)!;
    shell?.reserveVerticalBarBottom(this, bar.bottom + GlassVerticalBarMetrics.controlExtent);
  }

  @override
  void dispose() {
    _shell?.releaseVerticalBarBottom(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bar = GlassVerticalBar.maybeOf(context)!;
    final trailing = bar.edge == GlassVerticalBarEdge.trailing;
    final inset = bar.width - GlassVerticalBarMetrics.inset - GlassVerticalBarMetrics.controlExtent;
    Widget icon(int i) =>
        Badge(isLabelVisible: i == 2 && widget.badge > 0, label: Text('${widget.badge}'), child: Icon(widget.icons[i]));
    return LayoutBuilder(
      builder: (context, constraints) => WindowChrome(
        size: constraints.biggest,
        child: Align(
          alignment: trailing ? AlignmentDirectional.bottomEnd : AlignmentDirectional.bottomStart,
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              bottom: bar.bottom,
              start: trailing ? 0 : inset,
              end: trailing ? inset : 0,
            ),
            child: GlassPullDownButton(
              icon: IconTheme(
                data: IconThemeData(color: context.palette.accent),
                child: icon(widget.selected),
              ),
              semanticLabel: '${widget.labels[widget.selected]}，切换页面',
              menuSemanticLabel: '切换页面',
              buttonWidth: GlassVerticalBarMetrics.controlExtent,
              buttonHeight: GlassVerticalBarMetrics.controlExtent,
              menuWidth: 220,
              settings: glassPanelSettings(context, context.palette.card),
              quality: glassQuality(context),
              items: [
                for (var i = 0; i < widget.labels.length; i++)
                  GlassMenuItem(
                    title: widget.labels[i],
                    icon: icon(i),
                    trailing: i == widget.selected ? const Icon(Icons.check, size: 18) : null,
                    onTap: () => widget.onSelected(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
