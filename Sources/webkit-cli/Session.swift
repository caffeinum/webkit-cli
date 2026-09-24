import AppKit
import WebKit

/// One command for a profile's session. Crosses the unix socket as a JSON line.
struct Request: Codable {
  var cmd: String
  var target: String?        // tab id ("t3") or URL
  var url: String?
  var js: String?
  var selector: String?
  var text: String?
  var path: String?
  var untilURL: String?
  var untilSelector: String?
  var wait: Double?          // nil = the command's default settle time
  var timeout: Double
  var untilHidden: Bool?
  var escalate: Bool?
  var challengeURLs: [String]?
  var humanTimeout: Double?
  var redact: Bool?
  var maxChars: Int?
  var json: Bool?
}

let defaultHumanTimeout: Double = 600

/// A command's time budget. Paused while a human works in a shown tab: --timeout is machine time only.
@MainActor
final class Deadline {
  private var at: Date
  private var pausedAt: Date?

  init(_ seconds: Double) { at = Date().addingTimeInterval(seconds) }

  var expired: Bool { pausedAt == nil && Date() > at }
  func pause() { if pausedAt == nil { pausedAt = Date() } }
  func resume() {
    guard let p = pausedAt else { return }
    at = at.addingTimeInterval(Date().timeIntervalSince(p))
    pausedAt = nil
  }
}

/// Pages that need a person: sign-in challenges and visible captchas. Scripts add more with --challenge-url.
let builtinChallengeURLs = [
  #"^https://accounts\.google\.com/(v3/)?signin/(v2/)?challenge"#,
  #"^https://accounts\.google\.com/.*/challenge/"#,
  #"^https://accounts\.google\.com/speedbump"#,
  #"^https://github\.com/sessions/(two-factor|verified-device)"#,
]

struct Response: Codable {
  var ok: Bool
  var output: String?
  var error: String?
  var code: Int32?
}

func isTabID(_ s: String) -> Bool {
  s.range(of: "^t[0-9a-f]{6}$", options: .regularExpression) != nil
}

/// Holds a profile's open tabs and executes requests against them. Runs inside the per-profile
/// session process, or in-process for the throwaway `-` profile (where tabs die with the command).
@MainActor
final class Engine {
  let profile: Profile
  let keepsTabs: Bool
  private var tabs: [String: Browser] = [:]
  private var openers: [String: String] = [:]
  /// Where the current request's notes go: straight to its caller's stderr, while it still waits.
  @TaskLocal static var noteSink: (@Sendable (String) -> Void)?
  /// Popups open from WebKit callbacks, outside any request; their note goes to the latest caller.
  private var lastSink: (@Sendable (String) -> Void)?

  private func note(_ s: String) {
    if let sink = Engine.noteSink {
      lastSink = sink
      sink(s)
    } else {
      lastSink?(s)
    }
  }

  var anyShown: Bool { tabs.values.contains { $0.isShown } }

  init(profile: Profile, keepsTabs: Bool) {
    self.profile = profile
    self.keepsTabs = keepsTabs
  }

