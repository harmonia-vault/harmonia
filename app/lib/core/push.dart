// 后台通知的登记（设计文档 18.4，协议 3.10 与第 5 节）：向推送中继登记本机的推送令牌，把中继给的句柄交给实例。
// 通知只是提醒，这里的任何失败都不影响其他流程。
import 'dart:convert';

import 'account.dart';
import 'api.dart';
import 'store.dart';
import 'vault.dart';

/// 推送中继的地址：句柄只在登记它的中继上有效，必须和服务端代码里的一致（设计文档 18.6）。
/// `DEV_PUSH_RELAY_URL` 只用于本地开发。
const pushRelayUrl = String.fromEnvironment('DEV_PUSH_RELAY_URL', defaultValue: 'https://harmonia-push.zzz.sd');

enum PushPermission { granted, denied, notDetermined }

/// 设置页“后台通知”下方显示的状态。
enum PushStatus {
  /// 解锁后还没有检查过。
  checking,

  /// 有新的请求时会收到通知。
  ok,

  /// 用户在 App 里关闭了开关。
  off,

  /// 还没有请求过系统的通知权限。
  needsPermission,

  /// 系统设置里关闭了 Harmonia 的通知。
  systemOff,

  /// 取不到推送令牌，或者暂时连不上中继、实例。
  unavailable,

  /// 实例关闭了后台通知（部署变量 `PUSH_NOTIFICATIONS=false`）。
  serverOff,
}

class PushToken {
  const PushToken(this.token, {this.apnsEnvironment});
  final String token;

  /// iOS 的 APNs 环境：`production` 或 `sandbox`；Android 为 null。
  final String? apnsEnvironment;
}

/// 系统的通知能力，由平台通道实现（Android 的 FCM、iOS 的 APNs）。
abstract class PushDevice {
  Future<PushPermission> permission();

  /// 弹出系统的通知权限请求，返回是否允许。
  Future<bool> requestPermission();

  /// 本机的推送令牌；没有 Google 服务、网络不通或签名不属于发布者时返回 null。
  Future<PushToken?> token();

  Future<void> openSettings();

  /// 上次读取之后，用户是否点开过 Harmonia 的通知。读取后清除。
  Future<bool> takeOpened();
}

/// 推送中继的接口（协议第 5 节）。
abstract class PushRelay {
  Future<String> register(String platform, PushToken token);

  /// 确认登记并更新令牌；句柄已不存在时返回 false。
  Future<bool> confirm(String handle, PushToken token);
  Future<void> remove(String handle);
}

/// 实例上与句柄有关的操作（协议 3.10）。
abstract class PushInstance {
  /// `GET /instance` 的 `push`。
  Future<bool> allowsPush();
  Future<void> setHandle(String handle);
  Future<void> clearHandle();
}

/// 经本机的设备会话调用实例（App 和无界面管理脚本共用）。
class VaultPushInstance implements PushInstance {
  VaultPushInstance(this.vault, this.account);
  final Vault vault;
  final AccountService account;

  @override
  Future<bool> allowsPush() async => (await account.instance(vault.config!.server)).push;
  @override
  Future<void> setHandle(String handle) => vault.setPushHandle(handle);
  @override
  Future<void> clearHandle() => vault.clearPushHandle();
}

class RelayClient implements PushRelay {
  RelayClient([ApiClient? client]) : _api = client ?? ApiClient(pushRelayUrl);
  final ApiClient _api;

  static Map<String, dynamic> _body(PushToken t) => {
    'token': t.token,
    if (t.apnsEnvironment != null) 'apnsEnvironment': t.apnsEnvironment,
  };

  @override
  Future<String> register(String platform, PushToken token) async {
    final res = await _api.public('POST', '/api/v1/registrations', {'platform': platform, ..._body(token)});
    return res['handle'] as String;
  }

  @override
  Future<bool> confirm(String handle, PushToken token) async {
    try {
      await _api.withToken(handle, 'PUT', '/api/v1/registration', _body(token));
      return true;
    } on ApiException catch (e) {
      if (e.code == 'not_found') return false;
      rethrow;
    }
  }

  @override
  Future<void> remove(String handle) => _api.withToken(handle, 'DELETE', '/api/v1/registration');
}

/// 本机保存的登记状态（应用私有文件，卸载即清除）。
class PushState {
  bool enabled = true;

  /// 已经请求过一次系统通知权限；之后不再主动弹出。
  bool asked = false;
  String? handle;

  /// 句柄已经交给实例。
  bool delivered = false;
  String? token;
  String? apnsEnvironment;

  /// 上次向实例和中继完整确认的时间（毫秒）。
  int checkedAt = 0;
  bool serverOff = false;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'asked': asked,
    'handle': handle,
    'delivered': delivered,
    'token': token,
    'apnsEnvironment': apnsEnvironment,
    'checkedAt': checkedAt,
    'serverOff': serverOff,
  };

  static PushState fromJson(Map<String, dynamic> j) => PushState()
    ..enabled = j['enabled'] != false
    ..asked = j['asked'] == true
    ..handle = j['handle'] as String?
    ..delivered = j['delivered'] == true
    ..token = j['token'] as String?
    ..apnsEnvironment = j['apnsEnvironment'] as String?
    ..checkedAt = (j['checkedAt'] as num?)?.toInt() ?? 0
    ..serverOff = j['serverOff'] == true;
}

