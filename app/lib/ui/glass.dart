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

LiquidGlassSettings glassSettings(BuildContext context) => glassMaterial(
  dark: Theme.of(context).brightness == Brightness.dark,
  opacity: Theme.of(context).extension<AppearanceTheme>()?.glassOpacity ?? 0.5,
);

/// 弹窗、弹层与通知的材质：正文必须可读，透明度滑条只在可读范围内调节。
LiquidGlassSettings glassPanelSettings(BuildContext context, Color tint) => glassPanelMaterial(
  dark: Theme.of(context).brightness == Brightness.dark,
  opacity: Theme.of(context).extension<AppearanceTheme>()?.glassOpacity ?? 0.5,
  tint: tint,
  refraction: glassQuality(context) == GlassQuality.premium,
);

/// 面板里需要更稳的阅读底时用的雾面：比面板更不透，但仍带着背后的颜色。
Color glassFrostFill(BuildContext context) => context.palette.card.withValues(alpha: 0.6);

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
    if (!usesGlass(context)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: ColoredBox(color: color, child: child),
      );
    }
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

/// 布局交给组件库的 GlassAppBar：栏本身透明，只有返回和操作按钮是玻璃。
class AppBarSurface extends StatelessWidget implements PreferredSizeWidget {
  const AppBarSurface({super.key, this.title, this.leading, this.actions, this.largeTitle});
  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;

  /// 一级页面的大标题在正文里，由它带着栏内小标题一起收放；见 [AppTabPage]。
  final GlassLargeTitleController? largeTitle;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    if (!usesGlass(context)) return AppBar(title: title, leading: leading, actions: actions);
    final p = context.palette;
    final back =
        leading ??
        (largeTitle == null && Navigator.of(context).canPop()
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: GlassAppBar(
        toolbarHeight: kToolbarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        largeTitleController: largeTitle,
        leading: back == null ? null : controls([back]),
        actions: actions?.isNotEmpty == true ? [controls(actions!)] : null,
        title: title == null
            ? null
            : DefaultTextStyle(
                style: Theme.of(context).textTheme.titleMedium!
                    .copyWith(color: p.ink, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: title!,
              ),
      ),
    );
  }
}

/// 正文必须在 Scaffold 的 MediaQuery 之下构建，读取的是实际遮挡高度。
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
    this.overlay,
    this.avoidKeyboard,
  });
  final AppBarSurface? appBar;
  final WidgetBuilder body;
  final Widget? floatingActionButton;

  /// 正文是否随键盘收缩。默认只有不带悬浮按钮的页面收缩：带悬浮按钮的页面自己没有输入框，
  /// 键盘来自上面的弹窗，按钮不该被顶上去。
  final bool? avoidKeyboard;

  /// 盖在正文和边缘效果之上的定位内容，与正文共用同一套遮挡高度。
  final WidgetBuilder? overlay;

  @override
  Widget build(BuildContext context) {
    final behindBar = usesGlass(context) && appBar != null;
    return GlassBackdropGroup(
      enabled: usesGlass(context),
      joinEnclosing: true,
      child: Scaffold(
        resizeToAvoidBottomInset: avoidKeyboard ?? floatingActionButton == null,
        extendBodyBehindAppBar: behindBar,
        appBar: appBar,
        floatingActionButton: floatingActionButton,
        body: Builder(
          builder: (context) {
            if (!behindBar) return body(context);
            // 正文滚到标题栏下方时溶进纸色，不和标题、按钮叠在一起。iOS 再叠一层渐进模糊；
            // 它每帧多一次整宽的背景采样，Android 机型差异大，只保留不耗 GPU 的纸色渐隐。
            final fadeHeight = MediaQuery.paddingOf(context).top + 24;
            final page = body(context);
            final content = GlassScrollEdgeEffect(
              fadeBottom: false,
              topFadeHeight: fadeHeight,
              fadeColor: context.palette.paper,
              child: Theme.of(context).platform == TargetPlatform.iOS
                  ? GlassScrollEdgeEffect(
                      fadeBottom: false,
                      topFadeHeight: fadeHeight,
                      style: GlassScrollEdgeStyle.blur,
                      child: page,
                    )
                  : page,
            );
            return overlay == null ? content : Stack(children: [content, overlay!(context)]);
          },
        ),
      ),
    );
  }
}

