// 应用内更新：读取更新源（GitHub Releases 的 update-feed）中对应渠道、带 minisign 签名的清单。
// 安装包下载后先按清单校验。Android 上交给系统安装器；iOS 上交给用户选择的签名工具，由它签名安装。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/crypto.dart';
import '../core/update_download.dart';
import '../core/update_asset.dart';
import 'debug_update.dart';
import 'platform.dart';
import '../ui/download_progress.dart';
import '../ui/update_sheet.dart';
import '../ui/app_scope.dart';
import '../ui/widgets.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.1.0');

/// 发布签名公钥（minisign 格式），与 CLI 内置的相同。
const releasePublicKey = 'RWSG3mCrOrJkGKAhsnHOVBP4a+qs9VJi/47Vv3BQobIJ/ZamvbuQjabm';

const _releases = 'https://github.com/harmonia-vault/harmonia/releases';
const _feedBase = '$_releases/download/update-feed';

/// 更新渠道：正式版只接收正式版本；测试版接收全部版本中最新的一个（含 -rc.x、-beta.x）。
enum UpdateChannel {
  stable('正式版', '只接收正式版本，最稳定'),
  beta('测试版', '先体验新功能（-rc、-beta 版本），也可能不够稳定');

  const UpdateChannel(this.label, this.description);
  final String label, description;

  /// 默认渠道：测试版程序默认留在测试版渠道。
  static UpdateChannel parse(String? s) =>
      values.where((c) => c.name == s).firstOrNull ?? (isPrerelease(appVersion) ? beta : stable);
}

const _channel = MethodChannel('harmonia/platform');

class UpdateInfo {
  UpdateInfo(this.version, this.notes, this.url, this.sha256, this.size);
  final String version, notes, url, sha256;
  final int size;
}

// 预发布标识的先后：rc 晚于 beta，beta 晚于 alpha；正式版晚于同一基础版本的全部预发布版本。
const _preRank = {'alpha': 1, 'beta': 2, 'rc': 3};

List<int> _versionKey(String v) {
  final s = v.trim().replaceFirst(RegExp('^v'), '');
  final dash = s.indexOf('-');
  final main = dash < 0 ? s : s.substring(0, dash);
  final base = (main.split('.') + ['0', '0', '0']).take(3).map((x) => int.tryParse(x) ?? 0).toList();
  if (dash < 0) return [...base, 4, 0];
  final pre = s.substring(dash + 1).toLowerCase();
  final kind = pre.replaceFirst(RegExp(r'[0-9.]*$'), '');
  final num = int.tryParse(pre.substring(kind.length).replaceFirst(RegExp(r'^\.'), '')) ?? 0;
  return [...base, _preRank[kind] ?? 0, num];
}

/// 比较版本：a 较新返回正数。顺序示例：0.1.2 > 0.1.2-rc.1 > 0.1.2-beta.1 > 0.1.1。
int compareVersions(String a, String b) {
  final ka = _versionKey(a), kb = _versionKey(b);
  for (var i = 0; i < ka.length; i++) {
    if (ka[i] != kb[i]) return ka[i].compareTo(kb[i]);
  }
  return 0;
}

bool isNewer(String a, String b) => compareVersions(a, b) > 0;

bool isPrerelease(String v) => v.contains('-');

/// 校验 minisign 签名（预哈希 ED 算法 + 可信注释签名）。
bool verifyMinisign(HCrypto c, String publicKey, Uint8List data, String signature) {
  try {
    final pk = base64.decode(publicKey.trim().split('\n').last.trim());
    final lines = signature.trim().split('\n');
    final sig = base64.decode(lines[1].trim());
    final trusted = lines[2].replaceFirst('trusted comment: ', '');
    final global = base64.decode(lines[3].trim());
    if (pk.length != 42 || sig.length != 74) return false;
    // Ed：直接签名原文；ED：签名原文的 BLAKE2b-512（minisign 预哈希模式）。
    final alg = String.fromCharCodes(sig.sublist(0, 2));
    if (alg != 'Ed' && alg != 'ED') return false;
    for (var i = 0; i < 8; i++) {
      if (pk[2 + i] != sig[2 + i]) return false;
    }
    final pub = Uint8List.fromList(pk.sublist(10));
    final signed = alg == 'ED' ? c.sodium.crypto.genericHash(message: data, outLen: 64) : data;
    final s = Uint8List.fromList(sig.sublist(10));
    if (!c.verify(pub, signed, s)) return false;
    return c.verify(pub, Uint8List.fromList([...s, ...utf8.encode(trusted)]), Uint8List.fromList(global));
  } catch (_) {
    return false;
  }
}

