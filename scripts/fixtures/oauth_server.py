#!/usr/bin/env python3
"""Fake OAuth fixture for session-mode and escalate QA (docs/acceptance/session-mode.md, escalate.md).

Two origins on 127.0.0.1: app (default :8765) and idp (default :8766).
Usage: scripts/fixtures/oauth_server.py [app_port] [idp_port]
?challenge=1 on /signin or /signin-popup makes the idp insert a fake "confirm it's you" step
(idp /challenge: #code + Continue) between login and callback.
Request log (method, path, cookie *names* only) → stderr.
"""
import http.server, json, secrets, sys, threading, time, urllib.parse as up, urllib.request, os

APP_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
IDP_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8766
APP = f"http://127.0.0.1:{APP_PORT}"
IDP = f"http://127.0.0.1:{IDP_PORT}"
REACT = {
    "react.js": "https://cdn.jsdelivr.net/npm/react@18.3.1/umd/react.production.min.js",
    "react-dom.js": "https://cdn.jsdelivr.net/npm/react-dom@18.3.1/umd/react-dom.production.min.js",
}
CACHE = os.path.join(os.environ.get("TMPDIR", "/tmp"), "webkit-cli-fixture-react")

codes, sessions, pending, lock = {}, {}, {}, threading.Lock()


def page(title, body):
    return f"<!doctype html><html><head><meta charset=utf-8><title>{title}</title></head><body>{body}</body></html>"


