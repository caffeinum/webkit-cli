# snapshot — acceptance criteria

owner: webkit-pm · dev: webkit-cli · qa: webkit-qa · real run: personal

**why:** `text` flattens the page, so every time an agent needed to act it followed `text` with a custom `eval` to find the button. The agent's read should hand it the next action directly.

**the bar:** create an API key on browser-use, then on railway, with only `snapshot` / `click <ref>` / `type <ref>` / `wait`. No raw `eval` for finding or clicking. Reading the new key is part of the job: the snapshot shows its real value (aleks: fetching api keys is the whole use case).

prior art: Search `docs/headless.md` §2 (`/Users/aleks/.paw/repos/driceroland/Search/docs/headless.md` lines 42–97). Same ref idea, with two deliberate differences: our refs stay stable across snapshots (theirs expire on each snapshot), and we include text/headings by default (theirs are behind `--full`). `press`/`select`/`--enter` from there are out of scope here (`type` on a select covers select).

## surface

```
webkit-cli snapshot <tab|url> [--json] [--redact] [--max-chars N]
```

Default output is compact text, one element per line and indented by nesting:

```
# Browser Use — API keys
https://cloud.browser-use.com/settings?tab=api-keys
[nav]
  [e1] link "Dashboard" → /dashboard
  [e2] link "Settings" → /settings?tab=api-keys
[main]
  ## API keys
  [e3] button "Create API Key"
  Name  Created  Key
  default  2026-09-23  bu_8f2c…(real value)
[dialog "Create API key"]
  [e7] input text "Name" placeholder="Key 23/09/26…" value=""
  [e8] checkbox "Read only" [ ]
  [e9] select "Workspace" = "Personal" (options: Personal, Team)
  [e10] button "Create"
  [e11] button "Cancel" disabled
```

- **refs**: `e<n>`. `click`, `type` and `wait --until-selector` accept a ref (`e7`, or `ref=e7` spelled out) wherever they take a selector.
  - an element **keeps its ref** across snapshots for as long as it stays in the document. New elements get new numbers.
  - numbers are **never reused within a tab**, not even after a navigation. So an old ref can never point at a different element.
  - `wait --until-selector <ref>` with a stale ref fails fast with the same stale message (exit 1). It doesn't wait for the timeout.
  - a ref whose element is gone (removed, or the page navigated) → exit 1, `stale ref e7: page changed since the snapshot — take a new one`. Never a click on anything else.
  - **only what a person could reach** (SNAP-5, pm 2026-09-23): `click`/`type` (by ref, CSS or `text=`) refuse elements that are `inert`, inside an inert subtree, behind an open modal (`<dialog>` via showModal / `[aria-modal=true]`), or disabled. They exit 1 with the reason (`e12 is behind an open modal dialog`). While a modal is open, `snapshot` lists the dialog block and replaces the rest with one line: `[N elements behind the modal dialog]`.
  - `click <ref>` scrolls the element into view first. `type <ref>` on a `select` picks by option label, then by value. `click` on a checkbox toggles it.
- **what's included**: headings, landmarks, readable text (collapsed whitespace), and interactive elements (a, button, input, textarea, select, `[role=button|link|tab|menuitem|checkbox|radio|switch|combobox|option]`, `[contenteditable]`, `[onclick]`/`cursor:pointer` only if cheap). Each gets its accessible name (aria-labelledby → aria-label → `<label>` → text → alt → title → placeholder) and its state: disabled, checked, expanded, selected, required, value.
  - **visible only**: skips `display:none`, `visibility:hidden`, zero size, `aria-hidden`, `inert`. Elements scrolled out of view are still included.
  - open dialogs (`[role=dialog]`, `<dialog open>`) are listed as their own block, **first** when modal.
  - same-origin iframes and open shadow roots are walked, and their refs work. Cross-origin iframes show up as `[iframe cross-origin <origin>]` with no contents (later).
- **size**: `--max-chars` defaults to 8000. Past it, text is cut before interactive elements are, ending with `… truncated: N more elements, M chars`. The dialog block is never cut.
- **`--json`**: `{"title","url","truncated":bool,"nodes":[{"ref"?,"role","name","value"?,"state"?,"href"?,"children"?}]}`. Dev writes the schema in the README.
- **no masking by default** (aleks reversed an earlier draft: fetching api keys is the whole use case). Values and text are shown as they are. `input[type=password]` values are still **never** shown (`value=‹password›`). Aleks confirmed this on 2026-09-23.
- **`--redact` (opt-in)**: other input/textarea values and text nodes that look like secrets become `‹redacted len=N #<first 8 of sha256>›`. That covers known prefixes (`sk-`, `sk_live_`, `bu_`, `ghp_`, `github_pat_`, `xox[bp]-`, `AKIA`, `eyJ…` JWTs, railway-style tokens) and any run of ≥ 24 chars from `[A-Za-z0-9_\-+/=]` with mixed letter/digit classes. The hash lets an agent tell keys apart without seeing them. `--redact` covers **everything printed**: the title and URL lines, link `→ href`s (query strings, e.g. OAuth `code=`/`token=` params), values and text.
- webkit-cli itself never writes snapshot output to its daemon log. Where the output goes is the caller's job; the README says so under Security.
- **`text` is removed** (aleks: "they can drop `text`"). `text …` → exit 2 with stderr `text was removed — use \`snapshot\`, or \`eval 'return document.body.innerText'\` for raw text`. Help, README, `scripts/check.sh`, `scripts/browser-use-apikey.sh`, the rehearsal scripts and the other acceptance docs stop using it.
- works on a one-shot url (`snapshot <url>`) too, but refs are useless there (the tab is gone), so print a stderr note.

