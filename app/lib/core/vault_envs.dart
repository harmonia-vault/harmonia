// 管理设备编辑环境：预览最终名字、新建、保存和删除（设计文档 17.1、17.2）。
part of 'vault.dart';

mixin VaultEnvironments {
  HCrypto get crypto;
  ApiClient? get api;
  List<DeviceInfo> get devices;
  List<String> variableNames(String vaultId);
  List<EnvDef> get envDefs;
  SignKey _root();
  Uint8List _verifiedBoxPub(String deviceId, String kind, String signPub, String boxPub, String cert);
  List<Map<String, dynamic>> _sealVaults(Iterable<String> vaultIds, String recipient, Uint8List boxPub);
  Future<void> sync({bool full = false});

  /// 编辑环境时的预览：最终名字、被遮住的同名变量，以及保存时会被拒绝的重名。
  ({List<EnvItem> items, List<EnvItem> shadowed, List<String> duplicates}) previewEnvironment(List<EnvRef> refs) {
    final r = expandRefs(refs, variableNames);
    return (items: r.items, shadowed: r.shadowed, duplicates: duplicateNames(refs, variableNames));
  }

  void _checkRefs(List<EnvRef> refs) {
    final dup = duplicateNames(refs, variableNames);
    if (dup.isNotEmpty) throw VaultException('环境里有重名的变量：${dup.join('、')}。请给其中一个改名，或取消勾选。');
  }

  /// 环境名不能和其他环境重复（设计文档 19.2）。服务端同样检查，这里先给出同样的提示，免得白跑一次请求。
  void checkEnvName(String name, {String? exceptId}) {
    if (envNameTaken([for (final e in envDefs) if (e.id != exceptId) e.name], name)) {
      throw VaultException('已经有名为“${name.trim()}”的环境，请换一个名字。');
    }
  }

  /// 新建环境。新环境还没有授权给任何设备，不需要封装。返回环境 ID。
  Future<String> createEnvironment(String name, List<EnvRef> refs) async {
    _root();
    checkEnvName(name);
    _checkRefs(refs);
    final id = crypto.newId();
    await api!.device(
      'POST',
      '/api/v1/environments',
      body: {'id': id, 'name': name.trim(), 'refs': refs.map((r) => r.toJson()).toList()},
    );
    await sync();
    return id;
  }

  /// 整体替换环境的名字和引用。被授权这个环境、开启了本机解密的设备，在同一个请求里附上引用到的变量库的封装
  /// （先校验设备证书），服务端据此补上新引用的、删掉不再用到的（设计文档 17.2）。
  Future<void> saveEnvironment(String id, String name, List<EnvRef> refs) async {
    _root();
    checkEnvName(name, exceptId: id);
    _checkRefs(refs);
    final vaultIds = refs.where((r) => !r.missing).map((r) => r.vaultId);
    final envelopes = <Map<String, dynamic>>[];
    for (final d in devices) {
      if (!d.grants.any((g) => g.envId == id && g.localDecrypt)) continue;
      envelopes.addAll(_sealVaults(vaultIds, d.id, _verifiedBoxPub(d.id, d.kind, d.signPub, d.boxPub, d.cert)));
    }
    await api!.device(
      'PUT',
      '/api/v1/environments/$id',
      body: {'name': name.trim(), 'refs': refs.map((r) => r.toJson()).toList(), 'envelopes': envelopes},
    );
    await sync();
  }

  /// 删除环境和设备对它的授权，变量库不受影响。
  Future<void> deleteEnvironment(String id) async {
    await api!.device('DELETE', '/api/v1/environments/$id');
    await sync();
  }
}
