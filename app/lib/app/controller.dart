// App 的唯一状态机：路由只根据 stage 决定显示哪个页面，页面自己不决定跳转。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/account.dart';
import '../core/api.dart';
import '../core/crypto.dart';
import '../core/store.dart';
import '../core/vault.dart';
import 'identity.dart';
import 'updater.dart' show UpdateChannel;

enum Stage {
  loading,
  connect, // 填写服务器地址
  signedOut, // 登录 / 注册 / 找回密码
  verifyEmail, // 注册后验证邮箱
  setPin, // 登录后设置 App PIN（可选开启指纹）
  setup, // 首次初始化：保存恢复码
  unpaired, // 已登录，本机还不是管理手机
  pairing, // 等待另一台手机批准
  locked, // App 锁
  rotation, // 恢复后必须更换恢复码
  home,
}

class Prefs {
  Prefs({this.server, this.email, this.updateChannel});
  String? server;
  String? email;
  String? updateChannel;

  Map<String, dynamic> toJson() => {'server': server, 'email': email, 'updateChannel': updateChannel};
  factory Prefs.fromJson(Map<String, dynamic> j) => Prefs(
      server: j['server'] as String?,
      email: j['email'] as String?,
      updateChannel: j['updateChannel'] as String?);
}

class AppController extends ChangeNotifier {
  AppController({
    required this.crypto,
    required this.secure,
    required this.files,
    required this.deviceName,
    required this.identity,
  })  : account = AccountService(crypto),
        vault = Vault(crypto, secure, files);

  final HCrypto crypto;
  final LocalStore secure;
  final LocalStore files;
  final String deviceName;
  final Identity identity;
  final AccountService account;
  final Vault vault;

  Stage stage = Stage.loading;
  Prefs prefs = Prefs();
  InstanceInfo? instance;
  PasswordSession? session;
  SetupDraft? setupDraft;
  /// 首次初始化已提交成功，正在显示完成页。
  bool setupCompleted = false;
  PendingPairing? pendingPairing;
  String? pendingEmail;
  String? _pendingPassword;

  /// 从登录页直接用恢复码恢复时，设置 App PIN 之前暂存的设备信息。
  LocalConfig? _pendingRecovery;

  /// 显示在登录页顶部的一次性提示（例如“这台手机已被移除”）。
  String? notice;

  /// 推送连接状态：false 时界面显示“离线”。
  bool online = false;
  int pendingPairingCount = 0;
  DateTime? _backgroundAt;
  Timer? _lockTimer;
  bool _foreground = true;
  int _pushGeneration = 0;

  static const _prefsKey = 'prefs';
  static const lockTimeout = Duration(minutes: 5);

  void _go(Stage s) {
    stage = s;
    notifyListeners();
  }

  void refresh() => notifyListeners();

  Future<void> _savePrefs() => files.write(_prefsKey, jsonEncode(prefs.toJson()));

  // ---- 启动 ----

