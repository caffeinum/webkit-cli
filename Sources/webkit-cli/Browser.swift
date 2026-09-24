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

/// Whether this process can put a window in front of a person (false over ssh / at the login window).
func hasGUISession() -> Bool {
  guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
  return session[kCGSessionOnConsoleKey as String] as? Bool ?? false
}

func screenIsLocked() -> Bool {
  let session = CGSessionCopyCurrentDictionary() as? [String: Any]
  return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

/// One web view in its own window — a tab. Headless tabs live off-screen; `auth` uses a visible one.
@MainActor
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
  let web: WKWebView
  let window: NSWindow
  let visible: Bool
  private(set) var lastStatus: Int?
  /// The most recent main-frame load error, even one nobody was awaiting (e.g. after a click).
  private(set) var lastFailure: String?
  private var requestedURL: String?
  private var pendingLoad: CheckedContinuation<Void, Error>?
  private var closed: CheckedContinuation<Void, Never>?

  /// Called with each window.open popup. Without a handler the popup is kept alive by this tab.
  var onPopup: ((Browser) -> Void)?
  /// Called when the page closes itself (window.close()).
  var onPageClose: (() -> Void)?
  private var ownedPopups: [Browser] = []

  convenience init(store: WKWebsiteDataStore, visible: Bool, title: String = "webkit-cli") throws {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = store
    try self.init(configuration: cfg, visible: visible, title: title)
    if visible {
      let w = window
      window.contentView = AuthContainer(web: web) { w.performClose(nil) }
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private init(configuration: WKWebViewConfiguration, visible: Bool, title: String) throws {
    self.visible = visible
    web = WKWebView(frame: NSRect(origin: .zero, size: viewport), configuration: configuration)
    web.customUserAgent = try safariUserAgent()
    window = Browser.makeWindow(visible: visible, title: title)
    super.init()
    web.navigationDelegate = self
    web.uiDelegate = self
    window.contentView = web
    window.delegate = self
    if !visible {
      window.orderFrontRegardless()
      try disableOcclusionDetection(web)
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
    makeHeadless(w)
    return w
  }

  private static func makeHeadless(_ w: NSWindow) {
    w.isExcludedFromWindowsMenu = true
    w.collectionBehavior = [.transient, .ignoresCycle, .stationary]
    w.hasShadow = false
  }

  private(set) var isClosed = false

  // MARK: showing a headless tab to a person

  /// True while this headless tab is on screen for a person (show/--escalate).
  private(set) var isShown = false
  private var shownBar: (NSTitlebarAccessoryViewController, AuthBar)?
  /// How many tabs are on screen, and which app had the keyboard before the first one appeared.
  private static var shownCount = 0
  private static var previousApp: NSRunningApplication?

  /// Brings this tab's own window on screen — the same window and web view, so the page keeps its state,
  /// process and JS — with a bar saying what to do and a Done button. Done, ⌘W and the close button hide it.
  func show(reason: String) throws {
    guard !visible else { return }
    guard hasGUISession() else {
      throw CLIError("can't show a window: no GUI session (logged in over ssh, or at the login window?)")
    }
    installMenu()
    if let (_, bar) = shownBar {
      bar.instruction = reason
    } else {
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
      window.title = "webkit-cli — needs you"
      window.collectionBehavior = [.moveToActiveSpace]
      window.hasShadow = true
      let bar = AuthBar(web: web, instruction: reason) { [weak self] in self?.hide() }
      let accessory = NSTitlebarAccessoryViewController()
      accessory.view = bar
      accessory.layoutAttribute = .bottom
      window.addTitlebarAccessoryViewController(accessory)
      shownBar = (accessory, bar)
      window.setContentSize(viewport)
      window.center()
      // cascade, so a second shown tab doesn't sit exactly on the first
      let offset = CGFloat(Browser.shownCount) * 30
      window.setFrameOrigin(NSPoint(x: window.frame.origin.x + offset, y: window.frame.origin.y - offset))
    }
    if !isShown {
      if Browser.shownCount == 0 {
        let front = NSWorkspace.shared.frontmostApplication
        Browser.previousApp = front?.processIdentifier == getpid() ? nil : front
      }
      Browser.shownCount += 1
      isShown = true
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  /// Puts a shown tab back off screen, headless and still rendering. The tab stays open.
  func hide() {
    guard isShown else { return }
    isShown = false
    Browser.shownCount -= 1
    defer {
      // give the keyboard back to whatever the person was using before we popped up
      if Browser.shownCount == 0 {
        if let previous = Browser.previousApp, !previous.isTerminated { previous.activate() } else { NSApp.hide(nil) }
        Browser.previousApp = nil
      }
    }
    if let (accessory, _) = shownBar, let i = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
      window.removeTitlebarAccessoryViewController(at: i)
    }
    shownBar = nil
    window.styleMask = [.borderless]
    Browser.makeHeadless(window)
    window.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: viewport), display: false)
    window.orderFrontRegardless()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard isShown else { return true }
    hide() // the close button / ⌘W on a shown tab means "done", never "close the tab"
    return false
  }

  func close() {
    isClosed = true
    hide()
    failRunningJS(CLIError("tab was closed while the script ran"))
    ownedPopups.forEach { $0.close() }
    ownedPopups = []
    finishLoad(.failure(CLIError("tab was closed")))
    web.stopLoading()
    window.close()
  }

  // MARK: loading

  func load(_ url: URL) async throws {
    lastStatus = nil
    lastFailure = nil
    requestedURL = url.absoluteString
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      finishLoad(.failure(CLIError("load of \(requestedURL ?? "?") was superseded by another load")))
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

  /// Waits until no navigation is in flight, polling; returns false if `expired()` turns true first.
  func waitUntilIdle(until expired: () -> Bool) async throws -> Bool {
    while web.isLoading {
      if expired() { return false }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    return true
  }

  private func finishLoad(_ result: Result<Void, Error>) {
    guard let c = pendingLoad else { return }
    pendingLoad = nil
    c.resume(with: result)
  }

  func webView(_ w: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
    lastFailure = nil
  }

  func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
    finishLoad(.success(()))
  }

  func webView(_ w: WKWebView, didFail _: WKNavigation!, withError error: Error) {
    navigationFailed(error)
  }

  func webView(_ w: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
    navigationFailed(error)
  }

  private func navigationFailed(_ error: Error) {
    let ns = error as NSError
    // superseded by a redirect or a newer navigation — keep waiting for that one to finish
    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
    let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
    let url = failing ?? requestedURL ?? "the page"
    lastFailure = "\(url): \(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    finishLoad(.failure(CLIError("load failed for \(url): \(ns.localizedDescription) (\(ns.domain) \(ns.code))")))
  }

  func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
    if response.isForMainFrame, let http = response.response as? HTTPURLResponse {
      lastStatus = http.statusCode
    }
    return .allow
  }

  func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
    lastFailure = "web content process crashed"
    failRunningJS(CLIError("the page's web content process crashed while the script ran"))
    finishLoad(.failure(CLIError("the page's web content process crashed")))
  }

  // MARK: popups (window.open — OAuth often uses these)

  func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration, for _: WKNavigationAction,
               windowFeatures _: WKWindowFeatures) -> WKWebView? {
    let popup: Browser
    do {
      popup = try Browser(configuration: cfg, visible: visible, title: "webkit-cli popup")
    } catch {
      printErr("webkit-cli: refusing popup: \((error as? CLIError)?.message ?? "\(error)")")
      return nil
    }
    if visible {
      popup.window.center()
      popup.window.makeKeyAndOrderFront(nil)
    }
    if let onPopup {
      onPopup(popup)
    } else {
      popup.onPageClose = { [weak self, weak popup] in
        popup?.close()
        self?.ownedPopups.removeAll { $0 === popup }
      }
      ownedPopups.append(popup)
    }
    return popup.web
  }

  func webViewDidClose(_ w: WKWebView) {
    onPageClose?()
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

  private static let navigatedAway = CLIError("""
    the page navigated away before the script finished. Split steps that change page: \
    `click <tab> …` then `wait <tab> --until-url …`
    """)

  /// Scripts in flight. A cross-document navigation destroys their context and WebKit may never call
  /// back, so a commit fails them all at once instead of letting them hang until --timeout.
  private var runningJS: [UUID: CheckedContinuation<Any?, Error>] = [:]

  func callJS(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
    // a closed web view may never call back
    guard !isClosed else { throw CLIError("tab was closed (the page closed itself, or `close`)") }
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
      let id = UUID()
      runningJS[id] = c
      web.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { [weak self] result in
        guard let c = self?.runningJS.removeValue(forKey: id) else { return }
        switch result {
        case .success(let value):
          c.resume(returning: value is NSNull ? nil : value)
        case .failure(let error as NSError):
          if let msg = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
            let plain = msg.hasPrefix("Error: ") ? String(msg.dropFirst(7)) : msg
            c.resume(throwing: CLIError("javascript error: \(plain)"))
          } else if error.localizedDescription.contains("no longer reachable") {
            c.resume(throwing: Browser.navigatedAway)
          } else {
            c.resume(throwing: CLIError("javascript failed: \(error.localizedDescription)"))
          }
        }
      }
    }
  }

  private func failRunningJS(_ error: CLIError) {
    let running = runningJS
    runningJS = [:]
    running.values.forEach { $0.resume(throwing: error) }
  }

  func webView(_ w: WKWebView, didCommit _: WKNavigation!) {
    failRunningJS(Browser.navigatedAway)
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
    guard visible else { return }
    ownedPopups.forEach { $0.window.close() }
    closed?.resume()
    closed = nil
  }
}
