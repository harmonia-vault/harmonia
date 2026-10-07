// 平台通道上的文件与剪贴板能力（实现见 Android MainActivity / HtmlPdf）。
import 'package:flutter/services.dart';

const _channel = MethodChannel('harmonia/platform');

/// 用系统网页引擎把 HTML 排版成 A4 PDF。
Future<Uint8List> htmlToPdf(String html) async =>
    (await _channel.invokeMethod<Uint8List>('htmlToPdf', {'html': html}))!;

/// 弹出系统“保存到”让用户选择位置。用户取消时返回 false。
Future<bool> saveFile(String name, String mime, Uint8List bytes) async =>
    await _channel.invokeMethod<bool>('saveFile', {'name': name, 'mime': mime, 'bytes': bytes}) ?? false;

/// 复制敏感内容：剪贴板预览中隐藏，1 分钟后自动清空剪贴板。
Future<void> copySensitive(String text) => _channel.invokeMethod('copySensitive', {'text': text});
