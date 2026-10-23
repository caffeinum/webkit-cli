#if os(macOS)
import AppKit
import WebKit

/// A tab's window always reports itself key. WebKit treats a page in a non-key window as inactive
/// and turns its mouse moves into scrollbar updates (no hover, no mousemove); a headless tab of an
/// accessory process can never become key for real, and activating would steal the person's focus.
final class TabWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

private typealias DoAfter = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
private typealias SendEvent = @convention(c) (AnyObject, Selector, NSEvent) -> Void
private let afterMouseSel = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
private let afterKeysSel = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
private let simulateMoveSel = NSSelectorFromString("_simulateMouseMove:")

/// The private WKWebView hooks trusted input relies on; missing ones fail loudly at tab creation.
func requireInputSPI(_ web: WKWebView) throws {
  for sel in [afterMouseSel, afterKeysSel, simulateMoveSel] where !web.responds(to: sel) {
    throw CLIError("WKWebView no longer implements the private \(NSStringFromSelector(sel)) (macOS update?); trusted input can't work, so refusing to run.")
  }
}

extension Browser {
  /// A mouse event at (x, y) CSS px of the viewport. `buttons` (bit per button) held during a move makes it a drag.
  func pointer(_ kind: InputStep.Kind, x: Double, y: Double, button: Int, clicks: Int, modifiers: KeyModifiers, buttons: Int = 0) throws {
    let type: NSEvent.EventType
    switch (kind, button) {
    case (.move, _):
      type = buttons & 1 != 0 ? .leftMouseDragged : .mouseMoved
    case (.down, 0): type = .leftMouseDown
    case (.up, 0): type = .leftMouseUp
    // a real right click opens WebKit's native context menu, whose tracking loop blocks this process
    case (.down, _), (.up, _): throw CLIError("mouse button \(button) isn't supported on mac (only the left one, 0)", code: ExitCode.usage)
    default: throw CLIError("\(kind) is not a pointer event")
    }
    guard let e = NSEvent.mouseEvent(with: type, location: windowPoint(x, y), modifierFlags: modifiers.flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, eventNumber: 0, clickCount: kind == .move ? 0 : clicks,
                                     pressure: kind == .down ? 1 : 0) else {
      throw CLIError("could not make a \(type) event")
    }
    if type == .mouseMoved {
      unsafeBitCast(web.method(for: simulateMoveSel), to: SendEvent.self)(web, simulateMoveSel, e)
    } else {
      window.sendEvent(e)
    }
  }

  func wheel(x: Double, y: Double, dx: Double, dy: Double, modifiers: KeyModifiers) throws {
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: Int32((-dy).rounded()), wheel2: Int32((-dx).rounded()), wheel3: 0) else {
      throw CLIError("could not make a scroll event")
    }
    // a window-less NSEvent's locationInWindow is its screen point, so put the screen point where
    // the view expects the window point (CG screen space is flipped against Cocoa's)
    let p = windowPoint(x, y)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    cg.location = CGPoint(x: p.x, y: primaryHeight - p.y)
    cg.flags = CGEventFlags(rawValue: UInt64(modifiers.flags.rawValue))
    guard let e = NSEvent(cgEvent: cg) else { throw CLIError("could not make a scroll event") }
    web.scrollWheel(with: e)
  }

  /// A key going down or up. `key` is a W3C key value: one character, or a name like "Enter" or "Shift".
  func key(_ key: String, down: Bool, modifiers: KeyModifiers) throws {
    if let m = KeyModifiers(key: key) {
      let held = down ? modifiers.union(m) : modifiers.subtracting(m)
      guard let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held.flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                     keyCode: macModifierKeyCodes[key]!) else { throw CLIError("could not make a \(key) event") }
      window.sendEvent(e)
      return
    }
    let (code, chars, shifted) = try macKey(key)
    var flags = modifiers.flags
    if shifted { flags.insert(.shift) }
    if chars.unicodeScalars.first.map({ (0xF700...0xF8FF).contains($0.value) }) == true { flags.insert(.function) }
    guard let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                   isARepeat: false, keyCode: code) else { throw CLIError("could not make a \(key) event") }
    // AppKit offers ⌘-combinations as key equivalents before it sends them as key events
    if down, flags.contains(.command), web.performKeyEquivalent(with: e) { return }
    window.sendEvent(e)
  }

  func inputMark() async -> [String: Int] { [:] }

  /// Resolves once WebKit has handed every queued mouse and key event to the page.
  func inputSettled(last _: String, since _: [String: Int]) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      let afterMouse = unsafeBitCast(web.method(for: afterMouseSel), to: DoAfter.self)
      let afterKeys = unsafeBitCast(web.method(for: afterKeysSel), to: DoAfter.self)
      afterMouse(web, afterMouseSel) { [web] in afterKeys(web, afterKeysSel) { c.resume() } }
    }
  }

  private func windowPoint(_ x: Double, _ y: Double) -> NSPoint {
    web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
  }
}

