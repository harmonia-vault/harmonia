// 每个界面会话显式携带身份服务，调试路由不能取得真实账号的身份服务。
import 'package:flutter/widgets.dart';

import '../app/identity.dart';

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.identity, this.simulated = false, required super.child});
  final Identity identity;
  final bool simulated;

  static AppScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!;
  static bool isSimulated(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.simulated ?? false;

  @override
  bool updateShouldNotify(AppScope oldWidget) => identity != oldWidget.identity || simulated != oldWidget.simulated;
}
