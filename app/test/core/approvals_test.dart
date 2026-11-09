import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/api.dart';
import 'package:harmonia/core/approval_choice.dart';
import 'package:harmonia/core/crypto.dart';
import 'package:harmonia/core/models.dart';
import 'package:harmonia/core/store.dart';
import 'package:harmonia/core/vault.dart';

/// 记下请求，不访问网络。
class RecordingApi extends ApiClient {
  RecordingApi() : super('https://example.invalid');
  final calls = <(String, String, Object?)>[];
  @override
  Future<Map<String, dynamic>> device(String method, String path, {Object? body, Map<String, String>? headers}) async {
    calls.add((method, path, body));
    return {};
  }
}

/// 解密结果直接给定的保险库：变量库 v 里有 OPENAI_API_KEY、MODEL、RO。
class TestVault extends Vault {
  TestVault(HCrypto crypto) : super(crypto, MemoryStore(), MemoryStore());
  @override
  Map<String, VarEntry> entries(String vaultId) => {
    'OPENAI_API_KEY': const VarEntry('sk-1', note: '备注'),
    'MODEL': const VarEntry('m'),
    'RO': const VarEntry('ro'),
  };
}

void main() {
  late HCrypto crypto;
  late TestVault vault;
  late SignKey dev;
  late RecordingApi api;

  setUpAll(() async => crypto = await HCrypto.init());

  setUp(() {
    final root = crypto.signKeyFromSeed(crypto.random(32));
    dev = crypto.signKeyFromSeed(crypto.random(32));
    final devBox = crypto.boxKeyFromSeed(crypto.random(32));
    api = RecordingApi();
    vault = TestVault(crypto)
      ..api = api
      ..root = root
      ..boxKey = crypto.boxKeyFromSeed(crypto.random(32))
      ..config = LocalConfig(
        server: 'https://example.invalid',
        accountId: 'acc',
        email: 'demo@example.invalid',
        rootPub: b64(root.pub),
        deviceId: 'phone',
        deviceName: '示例手机',
        signSeed: '',
        boxSeed: '',
      );
    final cert = b64(crypto.sign(root, deviceCertMsg('pc', 'client', b64(dev.pub), b64(devBox.pub))));
    const items = [
      EnvItem('LLM_KEY', 'v', 'OPENAI_API_KEY', true),
      EnvItem('MODEL', 'v', 'MODEL', true),
      EnvItem('RO', 'v2', 'RO', false),
    ];
    vault.cache
      ..self = {'kind': 'manager'}
      ..environments = [
        Environment('env', '生产', 'rw', 0, items: items),
        Environment('local', '本机', 'rw', 0, items: items),
      ]
      ..variables = {
        'v': {'OPENAI_API_KEY': CachedVariable('', 1), 'MODEL': CachedVariable('', 1)},
      }
      ..manager = {
        'vaults': [
          {'id': 'v', 'name': '共享', 'keyVersion': '1'},
        ],
        'environments': [
          {
            'id': 'env',
            'name': '生产',
            'refs': [
              {
                'vaultId': 'v',
                'scope': 'all',
                'writable': true,
                'items': [
                  {'name': 'OPENAI_API_KEY', 'as': 'LLM_KEY'},
                ],
              },
            ],
          },
        ],
        'devices': [
          {
            'id': 'pc',
            'name': '电脑',
            'platform': 'darwin',
            'kind': 'client',
            'signPub': b64(dev.pub),
            'boxPub': b64(devBox.pub),
            'cert': cert,
            'createdAt': 0,
            'lastSeenAt': 0,
            'grants': [
              {'environmentId': 'env', 'role': 'rw', 'expiresAt': 0, 'localDecrypt': false},
              {'environmentId': 'local', 'role': 'rw', 'expiresAt': 0, 'localDecrypt': true},
            ],
          },
        ],
      };
  });

  ApprovalRequest request(Map<String, dynamic> detail, {String payload = '', String id = 'req-1', SignKey? signer}) {
    final raw = jsonEncode({
      'kind': 'read',
      'deviceId': 'pc',
      'createdAt': 0,
      'command': 'npm test',
      'cwd': '/',
      ...detail,
    });
    return ApprovalRequest({
      'id': id,
      'deviceId': 'pc',
      'detail': raw,
      'payload': payload,
      'sig': b64(crypto.sign(signer ?? dev, approvalRequestMsg(id, 'pc', raw, payload))),
      'createdAt': 0,
      'expiresAt': 0,
    });
  }

  Map<String, String> item(String env, String name, [String? vaultId]) => {
    'environmentId': env,
    'name': name,
    'vaultId': ?vaultId,
  };

  test('按自己的数据核对请求', () {
    final ok = request({
      'items': [item('env', 'LLM_KEY')],
    });
    expect(vault.approvalProblem(ok), isNull);
    expect(ok.code, approvalCode(ok.detail));
    final forged = request({
      'items': [item('env', 'LLM_KEY')],
    }, signer: crypto.signKeyFromSeed(crypto.random(32)));
    expect(vault.approvalProblem(forged), contains('签名'));
    expect(
      vault.approvalProblem(
        request({
          'items': [item('local', 'MODEL')],
        }),
      ),
      contains('本机解密'),
    );
    expect(
      vault.approvalProblem(
        request({
          'items': [item('env', 'NOPE')],
        }),
      ),
      contains('没有 NOPE'),
    );
    Map<String, dynamic> write(List<Map<String, String>> items, [List<Map<String, String>> del = const []]) => {
      'kind': 'write',
      'items': items,
      'delete': del,
    };
    expect(vault.approvalProblem(request(write([item('env', 'MODEL')], [item('env', 'LLM_KEY')]))), isNull);
    expect(vault.approvalProblem(request(write([item('env', 'NEW_ONE', 'v')]))), isNull);
    expect(vault.approvalProblem(request(write([item('env', 'MODEL', 'v')]))), contains('不能'));
    expect(vault.approvalProblem(request(write([item('env', 'RO')]))), contains('不允许修改'));
    expect(vault.approvalProblem(request(write([], [item('env', 'RO')]))), contains('不允许删除'));
  });

  test('批准读取：只交出请求的变量，加密给临时公钥并由 root 签名', () async {
    final eph = crypto.boxKeyFromSeed(crypto.random(32));
    final a = request({
      'ephPub': b64(eph.pub),
      'items': [item('env', 'LLM_KEY')],
    });
    await vault.approveRead(a, scope: scopeTerminal, expiresAt: 99);
    final (method, path, body) = api.calls.single;
    expect((method, path), ('POST', '/api/v1/approvals/req-1/approve'));
    final b = body! as Map<String, dynamic>;
    final sealed = unb64(b['sealed'] as String);
    expect(crypto.verify(vault.root!.pub, approvalGrantMsg('req-1', sealed), unb64(b['sig'] as String)), isTrue);
    final grant = jsonDecode(utf8.decode(crypto.open(eph, sealed))) as Map<String, dynamic>;
    expect(grant['requestId'], 'req-1');
    expect(grant['scope'], 'terminal');
    expect(grant['expiresAt'], 99);
    expect(grant['values'], [
      {
        'environmentId': 'env',
        'name': 'LLM_KEY',
        'vaultId': 'v',
        'source': 'OPENAI_API_KEY',
        'plain': {'value': 'sk-1', 'note': '备注'},
      },
    ]);
  });

  test('写入内容：只认加密给这台手机、请求 ID 和变量都一致的', () {
    Uint8List seal(Map<String, dynamic> content) => crypto.seal(utf8.encode(jsonEncode(content)), vault.boxKey!.pub);
    ApprovalRequest write(Map<String, dynamic> content, {String manager = 'phone'}) => request(
      {
        'kind': 'write',
        'items': [item('env', 'NEW_ONE', 'v')],
      },
      payload: jsonEncode({
        'sealed': [
          {'managerId': manager, 'sealed': b64(seal(content))},
        ],
      }),
    );
    final good = {
      'requestId': 'req-1',
      'set': [
        {
          ...item('env', 'NEW_ONE', 'v'),
          'plain': {'value': 'x'},
        },
      ],
    };
    final w = vault.approvalWrites(write(good)).single;
    expect((w.item.name, w.item.vaultId, w.plain['value']), ('NEW_ONE', 'v', 'x'));
    expect(() => vault.approvalWrites(write(good, manager: 'other')), throwsA(isA<VaultException>()));
    expect(() => vault.approvalWrites(write({...good, 'requestId': 'other'})), throwsA(isA<VaultException>()));
    expect(
      () => vault.approvalWrites(
        write({
          'requestId': 'req-1',
          'set': [
            {
              ...item('env', 'MODEL'),
              'plain': {'value': 'x'},
            },
          ],
        }),
      ),
      throwsA(isA<VaultException>()),
    );
    // 新增变量必须带值。
    expect(
      () => vault.approvalWrites(
        write({
          'requestId': 'req-1',
          'set': [
            {
              ...item('env', 'NEW_ONE', 'v'),
              'plain': {'note': 'x'},
            },
          ],
        }),
      ),
      throwsA(isA<VaultException>()),
    );
  });

  test('有效时长和授权范围的选择', () {
    expect(ApprovalDuration.presets.map((d) => d.label), ['仅这一次', '30 分钟', '2 小时', '8 小时', '长期']);
    expect(ApprovalDuration.of(90).label, '90 分钟');
    expect(ApprovalDuration.of(1440 * 3).label, '3 天');
    expect(() => ApprovalDuration.of(0), throwsArgumentError);
    expect(() => ApprovalDuration.of(ApprovalDuration.maxMinutes + 1), throwsArgumentError);
    expect(ApprovalDuration.of(30).expiresAt(1000), 1000 + 30 * 60000);
    expect(ApprovalDuration.forever.expiresAt(1000), 0);
    final c = ApprovalChoice(ApprovalDuration.of(120), 'all');
    expect(ApprovalChoice.decode(c.encode()).encode(), c.encode());
    expect(ApprovalChoice.decode(null).encode(), ApprovalChoice.initial.encode());
    expect(ApprovalChoice.decode('bad').submitScope, 'once');
    expect(ApprovalChoice(ApprovalDuration.forever, 'terminal').forPlatform('windows').scope, 'all');
    expect(ApprovalChoice(ApprovalDuration.of(30), 'terminal').submitScope, 'terminal');
  });
}
