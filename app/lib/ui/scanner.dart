// 扫二维码：相机取景框，以及“连接服务器”时扫服务器首页上的二维码。
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/api.dart';
import 'theme.dart';
import 'widgets.dart';

/// 相机取景框：识别到二维码时把内容交给 [onCode]。同一个二维码在镜头里会被反复识别，由调用方去重。
class QrScannerView extends StatefulWidget {
  const QrScannerView({super.key, required this.onCode, required this.blocked});
  final void Function(String raw) onCode;

  /// 相机打不开时显示的说明，要告诉用户还能怎么办。
  final String blocked;

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView> {
  final _scanner = MobileScannerController(formats: [BarcodeFormat.qrCode]);

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: AspectRatio(
      aspectRatio: 1,
      child: MobileScanner(
        controller: _scanner,
        errorBuilder: (context, error) => Container(
          color: context.palette.card,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(Space.xl),
          child: Text(widget.blocked, textAlign: TextAlign.center),
        ),
        onDetect: (capture) {
          final raw = capture.barcodes.firstOrNull?.rawValue;
          if (raw != null) widget.onCode(raw);
        },
      ),
    ),
  );
}

/// 扫服务器首页上的二维码；扫到后带着服务器地址返回上一页。
class ScanServerPage extends StatefulWidget {
  const ScanServerPage({super.key});
  @override
  State<ScanServerPage> createState() => _ScanServerPageState();
}

class _ScanServerPageState extends State<ScanServerPage> {
  bool _done = false;

  /// 上一个不认识的二维码：它还在镜头里时不重复提示。
  String? _rejected;

  void _found(String raw) {
    if (_done || raw == _rejected) return;
    try {
      final server = serverFromQr(raw);
      _done = true;
      Navigator.pop(context, server);
    } on ApiException catch (e) {
      _rejected = raw;
      toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫码连接服务器')),
    body: ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        Text(tidy('在电脑的浏览器里打开服务器地址，扫描页面上的二维码。')),
        const SizedBox(height: Space.md),
        QrScannerView(
          onCode: _found,
          blocked: '无法打开相机。请在系统设置中允许 Harmonia 使用相机，或返回上一页手动填写服务器地址。',
        ),
      ],
    ),
  );
}
