import Flutter
import UIKit

// 平台通道：harmonia/keys 是本机密钥保护（LocalKeys），harmonia/platform 是文件与剪贴板等能力（PlatformChannel）。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let keys = LocalKeys()
  private let platform = PlatformChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeDataFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMethodChannel(name: "harmonia/keys", binaryMessenger: messenger)
      .setMethodCallHandler(keys.handle)
    FlutterMethodChannel(name: "harmonia/platform", binaryMessenger: messenger)
      .setMethodCallHandler(platform.handle)
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