  func handle(_ r: Request, deadline: Deadline) async throws -> String {
    if let sink = Engine.noteSink { lastSink = sink }
    switch r.cmd {
    case "open":
      let url = try requireURL(r.url)
      let (id, tab) = try newTab()
      do {
        try await tab.load(url)
      } catch {
        closeTab(id)
        throw error
      }
      try await settle(r.wait ?? 3)
      var info = try await pageInfo(tab)
      if keepsTabs { info["tab"] = id } else { closeTab(id) }
      return try jsonString(info)
    case "goto":
      let (id, tab) = try tab(r.target)
      try await tab.load(try requireURL(r.url))
      try await settle(r.wait ?? 3)
      try await escalateIfChallenged(id, r, deadline: deadline)
      var info = try await pageInfo(tab)
      info["tab"] = id
      return try jsonString(info)
    case "tabs":
      var rows: [[String: Any]] = []
      for id in tabs.keys.sorted() {
        let t = tabs[id]!
        var row: [String: Any] = ["tab": id, "url": t.web.url?.absoluteString ?? NSNull(), "title": t.web.title ?? NSNull(),
                                  "loading": t.web.isLoading, "shown": t.isShown]
        if let opener = openers[id] { row["opener"] = opener }
        rows.append(row)
      }
      return try jsonString(rows)
    case "snapshot":
      if let target = r.target, !isTabID(target) {
        note("snapshot of a URL: its tab closes right after, so these refs can't be used — `open` it for refs")
      }
      return try await withTarget(r) { tab in
        let result = try await tab.callJS(snapshotJS, [
          "startRef": tab.nextRef, "redactOn": r.redact == true, "maxChars": r.maxChars ?? 8000, "asJSON": r.json == true,
        ]) as? [String: Any]
        guard let result, let output = result["output"] as? String, let next = result["nextRef"] as? Int else {
          throw CLIError("snapshot returned nothing")
        }
        tab.nextRef = max(tab.nextRef, next)
        return output
      }
    case "eval":
      guard let js = r.js else { throw CLIError("eval needs javascript") }
      return try await withTarget(r) { tab in
        if let json = try await tab.evalJSON(js) { return json }
        if !js.contains("return") {
          self.note("result was undefined — eval runs your code as an async function body, so use `return <value>`")
        }
        return "null"
      }
    case "shot":
      guard let path = r.path else { throw CLIError("shot needs an output path") }
      return try await withTarget(r) { tab in
        let shot = try await tab.snapshotPNG()
        try writePNG(shot.data, to: URL(fileURLWithPath: path))
        var info = try await self.pageInfo(tab)
        info["path"] = path
        info["width"] = shot.width
        info["height"] = shot.height
        return try jsonString(info)
      }
    case "click":
      let (id, tab) = try tab(r.target)
      guard let selector = r.selector else { throw CLIError("click needs a selector") }
      let hit = try await tab.callJS(clickJS, ["selector": selector])
      // the click is dispatched on the next tick; give a navigation it starts a moment to begin
      try await Task.sleep(nanoseconds: 500_000_000)
      guard try await tab.waitUntilIdle(until: { deadline.expired }) else { throw timeoutError(r) }
      try await settle(r.wait ?? 1)
      try await escalateIfChallenged(id, r, deadline: deadline)
      var info = try await pageInfo(tab)
      info["tab"] = id
      info["clicked"] = hit ?? NSNull()
      return try jsonString(info)
    case "type":
      let (id, tab) = try tab(r.target)
      guard let selector = r.selector, let text = r.text else { throw CLIError("type needs a selector and text") }
      let field = try await tab.callJS(typeJS, ["selector": selector, "text": text])
      try await settle(r.wait ?? 0)
      return try jsonString(["tab": id, "typed": field ?? NSNull()] as [String: Any])
    case "wait":
      let (id, tab) = try tab(r.target)
      try await waitFor(id, tab, r, deadline: deadline)
      try await settle(r.wait ?? 0)
      var info = try await pageInfo(tab)
      info["tab"] = id
      return try jsonString(info)
    case "show":
      let (id, tab) = try tab(r.target)
      let reason = r.text ?? "Finish this step, then click Done."
      let wasShown = tab.isShown
      try tab.show(reason: reason)
      if !wasShown { noteNeedsYou(reason, id) }
      return try jsonString(["tab": id, "shown": true] as [String: Any])
    case "hide":
      let (id, tab) = try tab(r.target)
      tab.hide()
      return try jsonString(["tab": id, "shown": false] as [String: Any])
    case "close":
      let (id, _) = try tab(r.target)
      closeTab(id)
      return try jsonString(["closed": id])
    default:
      throw CLIError("unknown session command '\(r.cmd)'", code: ExitCode.usage)
    }
  }

  /// Where a tab is right now, for error messages.
  func location(of target: String?) -> String? {
    guard let target, let tab = tabs[target] else { return nil }
    return tab.web.url?.absoluteString
  }

  func closeAll() {
    for id in Array(tabs.keys) { closeTab(id) }
  }

  // MARK: tabs

  private func newTab() throws -> (String, Browser) {
    let tab = try Browser(store: profile.store, visible: false)
    return (register(tab), tab)
  }

  private func register(_ tab: Browser, opener: String? = nil) -> String {
    // random, so an id kept across a session restart can never land on someone else's new tab
    var id: String
    repeat { id = "t" + String(format: "%06x", UInt32.random(in: 0...0xFFFFFF)) } while tabs[id] != nil
    tabs[id] = tab
    if let opener { openers[id] = opener }
    tab.onPopup = { [weak self] popup in
      guard let self else { return }
      let popupID = self.register(popup, opener: id)
      self.note("tab \(id) opened popup \(popupID)")
    }
    tab.onPageClose = { [weak self] in self?.closeTab(id) }
    return id
  }

  private func closeTab(_ id: String) {
    guard let tab = tabs.removeValue(forKey: id) else { return }
    openers.removeValue(forKey: id)
    tab.close()
  }

  private func tab(_ target: String?) throws -> (String, Browser) {
    guard let target, isTabID(target) else {
      throw CLIError("expected a tab id like t3f9a2c (from `webkit-cli open <url>`), got '\(target ?? "")'", code: ExitCode.usage)
    }
    guard let tab = tabs[target] else {
      let open = tabs.keys.sorted().joined(separator: ", ")
      throw CLIError("no tab \(target) in this session (open: \(open.isEmpty ? "none" : open)) — the session was restarted or expired since; `webkit-cli tabs` lists live tabs")
    }
    return (target, tab)
  }

