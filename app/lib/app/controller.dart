// App 的唯一状态机：路由只根据 stage 决定显示哪个页面，页面自己不决定跳转。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/account.dart';
import '../core/appearance.dart';
import '../core/api.dart';
import '../core/crypto.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/vault.dart';
import 'identity.dart';
import 'updater.dart' show UpdateChannel;

part 'onboarding.dart';

enum Stage {
  loading,
  connect, // 填写服务器地址
  signedOut, // 登录 / 注册 / 找回密码
  verifyEmail, // 注册后验证邮箱
  setPin, // 登录后设置 App PIN（可选开启指纹）
  setup, // 首次初始化：保存恢复码
  unpaired, // 已登录，本机还不是管理设备
  pairing, // 等待管理设备批准
  locked, // App 锁
  rotation, // 恢复后必须更换恢复码
  home,
}

class Prefs {
  Prefs({this.server, this.email, this.updateChannel, this.developerOptions = false});
  String? server;
  String? email;
  String? updateChannel;

  /// 在“关于”页连点版本号 5 次打开，设置页底部才出现开发者选项。
  bool developerOptions;

  Map<String, dynamic> toJson() => {
    'server': server,
    'email': email,
    'updateChannel': updateChannel,
    'developerOptions': developerOptions,
  };
  factory Prefs.fromJson(Map<String, dynamic> j) => Prefs(
    server: j['server'] as String?,
    email: j['email'] as String?,
    updateChannel: j['updateChannel'] as String?,
    developerOptions: j['developerOptions'] == true,
  );
}

class AppController extends ChangeNotifier {
  AppController({
    required this.crypto,
    required this.secure,
    required this.files,
    required this.deviceName,
    required this.platform,
    required this.identity,
    required this.account,
    required this.vault,
    required Future<void> Function() prepareGlass,
    bool defaultLiquidGlass = false,
  }) : appearance = AppearanceSettings(files, prepareGlass: prepareGlass, defaultLiquidGlass: defaultLiquidGlass);

  final HCrypto crypto;
  final LocalStore secure;
  final LocalStore files;
  final String deviceName;

  /// 本机在协议中的平台名（`android` 或 `ios`）。
  final String platform;
  final Identity identity;
  final AccountService account;
  final Vault vault;
  final AppearanceSettings appearance;
  String? appearanceError;

  /// 调试导航覆盖真实会话时，阻止真实弹窗进入。
  bool pageDebugActive = false;

  /// 调试页已经完全盖住真实页面，真实页面可以停止绘制。进出的转场期间保持 false，否则转场里露出的是一片黑。
  bool pageDebugCovers = false;

  void beginPageDebug() {
    pageDebugActive = true;
    refresh();
  }

  void setPageDebugCovers(bool covers) {
    if (pageDebugCovers == covers) return;
    pageDebugCovers = covers;
    refresh();
  }

  void endPageDebug() {
    pageDebugActive = false;
    pageDebugCovers = false;
    refresh();
  }

  Stage stage = Stage.loading;
  Prefs prefs = Prefs();
  InstanceInfo? instance;
  PasswordSession? session;
  SetupDraft? setupDraft;

  /// 首次初始化已提交成功，正在显示完成页。
  bool setupCompleted = false;
  PendingPairing? pendingPairing;

  /// 正在进行的恢复码轮换编号；网络中断后可凭它查询是否已经生效。
  String? rotationKey;
  String? pendingEmail;

  /// 邮箱验证码绑定的流程凭证（协议 3.0）。
  String? verifyFlow;
  String? _pendingPassword;

  /// 从登录页直接用恢复码恢复时，设置 App PIN 之前暂存的设备信息。
  LocalConfig? _pendingRecovery;

  /// 显示在登录页顶部的一次性提示（例如“这台手机已被移除”）。
  String? notice;

  /// 推送连接状态：false 时界面显示“离线”。
  bool online = false;

  /// 待批准的配对请求（只有管理设备会有）。
  List<PairingRequest> pairings = [];
  int get pendingPairingCount => pairings.length;
  DateTime? _backgroundAt;
  Timer? _lockTimer;
  bool _foreground = true;
  bool get foreground => _foreground;
  int lockGeneration = 0;
  int _pushGeneration = 0;

  static const _prefsKey = 'prefs';
  static const _installedKey = 'installed';
  static const lockTimeout = Duration(minutes: 5);

