// A small C layer over WPE WebKit for the Swift Linux backend: GLib signal macros, varargs
// constructors and GAsyncReadyCallbacks don't import into Swift, so they live here behind plain
// C callbacks that carry an opaque `ctx` (the Swift tab).
#pragma once
#include <stdint.h>

typedef struct wk_tab wk_tab;
typedef struct wk_session wk_session;

enum { WK_LOAD_STARTED = 0, WK_LOAD_COMMITTED = 1, WK_LOAD_FINISHED = 2, WK_LOAD_FAILED = 3, WK_LOAD_CANCELLED = 4 };

typedef struct {
  void (*load)(void *ctx, int event, const char *error);          // error only for WK_LOAD_FAILED
  void (*status)(void *ctx, int http_status);                      // main-frame response
  void (*closed)(void *ctx);                                       // the page called window.close()
  void (*crashed)(void *ctx);                                      // web process terminated
  void (*popup)(void *ctx, wk_tab *popup);                         // window.open: adopt `popup` (wk_tab_set_ctx)
  void (*window_closed)(void *ctx);                                // a visible window's close button
} wk_callbacks;

typedef void (*wk_js_done)(void *req, const char *json, int undefined, const char *error);
typedef void (*wk_snap_done)(void *req, int width, int height, const char *error);
typedef void (*wk_cookies_done)(void *req, const char *lines, const char *error);
typedef void (*wk_done)(void *req, const char *error);

/// Connects the headless display once; returns an error message or NULL.
const char *wk_init(void);
/// Connects the Wayland display for visible windows (auth/show); returns an error message or NULL.
/// Needs $WAYLAND_DISPLAY (WPE has no X11 platform).
const char *wk_init_gui(void);
int wk_gui_available(void);
/// A visible window on the Wayland display, sharing `session` with the headless tabs.
wk_tab *wk_tab_new_visible(wk_session *session, const char *user_agent, const char *title, int width, int height);
void wk_tab_set_title(wk_tab *tab, const char *title);

/// data_dir/cache_dir NULL → ephemeral (in memory).
wk_session *wk_session_new(const char *data_dir, const char *cache_dir);

wk_tab *wk_tab_new(wk_session *session, const char *user_agent, int width, int height);
void wk_tab_set_ctx(wk_tab *tab, void *ctx, const wk_callbacks *callbacks);
void wk_tab_load(wk_tab *tab, const char *uri);
void wk_tab_load_html(wk_tab *tab, const char *html, const char *base_uri);
void wk_tab_stop(wk_tab *tab);
void wk_tab_close(wk_tab *tab);                                   // destroys the view; no callbacks after
const char *wk_tab_uri(wk_tab *tab);
const char *wk_tab_title(wk_tab *tab);
int wk_tab_is_loading(wk_tab *tab);
const char *wk_tab_user_agent(wk_tab *tab);

/// Runs `body` as an async function with one string argument named `args_name` holding `args_json`.
void wk_tab_call_js(wk_tab *tab, const char *body, const char *args_name, const char *args_json, void *req, wk_js_done done);
/// Visible viewport → PNG at `path` (mode set by the caller).
void wk_tab_snapshot_png(wk_tab *tab, const char *path, void *req, wk_snap_done done);

/// Session-only cookies as Set-Cookie-style lines "domain\tpath\tsecure\thttponly\tname=value".
void wk_session_session_cookies(wk_session *session, void *req, wk_cookies_done done);
void wk_session_add_cookie(wk_session *session, const char *domain, const char *path, int secure, int http_only,
                           const char *name, const char *value, void *req, wk_done done);

/// Runs the GLib main loop forever, draining Swift's main queue whenever `wake_fd` is readable
/// (libdispatch's main-queue eventfd) so @MainActor code and WebKit share the main thread.
void wk_main_loop_run(int wake_fd, void (*drain)(void));

/// SO_PEERCRED (needs _GNU_SOURCE, which Swift's Glibc import doesn't give us). 0 on success.
int wk_peer_uid(int fd, unsigned *uid);
