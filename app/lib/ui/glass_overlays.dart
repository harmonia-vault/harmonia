// 弹层采用独立悬浮面板，系统对话框路由继续管理焦点与键盘避让。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';

export 'app_dialog.dart' show showAppDialog, appDialogRoute;

class _GlassDialog extends StatefulWidget {
  const _GlassDialog({this.title, this.content, this.actions});
  final Widget? title, content;
  final List<Widget>? actions;

  @override
  State<_GlassDialog> createState() => _GlassDialogState();
}

class _GlassDialogState extends State<_GlassDialog> {
  // 上游在转场结束时移除内容滤镜；保持输入子树身份，避免焦点和滚动位置重置。
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final title = widget.title, content = widget.content, actions = widget.actions;
    final p = context.palette;
    final theme = Theme.of(context);
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: p.mute),
    );
    final readableTheme = theme.copyWith(
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: glassFrostFill(context),
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(borderSide: BorderSide(color: p.accent, width: 2)),
        errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: theme.colorScheme.error)),
        focusedErrorBorder: inputBorder.copyWith(borderSide: BorderSide(color: theme.colorScheme.error, width: 2)),
        labelStyle: TextStyle(color: p.mute),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.error)
                ? theme.colorScheme.error
                : states.contains(WidgetState.focused)
                ? p.ink
                : p.mute,
          ),
        ),
        hintStyle: TextStyle(color: p.mute),
        // 辅助文字位于输入底色之外，使用正文对比度；错误边框仍保留错误色。
        counterStyle: TextStyle(color: p.ink),
        helperStyle: TextStyle(color: p.ink),
        errorStyle: TextStyle(color: p.ink),
        errorMaxLines: 4,
        helperMaxLines: 4,
        hintMaxLines: 3,
      ),
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // 尺寸与间距照系统提醒框量取：面板宽 320，文字左右缩进 30，按钮左右与底部各留 16。
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 320),
      child: AppSurface(
        color: p.card,
        radius: 36,
        panel: true,
        child: Padding(
          key: _contentKey,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: RepaintBoundary(
            child: Theme(
              data: readableTheme,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 极短视口或大字号时连标题和按钮一起滚动，避免键盘把操作挤出屏幕。
                  final scrollWhole =
                      constraints.maxHeight < 320 ||
                      (MediaQuery.textScalerOf(context).scale(14) > 20 && constraints.maxHeight < 460);
                  final body = content == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: DefaultTextStyle(
                            style: theme.textTheme.bodyMedium!.copyWith(color: p.mute, fontSize: 15, height: 20 / 15),
                            child: content,
                          ),
                        );
                  // 两个操作等宽并排，占满一行；更多操作或大字号时纵向排列，主要操作在上。
                  final sideBySide = actions?.length == 2 && MediaQuery.textScalerOf(context).scale(14) <= 18;
                  final panel = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (title != null)
                        Padding(
                          // 正文是一段文字时与系统提醒框一样紧跟标题；是输入框等控件时多留一些，
                          // 浮动标签不会顶到标题。
                          padding: EdgeInsets.fromLTRB(14, 0, 14, body == null ? 0 : (content is Text ? 6 : 16)),
                          child: DefaultTextStyle(
                            style: theme.textTheme.titleLarge!.copyWith(
                              color: p.ink,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              height: 22 / 17,
                            ),
                            child: title,
                          ),
                        ),
                      if (body != null)
                        if (scrollWhole) body else Flexible(child: SingleChildScrollView(child: body)),
                      if (actions?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 20),
                        FilledButtonTheme(
                          // 只改高度，颜色沿用全局实心按钮。
                          data: FilledButtonThemeData(
                            style: theme.filledButtonTheme.style?.copyWith(
                              minimumSize: const WidgetStatePropertyAll(Size(64, 46)),
                              textStyle: const WidgetStatePropertyAll(
                                TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          child: TextButtonTheme(
                            data: TextButtonThemeData(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(64, 46),
                                backgroundColor: p.ink.withValues(alpha: 0.1),
                                foregroundColor: p.ink,
                                textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                              ),
                            ),
                            child: sideBySide
                                ? Row(
                                    children: [
                                      Expanded(child: actions![0]),
                                      const SizedBox(width: 8),
                                      Expanded(child: actions[1]),
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      for (final (i, action) in actions!.reversed.indexed) ...[
                                        if (i > 0) const SizedBox(height: 8),
                                        action,
                                      ],
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ],
                  );
                  return scrollWhole ? SingleChildScrollView(child: panel) : panel;
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppAlertDialog extends AlertDialog {
  const AppAlertDialog({super.key, super.title, super.content, super.actions}) : super(scrollable: true);

  @override
  Widget build(BuildContext context) =>
      usesGlass(context) ? _GlassDialog(title: title, content: content, actions: actions) : super.build(context);
}

class AppSimpleDialog extends SimpleDialog {
  const AppSimpleDialog({super.key, super.title, super.children});

  @override
  Widget build(BuildContext context) => usesGlass(context)
      ? _GlassDialog(
          title: title,
          content: Column(mainAxisSize: MainAxisSize.min, children: children ?? []),
        )
      : super.build(context);
}

class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key, required this.items, required this.onSelected});
  final List<({String value, String label, IconData icon, bool danger})> items;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (!usesGlass(context)) {
      return PopupMenuButton<String>(
        onSelected: onSelected,
        itemBuilder: (_) => [for (final item in items) PopupMenuItem(value: item.value, child: Text(item.label))],
      );
    }
    return GlassMenu(
      autoAdjustToScreen: true,
      morphSpeed: MediaQuery.disableAnimationsOf(context) ? MorphSpeed.instant : MorphSpeed.fast,
      menuWidth: 240,
      menuBorderRadius: 28,
      itemBorderRadius: 20,
      menuPadding: const EdgeInsets.all(6),
      // 菜单上是文字，与弹窗用同一种面板材质，背后的标题和按钮不会透出字形。
      settings: glassPanelSettings(context, context.palette.card),
      quality: glassQuality(context),
      semanticLabel: '环境操作',
      items: [
        for (final item in items)
          GlassMenuItem(
            title: item.label,
            icon: Icon(item.icon),
            isDestructive: item.danger,
            height: 48,
            enablePressScale: !MediaQuery.disableAnimationsOf(context),
            onTap: () => onSelected(item.value),
          ),
      ],
      triggerBuilder: (context, toggle) =>
          IconButton(tooltip: '更多操作', icon: const Icon(CupertinoIcons.ellipsis), onPressed: toggle),
    );
  }
}
