#!/usr/bin/env python3
"""Fake OAuth fixture for session-mode and escalate QA (docs/acceptance/session-mode.md, escalate.md).

Two origins on 127.0.0.1: app (default :8765) and idp (default :8766).
Usage: scripts/fixtures/oauth_server.py [app_port] [idp_port]
?challenge=1 on /signin or /signin-popup makes the idp insert a fake "confirm it's you" step
(idp /challenge: #code + Continue) between login and callback.
Request log → stderr: method, path, query/cookie *names* only. Never values or bodies: a person may type
real input into a shown window. Clicks recorded by /hit are kept in memory only (GET /hit/log).
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
hits = []  # /hit query dicts, memory only


def fake_token(alphabet, n):
    return "".join(secrets.choice(alphabet) for _ in range(n))


ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
B64URL = ALNUM + "-_"
# fake secrets for snapshot S6, generated per server start; QA reads them from /snapshot/secrets.json
FAKE_SECRETS = {
    "bu": "bu_" + fake_token(ALNUM, 40),
    "sk": "sk-" + fake_token(ALNUM, 32),
    "jwt": "eyJhbGciOiJIUzI1NiJ9." + fake_token(B64URL, 36) + "." + fake_token(B64URL, 43),
    "plain32": fake_token("abcdef", 16) + fake_token("0123456789", 8) + fake_token("ABCDEF", 8),
    "password": "pw-" + fake_token(ALNUM, 20),
}


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
        u = up.urlparse(self.path)
        keys = [k for k, _ in up.parse_qsl(u.query, keep_blank_values=True)]
        query = "?" + "&".join(keys) if keys else ""
        sys.stderr.write(f"{time.strftime('%H:%M:%S')} {self.role} {self.command} {u.path}{query} cookies={names}\n")

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
        # snapshot fixture (docs/acceptance/snapshot.md). ?items=N sets the list length (default 2000)
        if path == "/snapshot":
            n = int(q.get("items", 2000))
            items = "".join(f"<li>item {i}</li>" for i in range(n))
            return self.send(200, page("Snapshot fixture", SNAPSHOT_PAGE
                                       .replace("%ITEMS%", items).replace("%IDP%", IDP)
                                       .replace("%BU%", FAKE_SECRETS["bu"]).replace("%SK%", FAKE_SECRETS["sk"])
                                       .replace("%JWT%", FAKE_SECRETS["jwt"]).replace("%PLAIN32%", FAKE_SECRETS["plain32"])
                                       .replace("%PASSWORD%", FAKE_SECRETS["password"])))
        if path == "/snapshot/frame":
            return self.send(200, page("frame", "<p>inside same-origin frame</p>"
                                                "<button id=frame-btn onclick=\"fetch('/hit?what=iframe')\">Frame button</button>"))
        if path == "/snapshot/secrets.json":
            return self.send(200, json.dumps(FAKE_SECRETS), "application/json")
        if path == "/hit":
            with lock:
                hits.append(q)
            return self.send(204, "", "text/plain")
        if path == "/hit/log":
            with lock:
                return self.send(200, json.dumps(hits), "application/json")
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
        if path == "/xframe":
            return self.send(200, page("xframe", "<button onclick=\"fetch('/x')\">Cross-origin button</button>"))
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


SNAPSHOT_PAGE = """<nav><a href="/dashboard">Dashboard</a> <a href="/snapshot?items=0#top">This page</a></nav>
<main>
<h1>Snapshot fixture</h1>
<div id=inserts></div>
<h2>Controls</h2>
<button id=hidden-btn style="display:none" onclick="fetch('/hit?what=hidden')">Hidden button</button>
<button id=invisible-btn style="visibility:hidden">Invisible button</button>
<button id=zero-btn style="width:0;height:0;padding:0;border:0;overflow:hidden">Zero button</button>
<a id=aria-hidden-link href="/hit?what=aria-hidden" aria-hidden="true">Aria hidden link</a>
<div inert><button id=inert-btn onclick="fetch('/hit?what=inert')">Inert button</button></div>
<button id=disabled-btn disabled>Disabled button</button>
<label><input type=checkbox id=agree checked> I agree</label>
<label for=plan>Plan</label> <select id=plan><option value=free>Free</option><option value=team selected>Team</option><option value=ent>Enterprise</option></select>
<button id=victim onclick="fetch('/hit?what=victim')">Victim button</button>
<button id=remove-victim onclick="document.getElementById('victim').remove()">Remove victim</button>
<button id=insert-above onclick="const b=document.createElement('button');b.textContent='Inserted '+(document.getElementById('inserts').children.length+1);b.onclick=()=>fetch('/hit?what=inserted');document.getElementById('inserts').prepend(b)">Insert above</button>
<h2>Frames</h2>
<iframe id=same-frame src="/snapshot/frame" width=300 height=80></iframe>
<iframe id=cross-frame src="%IDP%/xframe" width=300 height=80></iframe>
<div id=shadow-host></div>
<script>
const root = document.getElementById('shadow-host').attachShadow({mode: 'open'});
root.innerHTML = '<p>inside shadow root</p><button id=shadow-btn>Shadow button</button>';
root.getElementById('shadow-btn').onclick = () => fetch('/hit?what=shadow');
</script>
<h2>Dialog</h2>
<button id=open-dialog onclick="document.getElementById('dlg').showModal()">Open dialog</button>
<dialog id=dlg aria-label="Create key">
  <label for=key-name>Key name</label> <input id=key-name placeholder="my key">
  <button id=dialog-submit onclick="fetch('/hit?what=dialog-submit&name='+encodeURIComponent(document.getElementById('key-name').value));document.getElementById('dlg').close()">Create</button>
  <button id=dialog-cancel onclick="document.getElementById('dlg').close()">Cancel</button>
