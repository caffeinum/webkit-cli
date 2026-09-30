#if os(Linux)
import Foundation
import WPEShim

let viewportWidth: Int32 = 1280
let viewportHeight: Int32 = 800

/// A profile's WebKit network session (cookies, storage), owned for the life of the process.
final class WebStore {
  let handle: OpaquePointer

  init(dataDirectory: String?, cacheDirectory: String?) {
    handle = wk_session_new(dataDirectory, cacheDirectory)
  }
}

/// One WPE web view on the headless display: a tab. Same surface as the macOS Browser, so the shared
/// Engine, daemon and snapshot code don't know which backend runs them.
@MainActor
final class Browser {
  private var tab: OpaquePointer?
  private(set) var lastStatus: Int?
  private(set) var lastFailure: String?
  private(set) var isClosed = false
  var nextRef = 1
  private let store: WebStore?
  /// true for `auth`'s window and for the window `show` opens
  let visible: Bool
  /// While shown: the visible window a person works in. The page can't move between displays on
  /// Linux, so it's a second view on the same profile; commands on this tab act on it until `hide`.
  private var presented: Browser?
  var isShown: Bool { presented != nil }
  /// Called when a person closes a visible window.
  var onWindowClosed: (() -> Void)?
  private var closedWaiter: CheckedContinuation<Void, Never>?

  var onPopup: ((Browser) -> Void)?
  var onPageClose: (() -> Void)?
  private var ownedPopups: [Browser] = []

  private var pendingLoad: CheckedContinuation<Void, Error>?
  private var requestedURL: String?
  private var runningJS: [ObjectIdentifier: JSCall] = [:]

  convenience init(store: WebStore, visible: Bool, title: String = "webkit-cli") throws {
    if visible {
      try requireGUI()
      guard let tab = wk_tab_new_visible(store.handle, nil, title, viewportWidth, viewportHeight) else {
        throw CLIError("could not open a window on the Wayland display")
      }
      self.init(adopting: tab, store: store, visible: true)
    } else {
      guard let tab = wk_tab_new(store.handle, nil, viewportWidth, viewportHeight) else { throw CLIError("could not create a WPE web view") }
      self.init(adopting: tab, store: store, visible: false)
    }
  }

  private init(adopting tab: OpaquePointer, store: WebStore?, visible: Bool) {
    self.tab = tab
    self.store = store
    self.visible = visible
    var callbacks = wk_callbacks(load: onLoad, status: onStatus, closed: onClosed, crashed: onCrashed, popup: onPopupCreated,
                                 window_closed: onWindowClosedCallback)
    wk_tab_set_ctx(tab, Unmanaged.passUnretained(self).toOpaque(), &callbacks)
  }

  var url: URL? { presented?.url ?? ownURL ?? closedURL }
  /// where the page was when the tab closed (auth reports the host it ended on)
  private var closedURL: URL?
  var title: String? { presented?.title ?? tab.flatMap { wk_tab_title($0) }.map { String(cString: $0) } }
  var isLoading: Bool { presented?.isLoading ?? (tab.map { wk_tab_is_loading($0) != 0 } ?? false) }
  private var ownURL: URL? { tab.flatMap { wk_tab_uri($0) }.flatMap { URL(string: String(cString: $0)) } }
  var userAgent: String? { tab.flatMap { wk_tab_user_agent($0) }.map { String(cString: $0) } }

  func close() {
    guard let tab else { return }
    closedURL = ownURL
    isClosed = true
    presented?.close()
    presented = nil
    closedWaiter?.resume()
    closedWaiter = nil
    failRunningJS(CLIError("tab was closed while the script ran"))
    finishLoad(.failure(CLIError("tab was closed")))
    ownedPopups.forEach { $0.close() }
    ownedPopups = []
    wk_tab_close(tab)
    self.tab = nil
  }

  // MARK: showing to a person

  /// Opens a window on the same profile at this tab's page, titled with `reason`. Cookies are shared,
  /// in-page state is not (a WPE page can't move from the headless display to the screen).
  func show(reason: String, activate: Bool = false) throws {
    let title = "webkit-cli — needs you: \(reason)"
    if let presented {
      presented.setTitle(title)
      return
    }
    guard let store else { throw CLIError("this tab has no profile to show") }
    let window = try Browser(store: store, visible: true, title: title)
    window.onWindowClosed = { [weak self] in self?.hide() }
    presented = window
    if let url = ownURL { window.startLoad(url) }
    // park the headless copy so the page never runs twice (challenge pages poll and submit); `hide`
    // brings it back at wherever the person ended up
    if let tab { wk_tab_load(tab, "about:blank") }
  }

