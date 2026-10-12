// 弹层采用独立悬浮面板，系统对话框路由继续管理焦点与键盘避让。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';

export 'app_dialog.dart' show showAppDialog, appDialogRoute;

class _GlassDialog extends StatelessWidget {
  const _GlassDialog({this.title, this.content, this.actions});
  final Widget? title, content;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: p.mute),
    );
    final readableTheme = theme.copyWith(
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        // 输入内容使用实色底，标签、计数和多行错误也不受背后页面颜色干扰。
        filled: true,
        fillColor: p.card,
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
        counterStyle: TextStyle(color: p.mute),
        helperStyle: TextStyle(color: p.mute),
        errorStyle: TextStyle(color: theme.colorScheme.error),
        errorMaxLines: 4,
        helperMaxLines: 4,
        hintMaxLines: 3,
      ),
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 360),
      child: AppSurface(
        color: p.card,
        radius: 32,
        tintAlpha: 0.94,
        child: Padding(
          padding: const EdgeInsets.all(24),
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
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: DefaultTextStyle(
                          style: theme.textTheme.bodyMedium!.copyWith(color: p.ink, fontSize: 15, height: 1.5),
                          child: content!,
                        ),
                      );
                final panel = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: DefaultTextStyle(
                          style: theme.textTheme.titleLarge!.copyWith(
                            color: p.ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                          textAlign: TextAlign.center,
                          child: title!,
                        ),
                      ),
                    if (body != null)
                      if (scrollWhole) body else Flexible(child: SingleChildScrollView(child: body)),
                    if (actions?.isNotEmpty ?? false) ...[
                      const SizedBox(height: 24),
                      FilledButtonTheme(
                        data: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(64, 46))),
                        child: TextButtonTheme(
                          data: TextButtonThemeData(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(64, 46),
                              backgroundColor: p.ink.withValues(alpha: 0.06),
                              foregroundColor: p.ink,
                            ),
                          ),
                          child: OverflowBar(
                            spacing: 10,
                            overflowSpacing: 8,
                            alignment: MainAxisAlignment.end,
                            overflowAlignment: OverflowBarAlignment.end,
                            children: actions!,
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
    );
  }
}

class AppAlertDialog extends AlertDialog {
  const AppAlertDialog({super.key, super.title, super.content, super.actions});

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
      settings: glassSettings(context),
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
