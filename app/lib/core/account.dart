// 本机还没有接入账号时的流程：注册、验证、登录、首次初始化、作为新手机配对、恢复、找回密码、重置账号。
import 'dart:io' show WebSocket;
import 'dart:typed_data';

import 'api.dart';
import 'crypto.dart';
import 'vault.dart';

class InstanceInfo {
  InstanceInfo(this.server, this.version, this.registrationOpen, this.emailVerification);
  final String server;
  final String version;
  final bool registrationOpen;
  final bool emailVerification;
}

class PasswordSession {
  PasswordSession(this.server, this.email, this.token, this.accountId, this.initialized, this.rootPub);
  final String server, email, token, accountId;
  final bool initialized;
  final String? rootPub;
}

/// 首次初始化前在本机生成的密钥与恢复码；用户确认抄写后才提交。
class SetupDraft {
  SetupDraft(this.code, this.rootSeed, this.signSeed, this.boxSeed, this.deviceId);
  final Uint8List code;
  final Uint8List rootSeed, signSeed, boxSeed;
  final String deviceId;
  String get formattedCode => formatRecoveryCode(code);
}

/// 作为新的管理设备发起的配对请求。
class PendingPairing {
  PendingPairing(this.session, this.id, this.secret, this.signSeed, this.boxSeed, this.qr,
      this.code, this.expiresAt, this.deviceName);
  final PasswordSession session;
  final String id, secret, qr, code, deviceName;
  final Uint8List signSeed, boxSeed;
  final DateTime expiresAt;

  /// 等待连接；关闭它即放弃这次请求，服务端随即作废。
  WebSocket? _socket;
  void cancel() => _socket?.close();
}

class AccountService {
  AccountService(this.crypto);
  final HCrypto crypto;

  ApiClient _client(String server, [String? accountId]) => ApiClient(server)..accountId = accountId;

  Future<InstanceInfo> instance(String rawServer) async {
    final server = normalizeServer(rawServer);
    final res = await _client(server).public('GET', '/api/v1/instance');
    if (res['product'] != 'harmonia') {
      throw VaultException('这个地址不是 Harmonia 服务，请检查服务器地址。');
    }
    if (res['protocol'] != 1) {
      throw VaultException('服务器版本（${res['version']}）与 App 不兼容，请升级 App 或服务器。');
    }
    final reg = (res['registration'] as Map).cast<String, dynamic>();
    return InstanceInfo(server, res['version'] as String, reg['open'] as bool,
        reg['emailVerification'] as bool);
  }

  Future<Map<String, String>> _password(String password) async {
    final salt = crypto.random(16);
    return {'kdfSalt': b64(salt), 'authKey': b64(await passwordKeyInIsolate(password, salt))};
  }

  /// 注册；返回是否需要验证邮箱。
  Future<bool> register(String server, String email, String password) async {
    final res = await _client(server)
        .public('POST', '/api/v1/register', {'email': email.trim(), ...await _password(password)});
    return res['verificationRequired'] as bool;
  }

  Future<void> verifyEmail(String server, String email, String code) =>
      _client(server).public('POST', '/api/v1/register/verify', {'email': email.trim(), 'code': code});

  Future<void> resendVerification(String server, String email) =>
      _client(server).public('POST', '/api/v1/register/resend', {'email': email.trim()});

  Future<PasswordSession> login(String server, String email, String password) async {
    final c = _client(server);
    final pre = await c.public(
        'GET', '/api/v1/auth/prelogin?email=${Uri.encodeQueryComponent(email.trim())}');
    final key = await passwordKeyInIsolate(password, unb64(pre['kdfSalt'] as String));
    final s = await c.public('POST', '/api/v1/auth/login', {'email': email.trim(), 'authKey': b64(key)});
    final token = s['token'] as String;
    c.accountId = s['accountId'] as String;
    final acct = await c.withToken(token, 'GET', '/api/v1/account');
    return PasswordSession(server, acct['email'] as String, token, acct['accountId'] as String,
        acct['initialized'] as bool, acct['rootPub'] as String?);
  }

  Future<void> requestPasswordReset(String server, String email) =>
      _client(server).public('POST', '/api/v1/password-reset/request', {'email': email.trim()});

