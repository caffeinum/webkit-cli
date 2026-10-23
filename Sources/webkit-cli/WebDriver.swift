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
      var found = try execute(sid, findElementsJS, [using, value, rest[0] == "element"], async: false)
      while (found as? [Any])?.isEmpty ?? false, Date() < until {
        usleep(100_000)
        found = try execute(sid, findElementsJS, [using, value, rest[0] == "element"], async: false)
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
      let js = rest[2] == "text" ? "return arguments[0].innerText" : "return arguments[0].tagName.toLowerCase()"
      return (200, try execute(sid, js, [elementRef(rest[1])], async: false))
    case ("GET", "element", 4) where rest[2] == "attribute" || rest[2] == "property":
      let js = rest[2] == "attribute" ? "return arguments[0].getAttribute(arguments[1])" : "return arguments[0][arguments[1]]"
      return (200, try execute(sid, js, [elementRef(rest[1]), rest[3]], async: false))
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
      _ = try execute(sid, actionsJS, [actions], async: false)
      _ = try call(Request(cmd: "wait", target: sid, timeout: timeout))
      return (200, NSNull())
    case ("DELETE", "actions", 1):
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

  /// A CSS selector for a found element; a stale element (gone, or the page navigated) fails here.
  private func elementSelector(_ sid: String, _ id: String) throws -> String {
    guard id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw WDError(404, "no such element", "bad element id \(id)") }
    _ = try execute(sid, "return arguments[0] === null ? 0 : 1", [elementRef(id)], async: false)
    return "[data-wd=\"\(id)\"]"
  }

  private func sendKeys(_ sid: String, _ id: String, _ text: String) throws {
    let selector = try elementSelector(sid, id)
    let enter = text.unicodeScalars.contains { $0 == "\u{E007}" || $0 == "\u{E006}" }
    // WebDriver's special keys live in U+E000–U+F8FF; only Enter is acted on, the rest are dropped
    let typed = String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0xE000...0xF8FF).contains($0.value) }))
    if !typed.isEmpty {
      let current = try execute(sid, "const e = arguments[0]; return e.isContentEditable ? e.textContent : (e.value ?? '')",
                                [elementRef(id)], async: false) as? String ?? ""
      _ = try call(Request(cmd: "type", target: sid, selector: selector, text: current + typed, timeout: timeout))
    }
    if enter {
      _ = try execute(sid, pressEnterJS, [elementRef(id)], async: false)
      usleep(300_000)
      _ = try call(Request(cmd: "wait", target: sid, timeout: timeout))
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

  /// Runs a WebDriver script (a function body, args as `arguments`); elements cross as {element-…: id}.
  private func execute(_ sid: String, _ js: String, _ args: [Any], async: Bool, timeout script: Double? = nil) throws -> Any {
    let argsJSON = String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]), as: UTF8.self)
    let body = async
      ? "return await new Promise((resolve, reject) => { (function() { \(js) }).apply(null, [...un(\(argsJSON)), resolve]); })"
      : "return await (async function() { \(js) }).apply(null, un(\(argsJSON)))"
    let wrapped = executeJS.replacingOccurrences(of: "/*BODY*/", with: "return ser(await (async () => { \(body) })());")
    do {
      return try call(Request(cmd: "eval", target: sid, js: wrapped, timeout: script ?? timeout))
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
      case resp.code == ExitCode.timeout: throw WDError(500, "timeout", msg)
      case msg.contains("stale ref") || msg.contains("no element matches"): throw WDError(404, "stale element reference", msg)
      case msg.contains("could not reach"): throw WDError(400, "element not interactable", msg)
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
  var strategy = "normal"
  var pageLoad: Double
  var script: Double? = 30
  var implicit: Double = 0

  var timeoutsJSON: [String: Any] {
    ["pageLoad": Int(pageLoad * 1000), "script": script.map { Int($0 * 1000) } ?? NSNull(), "implicit": Int(implicit * 1000)]
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

/// Element handles are `data-wd` attributes stamped on the element; `un` resolves them in arguments,
/// `ser` stamps returned elements.
private let executeJS = """
  const W = '\(elementKey)';
  const un = v => {
    if (Array.isArray(v)) return v.map(un);
    if (v && typeof v === 'object') {
      if (W in v) {
        const el = document.querySelector('[data-wd="' + v[W] + '"]');
        if (!el) throw new Error('WKCLI-STALE');
        return el;
      }
      return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, un(x)]));
    }
    return v;
  };
  const stamp = el => {
    let id = el.getAttribute('data-wd');
    if (!id) { id = 'w' + Math.random().toString(36).slice(2, 12) + Date.now().toString(36); el.setAttribute('data-wd', id); }
    return { [W]: id };
  };
  const ser = v => {
    if (v instanceof Element) return stamp(v);
    if (Array.isArray(v) || v instanceof NodeList || v instanceof HTMLCollection) return [...v].map(ser);
    if (v && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype)
      return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, ser(x)]));
    return v === undefined ? null : v;
  };
  /*BODY*/
  """

/// arguments: using, value, firstOnly. Returns the matching elements (ser() turns them into handles).
private let findElementsJS = """
  const [using, value, firstOnly] = arguments;
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
  return firstOnly ? found.slice(0, 1) : found;
  """

/// Enter on an element: key events, then submit its form as a browser would.
private let pressEnterJS = """
  const el = arguments[0];
  const opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
  const go = el.dispatchEvent(new KeyboardEvent('keydown', opts));
  el.dispatchEvent(new KeyboardEvent('keypress', opts));
  el.dispatchEvent(new KeyboardEvent('keyup', opts));
  if (go && el.form && el.tagName !== 'TEXTAREA') {
    if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
  }
  return null;
  """

/// W3C actions, tick by tick: key (text into the focused element, Enter submits), pointer (move/down/up
/// → mouse events and a click at the pointer), wheel (scroll), pause.
private let actionsJS = """
  const sequences = arguments[0];
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const pointer = { x: 0, y: 0 };
  const ticks = Math.max(0, ...sequences.map(s => (s.actions || []).length));
  const keyName = k => ({ '\\uE007': 'Enter', '\\uE006': 'Enter', '\\uE003': 'Backspace', '\\uE004': 'Tab', '\\uE00C': 'Escape' })[k] || k;
  const center = el => { const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; };
  const mouse = (type, target) => target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window, clientX: pointer.x, clientY: pointer.y, button: 0 }));
  for (let t = 0; t < ticks; t++) {
    let wait = 0;
    for (const s of sequences) {
      const a = (s.actions || [])[t];
      if (!a) continue;
      if (a.type === 'pause') { wait = Math.max(wait, a.duration || 0); continue; }
      if (s.type === 'key') {
        const el = document.activeElement || document.body;
        const key = keyName(a.value);
        const opts = { key, bubbles: true, cancelable: true };
        if (a.type === 'keyDown') {
          const go = el.dispatchEvent(new KeyboardEvent('keydown', opts));
          if (!go) continue;
          if (key === 'Enter') {
            if (el.form && el.tagName !== 'TEXTAREA') { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
          } else if (key === 'Backspace') {
            if ('value' in el) { el.value = el.value.slice(0, -1); el.dispatchEvent(new Event('input', { bubbles: true })); }
          } else if (key.length === 1) {
            if ('value' in el && /^(INPUT|TEXTAREA)$/.test(el.tagName)) { el.value += key; el.dispatchEvent(new Event('input', { bubbles: true })); }
            else if (el.isContentEditable) { el.textContent += key; el.dispatchEvent(new Event('input', { bubbles: true })); }
          }
        } else if (a.type === 'keyUp') {
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
          if (key.length === 1 && 'value' in el) el.dispatchEvent(new Event('change', { bubbles: true }));
        }
      } else if (s.type === 'pointer') {
        if (a.type === 'pointerMove') {
          const o = a.origin;
          if (o && typeof o === 'object') { const c = center(o); pointer.x = c.x + (a.x || 0); pointer.y = c.y + (a.y || 0); }
          else if (o === 'pointer') { pointer.x += a.x || 0; pointer.y += a.y || 0; }
          else { pointer.x = a.x || 0; pointer.y = a.y || 0; }
          const at = document.elementFromPoint(pointer.x, pointer.y);
          if (at) mouse('mousemove', at);
        } else if (a.type === 'pointerDown' || a.type === 'pointerUp') {
          const at = document.elementFromPoint(pointer.x, pointer.y);
          if (!at) throw new Error('no element at ' + pointer.x + ',' + pointer.y);
          if (a.type === 'pointerDown') { mouse('mousedown', at); if (at.focus) at.focus(); }
          else { mouse('mouseup', at); at.click(); }
        }
      } else if (s.type === 'wheel' && a.type === 'scroll') {
        window.scrollBy(a.deltaX || 0, a.deltaY || 0);
      }
    }
    if (wait) await sleep(wait);
  }
  return null;
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
