import 'dart:ffi';

import 'update_asset.dart';

/// Apple 分发包只展示版本号，GitHub IPA 保留下载安装流程。
const appleDistribution = bool.fromEnvironment('APPLE_DISTRIBUTION');

class UpdateNotice {
  const UpdateNotice(this.version);
  final String version;
}

class UpdateInfo extends UpdateNotice {
  const UpdateInfo(super.version, this.notes, this.url, this.sha256, this.size);
  final String notes, url, sha256;
  final int size;
}

/// 清单已通过签名验证；Apple 包不读取安装包或更新说明。
UpdateNotice? parseAppUpdate(
  Map<String, dynamic> manifest, {
  required String currentVersion,
  required bool apple,
  required String platform,
  required Abi abi,
}) {
  final version = manifest['version'] as String;
  if (!isNewer(version, currentVersion)) return null;
  if (apple) return UpdateNotice(version);
  final asset = selectAppUpdateAsset((manifest['assets'] as Map).cast<String, dynamic>(), platform: platform, abi: abi);
  return UpdateInfo(
    version,
    manifest['notes'] as String? ?? '',
    asset['url'] as String,
    asset['sha256'] as String,
    asset['size'] as int,
  );
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
