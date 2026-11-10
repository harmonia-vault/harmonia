import Flutter
import UIKit
import UserNotifications

// harmonia/push 通道（设计文档 18.4）：通知权限、APNs 设备令牌、“用户点开了通知”。
// 令牌属于哪个 APNs 环境由签名决定：开发描述文件是测试环境，其余（Ad Hoc、TestFlight、App Store）是正式环境。
final class PushChannel: NSObject {
  private var token: String?
  private var waiters: [FlutterResult] = []
  private var opened = false

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "permission":
      center.getNotificationSettings { settings in
        let value: String
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: value = "granted"
        case .notDetermined: value = "notDetermined"
        default: value = "denied"
        }
        DispatchQueue.main.async { result(value) }
      }
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "token":
      if let token {
        result(Self.payload(token))
        return
      }
      waiters.append(result)
      UIApplication.shared.registerForRemoteNotifications()
      // 自行重签、没有推送能力的版本不会有任何回调。
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(nil) }
    case "openSettings":
      let raw: String
      if #available(iOS 16.0, *) {
        raw = UIApplication.openNotificationSettingsURLString
      } else {
        raw = UIApplication.openSettingsURLString
      }
      if let url = URL(string: raw) { UIApplication.shared.open(url) }
      result(nil)
    case "takeOpened":
      result(opened)
      opened = false
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func didRegister(_ deviceToken: Data) {
    token = deviceToken.map { String(format: "%02x", $0) }.joined()
    finish(token)
  }

  func didFailToRegister() { finish(nil) }

  func didOpenNotification() { opened = true }

  private func finish(_ token: String?) {
    let pending = waiters
    waiters = []
    for result in pending { result(token.map(Self.payload)) }
  }

  private static func payload(_ token: String) -> [String: String] {
    ["token": token, "apnsEnvironment": apnsEnvironment]
  }

  /// 读取安装包里描述文件的 aps-environment；App Store 版本没有描述文件，属于正式环境。
  private static let apnsEnvironment: String = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .isoLatin1),
      let start = text.range(of: "<?xml"),
      let end = text.range(of: "</plist>"),
      let xml = text[start.lowerBound..<end.upperBound].data(using: .isoLatin1),
      let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any]
    else { return "production" }
    return entitlements["aps-environment"] as? String == "development" ? "sandbox" : "production"
  }()
}
