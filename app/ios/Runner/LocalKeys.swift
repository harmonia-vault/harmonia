import CryptoKit
import Flutter
import Foundation
import LocalAuthentication
import Security

// 本机密钥保护的系统部分（docs/protocol.md 2.5 的 iOS 部分）：
// PIN 槽用的 Secure Enclave 私钥 K_se（不可导出，不要求验证），
// 以及只有面容 ID / 触控 ID 能读出的钥匙串条目（保存本机数据密钥）。
final class LocalKeys {
  private static let service = "harmonia.local"
  private static let pinAccount = "pin-key"
  private static let bioAccount = "bio"

  enum KeyError: Error {
    case noPoint
    case keychain(OSStatus)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    func bytes(_ name: String) -> Data { (args[name] as? FlutterStandardTypedData)?.data ?? Data() }
    do {
      switch call.method {
      case "pinMac":
        result(FlutterStandardTypedData(bytes: try pinMac(bytes("input"))))
      case "bioKind":
        result(bioKind())
      case "bioAvailable":
        result(LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil))
      case "bioEnable":
        try bioEnable(bytes("key"), args["title"] as? String ?? "", args["cancel"] as? String ?? "", result)
      case "bioUnlock":
        bioUnlock(args["title"] as? String ?? "", args["cancel"] as? String ?? "", result)
      case "deleteAll":
        delete(Self.pinAccount)
        delete(Self.bioAccount)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "failed", message: "\(error)", details: nil))
    }
  }

  // ---- PIN 槽：kek = SHA-256(ECDH(K_se, HashToP256(pk))) ----

  /// 把 pk 映射为 P-256 曲线上的点：取第一个能让 0x02 ‖ SHA-256(pk ‖ i) 成为合法压缩点的 i。
  static func hashToP256(_ pk: Data) throws -> P256.KeyAgreement.PublicKey {
    for i in UInt8.min...UInt8.max {
      let x = SHA256.hash(data: pk + [i])
      if let point = try? P256.KeyAgreement.PublicKey(compressedRepresentation: [0x02] + x) { return point }
    }
    throw KeyError.noPoint
  }

  /// ECDH 的结果是共享点的 x 坐标；kek 是它的 SHA-256。
  static func kek(_ secret: SharedSecret) -> Data {
    secret.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }
  }

  private func pinMac(_ pk: Data) throws -> Data {
    let point = try Self.hashToP256(pk)
    #if targetEnvironment(simulator)
    // 模拟器没有 Secure Enclave：改用保存在钥匙串里的普通私钥，只用于布局检查。
    let key: P256.KeyAgreement.PrivateKey
    if let raw = try read(Self.pinAccount) {
      key = try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    } else {
      key = P256.KeyAgreement.PrivateKey()
      try write(Self.pinAccount, key.rawRepresentation)
    }
    #else
    // 钥匙串里保存的是只有这台手机的 Secure Enclave 才能使用的密钥引用，不是私钥本身。
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    if let blob = try read(Self.pinAccount) {
      key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
    } else {
      guard let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil)
      else { throw KeyError.keychain(errSecParam) }
      key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
      try write(Self.pinAccount, key.dataRepresentation)
    }
    #endif
    return Self.kek(try key.sharedSecretFromKeyAgreement(with: point))
  }

  // ---- 面容 ID / 触控 ID 槽 ----

  private func bioKind() -> String {
    let context = LAContext()
    // biometryType 在检查之后才有值。
    _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    switch context.biometryType {
    case .faceID: return "face"
    case .touchID: return "touch"
    default: return ""
    }
  }

  private func bioEnable(_ key: Data, _ title: String, _ cancel: String, _ result: @escaping FlutterResult) throws {
    delete(Self.bioAccount)
    // 只接受当前已录入的面容或指纹，不接受锁屏密码；录入有变化或关闭锁屏密码后，系统使条目失效。
    guard let access = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
    else { throw KeyError.keychain(errSecParam) }
    var item = query(Self.bioAccount)
    item[kSecAttrAccessControl as String] = access
    item[kSecValueData as String] = key
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeyError.keychain(status) }
    // 写入不需要验证，所以马上读一次：让用户验证一次，并确认这条条目读得出来。
    bioRead(title, cancelTitle: cancel) { status, data in
      if status == errSecSuccess, data == key {
        // 密钥在钥匙串里；返回的槽只是“已开启”的标记。
        result(FlutterStandardTypedData(bytes: Data([1])))
      } else {
        self.delete(Self.bioAccount)
        result(FlutterError(code: status == errSecUserCanceled ? "canceled" : "failed", message: nil, details: nil))
      }
    }
  }

  private func bioUnlock(_ title: String, _ cancel: String, _ result: @escaping FlutterResult) {
    bioRead(title, cancelTitle: cancel) { status, data in
      switch status {
      case errSecSuccess where data != nil:
        result(FlutterStandardTypedData(bytes: data!))
      case errSecItemNotFound:
        result(FlutterError(code: "invalidated", message: nil, details: nil))
      case errSecUserCanceled:
        result(FlutterError(code: "canceled", message: nil, details: nil))
      default:
        result(FlutterError(code: "failed", message: "\(status)", details: nil))
      }
    }
  }

  private func bioRead(_ title: String, cancelTitle: String, done: @escaping (OSStatus, Data?) -> Void) {
    let context = LAContext()
    context.localizedReason = title
    context.localizedFallbackTitle = ""
    context.localizedCancelTitle = cancelTitle
    var q = query(Self.bioAccount)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecUseAuthenticationContext as String] = context
    // 读取会一直等到用户完成验证，不能占用主线程。
    DispatchQueue.global(qos: .userInitiated).async {
      var out: CFTypeRef?
      let status = SecItemCopyMatching(q as CFDictionary, &out)
      DispatchQueue.main.async { done(status, out as? Data) }
    }
  }

  // ---- 钥匙串 ----

  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
    ]
  }

  private func read(_ account: String) throws -> Data? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeyError.keychain(status) }
    return out as? Data
  }

  private func write(_ account: String, _ data: Data) throws {
    delete(account)
    var item = query(account)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    item[kSecValueData as String] = data
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeyError.keychain(status) }
  }

  private func delete(_ account: String) {
    SecItemDelete(query(account) as CFDictionary)
  }
}
