# webkit-cli on Linux: proposal (beads-cdfg, phase 1)

Goal: the same CLI, session daemon and `snapshot`/`click`/`type`/`eval`/`shot` semantics as on macOS, still in Swift, on a Linux WebKit, tested in an e2b sandbox. The mac backend stays untouched.

Tags on claims: **[RAN]** means run in docker on this Mac (arm64), **[SRC]** means read from WebKit source or Debian packages, **[UNC]** means not verified yet.

## Recommendation

**WPE WebKit 2.54 with the WPEPlatform headless display, on Debian sid/forky.** WebKitGTK 6.0 under weston-headless is the fallback for Ubuntu. The same C API covers both.

| | WPE 2.54 (WPEPlatform headless) | WPE 2.48 (legacy libwpe + fdo) | WebKitGTK 6.0 (2.52) |
|---|---|---|---|
| where | Debian sid/forky: 2.54.0 **[RAN]** | Debian trixie **[RAN]** | Ubuntu 24.04+, Debian trixie **[RAN]** |
| display needed | **none**: `wpe_display_headless_new()` **[RAN]** | EGL/fdo exportable, you read buffers yourself | yes: Xvfb or `weston --backend=headless` |
| `webkit_web_view_get_snapshot` | **yes** (`WebKitImage`) **[RAN]** | **no** **[RAN]** | yes (`GdkTexture`) |
| per-profile dirs | `webkit_network_session_new(data, cache)` **[RAN]** | same **[RAN]** | same (6.0 API only, not 4.1) |
| Ubuntu | not packaged at all **[RAN]** | not packaged | packaged |

- **Why WPE 2.54:** it's the only option with a real headless display (no X/Wayland, no GPU needed) *and* a snapshot API.
  - Its headless view maps itself, is `visible` by default, and ticks frames at a fixed 60 Hz **[SRC]**. So the macOS occlusion hack (off-screen window + private SPI) shouldn't be needed. `doctor` will prove it in the spike **[UNC]**.
  - 2.48 on trixie would mean hand-rolling buffer export for screenshots. Not worth it.
- **Legacy path to avoid:** libwpe + WPEBackend-fdo is being deprecated as of 2.54 **[SRC]**.

## Toolchain [RAN]

- **Build image:** `swift:6.4-trixie` (official, 1.4 GB compressed), with sid's `libwpewebkit-2.0-dev` pinned in via apt.
  - A probe using a SwiftPM `systemLibrary` target (`pkgConfig: "wpe-webkit-2.0 wpe-platform-headless-2.0"`) builds in 5 s.
  - At runtime it creates a headless display and a network session with no GPU or display server.
- **Runtime size:** `libwpewebkit-2.0-1` plus deps add about **590 MB** to a `debian:sid` base, plus the Swift runtime libs (`swift:6.4-trixie-slim` is 118 MB).
- **e2b:** use a custom template built from a Dockerfile (Swift + WPE baked in). Installing at sandbox start would take minutes.
  - `e2b` CLI here is logged in to aleks's account, so phase 2 needs no new key. Sandboxes cost money, so I'm asking for a go-ahead.

## What ports

About 55% of the Swift ports as-is.

| file | status |
|---|---|
| `Accounts.swift`, `Errors.swift`, `CLI.swift`, `Snapshot.swift` (all the snapshot/click/type JS) | portable |
| `Session.swift` (Engine, refs, escalate logic) | portable once it talks to a `Tab` protocol instead of `Browser` |
| `Daemon.swift` | mostly portable. Swaps: `Darwin`→`Glibc`; `SO_NOSIGPIPE` → `MSG_NOSIGNAL` + ignored SIGPIPE; `getpeereid` → `SO_PEERCRED`; `CGSession` checks → `$WAYLAND_DISPLAY`/`$DISPLAY` |
| `Browser.swift`, `AuthBar.swift`, `SessionCookies.swift`, the AppKit bits of `Commands.swift`/`main.swift` | mac backend, unchanged |

Shape of the change: extract a small `Tab` protocol from `Browser`:
- `load(url)`, `callJS(body, args)`, `url`/`title`/`isLoading`/`lastStatus`/`lastFailure`
- `snapshotPNG()`, `close()`, `onPopup`/`onPageClose`
- `show`/`hide` (mac only for now)
- cookies: `allCookies`/`add`

