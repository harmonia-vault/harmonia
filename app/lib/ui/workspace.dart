import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app/controller.dart';
import 'adaptive_navigation.dart';
import 'devices.dart';
import 'environments.dart';
import 'env_page.dart';
import 'glass.dart';
import 'navigation_shell.dart';
import 'settings.dart';
import 'theme.dart';
import 'vaults.dart';
import 'vaults_tab.dart';
import 'window_layout.dart';
import 'workspace_scope.dart';
import 'workspace_empty.dart';
import 'workspace_detail.dart';

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.c, this.initialEntry, this.initialTab = 0});
  final AppController c;
  final WorkspaceEntry? initialEntry;
  final int initialTab;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspacePage {
  _WorkspacePage.editor(this.page) : editing = true;
  _WorkspacePage.detail(WorkspaceEntry entry) : page = entry.page, editing = false;
  final WidgetBuilder page;
  final bool editing;
  final key = UniqueKey();
  final closed = Completer<Object?>();
  Object? result;
}

class _WorkspaceState extends State<Workspace> {
  final _navigators = List.generate(4, (_) => GlobalKey<NavigatorState>());
  final _heroes = List.generate(4, (_) => HeroController());
  final _masterKeys = List.generate(3, (_) => GlobalKey());
  final _selected = <int, WorkspaceEntry>{};
  final _waiting = <int, Completer<void>>{};
  final _pages = <int, List<_WorkspacePage>>{};
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    if (widget.initialEntry case final entry?) {
      _tab = entry.tab;
      _selected[entry.tab] = entry;
      _waiting[entry.tab] = Completer<void>();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSelections();
  }

  @override
  void didUpdateWidget(Workspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSelections();
  }

  void _syncSelections() {
    final c = widget.c;
    final wide = WindowLayoutScope.maybeOf(context)!.twoPanes;
    final entries = [
      [
        for (final v in c.vault.vaults)
          WorkspaceEntry(
            tab: 0,
            id: 'vault:${v.id}',
            page: (_) => VaultPage(c: c, vaultId: v.id),
          ),
      ],
      [
        for (final e in c.vault.environments)
          WorkspaceEntry(
            tab: 1,
            id: 'env:${e.id}',
            page: (_) => EnvironmentPage(c: c, envId: e.id),
          ),
      ],
      [
        for (final manager in [true, false])
          for (final d in c.vault.devices.where((d) => d.isManager == manager))
            WorkspaceEntry(
              tab: 2,
              id: 'device:${d.id}',
              page: (_) => DevicePage(c: c, deviceId: d.id),
            ),
      ],
    ];
    for (final (tab, choices) in entries.indexed) {
      final current = _selected[tab];
      if (current != null && choices.any((entry) => entry.id == current.id)) continue;
      _selected.remove(tab);
      _waiting.remove(tab)?.complete();
      if (wide && choices.isNotEmpty) {
        _selected[tab] = choices.first;
        _waiting[tab] = Completer<void>();
      }
    }
  }

