#if os(Linux)
import Foundation
import WPEShim

/// Where WebKit keeps each profile on Linux (not keyed by the binary name, unlike macOS).
enum LinuxPaths {
  static let data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/webkit-cli/profiles", isDirectory: true)
  static let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/webkit-cli", isDirectory: true)
  static func data(_ id: UUID) -> URL { data.appendingPathComponent(id.uuidString) }
  static func cache(_ id: UUID) -> URL { cache.appendingPathComponent(id.uuidString) }
}

/// An account's network session plus our side-car file of session-only cookies (same design as macOS).
@MainActor
struct Profile {
  let store: WebStore
  let sessionFile: URL?

  static func open(_ account: String, create: Bool = false) async throws -> Profile {
    if account == "-" { return Profile(store: ephemeralStore(), sessionFile: nil) }
    var accounts = try Accounts.load()
    let id = create || account == defaultAccount ? try accounts.create(account) : try accounts.id(of: account)
    try ensurePrivateDir(LinuxPaths.data(id))
    try ensurePrivateDir(LinuxPaths.cache(id))
    let profile = Profile(store: WebStore(dataDirectory: LinuxPaths.data(id).path, cacheDirectory: LinuxPaths.cache(id).path),
                          sessionFile: Accounts.sessionFile(for: id))
    try await restoreSessionCookies(into: profile.store, from: profile.sessionFile!)
    return profile
  }

  func close() async throws {
    guard let file = sessionFile else { return }
    let lines = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
      wk_session_session_cookies(store.handle, Unmanaged.passRetained(Box(c)).toOpaque(), cookiesDone)
    }
    try writePrivate(Data(lines.utf8), to: file)
  }
}

private func restoreSessionCookies(into store: WebStore, from file: URL) async throws {
  guard FileManager.default.fileExists(atPath: file.path) else { return }
  let text = try String(contentsOf: file, encoding: .utf8)
  for (i, line) in text.split(separator: "\n").enumerated() {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count == 6 else {
      throw CLIError("\(file.path): cookie line \(i + 1) is malformed — delete the file to drop saved session cookies")
    }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      wk_session_add_cookie(store.handle, f[0], f[1], f[2] == "1" ? 1 : 0, f[3] == "1" ? 1 : 0, f[4], f[5],
                            Unmanaged.passRetained(Box(c)).toOpaque(), cookieAdded)
    }
  }
}

final class Box<T> {
  let continuation: CheckedContinuation<T, Error>
  init(_ c: CheckedContinuation<T, Error>) { continuation = c }
}

private let cookiesDone: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = { req, lines, error in
  let box = Unmanaged<Box<String>>.fromOpaque(req!).takeRetainedValue()
  if let error { box.continuation.resume(throwing: CLIError("could not read cookies: \(String(cString: error))")) }
  else { box.continuation.resume(returning: lines.map { String(cString: $0) } ?? "") }
}

private let cookieAdded: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { req, error in
  let box = Unmanaged<Box<Void>>.fromOpaque(req!).takeRetainedValue()
  if let error { box.continuation.resume(throwing: CLIError("could not restore a cookie: \(String(cString: error))")) }
  else { box.continuation.resume() }
}

@MainActor
func ephemeralStore() -> WebStore { WebStore(dataDirectory: nil, cacheDirectory: nil) }

/// Same flow as macOS: a window on the profile; sign in; closing it (or Ctrl-C here) saves.
@MainActor
func auth(_ account: String, _ url: URL) async throws {
  try requireGUI()
  // a running session holds the profile's session cookies in memory and would overwrite what we save
  if try SessionClient.stopIfRunning(account: account) {
    printErr("webkit-cli: stopped the running session for '\(account)' so the sign-in is saved cleanly")
  }
  let profile = try await Profile.open(account, create: true)
  let window = try Browser(store: profile.store, visible: true, title: "webkit-cli · \(account) — sign in, then close this window")
  window.startLoad(url)
  printErr("webkit-cli: signing in as '\(account)' — close the window when you're finished (or Ctrl-C here).")
  let signals = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { MainActor.assumeIsolated { window.close() } }
    src.resume()
    return src
  }
  await window.waitUntilClosed()
  signals.forEach { $0.cancel() }
  let host = window.url?.host ?? "?"
  window.close()
  try await profile.close()
  print(try jsonString(["account": account, "saved": true, "lastHost": host] as [String: Any]))
}

@MainActor
func removeDataStore(_ id: UUID) async throws {
  for dir in [LinuxPaths.data(id), LinuxPaths.cache(id)] where FileManager.default.fileExists(atPath: dir.path) {
    try FileManager.default.removeItem(at: dir)
  }
}

@MainActor
func installMenu() {}

// libdispatch's main queue on Linux: its wake-up eventfd, and the call that drains it (what
// CoreFoundation's run loop uses). Draining it from the GLib loop runs @MainActor work next to WebKit.
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchMainQueueHandle() -> Int32
@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueDrain(_ msg: UnsafeMutableRawPointer?)

private let drainMainQueue: @convention(c) () -> Void = { dispatchMainQueueDrain(nil) }

/// WebKit sandboxes its web processes with bubblewrap, which needs unprivileged user namespaces.
/// Where those are blocked (docker's default seccomp, some sandboxes) WebKit aborts on the first page,
/// so check up front and say so, instead of crashing mid-command.
private func requireWebKitSandbox() throws {
  if ProcessInfo.processInfo.environment["WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS"] == "1" { return }
  let probe = Process()
  probe.executableURL = URL(fileURLWithPath: "/usr/bin/bwrap")
  // roughly what WebKit asks bwrap for: new user+pid namespaces and a fresh /proc
  probe.arguments = ["--ro-bind", "/", "/", "--unshare-user", "--unshare-pid", "--proc", "/proc", "true"]
  probe.standardError = FileHandle.nullDevice
  do { try probe.run() } catch {
    throw CLIError("WebKit's sandbox needs /usr/bin/bwrap (package bubblewrap): \(error.localizedDescription)")
  }
  probe.waitUntilExit()
  guard probe.terminationStatus == 0 else {
    throw CLIError("""
      WebKit's sandbox can't start here: bwrap can't create user/pid namespaces or mount /proc. \
      Run where unprivileged user namespaces work (docker: --privileged), \
      or set WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 to run pages without WebKit's sandbox.
      """)
  }
}

func startApp(_ command: Command, _ options: Options) -> Never {
  do { try requireWebKitSandbox() } catch { die(error) }
  if let error = wk_init() { die(CLIError(String(cString: error))) }
  Task { @MainActor in
    do {
      try await run(command, options)
      exit(0)
    } catch {
      die(error)
    }
  }
  wk_main_loop_run(dispatchMainQueueHandle(), drainMainQueue)
  fatalError("GLib main loop returned")
}
#endif