  Future<void> completePasswordReset(
          String server, String email, String code, String newPassword) async =>
      _client(server).public('POST', '/api/v1/password-reset/complete',
          {'email': email.trim(), 'code': code, ...await _password(newPassword)});

  Future<void> requestAccountReset(String server, String email) =>
      _client(server).public('POST', '/api/v1/account-reset/request', {'email': email.trim()});

  Future<void> completeAccountReset(String server, String email, String code) =>
      _client(server)
          .public('POST', '/api/v1/account-reset/complete', {'email': email.trim(), 'code': code});

  // ---- 首次初始化 ----

  SetupDraft prepareSetup() => SetupDraft(
      crypto.random(16), crypto.random(32), crypto.random(32), crypto.random(32), crypto.newId());

  Future<LocalConfig> completeSetup(PasswordSession s, SetupDraft d, String deviceName) async {
    final root = crypto.signKeyFromSeed(d.rootSeed);
    final sign = crypto.signKeyFromSeed(d.signSeed);
    final box = crypto.boxKeyFromSeed(d.boxSeed);
    final rec = crypto.deriveRecovery(d.code);
    final recSealed = crypto.seal(d.rootSeed, rec.box.pub);
    final signPub = b64(sign.pub), boxPub = b64(box.pub);
    await _client(s.server, s.accountId).withToken(s.token, 'POST', '/api/v1/account/setup', {
      'rootPub': b64(root.pub),
      'device': {
        'id': d.deviceId,
        'name': deviceName,
        'platform': 'android',
        'signPub': signPub,
        'boxPub': boxPub,
        'cert': b64(crypto.sign(root, deviceCertMsg(d.deviceId, 'manager', signPub, boxPub))),
      },
      'rootSealed': b64(crypto.seal(d.rootSeed, box.pub)),
      'recovery': {
        'generation': '1',
        'signPub': b64(rec.sign.pub),
        'boxPub': b64(rec.box.pub),
        'rootSealed': b64(recSealed),
        'rootSig': b64(crypto.sign(rec.sign, rootRecoveryMsg(1, recSealed))),
      },
    });
    return LocalConfig(
        server: s.server,
        accountId: s.accountId,
        email: s.email,
        rootPub: b64(root.pub),
        deviceId: d.deviceId,
        deviceName: deviceName,
        signSeed: b64(d.signSeed),
        boxSeed: b64(d.boxSeed));
  }

  // ---- 作为新手机配对 ----

  Future<PendingPairing> startPairing(PasswordSession s, String deviceName) async {
    final signSeed = crypto.random(32), boxSeed = crypto.random(32);
    final signPub = b64(crypto.signKeyFromSeed(signSeed).pub);
    final boxPub = b64(crypto.boxKeyFromSeed(boxSeed).pub);
    final res = await _client(s.server, s.accountId).withToken(s.token, 'POST', '/api/v1/pairings', {
      'name': deviceName,
      'platform': 'android',
      'signPub': signPub,
      'boxPub': boxPub,
      'rootPub': s.rootPub,
      'canManage': true,
    });
    final id = res['id'] as String;
    final fp = pairingFingerprint(id, signPub, boxPub, s.rootPub!);
    return PendingPairing(s, id, res['secret'] as String, signSeed, boxSeed, pairingQr(id, fp),
        pairingCode(fp), DateTime.fromMillisecondsSinceEpoch(res['expiresAt'] as int), deviceName);
  }

  /// 保持等待连接直到有结果：批准后返回本机配置，否则抛出说明原因的异常。连上后调用 [onReady]。
  Future<LocalConfig> waitPairing(PendingPairing p, {required void Function() onReady}) async {
    final c = _client(p.session.server, p.session.accountId);
    String? result;
    try {
      result = await c.waitPairing(p.id, p.secret, onReady: (ws) {
        p._socket = ws;
        onReady();
      });
    } catch (_) {
      // 连接失败或中断，下面查一次最终状态。
    }
    if (result == null) {
      try {
        final res = await c.publicWithHeaders('GET', '/api/v1/pairings/${p.id}/status', {'x-pairing-secret': p.secret});
        result = res['status'] as String?;
      } catch (_) {}
    }
    switch (result) {
      case 'approved':
        return LocalConfig(
            server: p.session.server,
            accountId: p.session.accountId,
            email: p.session.email,
            rootPub: p.session.rootPub!,
            deviceId: p.id,
            deviceName: p.deviceName,
            signSeed: b64(p.signSeed),
            boxSeed: b64(p.boxSeed));
      case 'rejected':
        throw VaultException('这次配对被拒绝或已作废，请重新发起。');
      case 'expired':
        throw VaultException('配对请求已过期（10 分钟），请重新发起。');
    }
    throw VaultException('与服务器的连接中断，这次配对已作废。请检查网络后重新发起。');
  }

