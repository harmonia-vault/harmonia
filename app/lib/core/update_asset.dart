// 按 Dart 实际运行架构选择已签名安装包，不回退到其他架构或通用包。
import 'dart:ffi';

Map<String, dynamic> selectAppUpdateAsset(Map<String, dynamic> assets, {required String platform, required Abi abi}) {
  final key = switch ((platform, abi)) {
    ('ios', _) => 'ios',
    ('android', Abi.androidArm64) => 'android-arm64',
    ('android', Abi.androidArm) => 'android-arm',
    _ => throw Exception('当前设备暂不支持应用内更新，请到发布页选择安装包。'),
  };
  final asset = assets[key];
  if (asset is! Map) throw Exception('没有找到适合当前设备的安装包，请到发布页下载或稍后重试。');
  return asset.cast<String, dynamic>();
}
