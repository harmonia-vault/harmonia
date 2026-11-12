import 'dart:async';

import 'package:flutter/material.dart';

class WorkspaceEntry {
  const WorkspaceEntry({required this.tab, required this.id, required this.page});
  final int tab;
  final String id;
  final WidgetBuilder page;
}

class WorkspaceScope extends InheritedWidget {
  const WorkspaceScope({
    super.key,
    required this.open,
    required this.select,
    required this.selected,
    required this.openEditor,
    required super.child,
  });
  final Future<void> Function(WorkspaceEntry) open, select;
  final Map<int, WorkspaceEntry> selected;
  final Future<T?> Function<T>(WidgetBuilder) openEditor;
  static WorkspaceScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
  @override
  bool updateShouldNotify(WorkspaceScope oldWidget) => selected != oldWidget.selected;
}

Future<void> openWorkspaceEntry(BuildContext context, WorkspaceEntry entry) {
  final workspace = WorkspaceScope.maybeOf(context);
  return workspace?.open(entry) ?? Navigator.of(context).push<void>(MaterialPageRoute(builder: entry.page));
}

/// 一级列表选择会更换当前栏的起点；正文中的引用使用 openWorkspaceEntry 逐层进入。
Future<void> selectWorkspaceEntry(BuildContext context, WorkspaceEntry entry) {
  final workspace = WorkspaceScope.maybeOf(context);
  return workspace?.select(entry) ?? Navigator.of(context).push<void>(MaterialPageRoute(builder: entry.page));
}

class WorkspacePane extends InheritedWidget {
  const WorkspacePane({
    super.key,
    required this.master,
    required this.active,
    required this.navigationHeight,
    required super.child,
  });
  final bool master, active;
  final double navigationHeight;
  static WorkspacePane? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<WorkspacePane>();
  @override
  bool updateShouldNotify(WorkspacePane oldWidget) =>
      master != oldWidget.master || active != oldWidget.active || navigationHeight != oldWidget.navigationHeight;
}
