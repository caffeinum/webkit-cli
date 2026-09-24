import Foundation
import WebKit

/// WebKit drops session-only cookies (no Expires/Max-Age) when the process exits, which logs out
/// sites like e2b. We persist them ourselves and put them back before the first load.
@MainActor
enum SessionCookies {
  static func save(from store: WKWebsiteDataStore, to file: URL) async throws {
    let cookies = await store.httpCookieStore.allCookies().filter(\.isSessionOnly)
    let plist: [[String: Any]] = cookies.compactMap { cookie in
      guard let props = cookie.properties else { return nil }
      return Dictionary(uniqueKeysWithValues: props.map { ($0.key.rawValue, $0.value) })
    }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    try writePrivate(data, to: file)
  }

  static func restore(into store: WKWebsiteDataStore, from file: URL) async throws {
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    let data = try Data(contentsOf: file)
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
      throw CLIError("\(file.path) is not a list of cookies")
    }
    for (i, raw) in plist.enumerated() {
      let props = Dictionary(uniqueKeysWithValues: raw.map { (HTTPCookiePropertyKey($0.key), $0.value) })
      guard let cookie = HTTPCookie(properties: props) else {
        throw CLIError("\(file.path): cookie #\(i) could not be rebuilt — delete the file to drop saved session cookies")
      }
      await store.httpCookieStore.setCookie(cookie)
    }
  }
}
