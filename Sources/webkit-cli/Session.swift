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
}

struct Response: Codable {
  var ok: Bool
  var output: String?
  var notes: [String]?
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
  /// Hints for the caller's stderr, collected during the current request.
  private(set) var notes: [String] = []

  init(profile: Profile, keepsTabs: Bool) {
    self.profile = profile
    self.keepsTabs = keepsTabs
  }

  func handle(_ r: Request) async throws -> String {
    notes = []
    let deadline = Date().addingTimeInterval(r.timeout)
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
      var info = try await pageInfo(tab)
      info["tab"] = id
      return try jsonString(info)
    case "tabs":
      var rows: [[String: Any]] = []
      for id in tabs.keys.sorted() {
        let t = tabs[id]!
        var row: [String: Any] = ["tab": id, "url": t.web.url?.absoluteString ?? NSNull(), "title": t.web.title ?? NSNull(),
                                  "loading": t.web.isLoading]
        if let opener = openers[id] { row["opener"] = opener }
        rows.append(row)
      }
      return try jsonString(rows)
    case "text":
      return try await withTarget(r) { tab in
        guard let text = try await tab.callJS("return document.body ? document.body.innerText : null") as? String else {
          throw CLIError("page has no <body>")
        }
        return text
      }
    case "eval":
      guard let js = r.js else { throw CLIError("eval needs javascript") }
      return try await withTarget(r) { tab in
        if let json = try await tab.evalJSON(js) { return json }
        if !js.contains("return") {
          notes.append("result was undefined — eval runs your code as an async function body, so use `return <value>`")
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
      guard try await tab.waitUntilIdle(deadline: deadline) else { throw timeoutError(r) }
      try await settle(r.wait ?? 1)
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
      try await waitFor(tab, r, deadline: deadline)
      try await settle(r.wait ?? 0)
      var info = try await pageInfo(tab)
      info["tab"] = id
      return try jsonString(info)
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
      self.notes.append("tab \(id) opened popup \(popupID)")
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

  private func waitFor(_ tab: Browser, _ r: Request, deadline: Date) async throws {
    if let pattern = r.untilURL {
      do { _ = try NSRegularExpression(pattern: pattern) } catch {
        throw CLIError("--until-url is not a valid regex: \(pattern)", code: ExitCode.usage)
      }
    }
    while true {
      let idle = !tab.web.isLoading
      let urlOK = try r.untilURL.map { pattern in
        let url = tab.web.url?.absoluteString ?? ""
        return try NSRegularExpression(pattern: pattern).firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
      } ?? true
      var selectorOK = true
      if idle, urlOK, let sel = r.untilSelector {
        let found = try await tab.callJS(
          "try { return !!document.querySelector(selector) } catch (e) { return 'invalid' }", ["selector": sel])
        if found as? String == "invalid" {
          throw CLIError("--until-selector is not a valid CSS selector: \(sel)", code: ExitCode.usage)
        }
        selectorOK = found as? Bool ?? false
      }
      if idle && urlOK && selectorOK { return }
      if Date() > deadline { throw timeoutError(r, url: tab.web.url?.absoluteString) }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
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
      "title": b.web.title ?? NSNull(),
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

/// `selector` is CSS, or `text=<words>` to match a visible clickable element by its text / label.
private let findJS = """
  const visible = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length) &&
    getComputedStyle(el).visibility !== 'hidden';
  const norm = s => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
  const label = el => norm(el.innerText || el.value || el.getAttribute('aria-label') || el.title);
  const clickables = () => [...document.querySelectorAll(
    'button, a, [role=button], [role=link], [role=menuitem], [role=option], [role=tab], input[type=submit], input[type=button], summary, label, [data-identifier], [onclick], [tabindex]'
  )].filter(visible);
  const find = sel => {
    if (!sel.startsWith('text=')) return document.querySelector(sel);
    const want = norm(sel.slice(5));
    const all = clickables();
    return all.find(el => label(el) === want)
      || all.filter(el => label(el).includes(want)).sort((a, b) => label(a).length - label(b).length)[0]
      || null;
  };
  const missing = sel => new Error('no element matches ' + sel + '. visible clickables: ' +
    JSON.stringify([...new Set(clickables().map(label).filter(Boolean))].slice(0, 25)));
  """

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
  return {tag: el.tagName.toLowerCase(), text: label(el).slice(0, 80)};
  """

private let typeJS = findJS + """
  const el = find(selector);
  if (!el) throw missing(selector);
  el.focus();
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
    : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype
    : el instanceof HTMLInputElement ? HTMLInputElement.prototype : null;
  if (!proto) throw new Error(selector + ' is a <' + el.tagName.toLowerCase() + '>, not an input, textarea or select');
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return {tag: el.tagName.toLowerCase(), name: el.name || el.id || null};
  """
