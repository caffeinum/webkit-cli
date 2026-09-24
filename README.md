# webkit-cli

A tiny macOS CLI over the system WebKit (`WKWebView`) so agents can browse **logged in** with **no windows**.

Sign in to a service once in a real window (usually "Sign in with Google/GitHub"). After that every command runs headless: navigate dashboards, click, read, create and copy API keys.

## Why this works (the occlusion finding)

A `WKWebView` with no window, or in a hidden app, is treated as occluded. WebKit reports `document.visibilityState === "hidden"`, stops `requestAnimationFrame`, clamps timers, and React/Next apps never finish hydrating, so buttons do nothing. Spoofing `visibilityState` from JS doesn't help because the engine still throttles. What does work: put the view in a **borderless window at (-20000, -20000)**, call `orderFrontRegardless()`, use activation policy `.accessory` (no Dock icon), and turn off WebKit's occlusion detection with the private `-[WKWebView _setWindowOcclusionDetectionEnabled:NO]`. The page then renders at full speed where no one can see it. If a macOS update removes that selector, webkit-cli **refuses to run** instead of running throttled without telling you.

Measured with `webkit-cli doctor` on macOS 27.0 (26A5425a), MacBook Pro, 2-second window on a local page:

| setup | visibilityState | rAF / 2s | 10ms-timer ticks / 2s |
|---|---|---|---|
| no window | hidden | 0 | 7 |
| off-screen window only | hidden | 0 | 8 |
| off-screen window + occlusion off (**webkit-cli**) | **visible** | **59–60** | **167** |

These runs were on battery with Low Power Mode on, which caps display refresh at 30 Hz. Earlier runs on AC power measured ~50–60 rAF/s. A live React app (react.dev) hydrates headless: its buttons have React fibers attached.

## Install

Needs macOS 14+ and Xcode or the Command Line Tools.

```sh
git clone https://github.com/caffeinum/webkit-cli && cd webkit-cli
swift build -c release
cp .build/release/webkit-cli /usr/local/bin/    # keep the name "webkit-cli", see below
./scripts/check.sh                              # regression check: doctor + open/text/eval/shot on example.com
```

**Keep the binary named `webkit-cli`.** WebKit files persistent data under `~/Library/WebKit/<executable-name>/WebsiteDataStore/<uuid>`, so a renamed copy would quietly see none of your accounts. The binary checks its own name and refuses to run under any other.

## Commands

```
webkit-cli accounts                         list accounts (JSON)
webkit-cli auth <account> <url>             visible window: sign in, then close it to save
webkit-cli open <account> <url>             → {"url","title","status"}
webkit-cli text <account> <url>             page innerText
webkit-cli eval <account> <url> '<js>'      JS as an async function body → JSON result
webkit-cli shot <account> <url> <out.png>   screenshot of the 1280×800 viewport (PNG at 2× on Retina, mode 0600)
webkit-cli forget <account>                 delete the account and all its website data
webkit-cli doctor                           check that headless pages really render

--wait <sec>     settle time after load (default 3)
--timeout <sec>  give up and exit 3 (default 60; auth has no timeout)
```

- `<account>` is any name you pick. `-` gives a throwaway in-memory session that saves nothing.
- A URL without a scheme gets `https://`.
- Exit codes: `0` ok, `1` error, `2` usage, `3` timeout. Errors go to stderr.

### Sign in once

```sh
webkit-cli auth work google      # accounts.google.com in a real window
webkit-cli auth work github      # github.com/login
webkit-cli auth work https://railway.com/login
```

`auth` is the only command that opens a window: a normal titled window with a real Edit menu, so ⌘V pastes passwords. You type into the page yourself; webkit-cli never handles, stores or prints passwords. Close the window (⌘W), quit (⌘Q) or press Ctrl-C in the terminal to save and exit. Sign in to Google or GitHub in an account once, and "Sign in with Google/GitHub" buttons on other sites in that same account usually complete headless. Popups from `window.open`, which some OAuth flows use, open as real windows here and as hidden ones in headless mode.

### Then run headless

```sh
webkit-cli open work https://console.e2b.dev
webkit-cli text work https://railway.com/account/tokens
webkit-cli eval work https://github.com/settings/tokens 'return document.title'
webkit-cli shot work https://vercel.com/dashboard /tmp/vercel.png
```

