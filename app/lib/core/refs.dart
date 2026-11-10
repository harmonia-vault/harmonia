// 环境对变量库的引用：展开最终名字、找出被遮住的同名变量、保存前检查重名
// （docs/protocol.md 3.2，设计文档 17.1）。规则三端一致，见 vectors/refs.json。

/// 引用里的一个变量：[name] 是变量库里的原名，[as] 是在环境里的新名字（null 表示不改名）。
class RefItem {
  const RefItem(this.name, [this.as]);
  final String name;
  final String? as;

  factory RefItem.fromJson(Map<String, dynamic> j) {
    final as = j['as'] as String?;
    return RefItem(j['name'] as String, as == null || as.isEmpty ? null : as);
  }

  Map<String, dynamic> toJson() => {'name': name, if (as != null) 'as': as};
}

/// 环境对一个变量库的引用。[scope] 是 all（全部变量）或 pick（勾选的变量）；[missing] 表示变量库已被删除。
class EnvRef {
  const EnvRef(this.vaultId, this.scope, {this.items = const [], this.missing = false});
  final String vaultId;
  final String scope;
  final List<RefItem> items;
  final bool missing;

  bool get all => scope == 'all';

  factory EnvRef.fromJson(Map<String, dynamic> j) => EnvRef(
    j['vaultId'] as String,
    j['scope'] as String,
    items: ((j['items'] as List?) ?? []).map((i) => RefItem.fromJson((i as Map).cast<String, dynamic>())).toList(),
    missing: j['missing'] as bool? ?? false,
  );

  /// 提交给服务端的形式（不含 missing）。
  Map<String, dynamic> toJson() => {
    'vaultId': vaultId,
    'scope': scope,
    'items': items.map((i) => i.toJson()).toList(),
  };

  /// 变量库里的 [source] 在这条引用下的名字。
  String nameOf(String source) {
    for (final i in items) {
      if (i.name == source && i.as != null) return i.as!;
    }
    return source;
  }
}

/// 展开后的一项：[name] 是环境里的名字，[source] 是变量库里的原名。
class EnvItem {
  const EnvItem(this.name, this.vaultId, this.source);
  final String name;
  final String vaultId;
  final String source;

  factory EnvItem.fromJson(Map<String, dynamic> j) =>
      EnvItem(j['name'] as String, j['vaultId'] as String, j['source'] as String);

  Map<String, dynamic> toJson() => {'name': name, 'vaultId': vaultId, 'source': source};

  @override
  bool operator ==(Object other) =>
      other is EnvItem && other.name == name && other.vaultId == vaultId && other.source == source;

  @override
  int get hashCode => Object.hash(name, vaultId, source);

  @override
  String toString() => '$name($vaultId/$source)';
}

/// 变量库里现存的变量名；不存在的变量库返回空。
typedef VaultNames = Iterable<String> Function(String vaultId);

List<String> _sorted(Iterable<String> names) => names.toSet().toList()..sort();

/// 按引用顺序展开最终名字：勾选只取存在的变量（按勾选顺序），全部变量按名字排序。
/// 同名时排在前面的优先，其余放进 shadowed。
({List<EnvItem> items, List<EnvItem> shadowed}) expandRefs(List<EnvRef> refs, VaultNames names) {
  final items = <EnvItem>[];
  final shadowed = <EnvItem>[];
  final seen = <String>{};
  for (final r in refs) {
    final existing = names(r.vaultId).toSet();
    final sources = r.all ? _sorted(existing) : r.items.map((i) => i.name).where(existing.contains);
    for (final source in sources) {
      final item = EnvItem(r.nameOf(source), r.vaultId, source);
      if (seen.add(item.name)) {
        items.add(item);
      } else {
        shadowed.add(item);
      }
    }
  }
  return (items: items, shadowed: shadowed);
}

/// 保存环境前的重名检查：勾选的变量不论是否存在都算，全部变量按现存的算。
/// 返回重复的最终名字，按出现顺序，不重复列出。
List<String> duplicateNames(List<EnvRef> refs, VaultNames names) {
  final seen = <String>{};
  final dup = <String>[];
  for (final r in refs) {
    final sources = r.all ? _sorted(names(r.vaultId)) : r.items.map((i) => i.name);
    for (final source in sources) {
      final name = r.nameOf(source);
      if (!seen.add(name) && !dup.contains(name)) dup.add(name);
    }
  }
  return dup;
}

/// 环境页的变量面板改名（设计文档 19.4）：把来自 [vaultId] 的 [source] 在环境里的名字改为 [as]，
/// null 表示用回原名。返回新的引用列表，其余引用不变。
List<EnvRef> renameInRefs(List<EnvRef> refs, String vaultId, String source, String? as) => [
  for (final r in refs)
    if (r.vaultId != vaultId)
      r
    else
      EnvRef(
        r.vaultId,
        r.scope,
        missing: r.missing,
        items: r.all
            // 全部变量范围下只记改了名的变量。
            ? [
                for (final i in r.items)
                  if (i.name != source) i,
                if (as != null) RefItem(source, as),
              ]
            : [for (final i in r.items) i.name == source ? RefItem(source, as) : i],
      ),
];

/// 从环境里移除来自 [vaultId] 的 [source]：只对勾选范围的引用有效；来自全部变量的引用返回 null，
/// 要单独移除需先在编辑引用里改为勾选（设计文档 19.4）。
List<EnvRef>? removeFromRefs(List<EnvRef> refs, String vaultId, String source) {
  final ref = refs.where((r) => r.vaultId == vaultId).firstOrNull;
  if (ref == null || ref.all) return null;
  return [
    for (final r in refs)
      r.vaultId == vaultId
          ? EnvRef(r.vaultId, r.scope, missing: r.missing, items: [for (final i in r.items) if (i.name != source) i])
          : r,
  ];
}

/// 环境名是否和 [others] 里的某个重复：去掉首尾空白后不区分大小写比较（设计文档 19.2）。
bool envNameTaken(Iterable<String> others, String name) {
  final key = name.trim().toLowerCase();
  return others.any((n) => n.trim().toLowerCase() == key);
}
