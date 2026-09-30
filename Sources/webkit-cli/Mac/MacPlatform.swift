#if os(macOS)
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
func ephemeralStore() -> WKWebsiteDataStore { .nonPersistent() }

@MainActor
func auth(_ account: String, _ url: URL) async throws {
  // a running session holds the profile's session cookies in memory and would overwrite what we save
  if try SessionClient.stopIfRunning(account: account) {
    printErr("webkit-cli: stopped the running session for '\(account)' so the sign-in is saved cleanly")
  }
  installMenu()
  let profile = try await Profile.open(account, create: true)
  let browser = try Browser(store: profile.store, visible: true, title: "webkit-cli · \(account)")
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

/// remove(forIdentifier:) segfaults inside WebKit (WTF::RunLoop::dispatch) when it is the first WebKit
/// call in the process; touching a data store first sets up the run loop it posts its completion to.
@MainActor
func removeDataStore(_ id: UUID) async throws {
  _ = await WKWebsiteDataStore.nonPersistent().httpCookieStore.allCookies()
  try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
    WKWebsiteDataStore.remove(forIdentifier: id) { error in
      if let error { c.resume(throwing: CLIError("could not delete website data for \(id): \(error.localizedDescription)")) } else { c.resume() }
    }
  }
}

@MainActor
func installMenu() {
  guard NSApp.mainMenu?.items.isEmpty ?? true else { return }
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
  submenu("File", [item("Close Window", "performClose:", "w")])
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

func startApp(_ command: Command, _ options: Options) -> Never {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(command.isAuth ? .regular : .accessory)
    Task { @MainActor in
      do {
        try await run(command, options)
        exit(0)
      } catch {
        die(error)
      }
    }
    app.run()
  }
  fatalError("NSApplication.run returned")
}
#endif