`eval` runs your code as the body of an async function in the page. `return` gives the output and `await` works. Multi-step flows (click, wait, read) go inside a single `eval`:

```sh
webkit-cli eval work https://railway.com/account/tokens '
  const i = document.querySelector("input[name=name]");
  // React-controlled inputs: use the native setter, then fire input/change
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(i, "agent-key");
  i.dispatchEvent(new Event("input", {bubbles: true}));
  [...document.querySelectorAll("button")].find(b => b.textContent.trim() === "Create").click();
  for (let t = 0; t < 20; t++) {
    await new Promise(r => setTimeout(r, 500));
    const dialog = document.querySelector("[role=dialog]");
    if (dialog) return dialog.innerText;
  }
  throw new Error("no dialog appeared");'
```

For `<select>`, use `HTMLSelectElement.prototype`'s setter and dispatch `change`. To submit a form, call `form.requestSubmit()` or the button's `.click()`.

## Security

- `~/.config/webkit-cli/` (mode 0700) holds `accounts.json` (name → store UUID) and `sessions/<uuid>.plist`, the saved session cookies. Every file is written 0600. Screenshots are written 0600 too, since they may show secrets.
- **Cookies are credentials.** Anyone who can read `~/Library/WebKit/webkit-cli/` or `~/.config/webkit-cli/` is logged in as you. Never commit, sync or share them.
- webkit-cli never prints cookies or passwords. What your `eval` returns is up to you. When a flow creates an API key, write it to a 0600 file or pipe it straight into its destination. Don't return it into a log someone else reads.
- User agent: Safari's, built from the installed Safari's version (`/Applications/Safari.app/Contents/Info.plist`), because Google sign-in rejects WKWebView's default UA. If that file can't be read, webkit-cli fails instead of guessing.

## Known gaps

- **Session-only cookies**: WebKit doesn't persist cookies without an expiry. For example, e2b loses its login when the process exits. webkit-cli saves them to `sessions/<uuid>.plist` at the end of each command and restores them before loading. A site that rotates its session cookie mid-command is saved with the new value, but only if the command finishes successfully.
- **Private SPI**: `_setWindowOcclusionDetectionEnabled:` is private and could disappear in a macOS update. Run `webkit-cli doctor` after updating. It exits non-zero if pages are throttled.
- **Passkeys**: WebAuthn platform passkeys (iCloud Keychain / Touch ID) **don't work** in this unbundled CLI. `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` returns `false`. WKWebView only offers them to apps signed with the restricted `com.apple.developer.web-browser.public-key-credential` entitlement, and that entitlement needs an embedded provisioning profile, which only a signed `.app` bundle can carry. This is how apps like Search.app do it. Workaround for now: at the Google/GitHub prompt, choose password, a phone prompt or a security code instead of a passkey. Wrapping webkit-cli in a signed `.app` would fix this, but WebKit would then key its storage by bundle ID instead of binary name, so existing accounts would need migrating.
- **No network interception**: you can't read or modify requests or responses. Use `fetch` inside `eval` when you need an API call with the page's cookies.
- **Synthetic events aren't trusted**: `.click()` and `dispatchEvent` produce `isTrusted: false` events. Most apps accept them. A few (some payment and captcha widgets) don't.
- **One process per command**: every command loads the page fresh. A long-lived daemon/session mode (load once, send many steps) is planned for v2. Until then, put multi-step flows inside one `eval`.
- `eval` and `text` see only the main page. Popups and cross-origin iframes aren't scriptable from the CLI.

## What's verified

On macOS 27.0 with `scripts/check.sh`: `doctor` (visible, rAF > 0), `open`, `text`, `eval` (including `await` and JS errors → exit 1), `shot` (valid PNG), and `--timeout` → exit 3, all against example.com. Also checked by hand: persistent cookies and localStorage survive across processes in a named account, session-only cookies come back only because of the side-car file (with the file moved away they're gone), `forget` deletes both the WebKit store and the side-car, and a renamed binary refuses to run.

**Not yet verified:** `auth` has not been run end to end. It needs a person at the keyboard to sign in. The underlying technique (Safari UA, per-account store, Google account chooser → signed in headless) was proven in the prototypes this tool grew from, but not through this binary.
