# session mode — acceptance criteria (beads-r293)

owner: webkit-pm · dev: webkit-cli · qa: webkit-qa · final run: personal (on aleks's account)

**the bar:** sign in with Google on cloud.browser-use.com → dashboard, then create an API key, using only `webkit-cli` commands and **zero windows**.

sign-off needs every part-A scenario green (QA runs them, logs attached to the bead) plus part B run once by personal.

## ground rules (apply to every scenario)

- build with `--scratch-path` outside `.build` if `pgrep -fl webkit-cli` shows aleks's `auth` running. Use `BIN=...`.
- never touch `main`, aleks's real profiles, or `~/Library/WebKit/com.officecommun.search`. QA uses `--account -` (one-shot only) or a named throwaway profile `qa-*` created for the test and `forget`-ed afterwards.
  - **dev decision:** no new flag. `~/.config/webkit-cli/accounts.json` is only a name → UUID map, so QA creates `qa-*` by adding an entry: `python3 -c 'import json,uuid,os;p=os.path.expanduser("~/.config/webkit-cli/accounts.json");d=json.load(open(p));d["qa-1"]=str(uuid.uuid4()).upper();json.dump(d,open(p,"w"),indent=2)'`, then `webkit-cli forget qa-1` afterwards (this also stops its session). The WebKit store is created on first use. Stop any running session before editing the file.
- **zero windows**, checked during every scenario: no window appears on screen, no Dock icon, and `CGWindowListCopyWindowInfo` shows no webkit-cli window with on-screen bounds (off-screen at -20000 is fine).
- **no secrets on stdout/stderr/log**: `type` never echoes its text; the daemon log (`~/.config/webkit-cli/run/<acct>.log`) contains no cookie values, no typed text, and no page content. grep the log for the typed marker string → must be 0 hits.
- exit codes: 0 ok, 1 error, 2 usage, 3 timeout. Error messages go to stderr and name the problem (tab id, selector, timeout, url).

## part A — QA runs for real

Local fixtures: QA writes a tiny local server (python/node, `127.0.0.1`, two ports = two "origins": `app` and `idp`) that fakes an OAuth flow. Keep it under `scripts/fixtures/` so it can be re-run.

| # | scenario | steps | pass |
|---|---|---|---|
| A1 | **redirect OAuth, session-only cookie** | `open app/signin` → `click 'text=Continue with IdP'` → idp login page → `type '#user' qa` → `click 'button[type=submit]'` → 302 to `app/callback?code=…` → app sets a cookie **with no expiry** → 302 to `app/dashboard` → `wait --until-url 'dashboard' --until-selector '#welcome'` → `text` | `text` shows "welcome qa". A second command (`goto <tab> app/dashboard`) is still signed in. After `stop`, a new `open app/dashboard` in the same profile is **still signed in** (session cookie restored from side-car). |
| A2 | **popup OAuth** | `open app/signin-popup` → `click 'text=Sign in'` does `window.open(idp/login)` → `tabs` lists a new tab with `opener` = the first → `type`/`click` in the popup tab → idp calls `window.opener.postMessage` and `window.close()` → `wait <first tab> --until-selector '#welcome'` | popup shows up in `tabs` with its own id; after it closes itself it's gone from `tabs` (or marked closed); the opener gets the message and reaches the dashboard. Nothing appears on screen. |
| A3 | **cross-document nav mid-command** | (a) `click` a link that navigates to a slow page (server delays 2s) → (b) `eval` a script that triggers navigation then keeps running (`location.href=…; await sleep(5000); return 1`) | (a) `click` returns after the new page loads (with the default `--wait 1`), `text` shows the new page. (b) `eval` fails clearly (exit 1, message says the page navigated), **the tab survives** and `text <tab>` shows the new page. No hang past `--timeout`. |
| A4 | **wait timeout** | `wait <tab> --until-url 'never' --timeout 3` | exit 3 within ~3–4s, stderr shows the current url. Tab still usable afterwards. Invalid regex → exit 2. |
| A5 | **idle expiry mid-flow** | start session with `--idle 5` → `open` → sleep 10 → `text <tab>` | the daemon is gone (no process, no socket). The error names the missing tab and says sessions expire when idle — exit 1, not a hang. The next `open` starts a fresh session. A command running longer than idle (`wait --timeout 20` with `--idle 5`) is **not** killed mid-command. |
| A6 | **two clients, one daemon** | two shells at once: shell 1 `wait t1 --until-selector '#late' --timeout 30`, shell 2 `open`, `text`, `tabs` on the same profile | exactly one daemon pid for the profile (`pgrep`); shell 2 isn't blocked by shell 1's wait; both get correct results. 5 parallel `open`s → 5 distinct tab ids, one daemon. Two parallel first commands (cold start race) → still one daemon. |
| A7 | **daemon kill -9 → recovery** | `open` → `kill -9 <daemon pid>` → `text t1` → `open example.com` | `text t1` fails clearly (tab gone), exit 1, no hang. `open` starts a new daemon (stale socket/lock handled) and works. Persistent cookies set before the kill survive. Session-only cookies: losing ones set since the last save is acceptable **if documented in the README's known gaps**. |
| A8 | **socket perms** | while a session runs: `stat -f %Lp` on `~/.config/webkit-cli`, `.../run`, the `.sock`, `.lock`, `.log` | dir 0700, run dir 0700, socket/lock/log 0600. The socket is never world-connectable, even for a moment: the run dir is already 0700 **before** `bind`. Another uid can't connect (check with `sudo -u nobody`, if QA has sudo; otherwise check the dir mode). |
| A9 | **doctor** | `webkit-cli doctor` | exit 0, reports `visible` and rAF > 0. Also: `eval <tab> 'return document.visibilityState'` in a session tab → `"visible"`, and a rAF count over 1s > 0. A session tab is no more throttled than a one-shot one. |
| A10 | **one-shot URL forms** | `text example.com`, `eval example.com 'return document.title'`, `shot example.com /tmp/x.png`, `./scripts/check.sh` | same output as v1, the PNG is 0600. After a one-shot, `tabs` shows no leftover temporary tab. |
| A11 | **throwaway `--account -`** | `text example.com --account -` ok; `open example.com --account -` | one-shot works and writes nothing to disk (no new store dir, no side-car). `open`/tab commands with `-` → exit 2 with a clear message (one-shot only). |
| A12 | **selector semantics** | `click 'text=Save'` on a page with "Save", "Save draft", and a hidden "Save" | clicks the visible exact "Save". Nothing matches → exit 1, stderr names the selector. `type` on a React-controlled input → React state updates (the fixture shows the value on the page). |
| A13 | **stop / close / tabs** | `close t1` → `tabs`; `stop` → `pgrep`; `stop` again | tab gone; daemon gone and cookies saved; a second `stop` exits 0 or clearly says there's no session (no crash). Bad tab id `x9` → exit 2. |
| A14 | **public multi-page smoke** | a real public site with multi-page nav (e.g. `open github.com/login` → `click 'text=Forgot password?'` → `wait --until-url 'password_reset'`) | works headless with no window. No credentials involved. |

## part B — real-account script (personal runs it)

Prereq, once, in a window: `webkit-cli auth google.com` (the only window in the whole story). Everything after this runs with zero windows.

Dev ships `scripts/browser-use-apikey.sh` that:

1. `open https://cloud.browser-use.com/signin` → tab
2. `click $tab 'text=Continue with Google'` (or whatever the button says). Handles both the redirect and the popup variant (checks `tabs` for a popup).
3. If Google shows an account chooser, `click` the account. If it shows a consent screen, `click 'text=Continue'`/`Allow`.
4. `wait $tab --until-url '^https://cloud\.browser-use\.com/(?!signin)' --timeout 120` → dashboard
5. go to the API keys page, `click` create, `type` a name (`webkit-cli-<date>`), confirm
6. read the key from the page and **write it straight to a 0600 file** (default `~/.config/webkit-cli/secrets/browser-use.key`, dir 0700, or a path from `$1`). The key **never** goes to stdout, stderr, the daemon log, or a screenshot the script leaves behind. The script prints only the file path + key prefix length or a fingerprint (e.g. `sha256 | head -c 8`).
7. `close` the tabs. `stop` is optional.

**pass (personal reports back):**
- dashboard reached, key file exists, `stat -f %Lp` = 600, and the key works: `curl` to a browser-use API endpoint with it returns 2xx (personal runs that, output not shared)
- no window appeared at any point after the initial `auth google.com`
- the script's full stdout+stderr and the daemon log contain no key and no cookie (personal greps for the first 8 chars of the key → 0 hits)
- on failure the script exits non-zero at the failing step, names it, and leaves a 0600 `shot` of that step for debugging

**known risks** (dev handles or documents): Google "verify it's you" / passkey prompt when there's no window → the script fails clearly, telling you to re-run `auth google.com`. The browser-use UI's text changes → selectors live in variables at the top of the script.

## sign-off

- [ ] A1–A14 green (QA, logs on beads-r293)
- [ ] README updated: session commands, idle, known gaps (kill -9 cookie loss if any, popup behaviour)
- [ ] B run by personal: pass
- [ ] webkit-pm signs off on beads-r293
