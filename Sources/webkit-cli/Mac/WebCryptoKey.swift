#if os(macOS)
import Foundation
import Security
import WebKit

/// The key WebKit wraps a page's persisted CryptoKeys with (IndexedDB holding a CryptoKey).
/// Without a delegate answer WebKit reads it from the login keychain in this process; for an
/// unbundled binary that raises a keychain prompt nobody answers, and the page's main thread
/// blocks on it forever. So each profile keeps its own key next to its session cookies.
@MainActor
enum WebCryptoKey {
  private static var cache: [UUID: Data] = [:]
  private static let ephemeral = random()

  static func file(for id: UUID) -> URL {
    Accounts.sessionsDir.appendingPathComponent("\(id.uuidString).webcrypto")
  }

  static func key(for store: WKWebsiteDataStore) -> Data? {
    guard let id = store.identifier else { return ephemeral }
    if let k = cache[id] { return k }
    do {
      let url = file(for: id)
      let key: Data
      if FileManager.default.fileExists(atPath: url.path) {
        key = try Data(contentsOf: url)
        guard key.count == 16 else { throw CLIError("\(url.path) is \(key.count) bytes, expected 16") }
      } else {
        try ensurePrivateDir(Accounts.sessionsDir)
        key = random()
        try writePrivateFile(key, to: url)
      }
      cache[id] = key
      return key
    } catch {
      printErr("webkit-cli: no WebCrypto key for this profile, the page's crypto storage will fail: \((error as? CLIError)?.message ?? "\(error)")")
      return nil
    }
  }

  private static func random() -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      fatalError("SecRandomCopyBytes failed")
    }
    return Data(bytes)
  }
}

extension Browser {
  @objc(_webCryptoMasterKeyForWebView:)
  func webCryptoMasterKey(for w: WKWebView) -> Data? {
    WebCryptoKey.key(for: w.configuration.websiteDataStore)
  }

  @objc(_webCryptoMasterKeyForWebView:completionHandler:)
  func webCryptoMasterKey(for w: WKWebView, completionHandler: @escaping (Data?) -> Void) {
    completionHandler(WebCryptoKey.key(for: w.configuration.websiteDataStore))
  }
}
#endif