Future<UpdateInfo?> fetchUpdate(HCrypto c, UpdateChannel channel) async {
  if (releasePublicKey.isEmpty) throw Exception('这个版本没有配置更新源（开发版本）。');
  final url = '$_feedBase/${channel.name}.json';
  // 清单与签名同时请求。
  final List<http.Response> responses;
  try {
    responses = await Future.wait([http.get(Uri.parse(url)), http.get(Uri.parse('$url.minisig'))])
        .timeout(const Duration(seconds: 20));
  } catch (_) {
    throw Exception('无法连接更新服务器，请检查网络后重试。');
  }
  final [res, sig] = responses;
  if (res.statusCode == 404) throw Exception('${channel.label}渠道还没有发布过版本。');
  if (res.statusCode != 200 || sig.statusCode != 200) throw Exception('暂时无法获取更新信息，请稍后重试。');
  if (!verifyMinisign(c, releasePublicKey, res.bodyBytes, sig.body)) {
    throw Exception('更新信息的签名无效，已拒绝。');
  }
  final m = (jsonDecode(utf8.decode(res.bodyBytes)) as Map).cast<String, dynamic>();
  final version = m['version'] as String;
  // 正式版渠道只接受正式版本，防止测试版清单被当作正式版下发。
  if (channel == UpdateChannel.stable && isPrerelease(version)) throw Exception('更新信息异常，已拒绝。');
  if (!isNewer(version, appVersion)) return null;
  final asset = selectAppUpdateAsset(
    (m['assets'] as Map).cast<String, dynamic>(),
    platform: hostPlatform,
    abi: Abi.current(),
  );
  return UpdateInfo(
    version,
    m['notes'] as String? ?? '',
    asset['url'] as String,
    asset['sha256'] as String,
    asset['size'] as int,
  );
}

late HCrypto updaterCrypto;
DateTime? _lastAutoCheck;

/// 检查更新。manual=false 时每 24 小时最多检查一次，并且只在有新版本时提示。
Future<void> checkForUpdate(BuildContext context, {required bool manual, required UpdateChannel channel}) async {
  if (AppScope.isSimulated(context)) {
    if (!manual) return;
    if (!await runBusy(context, () => Future<void>.delayed(const Duration(milliseconds: 600)))) return;
    if (!context.mounted) return;
    final choice = await showUpdateSheet(
      context,
      version: '0.0.1',
      current: '0.0.0',
      notes: List.generate(8, (i) => '- 示例更新 ${i + 1}：检查长内容滚动与固定按钮。').join('\n'),
      hint: '此处使用模拟更新。',
      primary: Platform.isIOS ? '下载并导入签名工具' : '下载并安装',
      secondary: '打开下载页',
    );
    if (!context.mounted) return;
    if (choice == UpdateChoice.primary) {
      await simulateUpdateDownload(context);
    } else if (choice == UpdateChoice.secondary) {
      toast(context, '模拟打开下载页');
    }
    return;
  }
  if (!manual) {
    if (releasePublicKey.isEmpty) return;
    if (_lastAutoCheck != null && DateTime.now().difference(_lastAutoCheck!) < const Duration(hours: 24)) return;
    _lastAutoCheck = DateTime.now();
  }
  UpdateInfo? fetched;
  if (manual) {
    // 手动检查时显示进度，失败时提示原因。
    if (!await runBusy(context, () async => fetched = await fetchUpdate(updaterCrypto, channel))) return;
  } else {
    try {
      fetched = await fetchUpdate(updaterCrypto, channel);
    } catch (_) {
      return;
    }
  }
  final info = fetched;
  if (!context.mounted) return;
  if (info == null) {
    if (manual) {
      toast(
        context,
        channel == UpdateChannel.stable && isPrerelease(appVersion)
            ? '当前是测试版 $appVersion，正式版发布更高的版本后会提示升级'
            : '已是最新版本（$appVersion）',
      );
    }
    return;
  }
  if (Platform.isIOS) return _offerIpa(context, info);
  final choice = await showUpdateSheet(
    context,
    version: info.version,
    current: appVersion,
    notes: info.notes,
    hint: '下载后会打开系统安装界面，数据会保留。',
    primary: '下载并安装',
    secondary: '打开下载页',
  );
  if (choice == null || !context.mounted) return;
  if (choice == UpdateChoice.secondary) {
    try {
      await openUrl('$_releases/tag/v${info.version}');
    } on PlatformException {
      if (context.mounted) toast(context, '无法打开下载页，请安装或启用浏览器后重试');
    }
    return;
  }
  if (await _channel.invokeMethod<bool>('canInstall') != true) {
    if (!context.mounted) return;
    final ok = await confirmDialog(
      context,
      title: '需要允许安装应用',
      body: '请在接下来的系统设置中允许 Harmonia 安装应用，然后回来再点一次“检查更新”。',
      ok: '去设置',
    );
    if (ok) await _channel.invokeMethod('openInstallSettings');
    return;
  }
  if (!context.mounted) return;
  final file = await _download(context, info, 'apk');
  if (file != null) await _channel.invokeMethod('install', {'path': file.path});
}

