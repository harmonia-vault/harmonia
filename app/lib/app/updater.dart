// 应用内更新：读取 GitHub Releases 上带 minisign 签名的 manifest.json，下载并校验 APK，交给系统安装器。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/crypto.dart';
import '../ui/widgets.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.1.0');

/// 发布签名公钥（minisign 格式），与 CLI 内置的相同。
const releasePublicKey = String.fromEnvironment('RELEASE_PUBKEY', defaultValue: '');

const _manifestUrl = 'https://github.com/harmonia-vault/harmonia/releases/latest/download/manifest.json';
const _channel = MethodChannel('harmonia/platform');

class UpdateInfo {
  UpdateInfo(this.version, this.notes, this.url, this.sha256, this.size);
  final String version, notes, url, sha256;
  final int size;
}

bool isNewer(String a, String b) {
  List<int> parse(String v) =>
      (v.replaceFirst('v', '').split('-').first.split('.') + ['0', '0', '0'])
          .take(3)
          .map((x) => int.tryParse(x) ?? 0)
          .toList();
  final pa = parse(a), pb = parse(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] > pb[i];
  }
  return false;
}

/// 校验 minisign 签名（预哈希 ED 算法 + 可信注释签名）。
bool verifyMinisign(HCrypto c, String publicKey, Uint8List data, String signature) {
  try {
    final pk = base64.decode(publicKey.trim().split('\n').last.trim());
    final lines = signature.trim().split('\n');
    final sig = base64.decode(lines[1].trim());
    final trusted = lines[2].replaceFirst('trusted comment: ', '');
    final global = base64.decode(lines[3].trim());
    if (pk.length != 42 || sig.length != 74) return false;
    if (String.fromCharCodes(sig.sublist(0, 2)) != 'ED') return false;
    for (var i = 0; i < 8; i++) {
      if (pk[2 + i] != sig[2 + i]) return false;
    }
    final pub = Uint8List.fromList(pk.sublist(10));
    final digest = c.sodium.crypto.genericHash(message: data, outLen: 64);
    final s = Uint8List.fromList(sig.sublist(10));
    if (!c.verify(pub, digest, s)) return false;
    return c.verify(pub, Uint8List.fromList([...s, ...utf8.encode(trusted)]), Uint8List.fromList(global));
  } catch (_) {
    return false;
  }
}

Future<UpdateInfo?> fetchUpdate(HCrypto c) async {
  if (releasePublicKey.isEmpty) throw Exception('这个版本没有配置更新源（开发版本）。');
  final res = await http.get(Uri.parse(_manifestUrl)).timeout(const Duration(seconds: 20));
  final sig = await http.get(Uri.parse('$_manifestUrl.minisig')).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200 || sig.statusCode != 200) throw Exception('暂时无法获取更新信息，请稍后重试。');
  if (!verifyMinisign(c, releasePublicKey, res.bodyBytes, sig.body)) {
    throw Exception('更新信息的签名无效，已拒绝。');
  }
  final m = (jsonDecode(utf8.decode(res.bodyBytes)) as Map).cast<String, dynamic>();
  final version = m['version'] as String;
  if (!isNewer(version, appVersion)) return null;
  final asset = ((m['assets'] as Map)['android'] as Map?)?.cast<String, dynamic>();
  if (asset == null) return null;
  return UpdateInfo(version, m['notes'] as String? ?? '', asset['url'] as String, asset['sha256'] as String,
      asset['size'] as int);
}

late HCrypto updaterCrypto;
DateTime? _lastAutoCheck;

/// 检查更新。manual=false 时每 24 小时最多检查一次，并且只在有新版本时提示。
Future<void> checkForUpdate(BuildContext context, {required bool manual}) async {
  if (!manual) {
    if (releasePublicKey.isEmpty) return;
    if (_lastAutoCheck != null && DateTime.now().difference(_lastAutoCheck!) < const Duration(hours: 24)) return;
    _lastAutoCheck = DateTime.now();
  }
  UpdateInfo? info;
  try {
    info = await fetchUpdate(updaterCrypto);
  } catch (e) {
    if (manual && context.mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
    return;
  }
  if (!context.mounted) return;
  if (info == null) {
    if (manual) toast(context, '已是最新版本（$appVersion）');
    return;
  }
  final go = await confirmDialog(context,
      title: '发现新版本 ${info.version}',
      body: '${info.notes.isEmpty ? '' : '${info.notes}\n\n'}下载后会打开系统安装界面，数据会保留。',
      ok: '下载并安装');
  if (!go || !context.mounted) return;
  if (await _channel.invokeMethod<bool>('canInstall') != true) {
    if (!context.mounted) return;
    final ok = await confirmDialog(context,
        title: '需要允许安装应用', body: '请在接下来的系统设置中允许 Harmonia 安装应用，然后回来再点一次“检查更新”。', ok: '去设置');
    if (ok) await _channel.invokeMethod('openInstallSettings');
    return;
  }
  if (!context.mounted) return;
  late File file;
  final update = info;
  final ok = await runBusy(context, () async {
    final res = await http.get(Uri.parse(update.url)).timeout(const Duration(minutes: 5));
    final bytes = res.bodyBytes;
    if (res.statusCode != 200 || bytes.length != update.size || b64(sha256(bytes)) != _hexToB64(update.sha256)) {
      throw Exception('下载的安装包校验失败，请稍后重试。');
    }
    final dir = Directory('${(await getApplicationCacheDirectory()).path}/updates');
    await dir.create(recursive: true);
    file = File('${dir.path}/harmonia-${update.version}.apk');
    await file.writeAsBytes(bytes, flush: true);
  });
  if (ok) await _channel.invokeMethod('install', {'path': file.path});
}

String _hexToB64(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return b64(out);
}
