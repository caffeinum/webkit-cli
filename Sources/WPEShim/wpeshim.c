#ifdef __linux__
#define _GNU_SOURCE
#include <sys/socket.h>
#include "wpeshim.h"
#include <wpe/webkit.h>
#include <wpe/headless/wpe-headless.h>
#include <cairo.h>
#include <string.h>
#include <glib-unix.h>

struct wk_session { WebKitNetworkSession *session; };
struct wk_tab {
  WebKitWebView *view;
  void *ctx;
  wk_callbacks cb;
  char *uri, *title;
};

static WPEDisplay *display;

const char *wk_init(void) {
  if (display) return NULL;
  display = wpe_display_headless_new();
  if (!display) return "wpe_display_headless_new() returned NULL";
  GError *error = NULL;
  if (!wpe_display_connect(display, &error)) {
    static char msg[512];
    snprintf(msg, sizeof msg, "cannot connect the headless display: %s", error ? error->message : "?");
    return msg;
  }
  return NULL;
}

wk_session *wk_session_new(const char *data_dir, const char *cache_dir) {
  wk_session *s = g_new0(wk_session, 1);
  s->session = data_dir ? webkit_network_session_new(data_dir, cache_dir) : webkit_network_session_new_ephemeral();
  WebKitCookieManager *cookies = webkit_network_session_get_cookie_manager(s->session);
  if (data_dir) {
    char *db = g_build_filename(data_dir, "cookies.sqlite", NULL);
    webkit_cookie_manager_set_persistent_storage(cookies, db, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
    g_free(db);
  }
  webkit_cookie_manager_set_accept_policy(cookies, WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY);
  return s;
}

// --- signals

static void on_load_changed(WebKitWebView *v, WebKitLoadEvent e, wk_tab *t) {
  if (!t->cb.load) return;
  if (e == WEBKIT_LOAD_STARTED) t->cb.load(t->ctx, WK_LOAD_STARTED, NULL);
  else if (e == WEBKIT_LOAD_COMMITTED) t->cb.load(t->ctx, WK_LOAD_COMMITTED, NULL);
  else if (e == WEBKIT_LOAD_FINISHED) t->cb.load(t->ctx, WK_LOAD_FINISHED, NULL);
}

static gboolean on_load_failed(WebKitWebView *v, WebKitLoadEvent e, char *uri, GError *error, wk_tab *t) {
  if (!t->cb.load) return FALSE;
  // superseded by a redirect or a newer navigation
  if (g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED) ||
      g_error_matches(error, WEBKIT_POLICY_ERROR, WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE)) {
    t->cb.load(t->ctx, WK_LOAD_CANCELLED, NULL);
    return FALSE;
  }
  char *msg = g_strdup_printf("load failed for %s: %s (%s %d)", uri, error->message, g_quark_to_string(error->domain), error->code);
  t->cb.load(t->ctx, WK_LOAD_FAILED, msg);
  g_free(msg);
  return FALSE;
}

static gboolean on_decide_policy(WebKitWebView *v, WebKitPolicyDecision *d, WebKitPolicyDecisionType type, wk_tab *t) {
  if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
    WebKitResponsePolicyDecision *r = WEBKIT_RESPONSE_POLICY_DECISION(d);
    if (webkit_response_policy_decision_is_main_frame_main_resource(r) && t->cb.status) {
      t->cb.status(t->ctx, (int)webkit_uri_response_get_status_code(webkit_response_policy_decision_get_response(r)));
    }
  }
  return FALSE; // default handling
}

static void on_close(WebKitWebView *v, wk_tab *t) { if (t->cb.closed) t->cb.closed(t->ctx); }
static void on_crash(WebKitWebView *v, WebKitWebProcessTerminationReason r, wk_tab *t) { if (t->cb.crashed) t->cb.crashed(t->ctx); }

static wk_tab *wrap(WebKitWebView *view, int width, int height);

static WebKitWebView *on_create(WebKitWebView *v, WebKitNavigationAction *a, wk_tab *t) {
  WebKitWebView *popup = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "related-view", v, "display", display, NULL));
  webkit_settings_set_user_agent(webkit_web_view_get_settings(popup), webkit_settings_get_user_agent(webkit_web_view_get_settings(v)));
  wk_tab *child = wrap(popup, 1280, 800);
  if (t->cb.popup) t->cb.popup(t->ctx, child);
  return popup;
}

