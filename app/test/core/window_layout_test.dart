import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/window_layout.dart';

void main() {
  test('侧边相机占用工具区后收起导航，另一侧相机不影响当前导航', () {
    final camera = layoutRect(630, 210, 48, 46);
    final right = WindowLayout(width: 678, height: 466, occlusions: [camera]);
    expect(right.navigationTop, 268);
    expect(right.compactNavigation, isTrue);
    final left = WindowLayout(width: 678, height: 466, navigation: NavigationEdge.left, occlusions: [camera]);
    expect(left.navigationTop, 12);
    expect(left.compactNavigation, isFalse);
  });
  test('普通窗口按可用空间切换分栏，横竖导航独立于分栏', () {
    final narrow = WindowLayout(width: 420, height: 860);
    expect(narrow.twoPanes, isFalse);
    expect(narrow.navigation, NavigationEdge.bottom);
    final wide = WindowLayout(width: 980, height: 660);
    expect(wide.twoPanes, isTrue);
    expect(wide.navigation, NavigationEdge.right);
    expect(wide.master.width + wide.detail.width, 980);
    expect(wide.detail.left, wide.master.width);
  });

  test('内屏竖向使用单栏和水平导航，横向有足够内容宽度才显示双栏', () {
    final inner = WindowLayout(width: 669, height: 951, regularWidth: true, navigation: NavigationEdge.bottom);
    expect(inner.twoPanes, isFalse);
    expect(inner.verticalNavigation, isFalse);
    final compact = WindowLayout(width: 669, height: 951, regularWidth: false);
    expect(compact.twoPanes, isFalse);
    final crowded = WindowLayout(width: 790, height: 669, regularWidth: true);
    expect(crowded.twoPanes, isFalse);
    final landscape = WindowLayout(width: 951, height: 669, regularWidth: true);
    expect(landscape.twoPanes, isTrue);
  });

  test('分屏边缘服从当前窗口的信息，不从左右安全区猜测', () {
    final left = WindowLayout(width: 476, height: 669, navigation: NavigationEdge.left);
    final right = WindowLayout(width: 476, height: 669, navigation: NavigationEdge.right);
    expect(left.navigation, NavigationEdge.left);
    expect(right.navigation, NavigationEdge.right);
    expect(left.twoPanes, isFalse);
    expect(right.twoPanes, isFalse);
    expect(WindowLayout(width: 678, height: 360, navigation: NavigationEdge.right).compactNavigation, isTrue);
  });

  test('书本式分栏以真实折叠区为界，面板不会跨越折叠区', () {
    final layout = WindowLayout(
      width: 1000,
      height: 700,
      fold: layoutRect(492, 0, 16, 700),
      navigation: NavigationEdge.right,
    );
    expect(layout.twoPanes, isTrue);
    expect(layout.master, layoutRect(0, 0, 492, 700));
    expect(layout.detail, layoutRect(508, 0, 492, 700));
    expect(layout.presentation.left, 508);
    expect(layout.presentation.width, 492);
  });

  test('竖屏半展开保持普通分栏，面板仍完整位于折叠区下方', () {
    final layout = WindowLayout(width: 700, height: 1000, fold: layoutRect(0, 480, 700, 20));
    expect(layout.tabletop, isTrue);
    expect(layout.twoPanes, isFalse);
    expect(layout.detail, layoutRect(0, 0, 700, 1000));
    expect(layout.tabletopControls, layoutRect(0, 500, 700, 500));
    expect(layout.presentation.top, 500);
  });

  test('键盘覆盖桌面式下半区时面板进入上方可用区', () {
    final layout = WindowLayout(width: 700, height: 1000, keyboard: 470, fold: layoutRect(0, 480, 700, 20));
    expect(layout.presentation, layoutRect(0, 0, 700, 480));
  });

  test('各边安全区独立扣除，面板同时避开键盘与相机', () {
    final layout = WindowLayout(
      width: 900,
      height: 700,
      keyboard: 260,
      insets: (left: 12, top: 48, right: 84, bottom: 34),
      occlusions: [layoutRect(12, 48, 120, 44)],
    );
    expect(layout.usable, layoutRect(12, 48, 804, 392));
    expect(layout.presentation, layoutRect(12, 92, 804, 348));
  });

  test('只有中央分界线而没有实体宽度时仍保持两侧布局', () {
    final layout = WindowLayout(width: 840, height: 700, fold: layoutRect(420, 0, 0, 700));
    expect(layout.book, isTrue);
    expect(layout.master.width, 420);
    expect(layout.detail.left, 420);
  });
}