def react_asset(name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        urllib.request.urlretrieve(REACT[name], path)
    return open(path, "rb").read()


class Handler(http.server.BaseHTTPRequestHandler):
    role = "app"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        names = [p.split("=", 1)[0].strip() for p in self.headers.get("Cookie", "").split(";") if p.strip()]
        sys.stderr.write(f"{time.strftime('%H:%M:%S')} {self.role} {self.command} {self.path} cookies={names}\n")

    def send(self, status, body=b"", ctype="text/html; charset=utf-8", headers=()):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location, headers=()):
        self.send(302, "", headers=[("Location", location), *headers])

    def cookie(self, name):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == name:
                return v

    def form(self):
        n = int(self.headers.get("Content-Length") or 0)
        return dict(up.parse_qsl(self.rfile.read(n).decode())) if n else {}

    def do_GET(self):
        u = up.urlparse(self.path)
        q = dict(up.parse_qsl(u.query))
        if self.command == "POST":
            q.update(self.form())
        getattr(self, f"{self.role}_route")(u.path, q)

    do_POST = do_GET

    def account(self):
        with lock:
            return sessions.get(self.cookie("qa_session") or "")

    # ---------------- app ----------------
    def app_route(self, path, q):
        if path == "/":
            links = " · ".join(f'<a href="{p}">{p}</a>' for p in (
                "/signin", "/signin-popup", "/signin?challenge=1", "/signin-popup?challenge=1", "/dashboard", "/slow-link", "/late", "/jsredirect",
                "/selectors", "/react", "/set-persistent", "/whoami"))
            return self.send(200, page("QA App", f"<h1>QA App</h1><p>{links}</p>"))

        if path == "/signin":
            return self.send(200, page("Sign in", f"""<h1>Sign in</h1>
<a id=idp href="/oauth/start{challenge_qs(q, '?')}"><button>Continue with IdP</button></a>"""))
        if path == "/oauth/start":
            return self.redirect(f"/oauth/start2?state={secrets.token_hex(4)}{challenge_qs(q)}")
        if path == "/oauth/start2":
            ret = up.quote(APP + "/callback", safe="")
            return self.redirect(f"{IDP}/login?client_id=qa&redirect_uri={ret}&state={q.get('state', '')}{challenge_qs(q)}")

        if path in ("/callback", "/callback-popup"):
            with lock:
                acct = codes.pop(q.get("code", ""), None)
            if not acct:
                return self.send(400, page("Bad code", "<h1>invalid code</h1>"))
            sid = secrets.token_hex(16)
            with lock:
                sessions[sid] = acct
            # session-only: no Expires / Max-Age
            ck = ("Set-Cookie", f"qa_session={sid}; Path=/; HttpOnly; SameSite=Lax")
            if path == "/callback-popup":
                return self.send(200, '{"ok":true}', "application/json", [ck])
            return self.redirect("/dashboard", [ck])

        if path == "/dashboard":
            acct = self.account()
            if not acct:
                return self.send(401, page("Not signed in", "<h1 id=signed-out>not signed in</h1><a href='/signin'>sign in</a>"))
            return self.send(200, page("Dashboard", f"""<h1 id=welcome>welcome {acct}</h1>
<button id=create onclick="fetch('/api/keys',{{method:'POST'}}).then(r=>r.json()).then(j=>{{document.getElementById('key').textContent=j.key}})">Create API key</button>
<pre id=key></pre>
<a href="/logout">Log out</a>"""))
        if path == "/api/keys":
            if not self.account():
                return self.send(401, '{"error":"unauthorized"}', "application/json")
            return self.send(200, json.dumps({"key": "sk-qa-" + secrets.token_hex(12)}), "application/json")
        if path == "/logout":
            with lock:
                sessions.pop(self.cookie("qa_session") or "", None)
            return self.redirect("/signin", [("Set-Cookie", "qa_session=; Path=/; Max-Age=0")])

        if path == "/signin-popup":
            ret = up.quote(APP + "/callback-popup", safe="")
            return self.send(200, page("Sign in (popup)", f"""<h1>Sign in (popup)</h1>
<button id=signin onclick="window.open('{IDP}/login?mode=popup&client_id=qa&redirect_uri={ret}{challenge_qs(q)}','idp','width=500,height=600')">Sign in</button>
<p id=status>waiting</p>
<script>
window.addEventListener('message', async e => {{
  if (e.origin !== '{IDP}') return;
  document.getElementById('status').textContent = 'got code';
  await fetch('/callback-popup?code=' + encodeURIComponent(e.data.code));
  location = '/dashboard';
}});
</script>"""))

        # A3: link to a slow page
        if path == "/slow-link":
            return self.send(200, page("Slow link", '<h1>slow link</h1><a id=go href="/slow">go slow</a>'))
        if path == "/slow":
            time.sleep(float(q.get("s", 2)))
            return self.send(200, page("Slow page", "<h1 id=slow>slow page loaded</h1>"))

        # A6: element appears after ?s seconds (default 10)
        if path == "/late":
            ms = int(float(q.get("s", 10)) * 1000)
            return self.send(200, page("Late", f"""<h1>late element in {ms}ms</h1>
<script>setTimeout(() => {{ const d = document.createElement('div'); d.id = 'late'; d.textContent = 'late arrived'; document.body.append(d) }}, {ms})</script>"""))

        if path == "/jsredirect":
            return self.send(200, page("Redirecting", "<h1>redirecting in 2s</h1><script>setTimeout(() => location = '/landed', 2000)</script>"))
        if path == "/landed":
            return self.send(200, page("Landed", "<h1 id=landed>landed after js redirect</h1>"))

        # A12: selector semantics
        if path == "/selectors":
            return self.send(200, page("Selectors", """<h1>selectors</h1>
<button style="display:none" onclick="document.getElementById('clicked').textContent='hidden Save'">Save</button>
<button onclick="document.getElementById('clicked').textContent='Save draft'">Save draft</button>
<button id=save onclick="document.getElementById('clicked').textContent='Save'">Save</button>
<p>clicked: <span id=clicked>none</span></p>"""))
        if path == "/react":
            return self.send(200, page("React", """<h1>react input</h1><div id=root></div>
<script src="/react.js"></script><script src="/react-dom.js"></script>
<script>
function App() {
  const [v, setV] = React.useState('');
  return React.createElement('div', null,
    React.createElement('input', {id: 'name', value: v, onChange: e => setV(e.target.value)}),
    React.createElement('p', null, 'state: ', React.createElement('span', {id: 'state'}, v || '(empty)')));
}
ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(App));
</script>"""))
        if path in ("/react.js", "/react-dom.js"):
            return self.send(200, react_asset(path[1:]), "application/javascript")

        # A7: persistent cookie + a page reporting which cookie names the server saw
        if path == "/set-persistent":
            return self.send(200, page("Persistent", "<h1 id=persisted>persistent cookie set</h1>"),
                             headers=[("Set-Cookie", "qa_persist=1; Path=/; Max-Age=86400; SameSite=Lax")])
        if path == "/whoami":
            names = sorted(p.split("=", 1)[0].strip() for p in self.headers.get("Cookie", "").split(";") if p.strip())
            return self.send(200, page("Whoami", f"<h1>cookies: <span id=cookies>{' '.join(names) or '(none)'}</span></h1>"
                                                 f"<p>account: <span id=account>{self.account() or '(none)'}</span></p>"))
        return self.send(404, page("404", "<h1>404</h1>"))

    # ---------------- idp ----------------
    def idp_route(self, path, q):
        if path == "/login":
            hidden = "".join(f'<input type=hidden name="{k}" value="{v}">' for k, v in q.items() if k != "user")
            return self.send(200, page("IdP login", f"""<h1>IdP login</h1>
<form method=post action="/authorize">{hidden}<input id=user name=user placeholder=username>
<button type=submit>Sign in</button></form>"""))
        if path == "/authorize":
            user = q.get("user", "").strip()
            if not user:
                return self.send(400, page("IdP error", "<h1>username required</h1>"))
            if q.get("challenge") == "1":
                token = secrets.token_hex(8)
                with lock:
                    pending[token] = {**q, "user": user}
                return self.send(303, "", headers=[("Location", f"/challenge?t={token}")])
            return self.finish_authorize(q, user)
        # fake "confirm it's you" — deliberately matches none of webkit-cli's built-in Google/captcha patterns
        if path == "/challenge":
            with lock:
                held = pending.get(q.get("t", ""))
            if not held:
                return self.send(400, page("IdP error", "<h1>unknown challenge</h1>"))
            code = q.get("code", "").strip() if self.command == "POST" else ""
            if not code:
                error = "<p id=error>enter the code</p>" if self.command == "POST" else ""
                return self.send(200, page("Confirm it's you", f"""<h1>Confirm it's you</h1>
<p>Enter the code we sent to your device.</p>{error}
<form method=post action="/challenge"><input type=hidden name=t value="{q['t']}">
<input id=code name=code autocomplete=off placeholder=code>
<button id=continue type=submit>Continue</button></form>"""))
            with lock:
                pending.pop(q["t"], None)
            return self.finish_authorize(held, held["user"])
        return self.send(404, page("404", "<h1>404</h1>"))

    def finish_authorize(self, q, user):
        code = secrets.token_hex(8)
        with lock:
            codes[code] = user
        if q.get("mode") == "popup":
            return self.send(200, page("Signing in", f"""<h1>signing in…</h1>
<script>window.opener.postMessage({{code: '{code}'}}, '{APP}'); setTimeout(() => window.close(), 300)</script>"""))
        ru = q["redirect_uri"]
        sep = "&" if "?" in ru else "?"
        # 303 so the POST becomes a GET on the app side
        self.send(303, "", headers=[("Location", f"{ru}{sep}code={code}&state={q.get('state', '')}")])


def challenge_qs(q, lead="&"):
    return f"{lead}challenge=1" if q.get("challenge") == "1" else ""


def serve(role, port):
    cls = type(f"Handler_{role}", (Handler,), {"role": role})
    http.server.ThreadingHTTPServer(("127.0.0.1", port), cls).serve_forever()


if __name__ == "__main__":
    threading.Thread(target=serve, args=("idp", IDP_PORT), daemon=True).start()
    sys.stderr.write(f"app {APP}  idp {IDP}\n")
    serve("app", APP_PORT)