  /// A tab id acts on that live tab; a URL loads it in a temporary tab that is closed afterwards.
  private func withTarget(_ r: Request, _ body: (Browser) async throws -> String) async throws -> String {
    guard let target = r.target else { throw CLIError("missing tab id or url", code: ExitCode.usage) }
    if isTabID(target) { return try await body(try tab(target).1) }
    let (id, tab) = try newTab()
    defer { closeTab(id) }
    try await tab.load(try requireURL(target))
    try await settle(r.wait ?? 3)
    return try await body(tab)
  }

  private func waitFor(_ id: String, _ tab: Browser, _ r: Request, deadline: Deadline) async throws {
    if let pattern = r.untilURL {
      do { _ = try NSRegularExpression(pattern: pattern) } catch {
        throw CLIError("--until-url is not a valid regex: \(pattern)", code: ExitCode.usage)
      }
    }
    let hasConditions = r.untilURL != nil || r.untilSelector != nil
    var humanSince: Date?
    defer { deadline.resume() }
    while true {
      if tab.isClosed {
        throw CLIError("tab \(id) closed before \(r.untilHidden == true ? "Done" : "the wait finished") (the page closed itself, `close`, or the session stopped)")
      }
      // --until-hidden races the url/selector conditions: whichever holds first
      if r.untilHidden == true && !tab.isShown { return }
      // time a person spends on a shown tab is human time: --human-timeout, not --timeout
      if r.untilHidden == true && tab.isShown {
        deadline.pause()
        let since = humanSince ?? Date()
        humanSince = since
        let limit = r.humanTimeout ?? defaultHumanTimeout
        if Date().timeIntervalSince(since) > limit {
          tab.hide()
          throw CLIError("no one clicked Done within \(Int(limit))s (tab \(id)) — raise --human-timeout", code: ExitCode.timeout)
        }
      } else {
        deadline.resume()
        humanSince = nil
      }
      try await escalateIfChallenged(id, r, deadline: deadline)
      let idle = !tab.web.isLoading
      let urlOK = try r.untilURL.map { pattern in
        let url = tab.web.url?.absoluteString ?? ""
        return try NSRegularExpression(pattern: pattern).firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
      } ?? true
      var selectorOK = true
      if idle, urlOK, let sel = r.untilSelector {
        let found = try await tab.callJS(findJS + """
          try { return !!find(selector) } catch (e) { return /^stale ref/.test(e.message) ? false : 'invalid' }
          """, ["selector": sel])
        if found as? String == "invalid" {
          throw CLIError("--until-selector is not a valid CSS selector: \(sel)", code: ExitCode.usage)
        }
        selectorOK = found as? Bool ?? false
      }
      if idle && urlOK && selectorOK && (hasConditions || r.untilHidden != true) { return }
      if deadline.expired { throw timeoutError(r, url: tab.web.url?.absoluteString) }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
  }

  // MARK: escalation to a human

  /// With --escalate: if the tab (or a popup it opened) sits on a challenge page, show it and wait for
  /// the person to get past it (or click Done), then hide it again. Human time doesn't count toward --timeout.
  private func escalateIfChallenged(_ id: String, _ r: Request, deadline: Deadline) async throws {
    guard r.escalate == true else { return }
    let candidates = [id] + openers.filter { $0.value == id }.map(\.key).sorted()
    var hit: (String, Browser)?
    for cid in candidates {
      if let t = tabs[cid], try await isChallenge(t, r) { hit = (cid, t); break }
    }
    guard let (cid, t) = hit else { return }
    let reason = "this page needs a person (\(t.web.url?.host ?? "?")) — finish it in the window; it closes by itself, or click Done"
    try t.show(reason: reason)
    noteNeedsYou(reason, cid)
    deadline.pause()
    defer { deadline.resume() }
    let giveUp = Date().addingTimeInterval(r.humanTimeout ?? defaultHumanTimeout)
    while true {
      try await Task.sleep(nanoseconds: 300_000_000)
      if t.isClosed || !t.isShown { break } // popup finished and closed itself, or Done
      if !t.web.isLoading, try await !isChallenge(t, r) { break }
      if Date() > giveUp {
        t.hide()
        throw CLIError("""
          no one finished the human step within \(Int(r.humanTimeout ?? defaultHumanTimeout))s \
          (tab \(cid) is at \(t.web.url?.absoluteString ?? "?")) — raise --human-timeout
          """, code: ExitCode.timeout)
      }
    }
    if !t.isClosed { t.hide() }
    note("human step done (tab \(cid))")
  }

  private func noteNeedsYou(_ reason: String, _ id: String) {
    note("needs you: \(reason) (tab \(id))")
    if screenIsLocked() { note("the screen is locked — the window will be waiting when you unlock") }
  }

  private func isChallenge(_ tab: Browser, _ r: Request) async throws -> Bool {
    let url = tab.web.url?.absoluteString ?? ""
    for pattern in builtinChallengeURLs + (r.challengeURLs ?? []) {
      let re = try NSRegularExpression(pattern: pattern)
      if re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil { return true }
    }
    let captcha = try? await tab.callJS("""
      return [...document.querySelectorAll('iframe')].some(f =>
        /recaptcha|hcaptcha|challenges\\.cloudflare\\.com/.test(f.src) && !/size=invisible/.test(f.src) &&
        f.offsetWidth > 30 && f.offsetHeight > 30 && getComputedStyle(f).visibility !== 'hidden')
      """)
    return captcha as? Bool ?? false
  }

  private func timeoutError(_ r: Request, url: String? = nil) -> CLIError {
    let at = url.map { " (tab is at \($0))" } ?? ""
    return CLIError("\(r.cmd) timed out after \(Int(r.timeout.rounded(.up)))s\(at) — raise with --timeout", code: ExitCode.timeout)
  }

  private func settle(_ seconds: Double) async throws {
    if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
  }

  private func requireURL(_ s: String?) throws -> URL {
    guard let s else { throw CLIError("missing url", code: ExitCode.usage) }
    return try parseURL(s)
  }

  private func pageInfo(_ b: Browser) async throws -> [String: Any] {
    var info: [String: Any] = [
      "url": b.web.url?.absoluteString ?? NSNull(),
      // WKWebView.title lags the document right after a load; ask the page
      "title": (try? await b.callJS("return document.title")) ?? b.web.title ?? NSNull(),
      "status": b.lastStatus ?? NSNull(),
      "loading": b.web.isLoading,
    ]
    if let failure = b.lastFailure { info["failure"] = failure }
    return info
  }
}

func writePNG(_ data: Data, to url: URL) throws {
  let dir = url.deletingLastPathComponent()
  guard FileManager.default.fileExists(atPath: dir.path) else { throw CLIError("directory does not exist: \(dir.path)") }
  guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
    throw CLIError("could not write \(url.path)")
  }
}

