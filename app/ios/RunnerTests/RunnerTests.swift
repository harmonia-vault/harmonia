import CryptoKit
import Flutter
import XCTest

@testable import Runner

// PIN 槽密钥的计算（docs/protocol.md 2.5 的 iOS 部分）。期望值由独立实现算出：
// 私钥固定为 01 02 … 20，对照 HashToP256 得到的点和 SHA-256(共享点的 x 坐标)。
// 另外检查恢复码模板在 iOS 上排出来正好是一页 A4。
class RunnerTests: XCTestCase {
  private let key = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))

  private func check(pk: Data, point: String, kek: String) throws {
    let p = try LocalKeys.hashToP256(pk)
    XCTAssertEqual(hex(p.x963Representation), point)
    XCTAssertEqual(hex(LocalKeys.kek(try key.sharedSecretFromKeyAgreement(with: p))), kek)
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  func testFirstCandidateIsOnCurve() throws {
    try check(
      pk: Data(0...31),
      point: "041b170dcb8d81735abf2c1e096158e067f3fc8dd8d5821f65cc0caea2c6fc7e68"
        + "f0079185a063a2ee605c5cb78a67537df3f557f8af418e7ceeda7b6b395fe180",
      kek: "e6698953220b05341820b9123d34153ac79324bd7730d88e199098d4db37efe1")
  }

  // 第一个候选不在曲线上，要取下一个。
  func testSkipsCandidatesOffCurve() throws {
    try check(
      pk: Data(repeating: 0xff, count: 32),
      point: "048f04045cb5b643a45a2df62d82153528de3ce3446c8127c19e2b1b4574bc72b7"
        + "61d91598b51783861c1dfbd99d9335c40c0910a9b30d16e15ad3c8e91b29240a",
      kek: "579e7f9004491fe582225e1010800452e9ab330c6d57b64c6addd7e82796249c")
  }

  // 模板取自 App 包内的 Flutter 资源，填入偏长的账号和服务器地址。
  func testRecoverySheetIsOneA4Page() throws {
    let url = try XCTUnwrap(Bundle.main.url(
      forResource: "recovery_sheet", withExtension: "html",
      subdirectory: "Frameworks/App.framework/flutter_assets/assets"))
    let code = ["WC3G", "29K1", "7ZK0", "NS9M", "Y227", "MSGR", "Y0"].map { "<span class=\"g\">\($0)</span>" }
    let values = [
      "{{EMAIL}}": "someone.with.a.long.name@mail.example.com",
      "{{SERVER}}": "https://harmonia-worker.some-account-name.workers.dev",
      "{{DATE}}": "2026-10-12",
      "{{CODE}}": "<div>\(code[..<4].joined())</div><div>\(code[4...].joined())</div>",
    ]
    var html = try String(contentsOf: url, encoding: .utf8)
    for (key, value) in values { html = html.replacingOccurrences(of: key, with: value) }

    let done = expectation(description: "pdf")
    var pdf: Data?
    let channel = PlatformChannel()
    channel.handle(FlutterMethodCall(methodName: "htmlToPdf", arguments: ["html": html])) { result in
      pdf = (result as? FlutterStandardTypedData)?.data
      done.fulfill()
    }
    wait(for: [done], timeout: 20)

    let provider = try XCTUnwrap(CGDataProvider(data: try XCTUnwrap(pdf) as CFData))
    let document = try XCTUnwrap(CGPDFDocument(provider))
    XCTAssertEqual(document.numberOfPages, 1)
    let page = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
    XCTAssertEqual(page.width, 595.2, accuracy: 0.5)
    XCTAssertEqual(page.height, 841.8, accuracy: 0.5)
  }
}