/// 登记的状态机：每次回到前台调用 [sync]，最多每天向中继和实例确认一次。
class PushRegistrar {
  PushRegistrar({
    required this.device,
    required this.relay,
    required this.store,
    required this.platform,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final PushDevice device;
  final PushRelay relay;
  final LocalStore store;
  final String platform;
  final DateTime Function() _now;

  static const _key = 'push';
  static const confirmEvery = Duration(days: 1);

  PushState state = PushState();
  PushStatus status = PushStatus.checking;
  Future<PushStatus>? _running;

  Future<void> load() async {
    final raw = await store.read(_key);
    if (raw != null) state = PushState.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
  }

  Future<void> _save() => store.write(_key, jsonEncode(state.toJson()));

  /// 只在第一次进入主页时请求一次系统权限（设计文档 18.4）。返回是否弹出了请求。
  Future<bool> askOnce() async {
    if (state.asked) return false;
    state.asked = true;
    await _save();
    if (await device.permission() != PushPermission.notDetermined) return false;
    await device.requestPermission();
    return true;
  }

  /// 设置页里点“允许通知”。
  Future<void> requestPermission() async {
    state.asked = true;
    await _save();
    await device.requestPermission();
  }

  /// 同一时刻只运行一次；[force] 跳过每天一次的间隔（开关刚打开、令牌刚取得时）。
  Future<PushStatus> sync(PushInstance instance, {bool force = false}) =>
      _running ??= _sync(instance, force).whenComplete(() => _running = null);

  Future<PushStatus> _sync(PushInstance instance, bool force) async {
    if (!state.enabled) {
      await _drop(instance);
      return status = PushStatus.off;
    }
    final permission = await _safe(device.permission, PushPermission.denied);
    if (permission != PushPermission.granted) {
      return status = permission == PushPermission.notDetermined ? PushStatus.needsPermission : PushStatus.systemOff;
    }
    final token = await _safe(device.token, null);
    if (token == null) return status = PushStatus.unavailable;

    final now = _now().millisecondsSinceEpoch;
    final tokenChanged = token.token != state.token || token.apnsEnvironment != state.apnsEnvironment;
    final due = force || now - state.checkedAt >= confirmEvery.inMilliseconds;
    if (!due && !tokenChanged && state.handle != null && state.delivered) return status = PushStatus.ok;
    if (!due && state.serverOff) return status = PushStatus.serverOff;

    try {
      if (!await instance.allowsPush()) return await _serverOff(instance, now);
      if (state.handle == null) {
        state.handle = await relay.register(platform, token);
        state.delivered = false;
      } else if (due || tokenChanged) {
        if (!await relay.confirm(state.handle!, token)) {
          state.handle = await relay.register(platform, token);
          state.delivered = false;
        }
      }
      state
        ..token = token.token
        ..apnsEnvironment = token.apnsEnvironment
        ..serverOff = false;
      await _save();
      if (!state.delivered) {
        await instance.setHandle(state.handle!);
        state.delivered = true;
      }
      state.checkedAt = now;
      await _save();
      return status = PushStatus.ok;
    } on ApiException catch (e) {
      if (e.code == 'forbidden') return await _serverOff(instance, now);
      return status = _fallback();
    }
  }

  PushStatus _fallback() => state.handle != null && state.delivered ? PushStatus.ok : PushStatus.unavailable;

  Future<PushStatus> _serverOff(PushInstance instance, int now) async {
    await _drop(instance, notifyInstance: false);
    state
      ..serverOff = true
      ..checkedAt = now;
    await _save();
    return status = PushStatus.serverOff;
  }

  /// 打开或关闭“后台通知”。关闭时向实例和中继删除句柄，重新打开时重新登记（设计文档 18.4）。
  Future<PushStatus> setEnabled(bool enabled, PushInstance instance) async {
    state.enabled = enabled;
    await _save();
    return sync(instance, force: true);
  }

  /// 退出登录、本机被撤销或清除本机数据：清掉本机的句柄，并尽力让中继删除。开关和“已请求过权限”保留。
  Future<void> forget() async {
    final handle = state.handle;
    state
      ..handle = null
      ..delivered = false
      ..checkedAt = 0
      ..serverOff = false;
    status = PushStatus.checking;
    await _save();
    if (handle != null) await _quiet(() => relay.remove(handle));
  }

  Future<void> _drop(PushInstance instance, {bool notifyInstance = true}) async {
    final handle = state.handle;
    if (handle == null) return;
    if (notifyInstance && state.delivered) await _quiet(instance.clearHandle);
    // 中继删除成功后句柄即失效，实例那边残留的也没用了；失败时留着，下次再试。
    if (!await _quiet(() => relay.remove(handle))) return;
    state
      ..handle = null
      ..delivered = false;
    await _save();
  }

  static Future<bool> _quiet(Future<void> Function() fn) async {
    try {
      await fn();
      return true;
    } on ApiException {
      return false;
    }
  }

  static Future<T> _safe<T>(Future<T> Function() fn, T fallback) async {
    try {
      return await fn();
    } catch (_) {
      return fallback;
    }
  }
}
