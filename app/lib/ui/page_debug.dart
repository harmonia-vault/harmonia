// 正式版本中的页面调试入口；使用独立导航器和内存会话。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app/controller.dart';
import '../app/debug_session.dart';
import '../core/debug_vault.dart';
import '../core/appearance.dart';
import 'app_scope.dart';
import 'glass.dart';
import 'page_debug_catalog.dart';
import 'stage_page.dart';
import 'theme.dart';

class PageDebug extends StatefulWidget {
  const PageDebug({super.key, this.initialGlass = false, this.initialColorMode = AppColorMode.system});
  final bool initialGlass;
  final AppColorMode initialColorMode;
  @override
  State<PageDebug> createState() => _PageDebugState();
}

class _PageDebugState extends State<PageDebug> {
  final _navigator = GlobalKey<NavigatorState>();
  DebugSession? _session;
  String? _error;
  int _navigationGeneration = 0;
  bool _large = false, _contrast = false, _reduceMotion = false, _pageActive = false;
  Stage _lastStage = Stage.home;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final session = await DebugSession.create(prepareGlass: GlassResources.prepare);
      if (!mounted) {
        session.dispose();
        return;
      }
      await session.c.setLiquidGlass(widget.initialGlass);
      await session.c.setColorMode(widget.initialColorMode);
      if (!mounted) {
        session.dispose();
        return;
      }
      session.c.addListener(_changed);
      setState(() => _session = session);
    } catch (_) {
      if (mounted) setState(() => _error = '页面调试未能打开，请返回后重试。');
    }
  }

  @override
  void dispose() {
    _session?.c.removeListener(_changed);
    _session?.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final stage = _session!.c.stage;
    if (_pageActive && stage != _lastStage) {
      _lastStage = stage;
      final generation = ++_navigationGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _navigationGeneration) return;
        _catalog(cancelFlow: false);
        _push(() => stagePage(_session!.c));
      });
    }
    setState(() {});
  }

  void _catalog({bool cancelFlow = true}) {
    _navigationGeneration++;
    _pageActive = false;
    if (cancelFlow) _session?.cancelPendingFlow();
    _navigator.currentState?.popUntil((route) => route.isFirst);
  }

  void _push(Widget Function() page) {
    _pageActive = true;
    _lastStage = _session!.c.stage;
    final openingStage = _lastStage;
    final generation = _navigationGeneration;
    _navigator.currentState!
        .push(
          MaterialPageRoute<void>(
            builder: (_) => AnimatedBuilder(
              animation: _session!.c,
              builder: (_, _) => _session!.c.stage == openingStage && generation == _navigationGeneration
                  ? page()
                  : const SizedBox.shrink(),
            ),
          ),
        )
        .whenComplete(() {
          if (mounted && !(_navigator.currentState?.canPop() ?? false)) {
            _pageActive = false;
            _session?.cancelPendingFlow();
          }
        });
  }

  Future<void> _open(DebugPageEntry entry) async {
    _pageActive = false;
    _error = null;
    try {
      await entry.prepare?.call(_session!);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return;
    }
    if (!mounted) return;
    _session!.c.stage = entry.stage;
    _push(() => entry.page(_session!));
  }

  void _reset(DebugScenario scenario) {
    _catalog();
    _error = null;
    _session!.reset(scenario: scenario);
    _lastStage = _session!.c.stage;
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('页面调试')),
        body: Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!)),
      );
    }
    return MaterialApp(
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, liquidGlass: session.c.appearance.liquidGlass),
      darkTheme: buildTheme(Brightness.dark, liquidGlass: session.c.appearance.liquidGlass),
      themeMode: colorThemeMode(session.c.appearance.colorMode),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (innerContext, child) => AppScope(
        identity: session.c.identity,
        simulated: true,
        child: MediaQuery(
          data: MediaQuery.of(innerContext).copyWith(
            textScaler: TextScaler.linear(_large ? 1.6 : 1),
            highContrast: _contrast,
            disableAnimations: _reduceMotion,
          ),
          child: LiquidGlassWidgets.wrap(
            brightnessResolver: Theme.maybeBrightnessOf,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('页面调试 · 模拟数据', style: TextStyle(fontSize: 16)),
                leading: IconButton(
                  tooltip: '退出调试',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
                actions: [
                  IconButton(tooltip: '返回目录', icon: const Icon(Icons.grid_view), onPressed: _catalog),
                  IconButton(
                    tooltip: '重置示例',
                    icon: const Icon(Icons.restart_alt),
                    onPressed: () => _reset(DebugScenario.normal),
                  ),
                ],
              ),
              body: child,
            ),
          ),
        ),
      ),
      home: DebugCatalog(
        session: session,
        error: _error,
        onOpen: _open,
        options: [
          SwitchListTile(
            title: const Text('液态玻璃'),
            value: session.c.appearance.liquidGlass,
            onChanged: (v) async {
              try {
                await session.c.setLiquidGlass(v);
              } catch (_) {
                if (mounted) setState(() => _error = '外观未能切换，请重试。');
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: DropdownButtonFormField<AppColorMode>(
              key: ValueKey(session.c.appearance.colorMode),
              initialValue: session.c.appearance.colorMode,
              decoration: const InputDecoration(labelText: '颜色模式'),
              items: [
                for (final mode in AppColorMode.values)
                  DropdownMenuItem(value: mode, child: Text(colorModeLabel(mode))),
              ],
              onChanged: (mode) {
                if (mode != null) session.c.setColorMode(mode);
              },
            ),
          ),
          SwitchListTile(title: const Text('大字号'), value: _large, onChanged: (v) => setState(() => _large = v)),
          SwitchListTile(title: const Text('高对比度'), value: _contrast, onChanged: (v) => setState(() => _contrast = v)),
          SwitchListTile(
            title: const Text('减少动态效果'),
            value: _reduceMotion,
            onChanged: (v) => setState(() => _reduceMotion = v),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: DropdownButtonFormField<DebugScenario>(
              key: ValueKey(session.vault.scenario),
              initialValue: session.vault.scenario,
              decoration: const InputDecoration(labelText: '模拟场景'),
              items: const [
                DropdownMenuItem(value: DebugScenario.normal, child: Text('正常数据')),
                DropdownMenuItem(value: DebugScenario.empty, child: Text('空数据')),
                DropdownMenuItem(value: DebugScenario.offline, child: Text('离线')),
                DropdownMenuItem(value: DebugScenario.failure, child: Text('操作失败')),
              ],
              onChanged: (v) {
                if (v != null) _reset(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