private extension KeyModifiers {
  var flags: NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if contains(.shift) { f.insert(.shift) }
    if contains(.control) { f.insert(.control) }
    if contains(.alt) { f.insert(.option) }
    if contains(.meta) { f.insert(.command) }
    return f
  }
}

private let macModifierKeyCodes: [String: UInt16] = ["Shift": 56, "Control": 59, "Alt": 58, "Meta": 55]

/// US-layout virtual key codes, so `code` reads like a real keyboard's.
private let macCharKeyCodes: [Character: UInt16] = [
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
  "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
  "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
  "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
]
private let shiftedChars: [Character: Character] = [
  "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
  "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
]
private func fn(_ k: Int) -> String { String(UnicodeScalar(UInt32(k))!) }
private let macNamedKeys: [String: (UInt16, String)] = [
  "Enter": (36, "\r"), "Tab": (48, "\t"), "Backspace": (51, "\u{7F}"), "Escape": (53, "\u{1B}"), " ": (49, " "),
  "Delete": (117, fn(NSDeleteFunctionKey)), "Home": (115, fn(NSHomeFunctionKey)), "End": (119, fn(NSEndFunctionKey)),
  "PageUp": (116, fn(NSPageUpFunctionKey)), "PageDown": (121, fn(NSPageDownFunctionKey)),
  "ArrowLeft": (123, fn(NSLeftArrowFunctionKey)), "ArrowRight": (124, fn(NSRightArrowFunctionKey)),
  "ArrowDown": (125, fn(NSDownArrowFunctionKey)), "ArrowUp": (126, fn(NSUpArrowFunctionKey)),
  "Insert": (114, fn(NSHelpFunctionKey)), "Help": (114, fn(NSHelpFunctionKey)),
  "F1": (122, fn(NSF1FunctionKey)), "F2": (120, fn(NSF2FunctionKey)), "F3": (99, fn(NSF3FunctionKey)),
  "F4": (118, fn(NSF4FunctionKey)), "F5": (96, fn(NSF5FunctionKey)), "F6": (97, fn(NSF6FunctionKey)),
  "F7": (98, fn(NSF7FunctionKey)), "F8": (100, fn(NSF8FunctionKey)), "F9": (101, fn(NSF9FunctionKey)),
  "F10": (109, fn(NSF10FunctionKey)), "F11": (103, fn(NSF11FunctionKey)), "F12": (111, fn(NSF12FunctionKey)),
]

/// (virtual key code, characters, needs Shift on a US keyboard)
private func macKey(_ key: String) throws -> (UInt16, String, Bool) {
  if let (code, chars) = macNamedKeys[key] { return (code, chars, false) }
  guard key.count == 1, let c = key.first else {
    throw CLIError("key \(key) isn't supported (one character, or Enter, Tab, Backspace, Escape, Delete, Home, End, PageUp, PageDown, arrows, F1–F12, Shift, Control, Alt, Meta)", code: ExitCode.usage)
  }
  if let code = macCharKeyCodes[c] { return (code, key, false) }
  if c.isUppercase, let lower = c.lowercased().first, let code = macCharKeyCodes[lower] { return (code, key, true) }
  if let base = shiftedChars[c], let code = macCharKeyCodes[base] { return (code, key, true) }
  return (0, key, false) // a character no US key types (é, 日): WebKit inserts it as text all the same
}
#endif
