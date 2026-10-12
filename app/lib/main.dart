// Harmonia（和弦）App 入口（Android 与 iOS）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app/controller.dart';
import 'app/identity.dart';
import 'app/licenses.dart';
import 'app/platform.dart';
import 'app/updater.dart';
import 'core/crypto.dart';
import 'core/account.dart';
import 'core/vault.dart';
import 'ui/app_scope.dart';
import 'core/keyring.dart';
import 'core/phrases.dart';
import 'core/store.dart';
import 'ui/glass.dart';
import 'ui/stage_page.dart';
import 'ui/pairing.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// 安全存储：Android 上由 Keystore 包装加密，iOS 上是仅限本机的钥匙串条目。
/// 设备密钥另外用本机数据密钥加密（见 core/keyring.dart）。
class SecureStore implements LocalStore {
  final _s = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
  );
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerLicenses();
  final crypto = await HCrypto.init();
  updaterCrypto = crypto;
  phraseBreaker = PhraseBreaker.fromJson(await rootBundle.loadString('assets/budoux/zh-hans.json'));
  final secure = SecureStore();
  final identity = Identity(Keyring(crypto, secure, KeystoreKeys()));
  await identity.loadBioName();
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/harmonia');
  final files = FileStore(dir);
  final controller = AppController(
    crypto: crypto,
    secure: secure,
    files: files,
    account: AccountService(crypto, platform: hostPlatform),
    vault: Vault(crypto, secure, files),
    deviceName: await hostDeviceName(),
    platform: hostPlatform,
    identity: identity,
    prepareGlass: GlassResources.prepare,
  );
  runApp(HarmoniaApp(c: controller));
  await controller.start();
}

class HarmoniaApp extends StatefulWidget {
  const HarmoniaApp({super.key, required this.c});
  final AppController c;
  @override
  State<HarmoniaApp> createState() => _HarmoniaAppState();
}

class _HarmoniaAppState extends State<HarmoniaApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  Stage? _shownStage;
  final _seenPairings = <String>{};
  bool _reviewing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.c.addListener(_onChange);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.c.removeListener(_onChange);
    super.dispose();
  }

  /// 阶段变化时清空页面栈，只显示新阶段的根页面；同一阶段内的子页面保留。
  void _onChange() {
    if (widget.c.pageDebugActive) {
      setState(() {});
      return;
    }
    if (_shownStage != widget.c.stage) {
      _shownStage = widget.c.stage;
      _navigator.currentState?.popUntil((r) => r.isFirst);
    }
    _popupPairing();
    setState(() {});
  }

  /// 在首页收到新的配对请求时直接打开批准页。每个请求只弹一次；已有弹出的批准页时不再叠加，
  /// 其余请求留在“设备”页的待批准列表里。
  Future<void> _popupPairing() async {
    final c = widget.c;
    final nav = _navigator.currentState;
    if (c.pageDebugActive || c.stage != Stage.home || nav == null) return;
    final fresh = c.pairings.where((p) => _seenPairings.add(p.id)).toList();
    if (fresh.isEmpty || _reviewing) return;
    _reviewing = true;
    await nav.push(
      MaterialPageRoute(
        builder: (_) => ReviewPairingPage(c: c, request: fresh.last, scanned: false),
      ),
    );
    _reviewing = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        widget.c.onLifecycle(foreground: true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        widget.c.onLifecycle(foreground: false);
      default:
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Harmonia',
    debugShowCheckedModeBanner: false,
    themeMode: colorThemeMode(widget.c.appearance.colorMode),
    theme: buildTheme(
      Brightness.light,
      liquidGlass: widget.c.appearance.liquidGlass,
      glassOpacity: widget.c.appearance.glassOpacity,
    ),
    darkTheme: buildTheme(
      Brightness.dark,
      liquidGlass: widget.c.appearance.liquidGlass,
      glassOpacity: widget.c.appearance.glassOpacity,
    ),
    builder: (_, child) => AppScope(
      identity: widget.c.identity,
      child: LiquidGlassWidgets.wrap(brightnessResolver: Theme.maybeBrightnessOf, child: child!),
    ),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorKey: _navigator,
    home: Offstage(
      offstage: widget.c.pageDebugActive,
      child: KeyedSubtree(key: ValueKey(widget.c.stage), child: stagePage(widget.c)),
    ),
  );
}
