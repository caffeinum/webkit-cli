import AppKit
import Darwin

/// One long-lived process per profile holds its tabs, so multi-page flows (OAuth redirects, "click then
/// read") survive between commands, and session-only cookies stay alive. Commands reach it over a unix
/// socket in ~/.config/webkit-cli/run (0700); the first command starts it, idleness ends it.
enum SessionPaths {
  static let runDir = Accounts.configDir.appendingPathComponent("run", isDirectory: true)
  static func socket(_ account: String) -> String { runDir.appendingPathComponent("\(account).sock").path }
  static func lock(_ account: String) -> String { runDir.appendingPathComponent("\(account).lock").path }
  static func log(_ account: String) -> String { runDir.appendingPathComponent("\(account).log").path }
}

let defaultIdleSeconds: Double = 15 * 60

// MARK: client

enum SessionClient {
  /// Sends one request to the profile's session process, starting it if needed.
  static func send(_ req: Request, account: String, idle: Double) throws -> Response {
    try ensurePrivateDir(SessionPaths.runDir)
    let path = SessionPaths.socket(account)
    var fd = try? connect(path)
    if fd == nil {
      try spawnServer(account: account, idle: idle)
      let giveUp = Date().addingTimeInterval(20)
      while fd == nil {
        guard Date() < giveUp else {
          throw CLIError("session process for '\(account)' did not start within 20s — see \(SessionPaths.log(account))")
        }
        usleep(100_000)
        fd = try? connect(path)
      }
    }
    return try exchange(fd!, req)
  }

  /// Asks a running session to stop; returns false if none was running.
  static func stopIfRunning(account: String) throws -> Bool {
    guard let fd = try? connect(SessionPaths.socket(account)) else { return false }
    let resp = try exchange(fd, Request(cmd: "stop", timeout: 30))
    guard resp.ok else { throw CLIError(resp.error ?? "stop failed") }
    // wait until the process has exited (its lock is released) before the caller touches the store
    let giveUp = Date().addingTimeInterval(10)
    while !SessionServer.lockIsFree(account) {
      guard Date() < giveUp else { throw CLIError("session for '\(account)' did not exit within 10s of stop") }
      usleep(50_000)
    }
    return true
  }

  private static func exchange(_ fd: Int32, _ req: Request) throws -> Response {
    defer { close(fd) }
    var tv = timeval(tv_sec: Int(req.timeout) + 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var line = try JSONEncoder().encode(req)
    line.append(0x0A)
    try writeAll(fd, line)
    shutdown(fd, SHUT_WR)
    let data = try readAll(fd)
    guard !data.isEmpty else { throw CLIError("session process closed the connection without answering (crashed? see its log)") }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw CLIError("unreadable answer from session process: \(String(decoding: data.prefix(200), as: UTF8.self))")
    }
  }

  private static func spawnServer(account: String, idle: Double) throws {
    guard let exe = Bundle.main.executablePath else { throw CLIError("cannot find own executable path") }
    let logPath = SessionPaths.log(account)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let args = [exe, "serve", "--account", account, "--idle", String(idle)]
    var argv = args.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &actions, &attr, &argv, environ)
    guard rc == 0 else { throw CLIError("could not start session process: \(String(cString: strerror(rc)))") }
  }
}

// MARK: server

@MainActor
final class SessionServer {
  private let account: String
  private let engine: Engine
  private let idle: Double
  private var active = 0
  private var lastActivity = Date()
  private var listenFD: Int32 = -1

  init(account: String, profile: Profile, idle: Double) {
    self.account = account
    self.engine = Engine(profile: profile, keepsTabs: true)
    self.idle = idle
  }

