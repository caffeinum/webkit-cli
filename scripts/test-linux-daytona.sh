#!/bin/sh
# Linux test run on a Daytona sandbox: create sandbox → upload this checkout's HEAD → build → run the
# regression suites → delete the sandbox (always, even on failure).
#   scripts/test-linux-daytona.sh
# Needs DAYTONA_API_KEY + DAYTONA_API_URL (sourced from ~/.config/daytona/env when present) and the
# `daytona` CLI. The build image is a Daytona snapshot from linux/Dockerfile, named after its hash and
# reused across runs. The sandbox's internet egress may be restricted, so the suites use a local fixture.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DAYTONA_API_KEY:-}" ] && [ -f "$HOME/.config/daytona/env" ]; then
  set -a; . "$HOME/.config/daytona/env"; set +a
fi
: "${DAYTONA_API_KEY:?DAYTONA_API_KEY is not set (and ~/.config/daytona/env is missing)}"
command -v daytona >/dev/null || { echo "daytona CLI not found" >&2; exit 1; }

d() { daytona "$@" 2>&1 | grep -v 'Version mismatch'; }
run() { # run a shell command in the sandbox; its output streams back, its exit code is ours
  d exec "$SB" --timeout "${2:-900}" -- "$1; echo __rc=\$?" | tee "$tmp/out" | { grep -v '^__rc=' || true; }
  rc=$(grep -o '^__rc=[0-9]*' "$tmp/out" | tail -1 | cut -d= -f2)
  [ "${rc:-1}" = 0 ]
}

# long jobs run fully detached in the sandbox (Daytona's exec waits on every descendant and its
# proxy can drop long requests), and we poll their log until they write their exit code
job() {
  name=$1; cmd=$2; limit=${3:-900}
  printf '%s\n' "$cmd" > "$tmp/$name.sh"
  b64=$(base64 < "$tmp/$name.sh" | tr -d '\n')
  run "echo $b64 | base64 -d > /tmp/$name.sh && rm -f /tmp/$name.log && setsid -f sh -c 'sh /tmp/$name.sh > /tmp/$name.log 2>&1; echo __done=\$? >> /tmp/$name.log' </dev/null >/dev/null 2>&1" 60
  waited=0
  while :; do
    sleep 5; waited=$((waited + 5))
    d exec "$SB" --timeout 30 -- "cat /tmp/$name.log 2>/dev/null" > "$tmp/$name.log" || true
    if grep -q '^__done=' "$tmp/$name.log"; then break; fi
    [ $waited -lt "$limit" ] || { cat "$tmp/$name.log"; echo "$name: no result after ${limit}s" >&2; return 1; }
  done
  grep -v '^__done=' "$tmp/$name.log"
  [ "$(grep -o '^__done=[0-9]*' "$tmp/$name.log" | cut -d= -f2)" = 0 ]
}

tmp=$(mktemp -d)
SNAP="webkit-cli-linux-$(shasum -a 256 linux/Dockerfile | cut -c1-12)"
SB="wkcli-test-$(date +%s)"
cleanup() {
  d delete "$SB" >/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

if ! d snapshot list | grep -q "$SNAP"; then
  echo "building Daytona snapshot $SNAP from linux/Dockerfile (a few minutes, once)"
  (cd linux && d snapshot create "$SNAP" -f Dockerfile --cpu 2 --memory 4 --disk 10) | tail -3
fi

echo "creating sandbox $SB"
d create --name "$SB" --snapshot "$SNAP" --auto-stop 30 --auto-delete 0 --label purpose=webkit-cli-test | grep -i "created" || { echo "sandbox create failed" >&2; exit 1; }

echo "uploading HEAD ($(git rev-parse --short HEAD)); uncommitted changes are not included"
git archive --format=tar.gz HEAD > "$tmp/src.tgz"
sum=$(shasum -a 256 "$tmp/src.tgz" | cut -c1-64)
base64 < "$tmp/src.tgz" | tr -d '\n' | fold -w 60000 > "$tmp/src.b64"
echo >> "$tmp/src.b64"
run "rm -f /tmp/src.b64 && mkdir -p /root/webkit-cli" 60
while IFS= read -r chunk; do [ -n "$chunk" ] && run "printf %s '$chunk' >> /tmp/src.b64" 60 >/dev/null; done < "$tmp/src.b64"
run "base64 -d /tmp/src.b64 > /tmp/src.tgz && echo '$sum  /tmp/src.tgz' | sha256sum -c --quiet && tar -xzf /tmp/src.tgz -C /root/webkit-cli" 60

echo "building"
run "cd /root/webkit-cli && swift build -c release 2>&1 | grep -E 'error:|Build complete'"

# WebKit sandboxes its web processes with bubblewrap; a container sandbox blocks the namespaces it
# needs, so there we run with WebKit's sandbox off and the Daytona sandbox as the isolation.
if run "cd /root/webkit-cli && .build/release/webkit-cli doctor >/dev/null 2>&1" 120; then
  NOSANDBOX=""
  echo "WebKit sandbox: on"
else
  NOSANDBOX="WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1"
  echo "WebKit sandbox: unavailable here (no user namespaces), running with it off"
fi

echo "suite: check-session.sh (local fixture)"
job session "cd /root/webkit-cli && $NOSANDBOX BIN=.build/release/webkit-cli sh scripts/check-session.sh"

echo "suite: browser-use rehearsal (redirect + popup)"
job rehearsal "set -e
cd /root/webkit-cli
python3 scripts/fixtures/oauth_server.py >/tmp/fixture.log 2>&1 &
fixture=\$!
sleep 1
export $NOSANDBOX WEBKIT_CLI=/root/webkit-cli/.build/release/webkit-cli
profile() { python3 -c \"import json,uuid,os; p=os.path.expanduser('~/.config/webkit-cli/accounts.json'); d=json.load(open(p)) if os.path.exists(p) else {}; d['rehearse']=str(uuid.uuid4()).upper(); json.dump(d,open(p,'w'))\"; }
profile; sh scripts/rehearse-browser-use.sh rehearse /tmp/k1; \$WEBKIT_CLI stop --account rehearse; \$WEBKIT_CLI forget rehearse
profile; SIGNIN_URL=http://127.0.0.1:8765/signin-popup GOOGLE_BUTTON='text=Sign in' sh scripts/rehearse-browser-use.sh rehearse /tmp/k2; \$WEBKIT_CLI stop --account rehearse; \$WEBKIT_CLI forget rehearse
stat -c '%a %n' /tmp/k1 /tmp/k2
kill \$fixture"
echo "PASS: webkit-cli on Linux (Daytona sandbox $SB, deleted on exit)"
