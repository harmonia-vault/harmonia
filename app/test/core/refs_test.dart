import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/refs.dart';

// 三端共用的展开规则向量（vectors/refs.json）。
void main() {
  final cases = ((jsonDecode(File('../vectors/refs.json').readAsStringSync()) as Map)['cases'] as List)
      .cast<Map<String, dynamic>>();

  test('有向量', () => expect(cases, isNotEmpty));

  for (final c in cases) {
    test(c['name'], () {
      final refs = (c['refs'] as List).map((r) => EnvRef.fromJson((r as Map).cast<String, dynamic>())).toList();
      final vaults = (c['vaults'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
      Iterable<String> names(String id) => vaults[id] ?? const [];
      List<EnvItem> items(String key) =>
          (c[key] as List).map((i) => EnvItem.fromJson((i as Map).cast<String, dynamic>())).toList();
      final got = expandRefs(refs, names);
      expect(got.items, items('items'));
      expect(got.shadowed, items('shadowed'));
      expect(duplicateNames(refs, names), (c['duplicates'] as List).cast<String>());
    });
  }

  group('环境页的变量面板', () {
    const pick = EnvRef('a', 'pick', items: [RefItem('K'), RefItem('T', 'TOKEN')]);
    const all = EnvRef('b', 'all', items: [RefItem('X', 'EX')]);
    String names(List<EnvRef> refs) => jsonEncode(refs.map((r) => r.toJson()).toList());

    test('改名：勾选范围替换名字，全部变量范围只记改了名的，用回原名时去掉', () {
      expect(names(renameInRefs([pick, all], 'a', 'K', 'KEY')), names([const EnvRef('a', 'pick', items: [RefItem('K', 'KEY'), RefItem('T', 'TOKEN')]), all]));
      expect(names(renameInRefs([pick, all], 'a', 'T', null)), names([const EnvRef('a', 'pick', items: [RefItem('K'), RefItem('T')]), all]));
      expect(names(renameInRefs([pick, all], 'b', 'Y', 'WHY')), names([pick, const EnvRef('b', 'all', items: [RefItem('X', 'EX'), RefItem('Y', 'WHY')])]));
      expect(names(renameInRefs([pick, all], 'b', 'X', null)), names([pick, const EnvRef('b', 'all')]));
      expect(names(renameInRefs([pick, all], 'b', 'X', 'EX2')), names([pick, const EnvRef('b', 'all', items: [RefItem('X', 'EX2')])]));
    });

    test('移除：只对勾选范围有效', () {
      expect(names(removeFromRefs([pick, all], 'a', 'T')!), names([const EnvRef('a', 'pick', items: [RefItem('K')]), all]));
      expect(removeFromRefs([pick, all], 'b', 'X'), isNull);
      expect(removeFromRefs([pick, all], 'c', 'X'), isNull);
    });

    test('环境名去掉首尾空白后不区分大小写比较', () {
      expect(envNameTaken(['生产', 'Staging'], ' staging '), isTrue);
      expect(envNameTaken(['生产', 'Staging'], '生产'), isTrue);
      expect(envNameTaken(['生产'], '生产 2'), isFalse);
      expect(envNameTaken([], 'x'), isFalse);
    });
  });
}
