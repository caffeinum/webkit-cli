// Plays the human for escalate QA (docs/acceptance/escalate.md): acts on the VISIBLE window of one
// process via Accessibility + CGEvents, never via page JS. Needs Accessibility permission for the caller.
//
// usage: swift scripts/fixtures/human.swift <pid> <command> [args]
//   window [--timeout s]     wait for an on-screen window, print {title,frame,main,focused}
//   type <dom-id> <text>     click the element with that DOM id in the window, then type keystrokes
//   press <dom-id|title>     AXPress a web element (DOM id) or a native button (title), e.g. `press Done`
//   click <dom-id|title>     real mouse click at the element's centre (window must be frontmost)
//   cmdw                     send ⌘W via the HID tap, only if the process is frontmost
//   close                    press the window's close (red) button
//   watch <seconds>          poll every 0.5s; exit 1 if the process ever has an on-screen window
// Exit: 0 ok, 1 not found / window seen (watch), 2 usage.
import AppKit
import ApplicationServices

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
  FileHandle.standardError.write("human: \(msg)\n".data(using: .utf8)!)
  exit(code)
}

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2, let pid = pid_t(args.first!) else {
  fail("usage: human.swift <pid> window|type|press|click|cmdw|close|watch …", 2)
}
let command = args.dropFirst().first!
let rest = Array(args.dropFirst(2))
guard AXIsProcessTrusted() else { fail("this process lacks Accessibility permission") }
let app = AXUIElementCreateApplication(pid)

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
  return value as? T
}

func frame(_ el: AXUIElement) -> CGRect? {
  guard let p: AXValue = attr(el, kAXPositionAttribute), let s: AXValue = attr(el, kAXSizeAttribute) else { return nil }
  var origin = CGPoint.zero, size = CGSize.zero
  AXValueGetValue(p, .cgPoint, &origin)
  AXValueGetValue(s, .cgSize, &size)
  return CGRect(origin: origin, size: size)
}

// on-screen per the window server, not just per AX
func onScreenWindowIDs() -> [CGRect] {
  let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  let displays = NSScreen.screens.map { $0.frame }
  return infos.compactMap { w in
    guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    return r.width > 1 && r.height > 1 && displays.contains { $0.intersects(r) } ? r : nil
  }
}

func visibleWindow() -> AXUIElement? {
  let onScreen = onScreenWindowIDs()
  let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
  return windows.first { w in frame(w).map { f in onScreen.contains { $0.intersects(f) } } ?? false }
}

func requireWindow() -> AXUIElement {
  guard let w = visibleWindow() else { fail("pid \(pid) has no on-screen window") }
  return w
}

func find(_ root: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
  if match(root) { return root }
  guard depth < 60, let kids: [AXUIElement] = attr(root, kAXChildrenAttribute) else { return nil }
  for k in kids { if let hit = find(k, depth: depth + 1, match) { return hit } }
  return nil
}

// WebKit builds the web area's AX tree lazily on first query, so retry for a few seconds
func element(_ key: String, in window: AXUIElement) -> AXUIElement {
  let deadline = Date().addingTimeInterval(5)
  repeat {
    let byDOM = find(window) { (attr($0, "AXDOMIdentifier") as String?) == key }
    let hit = byDOM ?? find(window) { el in
      (attr(el, kAXRoleAttribute) as String?) == kAXButtonRole
        && [(attr(el, kAXTitleAttribute) as String?), (attr(el, kAXDescriptionAttribute) as String?)].contains(key)
    }
    if let hit { return hit }
    usleep(250_000)
  } while Date() < deadline
  fail("no element with DOM id or button title '\(key)' in the visible window")
}

func mouseClick(_ el: AXUIElement) {
  guard let f = frame(el) else { fail("element has no frame") }
  let pt = CGPoint(x: f.midX, y: f.midY)
  for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(50_000)
  }
}

