// Harmonia（和弦）Android App 入口。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'app/controller.dart';
import 'app/identity.dart';
import 'app/updater.dart';
import 'core/crypto.dart';
import 'core/keyring.dart';
import 'core/store.dart';
import 'ui/auth_pages.dart';
import 'ui/home.dart';
import 'ui/lock.dart';
import 'ui/pin_setup.dart';
import 'ui/recovery_pages.dart';
import 'ui/theme.dart';

/// 安全存储：Android Keystore 包装加密。设备密钥另外用本机数据密钥加密（见 core/keyring.dart）。
class SecureStore implements LocalStore {
  final _s = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final crypto = await HCrypto.init();
  updaterCrypto = crypto;
  final secure = SecureStore();
  identity = Identity(Keyring(crypto, secure, KeystoreKeys()));
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/harmonia');
  final controller = AppController(
    crypto: crypto,
    secure: secure,
    files: FileStore(dir),
    deviceName: await _deviceName(),
    identity: identity,
  );
  runApp(HarmoniaApp(c: controller));
  await controller.start();
}

Future<String> _deviceName() async {
  try {
    final model = await const MethodChannel('harmonia/platform').invokeMethod<String>('deviceName');
    if (model != null && model.isNotEmpty) return model;
  } catch (_) {}
  return 'Android 手机';
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
    setState(() {});
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
