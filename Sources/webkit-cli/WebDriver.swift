import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `webkit-cli webdriver`: a W3C WebDriver endpoint on 127.0.0.1 over a profile's session.
/// A WebDriver session is one tab in that profile's session process; this process holds no WebKit,
/// it only turns HTTP into session requests. The subset is what agent-browser's client uses.
final class WebDriverServer {
  private let account: String
  private let idle: Double
  private let timeout: Double
  private var sessions: [String: WDSession] = [:]
  private let lock = NSLock()
  private var signalSources: [DispatchSourceSignal] = []

  init(account: String, idle: Double, timeout: Double) {
    self.account = account
    self.idle = idle
    self.timeout = timeout
  }

  func run(port: Int) throws -> Never {
    signal(SIGPIPE, SIG_IGN)
    let fd = try listenTCP(port)
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let bound = Int(UInt16(bigEndian: addr.sin_port))
    signalSources = [SIGTERM, SIGINT, SIGHUP].map { sig -> DispatchSourceSignal in
      signal(sig, SIG_IGN)
      let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      src.setEventHandler { [self] in shutdown() }
      src.resume()
      return src
    }
    print(try jsonString(["account": account, "port": bound, "url": "http://127.0.0.1:\(bound)"] as [String: Any]))
    fflush(stdout)
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 { continue }
      closeOnExec(client)
      noSigpipe(client)
      Thread.detachNewThread { [self] in handle(client) }
    }
  }

  private func shutdown() -> Never {
    lock.lock()
    let open = sessions.keys
    lock.unlock()
    for id in open { _ = try? send(Request(cmd: "close", target: id, timeout: 10)) }
    exit(0)
  }

  // MARK: HTTP

  private func handle(_ fd: Int32) {
    defer { close(fd) }
    let reply: (Int, Any)
    do {
      let (method, path, body) = try readHTTP(fd)
      reply = try route(method, path.split(separator: "/").map(String.init), body)
    } catch let e as WDError {
      reply = (e.status, ["error": e.code, "message": e.message, "stacktrace": ""])
    } catch {
      reply = (500, ["error": "unknown error", "message": "\(error)", "stacktrace": ""])
    }
    let json = (try? JSONSerialization.data(withJSONObject: ["value": reply.1], options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"][reply.0] ?? "Error"
    var out = Data("HTTP/1.1 \(reply.0) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-cache\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
    out.append(json)
    try? writeAll(fd, out)
  }

  private func readHTTP(_ fd: Int32) throws -> (String, String, [String: Any]) {
    var tv = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buf = Data()
    let sep = Data("\r\n\r\n".utf8)
    while buf.range(of: sep) == nil {
      guard let chunk = try readChunk(fd) else { throw WDError(400, "invalid argument", "connection closed mid-request") }
      buf.append(chunk)
      if buf.count > 1 << 20 { throw WDError(400, "invalid argument", "request headers too large") }
    }
    let end = buf.range(of: sep)!
    let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let parts = head[0].split(separator: " ")
    guard parts.count >= 2 else { throw WDError(400, "invalid argument", "bad request line") }
    var length = 0
    for h in head.dropFirst() where h.lowercased().hasPrefix("content-length:") {
      length = Int(h.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
    }
    var body = Data(buf[end.upperBound...])
    while body.count < length {
      guard let chunk = try readChunk(fd) else { throw WDError(400, "invalid argument", "body shorter than Content-Length") }
      body.append(chunk)
    }
    var json: [String: Any] = [:]
    if length > 0 {
      guard let obj = try? JSONSerialization.jsonObject(with: body.prefix(length)) as? [String: Any] else {
        throw WDError(400, "invalid argument", "body is not a JSON object")
      }
      json = obj
    }
    let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? "/"
    return (String(parts[0]), path, json)
  }

  // MARK: commands

  private func route(_ method: String, _ p: [String], _ body: [String: Any]) throws -> (Int, Any) {
    switch (method, p.count, p.first) {
    case ("GET", 1, "status"):
      return (200, ["ready": true, "message": "webkit-cli \(webkitCLIVersion), profile \(account)"])
    case ("POST", 1, "session"):
      return (200, try newSession(body))
    default: break
    }
    guard p.count >= 2, p[0] == "session" else { throw WDError(404, "unknown command", "\(method) /\(p.joined(separator: "/"))") }
    let sid = p[1]
    lock.lock()
    let known = sessions[sid]
    lock.unlock()
    guard let ws = known else { throw WDError(404, "invalid session id", "no session \(sid)") }
    let strategy = ws.strategy == "normal" ? nil : ws.strategy
    let rest = Array(p.dropFirst(2))
    switch (method, rest.first, rest.count) {
    case ("DELETE", nil, 0):
      lock.lock(); sessions.removeValue(forKey: sid); lock.unlock()
      _ = try? send(Request(cmd: "close", target: sid, timeout: timeout))
      return (200, NSNull())
    case ("GET", "timeouts", 1):
      return (200, ws.timeoutsJSON)
    case ("POST", "timeouts", 1):
      var updated = ws
      try updated.setTimeouts(body)
      lock.lock(); sessions[sid] = updated; lock.unlock()
      return (200, NSNull())
    case ("POST", "url", 1):
      guard let url = body["url"] as? String else { throw WDError(400, "invalid argument", "url needs {url}") }
      guard let parsed = URL(string: url), parsed.scheme != nil else { throw WDError(400, "invalid argument", "not an absolute URL: \(url)") }
      _ = try call(Request(cmd: "goto", target: sid, url: parsed.absoluteString, timeout: ws.pageLoad, strategy: strategy))
      return (200, NSNull())
    case ("GET", "url", 1):
      return (200, try script(sid, "return location.href"))
    case ("GET", "title", 1):
      return (200, try script(sid, "return document.title"))
    case ("GET", "source", 1):
      return (200, try script(sid, "return document.documentElement ? document.documentElement.outerHTML : ''"))
    case ("POST", "back", 1), ("POST", "forward", 1), ("POST", "refresh", 1):
      let nav = ["back": "back", "forward": "forward", "refresh": "reload"][rest[0]]!
      _ = try call(Request(cmd: "nav", target: sid, text: nav, timeout: ws.pageLoad, strategy: strategy))
      return (200, NSNull())
    case ("POST", "execute", 2) where rest[1] == "sync" || rest[1] == "async":
      guard let js = body["script"] as? String else { throw WDError(400, "invalid argument", "execute needs {script, args}") }
      let args = body["args"] as? [Any] ?? []
      return (200, try execute(sid, js, args, async: rest[1] == "async", timeout: ws.script ?? 365 * 86400)) // null = no limit
    case ("POST", "element", 1), ("POST", "elements", 1):
      guard let using = body["using"] as? String, let value = body["value"] as? String else {
        throw WDError(400, "invalid argument", "find needs {using, value}")
      }
      // implicit wait: keep looking until something matches or it runs out
      let until = Date().addingTimeInterval(ws.implicit)
      var found = try isolated(sid, findElementsJS, [using, value, rest[0] == "element"])
      while (found as? [Any])?.isEmpty ?? false, Date() < until {
        usleep(100_000)
        found = try isolated(sid, findElementsJS, [using, value, rest[0] == "element"])
      }
      if rest[0] == "elements" { return (200, found) }
      guard let list = found as? [Any], let first = list.first else {
        throw WDError(404, "no such element", "no element matches \(using) \(value)")
      }
      return (200, first)
    case ("POST", "element", 3) where rest[2] == "click":
      _ = try call(Request(cmd: "click", target: sid, selector: try elementSelector(sid, rest[1]), timeout: ws.pageLoad, strategy: strategy))
      return (200, NSNull())
    case ("POST", "element", 3) where rest[2] == "clear":
      _ = try call(Request(cmd: "type", target: sid, selector: try elementSelector(sid, rest[1]), text: "", timeout: timeout))
      return (200, NSNull())
    case ("POST", "element", 3) where rest[2] == "value":
      guard let text = body["text"] as? String else { throw WDError(400, "invalid argument", "value needs {text}") }
      try sendKeys(sid, rest[1], text)
      return (200, NSNull())
    case ("GET", "element", 3) where ["text", "name"].contains(rest[2]):
      let js = rest[2] == "text" ? "return elementOf(args[0]).innerText" : "return elementOf(args[0]).tagName.toLowerCase()"
      return (200, try isolated(sid, js, [elementRef(rest[1])]))
    case ("GET", "element", 4) where rest[2] == "attribute" || rest[2] == "property":
      let js = rest[2] == "attribute" ? "return elementOf(args[0]).getAttribute(args[1])" : "return ser(elementOf(args[0])[args[1]])"
      return (200, try isolated(sid, js, [elementRef(rest[1]), rest[3]]))
    case ("GET", "screenshot", 1):
      return (200, try screenshot(sid))
    case ("GET", "cookie", 1):
      return (200, try cookies(sid))
    case ("GET", "cookie", 2):
      guard let c = try cookies(sid).first(where: { $0["name"] as? String == rest[1] }) else {
        throw WDError(404, "no such cookie", "no cookie \(rest[1]) for this page")
      }
      return (200, c)
    case ("POST", "cookie", 1):
      guard let cookie = body["cookie"] as? [String: Any], cookie["name"] is String, cookie["value"] is String else {
        throw WDError(400, "invalid argument", "cookie needs {cookie: {name, value, …}}")
      }
      let raw = String(decoding: try JSONSerialization.data(withJSONObject: cookie), as: UTF8.self)
      _ = try call(Request(cmd: "set-cookie", target: sid, text: raw, timeout: timeout))
      return (200, NSNull())
    case ("DELETE", "cookie", 1), ("DELETE", "cookie", 2):
      _ = try call(Request(cmd: "delete-cookies", target: sid, text: rest.count == 2 ? rest[1] : nil, timeout: timeout))
      return (200, NSNull())
    case ("POST", "actions", 1):
      guard let actions = body["actions"] as? [Any] else { throw WDError(400, "invalid argument", "actions needs {actions: [...]}") }
      var updated = ws
      let steps = try actionSteps(sid, actions, &updated)
      try perform(sid, steps, updated)
      return (200, NSNull())
    case ("DELETE", "actions", 1):
      var updated = ws
      let steps = updated.releaseAll()
      try perform(sid, steps, updated)
      return (200, NSNull())
    case ("GET", "window", 1):
      return (200, sid)
    case ("GET", "window", 2) where rest[1] == "handles":
      return (200, [sid])
    default:
      throw WDError(404, "unknown command", "\(method) /\(p.joined(separator: "/")) is not supported by webkit-cli")
    }
  }

  private func newSession(_ body: [String: Any]) throws -> [String: Any] {
    let caps = body["capabilities"] as? [String: Any] ?? [:]
    var asked = caps["alwaysMatch"] as? [String: Any] ?? [:]
    if let first = (caps["firstMatch"] as? [[String: Any]])?.first { asked.merge(first) { a, _ in a } }
    var ws = WDSession(pageLoad: timeout)
    if let s = asked["pageLoadStrategy"] {
      guard let s = s as? String, ["normal", "eager", "none"].contains(s) else {
        throw WDError(400, "invalid argument", "pageLoadStrategy must be normal, eager or none")
      }
      ws.strategy = s
    }
    if let t = asked["timeouts"] {
      guard let t = t as? [String: Any] else { throw WDError(400, "invalid argument", "timeouts must be an object") }
      try ws.setTimeouts(t)
    }
    let out = try call(Request(cmd: "open", url: "about:blank", timeout: timeout))
    guard let info = out as? [String: Any], let tab = info["tab"] as? String else {
      throw WDError(500, "session not created", "the session process returned no tab")
    }
    lock.lock(); sessions[tab] = ws; lock.unlock()
    #if os(macOS)
    let platform = "mac"
    #else
    let platform = "linux"
    #endif
    return ["sessionId": tab, "capabilities": [
      "browserName": "webkit-cli", "browserVersion": webkitCLIVersion, "platformName": platform,
      "acceptInsecureCerts": false, "pageLoadStrategy": ws.strategy, "timeouts": ws.timeoutsJSON, "webkit-cli:account": account,
    ] as [String: Any]]
  }

  private func elementRef(_ id: String) -> [String: Any] { [elementKey: id] }

  /// The selector click/type resolve a WebDriver handle by (a stale one fails there).
  private func elementSelector(_ sid: String, _ id: String) throws -> String {
    guard id.hasPrefix("w"), id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw WDError(404, "no such element", "bad element id \(id)") }
    return "wd=\(id)"
  }

  /// Element send keys: real keystrokes after the field's content. WebDriver's modifier keys stay
  /// held for the rest of the text (pressing one again, or Null U+E000, lets go).
  private func sendKeys(_ sid: String, _ id: String, _ text: String) throws {
    let selector = try elementSelector(sid, id)
    var held: [String] = []
    var steps: [InputStep] = []
    let mods = { KeyModifiers(held.compactMap(KeyModifiers.init(key:))) }
    var plain = "" // typed while no modifier is held: long runs go in as one insertion
    let typePlain = { steps += typingSteps(plain); plain = "" }
    let release = {
      for k in held.reversed() { held.removeLast(); steps.append(InputStep(t: .key, key: k, down: false, mods: mods().rawValue)) }
    }
    for scalar in text.unicodeScalars {
      if held.isEmpty && !(0xE000...0xF8FF).contains(scalar.value) { plain.unicodeScalars.append(scalar); continue }
      typePlain()
      if scalar.value == 0xE000 { release(); continue }
      if (0xE000...0xF8FF).contains(scalar.value) && webDriverKeyName(scalar) == nil {
        throw WDError(400, "invalid argument", "unknown WebDriver key U+\(String(scalar.value, radix: 16, uppercase: true))")
      }
      let key = webDriverKeyName(scalar) ?? String(scalar)
      if KeyModifiers(key: key) != nil {
        if let i = held.firstIndex(of: key) {
          held.remove(at: i)
          steps.append(InputStep(t: .key, key: key, down: false, mods: mods().rawValue))
        } else {
          steps.append(InputStep(t: .key, key: key, down: true, mods: mods().rawValue))
          held.append(key)
        }
        continue
      }
      steps.append(InputStep(t: .key, key: key, down: true, mods: mods().rawValue))
      steps.append(InputStep(t: .key, key: key, down: false, mods: mods().rawValue))
    }
    typePlain()
    release()
    _ = try call(Request(cmd: "type", target: sid, selector: selector, timeout: timeout, input: steps, append: true))
    if steps.contains(where: { $0.key == "Enter" }) {
      // Enter in a form field submits it: let the navigation it starts finish
      usleep(300_000)
      _ = try call(Request(cmd: "wait", target: sid, timeout: timeout))
    }
  }

  /// Sends resolved action steps and keeps the session's input state (held keys, buttons, pointer).
  private func perform(_ sid: String, _ steps: [InputStep], _ updated: WDSession) throws {
    if !steps.isEmpty { _ = try call(Request(cmd: "input", target: sid, timeout: updated.pageLoad, input: steps)) }
    lock.lock(); if sessions[sid] != nil { sessions[sid]?.input = updated.input }; lock.unlock()
    if steps.contains(where: { $0.t == .up || $0.key == "Enter" }) {
      // a click or Enter may have started a navigation: let it finish
      _ = try call(Request(cmd: "wait", target: sid, timeout: updated.pageLoad))
    }
  }

  /// W3C actions → input steps, tick by tick: each source's nth action runs in tick n, and a tick
  /// lasts as long as its longest pause or pointer move.
  private func actionSteps(_ sid: String, _ sources: [Any], _ ws: inout WDSession) throws -> [InputStep] {
    var lists: [(type: String, actions: [[String: Any]])] = []
    for case let src as [String: Any] in sources {
      guard let type = src["type"] as? String, ["key", "pointer", "wheel", "none"].contains(type),
            let actions = src["actions"] as? [[String: Any]] else {
        throw WDError(400, "invalid argument", "each action source needs {type: key|pointer|wheel|none, actions: [...]}")
      }
      if type == "pointer", let p = src["parameters"] as? [String: Any], let pt = p["pointerType"] as? String, pt != "mouse" {
        throw WDError(400, "invalid argument", "pointerType \(pt) isn't supported (mouse is)")
      }
      lists.append((type, actions))
    }
    var steps: [InputStep] = []
    var clock = 0.0 // ms since these actions began, for telling a double click from two clicks
    let ticks = lists.map(\.actions.count).max() ?? 0
    for t in 0..<ticks {
      var tickMs = 0.0
      var movedMs = 0.0
      for (type, actions) in lists where t < actions.count {
        let a = actions[t]
        guard let kind = a["type"] as? String else { throw WDError(400, "invalid argument", "an action needs a type") }
        let duration = (a["duration"] as? NSNumber)?.doubleValue ?? 0
        switch (type, kind) {
        case (_, "pause"):
          tickMs = max(tickMs, duration)
        case ("key", "keyDown"), ("key", "keyUp"):
          let key = try actionKey(a["value"])
          let down = kind == "keyDown"
          steps.append(InputStep(t: .key, key: key, down: down, mods: ws.input.modifiers.rawValue))
          if down { ws.input.keys.append(key) } else if let i = ws.input.keys.lastIndex(of: key) { ws.input.keys.remove(at: i) }
        case ("pointer", "pointerMove"):
          let (x, y) = try target(sid, a, ws.input)
          let n = duration > 0 ? max(1, Int(duration / 16)) : 1
          for i in 1...n {
            let f = Double(i) / Double(n)
            steps.append(InputStep(t: .move, x: ws.input.x + (x - ws.input.x) * f, y: ws.input.y + (y - ws.input.y) * f,
                                   mods: ws.input.modifiers.rawValue, buttons: ws.input.buttons))
            if duration > 0 { steps.append(InputStep(t: .pause, ms: duration / Double(n))) }
          }
          movedMs = max(movedMs, duration)
          tickMs = max(tickMs, duration)
          ws.input.x = x; ws.input.y = y
        case ("pointer", "pointerDown"), ("pointer", "pointerUp"):
          let button = (a["button"] as? NSNumber)?.intValue ?? 0
          guard (0...2).contains(button) else { throw WDError(400, "invalid argument", "button must be 0, 1 or 2") }
          let s = ws.input
          if kind == "pointerDown" {
            let again = s.lastUp.map { clock - $0.at < 500 && $0.button == button && abs($0.x - s.x) <= 4 && abs($0.y - s.y) <= 4 } ?? false
            ws.input.clicks = again ? (s.lastUp?.count ?? 0) + 1 : 1
            ws.input.buttons |= 1 << button
          } else {
            ws.input.buttons &= ~(1 << button)
            ws.input.lastUp = (clock, s.x, s.y, button, s.clicks)
          }
          steps.append(InputStep(t: kind == "pointerDown" ? .down : .up, x: s.x, y: s.y, button: button, clicks: ws.input.clicks,
                                 mods: ws.input.modifiers.rawValue))
        case ("wheel", "scroll"):
          let (x, y) = try target(sid, a, ws.input)
          steps.append(InputStep(t: .wheel, x: x, y: y, dx: (a["deltaX"] as? NSNumber)?.doubleValue ?? 0,
                                 dy: (a["deltaY"] as? NSNumber)?.doubleValue ?? 0, mods: ws.input.modifiers.rawValue))
        default:
          throw WDError(400, "invalid argument", "\(type) source can't \(kind)")
        }
      }
      if tickMs > movedMs { steps.append(InputStep(t: .pause, ms: tickMs - movedMs)) }
      clock += tickMs
    }
    return steps
  }

  private func actionKey(_ v: Any?) throws -> String {
    guard let s = v as? String, s.count == 1 else { throw WDError(400, "invalid argument", "a key action's value must be one character") }
    if let scalar = s.unicodeScalars.first, s.unicodeScalars.count == 1, (0xE000...0xF8FF).contains(scalar.value) {
      guard let name = webDriverKeyName(scalar) else {
        throw WDError(400, "invalid argument", "unknown WebDriver key U+\(String(scalar.value, radix: 16, uppercase: true))")
      }
      return name
    }
    return s
  }

  /// A pointer move's or scroll's target in viewport px: relative to the viewport, the pointer, or an element's centre.
  private func target(_ sid: String, _ a: [String: Any], _ input: WDSession.Input) throws -> (Double, Double) {
    let dx = (a["x"] as? NSNumber)?.doubleValue ?? 0, dy = (a["y"] as? NSNumber)?.doubleValue ?? 0
    switch a["origin"] {
    case nil, "viewport" as String: return (dx, dy)
    case "pointer" as String: return (input.x + dx, input.y + dy)
    case let el as [String: Any] where el[elementKey] is String:
      let c = try isolated(sid, centerJS, [el]) as? [String: Any]
      guard let cx = (c?["x"] as? NSNumber)?.doubleValue, let cy = (c?["y"] as? NSNumber)?.doubleValue else {
        throw WDError(500, "unknown error", "could not locate the origin element")
      }
      return (cx + dx, cy + dy)
    default:
      throw WDError(400, "invalid argument", "origin must be viewport, pointer or an element")
    }
  }

  private func screenshot(_ sid: String) throws -> String {
    let path = SessionPaths.runDir.appendingPathComponent("wd-\(sid)-\(UUID().uuidString).png").path
    defer { unlink(path) }
    _ = try call(Request(cmd: "shot", target: sid, path: path, timeout: timeout))
    return try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
  }

  private func cookies(_ sid: String) throws -> [[String: Any]] {
    guard let list = try call(Request(cmd: "cookies", target: sid, timeout: timeout)) as? [[String: Any]] else {
      throw WDError(500, "unknown error", "unreadable cookie list")
    }
    return list
  }

  private func script(_ sid: String, _ js: String) throws -> Any {
    try execute(sid, js, [], async: false)
  }

  /// Runs `js` (a function body over `args`) in webkit-cli's isolated world, where element handles live.
  private func isolated(_ sid: String, _ js: String, _ args: [Any]) throws -> Any {
    let body = wdHandlesJS + "const args = \(try jsonText(args));\n" + js
    do {
      return try call(Request(cmd: "eval", target: sid, js: body, timeout: timeout, isolated: true))
    } catch let e as WDError where e.message.contains("WKCLI-STALE") {
      throw WDError(404, "stale element reference", "the element is no longer on the page (it changed or navigated)")
    }
  }

  /// Runs a WebDriver script (a function body, args as `arguments`) in the page's world. Element
  /// handles cross between the worlds as node paths: resolved before, and re-handled after.
  private func execute(_ sid: String, _ js: String, _ args: [Any], async: Bool, timeout script: Double? = nil) throws -> Any {
    var argsValue: Any = args
    if try jsonText(args).contains(elementKey) {
      argsValue = try isolated(sid, "return mapDeep(args[0], v => E in v ? {__wkPath: pathOf(elementOf(v))} : undefined)", [args])
    }
    let argsJSON = try jsonText(argsValue)
    let body = async
      ? "return await new Promise((resolve, reject) => { (function() { \(js) }).apply(null, [...un(\(argsJSON)), resolve]); })"
      : "return await (async function() { \(js) }).apply(null, un(\(argsJSON)))"
    let wrapped = executeJS.replacingOccurrences(of: "/*BODY*/", with: "return ser(await (async () => { \(body) })());")
    do {
      let out = try call(Request(cmd: "eval", target: sid, js: wrapped, timeout: script ?? timeout))
      guard try jsonText(out).contains("__wkPath") else { return out }
      return try isolated(sid, """
        return mapDeep(args[0], v => {
          if (!('__wkPath' in v)) return undefined;
          const el = nodeAt(v.__wkPath);
          if (!el) throw new Error('WKCLI: the script returned an element webkit-cli can not reach (in a closed shadow root?)');
          return handleOf(el);
        })
        """, [out])
    } catch let e as WDError where e.message.contains("WKCLI-STALE") {
      throw WDError(404, "stale element reference", "the element is no longer on the page (it changed or navigated)")
    } catch let e as WDError where e.code == "timeout" && script != nil {
      throw WDError(500, "script timeout", e.message)
    }
  }

  // MARK: session process

  private func send(_ r: Request) throws -> Response {
    try SessionClient.send(r, account: account, idle: idle)
  }

  /// One session request; its JSON output parsed, errors as WebDriver errors.
  private func call(_ r: Request) throws -> Any {
    let resp = try send(r)
    guard resp.ok else {
      let msg = resp.error ?? "\(r.cmd) failed"
      switch true {
      case msg.contains("WKCLI-STALE"): throw WDError(404, "stale element reference", "the element is no longer on the page (it changed or navigated)")
      case resp.code == ExitCode.timeout: throw WDError(500, "timeout", msg)
      case msg.contains("stale ref") || msg.contains("no element matches"): throw WDError(404, "stale element reference", msg)
      case msg.contains("could not reach") || msg.contains("has no size"): throw WDError(400, "element not interactable", msg)
      case msg.contains("is covered by"): throw WDError(400, "element click intercepted", msg)
      case msg.contains("not an input"): throw WDError(400, "invalid element state", msg)
      case msg.contains("no tab"): throw WDError(404, "no such window", msg)
      case r.cmd == "eval": throw WDError(500, "javascript error", msg)
      default: throw WDError(500, "unknown error", msg)
      }
    }
    guard let out = resp.output, let data = out.data(using: .utf8) else { return NSNull() }
    return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? out
  }
}

/// A WebDriver session's settings; timeouts in seconds (W3C speaks milliseconds).
struct WDSession {
  /// What the session's virtual keyboard and mouse hold between action calls.
  struct Input {
    var x = 0.0
    var y = 0.0
    var buttons = 0                 // bit 1 << button
    var clicks = 1                  // the press count of the button now down
    var keys: [String] = []         // held keys, in press order
    var lastUp: (at: Double, x: Double, y: Double, button: Int, count: Int)?
    var modifiers: KeyModifiers { KeyModifiers(keys.compactMap(KeyModifiers.init(key:))) }
  }

  var input = Input()
  var strategy = "normal"
  var pageLoad: Double
  var script: Double? = 30
  var implicit: Double = 0

  var timeoutsJSON: [String: Any] {
    ["pageLoad": Int(pageLoad * 1000), "script": script.map { Int($0 * 1000) } ?? NSNull(), "implicit": Int(implicit * 1000)]
  }

  /// Steps letting go of every held key and button (DELETE actions); the state is cleared.
  mutating func releaseAll() -> [InputStep] {
    var steps: [InputStep] = []
    for k in input.keys.reversed() {
      input.keys.removeLast()
      steps.append(InputStep(t: .key, key: k, down: false, mods: input.modifiers.rawValue))
    }
    for b in 0...2 where input.buttons & (1 << b) != 0 {
      steps.append(InputStep(t: .up, x: input.x, y: input.y, button: b, clicks: input.clicks))
    }
    input.buttons = 0
    return steps
  }

  mutating func setTimeouts(_ t: [String: Any]) throws {
    func ms(_ key: String) throws -> Double? {
      guard let v = t[key], !(v is NSNull) else { return nil }
      guard let n = v as? NSNumber, String(cString: n.objCType) != "c", n.doubleValue >= 0, n.doubleValue.rounded() == n.doubleValue else {
        throw WDError(400, "invalid argument", "timeouts.\(key) must be a whole number of milliseconds ≥ 0")
      }
      return n.doubleValue / 1000
    }
    if let v = try ms("pageLoad") { pageLoad = v }
    if let v = try ms("implicit") { implicit = v }
    if t.keys.contains("script") { script = try ms("script") }
  }
}

private func jsonText(_ v: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), as: UTF8.self)
}

