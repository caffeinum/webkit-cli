# webkit-cli

A tiny macOS CLI over the system WebKit (`WKWebView`) so agents can browse **logged in** with **no windows**.

Sign in to a service once in a real window (usually "Sign in with Google/GitHub"). After that every command runs headless: navigate dashboards, click, read, create and copy API keys. If a headless flow hits a step only a person can do (Google's "confirm it's you", 2FA, a captcha), you can opt in to have that same live tab pop up, let the person finish, and carry on headless.

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
webkit-cli auth <url>                   open a window at <url>; sign in; click Done to save

webkit-cli open <url>                   open a live tab → {"tab","url","title","status","loading"}
webkit-cli click <tab> <selector>       click; waits for any navigation it starts
webkit-cli type <tab> <selector> <text> set an input's value (React-safe); the text is never echoed
webkit-cli wait <tab> [--until-url <regex>] [--until-selector <css>]
webkit-cli goto <tab> <url>             navigate an open tab
webkit-cli snapshot <tab|url>           what's on the page: text, headings, and every action with a ref
webkit-cli eval <tab|url> '<js>'        JS as an async function body → JSON result
webkit-cli shot <tab|url> <out.png>     1280×800 viewport screenshot (2× on Retina, mode 0600)
webkit-cli tabs                         open tabs; popups show up as their own tabs
webkit-cli close <tab>
webkit-cli stop                         end the profile's session now

webkit-cli accounts                     list saved profiles (JSON)
webkit-cli forget <account>             delete a profile and all its website data
webkit-cli doctor                       check that headless pages really render

-a, --account <name>    a separate profile instead of the default; `-` = throwaway (one-shot only)
--wait <sec>            settle time after a load/click (open/goto/one-shot 3, click 1, others 0)
--timeout <sec>         give up and exit 3 (default 60, counted from when the command reaches the session)
--until-url / --until-selector   conditions for `wait`
--out <file>            write eval/snapshot output to a 0600 file, print only {"written","bytes"}
--raw                   eval: print a string result without JSON quotes
--idle <sec>            idle timeout for the session this command starts (default 900)
```

- **One shared default profile.** Every command uses the profile named `main` unless you pass `--account`. `main` is created on first use. A named profile is only created by `auth`, so a typo in `--account` fails instead of silently giving you a logged-out profile.
- **Tabs live between commands.** The first command for a profile starts a background session process for it, reached over a unix socket in `~/.config/webkit-cli/run/` (dir 0700, socket 0600). `open` returns a tab id like `t3f9a2c`, and later commands act on that live tab, so a click that navigates to another site (OAuth) doesn't kill anything. The session exits after `--idle` seconds with no commands (default 15 min) or on `stop`. Commands for one profile run one at a time, in order.
- **A URL instead of a tab** (`snapshot`, `eval`, `shot`) loads it in a temporary tab, acts, and closes the tab.
- `<selector>` is a snapshot ref (`e7`), CSS, or `text=<words>` to match a visible button, link or option by its text (exact first, then the shortest containing match). When nothing matches, the error lists the visible clickable texts.
- A URL without a scheme gets `https://`, so `google.com` means `https://google.com`.
- Exit codes: `0` ok, `1` error, `2` usage, `3` timeout. Errors go to stderr.

### Sign in once

```sh
webkit-cli auth google.com        # sign in to Google, click Done
webkit-cli auth github.com        # same profile, now GitHub too
webkit-cli auth railway.com       # "Sign in with GitHub" completes in the same profile
webkit-cli auth vercel.com --account work   # a second, separate identity
```

`auth` opens a window, and so do `show`/`--escalate` below when you ask for them. Nothing else ever does. It's a normal window with a bar across the top that shows the instruction ("Sign in, then click Done."), the page's current URL, and a **Done** button. It also has a real Edit menu, so ⌘V pastes passwords. You type into the page yourself; webkit-cli never handles, stores or prints passwords. Click Done, close the window (⌘W), quit (⌘Q) or press Ctrl-C in the terminal: every one of these saves and exits. Popups from `window.open`, which some OAuth flows use, open as real windows here and as hidden ones in headless mode.

### Then run headless

```sh
webkit-cli snapshot https://railway.com/account/tokens       # one-shot
webkit-cli eval https://github.com/settings/tokens 'return document.title'

tab=$(webkit-cli open https://cloud.browser-use.com/signin | jq -r .tab)
webkit-cli click $tab 'text=Sign in with Google'             # cross-site redirect: the tab survives
webkit-cli wait  $tab --until-url '^https://cloud\.browser-use\.com/(?!signin)' --timeout 90
webkit-cli goto  $tab 'https://cloud.browser-use.com/settings?tab=api-keys'
webkit-cli eval  $tab --raw --out ~/.config/webkit-cli/secrets/key 'return document.querySelector("code").textContent'
webkit-cli close $tab
```

`scripts/browser-use-apikey.sh` is the full version of that flow: Google account chooser, consent, creating the key, and writing it to a 0600 file without ever printing it. `scripts/rehearse-browser-use.sh` runs the same script against a local fake OAuth server (`scripts/fixtures/oauth_server.py`).

`eval` runs your code as the body of an async function in the page. `return` gives the output and `await` works. If the page navigates while the script runs, the script dies. Split steps that change pages into `click` then `wait`. Within one page, `eval` can do several steps:

```sh
webkit-cli eval $tab '
  const i = document.querySelector("input[name=name]");
  // React-controlled inputs: use the native setter, then fire input/change (this is what `type` does)
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(i, "agent-key");
  i.dispatchEvent(new Event("input", {bubbles: true}));
  [...document.querySelectorAll("button")].find(b => b.textContent.trim() === "Create").click();
  await new Promise(r => setTimeout(r, 1000));
  return document.querySelector("[role=dialog]")?.innerText'
```

### Snapshot: read the page, act by ref

```sh
$ webkit-cli snapshot $tab
Sign in to GitHub · GitHub
https://github.com/login
[e1] link "Skip to content" → /login#start-of-content
[main]
  # Sign in to GitHub
  [form]
    [e2] input text "Username or email address" value="" required
    [e3] input password "Password" value=‹password› required
    [e4] link "Forgot password?" → /password_reset
    [e5] button "Sign in"
…
$ webkit-cli type $tab e2 'me@example.com'
$ webkit-cli click $tab e5
```

- It lists headings, landmarks (`[nav]`, `[main]`, `[form]`…), readable text, and every interactive element with its accessible name, value and state (disabled, required, expanded, `[x]`/`[ ]` checkboxes, a select's value and options, a link's `→ target`). Only visible things are listed: `display:none`, `visibility:hidden`, zero-size, `aria-hidden` and `inert` elements are skipped.
- **Refs** (`e7`, or `ref=e7`) work wherever `click`, `type` and `wait --until-selector` take a selector. An element keeps its ref across snapshots. Ref numbers are never reused within a tab, not even after navigating. So if the element is gone you get `stale ref e7: page changed since the snapshot — take a new one` (exit 1), never a click on something else. The ref is stamped on the element as a `data-wk-ref` attribute.
- Open dialogs get their own `[dialog "…"]` block, first when modal. Same-origin iframes and open shadow roots are walked, and their refs work. Cross-origin iframes show as `[iframe cross-origin <origin>]`. While a modal dialog is open, the page behind it can't be used, so it collapses to one line, `[N elements behind the modal dialog]`, with no refs. Its refs work again once the dialog closes.
- `click` and `type` refuse what a person couldn't reach: disabled, inert, or behind an open modal dialog. That's exit 1 with the reason (`e6 is behind an open modal dialog — a person could not reach it`).
- `type <ref> <text>` on a `<select>` picks the option by label, then by value. `click` on a checkbox toggles it.
- **Values are shown as they are**, API keys included (reading them is the point). `--redact` masks secret-looking values as `‹redacted len=N #sha8›`: known prefixes (`sk-`, `bu_`, `ghp_`, `github_pat_`, `xoxb-`, `AKIA`, JWTs, UUID tokens) and any ≥ 24-char run that mixes letters and digits. The hash is computed in the page, so a masked value never leaves it. **Password inputs are never shown**, with or without `--redact`.
- `--max-chars` (default 8000) is the budget. Text is cut first, then interactive elements. Dialogs are never cut. It ends with `… truncated: N more elements, M chars`.
- `--json`: `{"title", "url", "truncated", "nodes": [...]}`. Every node has `role` and `name` (`""` when there's none). Roles: actionable ones (`button`, `link`, `input text`, `checkbox`, `select`, …), which add `ref` and, when present, `value`, `checked`, `options`, `placeholder`, `href`, `state` (a list); `heading` (adds `level`); `text`; groups (`nav`, `main`, `form`, `dialog`, `iframe`, …) with `children` (dialogs add `modal`); and a cross-origin frame, `{"role": "iframe", "crossOrigin": true, "origin": "…"}`, with no children. `--max-chars` is measured on the text form. `--json` keeps the same nodes, so the JSON can be somewhat longer.
- `text` was removed. Use `snapshot`, or `eval <tab> 'return document.body.innerText'` for raw text.

### When a person is needed

```sh
webkit-cli show $tab --reason "Approve the 2FA prompt, then click Done"   # that live tab, on screen
webkit-cli wait $tab --until-hidden --timeout 600                          # until they click Done
webkit-cli snapshot $tab                                                   # back headless, same page state

webkit-cli click $tab 'text=Continue' --escalate          # pops up only if it lands on a challenge page
webkit-cli wait  $tab --until-url dashboard --escalate --human-timeout 300
```

- `show` puts the tab's own window on screen, with the page state untouched. A bar shows the reason, the live URL and **Done**. Done, ⌘W and the close button all hide it again. None of them close the tab.
- `--escalate` (on `click`, `wait`, `goto`) watches for challenge pages: Google `signin/challenge` and `speedbump`, GitHub 2FA, a visible reCAPTCHA/hCaptcha/Turnstile, and your own `--challenge-url <regex>`. The tab and any popup it opened are both checked. When one hits, it shows that tab, prints `webkit-cli: needs you: …` to stderr right away, waits until the page is past the challenge (or Done), hides it, and returns normally.
- Time spent waiting for the person doesn't count toward `--timeout`. `--human-timeout` (default 600s) bounds it, then exit 3.
- `show`, `hide`, `tabs`, `close` and `stop` skip the command queue, so they work while something is waiting on the person. `close` or `stop` on the tab a `wait` is watching makes that wait exit 1 ("closed before Done"). The session never idles out while a tab is shown.
- `ESCALATE=1 scripts/browser-use-apikey.sh` uses this for Google's "confirm it's you".

## Security

- `~/.config/webkit-cli/` (mode 0700) holds `accounts.json` (name → store UUID) and `sessions/<uuid>.plist`, the saved session cookies. Every file is written 0600. Screenshots are written 0600 too, since they may show secrets.
- **Cookies are credentials.** Anyone who can read `~/Library/WebKit/webkit-cli/` or `~/.config/webkit-cli/` is logged in as you. Never commit, sync or share them.
- webkit-cli never prints cookies or passwords. What your `eval` returns is up to you. When a flow creates an API key, write it to a 0600 file or pipe it straight into its destination. Don't return it into a log someone else reads. `snapshot` prints what the page shows, including API keys and tokens, as they are (unless you pass `--redact`). Password fields are never shown. So treat snapshot output like the page itself: don't paste it where others can read it.
- User agent: Safari's, built from the installed Safari's version (`/Applications/Safari.app/Contents/Info.plist`), because Google sign-in rejects WKWebView's default UA. If that file can't be read, webkit-cli fails instead of guessing.

## Known gaps

- **Session-only cookies**: WebKit doesn't persist cookies without an expiry. For example, e2b loses its login when the process exits. webkit-cli saves them to `sessions/<uuid>.plist` at the end of each command and restores them before loading. A site that rotates its session cookie mid-command is saved with the new value, but only if the command finishes successfully.
- **Private SPI**: `_setWindowOcclusionDetectionEnabled:` is private and could disappear in a macOS update. Run `webkit-cli doctor` after updating. It exits non-zero if pages are throttled.
- **Passkeys**: WebAuthn platform passkeys (iCloud Keychain / Touch ID) **don't work** in this unbundled CLI. `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` returns `false`. WKWebView only offers them to apps signed with the restricted `com.apple.developer.web-browser.public-key-credential` entitlement, and that entitlement needs an embedded provisioning profile, which only a signed `.app` bundle can carry. This is how apps like Search.app do it. Workaround for now: at the Google/GitHub prompt, choose password, a phone prompt or a security code instead of a passkey. Wrapping webkit-cli in a signed `.app` would fix this, but WebKit would then key its storage by bundle ID instead of binary name, so existing accounts would need migrating.
- **No network interception**: you can't read or modify requests or responses. Use `fetch` inside `eval` when you need an API call with the page's cookies.
- **Synthetic events aren't trusted**: `.click()` and `dispatchEvent` produce `isTrusted: false` events. Most apps accept them. A few (some payment and captcha widgets) don't.
- **One command at a time per profile**: a long `wait` holds up other scripts on the same profile. `--timeout` includes time spent queued. Use `--account` for independent work.
- **kill -9 of a session**: session-only cookies are saved after every command and on stop/idle exit. A hard kill loses only those a page set after the last command returned. The next command starts a fresh session. Its tabs are gone, and old tab ids never match new ones.
- **Don't run commands while `auth` is open on the same profile.** `auth` stops that profile's session first, but a command started during sign-in would start a new session that may not see the new login until it restarts (`webkit-cli stop`).
- Cross-origin iframes aren't scriptable from the CLI. Popups are, as their own tabs.

## What's verified

On macOS 27.0. `scripts/check.sh` runs `doctor` (visible, rAF > 0) and the one-shot `text`/`eval`/`shot` against example.com, plus JS errors → exit 1, `--timeout` → exit 3, and `open` with `-` → exit 2.

**Session mode** was built by a dev/pm/qa team on the mesh. An independent QA agent ran all 14 scenarios in [docs/acceptance/session-mode.md](docs/acceptance/session-mode.md) against the built binary, using throwaway profiles. Everything is green on the final build.

- sign-in through a local fake OAuth redirect chain, and through a popup (the popup becomes a tab and closes itself)
- a session-only login cookie survives `stop`, `kill -9` and idle expiry
- `eval` that navigates fails at once, and the tab survives
- queued commands run in order and honour `--timeout`
- Ctrl-C'd or killed clients don't take the session down
- concurrent cold starts give exactly one session
- the idle exit fires between idle and idle+10%
- the socket is 0600 and the run dir 0700
- `text=` selectors, React-controlled inputs, and a public multi-page flow on github.com
- zero on-screen windows throughout
- the session log never contains cookies, keys or page text

QA fixed 10 bugs along the way.

`scripts/browser-use-apikey.sh` passes its dress rehearsal (`scripts/rehearse-browser-use.sh`) in both the redirect and the popup variant: exactly one key created, file mode 600, and the key doesn't appear in the script output or the session log.

**Not verified here:** the real browser-use + Google run needs aleks's account. GitHub sign-in and clicking Done by hand are also untested. A Google sign-in done by hand with v1 does work headless: the default profile loads `myaccount.google.com` signed in, while a throwaway profile gets the signed-out page.

## Upgrading from v1 (`auth <account> <url>`)

No migration is needed. The default profile is named `main`, so a login made with `webkit-cli auth main <url>` is what every command now uses. Other v1 accounts keep working with `--account <name>`.
