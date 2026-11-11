// 窗口几何只决定内容放置，不读取账号或设备型号。
import 'dart:math' as math;

enum NavigationEdge { bottom, left, right }

typedef LayoutRect = ({double left, double top, double width, double height});
typedef LayoutInsets = ({double left, double top, double right, double bottom});

const noLayoutInsets = (left: 0.0, top: 0.0, right: 0.0, bottom: 0.0);

LayoutRect layoutRect(double left, double top, double width, double height) =>
    (left: left, top: top, width: width, height: height);

class WindowLayout {
  WindowLayout({
    required this.width,
    required this.height,
    this.insets = noLayoutInsets,
    this.keyboard = 0,
    this.fold,
    this.occlusions = const [],
    NavigationEdge? navigation,
    bool? regularWidth,
  }) : navigation = navigation ?? (width > height ? NavigationEdge.right : NavigationEdge.bottom),
       regularWidth = regularWidth ?? width >= 720;

  final double width, height, keyboard;
  final LayoutInsets insets;
  final NavigationEdge navigation;
  final bool regularWidth;
  final LayoutRect? fold;
  final List<LayoutRect> occlusions;

  bool get verticalNavigation => navigation != NavigationEdge.bottom;
  bool get book => fold != null && fold!.height > fold!.width;
  bool get tabletop => fold != null && !book;
  bool get twoPanes => book || regularWidth && width > height && width - navigationWidth >= 720;
  bool get compactNavigation => verticalNavigation && height - navigationTop - navigationBottom < 420;
  double get navigationWidth => verticalNavigation ? 84 : 0;

  double get navigationTop {
    var top = insets.top + 12;
    for (final area in _navigationOcclusions) {
      if (area.top < height / 2) top = math.max(top, area.top + area.height + 12);
    }
    return top;
  }

  double get navigationBottom {
    var bottom = math.max(insets.bottom, keyboard) + 12;
    for (final area in _navigationOcclusions) {
      if (area.top >= height / 2) bottom = math.max(bottom, height - area.top + 12);
    }
    return bottom;
  }

  Iterable<LayoutRect> get _navigationOcclusions => occlusions.where(
    (area) => navigation == NavigationEdge.left ? area.left < 84 : area.left + area.width > width - 84,
  );

  LayoutRect get usable => layoutRect(
    insets.left,
    insets.top,
    math.max(0, width - insets.left - insets.right),
    math.max(0, height - insets.top - math.max(insets.bottom, keyboard)),
  );

  /// 实际折叠区将可用窗口分成两个区域，坐标沿用窗口坐标系。
  List<LayoutRect> get regions {
    final area = usable, division = fold;
    if (division == null) return [area];
    if (book) {
      final start = division.left.clamp(area.left, area.left + area.width);
      final end = (division.left + division.width).clamp(area.left, area.left + area.width);
      return [
        layoutRect(area.left, area.top, start - area.left, area.height),
        layoutRect(end, area.top, area.left + area.width - end, area.height),
      ];
    }
    final start = division.top.clamp(area.top, area.top + area.height);
    final end = (division.top + division.height).clamp(area.top, area.top + area.height);
    return [
      layoutRect(area.left, area.top, area.width, start - area.top),
      layoutRect(area.left, end, area.width, area.top + area.height - end),
    ];
  }

  LayoutRect get master {
    if (book) return layoutRect(0, 0, fold!.left, height);
    return layoutRect(0, 0, ((width - navigationWidth) * .32).clamp(240, 320), height);
  }

  LayoutRect get detail {
    if (book) {
      final left = fold!.left + fold!.width;
      return layoutRect(left, 0, width - left, height);
    }
    if (!twoPanes) return layoutRect(0, 0, width, height);
    final first = master;
    return layoutRect(first.width, 0, width - first.width, height);
  }

  LayoutRect get tabletopControls {
    final top = fold!.top + fold!.height;
    return layoutRect(0, top, width, height - top);
  }

  /// 面板优先位于右半区或桌面式下半区；键盘或遮挡占满该区时选择仍可操作的区域。
  LayoutRect get presentation {
    final choices = regions;
    var area = choices.last;
    if (area.width < 180 || area.height < 160) {
      area = choices.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
    }
    for (final obstruction in occlusions) {
      final left = math.max(area.left, obstruction.left);
      final right = math.min(area.left + area.width, obstruction.left + obstruction.width);
      final top = math.max(area.top, obstruction.top);
      final bottom = math.min(area.top + area.height, obstruction.top + obstruction.height);
      if (left >= right || top >= bottom) continue;
      final above = layoutRect(area.left, area.top, area.width, top - area.top);
      final below = layoutRect(area.left, bottom, area.width, area.top + area.height - bottom);
      area = above.height >= below.height ? above : below;
    }
    return area;
  }
}
