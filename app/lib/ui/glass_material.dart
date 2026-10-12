// 默认材质直接使用依赖库预设；通透度比例来自 ios27-design-system 的五档曲线。
// 这是一套开源近似参数，不是 Apple 公布的系统内部参数。
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
