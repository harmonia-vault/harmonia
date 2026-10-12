// 复用安装包中的应用图标，避免“关于”页与桌面图标各用一套图形。
import 'package:flutter/material.dart';

class AppIcon extends StatelessWidget {
  const AppIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = theme.platform == TargetPlatform.iOS
        ? 'ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon${theme.brightness == Brightness.dark ? '-dark' : ''}.png'
        : 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset(path, width: 48, height: 48, fit: BoxFit.cover, excludeFromSemantics: true),
    );
  }
}
