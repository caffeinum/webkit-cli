import AppKit
import WebKit

/// An account's website data store plus our side-car file of session-only cookies.
@MainActor
struct Profile {
  let store: WKWebsiteDataStore
  let sessionFile: URL?

  static func open(_ account: String, create: Bool = false) async throws -> Profile {
    if account == "-" { return Profile(store: .nonPersistent(), sessionFile: nil) }
    try Accounts.requirePinnedExecutableName()
    var accounts = try Accounts.load()
    // the default profile is created on first use; a named one must come from `auth` so typos fail loudly
    let id = create || account == defaultAccount ? try accounts.create(account) : try accounts.id(of: account)
    let profile = Profile(store: WKWebsiteDataStore(forIdentifier: id), sessionFile: Accounts.sessionFile(for: id))
    try await SessionCookies.restore(into: profile.store, from: profile.sessionFile!)
    return profile
  }

  func close() async throws {
    guard let file = sessionFile else { return }
    try await SessionCookies.save(from: store, to: file)
  }
}

@MainActor
func run(_ command: Command, _ opts: Options) async throws {
  switch command {
  case .help:
    print(helpText)
  case .accounts:
    let accounts = try Accounts.load()
    let rows = accounts.byName.keys.sorted().map { ["name": $0, "id": accounts.byName[$0]!.uuidString] }
    print(try jsonString(rows))
  case .auth(let account, let url):
    try await auth(account, url)
  case .open(let account, let url):
    try await headless(account, url, opts) { b in
      print(try jsonString(try await pageInfo(b)))
    }
  case .text(let account, let url):
    try await headless(account, url, opts) { b in
      guard let text = try await b.callJS("return document.body ? document.body.innerText : null") as? String else {
        throw CLIError("page has no <body>")
      }
      print(text)
    }
  case .eval(let account, let url, let js):
    try await headless(account, url, opts) { b in
      if let json = try await b.evalJSON(js) {
        print(json)
      } else {
        print("null")
        if !js.contains("return") {
          printErr("webkit-cli: note: result was undefined — eval runs your code as an async function body, so use `return <value>`")
        }
      }
    }
  case .shot(let account, let url, let out):
    try await headless(account, url, opts) { b in
      let shot = try await b.snapshotPNG()
      try writePNG(shot.data, to: out)
      var info = try await pageInfo(b)
      info["path"] = out.path
      info["width"] = shot.width
      info["height"] = shot.height
      print(try jsonString(info))
    }
  case .forget(let account):
    try Accounts.requirePinnedExecutableName()
    var accounts = try Accounts.load()
    let id = try accounts.id(of: account)
    try await removeDataStore(id)
    try? FileManager.default.removeItem(at: Accounts.sessionFile(for: id))
    try accounts.remove(account)
    print(try jsonString(["forgot": account, "id": id.uuidString]))
  case .doctor:
    try await doctor(opts)
  }
}

@MainActor
private func headless(_ account: String, _ url: URL, _ opts: Options, _ body: (Browser) async throws -> Void) async throws {
  startWatchdog(opts.timeout)
  let profile = try await Profile.open(account)
  let browser = try Browser(store: profile.store, visible: false)
  try await browser.load(url)
  try await Task.sleep(nanoseconds: UInt64(opts.wait * 1e9))
  try await body(browser)
  try await profile.close()
}

@MainActor
private func auth(_ account: String, _ url: URL) async throws {
  installMenu()
  let profile = try await Profile.open(account, create: true)
  let browser = try Browser(store: profile.store, visible: true,
                            title: "webkit-cli · \(account)")
  browser.web.load(URLRequest(url: url))
  printErr("webkit-cli: signing in as '\(account)' — click Done in the window when you're finished (or close it / Ctrl-C here).")
  let signals = closeOnSignals(browser.window)
  await browser.waitUntilClosed()
  signals.forEach { $0.cancel() }
  try await profile.close()
  let host = browser.web.url?.host ?? "?"
  print(try jsonString(["account": account, "saved": true, "lastHost": host] as [String: Any]))
}

/// Ctrl-C / SIGTERM close the auth window the normal way, so session cookies still get saved.
@MainActor
private func closeOnSignals(_ window: NSWindow) -> [DispatchSourceSignal] {
  [SIGINT, SIGTERM, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { MainActor.assumeIsolated { window.close() } }
    src.resume()
    return src
  }
}

