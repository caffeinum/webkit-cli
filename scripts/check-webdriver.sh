#!/bin/sh
# `webkit-cli webdriver` against the local fake OAuth fixture (no internet needed), on mac and linux:
# the W3C endpoints agent-browser's client uses, plus the session socket's protocol check.
#   BIN=/path/to/webkit-cli scripts/check-webdriver.sh
set -eu
cd "$(dirname "$0")/.."
B=${BIN:?set BIN to the webkit-cli binary}
P="wd-check-$$"
tmp=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 scripts/fixtures/oauth_server.py 18765 18766 2>"$tmp/fixture.log" &
FIXTURE=$!
WD=""
cleanup() {
  [ -n "$WD" ] && kill "$WD" 2>/dev/null || true
  $B stop --account "$P" >/dev/null 2>&1 || true
  $B forget "$P" >/dev/null 2>&1 || true
  kill $FIXTURE 2>/dev/null && wait $FIXTURE 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18765/')" 2>/dev/null && break; sleep 0.3; done

$B create "$P" >/dev/null || fail "create profile"
$B webdriver --account "$P" > "$tmp/wd.out" 2> "$tmp/wd.err" &
WD=$!
for _ in $(seq 1 50); do grep -q '"port"' "$tmp/wd.out" 2>/dev/null && break; sleep 0.1; done
PORT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['port'])" "$tmp/wd.out") || fail "webdriver printed no port: $(cat "$tmp/wd.err")"

python3 - "$PORT" "$P" <<'EOF' || fail "webdriver endpoints (see above)"
import json, os, socket, sys, urllib.request, urllib.error, base64
port, profile = sys.argv[1], sys.argv[2]
APP, IDP = "http://127.0.0.1:18765", "http://127.0.0.1:18766"
E = "element-6066-11e4-a52e-4f735466cecf"
def req(method, path, body=None, expect=200):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                               headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            status, out = resp.status, json.load(resp)
    except urllib.error.HTTPError as e:
        status, out = e.code, json.load(e)
    if status != expect:
        sys.exit(f"{method} {path}: HTTP {status}, wanted {expect}: {out}")
    return out["value"]
def ok(what): print(f"ok  {what}")
def check(cond, what):
    if not cond: sys.exit(f"FAIL {what}")

check(req("GET", "/status")["ready"] is True, "status"); ok("status")
s = req("POST", "/session", {"capabilities": {"alwaysMatch": {}}})
sid = s["sessionId"]; S = f"/session/{sid}"
check(s["capabilities"]["browserName"] == "webkit-cli", "capabilities"); ok(f"new session {sid}")

req("POST", f"{S}/url", {"url": f"{APP}/signin"})
check(req("GET", f"{S}/url") == f"{APP}/signin", "get url")
check(isinstance(req("GET", f"{S}/title"), str), "get title"); ok("navigate, url, title")

old = req("POST", f"{S}/element", {"using": "css selector", "value": "#idp button"})[E]
req("POST", f"{S}/element/{old}/click", {})
check(req("GET", f"{S}/url").startswith(IDP + "/login"), "click went to the idp"); ok("find (css) + click")
check(req("POST", f"{S}/element/{old}/click", {}, expect=404)["error"] == "stale element reference", "stale after navigation"); ok("stale element after navigation")
check(req("POST", f"{S}/element", {"using": "css selector", "value": "#nope"}, expect=404)["error"] == "no such element", "missing element"); ok("no such element")

user = req("POST", f"{S}/element", {"using": "xpath", "value": "//input[@id='user']"})[E]
req("POST", f"{S}/element/{user}/value", {"text": "bo"})
req("POST", f"{S}/element/{user}/clear", {})
req("POST", f"{S}/element/{user}/value", {"text": "ali"})
req("POST", f"{S}/element/{user}/value", {"text": "ce"})
check(req("GET", f"{S}/url").startswith(APP + "/dashboard"), "Enter submitted the form")
check("welcome alice" in req("GET", f"{S}/source"), "page source after sign-in"); ok("xpath, clear, send keys (append, Enter submits), source")

cookies = req("GET", f"{S}/cookie")
qa = [c for c in cookies if c["name"] == "qa_session"]
check(qa and qa[0]["httpOnly"] is True, f"httpOnly session cookie listed: {cookies}")
req("POST", f"{S}/cookie", {"cookie": {"name": "wd", "value": "1"}})
check(req("GET", f"{S}/cookie/wd")["value"] == "1", "cookie set")
check(req("POST", f"{S}/execute/sync", {"script": "return document.cookie", "args": []}).find("wd=1") >= 0, "page sees the cookie")
req("DELETE", f"{S}/cookie/wd")
check(req("GET", f"{S}/cookie/wd", expect=404)["error"] == "no such cookie", "cookie deleted"); ok("cookies: list (httpOnly), add, get, delete")

