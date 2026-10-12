// 紧凑玻璃底栏：选中胶囊始终比主体略高，独立布局避免被主体裁切。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';

class AppGlassNavBar extends StatefulWidget {
  const AppGlassNavBar({super.key, required this.tabs, required this.selectedIndex, required this.onSelected});
  final List<GlassTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<AppGlassNavBar> createState() => _AppGlassNavBarState();
}

class _AppGlassNavBarState extends State<AppGlassNavBar> {
  double? _dragIndex;

  double _indexAt(double x, double width, TextDirection direction) {
    final fraction = (x / width).clamp(0.0, 1.0);
    final logical = direction == TextDirection.rtl ? 1 - fraction : fraction;
    return (logical * widget.tabs.length - 0.5).clamp(0.0, widget.tabs.length - 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final direction = Directionality.of(context);
    final labelStyle = Theme.of(context).textTheme.labelSmall!.copyWith(fontSize: 11, fontWeight: FontWeight.w600);
    final label = TextPainter(
      text: TextSpan(text: widget.tabs.first.label ?? '', style: labelStyle),
      textDirection: direction,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    // 常规字号主体 52，胶囊 60；大字号按真实行高增高，点击区域始终至少 60。
    final barHeight = (24 + 3 + label.height + 8).clamp(52.0, double.infinity);
    label.dispose();
    final capsuleHeight = barHeight + 8;
    final visualIndex = _dragIndex ?? widget.selectedIndex.toDouble();
    final alignment = widget.tabs.length == 1 ? 0.0 : visualIndex / (widget.tabs.length - 1) * 2 - 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
      child: SizedBox(
        height: capsuleHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(top: 4, bottom: 4, child: IgnorePointer(child: _glass(context))),
            Positioned.fill(
              left: 4,
              right: 4,
              child: IgnorePointer(
                child: AnimatedAlign(
                  alignment: AlignmentDirectional(alignment, 0),
                  duration: reduceMotion || _dragIndex != null ? Duration.zero : const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                  child: FractionallySizedBox(
                    widthFactor: 1 / widget.tabs.length,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(capsuleHeight / 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10),
                            blurRadius: 12,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: _glass(context, selected: true),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (details) =>
                      setState(() => _dragIndex = _indexAt(details.localPosition.dx, constraints.maxWidth, direction)),
                  onHorizontalDragUpdate: (details) =>
                      setState(() => _dragIndex = _indexAt(details.localPosition.dx, constraints.maxWidth, direction)),
                  onHorizontalDragCancel: () => setState(() => _dragIndex = null),
                  onHorizontalDragEnd: (_) {
                    final index = (_dragIndex ?? widget.selectedIndex.toDouble()).round();
                    setState(() => _dragIndex = null);
                    if (index != widget.selectedIndex) widget.onSelected(index);
                  },
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.tabs.length; i++)
                        Expanded(
                          child: Semantics(
                            selected: i == widget.selectedIndex,
                            child: TextButton(
                              onPressed: () => widget.onSelected(i),
                              style: TextButton.styleFrom(
                                foregroundColor: i == visualIndex.round() ? p.accent : p.ink,
                                minimumSize: Size(48, capsuleHeight),
                                padding: EdgeInsets.zero,
                                shape: const StadiumBorder(),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconTheme.merge(
                                    data: const IconThemeData(size: 24),
                                    child: widget.tabs[i].icon ?? const SizedBox.shrink(),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    widget.tabs[i].label ?? '',
                                    style: labelStyle.copyWith(color: i == visualIndex.round() ? p.accent : p.ink),
                                    maxLines: 1,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glass(BuildContext context, {bool selected = false}) => GlassContainer(
    useOwnLayer: true,
    quality: glassQuality(context),
    shape: const LiquidRoundedRectangle(borderRadius: 999),
    settings: glassSettings(context).copyWith(thickness: selected ? 28 : 22),
    child: selected
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: context.palette.ink.withValues(alpha: 0.10)),
            ),
          )
        : null,
  );
}
