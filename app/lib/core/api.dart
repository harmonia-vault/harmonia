// docs/protocol.md 第 3 节的 HTTP 客户端。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, {this.flow});
  final int status;
  final String code;
  final String message;

  /// 随 code_required 返回：带上它和邮件验证码再登录一次（协议 3.8）。
  final String? flow;

  bool get isNetwork => code == 'network';

  @override
  String toString() => message;
}

/// 本设备已被移除；调用方应清除本机数据。
class RevokedException implements Exception {
  @override
  String toString() => '这台设备已被移除';
}

/// 由设备签名钥对登录挑战签名。
typedef AuthSigner = String Function(String nonce);

String normalizeServer(String raw) {
  var s = raw.trim();
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) {
    throw ApiException(0, 'invalid', '服务器地址格式不对，例如 vault.example.com');
  }
  final local = u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '10.0.2.2';
  if (u.scheme != 'https' && !(u.scheme == 'http' && local)) {
    throw ApiException(0, 'invalid', '服务器地址必须使用 https://');
  }
  final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  return '${u.scheme}://${u.authority}$path';
}

class ApiClient {
  ApiClient(this.base, {http.Client? client}) : _http = client ?? http.Client();

  final String base;
  final http.Client _http;
  String? accountId;
  String? deviceId;
  AuthSigner? signer;

  String? _token;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  void clearSession() => _token = null;

  Future<Map<String, dynamic>> _do(
    String method,
    String path, {
    Object? body,
    String? token,
    Map<String, String>? headers,
  }) async {
    final h = <String, String>{'content-type': 'application/json'};
    if (token != null) h['authorization'] = 'Bearer $token';
    if (accountId != null) h['x-harmonia-account'] = accountId!;
    if (headers != null) h.addAll(headers);
    final req = http.Request(method, Uri.parse('$base$path'))..headers.addAll(h);
    if (body != null) req.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(
          await _http.send(req).timeout(const Duration(seconds: 30)));
    } on TimeoutException {
      throw ApiException(0, 'network', '连接服务器超时，请检查网络后重试。');
    } on SocketException {
      throw ApiException(0, 'network', '无法连接服务器，请检查网络和服务器地址。');
    } on http.ClientException {
      throw ApiException(0, 'network', '无法连接服务器，请检查网络和服务器地址。');
    } on HandshakeException {
      throw ApiException(0, 'network', '无法建立安全连接，请确认服务器的 HTTPS 证书有效。');
    }
    Map<String, dynamic> json;
    try {
      json = (jsonDecode(utf8.decode(res.bodyBytes)) as Map).cast<String, dynamic>();
    } catch (_) {
      throw ApiException(res.statusCode, 'http',
          '服务器返回了意外的响应（HTTP ${res.statusCode}），请确认地址是 Harmonia 服务。');
    }
    if (res.statusCode != 200) {
      final code = json['error'] as String? ?? 'http';
      if (code == 'device_revoked') throw RevokedException();
      throw ApiException(res.statusCode, code, json['message'] as String? ?? '服务器返回错误（HTTP ${res.statusCode}）',
          flow: json['flow'] as String?);
    }
    return json;
  }

  Future<Map<String, dynamic>> public(String method, String path, [Object? body]) =>
      _do(method, path, body: body);

  Future<Map<String, dynamic>> publicWithHeaders(
          String method, String path, Map<String, String> headers) =>
      _do(method, path, headers: headers);

  Future<Map<String, dynamic>> withToken(String token, String method, String path,
          [Object? body]) =>
      _do(method, path, body: body, token: token);

  Future<String> deviceToken() async {
    if (_token != null && _expires.difference(DateTime.now()).inSeconds > 60) {
      return _token!;
    }
    if (signer == null || deviceId == null) {
      throw ApiException(401, 'unauthorized', '本机还没有接入账号。');
    }
    final ch = await _do('POST', '/api/v1/auth/challenge', body: {'deviceId': deviceId});
    final nonce = ch['nonce'] as String;
    final s = await _do('POST', '/api/v1/auth/device-session',
        body: {'deviceId': deviceId, 'nonce': nonce, 'signature': signer!(nonce)});
    _token = s['token'] as String;
    _expires = DateTime.fromMillisecondsSinceEpoch(s['expiresAt'] as int);
    return _token!;
  }

  /// 以设备身份调用；会话失效时重新登录一次。
  Future<Map<String, dynamic>> device(String method, String path,
      {Object? body, Map<String, String>? headers}) async {
    for (var attempt = 0;; attempt++) {
      final token = await deviceToken();
      try {
        return await _do(method, path, body: body, token: token, headers: headers);
      } on ApiException catch (e) {
        if (attempt == 0 && e.code == 'unauthorized') {
          _token = null;
          continue;
        }
        rethrow;
      }
    }
  }

  /// 保持推送连接，直到连接断开；收到提示时调用 [onEvent]。
  Future<void> listen(void Function(Map<String, dynamic> event) onEvent) async {
    final token = await deviceToken();
    final wsUrl = '${base.replaceFirst('http', 'ws')}/api/v1/events';
    final ws = await WebSocket.connect(wsUrl, headers: {'authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    final ping = Timer.periodic(const Duration(seconds: 30), (_) => ws.add('ping'));
    try {
      await for (final msg in ws) {
        if (msg is! String || msg == 'pong') continue;
        final ev = (jsonDecode(msg) as Map).cast<String, dynamic>();
        if (ev['type'] == 'revoked') throw RevokedException();
        onEvent(ev);
      }
      if (ws.closeCode == 4001) throw RevokedException();
    } finally {
      ping.cancel();
      await ws.close();
    }
  }

  /// 作为配对发起方保持等待连接（协议 3.5.1）：连上后调用 [onReady]，返回服务端推送的结果
  /// （approved、rejected 或 expired）；连接断开时返回 null。关闭 [onReady] 拿到的连接即放弃这次请求。
  Future<String?> waitPairing(String id, String secret, {required void Function(WebSocket ws) onReady}) async {
    final wsUrl = '${base.replaceFirst('http', 'ws')}/api/v1/pairings/$id/events';
    final ws = await WebSocket.connect(wsUrl, headers: {'x-harmonia-account': accountId!, 'x-pairing-secret': secret})
        .timeout(const Duration(seconds: 20));
    onReady(ws);
    final ping = Timer.periodic(const Duration(seconds: 10), (_) {
      try {
        ws.add('ping');
      } catch (_) {}
    });
    try {
      await for (final msg in ws) {
        if (msg is! String || msg == 'pong') continue;
        final type = (jsonDecode(msg) as Map)['type'];
        if (type == 'approved' || type == 'rejected' || type == 'expired') return type as String;
      }
      return null;
    } finally {
      ping.cancel();
      await ws.close();
    }
  }
}
