// 平台通道上的文件与剪贴板能力（实现见 Android 的 MainActivity / HtmlPdf，iOS 的 PlatformChannel）。
import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('harmonia/platform');

/// 本机在协议中的平台名。
final hostPlatform = Platform.isIOS ? 'ios' : 'android';

/// 本机的设备名；取不到时用平台的通称。
Future<String> hostDeviceName() async {
  try {
    final name = await _channel.invokeMethod<String>('deviceName');
    if (name != null && name.isNotEmpty) return name;
  } catch (_) {}
  return Platform.isIOS ? 'iPhone' : 'Android 手机';
}

/// 用系统网页引擎把 HTML 排版成 A4 PDF。
Future<Uint8List> htmlToPdf(String html) async =>
    (await _channel.invokeMethod<Uint8List>('htmlToPdf', {'html': html}))!;

/// 弹出系统“保存到”让用户选择位置。用户取消时返回 false。
Future<bool> saveFile(String name, String mime, Uint8List bytes) async =>
    await _channel.invokeMethod<bool>('saveFile', {'name': name, 'mime': mime, 'bytes': bytes}) ?? false;

/// 复制敏感内容：1 分钟后自动清空剪贴板；Android 上在剪贴板预览中隐藏，iOS 上不同步到其他设备。
Future<void> copySensitive(String text) => _channel.invokeMethod('copySensitive', {'text': text});

/// 用系统浏览器打开网页（iOS 上用来打开新版本的下载页）。
Future<void> openUrl(String url) => _channel.invokeMethod('openUrl', {'url': url});
