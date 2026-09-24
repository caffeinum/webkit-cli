#!/bin/sh
# Regression check: headless pages must render (visible + rAF), and the headless commands must work
# against a public page. Uses only the throwaway `--account -`; touches no saved profiles.
set -eu
cd "$(dirname "$0")/.."
# BIN=/path/to/webkit-cli skips the build (e.g. while another webkit-cli from .build is running)
if [ -z "${BIN:-}" ]; then swift build -c release >/dev/null; fi
B="${BIN:-.build/release/webkit-cli}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

$B doctor >"$tmp/doctor.json" || fail "doctor: $(cat "$tmp/doctor.json")"
echo "doctor: $(cat "$tmp/doctor.json")"

$B open example.com --account - --wait 0 | grep -q '"title":"Example Domain"' || fail open
$B text example.com --account - --wait 0 | grep -q 'Example Domain' || fail text
[ "$($B eval example.com --account - --wait 0 'return document.querySelector("h1").textContent')" = '"Example Domain"' ] || fail eval
[ "$($B eval example.com --account - --wait 0 'await new Promise(r => setTimeout(r, 200)); return 1 + 1')" = 2 ] || fail "eval await"
$B shot example.com --account - "$tmp/shot.png" --wait 0 >/dev/null || fail shot
[ "$(head -c 8 "$tmp/shot.png" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || fail "shot is not a PNG"
if $B eval example.com --account - --wait 0 'throw new Error("x")' 2>/dev/null; then fail "js error should exit non-zero"; fi
set +e; $B open https://example.com --account - --timeout 0.01 2>/dev/null; code=$?; set -e
[ "$code" = 3 ] || fail "timeout should exit 3, got $code"
echo "ok: doctor, open, text, eval, eval+await, shot, js error, timeout"