static wk_tab *wrap(WebKitWebView *view, int width, int height) {
  wk_tab *t = g_new0(wk_tab, 1);
  t->view = view;
  g_object_ref_sink(view);
  WPEView *wpe = webkit_web_view_get_wpe_view(view);
  if (wpe) {
    WPEToplevel *top = wpe_view_get_toplevel(wpe);
    if (top) wpe_toplevel_resize(top, width, height);
    wpe_view_set_visible(wpe, TRUE);
    wpe_view_focus_in(wpe);
  }
  g_signal_connect(view, "load-changed", G_CALLBACK(on_load_changed), t);
  g_signal_connect(view, "load-failed", G_CALLBACK(on_load_failed), t);
  g_signal_connect(view, "decide-policy", G_CALLBACK(on_decide_policy), t);
  g_signal_connect(view, "close", G_CALLBACK(on_close), t);
  g_signal_connect(view, "web-process-terminated", G_CALLBACK(on_crash), t);
  g_signal_connect(view, "create", G_CALLBACK(on_create), t);
  return t;
}

wk_tab *wk_tab_new(wk_session *s, const char *user_agent, int width, int height) {
  WebKitWebView *view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display, "network-session", s->session, NULL));
  WebKitSettings *settings = webkit_web_view_get_settings(view);
  webkit_settings_set_javascript_can_open_windows_automatically(settings, TRUE);
  if (user_agent) webkit_settings_set_user_agent(settings, user_agent);
  return wrap(view, width, height);
}

void wk_tab_set_ctx(wk_tab *t, void *ctx, const wk_callbacks *cb) { t->ctx = ctx; t->cb = *cb; }
void wk_tab_load(wk_tab *t, const char *uri) { webkit_web_view_load_uri(t->view, uri); }
void wk_tab_load_html(wk_tab *t, const char *html, const char *base) { webkit_web_view_load_html(t->view, html, base); }
void wk_tab_stop(wk_tab *t) { webkit_web_view_stop_loading(t->view); }

void wk_tab_close(wk_tab *t) {
  g_signal_handlers_disconnect_by_data(t->view, t);
  memset(&t->cb, 0, sizeof t->cb);
  webkit_web_view_try_close(t->view);
  g_object_unref(t->view);
  g_free(t->uri); g_free(t->title);
  g_free(t);
}

const char *wk_tab_uri(wk_tab *t) { return webkit_web_view_get_uri(t->view); }
const char *wk_tab_title(wk_tab *t) { return webkit_web_view_get_title(t->view); }
int wk_tab_is_loading(wk_tab *t) { return webkit_web_view_is_loading(t->view); }
const char *wk_tab_user_agent(wk_tab *t) { return webkit_settings_get_user_agent(webkit_web_view_get_settings(t->view)); }

// --- javascript

typedef struct { void *req; wk_js_done done; } js_call;

static void js_finished(GObject *source, GAsyncResult *res, gpointer data) {
  js_call *c = data;
  GError *error = NULL;
  JSCValue *value = webkit_web_view_call_async_javascript_function_finish(WEBKIT_WEB_VIEW(source), res, &error);
  if (!value) {
    c->done(c->req, NULL, 0, error ? error->message : "javascript failed");
    if (error) g_error_free(error);
  } else if (jsc_value_is_undefined(value)) {
    c->done(c->req, NULL, 1, NULL);
    g_object_unref(value);
  } else {
    char *json = jsc_value_to_json(value, 0);
    c->done(c->req, json ? json : "null", 0, NULL);
    g_free(json);
    g_object_unref(value);
  }
  g_free(c);
}

void wk_tab_call_js(wk_tab *t, const char *body, const char *args_name, const char *args_json, void *req, wk_js_done done) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&b, "{sv}", args_name, g_variant_new_string(args_json));
  js_call *c = g_new0(js_call, 1);
  c->req = req; c->done = done;
  webkit_web_view_call_async_javascript_function(t->view, body, -1, g_variant_builder_end(&b), NULL, NULL, NULL, js_finished, c);
}

// --- snapshots

typedef struct { void *req; wk_snap_done done; char *path; } snap_call;

