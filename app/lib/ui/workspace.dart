import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app/controller.dart';
import 'adaptive_navigation.dart';
import 'adaptive_tools.dart';
import 'devices.dart';
import 'environments.dart';
import 'glass.dart';
import 'settings_categories.dart';
import 'theme.dart';
import 'vaults_tab.dart';
import 'window_layout.dart';
import 'workspace_scope.dart';
import 'workspace_empty.dart';

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.c, this.initialEntry});
  final AppController c;
  final WorkspaceEntry? initialEntry;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final _navigators = List.generate(4, (_) => GlobalKey<NavigatorState>());
  final _heroes = List.generate(4, (_) => HeroController());
  final _selected = <int, WorkspaceEntry>{};
  final _waiting = <int, Completer<void>>{};
  final _tools = WorkspaceTools();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialEntry case final entry?) {
      _tab = entry.tab;
      _selected[entry.tab] = entry;
      _waiting[entry.tab] = Completer<void>();
    }
  }

  Future<void> _open(WorkspaceEntry entry) {
    if (_selected[entry.tab]?.id == entry.id) {
      setState(() => _tab = entry.tab);
      return _waiting[entry.tab]!.future;
    }
    _waiting.remove(entry.tab)?.complete();
    final closed = _waiting[entry.tab] = Completer<void>();
    setState(() {
      _selected[entry.tab] = entry;
      _tab = entry.tab;
    });
    return closed.future;
  }

  void _removed(int tab, Page<Object?> page) {
    if (page.key != ValueKey(_selected[tab]?.id)) return;
    setState(() => _selected.remove(tab));
    _waiting.remove(tab)?.complete();
  }

  @override
  void dispose() {
    for (final waiting in _waiting.values) {
      waiting.complete();
    }
    _tools.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = WindowLayoutScope.maybeOf(context)!;
    final c = widget.c;
    final masterPages = [VaultsTab(c: c), EnvironmentsTab(c: c), DevicesTab(c: c), SettingsCategories(c: c)];
    final navigationHeight = layout.verticalNavigation
        ? 0.0
        : 84.0 + (MediaQuery.textScalerOf(context).scale(11) - 11).clamp(0.0, 40.0);
    final showDetail = _selected.containsKey(_tab);
    final showMaster = layout.twoPanes || !showDetail;
    return WorkspaceScope(
      open: _open,
      selected: Map.of(_selected),
      tools: _tools,
      child: GlassBackdropGroup(
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              _pane(
                context,
                layout: layout,
                bounds: layout.twoPanes ? layout.master : layoutRect(0, 0, layout.width, layout.height),
                visible: showMaster,
                child: Column(
                  children: [
                    Expanded(
                      child: IndexedStack(
                        index: _tab,
                        children: [
                          for (var i = 0; i < 4; i++)
                            WorkspacePane(
                              master: layout.twoPanes,
                              active: i == _tab && showMaster,

                              navigationHeight: navigationHeight,
                              child: TickerMode(enabled: i == _tab, child: masterPages[i]),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _pane(
                context,
                layout: layout,
                bounds: layout.detail,
                visible: layout.twoPanes || showDetail,
                child: IndexedStack(
                  index: _tab,
                  children: [
                    for (var i = 0; i < 4; i++)
                      WorkspacePane(
                        master: false,
                        active: i == _tab && (layout.twoPanes || showDetail),

                        navigationHeight: navigationHeight,
                        child: TickerMode(
                          enabled: i == _tab,
                          child: HeroControllerScope(
                            controller: _heroes[i],
                            child: NavigatorPopHandler<Object?>(
                              enabled: i == _tab && showDetail,
                              onPopWithResult: (value) => _navigators[i].currentState!.pop(value),
                              child: Navigator(
                                key: _navigators[i],
                                pages: [
                                  MaterialPage(
                                    key: ValueKey('empty-$i'),
                                    child: WorkspaceEmpty(tab: i),
                                  ),
                                  if (_selected[i] case final entry?)
                                    MaterialPage(
                                      key: ValueKey(entry.id),
                                      child: Builder(builder: entry.page),
                                    ),
                                ],
                                onDidRemovePage: (page) => _removed(i, page),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned.fill(
                child: AdaptiveNavigation(
                  selected: _tab,
                  badge: c.pendingPairingCount,
                  onSelected: (tab) => setState(() => _tab = tab),
                ),
              ),
              if (layout.verticalNavigation)
                Positioned.fill(
                  child: ListenableBuilder(
                    listenable: _tools,
                    builder: (context, _) => AdaptiveTools(
                      layout: layout,
                      withNavigation: true,
                      tools: [?_tools.leading, ..._tools.actions],
                    ),
                  ),
                ),
              if (!c.online)
                Positioned(
                  left: math.max(layout.insets.left, layout.navigation == NavigationEdge.left ? 84 : 0) + 16,
                  right: math.max(layout.insets.right, layout.navigation == NavigationEdge.right ? 84 : 0) + 16,
                  bottom: layout.insets.bottom + navigationHeight + 8,
                  child: IgnorePointer(
                    child: AppSurface(
                      color: context.palette.warnBox,
                      radius: 24,
                      panel: true,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '离线，显示上次同步的数据，修改需要联网',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.palette.onWarnBox),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pane(
    BuildContext context, {
    required WindowLayout layout,
    required LayoutRect bounds,
    required bool visible,
    required Widget child,
  }) {
    final media = MediaQuery.of(context);
    final full = Rect.fromLTWH(0, 0, layout.width, layout.height);
    final rect = flutterRect(bounds);
    EdgeInsets local(EdgeInsets insets) => EdgeInsets.fromLTRB(
      rect.left == 0 ? math.max(insets.left, layout.navigation == NavigationEdge.left ? 84 : 0) : 0,
      rect.top == 0 ? math.max(insets.top, layout.verticalNavigation ? 12 : 0) : 0,
      rect.right == full.right ? math.max(insets.right, layout.navigation == NavigationEdge.right ? 84 : 0) : 0,
      rect.bottom == full.bottom ? math.max(insets.bottom, layout.verticalNavigation ? 12 : 0) : 0,
    );
    return AnimatedLayoutRegion(
      viewport: full.size,
      rect: rect,
      builder: (context, frame) => Offstage(
        offstage: !visible,
        child: MediaQuery(
          data: media.copyWith(size: frame.size, padding: local(media.padding), viewPadding: local(media.viewPadding)),
          child: child,
        ),
      ),
    );
  }
}
