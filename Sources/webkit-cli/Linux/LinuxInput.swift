#if os(Linux)
import Foundation
import WPEShim

/// Counts the trusted input events the page has received, in webkit-cli's isolated world (the user
/// script that installs it also keeps that world alive between calls).
/// WebKit queues input and hands it to the page one event at a time, so the last event we sent
/// arriving means every earlier one has too.
let isolatedWorld = "webkit-cli"
let inputWorldScript = """
  if (!window.__wkSeen) {
    window.__wkSeen = {doc: Math.floor(Math.random() * 2 ** 31)};
    for (const t of ['mousemove', 'mousedown', 'mouseup', 'keydown', 'keyup', 'wheel'])
      addEventListener(t, e => { if (e.isTrusted) __wkSeen[t] = (__wkSeen[t] || 0) + 1; }, true);
  }
  """
private let countJS = inputWorldScript + "return __wkSeen;"

extension Browser {
  func pointer(_ kind: InputStep.Kind, x: Double, y: Double, button: Int, clicks: Int, modifiers: KeyModifiers, buttons: Int = 0) throws {
    let wpeKind: Int32
    switch kind {
    case .move: wpeKind = 0
    case .down: wpeKind = 1
    case .up: wpeKind = 2
    default: throw CLIError("\(kind) is not a pointer event")
    }
    guard (0...2).contains(button) else { throw CLIError("mouse button \(button) isn't supported (0 left, 1 middle, 2 right)", code: ExitCode.usage) }
    var mods = modifiers.wpe
    // WPEModifiers: POINTER_BUTTON1…3 are bits 8…10
    for (bit, mask) in [(1, UInt32(1 << 8)), (2, UInt32(1 << 9)), (4, UInt32(1 << 10))] where buttons & bit != 0 { mods |= mask }
    // WPE numbers buttons like X11: 1 left, 2 middle, 3 right
    wk_tab_pointer(try inputTab(), wpeKind, x, y, UInt32([1, 2, 3][button]), UInt32(clicks), mods)
  }

  func wheel(x: Double, y: Double, dx: Double, dy: Double, modifiers: KeyModifiers) throws {
    wk_tab_scroll(try inputTab(), x, y, -dx, -dy, modifiers.wpe)
  }

  func key(_ key: String, down: Bool, modifiers: KeyModifiers) throws {
    var mods = modifiers
    if let m = KeyModifiers(key: key) { mods = down ? mods.union(m) : mods.subtracting(m) }
    let (keyval, shifted) = try keysym(key)
    if shifted { mods.insert(.shift) }
    wk_tab_key(try inputTab(), down ? 1 : 0, keyval, mods.wpe)
  }

  func inputMark() async -> [String: Int] {
    (try? await callJS(countJS)) as? [String: Int] ?? [:]
  }

  /// Waits until the page has received the last event sent (its type `last`) after `mark`.
  /// A navigation replaces the world and its counts: the events reached the old page, so that's settled too.
  func inputSettled(last: String, since mark: [String: Int]) async {
    let until = Date().addingTimeInterval(2)
    while Date() < until {
      guard let seen = try? await callJS(countJS) as? [String: Int] else { return }
      if seen["doc"] != mark["doc"] { return } // a new document
      if seen[last, default: 0] > mark[last, default: 0] { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func inputTab() throws -> OpaquePointer {
    if let presented { return try presented.inputTab() }
    guard let tab else { throw CLIError("tab was closed") }
    return tab
  }
}

private extension KeyModifiers {
  /// WPEModifiers: KEYBOARD_CONTROL 1<<0, SHIFT 1<<1, ALT 1<<2, META 1<<3
  var wpe: UInt32 {
    var m: UInt32 = 0
    if contains(.control) { m |= 1 << 0 }
    if contains(.shift) { m |= 1 << 1 }
    if contains(.alt) { m |= 1 << 2 }
    if contains(.meta) { m |= 1 << 3 }
    return m
  }
}

private let namedKeysyms: [String: UInt32] = [
  "Enter": 0xff0d, "Tab": 0xff09, "Backspace": 0xff08, "Escape": 0xff1b, "Delete": 0xffff, "Insert": 0xff63,
  "Home": 0xff50, "End": 0xff57, "PageUp": 0xff55, "PageDown": 0xff56,
  "ArrowLeft": 0xff51, "ArrowUp": 0xff52, "ArrowRight": 0xff53, "ArrowDown": 0xff54,
  "Shift": 0xffe1, "Control": 0xffe3, "Alt": 0xffe9, "Meta": 0xffeb, "Help": 0xff6a, " ": 0x20,
]
private let shiftedChars = Set("~!@#$%^&*()_+{}|:\"<>?")

/// (XKB keysym, needs Shift on a US keyboard)
private func keysym(_ key: String) throws -> (UInt32, Bool) {
  if let k = namedKeysyms[key] { return (k, false) }
  if key.hasPrefix("F"), let n = UInt32(key.dropFirst()), (1...12).contains(n) { return (0xffbe + n - 1, false) }
  guard key.unicodeScalars.count == 1, let c = key.unicodeScalars.first, let ch = key.first else {
    throw CLIError("key \(key) isn't supported (one character, or Enter, Tab, Backspace, Escape, Delete, Home, End, PageUp, PageDown, arrows, F1–F12, Shift, Control, Alt, Meta)", code: ExitCode.usage)
  }
  // X11: Latin-1 keysyms are the code point, everything else is 0x01000000 + code point
  let sym = (0x20...0x7e).contains(c.value) || (0xa0...0xff).contains(c.value) ? c.value : 0x0100_0000 + c.value
  return (sym, ch.isUppercase || shiftedChars.contains(ch))
}
#endif
