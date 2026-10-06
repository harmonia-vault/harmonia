// 视觉：沿用“砂岩”配色——暖纸米色底、深墨描边、陶橙主色。
import 'package:flutter/material.dart';

abstract final class Space {
  static const double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32;
}

class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.paper,
    required this.card,
    required this.ink,
    required this.mute,
    required this.line,
    required this.accent,
    required this.ok,
    required this.warnBox,
    required this.onWarnBox,
    required this.yellow,
    required this.sage,
  });

  final Color paper, card, ink, mute, line, accent, ok, warnBox, onWarnBox, yellow, sage;

  static const light = Palette(
    paper: Color(0xFFF2EDE4),
    card: Color(0xFFFFFAF2),
    ink: Color(0xFF1E1B16),
    mute: Color(0xFF6E675C),
    line: Color(0xFFDDD4C4),
    accent: Color(0xFFE2572B),
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

ThemeData buildTheme(Brightness brightness) {
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
    extensions: [p],
    appBarTheme: AppBarTheme(
      backgroundColor: p.paper,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.line, width: 1.2),
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
        minimumSize: const Size.fromHeight(52),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: const StadiumBorder(),
        foregroundColor: p.ink,
        side: BorderSide(color: p.ink.withValues(alpha: 0.6), width: 1.2),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.card,
      indicatorColor: p.yellow,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
  );
}
