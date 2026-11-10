import Flutter
import UIKit
import UserNotifications

// 平台通道：harmonia/keys 是本机密钥保护（LocalKeys），harmonia/platform 是文件与剪贴板等能力（PlatformChannel），
// harmonia/push 是后台通知（PushChannel）。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let keys = LocalKeys()
  private let platform = PlatformChannel()
  private let push = PushChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeDataFromBackup()
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMethodChannel(name: "harmonia/keys", binaryMessenger: messenger)
      .setMethodCallHandler(keys.handle)
    FlutterMethodChannel(name: "harmonia/platform", binaryMessenger: messenger)
      .setMethodCallHandler(platform.handle)
    FlutterMethodChannel(name: "harmonia/push", binaryMessenger: messenger)
      .setMethodCallHandler(push.handle)
  }

  override func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    push.didRegister(deviceToken)
  }

  override func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    push.didFailToRegister()
  }

  // App 在前台时不显示横幅：批准页会直接弹出（设计文档 18.4）。
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    push.didOpenNotification()
    completionHandler()
  }

  // App 数据不进备份，与 Android 的 allowBackup=false 对应：从备份恢复或换机之后是一台新设备。
  private func excludeDataFromBackup() {
    guard var dir = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
  }
}