/// 下载安装包并按清单核对大小和 SHA-256，保存到缓存目录；失败时提示并返回 null。
/// 目录里之前留下的安装包先清掉。
Future<File?> _download(BuildContext context, UpdateInfo info, String extension) async {
  late File file;
  final progress = ValueNotifier(DownloadProgress(total: info.size));
  final refresh = Stopwatch()..start();
  try {
    final ok = await runBusy(context, () async {
      final bytes = await downloadUpdatePackage(
        Uri.parse(info.url),
        expectedSize: info.size,
        onProgress: (received) {
          // 大文件分块很密集，界面最多每 100 毫秒刷新一次，首尾状态始终显示。
          if (received != 0 && received != info.size && refresh.elapsedMilliseconds < 100) return;
          refresh.reset();
          progress.value = DownloadProgress(total: info.size, received: received, phase: DownloadPhase.receiving);
        },
      );
      progress.value = DownloadProgress(total: info.size, received: bytes.length, phase: DownloadPhase.verifying);
      // 保留原有哈希校验，放到后台计算，校验期间进度界面仍可绘制。
      if (b64(await compute(sha256, bytes)) != _hexToB64(info.sha256)) {
        throw Exception('下载的安装包校验失败，请稍后重试。');
      }
      final dir = Directory('${(await getApplicationCacheDirectory()).path}/updates');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      file = File('${dir.path}/harmonia-${info.version}.$extension');
      await file.writeAsBytes(bytes, flush: true);
    }, progressBuilder: (_) => DownloadProgressDialog(progress: progress));
    return ok ? file : null;
  } finally {
    progress.dispose();
  }
}

/// iOS 不能在 App 内安装：下载并校验新的 IPA，再通过系统分享面板交给用户安装 Harmonia 时用的签名工具。
Future<void> _offerIpa(BuildContext context, UpdateInfo info) async {
  final choice = await showUpdateSheet(
    context,
    version: info.version,
    current: appVersion,
    notes: info.notes,
    primary: '下载并导入签名工具',
    secondary: '打开下载页',
  );
  if (choice == UpdateChoice.secondary) return openUrl('$_releases/tag/v${info.version}');
  if (choice == null || !context.mounted) return;
  final file = await _download(context, info, 'ipa');
  if (file == null) return;
  // 取消时马上删掉。交出去之后先留着：有的 App 在面板关闭后才读取文件，下次下载前会清掉。
  final handedOver = await shareFile(file.path);
  if (!handedOver && await file.exists()) await file.delete();
}

String _hexToB64(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return b64(out);
}