struct WDError: Error {
  let status: Int
  let code: String
  let message: String
  init(_ status: Int, _ code: String, _ message: String) {
    self.status = status
    self.code = code
    self.message = message
  }
}

private let elementKey = "element-6066-11e4-a52e-4f735466cecf"

/// A node's path from the top document (child indexes; 's' enters an open shadow root, 'f' a
/// same-origin iframe), and back. How an element crosses between the page's world and webkit-cli's.
private let pathJS = """
  const pathOf = n => {
    const steps = [];
    for (;;) {
      const p = n.parentNode;
      if (p) {
        steps.push([...p.childNodes].indexOf(n));
        n = p;
        if (p.nodeType === 11 && p.host) { steps.push('s'); n = p.host; }
        continue;
      }
      if (n.nodeType === 9 && n.defaultView && n.defaultView.frameElement) { steps.push('f'); n = n.defaultView.frameElement; continue; }
      return steps.reverse();
    }
  };
  const nodeAt = steps => {
    let n = document;
    for (const s of steps) {
      n = s === 's' ? n.shadowRoot : s === 'f' ? n.contentDocument : n.childNodes[s];
      if (!n) return null;
    }
    return n;
  };
  """

/// webkit-cli's world: WebDriver handles are ids in its registry (handlesJS), never DOM attributes.
private let wdHandlesJS = handlesJS + pathJS + """
  const E = '\(elementKey)';
  const handleOf = el => ({[E]: stamp(el, 'wd', () => 'w' + Math.random().toString(36).slice(2, 12) + Date.now().toString(36))});
  const elementOf = v => { const el = live(v[E]); if (!el) throw new Error('WKCLI-STALE'); return el; };
  const mapDeep = (v, f) => {
    if (Array.isArray(v)) return v.map(x => mapDeep(x, f));
    if (v && typeof v === 'object') {
      const r = f(v);
      return r !== undefined ? r : Object.fromEntries(Object.entries(v).map(([k, x]) => [k, mapDeep(x, f)]));
    }
    return v;
  };
  const ser = v => v instanceof Element ? handleOf(v) : v === undefined ? null : v;
  """