  /// Takes the profile's lock. Returns false if another live session is serving this profile.
  /// A session that is shutting down still holds the lock for a moment after its socket is gone,
  /// so a busy lock with no socket means "wait for it", not "someone else is serving".
  nonisolated static func claim(_ account: String) throws -> Bool {
    try ensurePrivateDir(SessionPaths.runDir)
    let fd = open(SessionPaths.lock(account), O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw CLIError("cannot open \(SessionPaths.lock(account)): \(String(cString: strerror(errno)))") }
    let giveUp = Date().addingTimeInterval(15)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      if let live = try? connect(SessionPaths.socket(account)) {
        close(live)
        close(fd)
        return false
      }
      guard Date() < giveUp else {
        close(fd)
        throw CLIError("the lock for '\(account)' is held but nothing is serving — is a session stuck? (\(SessionPaths.lock(account)))")
      }
      usleep(50_000)
    }
    return true // fd stays open (and locked) for the life of the process
  }

  /// True once no process holds the profile's lock.
  nonisolated static func lockIsFree(_ account: String) -> Bool {
    let fd = open(SessionPaths.lock(account), O_RDWR)
    guard fd >= 0 else { return true }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
    flock(fd, LOCK_UN)
    return true
  }

  func start() throws {
    let path = SessionPaths.socket(account)
    unlink(path)
    listenFD = try listenUnix(path)
    log("session for '\(account)' listening (pid \(getpid()), idle timeout \(Int(idle))s)")
    let fd = listenFD
    Thread.detachNewThread { [weak self] in
      while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
          close(client)
          continue
        }
        let data = (try? readLine(client)) ?? Data()
        Task { @MainActor [weak self] in self?.enqueue(client, data) }
      }
    }
    scheduleIdleCheck()
  }

  /// Requests run one at a time, in arrival order: two scripts poking the same tab concurrently
  /// would race each other's clicks and waits.
  private var queue: Task<Void, Never>?

  private func enqueue(_ fd: Int32, _ data: Data) {
    active += 1
    lastActivity = Date()
    let previous = queue
    let arrived = Date()
    queue = Task { @MainActor in
      await previous?.value
      await self.serve(fd, data, arrived: arrived)
    }
  }

  private func serve(_ fd: Int32, _ data: Data, arrived: Date) async {
    lastActivity = Date()
    var stopAfter = false
    let resp: Response
    var request: Request?
    do {
      let req = try JSONDecoder().decode(Request.self, from: data)
      request = req
      if req.cmd == "stop" {
        stopAfter = true
        resp = Response(ok: true, output: try jsonString(["stopped": account]))
      } else {
        // --timeout counts from arrival, so time spent queued behind another request is included
        let queued = Date().timeIntervalSince(arrived)
        guard queued < req.timeout else {
          throw CLIError("""
            \(req.cmd) timed out after \(Int(req.timeout))s queued behind another request on this profile \
            (one command runs at a time) — raise --timeout or wait for the other command
            """, code: ExitCode.timeout)
        }
        var inTime = req
        inTime.timeout = req.timeout - queued
        let output = try await withTimeout(inTime.timeout, cmd: req.cmd) { try await self.engine.handle(inTime) }
        resp = Response(ok: true, output: output, notes: engine.notes.isEmpty ? nil : engine.notes)
      }
    } catch let e as CLIError {
      var message = e.message
      if e.code == ExitCode.timeout, let target = request?.target, let url = engine.location(of: target), !message.contains(url) {
        message += " — \(target) is at \(url)"
      }
      resp = Response(ok: false, error: message, code: e.code)
    } catch {
      resp = Response(ok: false, error: "\(error)", code: ExitCode.failure)
    }
    do { try await engine.profile.close() } catch { log("could not save session cookies: \(error)") }
    let out = (try? JSONEncoder().encode(resp)) ?? Data()
    DispatchQueue.global().async {
      try? writeAll(fd, out)
      close(fd)
    }
    active -= 1
    lastActivity = Date()
    if stopAfter { await shutdown("stop requested") }
  }

  private func scheduleIdleCheck() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.active == 0 && Date().timeIntervalSince(self.lastActivity) > self.idle {
          Task { await self.shutdown("idle for \(Int(self.idle))s") }
        } else {
          self.scheduleIdleCheck()
        }
      }
    }
  }

  private func shutdown(_ reason: String) async {
    unlink(SessionPaths.socket(account))
    engine.closeAll()
    do { try await engine.profile.close() } catch { log("could not save session cookies: \(error)") }
    log("session for '\(account)' exiting: \(reason)")
    // let the last response flush
    try? await Task.sleep(nanoseconds: 200_000_000)
    exit(0)
  }

  private func log(_ s: String) {
    printErr("[\(ISO8601DateFormatter().string(from: Date()))] \(s)")
  }
}

/// Resolves with the body's result, or throws a timeout error once `seconds` pass (the body keeps running).
@MainActor
func withTimeout(_ seconds: Double, cmd: String, _ body: @escaping @MainActor () async throws -> String) async throws -> String {
  try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
    var done = false
    Task { @MainActor in
      let result: Result<String, Error>
      do { result = .success(try await body()) } catch { result = .failure(error) }
      if !done { done = true; c.resume(with: result) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      MainActor.assumeIsolated {
        if !done {
          done = true
          c.resume(throwing: CLIError("\(cmd) timed out after \(Int(seconds.rounded(.up)))s (raise with --timeout)", code: ExitCode.timeout))
        }
      }
    }
  }
}

// MARK: sockets

private func sockaddr(_ path: String) throws -> sockaddr_un {
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let cap = MemoryLayout.size(ofValue: addr.sun_path)
  guard bytes.count < cap else { throw CLIError("socket path too long (\(bytes.count) ≥ \(cap)): \(path) — use a shorter account name") }
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  return addr
}

private func connect(_ path: String) throws -> Int32 {
  var addr = try sockaddr(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw CLIError("socket(): \(String(cString: strerror(errno)))") }
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard rc == 0 else {
    close(fd)
    throw CLIError("connect(\(path)): \(String(cString: strerror(errno)))")
  }
  return fd
}

private func listenUnix(_ path: String) throws -> Int32 {
  var addr = try sockaddr(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw CLIError("socket(): \(String(cString: strerror(errno)))") }
  let old = umask(0o077)
  defer { umask(old) }
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard rc == 0, listen(fd, 32) == 0 else { throw CLIError("cannot listen on \(path): \(String(cString: strerror(errno)))") }
  chmod(path, 0o600)
  return fd
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
  try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
    var off = 0
    while off < buf.count {
      let n = write(fd, buf.baseAddress! + off, buf.count - off)
      guard n > 0 else { throw CLIError("socket write failed: \(String(cString: strerror(errno)))") }
      off += n
    }
  }
}

private func readAll(_ fd: Int32) throws -> Data {
  var out = Data()
  var buf = [UInt8](repeating: 0, count: 65536)
  while true {
    let n = read(fd, &buf, buf.count)
    if n == 0 { return out }
    guard n > 0 else {
      if errno == EAGAIN || errno == EWOULDBLOCK { throw CLIError("no answer from session process in time", code: ExitCode.timeout) }
      throw CLIError("socket read failed: \(String(cString: strerror(errno)))")
    }
    out.append(buf, count: n)
  }
}

private func readLine(_ fd: Int32) throws -> Data {
  var out = Data()
  var byte: UInt8 = 0
  while read(fd, &byte, 1) == 1 {
    if byte == 0x0A { break }
    out.append(byte)
  }
  return out
}
