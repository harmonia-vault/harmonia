// 独立内存会话，直接在设备窗口中检查正式布局与交互。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app/debug_session.dart';
import 'core/phrases.dart';
import 'ui/app_scope.dart';
import 'ui/glass.dart';
import 'ui/navigation_shell.dart';
import 'ui/theme.dart';
import 'ui/window_layout.dart';
import 'ui/stage_page.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  phraseBreaker = PhraseBreaker.fromJson(await rootBundle.loadString('assets/budoux/zh-hans.json'));
  final session = await DebugSession.create(prepareGlass: GlassResources.prepare);
  if (const bool.fromEnvironment('PREVIEW_LONG_LIST')) await session.prepareLongVaultList();
  await GlassResources.prepare();
  final navigator = GlobalKey<NavigatorState>();
  runApp(
    AnimatedBuilder(
      animation: session.c,
      builder: (context, _) => MaterialApp(
        navigatorKey: navigator,
        debugShowCheckedModeBanner: false,
        themeMode: colorThemeMode(session.c.appearance.colorMode),
        theme: buildTheme(Brightness.light, glassOpacity: session.c.appearance.glassOpacity),
        darkTheme: buildTheme(Brightness.dark, glassOpacity: session.c.appearance.glassOpacity),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => GlassOpacityPreview(
          preview: session.c.glassOpacityPreview,
          child: AppScope(
            identity: session.c.identity,
            simulated: true,
            child: AppWindowLayout(
              navigator: navigator,
              child: LiquidGlassWidgets.wrap(
                brightnessResolver: Theme.maybeBrightnessOf,
                child: AppNavigationShell(child: child!),
              ),
            ),
          ),
        ),
        home: KeyedSubtree(key: ValueKey(session.c.stage), child: stagePage(session.c)),
      ),
    ),
  );
}
