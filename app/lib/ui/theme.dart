// 视觉：沿用“砂岩”配色——暖纸米色底、深墨描边、陶橙主色。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' show GlassPageTransitionsBuilder;

import '../core/appearance.dart';

/// 沿用库的原生页面与手势转场，只缩短频繁编辑时的等待。
class _AppPageTransitions extends GlassPageTransitionsBuilder {
  const _AppPageTransitions();
  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 240);
}

String colorModeLabel(AppColorMode mode) => switch (mode) {
  AppColorMode.system => '跟随系统',
  AppColorMode.light => '亮色',
  AppColorMode.dark => '暗色',
};

ThemeMode colorThemeMode(AppColorMode mode) => switch (mode) {
  AppColorMode.system => ThemeMode.system,
  AppColorMode.light => ThemeMode.light,
  AppColorMode.dark => ThemeMode.dark,
};

abstract final class Space {
  static const double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32;
}

class AppearanceTheme extends ThemeExtension<AppearanceTheme> {
  const AppearanceTheme([this.glassOpacity = 0.5]);
  final double glassOpacity;

  @override
  AppearanceTheme copyWith({double? glassOpacity}) => AppearanceTheme(glassOpacity ?? this.glassOpacity);

  @override
  AppearanceTheme lerp(AppearanceTheme? other, double t) => other ?? this;
}

class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.paper,
    required this.card,
    required this.ink,
    required this.mute,
    required this.line,
    required this.accent,
    required this.accentFill,
    required this.ok,
    required this.warnBox,
    required this.onWarnBox,
    required this.yellow,
    required this.sage,
  });

  final Color paper, card, ink, mute, line, accent, accentFill, ok, warnBox, onWarnBox, yellow, sage;

  static const light = Palette(
    paper: Color(0xFFF2EDE4),
    card: Color(0xFFFFFAF2),
    ink: Color(0xFF1E1B16),
    mute: Color(0xFF6E675C),
    line: Color(0xFFDDD4C4),
    accent: Color(0xFFB5431F),
    accentFill: Color(0xFFC94F27),
    ok: Color(0xFF2F7D4F),
    warnBox: Color(0xFFF6D6C2),
    onWarnBox: Color(0xFF5C2611),
    yellow: Color(0xFFF5CF6B),
    sage: Color(0xFFBFD2B0),
  );

  static const dark = Palette(
    paper: Color(0xFF17140F),
    card: Color(0xFF221E18),
    ink: Color(0xFFF2EDE4),
    mute: Color(0xFFA69D8D),
    line: Color(0xFF342E25),
    accent: Color(0xFFEC6A3C),
    accentFill: Color(0xFFC94F27),
    ok: Color(0xFF79C792),
    warnBox: Color(0xFF4A2A1B),
    onWarnBox: Color(0xFFF6D6C2),
    yellow: Color(0xFFE9BD52),
    sage: Color(0xFFA3BD92),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) => t < 0.5 ? this : (other as Palette);
}

extension PaletteX on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
}

ThemeData buildTheme(Brightness brightness, {double glassOpacity = 0.5}) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: brightness,
    primary: p.accent,
    onPrimary: brightness == Brightness.light ? Colors.white : p.paper,
    surface: p.paper,
    onSurface: p.ink,
    surfaceContainerLowest: p.card,
    surfaceContainerLow: p.card,
    surfaceContainer: p.card,
    outline: p.ink.withValues(alpha: 0.5),
    outlineVariant: p.line,
  );
  // 输入框保留一道细线：浮动标签要落在线上，也用它和不可编辑的卡片区分。
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(18),
    borderSide: BorderSide(color: p.line, width: 1),
  );
  return ThemeData(
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {...const PageTransitionsTheme().builders, TargetPlatform.iOS: const _AppPageTransitions()},
    ),
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.paper,
    extensions: [p, AppearanceTheme(glassOpacity)],
    appBarTheme: AppBarTheme(
      backgroundColor: p.paper,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3),
      minLeadingWidth: 24,
      horizontalTitleGap: 14,
      iconColor: p.mute,
      titleTextStyle: TextStyle(inherit: false, color: p.ink, fontSize: 16, fontWeight: FontWeight.w500),
      subtitleTextStyle: TextStyle(inherit: false, color: p.mute, fontSize: 13, height: 1.5),
    ),
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      // 裁到圆角内，里面列表项的按压高亮才不会露出直角。
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide.none),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.card,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: p.accent, width: 1.6)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        // 实心按钮明暗两种模式同一个橙，白字对比度 4.5:1。
        backgroundColor: p.accentFill,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: const StadiumBorder(),
        foregroundColor: p.ink,
        backgroundColor: p.card,
        side: BorderSide.none,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dialogTheme: DialogThemeData(backgroundColor: p.card, surfaceTintColor: Colors.transparent),
    dividerTheme: DividerThemeData(color: p.line, thickness: 0.5, space: 1, indent: 56),
  );
}
