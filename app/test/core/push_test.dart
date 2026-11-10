import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/api.dart';
import 'package:harmonia/core/push.dart';
import 'package:harmonia/core/store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeDevice implements PushDevice {
  PushPermission perm = PushPermission.granted;
  PushToken? tok = const PushToken('tok-1');
  int requests = 0;
  bool opened = false;
  @override
  Future<PushPermission> permission() async => perm;
  @override
  Future<bool> requestPermission() async {
    requests++;
    perm = PushPermission.granted;
    return true;
  }

  @override
  Future<PushToken?> token() async => tok;
  @override
  Future<void> openSettings() async {}
  @override
  Future<bool> takeOpened() async {
    final o = opened;
    opened = false;
    return o;
  }
}

class FakeRelay implements PushRelay {
  final live = <String, String>{}; // 句柄 → 令牌
  int registered = 0, confirmed = 0;
  final removed = <String>[];
  bool down = false;
  void _net() {
    if (down) throw ApiException(0, 'network', '无法连接');
  }

  @override
  Future<String> register(String platform, PushToken token) async {
    _net();
    final h = 'h${++registered}';
    live[h] = token.token;
    return h;
  }

  @override
  Future<bool> confirm(String handle, PushToken token) async {
    _net();
    confirmed++;
    if (!live.containsKey(handle)) return false;
    live[handle] = token.token;
    return true;
  }

  @override
  Future<void> remove(String handle) async {
    _net();
    removed.add(handle);
    live.remove(handle);
  }
}

class FakeInstance implements PushInstance {
  bool allows = true;
  bool down = false;
  String? handle;
  int puts = 0;
  @override
  Future<bool> allowsPush() async {
    if (down) throw ApiException(0, 'network', '无法连接');
    return allows;
  }

  @override
  Future<void> setHandle(String h) async {
    if (!allows) throw ApiException(403, 'forbidden', '这台服务器关闭了后台通知');
    puts++;
    handle = h;
  }

  @override
  Future<void> clearHandle() async => handle = null;
}

