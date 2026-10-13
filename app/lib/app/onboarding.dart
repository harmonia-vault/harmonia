// 本机接入账号之前的流程：连接服务器、输入邮箱（注册或接入）、App PIN、首次初始化、作为新手机配对、用恢复码恢复。
part of 'controller.dart';

extension Onboarding on AppController {
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

  /// 匿名查询账号；邮箱还没有注册时返回 null。
  Future<AccountSession?> findAccount(String email) => account.lookup(server, email);

  /// 账号已确定（已初始化的账号，或刚拿到注册会话）：接下来设置 App PIN。
  Future<void> useAccount(AccountSession s) async {
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

  /// 设置 PIN（以及是否开启指纹）完成后，继续接入或恢复流程。
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

  /// 注册（未初始化的账号按新注册处理）；需要验证邮箱时进入验证页，否则直接设置 App PIN。
  Future<void> register(String email) async {
    final r = await account.register(server, email);
    pendingEmail = email.trim().toLowerCase();
    prefs.email = pendingEmail;
    await _savePrefs();
    if (r.flow != null) {
      verifyFlow = r.flow;
      _go(Stage.verifyEmail);
    } else {
      await useAccount(r.session!);
    }
  }

  Future<void> verifyEmail(String code) async {
    final flow = verifyFlow;
    if (flow == null) throw ApiException(0, 'invalid', '验证码已失效，请点“重新发送验证码”。');
    final s = await account.verifyEmail(server, pendingEmail!, flow, code);
    verifyFlow = null;
    await useAccount(s);
  }

  Future<void> resendVerification() async => verifyFlow = await account.resendVerification(server, pendingEmail!);

  void cancelToSignIn() {
    session = null;
    setupDraft = null;
    setupCompleted = false;
    pendingPairing = null;
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
    refresh();
  }

  void finishSetup() {
    setupDraft = null;
    setupCompleted = false;
    _go(Stage.home);
    _onUnlocked();
  }

  // ---- 作为新手机配对 ----

  /// 发起配对；连上等待连接后才显示二维码，避免对方扫到一个还不能批准的请求。
  /// [code] 是管理设备上生成的配对码，留空时管理设备只能扫码或手输核对码取到这次请求。
  Future<void> startPairing({String? code}) async {
    final p = await account.startPairing(session!, deviceName, code: code);
    final ready = Completer<void>();
    pendingPairing = p;
    unawaited(_waitPairing(p, ready));
    await ready.future;
    _go(Stage.pairing);
  }

  Future<void> _waitPairing(PendingPairing p, Completer<void> ready) async {
    try {
      final cfg = await account.waitPairing(p, onReady: ready.complete);
      if (!identical(pendingPairing, p)) return;
      await vault.adopt(cfg).catchError((_) {}); // 本机配置已保存；只是同步失败时，进入首页后会重试
      pendingPairing = null;
      session = null;
      _go(Stage.home);
      _onUnlocked();
    } on VaultException catch (e) {
      if (!ready.isCompleted) return ready.completeError(e);
      if (!identical(pendingPairing, p)) return; // 用户已离开等待页
      pendingPairing = null;
      notice = e.message;
      _go(Stage.unpaired);
    }
  }

  /// 离开等待页：断开等待连接，服务端随即作废这次请求。
  void cancelPairing() {
    pendingPairing?.cancel();
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
      // 从输入邮箱页直接恢复：先设置 App PIN，再保存设备密钥。
      _pendingRecovery = cfg;
      _go(Stage.setPin);
      return;
    }
    await vault.adopt(cfg);
    _go(Stage.rotation);
  }

  /// 生成新的恢复码（尚未提交）。
  Uint8List newRecoveryCode() => crypto.random(16);

  Future<void> rotateRecovery(Uint8List code) async {
    rotationKey ??= crypto.newId();
    try {
      await vault.rotateRecovery(code, key: rotationKey);
    } catch (e) {
      if (!await _rotationCompleted()) rethrow;
    }
    rotationKey = null;
    refresh();
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
}