  Future<void> start() async {
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

  /// 旧版本把设备密钥直接存在安全存储里，没有 App PIN 保护。1.0 之前不做迁移：清除后重新登录。
  Future<void> _dropOldFormat() async {
    if (await secure.read('config') == null) return;
    await secure.delete('config');
    await secure.delete('pin');
    await files.delete('cache');
    notice = 'Harmonia 更新了本机数据的保护方式，请重新登录并设置 App PIN。';
  }

  Stage _afterUnlock() => vault.cache.rotationRequired ? Stage.rotation : Stage.home;

  // ---- 服务器与账号 ----

  Future<void> connect(String server) async {
    instance = await account.instance(server);
    prefs.server = instance!.server;
    await _savePrefs();
    _go(Stage.signedOut);
  }

  Future<void> changeServer() async {
    prefs.server = null;
    instance = null;
    session = null;
    await _savePrefs();
    _go(Stage.connect);
  }

  String get server => prefs.server!;

  Future<void> login(String email, String password) async {
    final s = await account.login(server, email, password);
    prefs.email = s.email;
    await _savePrefs();
    session = s;
    notice = null;
    _go(Stage.setPin);
  }

  // ---- App PIN ----

  /// 生成本机数据密钥并用 PIN 保护。之后保存的设备密钥都用它加密。
  Future<void> setPin(String pin) async {
    vault.localKey = await identity.keyring.create(pin);
  }

  /// 设置 PIN（以及是否开启指纹）完成后，继续登录或恢复流程。
  Future<void> pinDone() async {
    final recovered = _pendingRecovery;
    if (recovered != null) {
      await vault.adopt(recovered);
      _pendingRecovery = null;
      _go(Stage.rotation);
    } else if (session!.initialized) {
      _go(Stage.unpaired);
    } else {
      setupDraft = account.prepareSetup();
      _go(Stage.setup);
    }
  }

  /// 注册；需要验证邮箱时进入验证页，否则直接登录。
  Future<void> register(String email, String password) async {
    final needVerify = await account.register(server, email, password);
    pendingEmail = email.trim();
    prefs.email = pendingEmail;
    await _savePrefs();
    _pendingPassword = password;
    if (needVerify) {
      _go(Stage.verifyEmail);
    } else {
      await _loginAfterRegister();
    }
  }

  Future<void> verifyEmail(String code) async {
    await account.verifyEmail(server, pendingEmail!, code);
    await _loginAfterRegister();
  }

  Future<void> resendVerification() => account.resendVerification(server, pendingEmail!);

  /// 登录时发现邮箱未验证：进入验证页并重新发送验证码。
  Future<void> startVerification(String email, String password) async {
    pendingEmail = email.trim();
    _pendingPassword = password;
    _go(Stage.verifyEmail);
    try {
      await resendVerification();
    } catch (_) {
      // 重发间隔未到等情况不影响进入验证页。
    }
  }

  Future<void> _loginAfterRegister() async {
    final email = pendingEmail!, password = _pendingPassword!;
    _pendingPassword = null;
    await login(email, password);
  }

  void cancelToSignIn() {
    session = null;
    setupDraft = null;
    setupCompleted = false;
    pendingPairing = null;
    _pendingPassword = null;
    _pendingRecovery = null;
    vault.localKey = null;
    _go(Stage.signedOut);
  }

  // ---- 首次初始化 ----

  /// 用户已确认抄写恢复码后提交。成功后停在完成页，由 [finishSetup] 进入主页。
  Future<void> completeSetup() async {
    final cfg = await account.completeSetup(session!, setupDraft!, deviceName);
    await vault.adopt(cfg);
    session = null;
    setupCompleted = true;
    notifyListeners();
  }

  void finishSetup() {
    setupDraft = null;
    setupCompleted = false;
    _go(Stage.home);
    _onUnlocked();
  }

  // ---- 作为新手机配对 ----

  Future<void> startPairing() async {
    pendingPairing = await account.startPairing(session!, deviceName);
    _go(Stage.pairing);
    unawaited(_pollPairing(pendingPairing!));
  }

  Future<void> _pollPairing(PendingPairing p) async {
    while (stage == Stage.pairing && identical(pendingPairing, p)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (stage != Stage.pairing || !identical(pendingPairing, p)) return;
      try {
        final cfg = await account.pollPairing(p);
        if (cfg == null) continue;
        await vault.adopt(cfg);
        pendingPairing = null;
        session = null;
        _go(Stage.home);
        _onUnlocked();
        return;
      } on VaultException catch (e) {
        pendingPairing = null;
        notice = e.message;
        _go(Stage.unpaired);
        return;
      } catch (_) {
        // 网络抖动时继续等待。
      }
    }
  }

  void cancelPairing() {
    pendingPairing = null;
    _go(session != null ? Stage.unpaired : Stage.signedOut);
  }

  // ---- 恢复 ----

  Future<void> recover(String email, String code) async {
    final cfg = await account.recover(server, email, code, deviceName);
    prefs.email = email.trim();
    await _savePrefs();
    session = null;
    if (vault.localKey == null) {
      // 从登录页直接恢复：先设置 App PIN，再保存设备密钥。
      _pendingRecovery = cfg;
      _go(Stage.setPin);
      return;
    }
    await vault.adopt(cfg);
    _go(Stage.rotation);
  }

  /// 生成新的恢复码（尚未提交）。
  Uint8List newRecoveryCode() => crypto.random(16);

  /// 正在进行的轮换编号；网络中断后可凭它查询是否已经生效。
  String? rotationKey;

  Future<void> rotateRecovery(Uint8List code, {String? newPassword}) async {
    rotationKey ??= crypto.newId();
    try {
      await vault.rotateRecovery(code, newPassword: newPassword, key: rotationKey);
    } catch (e) {
      if (!await _rotationCompleted()) rethrow;
    }
    rotationKey = null;
    notifyListeners();
  }

  /// 恢复后的强制轮换完成：离开完成页，进入主页。
  void finishRotation() {
    _go(Stage.home);
    _onUnlocked();
  }

  Future<bool> _rotationCompleted() async {
    try {
      return await vault.rotationCompleted(rotationKey!);
    } catch (_) {
      return false;
    }
  }

  // ---- App 锁 ----

  /// 用解开的本机数据密钥解锁。
  Future<void> unlock(Uint8List key) async {
    vault.localKey = key;
    await vault.load();
    _go(_afterUnlock());
    _onUnlocked();
  }

  /// 锁定：清除内存中的全部密钥，解锁后重新解开。
  void lockNow() {
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
    notice = '已清除本机数据，请重新登录。这台手机原来的设备记录，请在其他手机上移除。';
    cancelToSignIn();
  }

  UpdateChannel get updateChannel => UpdateChannel.parse(prefs.updateChannel);

  Future<void> setUpdateChannel(UpdateChannel c) async {
    prefs.updateChannel = c.name;
    await _savePrefs();
    notifyListeners();
  }

  void onLifecycle({required bool foreground}) {
    if (!foreground) {
      _foreground = false;
      _backgroundAt = DateTime.now();
      _stopPush();
      // 在后台满 5 分钟就清除内存中的密钥；进程被冻结时，回到前台再按离开时长判断。
      _lockTimer?.cancel();
      _lockTimer = Timer(lockTimeout, () {
        if (!_foreground && _lockable) lockNow();
      });
      return;
    }
    _foreground = true;
    _lockTimer?.cancel();
    final away = _backgroundAt == null ? Duration.zero : DateTime.now().difference(_backgroundAt!);
    _backgroundAt = null;
    if (away >= lockTimeout && _lockable) {
      lockNow();
      return;
    }
    if (stage == Stage.home || stage == Stage.rotation) _startPush();
  }

  // ---- 已接入后的同步与推送 ----

  void _onUnlocked() {
    unawaited(syncNow());
    _startPush();
  }

  Future<void> syncNow() async {
    try {
      await vault.sync();
      online = true;
      if (vault.isManager) {
        pendingPairingCount = (await vault.pendingPairings()).length;
      }
      if (vault.cache.rotationRequired && stage == Stage.home) stage = Stage.rotation;
    } on RevokedException {
      await _handleRevoked();
      return;
    } on ApiException catch (e) {
      if (e.isNetwork) online = false;
    } catch (_) {
      online = false;
    }
    notifyListeners();
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
        await vault.listen(() async {
          if (gen != _pushGeneration) return;
          if (vault.isManager) {
            try {
              pendingPairingCount = (await vault.pendingPairings()).length;
            } catch (_) {}
          }
          notifyListeners();
        }, () async {
          if (gen != _pushGeneration) return;
          pendingPairingCount = (await vault.pendingPairings()).length;
          notifyListeners();
        });
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
    notice = online ? null : '暂时无法连接服务器，本机数据已清除。请在其他手机上移除这台设备。';
    _go(Stage.signedOut);
    return online;
  }
}
