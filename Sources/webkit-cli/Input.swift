import Foundation

/// Trusted input: real platform events (NSEvent on mac, WPE events on linux) posted into the tab's
/// view, so the page sees isTrusted events with hover, click counts and held modifiers, as a
/// person's would. Coordinates are CSS pixels in the top-level viewport.

struct KeyModifiers: OptionSet, Codable {
  let rawValue: Int
  init(rawValue: Int) { self.rawValue = rawValue }
  static let shift = KeyModifiers(rawValue: 1)
  static let control = KeyModifiers(rawValue: 2)
  static let alt = KeyModifiers(rawValue: 4)
  static let meta = KeyModifiers(rawValue: 8)

  /// The modifier a key value names (W3C: "Shift", "Control", "Alt", "Meta"), if it is one.
  init?(key: String) {
    switch key {
    case "Shift": self = .shift
    case "Control": self = .control
    case "Alt": self = .alt
    case "Meta": self = .meta
    default: return nil
    }
  }
}

/// One step of an `input` request (WebDriver actions, already resolved to viewport points).
struct InputStep: Codable {
  enum Kind: String, Codable { case move, down, up, key, wheel, pause }
  var t: Kind
  var x: Double?
  var y: Double?
  var button: Int?     // 0 left, 1 middle, 2 right
  var clicks: Int?     // click count for down/up (2 = the second click of a double click)
  var key: String?     // W3C key value: one character or a name like "Enter"
  var down: Bool?
  var dx: Double?
  var dy: Double?
  var ms: Double?
  var mods: Int?
  var buttons: Int?    // buttons held during a move (bit 1 << button), so a held move is a drag

  var modifiers: KeyModifiers { KeyModifiers(rawValue: mods ?? 0) }
}

extension Browser {
  /// Posts the steps in order and returns once the page has received them all.
  func send(_ steps: [InputStep]) async throws {
    let mark = await inputMark()
    var last: String?
    for s in steps {
      switch s.t {
      case .pause:
        try await Task.sleep(nanoseconds: UInt64(max(0, s.ms ?? 0) * 1e6))
      case .move, .down, .up:
        guard let x = s.x, let y = s.y else { throw CLIError("a pointer step needs x and y", code: ExitCode.usage) }
        try pointer(s.t, x: x, y: y, button: s.button ?? 0, clicks: s.clicks ?? 1, modifiers: s.modifiers, buttons: s.buttons ?? 0)
        last = ["move": "mousemove", "down": "mousedown", "up": "mouseup"][s.t.rawValue]
      case .key:
        guard let key = s.key, let down = s.down else { throw CLIError("a key step needs key and down", code: ExitCode.usage) }
        try self.key(s.modifiers.contains(.shift) ? shifted(key) : key, down: down, modifiers: s.modifiers)
        last = down ? "keydown" : "keyup"
      case .wheel:
        guard let x = s.x, let y = s.y else { throw CLIError("a wheel step needs x and y", code: ExitCode.usage) }
        try wheel(x: x, y: y, dx: s.dx ?? 0, dy: s.dy ?? 0, modifiers: s.modifiers)
        last = "wheel"
      }
    }
    if let last { await inputSettled(last: last, since: mark) }
  }
}

/// WebDriver's special keys (U+E000…) as W3C key values; nil for a code point that isn't one.
func webDriverKeyName(_ s: Unicode.Scalar) -> String? {
  let names: [UInt32: String] = [
    0xE000: "Unidentified", 0xE001: "Cancel", 0xE002: "Help", 0xE003: "Backspace", 0xE004: "Tab", 0xE005: "Clear",
    0xE006: "Enter", 0xE007: "Enter", 0xE008: "Shift", 0xE009: "Control", 0xE00A: "Alt", 0xE00B: "Pause",
    0xE00C: "Escape", 0xE00D: " ", 0xE00E: "PageUp", 0xE00F: "PageDown", 0xE010: "End", 0xE011: "Home",
    0xE012: "ArrowLeft", 0xE013: "ArrowUp", 0xE014: "ArrowRight", 0xE015: "ArrowDown", 0xE016: "Insert", 0xE017: "Delete",
    0xE03D: "Meta", 0xE050: "Shift", 0xE051: "Control", 0xE052: "Alt", 0xE053: "Meta",
    0xE054: "PageUp", 0xE055: "PageDown", 0xE056: "End", 0xE057: "Home",
    0xE058: "ArrowLeft", 0xE059: "ArrowUp", 0xE05A: "ArrowRight", 0xE05B: "ArrowDown", 0xE05C: "Insert", 0xE05D: "Delete",
  ]
  if let n = names[s.value] { return n }
  if (0xE031...0xE03C).contains(s.value) { return "F\(s.value - 0xE031 + 1)" }
  return nil
}

/// What a US keyboard types for `key` with Shift held: "a" → "A", "1" → "!".
func shifted(_ key: String) -> String {
  guard key.count == 1, let c = key.first else { return key }
  if c.isLowercase { return c.uppercased() }
  let symbols: [Character: Character] = [
    "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+",
    "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
  ]
  return symbols[c].map(String.init) ?? key
}

/// The keys that type `text`: newline is Enter, tab is Tab, everything else its own character.
func keysFor(_ text: String) -> [String] {
  text.map { c in c == "\n" || c == "\r\n" ? "Enter" : c == "\t" ? "Tab" : String(c) }
}

/// Where a person would click `el`: scrolled into view, the centre of its first box, in top-level
/// viewport coordinates (through same-origin iframes). Refuses an element covered by another one.
let pointAtJS = """
  const pointAt = (el, sel) => {
    el.scrollIntoView({block: 'center', inline: 'center'});
    const box = [...el.getClientRects()].find(r => r.width > 0 && r.height > 0);
    if (!box) throw new Error('WKCLI: ' + sel + ' has no size on the page — a person could not click it');
    let x = box.x + box.width / 2, y = box.y + box.height / 2;
    const root = el.getRootNode();
    const hit = (root.elementFromPoint ? root : el.ownerDocument).elementFromPoint(x, y);
    let doc = el.ownerDocument;
    while (doc !== document) {
      const r = doc.defaultView.frameElement.getBoundingClientRect();
      x += r.x + doc.defaultView.frameElement.clientLeft; y += r.y + doc.defaultView.frameElement.clientTop;
      doc = doc.defaultView.frameElement.ownerDocument;
    }
    const ok = hit && (hit === el || el.contains(hit) || (el.labels && [...el.labels].some(l => l.contains(hit))));
    if (!ok) {
      const what = hit ? '<' + hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '') + '>' : 'nothing';
      throw new Error('WKCLI: ' + sel + ' is covered by ' + what + ' at its centre — a person would click that instead');
    }
    return {x, y};
  };
  """