## part A — QA (fixture)

Fixture page `/snapshot` on the local server, containing: nav + headings, a hidden button, an `aria-hidden` link, a disabled button, a checkbox, a select, a same-origin iframe with a button, an open shadow root with a button, a `<dialog>` opened by a button, a table cell and a readonly input holding fake secrets (`bu_` + 40 random, an `sk-…`, a JWT, a plain 32-char mixed token, and a *non-secret* long word like `internationalization`), a password input with a prefilled value, a list of 2000 items (for the budget), and a React-controlled input that re-renders.

| # | scenario | pass |
|---|---|---|
| S1 | **basic shape** | title + url on top, headings/landmarks present. Hidden, `aria-hidden` and `inert` elements absent. Disabled marked. Checkbox state and select value right. Links show the resolved `→ path`. |
| S2 | **act by ref** | snapshot → `click <dialog-open ref>` → snapshot shows the dialog block first, with its input ref → `type <ref> hello` → `click <submit ref>` → the fixture receives `hello`. No `eval` used. The React input's state updates. |
| S3 | **ref stability** | two snapshots in a row with no changes → identical refs. The DOM adds an element above → existing elements keep their refs and the new one gets a new number. |
| S4 | **stale ref** | snapshot → navigate (or remove the element) → `click <old ref>` → exit 1 with the stale message. The fixture log shows no click landed. After navigating, the new page's refs never repeat numbers from the old page. |
| S5 | **iframe + shadow** | the same-origin iframe button and the shadow-root button are listed, and clicking their refs works. A cross-origin iframe shows as a placeholder line. |
| S6 | **secrets: shown by default, `--redact` opt-in** | default: every fake secret appears in full and verbatim (a grep for each → hit). The password is never shown, with or without flags. `--redact`: every fake secret is masked with len + hash, `internationalization` is **not** masked, a grep for each secret → 0 hits, different keys → different hashes, the same key → the same hash. Daemon log: 0 hits for any secret in both modes. `--redact` also masks a secret put in the page URL's query string and in a link href. |
| S7 | **budget** | default output ≤ 8000 chars on the 2000-item page, ends with the truncation line, and the dialog + first interactive elements are still present. `--max-chars 100000` returns everything. |
| S8 | **--json** | valid JSON that matches the README schema **exactly** (fix the code or the README, whichever is wrong, but they must agree; groups/landmarks and iframe placeholders included), same refs as the text form, `--redact` applied the same way. |
| S9 | **speed** | on an already-loaded tab (time only the `snapshot` call, not `open`), the fixture page takes < 500 ms and a real public page (e.g. github.com/login) < 1.5 s. |
| S10 | **regressions + `text` removal** | session-mode A1–A14 and escalate E1–E12 still green, with `text` steps swapped for `snapshot`. `text <tab>` and `text <url>` → exit 2 with the migration message. `rg -w 'text' --glob '!docs/acceptance/**'` over scripts/README/help finds no remaining calls to the command. `check.sh` passes. |
| S11 | **public site** | on a public page with a real form (e.g. github.com/login, no submit): snapshot lists the username/password inputs and the sign-in button with sensible names. `type` a fake value into the username ref → a snapshot shows that value. Nothing gets submitted. |
| S12 | **unreachable elements** | with the modal open: a background ref, `text=Victim button` and a CSS selector for a background button → all exit 1 with a "behind an open modal" message, and the fixture's `/hit/log` registers nothing. The fixture's inert button and a disabled button → exit 1, nothing registered. Snapshot with the modal open shows the dialog + the `[N elements behind…]` line and no background refs. Close the modal → the background refs are usable again (same numbers). |

## part B — real (personal)

1. **browser-use**: `open` api-keys → snapshot → click the create ref → snapshot shows the dialog input ref → `type` a name → click the confirm ref → snapshot shows the new key **in full**. The agent saves it from the snapshot to a 0600 file → API 200 with it. Zero `eval` calls in the whole flow.
2. **railway**: the same on railway.com/account/tokens. Personal revokes the test token afterwards.
3. Pass = both flows done with only snapshot/click/type/wait, the key read from a snapshot works, the daemon log has 0 hits for the key's first 8 chars, and zero windows.

## sign-off

- [x] S1–S12 green (QA, cc6e763)
- [x] README: snapshot, the ref rules, `--redact`, the JSON schema, and a Security note that snapshot prints secrets as they are; `text` removed everywhere (cc6e763)
- [ ] B1 + B2 by personal
- [ ] webkit-pm signs off
