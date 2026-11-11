// 表单控件统一使用玻璃菜单、玻璃分段控件与 Cupertino 开关、勾选框。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass.dart';
import 'glass_overlays.dart';
import 'theme.dart';
import 'window_layout.dart';

typedef AppOption<T> = ({T value, String label});

/// 从几项中选一项，例如授权的有效期。放在行内作次要选项：触发处是不带底色的次要文字加箭头，
/// 不与同一行的主要控件抢视觉；玻璃布局下点按后展开玻璃菜单，当前项带对勾。
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
    final p = context.palette;
    final current = options.firstWhere((o) => o.value == value, orElse: () => options.first).label;
    Widget trigger(VoidCallback toggle) => TextButton(
      onPressed: toggle,
      style: TextButton.styleFrom(
        foregroundColor: p.mute,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(current),
          const SizedBox(width: 4),
          const Icon(CupertinoIcons.chevron_up_chevron_down, size: 13),
        ],
      ),
    );
    if (WindowLayoutScope.maybeOf(context)?.fold != null) {
      return trigger(() async {
        final selected = await showAppDialog<T>(
          context: context,
          builder: (context) => AppSimpleDialog(
            title: Text(semanticLabel),
            children: [
              for (final option in options)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, option.value),
                  child: Row(
                    children: [
                      Expanded(child: Text(option.label)),
                      if (option.value == value) const Icon(CupertinoIcons.checkmark, size: 18),
                    ],
                  ),
                ),
            ],
          ),
        );
        if (context.mounted && selected != null) onChanged(selected);
      });
    }
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
      triggerBuilder: (context, toggle) => trigger(toggle),
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
  Widget build(BuildContext context) =>
      CupertinoSwitch(value: value, activeTrackColor: context.palette.accentFill, onChanged: onChanged);
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
