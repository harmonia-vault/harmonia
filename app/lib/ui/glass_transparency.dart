// 无级本机透明度；松手吸附五个等距标记，读屏与键盘也能调整。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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

  void _change(double value) {
    final opacity = value.clamp(0.0, 1.0);
    if (_dragging) {
      setState(() => _draft = opacity);
      widget.onPreview(opacity);
    } else {
      _save(opacity);
    }
  }

  void _cancelPreview() {
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
    final glass = usesGlass(context);
    final label = _opacity == 0
        ? '最通透'
        : _opacity == 1
        ? '遮盖最强'
        : _opacity == 0.5
        ? '均衡（默认）'
        : '自定义';
    final theme = Theme.of(context);
    final appearance = theme.extension<AppearanceTheme>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '透明度 · $label',
            style: TextStyle(color: p.ink, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          Theme(
            data: theme.copyWith(
              extensions: [
                ...theme.extensions.values.where((e) => e is! AppearanceTheme),
                appearance.copyWith(glassOpacity: _opacity),
              ],
            ),
            child: Builder(
              builder: (context) => Semantics(
                slider: true,
                label: '液态玻璃透明度',
                value: '$label，${((1 - _opacity) * 100).round()}%',
                increasedValue: _opacity > 0 ? '${((1 - (_opacity - 0.05).clamp(0, 1)) * 100).round()}%' : null,
                decreasedValue: _opacity < 1 ? '${((1 - (_opacity + 0.05).clamp(0, 1)) * 100).round()}%' : null,
                onIncrease: _saving || _opacity == 0 ? null : () => _save((_opacity - 0.05).clamp(0, 1)),
                onDecrease: _saving || _opacity == 1 ? null : () => _save((_opacity + 0.05).clamp(0, 1)),
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
                      child: glass
                          ? Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              child: LayoutBuilder(
                                builder: (context, constraints) => GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: (event) =>
                                      _save(((event.localPosition.dx - 16) / (constraints.maxWidth - 32)).clamp(0, 1)),
                                  child: Listener(
                                    onPointerCancel: (_) => _cancelPreview(),
                                    child: TickerMode(
                                      enabled: !MediaQuery.disableAnimationsOf(context),
                                      child: GlassSlider(
                                        value: _opacity,
                                        min: 0,
                                        max: 1,

                                        onChangeStart: (_) => _dragging = true,
                                        onChanged: _change,
                                        onChangeEnd: (_) => _save(_opacity),
                                        activeColor: p.accent,
                                        inactiveColor: p.mute.withValues(alpha: 0.35),
                                        thumbColor: p.card,
                                        thumbRadius: 16,
                                        useOwnLayer: true,
                                        settings: glassSettings(context),
                                        quality: glassQuality(context),
                                        interactionBehavior: MediaQuery.disableAnimationsOf(context)
                                            ? GlassInteractionBehavior.none
                                            : GlassInteractionBehavior.full,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : Slider(
                              value: _opacity,
                              min: 0,
                              max: 1,

                              label: label,
                              onChangeStart: (_) => _dragging = true,
                              onChanged: _change,
                              onChangeEnd: (_) => _save(_opacity),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ExcludeSemantics(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var i = 0; i < 5; i++)
                    Container(
                      width: 3,
                      height: 5,
                      decoration: BoxDecoration(color: p.mute, borderRadius: BorderRadius.circular(2)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final text in ['最通透', '均衡', '遮盖最强']) Text(text, style: TextStyle(color: p.mute, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
