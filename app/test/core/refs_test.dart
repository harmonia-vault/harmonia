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
}
