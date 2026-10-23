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
import re
PROTOCOL = int(re.search(r"sessionProtocolVersion = (\d+)", open("Sources/webkit-cli/Session.swift").read()).group(1))
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

import time
def timed(f):
    t = time.monotonic(); f(); return time.monotonic() - t
# pageLoadStrategy: normal waits for the load event, eager for DOMContentLoaded, none for nothing
slow = f"{APP}/slow-image?s=3"
for strategy, lo, hi in (("normal", 3, 10), ("eager", 0, 1.5), ("none", 0, 0.5)):
    s2 = req("POST", "/session", {"capabilities": {"alwaysMatch": {"pageLoadStrategy": strategy}}})
    check(s2["capabilities"]["pageLoadStrategy"] == strategy, f"{strategy} in capabilities")
    S2 = f"/session/{s2['sessionId']}"
    dt = timed(lambda: req("POST", f"{S2}/url", {"url": slow}))
    check(lo <= dt <= hi, f"{strategy}: navigate took {dt:.2f}s, wanted {lo}-{hi}s")
    if strategy == "eager":
        check(req("POST", f"{S2}/execute/sync", {"script": "return document.getElementById('parsed') !== null", "args": []}), "eager: document parsed")
        req("POST", f"{S2}/url", {"url": f"{APP}/slow-link"})
        go = req("POST", f"{S2}/element", {"using": "css selector", "value": "#go"})[E]
        req("POST", f"{S2}/execute/sync", {"script": "arguments[0].href = '/slow-image?s=3'; return null", "args": [{E: go}]})
        dt = timed(lambda: req("POST", f"{S2}/element/{go}/click", {}))
        check(dt <= 1.5 and req("GET", f"{S2}/url").endswith("/slow-image?s=3"), f"eager: click to a slow page took {dt:.2f}s")
    req("DELETE", S2)
    ok(f"pageLoadStrategy {strategy}: navigate {dt:.2f}s")

# timeouts: pageLoad bounds navigation, script bounds execute, implicit waits for elements
s2 = req("POST", "/session", {"capabilities": {"alwaysMatch": {"timeouts": {"pageLoad": 1000}}}})
S2 = f"/session/{s2['sessionId']}"
check(req("GET", f"{S2}/timeouts") == {"pageLoad": 1000, "script": 30000, "implicit": 0}, "timeouts from capabilities")
check(req("POST", f"{S2}/url", {"url": f"{APP}/slow?s=3"}, expect=500)["error"] == "timeout", "pageLoad timeout")
req("POST", f"{S2}/url", {"url": f"{APP}/late?s=1"})
check(req("POST", f"{S2}/url", {"url": f"{APP}/late?s=1"}) is None, "navigate after a timed-out one")
req("POST", f"{S2}/timeouts", {"script": 500, "implicit": 3000})
check(req("GET", f"{S2}/timeouts") == {"pageLoad": 1000, "script": 500, "implicit": 3000}, "timeouts set")
check(req("POST", f"{S2}/execute/sync", {"script": "await new Promise(r => setTimeout(r, 3000))", "args": []}, expect=500)["error"] == "script timeout", "script timeout")
check(E in req("POST", f"{S2}/element", {"using": "css selector", "value": "#late"}), "implicit wait found the late element")
check(req("POST", f"{S2}/timeouts", {"implicit": -1}, expect=400)["error"] == "invalid argument", "bad timeout")
req("DELETE", S2)
ok("timeouts: pageLoad, script, implicit")

