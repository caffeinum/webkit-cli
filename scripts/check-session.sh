#!/bin/sh
# Session-mode regression suite against the local fake OAuth fixture (no internet needed), on a
# throwaway named profile that is forgotten at the end. Runs on macOS and Linux.
#   BIN=/path/to/webkit-cli scripts/check-session.sh
# Linux in a container: WebKit's bubblewrap sandbox needs user namespaces; where they're blocked,
# export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 (the container is then the isolation).
set -eu
cd "$(dirname "$0")/.."
B=${BIN:?set BIN to the webkit-cli binary}
P="check-$$"
A="--account $P"
APP=http://127.0.0.1:18765
tmp=$(mktemp -d)
pass=0

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok  $*"; }
tab() { sed -E 's/.*"tab":"([^"]+)".*/\1/'; }
ref() { grep -o "\[e[0-9]*\] $1" | head -1 | grep -o 'e[0-9]*' | head -1; }

python3 scripts/fixtures/oauth_server.py 18765 18766 2>"$tmp/fixture.log" &
FIXTURE=$!
cleanup() {
  $B stop $A >/dev/null 2>&1 || true
  $B forget "$P" >/dev/null 2>&1 || true
  kill $FIXTURE 2>/dev/null && wait $FIXTURE 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do python3 -c "import urllib.request; urllib.request.urlopen('$APP/')" 2>/dev/null && break; sleep 0.3; done

# a named throwaway profile (named ones normally come from `auth`, which needs a window)
python3 - "$P" <<'EOF'
import json, os, sys, uuid
p = os.path.expanduser("~/.config/webkit-cli/accounts.json")
os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
d = json.load(open(p)) if os.path.exists(p) else {}
d[sys.argv[1]] = str(uuid.uuid4()).upper()
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(d, indent=2).encode()); os.close(fd)
EOF

$B doctor >"$tmp/doctor" 2>&1 || fail "doctor: $(cat "$tmp/doctor")"
ok "doctor: $(grep -o '"rafPerSecond":[0-9.]*' "$tmp/doctor"), $(grep -o '"visibilityState":"[a-z]*"' "$tmp/doctor")"

# sign in through a redirect chain to another origin, one command per page
t=$($B open "$APP/signin" --wait 0 $A | tab); [ -n "$t" ] || fail open
$B click "$t" 'text=Continue with IdP' $A >/dev/null || fail "click to idp"
$B type "$t" '#user' alice $A >/dev/null || fail "type on idp"
$B click "$t" 'button[type=submit]' $A >/dev/null || fail "submit on idp"
$B wait "$t" --until-url '/dashboard' --timeout 20 $A >/dev/null || fail "wait for dashboard"
$B snapshot "$t" $A | grep -q "welcome alice" || fail "dashboard after sign-in"
ok "redirect sign-in across origins (open/click/type/wait/snapshot)"

# refs: act by ref, stable across snapshots, stale after navigation
snap=$($B snapshot "$t" $A); r=$(echo "$snap" | ref 'button "Create API key"'); [ -n "$r" ] || fail "no ref for Create API key"
[ "$($B snapshot "$t" $A | ref 'button "Create API key"')" = "$r" ] || fail "ref changed between snapshots"
$B click "$t" "$r" $A >/dev/null || fail "click by ref"
$B eval "$t" --raw --out "$tmp/key" 'return document.querySelector("pre#key").textContent' $A >/dev/null
grep -Eq '^sk-qa-[0-9a-f]{24}$' "$tmp/key" || fail "key via eval --out --raw"
[ "$(ls -l "$tmp/key" | cut -c1-10)" = "-rw-------" ] || fail "eval --out file not 0600"
$B goto "$t" "$APP/whoami" $A >/dev/null || fail goto
set +e; $B click "$t" "$r" $A 2>"$tmp/err"; code=$?; set -e
[ $code = 1 ] && grep -q "stale ref" "$tmp/err" || fail "stale ref after navigation (rc=$code)"
ok "refs (click by ref, stable, stale after goto) + eval --out --raw 0600"

# the session-only login cookie survives a session restart (side-car)
$B stop $A >/dev/null
t=$($B open "$APP/dashboard" --wait 0 $A | tab)
$B snapshot "$t" $A | grep -q "welcome alice" || fail "session cookie lost across stop"
ok "session-only cookie survives stop"

# popup sign-in: the popup becomes its own tab and closes itself
$B goto "$t" "$APP/signin-popup" $A >/dev/null
$B click "$t" 'text=Sign in' $A >/dev/null
popup=$($B tabs $A | grep -o "{[^}]*\"opener\":\"$t\"[^}]*}" | tab)
[ -n "$popup" ] || fail "popup not listed as a tab"
$B type "$popup" '#user' bob $A >/dev/null
$B click "$popup" 'button[type=submit]' $A >/dev/null 2>&1 || true   # the popup closes itself
$B wait "$t" --until-url '/dashboard' --timeout 20 $A >/dev/null || fail "opener after popup"
$B snapshot "$t" $A | grep -q "welcome bob" || fail "popup sign-in result"
ok "popup sign-in as its own tab"

# one-shot forms, errors and exit codes
$B snapshot "$APP/whoami" --wait 0 $A 2>/dev/null | grep -q "whoami" || fail "one-shot snapshot"
$B shot "$APP/dashboard" "$tmp/s.png" --wait 0 $A >/dev/null || fail "one-shot shot"
[ "$(head -c 8 "$tmp/s.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || fail "shot is not a PNG"
set +e
$B wait "$t" --until-url never --timeout 1 $A 2>/dev/null; [ $? = 3 ] || fail "timeout exit 3"
$B text "$t" $A 2>/dev/null; [ $? = 2 ] || fail "text removed exit 2"
$B open "$APP/" --account - 2>/dev/null; [ $? = 2 ] || fail "throwaway open exit 2"
set -e
$B close "$t" $A >/dev/null
[ "$($B tabs $A)" = "[]" ] || fail "tabs after close"
ok "one-shot snapshot/shot, timeout=3, text=2, throwaway open=2, close/tabs"

$B stop $A >/dev/null
$B forget "$P" >/dev/null || fail forget
ok "stop + forget"
echo "all $pass checks passed"
