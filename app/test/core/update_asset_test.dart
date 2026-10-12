import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/update_asset.dart';

void main() {
  final assets = <String, dynamic>{
    'android-arm64': {'url': 'https://example.invalid/arm64.apk', 'sha256': 'arm64-hash', 'size': 31},
    'android-arm': {'url': 'https://example.invalid/arm.apk', 'sha256': 'arm-hash', 'size': 27},
    'ios': {'url': 'https://example.invalid/app.ipa', 'sha256': 'ios-hash', 'size': 40},
  };

  test('两种 Android 架构分别使用对应包的地址、哈希和大小', () {
    final arm64 = selectAppUpdateAsset(assets, platform: 'android', abi: Abi.androidArm64);
    final arm = selectAppUpdateAsset(assets, platform: 'android', abi: Abi.androidArm);
    expect(arm64, assets['android-arm64']);
    expect(arm, assets['android-arm']);
    expect(arm64, isNot(arm));
  });

  test('缺少匹配包时拒绝其他架构及旧通用包，不误报最新版本', () {
    final incomplete = {...assets}..remove('android-arm64');
    incomplete['android'] = assets['android-arm'];
    expect(
      () => selectAppUpdateAsset(incomplete, platform: 'android', abi: Abi.androidArm64),
      throwsA(isA<Exception>()),
    );
  });

  test('未发布的 Android 架构不错误下载 ARM 安装包', () {
    expect(() => selectAppUpdateAsset(assets, platform: 'android', abi: Abi.androidX64), throwsA(isA<Exception>()));
  });

  test('iOS 继续选择 IPA', () {
    expect(selectAppUpdateAsset(assets, platform: 'ios', abi: Abi.iosArm64), assets['ios']);
  });
}
