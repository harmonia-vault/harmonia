// Shell 集成的页面调试操作只修改内存中的示例设备。
import 'vault.dart';

mixin DebugShell on Vault {
  void check();
  Set<String> get offlineDevices;

  @override
  Future<void> setShellEnabled(String id, bool on) async {
    check();
    final device = devices.singleWhere((d) => d.id == id);
    device.json['shellEnabled'] = on;
    device.json['shellState'] = offlineDevices.contains(id) ? null : {'enabled': on, 'error': null};
  }
}
