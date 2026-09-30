import Foundation

/// Commands that need no WebKit run synchronously before the app starts; returns false for the rest.
func runWithoutApp(_ command: Command) throws -> Bool {
  switch command {
  case .help:
    print(helpText)
  case .accounts:
    let accounts = try Accounts.load()
    let rows = accounts.byName.keys.sorted().map { ["name": $0, "id": accounts.byName[$0]!.uuidString] }
    print(try jsonString(rows))
  case .stop(let account):
    try Accounts.validate(account)
    let stopped = try SessionClient.stopIfRunning(account: account)
    print(try jsonString(["account": account, "stopped": stopped] as [String: Any]))
  case .session(let account, let request) where account != "-":
    try Accounts.requirePinnedExecutableName()
    try Accounts.validate(account)
    if account != defaultAccount { _ = try Accounts.load().id(of: account) }
    let resp = try SessionClient.send(request, account: account, idle: options.idle)
    guard resp.ok else { throw CLIError(resp.error ?? "session command failed", code: resp.code ?? ExitCode.failure) }
    try emit(resp.output ?? "", options)
  default:
    return false
  }
  return true
}

/// Prints a command's output, or with --out writes it to a 0600 file and prints only where and how much.
func emit(_ result: String, _ opts: Options) throws {
  var output = result
  if opts.raw, let s = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: .fragmentsAllowed) as? String {
    output = s
  }
  guard let path = opts.out else {
    print(output)
    return
  }
  let data = Data(output.utf8)
  try writePrivateFile(data, to: URL(fileURLWithPath: path))
  print(try jsonString(["written": path, "bytes": data.count] as [String: Any]))
}

@MainActor
func run(_ command: Command, _ opts: Options) async throws {
  switch command {
  case .help, .accounts, .stop:
    preconditionFailure("handled by runWithoutApp")
  case .session(_, let request):
    // throwaway profile: no session process, tabs die with this command
    startWatchdog(opts.timeout)
    if let target = request.target, isTabID(target) {
      throw CLIError("the throwaway profile `-` has no session, so no tabs — pass a URL, or use a saved profile", code: ExitCode.usage)
    }
    let engine = Engine(profile: try await Profile.open("-"), keepsTabs: false)
    let output = try await Engine.$noteSink.withValue({ printErr("webkit-cli: \($0)") }) {
      try await engine.handle(request, deadline: Deadline(request.timeout))
    }
    try emit(output, opts)
  case .serve(let account, let idle):
    guard try SessionServer.claim(account) else {
      printErr("webkit-cli: a session for '\(account)' is already running")
      exit(0)
    }
    let server = SessionServer(account: account, profile: try await Profile.open(account), idle: idle)
    try server.start()
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } // never resumed: the server exits the process on idle/stop
  case .auth(let account, let url):
    try await auth(account, url)
  case .forget(let account):
    try Accounts.requirePinnedExecutableName()
    var accounts = try Accounts.load()
    let id = try accounts.id(of: account)
    _ = try SessionClient.stopIfRunning(account: account)
    try await removeDataStore(id)
    try? FileManager.default.removeItem(at: Accounts.sessionFile(for: id))
    for leftover in [SessionPaths.lock(account), SessionPaths.log(account), SessionPaths.socket(account)] {
      try? FileManager.default.removeItem(atPath: leftover)
    }
    try accounts.remove(account)
    print(try jsonString(["forgot": account, "id": id.uuidString]))
  case .doctor:
    try await doctor(opts)
  }
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
  let browser = try Browser(store: ephemeralStore(), visible: false)
  try await browser.loadHTML("<!doctype html><title>webkit-cli doctor</title><body>probe</body>",
                             baseURL: URL(string: "https://webkit-cli.localhost/")!)
  guard let result = try await browser.callJS(doctorProbe) as? [String: Any] else {
    throw CLIError("doctor probe returned nothing")
  }
  var report = result
  report["userAgent"] = browser.userAgent ?? NSNull()
  report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
  print(try jsonString(report))
  let visible = result["visibilityState"] as? String == "visible"
  let raf = (result["rafPerSecond"] as? Double) ?? 0
  guard visible, raf > 0 else {
    throw CLIError("FAIL: headless page is throttled (visibilityState=\(result["visibilityState"] ?? "?"), rAF/s=\(raf))")
  }
  printErr("webkit-cli: doctor OK — headless page is visible and animating")
}

func startWatchdog(_ seconds: Double) {
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    die(CLIError("timed out after \(Int(seconds))s (raise with --timeout)", code: ExitCode.timeout))
  }
}

func jsonString(_ value: Any) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
  return String(decoding: data, as: UTF8.self)
}