/// The page's world: elements arrive and leave as node paths (pathJS).
private let executeJS = pathJS + """
  const un = v => {
    if (Array.isArray(v)) return v.map(un);
    if (v && typeof v === 'object') {
      if ('__wkPath' in v) {
        const el = nodeAt(v.__wkPath);
        if (!el) throw new Error('WKCLI-STALE');
        return el;
      }
      return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, un(x)]));
    }
    return v;
  };
  const ser = v => {
    if (v instanceof Element) return {__wkPath: pathOf(v)};
    if (Array.isArray(v) || v instanceof NodeList || v instanceof HTMLCollection) return [...v].map(ser);
    if (v && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype)
      return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, ser(x)]));
    return v === undefined ? null : v;
  };
  /*BODY*/
  """

/// args: using, value, firstOnly. Returns handles to the matching elements.
private let findElementsJS = """
  const [using, value, firstOnly] = args;
  let found;
  switch (using) {
    case 'css selector': found = [...document.querySelectorAll(value)]; break;
    case 'tag name': found = [...document.getElementsByTagName(value)]; break;
    case 'link text': found = [...document.querySelectorAll('a')].filter(a => a.innerText.trim() === value); break;
    case 'partial link text': found = [...document.querySelectorAll('a')].filter(a => a.innerText.includes(value)); break;
    case 'xpath': {
      const r = document.evaluate(value, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      found = [];
      for (let i = 0; i < r.snapshotLength; i++) if (r.snapshotItem(i) instanceof Element) found.push(r.snapshotItem(i));
      break;
    }
    default: throw new Error('unsupported locator strategy ' + using);
  }
  return (firstOnly ? found.slice(0, 1) : found).map(handleOf);
  """

/// An element's in-view centre in viewport px, scrolled into view first.
private let centerJS = """
  const el = elementOf(args[0]);
  el.scrollIntoView({block: 'center', inline: 'center'});
  const r = el.getClientRects()[0] || el.getBoundingClientRect();
  return {x: r.x + r.width / 2, y: r.y + r.height / 2};
  """

private func listenTCP(_ port: Int) throws -> Int32 {
  let fd = socket(AF_INET, streamSocket, 0)
  guard fd >= 0 else { throw CLIError("socket(): \(String(cString: strerror(errno)))") }
  closeOnExec(fd)
  var on: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = UInt16(port).bigEndian
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard rc == 0, listen(fd, 64) == 0 else {
    throw CLIError("cannot listen on 127.0.0.1:\(port): \(String(cString: strerror(errno)))")
  }
  return fd
}
