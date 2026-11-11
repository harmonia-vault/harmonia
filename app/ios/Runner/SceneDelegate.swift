import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var layout: WindowLayoutChannel?

  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      layout = WindowLayoutChannel(controller)
    }
  }
}

// 当前视图的几何信息不经过账号、存储或网络。
private final class WindowLayoutChannel: NSObject, FlutterStreamHandler {
  private let probe: WindowLayoutProbe
  private let channel: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var last: NSDictionary?

  init(_ controller: FlutterViewController) {
    probe = WindowLayoutProbe(frame: controller.view.bounds)
    channel = FlutterEventChannel(name: "harmonia/layout", binaryMessenger: controller.binaryMessenger)
    super.init()
    probe.onChange = { [weak self] in self?.publish() }
    controller.view.addSubview(probe)
    channel.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    last = nil
    publish()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func publish() {
    guard let view = probe.superview, let sink else { return }
    var data: [String: Any] = [
      "regularWidth": view.traitCollection.horizontalSizeClass == .regular,
      "occlusions": [[Double]]()
    ]
    if #available(iOS 27.1, *) {
      switch view.traitCollection.verticalBarEdge {
      case .leading: data["edge"] = "left"
      case .trailing: data["edge"] = "right"
      default: data["edge"] = "bottom"
      }
      func rect(_ frame: CGRect) -> [Double] {
        [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
      }
      data["fold"] = view.reservedRegions(kind: .division).first.map { rect($0.frame) }
      data["occlusions"] = view.reservedRegions(kind: .occlusion).map { rect($0.frame) }
    }
    let snapshot = data as NSDictionary
    if snapshot != last {
      last = snapshot
      sink(data)
    }
  }
}

private final class WindowLayoutProbe: UIView {
  var onChange: (() -> Void)?
  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    NotificationCenter.default.addObserver(
      self, selector: #selector(refresh), name: UIApplication.didBecomeActiveNotification, object: nil)
    if #available(iOS 27.1, *) {
      registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
        (self: WindowLayoutProbe, _: UITraitCollection) in self.onChange?()
      }
    }
  }
  required init?(coder: NSCoder) { fatalError("仅从当前 Flutter 视图创建") }
  override func layoutSubviews() { super.layoutSubviews(); onChange?() }
  override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); onChange?() }
  override func didMoveToWindow() { super.didMoveToWindow(); onChange?() }
  @objc private func refresh() { onChange?() }
}