  /// Closes the window and carries on in the headless tab from the page the person ended on.
  func hide() {
    guard let window = presented else { return }
    presented = nil
    let ended = window.url
    window.close()
    if let ended, ended != ownURL { startLoad(ended) }
  }

  func setTitle(_ title: String) {
    if let tab { wk_tab_set_title(tab, title) }
  }

  /// Starts a load without waiting for it (the caller polls `isLoading`).
  func startLoad(_ url: URL) {
    guard let tab else { return }
    requestedURL = url.absoluteString
    lastStatus = nil
    wk_tab_load(tab, url.absoluteString)
  }

  /// For `auth`: until the person closes the window (or `close()`).
  func waitUntilClosed() async {
    if isClosed { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in closedWaiter = c }
  }

  fileprivate func windowClosed() {
    if let onWindowClosed {
      onWindowClosed()
    } else {
      close()
    }
  }

  // MARK: loading

  func load(_ url: URL) async throws {
    guard let tab else { throw CLIError("tab was closed") }
    lastStatus = nil
    lastFailure = nil
    requestedURL = url.absoluteString
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      finishLoad(.failure(CLIError("load of \(requestedURL ?? "?") was superseded by another load")))
      pendingLoad = c
      wk_tab_load(tab, url.absoluteString)
    }
  }

  func loadHTML(_ html: String, baseURL: URL) async throws {
    guard let tab else { throw CLIError("tab was closed") }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      pendingLoad = c
      wk_tab_load_html(tab, html, baseURL.absoluteString)
    }
  }

  func waitUntilIdle(until expired: () -> Bool) async throws -> Bool {
    while isLoading {
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

  fileprivate func loadEvent(_ event: Int32, _ error: String?) {
    switch Int(event) {
    case Int(WK_LOAD_STARTED):
      lastFailure = nil
    case Int(WK_LOAD_COMMITTED):
      failRunningJS(Browser.navigatedAway)
    case Int(WK_LOAD_FINISHED):
      finishLoad(.success(()))
    case Int(WK_LOAD_FAILED):
      lastFailure = error
      finishLoad(.failure(CLIError(error ?? "load failed for \(requestedURL ?? "the page")")))
    default:
      break // cancelled: superseded by a redirect or a newer navigation — keep waiting
    }
  }

  fileprivate func status(_ code: Int32) { lastStatus = Int(code) }

  fileprivate func crashed() {
    lastFailure = "web content process crashed"
    failRunningJS(CLIError("the page's web content process crashed while the script ran"))
    finishLoad(.failure(CLIError("the page's web content process crashed")))
  }

  fileprivate func pageClosed() { onPageClose?() }

  fileprivate func adoptPopup(_ child: OpaquePointer) {
    let popup = Browser(adopting: child, store: store, visible: visible)
    if let onPopup {
      onPopup(popup)
    } else {
      popup.onPageClose = { [weak self, weak popup] in
        popup?.close()
        self?.ownedPopups.removeAll { $0 === popup }
      }
      ownedPopups.append(popup)
    }
  }

  // MARK: scripting

  private static let navigatedAway = CLIError("""
    the page navigated away before the script finished. Split steps that change page: \
    `click <tab> …` then `wait <tab> --until-url …`
    """)

  /// Runs `body` as the body of an async function; returns its JSON-encoded result, or nil for undefined.
  func evalJSON(_ body: String) async throws -> String? {
    let wrapped = """
      const __webkitCliResult = await (async () => {
      \(body)
      })();
      return __webkitCliResult === undefined ? undefined : JSON.stringify(__webkitCliResult);
      """
    return try await callJS(wrapped) as? String
  }

  /// `args` become constants of the same names inside `body` (passed as one JSON string: the C API
  /// takes a GVariant dictionary, and a single string keeps that simple).
  func callJS(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
    if let presented { return try await presented.callJS(body, args) }
    guard let tab else { throw CLIError("tab was closed (the page closed itself, or `close`)") }
    let argsJSON = try jsonString(args)
    let prelude = args.keys.sorted().map { "const \($0) = __wkArgs[\(try! jsonString($0))];" }.joined(separator: "\n")
    let source = "__wkArgs = JSON.parse(__wkArgs);\n\(prelude)\n\(body)"
    let json: String? = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String?, Error>) in
      let call = JSCall(c)
      runningJS[ObjectIdentifier(call)] = call
      call.onFinish = { [weak self] in self?.runningJS[ObjectIdentifier(call)] = nil }
      wk_tab_call_js(tab, source, "__wkArgs", argsJSON, Unmanaged.passRetained(call).toOpaque(), jsDone)
    }
    guard let json else { return nil }
    return try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
  }

  private func failRunningJS(_ error: CLIError) {
    let running = runningJS
    runningJS = [:]
    running.values.forEach { $0.finish(.failure(error)) }
  }

  func snapshotPNG() async throws -> (data: Data, width: Int, height: Int) {
    if let presented { return try await presented.snapshotPNG() }
    guard let tab else { throw CLIError("tab was closed") }
    try ensurePrivateDir(Accounts.configDir)
    let tmp = Accounts.configDir.appendingPathComponent(".shot-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let (w, h) = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Int, Int), Error>) in
      wk_tab_snapshot_png(tab, tmp.path, Unmanaged.passRetained(SnapCall(c)).toOpaque(), snapDone)
    }
    return (try Data(contentsOf: tmp), w, h)
  }
}

