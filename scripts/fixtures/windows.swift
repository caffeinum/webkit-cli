// Lists webkit-cli windows (owner name contains "webkit-cli"). Exit 1 if any is ordered in (kCGWindowIsOnscreen) with bounds on a display.
// Exit 1 if any webkit-cli window intersects a display. Usage: swift scripts/fixtures/windows.swift
import AppKit
let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let screens = NSScreen.screens.map { $0.frame }
var onScreen = 0
for w in infos where (w[kCGWindowOwnerName as String] as? String ?? "").contains("webkit-cli") {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    let visible = (w[kCGWindowIsOnscreen as String] as? Bool ?? false) && r.width > 1 && r.height > 1 && screens.contains { $0.intersects(r) }
    if visible { onScreen += 1 }
    print("pid=\(w[kCGWindowOwnerPID as String] ?? "?") isOnscreen=\(w[kCGWindowIsOnscreen as String] ?? false) alpha=\(w[kCGWindowAlpha as String] ?? "?") name=\(w[kCGWindowName as String] ?? "") layer=\(w[kCGWindowLayer as String] ?? "?") bounds=\(r) \(visible ? "ON-SCREEN" : "offscreen")")
}
print("webkit-cli windows on screen: \(onScreen)")
exit(onScreen == 0 ? 0 : 1)
