// 行尾统一保留 48 像素槽位；图标内边距 12 + 行尾 4，与左侧的 16 像素对齐。
import 'package:flutter/material.dart';

const listRowPadding = EdgeInsetsDirectional.fromSTEB(16, 3, 4, 3);

class ListRowChevron extends StatelessWidget {
  const ListRowChevron({super.key});

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 48, child: Center(child: Icon(Icons.chevron_right, size: 24)));
}

class ListRowActions extends StatelessWidget {
  const ListRowActions({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => IconButtonTheme(
    data: IconButtonThemeData(
      style: IconButton.styleFrom(
        fixedSize: const Size.square(48),
        padding: const EdgeInsets.all(12),
        iconSize: 24,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: children),
  );
}