private let clickJS = findJS + """
  const el = find(selector);
  if (!el) throw missing(selector);
  el.scrollIntoView({block: 'center'});
  const r = el.getBoundingClientRect();
  const at = {bubbles: true, cancelable: true, view: window, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, button: 0};
  setTimeout(() => {
    for (const type of ['pointerover', 'pointerenter', 'mouseover', 'pointerdown', 'mousedown'])
      el.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, {...at, pointerType: 'mouse', isPrimary: true}) : new MouseEvent(type, at));
    if (el.focus) el.focus();
    for (const type of ['pointerup', 'mouseup'])
      el.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, {...at, pointerType: 'mouse', isPrimary: true}) : new MouseEvent(type, at));
    el.click();
  }, 0);
  return {tag: el.tagName.toLowerCase(), text: (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().slice(0, 80)};
  """

private let typeJS = findJS + """
  const el = find(selector);
  if (!el) throw missing(selector);
  el.focus();
  const win = el.ownerDocument.defaultView; // the element may live in a same-origin iframe
  const tag = el.tagName;
  if (tag === 'SELECT') {
    const want = text.trim().toLowerCase();
    const opt = [...el.options].find(o => (o.label || o.text).trim().toLowerCase() === want) || [...el.options].find(o => o.value === text);
    if (!opt) throw new Error('no option ' + JSON.stringify(text) + ' in ' + selector + ' (options: ' + [...el.options].map(o => o.label || o.text).join(', ') + ')');
    Object.getOwnPropertyDescriptor(win.HTMLSelectElement.prototype, 'value').set.call(el, opt.value);
  } else if (tag === 'INPUT' || tag === 'TEXTAREA') {
    const proto = tag === 'INPUT' ? win.HTMLInputElement.prototype : win.HTMLTextAreaElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
  } else if (el.isContentEditable) {
    el.textContent = text;
  } else {
    throw new Error(selector + ' is a <' + tag.toLowerCase() + '>, not an input, textarea, select or editable');
  }
  el.dispatchEvent(new win.Event('input', {bubbles: true}));
  el.dispatchEvent(new win.Event('change', {bubbles: true}));
  return {tag: tag.toLowerCase(), name: el.name || el.id || el.getAttribute('data-wk-ref') || null};
  """
