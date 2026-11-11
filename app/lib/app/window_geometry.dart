// iOS 提供当前视图的保留区域，Android 的折叠信息由 Flutter 的 MediaQuery 提供。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/window_layout.dart';

class WindowGeometry extends ChangeNotifier {
  static const _channel = EventChannel('harmonia/layout');
  NavigationEdge? navigation;
  bool? regularWidth;
  double width = 0, height = 0;
  LayoutRect? fold;
  List<LayoutRect> occlusions = const [];
  late final _subscription = _channel.receiveBroadcastStream().listen(_update);

  void start() => _subscription;

  void _update(Object? event) {
    final data = (event as Map).cast<String, dynamic>();
    width = (data['width'] as num).toDouble();
    height = (data['height'] as num).toDouble();
    navigation = switch (data['edge']) {
      'left' => NavigationEdge.left,
      'right' => NavigationEdge.right,
      'bottom' => NavigationEdge.bottom,
      _ => null,
    };
    regularWidth = data['regularWidth'] as bool?;
    LayoutRect rect(dynamic value) {
      final box = value as List;
      return layoutRect(
        (box[0] as num).toDouble(),
        (box[1] as num).toDouble(),
        (box[2] as num).toDouble(),
        (box[3] as num).toDouble(),
      );
    }

    fold = data['fold'] == null ? null : rect(data['fold']);
    occlusions = [for (final box in data['occlusions'] as List) rect(box)];
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
