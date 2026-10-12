import Flutter
import UIKit

// 平台通道：harmonia/keys 是本机密钥保护（LocalKeys），harmonia/platform 是文件与剪贴板等能力（PlatformChannel）。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let keys = LocalKeys()
  private let platform = PlatformChannel()
  private var lockChannel: FlutterMethodChannel?
  private var pendingLock = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeDataFromBackup()
    NotificationCenter.default.addObserver(
      self, selector: #selector(deviceLocked),
      name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMethodChannel(name: "harmonia/keys", binaryMessenger: messenger)
      .setMethodCallHandler(keys.handle)
    FlutterMethodChannel(name: "harmonia/platform", binaryMessenger: messenger)
      .setMethodCallHandler(platform.handle)
    let channel = FlutterMethodChannel(name: "harmonia/lock", binaryMessenger: messenger)
    lockChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      guard call.method == "consumeLock" else { return result(FlutterMethodNotImplemented) }
      let locked = !UIApplication.shared.isProtectedDataAvailable
      result(["locked": locked, "wasLocked": self.pendingLock || locked])
      self.pendingLock = false
    }
  }

  // 系统即将锁住受保护数据时立即通知，不把锁屏当成普通切后台。
  @objc private func deviceLocked() {
    pendingLock = true
    lockChannel?.invokeMethod("locked", arguments: nil)
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
