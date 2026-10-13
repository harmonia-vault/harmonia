// 无级本机透明度；复用现成滑条的材质、动效与坐标，松手吸附五个等距标记。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../core/appearance.dart';
import 'glass.dart';
import 'theme.dart';
import 'widgets.dart';

class GlassTransparencyControl extends StatefulWidget {
  const GlassTransparencyControl({super.key, required this.value, required this.onChanged, required this.onPreview});
  final double value;
  final Future<void> Function(double) onChanged;
  final ValueChanged<double?> onPreview;

  @override
  State<GlassTransparencyControl> createState() => _GlassTransparencyControlState();
}

class _GlassTransparencyControlState extends State<GlassTransparencyControl> {
  double? _draft;
  bool _saving = false, _dragging = false;
  int _gesture = 0;
  double get _opacity => _draft ?? widget.value;

  Future<void> _save(double value) async {
    final opacity = snapGlassOpacity(value);
    if (_saving) return;
    _dragging = false;
    if (opacity == widget.value) {
      setState(() => _draft = null);
      widget.onPreview(null);
      return;
    }
    setState(() {
      _draft = opacity;
      _saving = true;
    });
    widget.onPreview(opacity);
    try {
      await widget.onChanged(opacity);
    } catch (_) {
      if (mounted) toast(context, '透明度未能保存，请重试。');
    } finally {
      if (mounted) {
        widget.onPreview(null);
        setState(() {
          _draft = null;
          _saving = false;
        });
      }
    }
  }

  void _start(double _) {
    _gesture++;
    _dragging = true;
  }

  void _change(double value) {
    if (!_dragging) return;
    final opacity = value.clamp(0.0, 1.0);
    setState(() => _draft = opacity);
    widget.onPreview(opacity);
  }

  void _end(double value) {
    final gesture = _gesture;
    // 上游把取消也报告为松手，等本次指针事件分发完后再确认是否保存。
    Future.microtask(() {
      if (mounted && _dragging && gesture == _gesture) _save(value);
    });
  }

  void _cancelPreview() {
    _gesture++;
    setState(() {
      _dragging = false;
      _draft = null;
    });
    widget.onPreview(null);
  }

  @override
  void dispose() {
    if (_draft != null || _dragging) {
      final clear = widget.onPreview;
      // 页面退出可能发生在构建中，下一帧清理临时外观。
      WidgetsBinding.instance.addPostFrameCallback((_) => clear(null));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glass = usesGlass(context) && !MediaQuery.disableAnimationsOf(context);
    final percent = (_opacity * 100).round();
    final label = '遮盖 $percent%';
    const layout = LiquidGlassSliderLayout();
    const motion = LiquidGlassLensMotionSpec();
    final labelStyle = DefaultTextStyle.of(context).style.copyWith(color: p.mute, fontSize: 12);
    // 说明文字、五个刻度和滑块端点使用同一中心行程；大字号按文字宽度留出两端空间。
    final text = TextPainter(
      text: TextSpan(text: '遮盖最强', style: labelStyle),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
    )..layout();
    final inset = math.max(
      layout.resolveHorizontalInset(motion.maxDeformation) + layout.thumbWidth / 2,
      text.width / 2,
    );
    text.dispose();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                '通透度',
                style: TextStyle(color: p.ink, fontWeight: FontWeight.w500),
              ),
              Text(label, style: TextStyle(color: p.mute)),
            ],
          ),
          const SizedBox(height: 12),
          Semantics(
            slider: true,
            label: '液态玻璃遮盖程度，向左更通透，向右遮盖更强',
            value: label,
            increasedValue: _opacity < 1 ? '遮盖 ${((_opacity + 0.05).clamp(0, 1) * 100).round()}%' : null,
            decreasedValue: _opacity > 0 ? '遮盖 ${((_opacity - 0.05).clamp(0, 1) * 100).round()}%' : null,
            onIncrease: _saving || _opacity == 1 ? null : () => _save((_opacity + 0.05).clamp(0, 1)),
            onDecrease: _saving || _opacity == 0 ? null : () => _save((_opacity - 0.05).clamp(0, 1)),
            child: ExcludeSemantics(
              child: Focus(
                onKeyEvent: (_, event) {
                  if (_saving || event is! KeyDownEvent) return KeyEventResult.ignored;
                  final direction = event.logicalKey == LogicalKeyboardKey.arrowRight
                      ? 1
                      : event.logicalKey == LogicalKeyboardKey.arrowLeft
                      ? -1
                      : 0;
                  if (direction == 0) return KeyEventResult.ignored;
                  _save((_opacity + direction * 0.05).clamp(0, 1));
                  return KeyEventResult.handled;
                },
                child: IgnorePointer(
                  ignoring: _saving,
                  child: Listener(
                    onPointerCancel: (_) => _cancelPreview(),
                    child: LayoutBuilder(
                      builder: (_, constraints) => glass
                          ? LiquidGlassSlider(
                              value: _opacity,
                              width: constraints.maxWidth,
                              layout: layout.copyWith(horizontalInset: inset - layout.thumbWidth / 2),
                              onChangeStart: _start,
                              onChanged: _change,
                              onChangeEnd: _end,
                              activeColor: p.accentFill,
                              inactiveColor: p.mute.withValues(alpha: 0.35),
                              // 保留上游白色滑块与 defaultStyle 的接触阴影，深色模式同样清晰。
                              thumbColor: Colors.white,
                            )
                          : SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                trackShape: const RectangularSliderTrackShape(),
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
                                thumbColor: Colors.white,
                                overlayShape: SliderComponentShape.noOverlay,
                              ),
                              child: Slider(
                                padding: EdgeInsets.symmetric(horizontal: inset, vertical: 16),
                                value: _opacity,
                                onChangeStart: _start,
                                onChanged: _change,
                                onChangeEnd: _end,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: LayoutBuilder(
              builder: (_, constraints) {
                final travel = constraints.maxWidth - 2 * inset;
                final labelWidth = math.max(1.0, travel / 2 - 8);
                const labels = [(0.0, '最通透'), (0.5, '默认'), (1.0, '遮盖最强')];
                var labelHeight = 0.0;
                for (final (_, label) in labels) {
                  final painter = TextPainter(
                    text: TextSpan(text: label, style: labelStyle),
                    textScaler: MediaQuery.textScalerOf(context),
                    textDirection: TextDirection.ltr,
                  )..layout(maxWidth: labelWidth);
                  labelHeight = math.max(labelHeight, painter.height);
                  painter.dispose();
                }
                return SizedBox(
                  height: 9 + labelHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = 0; i < 5; i++)
                        Positioned(
                          left: inset + travel * i / 4 - 1,
                          child: Container(width: 2, height: 5, color: p.mute),
                        ),
                      for (final (value, label) in labels)
                        Positioned(
                          left: inset + travel * value - labelWidth / 2,
                          top: 9,
                          width: labelWidth,
                          child: Text(label, style: labelStyle, textAlign: TextAlign.center),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
