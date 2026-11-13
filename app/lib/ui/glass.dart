// 玻璃承载悬浮操作，正文保持实色；内容始终位于折射层之外。
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'theme.dart';
import 'adaptive_page.dart';
import 'glass_material.dart';
import 'workspace_scope.dart';
import 'workspace_detail.dart';
import 'window_layout.dart';

export 'package:liquid_glass_widgets/liquid_glass_widgets.dart' show GlassBarItem;

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
GlassQuality glassQuality(BuildContext context) =>
    MediaQuery.highContrastOf(context) ? GlassQuality.standard : GlassRenderingScope.qualityOf(context);

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

LiquidGlassSettings glassSettings(BuildContext context) {
  final material = glassMaterial(
    dark: Theme.of(context).brightness == Brightness.dark,
    opacity: Theme.of(context).extension<AppearanceTheme>()?.glassOpacity ?? 0.5,
  );
  return MediaQuery.highContrastOf(context)
      ? material.copyWith(glassColor: context.palette.card, blur: 0, frost: 0, bodyShade: 0)
      : material;
}

/// 弹窗、弹层与通知的材质：正文必须可读，透明度滑条只在可读范围内调节。
LiquidGlassSettings glassPanelSettings(BuildContext context, Color tint) => MediaQuery.highContrastOf(context)
    ? glassSettings(context).copyWith(glassColor: tint)
    : glassPanelMaterial(
        dark: Theme.of(context).brightness == Brightness.dark,
        opacity: Theme.of(context).extension<AppearanceTheme>()?.glassOpacity ?? 0.5,
        tint: tint,
        refraction: glassQuality(context) == GlassQuality.premium,
      );

/// 面板里需要更稳的阅读底时用的雾面：比面板更不透，但仍带着背后的颜色。
Color glassFrostFill(BuildContext context) =>
    MediaQuery.highContrastOf(context) ? context.palette.card : context.palette.card.withValues(alpha: 0.6);

/// 玻璃面板从遮罩后的画面取样，遮罩过深会把面板一起压暗。
Color glassBarrierColor(BuildContext context) =>
    Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.45 : 0.24);

/// 悬浮操作用 [glassSettings]；[panel] 表示上面放的是正文。阴影与裁切交给组件库，避免玻璃折射到自己的阴影。
class AppSurface extends StatelessWidget {
  const AppSurface({super.key, required this.child, required this.color, this.radius = 0, this.panel = false});

  final Widget child;
  final Color color;
  final double radius;
  final bool panel;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      useOwnLayer: true,
      quality: glassQuality(context),
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      settings: panel
          ? glassPanelSettings(context, color)
          : glassSettings(context).copyWith(
              shadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 20, offset: Offset(0, 6))],
            ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 操作以语义项交给库，统一分组、溢出和返回转场。
class AppBarSurface extends StatelessWidget implements PreferredSizeWidget {
  const AppBarSurface({
    super.key,
    this.title,
    this.actions = const [],
    this.onBack,
    this.largeTitle,
    this.toolbarHeight = kToolbarHeight,
  });
  // 库默认操作组为 46 点，返回按钮另由库计算。
  static const double actionExtent = 46;
  final Widget? title;
  final List<GlassBarItem> actions;
  final VoidCallback? onBack;
  final GlassLargeTitleController? largeTitle;
  final double toolbarHeight;

  @override
  Size get preferredSize => Size.fromHeight(toolbarHeight);

