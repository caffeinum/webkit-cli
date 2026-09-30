# webkit-cli

swift package, one executable target. `swift build -c release`, then `./scripts/check.sh` (headless regression: doctor + open/text/eval/shot on example.com, throwaway `-` account only).

- headless = borderless window at (-20000,-20000) + orderFrontRegardless + `_setWindowOcclusionDetectionEnabled:` NO, called via `@convention(c)` bitcast (never `perform(_:with:NSNumber)`). missing selector → hard fail.
- WebKit stores data under ~/Library/WebKit/<process name>/ → binary name is pinned to `webkit-cli` (Accounts.requirePinnedExecutableName).
- `WKWebsiteDataStore.remove(forIdentifier:)` segfaults if it's the first WebKit call in the process → touch a nonPersistent store first (Commands.removeDataStore).
- Low Power Mode caps rAF at 30/s; doctor only requires > 0.
- passkeys need a signed .app with com.apple.developer.web-browser.public-key-credential; unbundled CLI can't.
- never test against aleks's real accounts or ~/Library/WebKit/com.officecommun.search.
- default profile is `main` (v1 accounts compat); named profiles only created by `auth --account`.
- aleks may be running `.build/release/webkit-cli auth` — don't rebuild into .build while one runs (`pgrep -fl webkit-cli`); build with `--scratch-path` elsewhere and `BIN=... ./scripts/check.sh`.
- session mode: one `serve` process per profile (Daemon.swift), unix socket in ~/.config/webkit-cli/run; requests serialized; SIGPIPE ignored (clients Ctrl-C). client must NOT shutdown(SHUT_WR) — server detects hung-up queued clients via POLLHUP.
- acceptance scenarios: docs/acceptance/session-mode.md; fake oauth fixture scripts/fixtures/oauth_server.py (app :8765, idp :8766); rehearsal scripts/rehearse-browser-use.sh.
- linux backend (Sources/webkit-cli/Linux + Sources/WPEShim C shim + Sources/CWPE module map): WPE WebKit 2.54 headless (Debian sid). mac-only code lives in Sources/webkit-cli/Mac under #if os(macOS); shared Engine only uses Browser.url/title/isLoading/callJS/…; both backends define `Browser`, `Profile`, `ephemeralStore()`, `startApp()`.
- linux main loop: GLib owns the main thread and drains libdispatch's main-queue eventfd (_dispatch_get_main_queue_handle_4CF) — that's how @MainActor + WebKit coexist.
- linux tests: `scripts/test-linux-daytona.sh` (creates a Daytona sandbox from linux/Dockerfile snapshot, uploads HEAD, runs scripts/check-session.sh + rehearsals, deletes sandbox). daytona exec waits on all descendants and its proxy drops long requests → run long things detached (the script's `job`). WebKit's bwrap sandbox needs userns: containers need WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 (never set by us).
- `scripts/check-session.sh` = session suite against the local fixture, runs on mac + linux (BIN=…).
- release: tags vX.Y.Z; `mint install caffeinum/webkit-cli` uses the latest tag.
- linux windows (auth/show/--escalate) need Wayland (WPE has no X11). a WPE page can't change display, so linux `show` = a second view on the same profile at the tab's URL; the headless copy is parked on about:blank; `hide`/close hands back at the window's final URL. tested by scripts/check-windows-linux.sh under `weston --backend=headless`; fixture `?challenge=auto` stands in for the person.