static void snap_finished(GObject *source, GAsyncResult *res, gpointer data) {
  snap_call *c = data;
  GError *error = NULL;
  WebKitImage *image = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(source), res, &error);
  if (!image) {
    c->done(c->req, 0, 0, error ? error->message : "snapshot failed");
    if (error) g_error_free(error);
  } else {
    int w = (int)webkit_image_get_width(image), h = (int)webkit_image_get_height(image), stride = (int)webkit_image_get_stride(image);
    GBytes *bytes = webkit_image_as_bytes(image);
    gsize len = 0;
    const unsigned char *px = g_bytes_get_data(bytes, &len);
    cairo_surface_t *surface = cairo_image_surface_create_for_data((unsigned char *)px, CAIRO_FORMAT_ARGB32, w, h, stride);
    cairo_status_t st = cairo_surface_write_to_png(surface, c->path);
    cairo_surface_destroy(surface);
    c->done(c->req, w, h, st == CAIRO_STATUS_SUCCESS ? NULL : cairo_status_to_string(st));
    g_object_unref(image);
  }
  g_free(c->path);
  g_free(c);
}

void wk_tab_snapshot_png(wk_tab *t, const char *path, void *req, wk_snap_done done) {
  snap_call *c = g_new0(snap_call, 1);
  c->req = req; c->done = done; c->path = g_strdup(path);
  webkit_web_view_get_snapshot(t->view, WEBKIT_SNAPSHOT_REGION_VISIBLE, WEBKIT_SNAPSHOT_OPTIONS_NONE, NULL, snap_finished, c);
}

// --- cookies

typedef struct { void *req; wk_cookies_done done; } cookies_call;

static void cookies_finished(GObject *source, GAsyncResult *res, gpointer data) {
  cookies_call *c = data;
  GError *error = NULL;
  GList *list = webkit_cookie_manager_get_all_cookies_finish(WEBKIT_COOKIE_MANAGER(source), res, &error);
  if (error) {
    c->done(c->req, NULL, error->message);
    g_error_free(error);
  } else {
    GString *out = g_string_new(NULL);
    for (GList *l = list; l; l = l->next) {
      SoupCookie *k = l->data;
      if (soup_cookie_get_expires(k)) continue; // persistent: WebKit keeps those itself
      g_string_append_printf(out, "%s\t%s\t%d\t%d\t%s\t%s\n", soup_cookie_get_domain(k), soup_cookie_get_path(k),
                             soup_cookie_get_secure(k), soup_cookie_get_http_only(k), soup_cookie_get_name(k), soup_cookie_get_value(k));
    }
    g_list_free_full(list, (GDestroyNotify)soup_cookie_free);
    c->done(c->req, out->str, NULL);
    g_string_free(out, TRUE);
  }
  g_free(c);
}

void wk_session_session_cookies(wk_session *s, void *req, wk_cookies_done done) {
  cookies_call *c = g_new0(cookies_call, 1);
  c->req = req; c->done = done;
  webkit_cookie_manager_get_all_cookies(webkit_network_session_get_cookie_manager(s->session), NULL, cookies_finished, c);
}

typedef struct { void *req; wk_done done; } done_call;

static void cookie_added(GObject *source, GAsyncResult *res, gpointer data) {
  done_call *c = data;
  GError *error = NULL;
  webkit_cookie_manager_add_cookie_finish(WEBKIT_COOKIE_MANAGER(source), res, &error);
  c->done(c->req, error ? error->message : NULL);
  if (error) g_error_free(error);
  g_free(c);
}

void wk_session_add_cookie(wk_session *s, const char *domain, const char *path, int secure, int http_only,
                           const char *name, const char *value, void *req, wk_done done) {
  SoupCookie *k = soup_cookie_new(name, value, domain, path, -1);
  soup_cookie_set_secure(k, secure);
  soup_cookie_set_http_only(k, http_only);
  done_call *c = g_new0(done_call, 1);
  c->req = req; c->done = done;
  webkit_cookie_manager_add_cookie(webkit_network_session_get_cookie_manager(s->session), k, NULL, cookie_added, c);
  soup_cookie_free(k);
}
static gboolean main_queue_ready(gint fd, GIOCondition condition, gpointer drain) {
  ((void (*)(void))drain)();
  return G_SOURCE_CONTINUE;
}

void wk_main_loop_run(int wake_fd, void (*drain)(void)) {
  g_unix_fd_add(wake_fd, G_IO_IN, main_queue_ready, (gpointer)drain);
  drain();
  g_main_loop_run(g_main_loop_new(NULL, FALSE));
}
int wk_peer_uid(int fd, unsigned *uid) {
  struct ucred cred;
  socklen_t len = sizeof cred;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
  *uid = cred.uid;
  return 0;
}
#endif
