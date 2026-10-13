// 表单控件随液态玻璃开关切换：玻璃布局下选择菜单用组件库的玻璃菜单，分段用玻璃分段控件，
// 开关和勾选框用 Cupertino 样式并统一填充色；普通布局沿用 Material 控件。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'theme.dart';

typedef AppOption<T> = ({T value, String label});

/// 从几项中选一项，例如授权的有效期。玻璃布局下点按后展开玻璃菜单，当前项带对勾。
class AppSelect<T> extends StatelessWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.semanticLabel,
  });
  final T value;
  final List<AppOption<T>> options;
  final ValueChanged<T> onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (!usesGlass(context)) {
      return DropdownButton<T>(
        value: value,
        isDense: true,
        items: [for (final o in options) DropdownMenuItem(value: o.value, child: Text(o.label))],
        onChanged: (v) => onChanged(v as T),
      );
    }
    final p = context.palette;
    final current = options.firstWhere((o) => o.value == value, orElse: () => options.first).label;
    return GlassMenu(
      autoAdjustToScreen: true,
      morphSpeed: MediaQuery.disableAnimationsOf(context) ? MorphSpeed.instant : MorphSpeed.fast,
      menuWidth: 200,
      menuBorderRadius: 24,
      itemBorderRadius: 18,
      menuPadding: const EdgeInsets.all(6),
      // 与弹窗、浮动菜单用同一种面板材质，背后的文字不会透出字形。
      settings: glassPanelSettings(context, p.card),
      quality: glassQuality(context),
      semanticLabel: semanticLabel,
      items: [
        for (final o in options)
          GlassMenuItem(
            title: o.label,
            trailing: o.value == value ? Icon(CupertinoIcons.checkmark, size: 18, color: p.accent) : null,
            height: 44,
            enablePressScale: !MediaQuery.disableAnimationsOf(context),
            onTap: () => onChanged(o.value),
          ),
      ],
      triggerBuilder: (context, toggle) => TextButton(
        onPressed: toggle,
        style: TextButton.styleFrom(
          foregroundColor: p.ink,
          backgroundColor: p.ink.withValues(alpha: 0.08),
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current),
            const SizedBox(width: 6),
            const Icon(CupertinoIcons.chevron_up_chevron_down, size: 14),
          ],
        ),
      ),
    );
  }
}

/// 并排的几个选项，例如环境权限。玻璃布局下是带玻璃滑块的分段控件。
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<AppOption<T>> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!usesGlass(context)) {
      return SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [for (final o in options) ButtonSegment(value: o.value, label: Text(o.label))],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      );
    }
    final p = context.palette;
    return GlassSegmentedControl(
      useOwnLayer: true,
      quality: glassQuality(context),
      settings: glassSettings(context),
      height: 36,
      segments: [for (final o in options) GlassSegment(label: o.label)],
      selectedIndex: options.indexWhere((o) => o.value == value),
      onSegmentSelected: (i) => onChanged(options[i].value),
      backgroundColor: p.ink.withValues(alpha: 0.08),
      selectedTextStyle: TextStyle(color: p.ink, fontSize: 14, fontWeight: FontWeight.w600),
      unselectedTextStyle: TextStyle(color: p.mute, fontSize: 14, fontWeight: FontWeight.w500),
    );
  }
}

/// 开关。玻璃布局下用 Cupertino 开关，填充色与实心按钮相同。
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => usesGlass(context)
      ? CupertinoSwitch(value: value, activeTrackColor: context.palette.accentFill, onChanged: onChanged)
      : Switch(value: value, onChanged: onChanged);
}

/// 带勾选框的一行。玻璃布局下用 Cupertino 勾选框，填充色与开关相同；勾选框默认在行首。
class AppCheckboxTile extends StatelessWidget {
  const AppCheckboxTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.secondary,
    this.leadingCheckbox = true,
    this.contentPadding,
  });
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget title;
  final Widget? subtitle, secondary;
  final bool leadingCheckbox;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    if (!usesGlass(context)) {
      return CheckboxListTile(
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        controlAffinity: leadingCheckbox ? ListTileControlAffinity.leading : ListTileControlAffinity.trailing,
        contentPadding: contentPadding,
        secondary: secondary,
        title: title,
        subtitle: subtitle,
      );
    }
    final box = CupertinoCheckbox(
      value: value,
      activeColor: context.palette.accentFill,
      onChanged: (v) => onChanged(v ?? false),
    );
    return ListTile(
      contentPadding: contentPadding,
      leading: leadingCheckbox ? box : secondary,
      trailing: leadingCheckbox ? secondary : box,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
    );
  }
}
