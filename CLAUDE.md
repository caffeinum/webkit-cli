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