  Widget bar(BuildContext context) {
    final pane = WorkspacePane.maybeOf(context);
    final presentation = PresentationScope.contains(context);
    if (pane?.active == false && !presentation) return const SizedBox(height: kToolbarHeight);
    final heading = title == null
        ? null
        : DefaultTextStyle(
            style: Theme.of(context).textTheme.titleMedium!
                .copyWith(color: context.palette.ink, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: title!,
          );
    final leading = [
      if (onBack != null) GlassBarItem.icon(icon: const Icon(CupertinoIcons.chevron_back), label: '返回', onTap: onBack!),
    ];
    final page = ModalRoute.of(context)?.settings;
    final rootSelection = page is WorkspaceDetailPage && page.selection && WindowLayoutScope.maybeOf(context)!.twoPanes;
    final shell = GlassNavigationShell.maybeOf(context);
    final localStrip = GlassVerticalBar.maybeOf(context) != null && shell?.verticalBar == null;
    // 紧凑横屏的操作随页面原生转场，避免把两页含义不同的加号与更多组融合。
    final compact = WindowLayoutScope.maybeOf(context)!.compactNavigation;
    if (pane?.master == true || compact || localStrip || presentation) {
      final bar = GlassPinnedBarChrome(
        enabled: false,
        leading: leading,
        backButton: pane?.master != true && !rootSelection,
        actions: actions,
        buttonSettings: glassSettings(context),
        horizontalInset: 20,
        largeTitleController: largeTitle,
        builder: (context, chrome) => GlassAppBar(
          title: heading,
          centerTitle: largeTitle != null,
          largeTitleController: largeTitle,
          toolbarHeight: toolbarHeight,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          leading: chrome.leading,
          actions: pane?.master == true
              ? [for (final action in chrome.actions) WindowMenuViewport(child: action)]
              : chrome.actions,
        ),
      );
      if (pane?.master == true) return GlassVerticalBar.disabled(child: bar);
      return localStrip ? WindowMenuViewport(child: bar) : bar;
    }
    return GlassAppBar.pinned(
      title: heading,
      centerTitle: largeTitle != null,
      largeTitleController: largeTitle,
      leading: leading,
      actions: actions,
      backButton: !rootSelection,
      toolbarHeight: toolbarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      buttonSettings: glassSettings(context),
    );
  }

  @override
  Widget build(BuildContext context) => bar(context);
}

/// 正文在页面容器提供的安全区下构建。
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    this.appBar,
    required this.body,
    this.avoidKeyboard,
    this.controls,
    this.header,
    this.headerScrollController,
  });
  final AppBarSurface? appBar;
  final WidgetBuilder body;
  final Widget? controls;
  final Widget? header;
  final ScrollController? headerScrollController;

  /// 正文是否随键盘收缩；一级列表由上层面板处理键盘，不收缩。
  final bool? avoidKeyboard;

  @override
  Widget build(BuildContext context) => AdaptivePageFrame(
    appBar: appBar,
    body: body,
    avoidKeyboard: avoidKeyboard,
    controls: controls,
    header: header,
    headerScrollController: headerScrollController,
  );
}

/// 页面容器已计算标题栏与安全区，不重复累加工具栏高度。
EdgeInsets pagePadding(BuildContext context, EdgeInsets padding) {
  final insets = MediaQuery.paddingOf(context);
  return padding.copyWith(top: padding.top + (insets.top), bottom: padding.bottom + insets.bottom);
}

/// 普通手机与双栏列表的大标题和操作同一行，滚动后交接为居中小标题。
class AppTabPage extends StatefulWidget {
  const AppTabPage({
    super.key,
    required this.title,
    required this.padding,
    required this.children,
    this.actions,
    this.onRefresh,
  });
  final String title;
  final EdgeInsets padding;
  final List<Widget> children;
  final List<GlassBarItem>? actions;
  final Future<void> Function()? onRefresh;

  @override
  State<AppTabPage> createState() => _AppTabPageState();
}

class _AppTabPageState extends State<AppTabPage> {
  final _largeTitle = GlassLargeTitleController();

  @override
  void dispose() {
    _largeTitle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = WindowLayoutScope.maybeOf(context)!;
    final master = WorkspacePane.maybeOf(context)?.master == true;
    final largeTitle = master || !layout.verticalNavigation && !layout.regularWidth ? _largeTitle : null;
    final strip = GlassVerticalBar.maybeOf(context);
    final toolbarHeight = master && strip != null
        ? strip.rowTop + GlassVerticalBarMetrics.rowHeight - MediaQuery.paddingOf(context).top
        : kToolbarHeight;
    return AppPage(
      appBar: AppBarSurface(
        title: Text(widget.title),
        actions: widget.actions ?? const [],
        largeTitle: largeTitle,
        toolbarHeight: toolbarHeight,
      ),
      headerScrollController: largeTitle?.scrollController,
      header: largeTitle == null
          ? null
          : IgnorePointer(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20 + AppBarSurface.actionExtent * (widget.actions?.length ?? 0) + Space.md,
                ),
                child: SizedBox(
                  height: toolbarHeight,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.ink,
                        fontSize: master ? 28 : 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.5,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
      avoidKeyboard: false,
      body: (context) {
        final insets = MediaQuery.paddingOf(context);
        final list = CustomScrollView(
          controller: _largeTitle.scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: widget.padding.copyWith(
                top: widget.padding.top + insets.top + Space.lg,
                bottom: widget.padding.bottom + insets.bottom,
              ),
              sliver: SliverList.list(children: widget.children),
            ),
          ],
        );
        final refresh = widget.onRefresh;
        return refresh == null ? list : RefreshIndicator(onRefresh: refresh, edgeOffset: insets.top, child: list);
      },
    );
  }
}

class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    required this.title,
    this.icon,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final Widget title;
  final Widget? icon, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: icon,
    title: title,
    subtitle: subtitle,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: CupertinoSwitch(value: value, activeTrackColor: context.palette.accentFill, onChanged: onChanged),
  );
}
