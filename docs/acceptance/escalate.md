# escalate to a human — acceptance criteria (beads-ivam)

owner: webkit-pm · dev: webkit-cli · qa: webkit-qa · final run: personal / aleks

**the ask (aleks):** "maybe agent can pop up the window when input from user is needed?"

**the bar:** a headless flow that hits a human-only step (Google "confirm it's you", 2FA, captcha, consent) shows **that same live tab** in a window. The user finishes the step and the tab goes back to headless, where the script carries on. No reload, no new tab, no second login.

**invariant kept from session mode:** without `show` or `--escalate`, no window ever appears. Escalation is always opt-in.

## surface (proposed, dev may adjust names, and records any change here)

- `webkit-cli show <tab> [--reason "<text>"]` moves the live web view into a normal window with the auth bar: the reason (default "Finish this step, then click Done."), the live URL, and a **Done** button. It returns right away with `{"tab","shown":true}`.
- `webkit-cli hide <tab>` puts the view back off-screen and headless. Done, ⌘W and closing the window all do the same as `hide`. **None of them close the tab.**
- `webkit-cli wait <tab> --until-hidden` waits until the user clicks Done. It combines with `--until-url` and `--until-selector`, where the first condition met wins.
- `--escalate` on `click`, `wait` and `goto`: when the tab lands on a known challenge page, the command shows the tab with a reason. It then waits until the challenge is gone (the URL no longer matches the challenge patterns and the original `--until-*` holds) or Done is clicked, hides the tab, and returns normally. A stderr line `webkit-cli: needs you: <reason> (tab <id>)` goes out when the window opens.
- `--human-timeout <sec>` (default 600) is how long an escalation waits for the human. When it runs out → exit 3 with stderr saying no one finished the step. `--timeout` doesn't include time spent waiting on the human.
- Challenge detection is a pattern list in one place (e.g. `accounts.google.com/v3/signin/challenge`, `/signin/v2/challenge`, pages with a visible reCAPTCHA/hCaptcha/Turnstile iframe). Scripts can extend it with `--challenge-url <regex>` (repeatable).
- For scripts: `browser-use-apikey.sh` passes `--escalate` when `ESCALATE=1`. It stays off by default, so an unattended run still fails fast with the right fix.

## part A — QA runs for real

Fixture: extend `scripts/fixtures/oauth_server.py` with `/challenge` (a fake "confirm it's you" page: a `#code` input + Continue, then 302 back into the flow) and a switch that makes the idp send `/login` → `/challenge` before `/callback`. The fixture's challenge URL has to match through `--challenge-url`, and no fixture URL may match the built-in Google patterns.

QA drives the human part with an AX/CGEvent helper (or `osascript`) that types into the **visible** window and clicks Done. Doing it via `eval` doesn't count as a human.

| # | scenario | pass |
|---|---|---|
| E1 | **show/hide keeps state** | `open` → `eval 'window.__m=42'` → `show` → window visible, on-screen, key window, URL bar right → `hide` → `eval 'return window.__m'` = 42. No reload (fixture log: 1 GET). Same tab id throughout. |
| E2 | **headless after hide** | after `show`/`hide`: `visibilityState` = `"visible"`, rAF > 0 over 1s, no on-screen webkit-cli window (the windows.swift helper → 0), no Dock icon left behind. |
| E3 | **human completes, script carries on** | `click $t 'text=Continue with IdP' --escalate --challenge-url '/challenge'` → window opens, stderr "needs you" line → helper types code + submits in the window → window closes by itself → command exits 0 → `wait --until-selector '#welcome'` → "welcome qa". Fixture log: exactly one /callback. |
| E4 | **Done / ⌘W / close button** | each of the three hides the tab and doesn't close it (`tabs` still lists it, `text` works). `wait --until-hidden` returns 0 on each. |
| E5 | **nobody comes** | `--escalate --human-timeout 5` on the challenge → exit 3 within ~5–7s, stderr says a human step wasn't finished. The window is hidden again and the tab is still alive. |
| E6 | **opt-in only** | the same challenge flow without `--escalate` → no window, ever (helper polls every 0.5s). `wait` times out or the script fails with the fix message. All session-mode checks (A1–A14) still green. |
| E7 | **popup tab** | the popup variant with the challenge inside the popup → the **popup** tab is shown, not its opener. After the popup finishes and closes itself, the window goes away and the opener reaches the dashboard. |
| E8 | **queue + idle** | while shown, `tabs` and `hide` from another shell aren't stuck behind a blocking `--escalate`/`wait --until-hidden` (either they skip the queue, or dev documents that Done is the only way out and E4 covers it; **dev decides, records it here**). The idle timer never fires while any tab is shown. |
| E9 | **kill -9 while shown** | the window disappears with the process. The next command recovers as in A7. |
| E10 | **no GUI session** | over ssh with no Aqua session (or `launchctl asuser` absent), `show`/`--escalate` → exit 1, "can't show a window: no GUI session". It doesn't hang. |
| E11 | **throwaway / one-shot** | `show` with `--account -` → exit 2. One-shot url forms reject `--escalate` → exit 2. |
| E12 | **no leaks** | text typed by the human in the window never reaches stdout, stderr or the daemon log (grep for the marker → 0). `shot` taken while shown is still 0600. |

## part B — real (aleks / personal)

Escalation can only be proven when Google actually challenges, and we can't trigger that on demand. So:

1. **opportunistic:** run `ESCALATE=1 scripts/browser-use-apikey.sh`. If Google challenges, the pass is: a window pops up showing the Google page, aleks clears it, the window goes away, and the script finishes with exit 0, key 0600, API 200, 0 leak hits.
2. **forced stand-in:** `show` on a live tab of the signed-in browser-use dashboard. Aleks clicks around, then Done, and the script reads the dashboard afterwards. This proves the reparenting on a real React app. The Google challenge part is covered by E3's fixture.

Pass = 2 done, and 1 done once whenever a challenge happens (recorded here with the date).

## open questions for dev

- does reparenting a `WKWebView` between the off-screen window and the visible one keep its process, layer tree and occlusion state? If not, what's the fallback (move the window itself on-screen, i.e. same NSWindow at a visible frame + restyle)? Moving one window is probably simpler.
- activation policy: the daemon is `.accessory`. Showing a window needs it to come to the front for keyboard focus (`NSApp.activate`), then go back.
- notification when the window opens (optional nice-to-have): a `say`/UserNotification. Leave it off by default.

## sign-off

- [ ] E1–E12 green (QA)
- [ ] README: show/hide/--escalate, invariant still stated
- [ ] B2 by aleks/personal; B1 recorded when it happens
- [ ] webkit-pm signs off on beads-ivam
