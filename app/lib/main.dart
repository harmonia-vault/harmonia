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
import 'app/push_device.dart';
import 'app/updater.dart';
import 'core/crypto.dart';
import 'core/account.dart';
import 'core/push.dart';
import 'core/vault.dart';
import 'ui/approval.dart';
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
    push: PushRegistrar(device: HostPushDevice(), relay: RelayClient(), store: files, platform: hostPlatform),
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
  final _seenApprovals = <String>{};
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
    _popupApproval();
    _staleNotification();
    setState(() {});
  }

  /// 在首页收到电脑的批准请求时直接打开批准页（设计文档 17.4）。App 在后台时不提醒，回到前台同步后仍在等待的
  /// 请求随即弹出。每个请求只弹一次，已有弹出的页面时不叠加，其余的留在“设备”页的待批准列表里。
  Future<void> _popupApproval() async {
    final c = widget.c;
    final nav = _navigator.currentState;
    if (c.pageDebugActive || c.stage != Stage.home || nav == null || !c.foreground) return;
    final fresh = c.approvals.where((a) => _seenApprovals.add(a.id)).toList();
    if (fresh.isEmpty || _reviewing) return;
    _reviewing = true;
    await nav.push(
      MaterialPageRoute(
        builder: (_) => ApprovalPage(c: c, request: fresh.last),
      ),
    );
    _reviewing = false;
  }

  /// 在首页收到用配对码发起的新请求时直接打开批准页（匿名请求不弹出）。每个请求只弹一次；
  /// 已有弹出的批准页时不再叠加，其余请求留在“设备”页的待批准列表里。
  Future<void> _popupPairing() async {
    final c = widget.c;
    final nav = _navigator.currentState;
    if (c.pageDebugActive || c.stage != Stage.home || nav == null) return;
    final fresh = c.authorizedPairings.where((p) => _seenPairings.add(p.id)).toList();
    if (fresh.isEmpty || _reviewing) return;
    _reviewing = true;
    await nav.push(
      MaterialPageRoute(
        builder: (_) => ReviewPairingPage(c: c, request: fresh.last, scanned: false),
      ),
    );
    _reviewing = false;
  }

  /// 点开通知进来，请求已经处理或过期（设计文档 18.4）。
  void _staleNotification() {
    final c = widget.c;
    final ctx = _navigator.currentContext;
    if (!c.staleNotification || ctx == null || c.stage != Stage.home) return;
    c.staleNotification = false;
    toast(ctx, staleNotificationText);
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
    theme: buildTheme(Brightness.light, glassOpacity: widget.c.appearance.glassOpacity),
    darkTheme: buildTheme(Brightness.dark, glassOpacity: widget.c.appearance.glassOpacity),
    builder: (context, child) => GlassOpacityPreview(
      preview: widget.c.glassOpacityPreview,
      child: AppScope(
        identity: widget.c.identity,
        child: LiquidGlassWidgets.wrap(brightnessResolver: Theme.maybeBrightnessOf, child: child!),
      ),
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
      offstage: widget.c.pageDebugCovers,
      child: KeyedSubtree(key: ValueKey(widget.c.stage), child: stagePage(widget.c)),
    ),
  );
}