/// A JS call in flight: resumed once, by WebKit's answer or by a navigation that kills its context.
final class JSCall {
  private var continuation: CheckedContinuation<String?, Error>?
  var onFinish: (() -> Void)?

  init(_ c: CheckedContinuation<String?, Error>) { continuation = c }

  func finish(_ result: Result<String?, Error>) {
    guard let c = continuation else { return }
    continuation = nil
    onFinish?()
    c.resume(with: result)
  }
}

final class SnapCall {
  let continuation: CheckedContinuation<(Int, Int), Error>
  init(_ c: CheckedContinuation<(Int, Int), Error>) { continuation = c }
}

// MARK: C callbacks → the Swift tab

private func browser(_ ctx: UnsafeMutableRawPointer?) -> Browser? {
  ctx.map { Unmanaged<Browser>.fromOpaque($0).takeUnretainedValue() }
}

private let onLoad: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void = { ctx, event, error in
  let message = error.map { String(cString: $0) }
  MainActor.assumeIsolated { browser(ctx)?.loadEvent(event, message) }
}
private let onStatus: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ctx, code in
  MainActor.assumeIsolated { browser(ctx)?.status(code) }
}
private let onClosed: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
  MainActor.assumeIsolated { browser(ctx)?.pageClosed() }
}
private let onCrashed: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
  MainActor.assumeIsolated { browser(ctx)?.crashed() }
}
private let onWindowClosedCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
  MainActor.assumeIsolated { browser(ctx)?.windowClosed() }
}
private let onPopupCreated: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?) -> Void = { ctx, child in
  guard let child else { return }
  MainActor.assumeIsolated { browser(ctx)?.adoptPopup(child) }
}

private let jsDone: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void = { req, json, undefined, error in
  guard let req else { return }
  let call = Unmanaged<JSCall>.fromOpaque(req).takeRetainedValue()
  if let error {
    var msg = String(cString: error)
    if msg.hasPrefix("Error: ") { msg.removeFirst(7) }
    if msg.hasPrefix("WKCLI: ") {
      call.finish(.failure(CLIError(String(msg.dropFirst(7)))))
    } else {
      call.finish(.failure(CLIError("javascript error: \(msg)")))
    }
  } else if undefined != 0 {
    call.finish(.success(nil))
  } else {
    call.finish(.success(json.map { String(cString: $0) } ?? "null"))
  }
}

private let snapDone: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?) -> Void = { req, w, h, error in
  guard let req else { return }
  let call = Unmanaged<SnapCall>.fromOpaque(req).takeRetainedValue()
  if let error {
    call.continuation.resume(throwing: CLIError("snapshot failed: \(String(cString: error))"))
  } else {
    call.continuation.resume(returning: (Int(w), Int(h)))
  }
}

/// Connects the Wayland display on first use; a person can only be shown a window where one exists.
@MainActor
func requireGUI() throws {
  if let error = wk_init_gui() {
    throw CLIError("""
      can't show a window: \(String(cString: error)). webkit-cli's windows on Linux need a Wayland session \
      (WPE has no X11 support; on X11, run a Wayland compositor such as `weston --backend=x11` and use its WAYLAND_DISPLAY)
      """)
  }
}

@MainActor
func hasGUISession() -> Bool { (try? requireGUI()) != nil }
func screenIsLocked() -> Bool { false }
#endif
