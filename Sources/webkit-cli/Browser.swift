import AppKit
import WebKit

let viewport = NSSize(width: 1280, height: 800)

func safariUserAgent() throws -> String {
  let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
  guard let info = NSDictionary(contentsOf: plist), let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
    throw CLIError("cannot read Safari's version from \(plist.path) — needed to build a Safari user agent (Google sign-in rejects WKWebView's default)")
  }
  return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
}

/// A hidden-but-rendering window: borderless, far off-screen, ordered front, with WebKit's occlusion
/// detection switched off. Without this WebKit reports visibilityState "hidden", stops rAF and clamps
/// timers, and SPAs never hydrate.
@MainActor
func disableOcclusionDetection(_ web: WKWebView) throws {
  let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
  guard web.responds(to: sel), let imp = web.method(for: sel) else {
    throw CLIError("""
      WKWebView no longer implements the private _setWindowOcclusionDetectionEnabled: (macOS update?). \
      Headless pages would be throttled (hidden, no rAF), so refusing to run.
      """)
  }
  typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
  unsafeBitCast(imp, to: SetBool.self)(web, sel, false)
}

@MainActor
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
  let web: WKWebView
  let window: NSWindow
  let visible: Bool
  private(set) var lastStatus: Int?
  private var requestedURL: String?
  private var popups: [NSWindow] = []
  private var pendingLoad: CheckedContinuation<Void, Error>?
  private var closed: CheckedContinuation<Void, Never>?
  private let userAgent: String

  init(store: WKWebsiteDataStore, visible: Bool, title: String = "webkit-cli") throws {
    userAgent = try safariUserAgent()
    self.visible = visible
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = store
    web = WKWebView(frame: NSRect(origin: .zero, size: viewport), configuration: cfg)
    window = Browser.makeWindow(visible: visible, title: title)
    super.init()
    try attach(web, to: window)
    window.delegate = self
    if visible {
      let w = window
      window.contentView = AuthContainer(web: web) { w.performClose(nil) }
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private static func makeWindow(visible: Bool, title: String) -> NSWindow {
    if visible {
      let w = NSWindow(contentRect: NSRect(origin: .zero, size: viewport),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
      w.title = title
      w.isReleasedWhenClosed = false
      return w
    }
    let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: viewport),
                     styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    return w
  }

  private func attach(_ view: WKWebView, to win: NSWindow) throws {
    view.customUserAgent = userAgent
    view.navigationDelegate = self
    view.uiDelegate = self
    win.contentView = view
    if !visible {
      win.orderFrontRegardless()
      try disableOcclusionDetection(view)
    }
  }

  // MARK: loading

  func load(_ url: URL) async throws {
    lastStatus = nil
    requestedURL = url.absoluteString
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      pendingLoad = c
      web.load(URLRequest(url: url))
    }
  }

  func loadHTML(_ html: String, baseURL: URL) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      pendingLoad = c
      web.loadHTMLString(html, baseURL: baseURL)
    }
  }

  private func finishLoad(_ result: Result<Void, Error>) {
    guard let c = pendingLoad else { return }
    pendingLoad = nil
    c.resume(with: result)
  }

  func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
    guard w === web else { return }
    finishLoad(.success(()))
  }

  func webView(_ w: WKWebView, didFail _: WKNavigation!, withError error: Error) {
    guard w === web else { return }
    navigationFailed(error)
  }

  func webView(_ w: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
    guard w === web else { return }
    navigationFailed(error)
  }

  private func navigationFailed(_ error: Error) {
    let ns = error as NSError
    // superseded by a redirect or a newer navigation — keep waiting for that one to finish
    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
    let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
    let url = failing ?? requestedURL ?? "the page"
    finishLoad(.failure(CLIError("load failed for \(url): \(ns.localizedDescription) (\(ns.domain) \(ns.code))")))
  }

  func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
    if w === web, response.isForMainFrame, let http = response.response as? HTTPURLResponse {
      lastStatus = http.statusCode
    }
    return .allow
  }

  func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
    guard w === web else { return }
    finishLoad(.failure(CLIError("the page's web content process crashed")))
  }

  // MARK: popups (window.open — OAuth often uses these)

  func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration, for _: WKNavigationAction,
               windowFeatures _: WKWindowFeatures) -> WKWebView? {
    let popup = WKWebView(frame: NSRect(origin: .zero, size: viewport), configuration: cfg)
    let win = Browser.makeWindow(visible: visible, title: "webkit-cli popup")
    do {
      try attach(popup, to: win)
    } catch {
      printErr("webkit-cli: refusing popup: \((error as? CLIError)?.message ?? "\(error)")")
      return nil
    }
    if visible {
      win.center()
      win.makeKeyAndOrderFront(nil)
    }
    popups.append(win)
    return popup
  }

  func webViewDidClose(_ w: WKWebView) {
    guard let win = popups.first(where: { $0.contentView === w }) else { return }
    popups.removeAll { $0 === win }
    win.close()
  }

  // MARK: scripting

  /// Runs `body` as the body of an async function in the page's world; returns its JSON-encoded result,
  /// or nil when the function returned undefined.
  func evalJSON(_ body: String) async throws -> String? {
    let wrapped = """
      const __webkitCliResult = await (async () => {
      \(body)
      })();
      return __webkitCliResult === undefined ? undefined : JSON.stringify(__webkitCliResult);
      """
    return try await callJS(wrapped) as? String
  }

  func callJS(_ body: String) async throws -> Any? {
    do {
      return try await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    } catch let error as NSError {
      if let msg = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
        throw CLIError("javascript error: \(msg)")
      }
      throw CLIError("javascript failed: \(error.localizedDescription)")
    }
  }

  func snapshotPNG() async throws -> (data: Data, width: Int, height: Int) {
    let image = try await web.takeSnapshot(configuration: nil)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw CLIError("snapshot produced no bitmap")
    }
    guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
      throw CLIError("could not encode snapshot as PNG")
    }
    return (png, cg.width, cg.height)
  }

  // MARK: visible window lifecycle (auth)

  func waitUntilClosed() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in closed = c }
  }

  func windowWillClose(_ note: Notification) {
    guard (note.object as? NSWindow) === window else { return }
    popups.forEach { $0.close() }
    closed?.resume()
    closed = nil
  }
}
