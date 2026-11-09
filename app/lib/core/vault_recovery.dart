// 管理设备轮换恢复码：全部库钥与账号根密钥重新封装给新恢复钥。
part of 'vault.dart';

/// 一次恢复码轮换的结果；网络中断时可凭 [key] 查询。
class RotationAttempt {
  RotationAttempt(this.key, this.generation);
  final String key;
  final int generation;
}

mixin VaultRecovery {
  HCrypto get crypto;
  ApiClient? get api;
  SyncCache get cache;
  List<VaultInfo> get vaults;
  SignKey _root();
  Uint8List _vaultKey(String vaultId);
  Map<String, dynamic> _envelope(String vaultId, int keyVersion, String recipient, Uint8List boxPub, Uint8List key);
  Future<void> sync({bool full = false});

  /// 用新恢复码轮换。全部库钥与账号根密钥重新封装给新恢复钥，提交成功后旧恢复码失效。
  Future<RotationAttempt> rotateRecovery(Uint8List newCode, {String? key}) async {
    final r = _root();
    final rec = crypto.deriveRecovery(newCode);
    final generation = int.parse((cache.manager!['recovery'] as Map)['generation'] as String) + 1;
    final rootSealed = crypto.seal(r.seed, rec.box.pub);
    final attempt = RotationAttempt(key ?? crypto.newId(), generation);
    final body = <String, dynamic>{
      'idempotencyKey': attempt.key,
      'generation': '$generation',
      'signPub': b64(rec.sign.pub),
      'boxPub': b64(rec.box.pub),
      'rootEnvelope': {
        'sealed': b64(rootSealed),
        'sig': b64(crypto.sign(rec.sign, rootRecoveryMsg(generation, rootSealed))),
      },
      'envelopes': [
        for (final v in vaults)
          _envelope(v.id, v.keyVersion, 'recovery', rec.box.pub, _vaultKey(v.id))..remove('recipient'),
      ],
    };
    await api!.device('POST', '/api/v1/recovery/rotate', body: body);
    await sync();
    return attempt;
  }

  /// 查询一次轮换是否已在服务器生效（网络中断后使用）。
  Future<bool> rotationCompleted(String key) async {
    final res = await api!.device('GET', '/api/v1/recovery/rotate/$key');
    final done = res['state'] == 'complete';
    if (done) await sync();
    return done;
  }
}