  void _go(Stage s) {
    stage = s;
    notifyListeners();
  }

  void refresh() => notifyListeners();

  // 预览独立通知外观层，不触发账号状态、路由或配对提示。
  final glassOpacityPreview = ValueNotifier<double?>(null);
  bool _disposed = false;

  void previewGlassOpacity(double? value) {
    if (_disposed) return;
    if (value != null && (!value.isFinite || value < 0 || value > 1)) throw ArgumentError.value(value, 'value');
    glassOpacityPreview.value = value;
  }

  @override
  void dispose() {
    _disposed = true;
    glassOpacityPreview.dispose();
    _stopPush();
    _lockTimer?.cancel();
    pendingPairing?.cancel();
    super.dispose();
  }

  Future<void> _savePrefs() => files.write(_prefsKey, jsonEncode(prefs.toJson()));

  // ---- 启动 ----

  Future<void> start() async {
    try {
      await appearance.load();
    } catch (_) {
      appearanceError = '外观设置未能加载，请重新设置。';
    }
    await _dropLeftovers();
    final raw = await files.read(_prefsKey);
    if (raw != null) prefs = Prefs.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    await _dropOldFormat();
    if (await vault.hasAccount()) {
      _go(Stage.locked);
      return;
    }
    if (prefs.server != null) {
      try {
        instance = await account.instance(prefs.server!);
      } catch (_) {
        // 离线时仍进入登录页，提交时再报告网络错误。
      }
      _go(Stage.signedOut);
    } else {
      _go(Stage.connect);
    }
  }

  /// iOS 的钥匙串在卸载后仍然保留：数据目录里没有安装标记说明是全新安装，先清除残留，
  /// 这样卸载重装和 Android 一样视为新设备（docs/protocol.md 2.5）。
  Future<void> _dropLeftovers() async {
    if (platform != 'ios' || await files.read(_installedKey) != null) return;
    await identity.keyring.wipe();
    await vault.wipe();
    await files.write(_installedKey, '1');
  }

  /// 旧版本把设备密钥直接存在安全存储里，没有 App PIN 保护。1.0 之前不做迁移：清除后重新登录。
  Future<void> _dropOldFormat() async {
    if (await secure.read('config') == null) return;
    await secure.delete('config');
    await secure.delete('pin');
    await files.delete('cache');
    notice = 'Harmonia 更新了本机数据的保护方式，请重新登录并设置 App PIN。';
  }

  Stage _afterUnlock() => vault.cache.rotationRequired ? Stage.rotation : Stage.home;

  // ---- App 锁 ----

  /// 用解开的本机数据密钥解锁。
  Future<void> unlock(Uint8List key) async {
    if (!_foreground) return;
    final generation = lockGeneration;
    vault.localKey = key;
    final loaded = await vault.load();
    if (generation != lockGeneration) return;
    if (!_foreground || !loaded) {
      vault.lock();
      return;
    }
    _go(_afterUnlock());
    _onUnlocked();
  }

  /// 锁定：清除内存中的全部密钥，解锁后重新解开。
  void lockNow() {
    lockGeneration++;
    _lockTimer?.cancel();
    _lockTimer = null;
    _stopPush();
    vault.lock();
    _go(Stage.locked);
  }

  bool get _lockable => vault.paired && {Stage.home, Stage.rotation}.contains(stage);

  /// 忘记 PIN：清除本机数据和本机密钥，回到登录页。
  Future<void> forgetDevice() async {
    _stopPush();
    await identity.keyring.wipe();
    await vault.wipe();
    notice = '已清除本机数据，请重新登录。\n这台手机原来的设备记录，请在管理设备上移除。';
    cancelToSignIn();
  }

  UpdateChannel get updateChannel => UpdateChannel.parse(prefs.updateChannel);

  Future<void> setLiquidGlass(bool enabled) async {
    await appearance.setLiquidGlass(enabled);
    appearanceError = null;
    notifyListeners();
  }

  Future<void> setColorMode(AppColorMode mode) async {
    await appearance.setColorMode(mode);
    appearanceError = null;
    notifyListeners();
  }

  Future<void> setGlassOpacity(double opacity) async {
    await appearance.setGlassOpacity(opacity);
    appearanceError = null;
    notifyListeners();
  }