func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
  for down in [true, false] {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    e.flags = flags
    if let text { let u = Array(text.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
    e.postToPid(pid)
    usleep(15_000)
  }
}

// cannotComplete = delivered but the app didn't answer (it hid/closed/exited inside the action);
// scenarios verify the outcome through webkit-cli, so that counts as pressed
func pressOrFail(_ el: AXUIElement, _ name: String) {
  let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
  switch err {
  case .success: print("pressed \(name)")
  case .cannotComplete: print("pressed \(name) (no reply from the app)")
  default: fail("AXPress on '\(name)' failed: AXError \(err.rawValue)")
  }
}

func activate() {
  NSRunningApplication(processIdentifier: pid)?.activate()
  usleep(300_000)
}

switch command {
case "window":
  let timeout = rest.count == 2 && rest[0] == "--timeout" ? Double(rest[1]) ?? 10 : 10
  let deadline = Date().addingTimeInterval(timeout)
  while visibleWindow() == nil {
    if Date() > deadline { fail("no on-screen window for pid \(pid) within \(timeout)s") }
    usleep(200_000)
  }
  let w = requireWindow()
  let f = frame(w) ?? .zero
  let out: [String: Any] = [
    "title": (attr(w, kAXTitleAttribute) as String?) ?? "",
    "frame": [f.origin.x, f.origin.y, f.width, f.height],
    "main": (attr(w, kAXMainAttribute) as Bool?) ?? false,
    "focused": (attr(w, kAXFocusedAttribute) as Bool?) ?? false,
    "appFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
  ]
  print(String(data: try! JSONSerialization.data(withJSONObject: out, options: .sortedKeys), encoding: .utf8)!)
case "type":
  guard rest.count == 2 else { fail("usage: type <dom-id> <text>", 2) }
  let w = requireWindow()
  let el = element(rest[0], in: w)
  activate()
  AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  mouseClick(el)
  for ch in rest[1] { key(0, text: String(ch)) }
  // AXValue can lag the keystrokes (React re-render), so poll briefly
  var value = ""
  for _ in 0..<20 where value != rest[1] {
    usleep(100_000)
    value = attr(el, kAXValueAttribute) ?? ""
  }
  guard value == rest[1] else { fail("typed into '\(rest[0])' but its value is \(value.count) chars, expected \(rest[1].count)") }
  print("typed \(rest[1].count) chars into #\(rest[0])")
case "press":
  guard rest.count == 1 else { fail("usage: press <dom-id|title>", 2) }
  let el = element(rest[0], in: requireWindow())
  pressOrFail(el, rest[0])
case "click":
  guard rest.count == 1 else { fail("usage: click <dom-id|title>", 2) }
  let el = element(rest[0], in: requireWindow())
  activate()
  mouseClick(el)
  print("clicked \(rest[0])")
case "cmdw":
  // menu key equivalents only fire for events from the HID tap, not postToPid; guard so a stray ⌘W
  // can never land in another app
  _ = requireWindow()
  activate()
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { fail("pid \(pid) is not frontmost; not sending ⌘W") }
  for down in [true, false] {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: down)!  // kVK_ANSI_W
    e.flags = .maskCommand
    e.post(tap: .cghidEventTap)
    usleep(30_000)
  }
  print("sent ⌘W (HID, pid frontmost)")
case "close":
  let w = requireWindow()
  guard let b: AXUIElement = attr(w, kAXCloseButtonAttribute) else { fail("window has no close button") }
  pressOrFail(b, "close button")
case "watch":
  guard rest.count == 1, let secs = Double(rest[0]) else { fail("usage: watch <seconds>", 2) }
  let deadline = Date().addingTimeInterval(secs)
  var polls = 0
  while Date() < deadline {
    polls += 1
    if let r = onScreenWindowIDs().first { fail("pid \(pid) showed an on-screen window \(r) (poll \(polls))") }
    usleep(500_000)
  }
  print("no on-screen window for pid \(pid) in \(polls) polls over \(secs)s")
default:
  fail("unknown command \(command)", 2)
}
