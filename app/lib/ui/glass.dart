// 玻璃承载悬浮操作，正文保持实色；内容始终位于折射层之外。
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'theme.dart';
import 'glass_material.dart';

abstract final class GlassResources {
  static bool _ready = false;

  static bool get supportsRefraction => ui.ImageFilter.isShaderFilterSupported;

  static Future<void> prepare() async {
    if (_ready) return;
    await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    debugPrint('[Harmonia glass] shaderFilterSupported=$supportsRefraction');
    _ready = true;
  }
}

/// 只在页面调试中覆盖；正常界面按引擎能力选择，不增加用户画质设置。
class GlassRenderingScope extends InheritedWidget {
  const GlassRenderingScope({super.key, this.quality, required super.child});
  final GlassQuality? quality;

  static GlassQuality qualityOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassRenderingScope>()?.quality ??
      (GlassResources.supportsRefraction ? GlassQuality.premium : GlassQuality.standard);

  @override
  bool updateShouldNotify(GlassRenderingScope oldWidget) => quality != oldWidget.quality;
}

// 不支持完整折射时直接选 standard，避免插件把 premium 的厚度和光照再次缩小。
GlassQuality glassQuality(BuildContext context) => GlassRenderingScope.qualityOf(context);

bool usesGlass(BuildContext context) =>
    (Theme.of(context).extension<AppearanceTheme>()?.liquidGlass ?? false) && !MediaQuery.highContrastOf(context);

/// 位于导航器上方，拖动直接更新所有玻璃表面；不写存储、不重建路由。
class GlassOpacityPreview extends StatelessWidget {
  const GlassOpacityPreview({super.key, required this.preview, required this.child});
  final ValueListenable<double?> preview;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double?>(
    valueListenable: preview,
    child: child,
    builder: (context, value, child) {
      final theme = Theme.of(context);
      final appearance = theme.extension<AppearanceTheme>()!;
      return Theme(
        data: theme.copyWith(
          extensions: [
            ...theme.extensions.values.where((extension) => extension is! AppearanceTheme),
            appearance.copyWith(glassOpacity: value ?? appearance.glassOpacity),
          ],
        ),
        child: child!,
      );
    },
  );
}

LiquidGlassSettings glassSettings(BuildContext context, {bool readable = false}) => glassMaterial(
  dark: Theme.of(context).brightness == Brightness.dark,
  // 正文弹层至少使用上游 regular 默认材质；不再盖一层近乎不透明的面板。
  opacity: (Theme.of(context).extension<AppearanceTheme>()?.glassOpacity ?? 0.5).clamp(readable ? 0.5 : 0.0, 1.0),
);

class AppSurface extends StatelessWidget {
  const AppSurface({super.key, required this.child, required this.color, this.radius = 0, this.tintAlpha});

  final Widget child;
  final Color color;
  final double radius;
  final double? tintAlpha;

  @override
  Widget build(BuildContext context) {
    final glass = usesGlass(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glass
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 20, offset: const Offset(0, 6))]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: glass
                    ? GlassContainer(
                        useOwnLayer: true,
                        quality: glassQuality(context),
                        shape: LiquidRoundedSuperellipse(borderRadius: radius),
                        settings: glassSettings(context),
                      )
                    : ColoredBox(color: color),
              ),
            ),
            if (glass && tintAlpha != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: const EdgeInsets.all(1),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: tintAlpha!),
                        borderRadius: BorderRadius.circular(radius - 1),
                      ),
                    ),
                  ),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

class AppBarSurface extends StatelessWidget implements PreferredSizeWidget {
  const AppBarSurface({super.key, this.title, this.leading, this.actions, this.largeTitle = false});
  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final bool largeTitle;

  @override
  Size get preferredSize => Size.fromHeight(largeTitle ? 96 : kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    if (!usesGlass(context)) return AppBar(title: title, leading: leading, actions: actions);
    final p = context.palette;
    final back =
        leading ??
        (!largeTitle && Navigator.of(context).canPop()
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(CupertinoIcons.chevron_back, size: 22),
              )
            : null);
    Widget controls(List<Widget> children) => AppSurface(
      color: p.card,
      radius: 24,
      child: Material(
        type: MaterialType.transparency,
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: p.ink),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
    final titleLabel = DefaultTextStyle(
      style: TextStyle(
        color: p.ink,
        fontSize: largeTitle ? 34 : 17,
        fontWeight: FontWeight.w700,
        letterSpacing: largeTitle ? -0.8 : 0,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: title ?? const SizedBox.shrink(),
    );
    final trailing = actions?.isNotEmpty == true ? controls(actions!) : null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: SizedBox(
        height: preferredSize.height + MediaQuery.viewPaddingOf(context).top,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [p.paper, p.paper.withValues(alpha: 0.96), p.paper.withValues(alpha: 0)],
              stops: const [0, 0.55, 1],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 6, 20, largeTitle ? 16 : 6),
              child: largeTitle
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: titleLabel),
                        ?trailing,
                      ],
                    )
                  : NavigationToolbar(
                      leading: back == null ? null : controls([back]),
                      middle: titleLabel,
                      trailing: trailing,
                      centerMiddle: true,
                      middleSpacing: 12,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 正文必须在 Scaffold 的 MediaQuery 之下构建，读取的是实际遮挡高度。
class AppPage extends StatelessWidget {
  const AppPage({super.key, this.appBar, required this.body, this.floatingActionButton});
  final AppBarSurface? appBar;
  final WidgetBuilder body;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: usesGlass(context) && appBar != null,
    appBar: appBar,
    floatingActionButton: floatingActionButton,
    body: Builder(builder: body),
  );
}

/// Scaffold 已计算标题栏与安全区；不要在这里再次累加工具栏高度。
EdgeInsets pagePadding(BuildContext context, EdgeInsets padding) {
  final insets = MediaQuery.paddingOf(context);
  return padding.copyWith(
    top: padding.top + (usesGlass(context) ? insets.top : 0),
    bottom: padding.bottom + insets.bottom,
  );
}

class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    required this.title,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final Widget title, icon;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => usesGlass(context)
      ? ListTile(
          leading: icon,
          title: title,
          subtitle: subtitle,
          onTap: onChanged == null ? null : () => onChanged!(!value),
          trailing: CupertinoSwitch(value: value, activeTrackColor: context.palette.accent, onChanged: onChanged),
        )
      : SwitchListTile(secondary: icon, title: title, subtitle: subtitle, value: value, onChanged: onChanged);
}