/// Scaffold 已计算标题栏与安全区；不要在这里再次累加工具栏高度。
EdgeInsets pagePadding(BuildContext context, EdgeInsets padding) {
  final insets = MediaQuery.paddingOf(context);
  return padding.copyWith(
    top: padding.top + (usesGlass(context) ? insets.top : 0),
    bottom: padding.bottom + insets.bottom,
  );
}

/// 一级页面。玻璃模式下大标题与右上角操作同在标题栏这一行，正文一滚动就淡出、换成栏内居中小标题；
/// 收放进度由组件库的 GlassLargeTitleController 给出。大标题不放进正文，否则会被标题栏下的边缘效果一起模糊。
class AppTabPage extends StatefulWidget {
  const AppTabPage({
    super.key,
    required this.title,
    required this.padding,
    required this.children,
    this.actions,
    this.floatingActionButton,
    this.onRefresh,
  });
  final String title;
  final EdgeInsets padding;
  final List<Widget> children;

  /// 同一个操作的两种放法：玻璃模式放进标题栏，普通模式用悬浮按钮。
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final Future<void> Function()? onRefresh;

  @override
  State<AppTabPage> createState() => _AppTabPageState();
}

class _AppTabPageState extends State<AppTabPage> {
  // 只在玻璃模式存在：收放进度跟着滚动位置走，关掉再打开时要从头算。
  GlassLargeTitleController? _largeTitle;

  @override
  void dispose() {
    _largeTitle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = usesGlass(context);
    if (glass) {
      _largeTitle ??= GlassLargeTitleController();
    } else if (_largeTitle case final old?) {
      _largeTitle = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    final largeTitle = _largeTitle;
    return AppPage(
      appBar: AppBarSurface(title: Text(widget.title), actions: glass ? widget.actions : null, largeTitle: largeTitle),
      floatingActionButton: glass ? null : widget.floatingActionButton,
      // 一级页面没有输入框，键盘只会来自弹窗。
      avoidKeyboard: false,
      body: (context) {
        final insets = MediaQuery.paddingOf(context);
        final list = largeTitle != null
            ? CustomScrollView(
                controller: largeTitle.scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: widget.padding.copyWith(
                      top: widget.padding.top + insets.top + Space.sm,
                      bottom: widget.padding.bottom + insets.bottom,
                    ),
                    sliver: SliverList.list(children: widget.children),
                  ),
                ],
              )
            : ListView(padding: pagePadding(context, widget.padding), children: widget.children);
        final onRefresh = widget.onRefresh;
        return onRefresh == null
            ? list
            : RefreshIndicator(onRefresh: onRefresh, edgeOffset: glass ? insets.top : 0, child: list);
      },
      overlay: largeTitle == null
          ? null
          : (context) => Positioned(
              top: MediaQuery.paddingOf(context).top - kToolbarHeight,
              left: 20,
              right: 20 + 44.0 * (widget.actions?.length ?? 0) + Space.md,
              height: kToolbarHeight,
              child: IgnorePointer(
                child: ListenableBuilder(
                  listenable: largeTitle,
                  builder: (context, _) => Opacity(
                    opacity: Curves.easeIn.transform(1 - largeTitle.collapseProgress),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.palette.ink,
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
  Widget build(BuildContext context) => usesGlass(context)
      ? ListTile(
          leading: icon,
          title: title,
          subtitle: subtitle,
          onTap: onChanged == null ? null : () => onChanged!(!value),
          trailing: CupertinoSwitch(value: value, activeTrackColor: context.palette.accentFill, onChanged: onChanged),
        )
      : SwitchListTile(secondary: icon, title: title, subtitle: subtitle, value: value, onChanged: onChanged);
}
