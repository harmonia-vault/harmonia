import 'dart:async';

import 'package:flutter/material.dart';

class WorkspaceEntry {
  const WorkspaceEntry({required this.tab, required this.id, required this.page});
  final int tab;
  final String id;
  final WidgetBuilder page;
}

class WorkspaceTools extends ChangeNotifier {
  Object? _owner;
  Widget? leading;
  List<Widget> actions = const [];
  void publish(Object owner, {Widget? leading, List<Widget>? actions}) {
    _owner = owner;
    this.leading = leading;
    this.actions = actions ?? const [];
    notifyListeners();
  }

  void release(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    leading = null;
    actions = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _owner = null;
    super.dispose();
  }
}

class WorkspaceScope extends InheritedWidget {
  const WorkspaceScope({
    super.key,
    required this.open,
    required this.selected,
    required this.tools,
    required super.child,
  });
  final Future<void> Function(WorkspaceEntry) open;
  final Map<int, WorkspaceEntry> selected;
  final WorkspaceTools tools;
  static WorkspaceScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
  @override
  bool updateShouldNotify(WorkspaceScope oldWidget) => selected != oldWidget.selected;
}

Future<void> openWorkspaceEntry(BuildContext context, WorkspaceEntry entry) {
  final workspace = WorkspaceScope.maybeOf(context);
  return workspace?.open(entry) ?? Navigator.of(context).push<void>(MaterialPageRoute(builder: entry.page));
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

/// 只更新侧边工具条，不重建页面或表单。
class WorkspaceToolReporter extends StatefulWidget {
  const WorkspaceToolReporter({super.key, this.leading, this.actions, required this.child});
  final Widget? leading;
  final List<Widget>? actions;
  final Widget child;
  @override
  State<WorkspaceToolReporter> createState() => _WorkspaceToolReporterState();
}

class _WorkspaceToolReporterState extends State<WorkspaceToolReporter> {
  WorkspaceTools? _tools;
  @override
  Widget build(BuildContext context) {
    final scope = WorkspaceScope.maybeOf(context), pane = WorkspacePane.maybeOf(context);
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (scope != null && pane != null && pane.active && !pane.master && current) {
      final tools = _tools = scope.tools;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          tools.publish(this, leading: widget.leading, actions: widget.actions);
        }
      });
    } else {
      final tools = _tools;
      _tools = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => tools?.release(this));
    }
    return widget.child;
  }

  @override
  void dispose() {
    final tools = _tools;
    WidgetsBinding.instance.addPostFrameCallback((_) => tools?.release(this));
    super.dispose();
  }
}