# trusted input: real platform events, so hover, double clicks, held modifiers and wheel work as a person's
s2 = req("POST", "/session", {"capabilities": {}})
S2 = f"/session/{s2['sessionId']}"
def js(code): return req("POST", f"{S2}/execute/sync", {"script": code, "args": []})
def act(*sources): req("POST", f"{S2}/actions", {"actions": list(sources)})
mouse = lambda *a: {"type": "pointer", "id": "m", "parameters": {"pointerType": "mouse"}, "actions": list(a)}
keys = lambda *a: {"type": "key", "id": "k", "actions": list(a)}
req("POST", f"{S2}/url", {"url": f"{APP}/input"})
hov = req("POST", f"{S2}/element", {"using": "css selector", "value": "#hov"})[E]
act(mouse({"type": "pointerMove", "origin": {E: hov}, "x": 0, "y": 0, "duration": 100}))
check(js("return hovered()"), "pointerMove hovers (:hover)")
check(any(e["t"] == "mouseover" for e in js("return log")), "pointerMove fires mouseover")
act(mouse({"type": "pointerDown", "button": 0}, {"type": "pointerUp", "button": 0}, {"type": "pointerDown", "button": 0}, {"type": "pointerUp", "button": 0}))
dbl = [e for e in js("return log") if e["t"] == "dblclick"]
check(len(dbl) == 1 and dbl[0]["detail"] == 2, f"double click: {dbl}")
field = req("POST", f"{S2}/element", {"using": "css selector", "value": "#field"})[E]
req("POST", f"{S2}/element/{field}/click", {})
act(keys({"type": "keyDown", "value": "\ue009"}, {"type": "keyDown", "value": "a"}, {"type": "keyUp", "value": "a"}, {"type": "keyUp", "value": "\ue009"}))
ka = [e for e in js("return log") if e["t"] == "keydown" and e["key"] == "a"]
check(ka and ka[-1]["ctrl"], f"Control held through key actions: {ka}")
req("POST", f"{S2}/element/{field}/clear", {})
req("POST", f"{S2}/element/{field}/value", {"text": "ab\ue008cd\ue000e1"})
check(js("return field.value") == "abCDe1", "send keys: Shift held until Null")
area = req("POST", f"{S2}/element", {"using": "css selector", "value": "#area"})[E]
long = "".join(chr(97 + i % 26) for i in range(12000))
js("log.length = 0")
took = timed(lambda: req("POST", f"{S2}/element/{area}/value", {"text": long + "\n" + "end"}))
check(js("return area.value") == long + "\nend", "long send keys: the whole text arrives")
check(took < 3, f"long send keys is one insertion, not 12000 keystrokes: {took:.2f}s")
ins = [e for e in js("return log") if e["t"] in ("beforeinput", "input") and e["inputType"] == "insertText"]
check(len(ins) >= 2 and all(e["trusted"] for e in ins), f"insertion fires trusted beforeinput/input insertText: {ins[:4]}")
check(sum(e["t"] == "keydown" for e in js("return log")) == 4, "short runs and line breaks stay keystrokes")
# a timed-out input request stops: the keys it hadn't sent yet are dropped, not typed later
req("POST", f"{S2}/element/{area}/clear", {})
req("POST", f"{S2}/element/{area}/click", {})
sock = socket.socket(socket.AF_UNIX); sock.connect(os.path.expanduser(f"~/.config/webkit-cli/run/{profile}.sock"))
steps = [{"t": "key", "key": "x", "down": d} for _ in range(4000) for d in (True, False)]
sock.sendall(json.dumps({"v": PROTOCOL, "cmd": "input", "target": s2["sessionId"], "timeout": 0.5, "input": steps}).encode() + b"\n")
answer = json.loads(sock.makefile().readline())
check(not answer["ok"] and "timed out" in answer["error"], f"input times out: {answer}")
time.sleep(0.5)
n = js("return area.value.length")
time.sleep(1)
check(js("return area.value.length") == n < 4000, f"typing stops with its timed-out request ({n} chars)")
ok(f"long send keys: 12000 chars inserted in {took:.2f}s; a timed-out input stopped at {n} of 4000 keys")
act({"type": "wheel", "id": "w", "actions": [{"type": "scroll", "x": 100, "y": 100, "deltaX": 0, "deltaY": 400}]})
for _ in range(20):
    if js("return scrollY") > 0: break
    time.sleep(0.05)
check(js("return scrollY") > 0, "wheel scrolls the page")
check(js("return document.querySelector('[data-wd], [data-wk-ref]') === null && !document.documentElement.outerHTML.includes('data-wd')"), "element handles leave no trace in the DOM")
same = req("POST", f"{S2}/element", {"using": "css selector", "value": "#hov"})[E]
check(same == hov, "the same element keeps its handle")
check(req("POST", f"{S2}/execute/sync", {"script": "return [arguments[0].id, document.getElementById('field')]", "args": [{E: hov}]}) == ["hov", {E: field}], "elements cross into execute and back")
untrusted = [e for e in js("return log") if not e["trusted"]]
check(not untrusted, f"every input event is trusted: {untrusted[:5]}")
check(req("POST", f"{S2}/element/{req('POST', f'{S2}/element', {'using': 'css selector', 'value': '#covered'})[E]}/click", {}, expect=400)["error"] == "element click intercepted", "covered element")
req("DELETE", S2)
ok("trusted input: hover, double click, held modifiers, send keys, wheel, click intercepted")

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
# the session process webdriver started is still running; it must not have inherited the listen socket
pgrep -f "serve --account $P" >/dev/null || fail "session process gone"
python3 -c "import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', int(sys.argv[1]))); s.listen()" "$PORT" \
  || fail "port $PORT still held after webdriver exited (the session process inherited the listen socket)"
echo "ok  session process didn't inherit the listen socket"
echo "all webdriver checks passed"