void main() {
  late FakeDevice device;
  late FakeRelay relay;
  late FakeInstance instance;
  late MemoryStore store;
  late DateTime now;
  PushRegistrar make() =>
      PushRegistrar(device: device, relay: relay, store: store, platform: 'android', now: () => now);

  setUp(() {
    device = FakeDevice();
    relay = FakeRelay();
    instance = FakeInstance();
    store = MemoryStore();
    now = DateTime(2026, 11, 9, 12);
  });

  test('有权限时登记并把句柄交给实例，状态保存在本机', () async {
    final r = make();
    expect(await r.sync(instance), PushStatus.ok);
    expect(instance.handle, 'h1');
    expect(relay.live, {'h1': 'tok-1'});

    final again = make();
    await again.load();
    expect(again.state.handle, 'h1');
    expect(again.state.delivered, isTrue);
  });

  test('一天之内回到前台不再联系中继和实例，满一天确认一次', () async {
    final r = make();
    await r.sync(instance);
    now = now.add(const Duration(hours: 23));
    expect(await r.sync(instance), PushStatus.ok);
    expect(relay.confirmed, 0);
    now = now.add(const Duration(hours: 2));
    await r.sync(instance);
    expect(relay.confirmed, 1);
    expect(instance.puts, 1);
  });

  test('令牌变了立即更新，句柄不变', () async {
    final r = make();
    await r.sync(instance);
    device.tok = const PushToken('tok-2');
    expect(await r.sync(instance), PushStatus.ok);
    expect(relay.live, {'h1': 'tok-2'});
    expect(instance.handle, 'h1');
  });

  test('中继答复句柄不存在时重新登记，把新句柄交给实例', () async {
    final r = make();
    await r.sync(instance);
    relay.live.clear();
    now = now.add(const Duration(days: 2));
    expect(await r.sync(instance), PushStatus.ok);
    expect(instance.handle, 'h2');
    expect(instance.puts, 2);
  });

  test('交给实例失败时下次回到前台再交', () async {
    final r = make();
    instance.down = true;
    expect(await r.sync(instance), PushStatus.unavailable);
    instance.down = false;
    expect(await r.sync(instance), PushStatus.ok);
    expect(instance.handle, 'h1');
  });

  test('没有权限、取不到令牌时不登记', () async {
    final r = make();
    device.perm = PushPermission.denied;
    expect(await r.sync(instance), PushStatus.systemOff);
    device.perm = PushPermission.notDetermined;
    expect(await r.sync(instance), PushStatus.needsPermission);
    device.perm = PushPermission.granted;
    device.tok = null;
    expect(await r.sync(instance), PushStatus.unavailable);
    expect(relay.registered, 0);
  });

  test('权限只主动请求一次', () async {
    final r = make();
    device.perm = PushPermission.notDetermined;
    expect(await r.askOnce(), isTrue);
    device.perm = PushPermission.notDetermined;
    expect(await r.askOnce(), isFalse);
    expect(device.requests, 1);
  });

  test('已经有系统权限时不弹出请求', () async {
    final r = make();
    expect(await r.askOnce(), isFalse);
    expect(device.requests, 0);
    expect(r.state.asked, isTrue);
  });

  test('关闭开关时向实例和中继删除句柄，重新打开时重新登记', () async {
    final r = make();
    await r.sync(instance);
    expect(await r.setEnabled(false, instance), PushStatus.off);
    expect(instance.handle, isNull);
    expect(relay.removed, ['h1']);
    expect(await r.setEnabled(true, instance), PushStatus.ok);
    expect(instance.handle, 'h2');
  });

  test('关闭时中继连不上，句柄留着下次再删', () async {
    final r = make();
    await r.sync(instance);
    relay.down = true;
    await r.setEnabled(false, instance);
    expect(r.state.handle, 'h1');
    relay.down = false;
    expect(await r.sync(instance), PushStatus.off);
    expect(relay.removed, ['h1']);
    expect(r.state.handle, isNull);
  });

  test('实例关闭了后台通知：不登记，已有的句柄删除，每天再查一次', () async {
    final r = make();
    await r.sync(instance);
    instance.allows = false;
    now = now.add(const Duration(days: 1));
    expect(await r.sync(instance), PushStatus.serverOff);
    expect(relay.removed, ['h1']);
    instance.allows = true;
    now = now.add(const Duration(hours: 1));
    expect(await r.sync(instance), PushStatus.serverOff);
    now = now.add(const Duration(days: 1));
    expect(await r.sync(instance), PushStatus.ok);
  });

  test('实例拒绝句柄时按关闭处理', () async {
    final r = make();
    final strict = _Rejecting();
    expect(await r.sync(strict), PushStatus.serverOff);
    expect(relay.removed, ['h1']);
  });

  test('退出登录时清掉句柄并让中继删除，开关保留', () async {
    final r = make();
    await r.sync(instance);
    await r.setEnabled(true, instance);
    await r.forget();
    expect(r.state.handle, isNull);
    expect(r.state.enabled, isTrue);
    expect(relay.removed, ['h1']);
  });

  test('中继客户端：句柄放在请求头，iOS 带 APNs 环境，句柄不存在时返回 false', () async {
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      if (req.method == 'POST') return http.Response(jsonEncode({'handle': 'abc'}), 200);
      if (req.method == 'PUT') {
        return http.Response(jsonEncode({'error': 'not_found', 'message': 'no such registration'}), 404);
      }
      return http.Response('{}', 200);
    });
    final relay = RelayClient(ApiClient('https://relay.example', client: client));
    expect(await relay.register('ios', const PushToken('ab01', apnsEnvironment: 'sandbox')), 'abc');
    expect(jsonDecode(seen[0].body), {'platform': 'ios', 'token': 'ab01', 'apnsEnvironment': 'sandbox'});
    expect(seen[0].url.path, '/api/v1/registrations');
    expect(await relay.confirm('abc', const PushToken('t')), isFalse);
    expect(seen[1].headers['authorization'], 'Bearer abc');
    expect(jsonDecode(seen[1].body), {'token': 't'});
    await relay.remove('abc');
    expect(seen[2].method, 'DELETE');
    expect(seen[2].url.path, '/api/v1/registration');
  });
}

class _Rejecting extends FakeInstance {
  @override
  Future<void> setHandle(String h) async => throw ApiException(403, 'forbidden', '这台服务器关闭了后台通知');
}
