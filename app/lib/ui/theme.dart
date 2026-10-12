// 视觉：沿用“砂岩”配色——暖纸米色底、深墨描边、陶橙主色。
import 'package:flutter/material.dart';

import '../core/appearance.dart';

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
  const AppearanceTheme(this.liquidGlass, [this.glassOpacity = 0.5]);
  final bool liquidGlass;
  final double glassOpacity;

  @override
  AppearanceTheme copyWith({bool? liquidGlass, double? glassOpacity}) =>
      AppearanceTheme(liquidGlass ?? this.liquidGlass, glassOpacity ?? this.glassOpacity);

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
    accent: Color(0xFFA83213),
    accentFill: Color(0xFFE2572B),
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
    accentFill: Color(0xFFEC6A3C),
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

ThemeData buildTheme(Brightness brightness, {bool liquidGlass = false, double glassOpacity = 0.5}) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: brightness,
    primary: p.accent,
    onPrimary: brightness == Brightness.light ? p.card : p.paper,
    surface: p.paper,
    onSurface: p.ink,
    surfaceContainerLowest: p.card,
    surfaceContainerLow: p.card,
    surfaceContainer: p.card,
    outline: p.ink.withValues(alpha: 0.5),
    outlineVariant: p.line,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: p.line, width: 1.2),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.paper,
    extensions: [p, AppearanceTheme(liquidGlass, glassOpacity)],
    appBarTheme: AppBarTheme(
      backgroundColor: p.paper,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    listTileTheme: liquidGlass
        ? ListTileThemeData(
            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3),
            minLeadingWidth: 24,
            horizontalTitleGap: 14,
            iconColor: p.mute,
            titleTextStyle: TextStyle(inherit: false, color: p.ink, fontSize: 16, fontWeight: FontWeight.w500),
            subtitleTextStyle: TextStyle(inherit: false, color: p.mute, fontSize: 13, height: 1.5),
          )
        : null,
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      // 裁到圆角内，里面列表项的按压高亮才不会露出直角。
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(liquidGlass ? 24 : 18),
        side: liquidGlass ? BorderSide.none : BorderSide(color: p.line, width: 1.2),
      ),
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
        backgroundColor: p.accentFill,
        foregroundColor: Palette.light.ink,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: const StadiumBorder(),
        foregroundColor: p.ink,
        side: BorderSide(color: p.ink.withValues(alpha: 0.6), width: 1.2),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dialogTheme: DialogThemeData(backgroundColor: p.card, surfaceTintColor: Colors.transparent),
    dividerTheme: DividerThemeData(
      color: p.line,
      thickness: liquidGlass ? 0.5 : 1,
      space: 1,
      indent: liquidGlass ? 56 : null,
    ),
  );
}
