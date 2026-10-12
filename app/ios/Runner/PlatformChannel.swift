import Flutter
import UIKit
import UniformTypeIdentifiers
import WebKit

// harmonia/platform 通道：设备名、HTML 转 PDF、通过系统“存储到文件”保存、
// 通过分享面板把文件交给其他 App、敏感内容复制（1 分钟后过期）、用浏览器打开网页。
final class PlatformChannel: NSObject, WKNavigationDelegate, UIDocumentPickerDelegate {
  private static let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)

  // 转换期间持有网页视图，防止被回收。
  private var pdfWeb: WKWebView?
  private var pdfResult: FlutterResult?
  private var pendingSave: (dir: URL, result: FlutterResult)?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "deviceName":
      // iOS 16 起，没有苹果单独批准的权限时，系统只返回“iPhone”这样的通称，拿不到用户起的名字。
      let name = UIDevice.current.name
      result(name.isEmpty ? UIDevice.current.model : name)
    case "htmlToPdf":
      htmlToPdf(args["html"] as? String ?? "", result)
    case "saveFile":
      saveFile(
        name: args["name"] as? String ?? "file",
        bytes: (args["bytes"] as? FlutterStandardTypedData)?.data ?? Data(),
        result)
    case "shareFile":
      shareFile(path: args["path"] as? String ?? "", result)
    case "copySensitive":
      // 只留在本机，不同步到其他 Apple 设备；1 分钟后由系统清除。
      UIPasteboard.general.setItems(
        [[UTType.utf8PlainText.identifier: args["text"] as? String ?? ""]],
        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
      result(nil)
    case "openUrl":
      guard let url = URL(string: args["url"] as? String ?? "") else { return result(false) }
      UIApplication.shared.open(url) { result($0) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ---- HTML 转 PDF：用系统网页引擎按打印方式排成 A4 ----

  private func htmlToPdf(_ html: String, _ result: @escaping FlutterResult) {
    pdfResult?(FlutterError(code: "pdf_failed", message: nil, details: nil))
    let web = WKWebView(frame: Self.a4)
    web.navigationDelegate = self
    pdfWeb = web
    pdfResult = result
    web.loadHTMLString(html, baseURL: nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let renderer = A4Renderer()
    renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
    let data = NSMutableData()
    UIGraphicsBeginPDFContextToData(data, Self.a4, nil)
    renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
    for page in 0..<renderer.numberOfPages {
      UIGraphicsBeginPDFPage()
      renderer.drawPage(at: page, in: Self.a4)
    }
    UIGraphicsEndPDFContext()
    finishPdf(data.length > 0 ? FlutterStandardTypedData(bytes: data as Data) : nil)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishPdf(nil)
  }

  private func finishPdf(_ bytes: FlutterStandardTypedData?) {
    pdfResult?(bytes ?? FlutterError(code: "pdf_failed", message: nil, details: nil))
    pdfResult = nil
    pdfWeb = nil
  }

  private final class A4Renderer: UIPrintPageRenderer {
    override var paperRect: CGRect { PlatformChannel.a4 }
    override var printableRect: CGRect { PlatformChannel.a4 }
  }

  // ---- 保存文件：弹出系统“存储到文件”，由用户选择位置 ----

  private func saveFile(name: String, bytes: Data, _ result: @escaping FlutterResult) {
    finishSave(false)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = dir.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try bytes.write(to: file, options: .completeFileProtection)
    } catch {
      return result(FlutterError(code: "write_failed", message: error.localizedDescription, details: nil))
    }
    guard let top = topController else {
      try? FileManager.default.removeItem(at: dir)
      return result(FlutterError(code: "write_failed", message: nil, details: nil))
    }
    pendingSave = (dir, result)
    let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
    picker.delegate = self
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishSave(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishSave(false)
  }

  // ---- 分享文件：弹出系统分享面板，由用户选择接收的 App（新版本的 IPA 交给签名工具） ----

  private func shareFile(path: String, _ result: @escaping FlutterResult) {
    guard FileManager.default.fileExists(atPath: path), let top = topController else {
      return result(FlutterError(code: "share_failed", message: nil, details: nil))
    }
    let sheet = UIActivityViewController(activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    // 完成或取消后才返回：调用方在这之后删除文件。
    sheet.completionWithItemsHandler = { _, completed, _, _ in result(completed) }
    // iPad 上以 iPhone 兼容模式运行时也需要一个弹出位置。
    sheet.popoverPresentationController?.sourceView = top.view
    sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
    top.present(sheet, animated: true)
  }

  private func finishSave(_ saved: Bool) {
    guard let (dir, result) = pendingSave else { return }
    pendingSave = nil
    // 临时文件里有恢复码，系统复制完成后立即删除。
    try? FileManager.default.removeItem(at: dir)
    result(saved)
  }

  private var topController: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var top = scenes.compactMap(\.keyWindow).first?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }
}