Then `MacTab` (today's `Browser`) and `WPETab` implement it. `#if os(macOS)` / `#if os(Linux)` pick the backend and the main loop.

The Linux backend in Swift over the C API:

| need | WPE / GLib API |
|---|---|
| load / events | `webkit_web_view_load_uri`, `load-changed`, `load-failed`, `decide-policy` (for HTTP status), `web-process-terminated` |
| JS | `webkit_web_view_call_async_javascript_function` (awaits promises), result → `jsc_value_to_json`. Args go in as **one JSON string**, parsed in the page, which avoids variadic `GVariant` construction in Swift |
| popups | the `create` signal → a new `WebKitWebView` with `related-view` → a new tab id |
| profiles | `webkit_network_session_new("~/.local/share/webkit-cli/<uuid>", …/cache)`. **No binary-name keying on Linux**, so a renamed binary is fine there |
| session-only cookies | `webkit_cookie_manager_get_all_cookies` → `SoupCookie`s without `expires` → our 0600 side-car, restored with `add_cookie`. Same design as mac |
| screenshots | `webkit_web_view_get_snapshot` → `WebKitImage` (raw pixels) → PNG via cairo (`cairo_image_surface_create_for_data` + `write_to_png`; cairo is already a WPE dependency) |
| user agent | **keep WPE's default UA.** WebKit's built-in quirks already send an unbranded, Safari-like UA to `accounts.google.com` **[SRC]**. A custom UA could bypass those quirks. Google sign-in itself is **[UNC]** until it's tried |

## Risks, in order

1. **Main loop:** WebKit needs a GLib main loop, while our daemon/async code uses Swift's `MainActor` (Dispatch main queue). On Linux they don't share a loop **[UNC]**. Plan: run `g_main_loop_run` on the main thread and drain Swift's main queue from a GLib source (or pump GLib from a dispatch timer as a fallback). **The spike settles this first.**
2. **Swift ↔ GLib ergonomics:** `g_signal_connect` and `G_CALLBACK` are macros, `GAsyncReadyCallback` can't capture, and the `g_variant_new`/`g_object_new` varargs don't import. Handled with `g_signal_connect_data` + `@convention(c)` trampolines + `Unmanaged` boxes, and a few C helpers in the module's shim header. It's tedious, not blocking; SwiftGtk-style projects do the same.
3. **Distro:** WPE 2.54 only on Debian sid/forky today. Trixie backports or Ubuntu would mean the WebKitGTK + weston-headless backend (same API, plus a display).
4. **Signing in on a server:** `auth` needs a person and a screen. For e2b, the realistic path is to sign in on the Mac, then `webkit-cli export-profile` → an encrypted/0600 cookie bundle → `import-profile` in the sandbox. Cookies are credentials, so this needs aleks's OK. `auth` on a Linux desktop via WPE's Wayland platform comes later.
5. **Not ported initially:** `show`/`--escalate` (no screen in e2b) → clear "no GUI session" errors. Passkeys (not available in WPE either).

## Rejected: WebDriver (WPEWebDriver / cog) instead of our daemon

It's packaged and gives screenshots and async scripts for free. But it needs one browser process per session, and profile directories only through launcher flags. Its cookie API is scoped to the current domain, so it can't dump every session-only cookie, which e2b-style logins need. And it would be a second architecture next to the mac one. Our daemon keeps the CLI identical on both OSes.

## Phase 2: the spike (≈ 1 day, in e2b)

1. An e2b template from a Dockerfile: `swift:6.4-trixie` + sid `libwpewebkit-2.0-dev` + cairo.
2. On branch `linux`: the `Tab` protocol refactor (mac stays green: `check.sh`), then `WPETab` + a GLib main loop.
3. **Done when**, headless in the sandbox:
   - `webkit-cli open https://example.com` → tab id
   - `snapshot <tab>` shows the refs
   - `shot <tab> out.png` produces a real PNG
   - `doctor` reports `visible` with rAF > 0
4. Then report back before the rest (auth/cookie import, escalate stubs, packaging).