  Future<void> _select(WorkspaceEntry entry) {
    for (final editor in _pages.remove(entry.tab) ?? const <_WorkspacePage>[]) {
      editor.closed.complete();
    }
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

  Future<void> _open(WorkspaceEntry entry) {
    final page = _WorkspacePage.detail(entry);
    setState(() => _pages.putIfAbsent(_tab, () => []).add(page));
    return page.closed.future;
  }

  Future<T?> _openEditor<T>(WidgetBuilder builder) {
    final page = _WorkspacePage.editor(builder);
    setState(() => _pages.putIfAbsent(_tab, () => []).add(page));
    return page.closed.future.then((value) => value as T?);
  }

  void _showSettings() => _navigators[3].currentState!.popUntil((route) => route.isFirst);

  void _removed(int tab, Page<Object?> page) {
    final editor = _pages[tab]?.where((editor) => editor.key == page.key).firstOrNull;
    if (editor != null) {
      setState(() => _pages[tab]!.remove(editor));
      editor.closed.complete(editor.result);
      return;
    }
    final entry = _selected[tab];
    // ValueKey 的泛型也参与比较，必须与详情页的 ValueKey<String> 一致。
    if (entry == null || page.key != ValueKey(entry.id)) return;
    setState(() => _selected.remove(tab));
    _waiting.remove(tab)?.complete();
  }

  @override
  void dispose() {
    for (final editor in _pages.values.expand((editors) => editors)) {
      editor.closed.complete();
    }
    for (final waiting in _waiting.values) {
      waiting.complete();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = WindowLayoutScope.maybeOf(context)!;
    final c = widget.c;
    final masterPages = [
      VaultsTab(key: _masterKeys[0], c: c),
      EnvironmentsTab(key: _masterKeys[1], c: c),
      DevicesTab(key: _masterKeys[2], c: c),
      SettingsSidebar(onSelected: _showSettings),
    ];
    final twoPanes = layout.twoPanes;
    final withNavigation = layout.twoPanes || (_pages[_tab]?.lastOrNull?.editing != true);
    final navigationHeight = layout.verticalNavigation || !withNavigation
        ? 0.0
        : 84.0 + (MediaQuery.textScalerOf(context).scale(11) - 11).clamp(0.0, 40.0);
    return WorkspaceScope(
      open: _open,
      select: _select,
      selected: Map.of(_selected),
      openEditor: _openEditor,
      // 工具栏留在工作区内，根导航器的弹窗覆盖在它上方，不切换底层栏的布局。
      child: AppNavigationShell(
        child: GlassBackdropGroup(
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Stack(
              children: [
                _pane(
                  context,
                  layout: layout,
                  bounds: layout.twoPanes ? layout.master : layoutRect(0, 0, layout.width, layout.height),
                  visible: twoPanes,
                  // 列表在单栏导航栈与双栏左侧之间移动时保留滚动状态。
                  child: layout.twoPanes
                      ? IndexedStack(
                          index: _tab,
                          children: [
                            for (var i = 0; i < 4; i++)
                              WorkspacePane(
                                master: true,
                                active: i == _tab,

                                navigationHeight: navigationHeight,
                                child: TickerMode(enabled: i == _tab, child: masterPages[i]),
                              ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                _pane(
                  context,
                  layout: layout,
                  bounds: twoPanes ? layout.detail : layoutRect(0, 0, layout.width, layout.height),
                  // 导航器持续显示，让框架完成按钮返回和交互式返回的转场。
                  visible: true,
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      for (var i = 0; i < 4; i++)
                        WorkspacePane(
                          master: false,
                          active: i == _tab,

                          navigationHeight: navigationHeight,
                          child: TickerMode(
                            enabled: i == _tab,
                            child: HeroControllerScope(
                              controller: _heroes[i],
                              child: NavigatorPopHandler<Object?>(
                                enabled: i == _tab && (!layout.twoPanes || i == 3 || (_pages[i]?.isNotEmpty ?? false)),
                                onPopWithResult: (value) => _navigators[i].currentState!.maybePop(value),
                                child: Navigator(
                                  key: _navigators[i],
                                  pages: [
                                    if (i == 3)
                                      MaterialPage(
                                        key: const ValueKey('settings'),
                                        child: SettingsTab(c: c),
                                      )
                                    else
                                      MaterialPage(
                                        key: ValueKey('root-$i'),
                                        child: Builder(
                                          builder: (context) => WindowLayoutScope.maybeOf(context)!.twoPanes
                                              ? WorkspaceEmpty(tab: i)
                                              : masterPages[i],
                                        ),
                                      ),
                                    if (_selected[i] case final entry?)
                                      WorkspaceDetailPage(
                                        key: ValueKey(entry.id),
                                        selection: true,
                                        canPop: !layout.twoPanes,
                                        child: Builder(builder: entry.page),
                                      ),
                                    // 编辑页使用稳定的页面身份，切换单栏、双栏时不丢失表单。
                                    for (final editor in _pages[i] ?? const <_WorkspacePage>[])
                                      WorkspaceDetailPage<Object?>(
                                        key: editor.key,
                                        onPopInvoked: (didPop, result) {
                                          if (didPop) editor.result = result;
                                        },
                                        child: Builder(builder: editor.page),
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
                if (withNavigation)
                  Positioned.fill(
                    child: AdaptiveNavigation(
                      selected: _tab,
                      badge: c.pendingPairingCount,
                      onSelected: (tab) => setState(() => _tab = tab),
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