@MainActor
private func pageInfo(_ b: Browser) async throws -> [String: Any] {
  var info: [String: Any] = [
    "url": b.web.url?.absoluteString ?? NSNull(),
    "title": try await b.callJS("return document.title") ?? NSNull(),
  ]
  info["status"] = b.lastStatus ?? NSNull()
  return info
}

private let doctorProbe = """
  return await new Promise(resolve => {
    let raf = 0, ticks = 0;
    const t0 = performance.now();
    const frame = () => { raf++; if (performance.now() - t0 < 2000) requestAnimationFrame(frame); };
    requestAnimationFrame(frame);
    const iv = setInterval(() => ticks++, 10);
    setTimeout(() => {
      clearInterval(iv);
      resolve({ visibilityState: document.visibilityState, hidden: document.hidden,
                rafPerSecond: raf / 2, timerTicksPerSecond: ticks / 2, ms: Math.round(performance.now() - t0) });
    }, 2000);
  });
  """

@MainActor
private func doctor(_ opts: Options) async throws {
  startWatchdog(opts.timeout)
  let browser = try Browser(store: .nonPersistent(), visible: false)
  try await browser.loadHTML("<!doctype html><title>webkit-cli doctor</title><body>probe</body>",
                             baseURL: URL(string: "https://webkit-cli.localhost/")!)
  guard let result = try await browser.callJS(doctorProbe) as? [String: Any] else {
    throw CLIError("doctor probe returned nothing")
  }
  var report = result
  report["userAgent"] = browser.web.customUserAgent
  report["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
  print(try jsonString(report))
  let visible = result["visibilityState"] as? String == "visible"
  let raf = (result["rafPerSecond"] as? Double) ?? 0
  guard visible, raf > 0 else {
    throw CLIError("FAIL: headless page is throttled (visibilityState=\(result["visibilityState"] ?? "?"), rAF/s=\(raf))")
  }
  printErr("webkit-cli: doctor OK — headless page is visible and animating")
}

/// remove(forIdentifier:) segfaults inside WebKit (WTF::RunLoop::dispatch) when it is the first WebKit
/// call in the process; touching a data store first sets up the run loop it posts its completion to.
@MainActor
private func removeDataStore(_ id: UUID) async throws {
  _ = await WKWebsiteDataStore.nonPersistent().httpCookieStore.allCookies()
  try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
    WKWebsiteDataStore.remove(forIdentifier: id) { error in
      if let error { c.resume(throwing: CLIError("could not delete website data for \(id): \(error.localizedDescription)")) } else { c.resume() }
    }
  }
}

private func startWatchdog(_ seconds: Double) {
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    die(CLIError("timed out after \(Int(seconds))s (raise with --timeout)", code: ExitCode.timeout))
  }
}

private func writePNG(_ data: Data, to url: URL) throws {
  let dir = url.deletingLastPathComponent()
  guard FileManager.default.fileExists(atPath: dir.path) else { throw CLIError("directory does not exist: \(dir.path)") }
  guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
    throw CLIError("could not write \(url.path)")
  }
}

func jsonString(_ value: Any) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
  return String(decoding: data, as: UTF8.self)
}

@MainActor
private func installMenu() {
  let main = NSMenu()
  func submenu(_ title: String, _ items: [NSMenuItem]) {
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    holder.submenu = menu
    main.addItem(holder)
  }
  func item(_ title: String, _ action: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
    i.keyEquivalentModifierMask = mods
    return i
  }
  submenu("webkit-cli", [item("Save and Quit", "performClose:", "q")])
  submenu("File", [item("Close Window (saves)", "performClose:", "w")])
  submenu("Edit", [
    item("Undo", "undo:", "z"),
    item("Redo", "redo:", "z", [.command, .shift]),
    .separator(),
    item("Cut", "cut:", "x"),
    item("Copy", "copy:", "c"),
    item("Paste", "paste:", "v"),
    item("Select All", "selectAll:", "a"),
  ])
  submenu("View", [item("Reload", "reload:", "r"), item("Back", "goBack:", "[")])
  NSApp.mainMenu = main
}