</dialog>
<h2>Keys</h2>
<table><tr><th>Name</th><th>Key</th></tr>
<tr><td>browser-use</td><td id=bu-key>%BU%</td></tr>
<tr><td>openai-ish</td><td>%SK%</td></tr>
<tr><td>session</td><td>%JWT%</td></tr>
<tr><td>word</td><td>internationalization</td></tr></table>
<label for=plain>Token</label> <input id=plain readonly value="%PLAIN32%">
<label for=pw>Password</label> <input id=pw type=password value="%PASSWORD%">
<h2>React</h2><div id=react-root></div>
<script src="/react.js"></script><script src="/react-dom.js"></script>
<script>
function Ticker() {
  const [v, setV] = React.useState('');
  const [tick, setTick] = React.useState(0);
  React.useEffect(() => { const i = setInterval(() => setTick(t => t + 1), 500); return () => clearInterval(i) }, []);
  return React.createElement('div', null,
    React.createElement('label', {htmlFor: 'react-name'}, 'React name'),
    React.createElement('input', {id: 'react-name', value: v, onChange: e => setV(e.target.value)}),
    React.createElement('p', null, 'state: ', React.createElement('span', {id: 'react-state'}, v || '(empty)'),
      ' renders: ', React.createElement('span', {id: 'renders', 'data-tick': tick}, tick > 0 ? 'many' : 'one')));
}
ReactDOM.createRoot(document.getElementById('react-root')).render(React.createElement(Ticker));
</script>
<h2>List</h2><ul id=big>%ITEMS%</ul>
</main>"""


def challenge_qs(q, lead="&"):
    return f"{lead}challenge=1" if q.get("challenge") == "1" else ""


def serve(role, port):
    cls = type(f"Handler_{role}", (Handler,), {"role": role})
    http.server.ThreadingHTTPServer(("127.0.0.1", port), cls).serve_forever()


if __name__ == "__main__":
    threading.Thread(target=serve, args=("idp", IDP_PORT), daemon=True).start()
    sys.stderr.write(f"app {APP}  idp {IDP}\n")
    serve("app", APP_PORT)
