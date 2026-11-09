// 页面调试的批准请求和正在生效的授权：全部是内存里的合成数据，不访问网络，也不做任何加解密。
import 'dart:convert';

import 'vault.dart';

/// 示例请求：读取（默认来自“个人 Mac”）和写入。
ApprovalRequest debugApproval({bool write = false, String deviceId = 'debug-mac'}) {
  final detail = jsonEncode({
    'kind': write ? 'write' : 'read',
    'deviceId': deviceId,
    'createdAt': 1791792000000,
    if (!write) 'ephPub': 'debug-eph',
    'command': write ? 'harmonia var set' : 'npm run dev -- --port 5173',
    'cwd': '/Users/demo/projects/blog',
    'items': write
        ? [
            {'environmentId': 'debug-env-3', 'name': 'SERVICE_TOKEN', 'vaultId': 'debug-vault-3'},
          ]
        : [
            {'environmentId': 'debug-env-2', 'name': 'LLM_KEY'},
            {'environmentId': 'debug-env-2', 'name': 'MODEL'},
          ],
    if (write)
      'delete': [
        {'environmentId': 'debug-env-3', 'name': 'OLD_SERVICE_URL'},
      ],
  });
  return ApprovalRequest({
    'id': write ? 'debug-approval-write' : 'debug-approval-$deviceId',
    'deviceId': deviceId,
    'detail': detail,
    'payload': write ? '{}' : '',
    'sig': '',
    'createdAt': 1791792000000,
    'expiresAt': DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch,
  });
}

mixin DebugApprovals on Vault {
  void check();

  /// 等待处理的示例请求，以及已经结束的请求（用于“已失效”的状态）。
  final approvals = <ApprovalRequest>[];
  final _ended = <String>{};
  final auths = <AuthorizationInfo>[];

  void resetApprovals() {
    approvals
      ..clear()
      ..add(debugApproval());
    _ended.clear();
    auths
      ..clear()
      ..add(
        AuthorizationInfo({
          'id': 'debug-auth-1',
          'deviceId': 'debug-mac',
          'scope': scopeTerminal,
          'expiresAt': DateTime.now().add(const Duration(minutes: 90)).millisecondsSinceEpoch,
          'items': [
            {'environmentId': 'debug-env-2', 'name': 'LLM_KEY'},
          ],
        }),
      )
      ..add(
        AuthorizationInfo({
          'id': 'debug-auth-2',
          'deviceId': 'debug-mac',
          'scope': scopeAll,
          'expiresAt': 0,
          'items': [
            {'environmentId': 'debug-env-2', 'name': 'MODEL'},
          ],
        }),
      );
  }

  /// 让一个请求失效（电脑上取消或超时）。
  void expireApproval(String id) {
    _ended.add(id);
    approvals.removeWhere((a) => a.id == id);
  }

  void _pending(String id) {
    check();
    if (_ended.contains(id)) throw VaultException('电脑上已经不再等待，这次请求已失效。');
  }

  @override
  Future<List<ApprovalRequest>> pendingApprovals() async {
    check();
    return List.of(approvals);
  }

  @override
  String? approvalProblem(ApprovalRequest a, {int? nowMs}) => null;

  @override
  List<ApprovalWrite> approvalWrites(ApprovalRequest a) => [
    for (final it in a.items) ApprovalWrite(it, {'value': 'demo-new-token-not-a-secret', 'note': '页面调试写入'}),
  ];

  @override
  Future<void> approveRead(ApprovalRequest a, {required String scope, required int expiresAt}) async {
    _pending(a.id);
    approvals.removeWhere((x) => x.id == a.id);
    if (scope == scopeOnce) return;
    auths.add(
      AuthorizationInfo({
        'id': a.id,
        'deviceId': a.deviceId,
        'scope': scope,
        'expiresAt': expiresAt,
        'items': [
          for (final it in a.items) {'environmentId': it.envId, 'name': it.name},
        ],
      }),
    );
  }

  @override
  Future<void> approveWrite(ApprovalRequest a) async {
    _pending(a.id);
    approvals.removeWhere((x) => x.id == a.id);
  }

  @override
  Future<void> rejectApproval(String id) async {
    _pending(id);
    approvals.removeWhere((x) => x.id == id);
  }

  @override
  Future<List<AuthorizationInfo>> authorizations({String? deviceId}) async {
    check();
    return [
      for (final a in auths)
        if (deviceId == null || a.deviceId == deviceId) a,
    ];
  }

  @override
  Future<void> endAuthorization(String id) async {
    check();
    auths.removeWhere((a) => a.id == id);
  }
}
