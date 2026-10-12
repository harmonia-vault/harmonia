// Harmonia（和弦）App 入口（Android 与 iOS）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'app/controller.dart';
import 'app/identity.dart';
import 'app/licenses.dart';
import 'app/platform.dart';
import 'app/updater.dart';
import 'core/crypto.dart';
import 'core/keyring.dart';
import 'core/phrases.dart';
import 'core/store.dart';
import 'ui/auth_pages.dart';
import 'ui/home.dart';
import 'ui/lock.dart';
import 'ui/pairing.dart';
import 'ui/pin_setup.dart';
import 'ui/recovery_pages.dart';
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
  identity = Identity(Keyring(crypto, secure, KeystoreKeys()));
  await identity.loadBioName();
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/harmonia');
  final controller = AppController(
    crypto: crypto,
    secure: secure,
    files: FileStore(dir),
    deviceName: await hostDeviceName(),
    platform: hostPlatform,
    identity: identity,
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
    if (c.stage != Stage.home || nav == null) return;
    final fresh = c.pairings.where((p) => _seenPairings.add(p.id)).toList();
    if (fresh.isEmpty || _reviewing) return;
    _reviewing = true;
    await nav.push(MaterialPageRoute(builder: (_) => ReviewPairingPage(c: c, request: fresh.last, scanned: false)));
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

  Widget _root() {
    final c = widget.c;
    return switch (c.stage) {
      Stage.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      Stage.connect => ConnectPage(c: c),
      Stage.signedOut => SignInPage(c: c),
      Stage.verifyEmail => VerifyEmailPage(c: c),
      Stage.setPin => SetPinPage(c: c),
      Stage.setup => SetupPage(c: c),
      Stage.unpaired => UnpairedPage(c: c),
      Stage.pairing => PairingWaitPage(c: c),
      Stage.locked => LockPage(c: c),
      Stage.rotation => RotationPage(c: c, forced: true),
      Stage.home => HomePage(c: c),
    };
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Harmonia',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        navigatorKey: _navigator,
        home: KeyedSubtree(key: ValueKey(widget.c.stage), child: _root()),
      );
}