  // ---- 恢复 ----

  /// 用恢复码把本机登记为管理设备。之后必须立即轮换恢复码。
  Future<LocalConfig> recover(String server, String email, String codeInput, String deviceName) async {
    final code = parseRecoveryCode(codeInput);
    if (code == null) throw VaultException('恢复码格式不对，请检查是否完整输入了 26 个字符。');
    final rec = crypto.deriveRecovery(code);
    final ch = await _client(server).public('POST', '/api/v1/recovery/challenge', {'email': email.trim()});
    final c = _client(server, ch['accountId'] as String);
    final nonce = ch['nonce'] as String;
    final Map<String, dynamic> sess;
    try {
      sess = await c.public('POST', '/api/v1/recovery/session',
          {'nonce': nonce, 'signature': b64(crypto.sign(rec.sign, recoveryAuthMsg(nonce)))});
    } on ApiException catch (e) {
      if (e.code == 'unauthorized') throw VaultException('恢复码不对，请检查后重试。');
      rethrow;
    }
    final token = sess['token'] as String;
    final m = await c.withToken(token, 'GET', '/api/v1/recovery/material');
    final generation = int.parse(m['generation'] as String);
    final rootEnv = (m['rootEnvelope'] as Map).cast<String, dynamic>();
    final rootSealedRec = unb64(rootEnv['sealed'] as String);
    if (!crypto.verify(rec.sign.pub, rootRecoveryMsg(generation, rootSealedRec),
        unb64(rootEnv['sig'] as String))) {
      throw VaultException('服务器返回的恢复数据签名无效，已停止。');
    }
    final rootSeed = crypto.open(rec.box, rootSealedRec);
    final root = crypto.signKeyFromSeed(rootSeed);
    if (b64(root.pub) != m['rootPub']) throw VaultException('恢复数据与账号公钥不一致，已停止。');

    final signSeed = crypto.random(32), boxSeed = crypto.random(32);
    final sign = crypto.signKeyFromSeed(signSeed), box = crypto.boxKeyFromSeed(boxSeed);
    final deviceId = crypto.newId();
    final signPub = b64(sign.pub), boxPub = b64(box.pub);
    final envelopes = <Map<String, dynamic>>[];
    for (final e in (m['envelopes'] as List).cast<Map>()) {
      final envId = e['envId'] as String;
      final kv = int.parse(e['keyVersion'] as String);
      final sealed = unb64(e['sealed'] as String);
      if (!crypto.verify(root.pub, envelopeMsg(envId, kv, 'recovery', sealed), unb64(e['sig'] as String))) {
        throw VaultException('服务器返回的环境密钥签名无效，已停止。');
      }
      final key = crypto.open(rec.box, sealed);
      final mine = crypto.seal(key, box.pub);
      envelopes.add({
        'envId': envId,
        'keyVersion': '$kv',
        'sealed': b64(mine),
        'sig': b64(crypto.sign(root, envelopeMsg(envId, kv, deviceId, mine))),
      });
    }
    await c.withToken(token, 'POST', '/api/v1/recovery/enroll', {
      'device': {
        'id': deviceId,
        'name': deviceName,
        'platform': 'android',
        'signPub': signPub,
        'boxPub': boxPub,
        'cert': b64(crypto.sign(root, deviceCertMsg(deviceId, 'manager', signPub, boxPub))),
      },
      'rootSealed': b64(crypto.seal(rootSeed, box.pub)),
      'envelopes': envelopes,
    });
    return LocalConfig(
        server: server,
        accountId: ch['accountId'] as String,
        email: email.trim(),
        rootPub: b64(root.pub),
        deviceId: deviceId,
        deviceName: deviceName,
        signSeed: b64(signSeed),
        boxSeed: b64(boxSeed));
  }
}
