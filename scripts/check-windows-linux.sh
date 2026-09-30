#!/bin/sh
# Linux windows (auth / show / --escalate) under a headless Wayland compositor, against the local
# fixture. The fixture's ?challenge=auto page completes itself, standing in for the person.
#   BIN=/path/to/webkit-cli scripts/check-windows-linux.sh      (needs weston + python3)
set -eu
cd "$(dirname "$0")/.."
B=${BIN:?set BIN to the webkit-cli binary}
P="win-$$"; A="--account $P"
APP=http://127.0.0.1:18765
tmp=$(mktemp -d)
export XDG_RUNTIME_DIR="$tmp/xdg"; mkdir -m 700 "$XDG_RUNTIME_DIR"
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok  $*"; }
tab() { sed -E 's/.*"tab":"([^"]+)".*/\1/'; }

python3 scripts/fixtures/oauth_server.py 18765 18766 2>"$tmp/fixture.log" & FIXTURE=$!
cleanup() {
  $B stop $A >/dev/null 2>&1 || true; $B forget "$P" >/dev/null 2>&1 || true
  kill $FIXTURE ${WESTON:-} 2>/dev/null || true; wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
sleep 1

python3 - "$P" <<'PY'
import json, os, sys, uuid
p = os.path.expanduser("~/.config/webkit-cli/accounts.json")
os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
d = json.load(open(p)) if os.path.exists(p) else {}
d[sys.argv[1]] = str(uuid.uuid4()).upper()
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600); os.write(fd, json.dumps(d).encode()); os.close(fd)
PY

unset WAYLAND_DISPLAY
t=$($B open "$APP/" --wait 0 $A | tab)
set +e; $B show "$t" $A 2>"$tmp/err"; code=$?; set -e
[ $code = 1 ] && grep -q "Wayland" "$tmp/err" || fail "show without a display should exit 1 naming Wayland (rc=$code)"
$B stop $A >/dev/null
ok "no display: show fails loudly"

weston --backend=headless --socket=wkcli-test >"$tmp/weston.log" 2>&1 & WESTON=$!
sleep 2
export WAYLAND_DISPLAY=wkcli-test

$B auth "$APP/signin" $A >"$tmp/auth" 2>&1 & AUTH=$!
sleep 4; kill -TERM $AUTH; wait $AUTH || fail "auth exit after SIGTERM: $(cat "$tmp/auth")"
grep -q '"saved":true' "$tmp/auth" && grep -q '"lastHost":"127.0.0.1"' "$tmp/auth" || fail "auth output: $(cat "$tmp/auth")"
ok "auth opens a window on the profile; SIGTERM saves and exits 0"

t=$($B open "$APP/whoami" --wait 0 $A | tab)
$B show "$t" --reason test $A >/dev/null 2>&1
$B tabs $A | grep -q '"shown":true' || fail "tab not shown"
[ "$($B eval "$t" 'return location.pathname' $A)" = '"/whoami"' ] || fail "window didn't open the tab's page"
$B eval "$t" 'location.href = "/dashboard"; return 1' $A >/dev/null 2>&1 || true
sleep 1
$B hide "$t" $A >/dev/null
$B wait "$t" --until-url /dashboard --timeout 10 $A >/dev/null || fail "hide didn't hand off to where the window ended"
ok "show opens the page in a window; hide continues headless where it ended"

$B goto "$t" "$APP/signin?challenge=auto" --wait 0 $A >/dev/null
$B click "$t" 'text=Continue with IdP' $A >/dev/null
$B type "$t" '#user' qa $A >/dev/null
$B click "$t" 'button[type=submit]' --escalate --challenge-url /challenge --human-timeout 60 $A >/dev/null 2>"$tmp/esc" || fail "escalation: $(cat "$tmp/esc")"
grep -q "needs you" "$tmp/esc" && grep -q "human step done" "$tmp/esc" || fail "escalation notes: $(cat "$tmp/esc")"
$B tabs $A | grep -q '"shown":false' || fail "window still shown after the challenge"
$B wait "$t" --until-url /dashboard --timeout 15 $A >/dev/null || fail "no dashboard after escalation"
$B snapshot "$t" $A | grep -q "welcome qa" || fail "not signed in after escalation"
ok "--escalate: challenge shown in a window, cleared, headless carries on signed in"

echo "all $pass window checks passed"
