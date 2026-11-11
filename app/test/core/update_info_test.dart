import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/update_info.dart';

void main() {
  test('Apple 包只读取新版本，忽略更新说明与安装包数据', () {
    for (final manifest in [
      <String, dynamic>{'version': '0.16.0'},
      <String, dynamic>{'version': '0.16.0', 'notes': 42, 'assets': '不是安装包'},
    ]) {
      final update = parseAppUpdate(
        manifest,
        currentVersion: '0.15.1',
        apple: true,
        platform: 'ios',
        abi: Abi.iosArm64,
      );
      expect(update?.version, '0.16.0');
      expect(update, isNot(isA<UpdateInfo>()));
    }
  });

  test('相同或较旧版本不提示更新，也不读取安装包', () {
    for (final apple in [true, false]) {
      for (final version in ['0.15.1', '0.15.0', '0.15.1-rc.1']) {
        expect(
          parseAppUpdate(
            {'version': version},
            currentVersion: '0.15.1',
            apple: apple,
            platform: 'ios',
            abi: Abi.iosArm64,
          ),
          isNull,
        );
      }
    }
  });

  test('GitHub IPA 保留说明与安装包信息', () {
    final update = parseAppUpdate(
      {
        'version': '0.16.0',
        'notes': '示例更新',
        'assets': {
          'ios': {'url': 'https://example.test/harmonia.ipa', 'sha256': 'abcd', 'size': 123},
        },
      },
      currentVersion: '0.15.1',
      apple: false,
      platform: 'ios',
      abi: Abi.iosArm64,
    ) as UpdateInfo;
    expect(update.notes, '示例更新');
    expect(update.url, 'https://example.test/harmonia.ipa');
    expect(update.sha256, 'abcd');
    expect(update.size, 123);
  });

  test('GitHub IPA 缺少安装包时仍报错', () {
    expect(
      () => parseAppUpdate(
        {'version': '0.16.0', 'assets': <String, dynamic>{}},
        currentVersion: '0.15.1',
        apple: false,
        platform: 'ios',
        abi: Abi.iosArm64,
      ),
      throwsException,
    );
  });
}