btn = req("POST", f"{S}/element", {"using": "css selector", "value": "#create"})[E]
check(req("POST", f"{S}/execute/sync", {"script": "return arguments[0].id + arguments[1]", "args": [{E: btn}, "!"]}) == "create!", "element argument")
got = req("POST", f"{S}/execute/sync", {"script": "return document.querySelector('#create')", "args": []})
check(got == {E: btn}, f"element result keeps its handle: {got}")
check(req("POST", f"{S}/execute/sync", {"script": "return await new Promise(r => setTimeout(() => r(42), 50))", "args": []}) == 42, "promise result")
check(req("POST", f"{S}/execute/sync", {"script": "throw new Error('boom')", "args": []}, expect=500)["error"] == "javascript error", "js error"); ok("execute/sync: args, element in/out, promise, error")

png = base64.b64decode(req("GET", f"{S}/screenshot"))
check(png[:8] == b"\x89PNG\r\n\x1a\n", "screenshot is a PNG"); ok(f"screenshot ({len(png)} bytes)")

req("POST", f"{S}/url", {"url": f"{APP}/selectors"})
req("POST", f"{S}/back", {}); check(req("GET", f"{S}/url").startswith(APP + "/dashboard"), "back")
req("POST", f"{S}/forward", {}); check(req("GET", f"{S}/url") == f"{APP}/selectors", "forward")
req("POST", f"{S}/refresh", {}); check(req("GET", f"{S}/url") == f"{APP}/selectors", "refresh"); ok("back, forward, refresh")

save = req("POST", f"{S}/element", {"using": "css selector", "value": "#save"})[E]
req("POST", f"{S}/actions", {"actions": [{"type": "pointer", "id": "mouse", "parameters": {"pointerType": "mouse"}, "actions": [
    {"type": "pointerMove", "origin": {E: save}, "x": 0, "y": 0}, {"type": "pointerDown", "button": 0}, {"type": "pointerUp", "button": 0}]}]})
check(req("POST", f"{S}/execute/sync", {"script": "return document.getElementById('clicked').textContent", "args": []}) == "Save", "pointer actions clicked #save")
req("POST", f"{S}/execute/sync", {"script": "const i = document.createElement('input'); i.id = 'k'; document.body.append(i); i.focus(); return null", "args": []})
req("POST", f"{S}/actions", {"actions": [{"type": "key", "id": "kb", "actions": [
    {"type": "keyDown", "value": "h"}, {"type": "keyUp", "value": "h"}, {"type": "keyDown", "value": "i"}, {"type": "keyUp", "value": "i"}]}]})
check(req("POST", f"{S}/execute/sync", {"script": "return document.getElementById('k').value", "args": []}) == "hi", "key actions typed"); ok("actions: pointer click, keys")

check(req("GET", "/session/nope/url", expect=404)["error"] == "invalid session id", "unknown session")
check(req("GET", f"{S}/frobnicate", expect=404)["error"] == "unknown command", "unknown command"); ok("errors: invalid session id, unknown command")

req("DELETE", S)
check(req("GET", f"{S}/url", expect=404)["error"] == "invalid session id", "session gone after delete"); ok("delete session")

# the session socket refuses a client of another protocol version, with what to do about it
sock = socket.socket(socket.AF_UNIX); sock.connect(os.path.expanduser(f"~/.config/webkit-cli/run/{profile}.sock"))
sock.sendall(json.dumps({"v": 1, "cmd": "tabs", "timeout": 5}).encode() + b"\n")
answer = json.loads(sock.makefile().readline())
check(not answer["ok"] and "protocol" in answer["error"] and "webkit-cli stop" in answer["error"], f"protocol mismatch: {answer}")
ok("session socket refuses another protocol version")
EOF

kill -TERM "$WD"
for _ in $(seq 1 50); do kill -0 "$WD" 2>/dev/null || break; sleep 0.1; done
kill -0 "$WD" 2>/dev/null && fail "webdriver still running 5s after SIGTERM"
wait "$WD" && rc=0 || rc=$?
WD=""
[ "$rc" = 0 ] || fail "webdriver exited $rc on SIGTERM"
echo "ok  SIGTERM: exit 0"
echo "all webdriver checks passed"
