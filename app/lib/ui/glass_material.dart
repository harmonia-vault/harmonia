// 默认材质直接使用依赖库预设；通透度比例来自 ios27-design-system 的五档曲线。
// 这是一套开源近似参数，不是 Apple 公布的系统内部参数。
import 'dart:ui' show lerpDouble;

import 'package:flutter/painting.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

LiquidGlassSettings glassMaterial({required bool dark, required double opacity}) {
  final base = dark ? LiquidGlassSettings.ios27Dark : LiquidGlassSettings.ios27Light;
  if (opacity == 0.5) return base;

  // 上游 transparency 方向相反；这里只反转顺序，并归一化到库的默认材质。
  // https://github.com/seunghan91/ios27-design-system/blob/a112a1b76f57435ad223d926a948d88e12f4a8e7/packages/tokens/src/materials.json
  const opacityScales = [0.5, 0.775, 1.05, 1.325, 1.6];
  const blurScales = [1.3, 1.15, 1.0, 0.75, 0.5];
  final position = opacity.clamp(0.0, 1.0) * 4;
  final index = position.floor().clamp(0, 3);
  final fraction = position - index;
  double interpolate(List<double> stops) => stops[index] + (stops[index + 1] - stops[index]) * fraction;
  final tint = interpolate(opacityScales) / opacityScales[2];
  final blur = interpolate(blurScales);
  return base.copyWith(
    glassColor: base.glassColor.withValues(alpha: (base.glassColor.a * tint).clamp(0, 1)),
    frostOpacity: (base.frostOpacity * tint).clamp(0, 1),
    bodyShade: (base.bodyShade * tint).clamp(0, 1),
    blur: base.blur * blur,
    frost: base.frost * blur,
  );
}

/// 弹窗、弹层与通知这类承载正文的表面，对照系统提醒框调校。
///
/// 系统提醒框的面板很亮，背后的内容糊成一片柔和的色块，看不到任何字形；边缘是一道细描边加高光。
/// 上游预设按 56 点高的控件校准，背后的文字以残影透出，铺成整块正文表面就显得浑浊。
/// 这里保留预设的折射、描边与边缘高光，用宽雾层抹掉全部细节，再按 [tint] 的原色着色，
/// 面板亮度不随遮罩变灰。
LiquidGlassSettings glassPanelMaterial({
  required bool dark,
  required double opacity,
  required Color tint,
  required bool refraction,
}) {
  final base = dark ? LiquidGlassSettings.ios27Dark : LiquidGlassSettings.ios27Light;
  return base.copyWith(
    bodyMode: GlassBodyMode.clear,
    glassColor: tint.withValues(alpha: lerpDouble(0.46, 0.9, opacity.clamp(0.0, 1.0))),
    frost: 30,
    frostOpacity: 1,
    frostClamp: 0,
    frostWeight: 1,
    // 轻量效果没有雾层，只能靠这一遍模糊；完整折射下再加大只会多付一遍采样。
    blur: refraction ? base.blur : 24,
    saturation: 1.6,
    bodyShade: 0,
    shadow: const [BoxShadow(color: Color(0x30000000), blurRadius: 48, offset: Offset(0, 18))],
  );
}
