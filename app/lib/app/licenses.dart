// 没有随 Dart 包自动登记的开源组件，在这里补登记版权说明和许可证，供“关于”页显示。
// Dart 包和 Flutter 引擎自带的那部分由 Flutter 在构建时收集；libsodium 的许可证随 sodium 包一起收集。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    final apache = await rootBundle.loadString('assets/licenses/apache-2.0.txt');
    // 中文分词模型（assets/budoux/zh-hans.json）。
    yield LicenseEntryWithLineBreaks(['BudouX'], 'Copyright 2021 Google LLC\n\n$apache');
    if (Platform.isAndroid) {
      yield LicenseEntryWithLineBreaks(['AndroidX'], 'Copyright The Android Open Source Project\n\n$apache');
      yield LicenseEntryWithLineBreaks(
          ['Kotlin'], 'Copyright JetBrains s.r.o. and Kotlin Programming Language contributors\n\n$apache');
    }
  });
}