  Future<void> setDeveloperOptions(bool enabled) async {
    if (prefs.developerOptions == enabled) return;
    prefs.developerOptions = enabled;
    try {
      await _savePrefs();
    } catch (_) {
      prefs.developerOptions = !enabled;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> setUpdateChannel(UpdateChannel c) async {
    prefs.updateChannel = c.name;
    await _savePrefs();
    notifyListeners();
  }

  void onLifecycle({required bool foreground}) {
    if (!foreground) {
      _foreground = false;
      _backgroundAt ??= DateTime.now();
      _stopPush();
      // 在后台满 5 分钟就清除内存中的密钥；进程被冻结时，回到前台再按离开时长判断。
      _lockTimer ??= Timer(lockTimeout, () {
        _lockTimer = null;
        if (!_foreground && _lockable) lockNow();
      });
      notifyListeners();
      return;
    }
    _foreground = true;
    _lockTimer?.cancel();
    _lockTimer = null;
    final away = _backgroundAt == null ? Duration.zero : DateTime.now().difference(_backgroundAt!);
    _backgroundAt = null;
    if (away >= lockTimeout && _lockable) {
      lockNow();
      return;
    }
    if (stage == Stage.home || stage == Stage.rotation) _onUnlocked(); // 补上后台期间错过的变更和配对请求
    notifyListeners();
  }

  // ---- 已接入后的同步与推送 ----

  void _onUnlocked() {
    unawaited(syncNow());
    _startPush();
  }

  Future<void> syncNow() async {
    final generation = lockGeneration;
    try {
      await vault.sync();
      if (_disposed || generation != lockGeneration) return;
      online = true;
      if (vault.isManager) {
        final pending = await vault.pendingPairings();
        if (_disposed || generation != lockGeneration) return;
        pairings = pending;
      }
      if (vault.cache.rotationRequired && stage == Stage.home) stage = Stage.rotation;
    } on RevokedException {
      if (_disposed || generation != lockGeneration) return;
      await _handleRevoked();
      return;
    } on ApiException catch (e) {
      if (e.isNetwork) online = false;
    } catch (_) {
      online = false;
    }
    if (!_disposed && generation == lockGeneration) notifyListeners();
  }

  /// 统一处理操作中出现的“设备已移除”。
  Future<T> guard<T>(Future<T> Function() fn) async {
    try {
      final r = await fn();
      notifyListeners();
      return r;
    } on RevokedException {
      await _handleRevoked();
      throw VaultException('这台手机已被移除。');
    }
  }

  Future<void> _handleRevoked() async {
    _stopPush();
    await identity.keyring.wipe();
    await vault.wipe();
    notice = '这台手机已从账号中移除，本机数据已清除。';
    _go(Stage.signedOut);
  }

  void _startPush() {
    if (!vault.paired || !_foreground) return;
    final gen = ++_pushGeneration;
    unawaited(_pushLoop(gen));
  }

  void _stopPush() {
    _pushGeneration++;
    online = false;
  }

  Future<void> _pushLoop(int gen) async {
    var backoff = const Duration(seconds: 1);
    while (gen == _pushGeneration && vault.paired) {
      final connectedAt = DateTime.now();
      try {
        online = true;
        notifyListeners();
        await vault.listen(
          () async {
            if (gen != _pushGeneration) return;
            if (vault.isManager) {
              try {
                pairings = await vault.pendingPairings();
              } catch (_) {}
            }
            notifyListeners();
          },
          () async {
            if (gen != _pushGeneration) return;
            pairings = await vault.pendingPairings();
            notifyListeners();
          },
        );
      } on RevokedException {
        if (gen == _pushGeneration) await _handleRevoked();
        return;
      } catch (_) {
        // 断线后重连。
      }
      if (gen != _pushGeneration) return;
      online = false;
      notifyListeners();
      if (DateTime.now().difference(connectedAt) > const Duration(minutes: 1)) {
        backoff = const Duration(seconds: 1);
      }
      await Future<void>.delayed(backoff);
      if (backoff < const Duration(seconds: 30)) backoff *= 2;
      if (gen == _pushGeneration) await syncNow();
    }
  }

  // ---- 退出 ----

  Future<bool> logout({bool confirmLast = false}) async {
    _stopPush();
    final online = await vault.logout(confirmLast: confirmLast);
    await identity.keyring.wipe();
    notice = online ? null : '暂时无法连接服务器，本机数据已清除。\n请在管理设备上移除这台手机。';
    _go(Stage.signedOut);
    return online;
  }
}
