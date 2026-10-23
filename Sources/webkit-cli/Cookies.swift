import Foundation

/// A cookie as both backends hand it over, in WebDriver's shape.
struct WireCookie: Codable {
  var name: String
  var value: String
  var domain: String?
  var path: String?
  var secure: Bool?
  var httpOnly: Bool?
  var expiry: Int?        // unix seconds; nil = session-only
  var sameSite: String?   // "None" | "Lax" | "Strict"; nil = the browser's default

  /// Whether a request to `url` would carry this cookie.
  func applies(to url: URL) -> Bool {
    guard let host = url.host?.lowercased(), let domain = domain?.lowercased() else { return false }
    let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    guard host == bare || host.hasSuffix("." + bare) else { return false }
    if secure == true && url.scheme != "https" && host != "localhost" && host != "127.0.0.1" { return false }
    let p = path ?? "/"
    let reqPath = url.path.isEmpty ? "/" : url.path
    return reqPath == p || reqPath.hasPrefix(p.hasSuffix("/") ? p : p + "/")
  }

  var json: [String: Any] {
    var o: [String: Any] = ["name": name, "value": value, "domain": domain ?? NSNull(), "path": path ?? "/",
                            "secure": secure ?? false, "httpOnly": httpOnly ?? false]
    if let expiry { o["expiry"] = expiry }
    if let sameSite { o["sameSite"] = sameSite }
    return o
  }
}
