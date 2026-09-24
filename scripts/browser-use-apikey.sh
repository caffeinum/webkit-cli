#!/bin/sh
# Sign in to Browser Use Cloud with Google and create an API key, headless, with only webkit-cli.
#
# Prereq, once, in a window:   webkit-cli auth google.com
# Usage:                        scripts/browser-use-apikey.sh [key-file]
#   key-file defaults to ~/.config/webkit-cli/secrets/browser-use.key (written 0600, dir 0700).
#   GOOGLE_EMAIL=you@x.com picks that account if Google shows an account chooser.
#   WEBKIT_CLI=/path/to/webkit-cli overrides the binary.
#
# The key goes page → file (eval --out --raw) and is never printed, logged or screenshotted.
# The script prints the file path and a short sha256 fingerprint only.
#
# Ported from Search's bench (parity on this flow): tabs that live between commands in a long-lived
# per-profile process, so a click that navigates cross-document doesn't kill the flow; `wait` with
# a URL condition instead of polling; one command in flight per profile; random tab ids;
# off-screen 1280x800 tabs with occlusion detection off (visible + animating, zero windows).
set -eu

W=${WEBKIT_CLI:-webkit-cli}
KEY_FILE=${1:-$HOME/.config/webkit-cli/secrets/browser-use.key}
KEY_NAME="webkit-cli-$(date +%Y%m%d-%H%M%S)"

# --- Browser Use's URLs and UI; adjust when they change. Lists are one selector per line.
# Every one can be overridden from the environment (that's how QA rehearses this against a local fake).
SIGNIN_URL=${SIGNIN_URL:-https://cloud.browser-use.com/signin}
GOOGLE_BUTTON=${GOOGLE_BUTTON:-'text=Sign in with Google'}
APP_URL_RE=${APP_URL_RE:-'^https://cloud\.browser-use\.com/(?!signin|signup)'}
API_KEYS_URL=${API_KEYS_URL:-'https://cloud.browser-use.com/settings?tab=api-keys&new=1'}   # from docs.browser-use.com
CREATE_BUTTONS=${CREATE_BUTTONS:-'text=Create API key
text=New API key
text=Create key
text=Create'}
NAME_INPUTS=${NAME_INPUTS:-'[role=dialog] input[type=text]
[role=dialog] input:not([type])
input[placeholder*="name" i]'}
# only ever inside the dialog: a page-level "Create" here would mint a second key
CONFIRM_BUTTONS=${CONFIRM_BUTTONS:-'[role=dialog] button[type=submit]
[role=dialog] button:last-of-type'}
SIGNED_OUT_RE=${SIGNED_OUT_RE:-'/signin|/signup'}
APP_ORIGIN_RE=${APP_ORIGIN_RE:-'^https://cloud\.browser-use\.com/'}
PROVIDER_URL_RE=${PROVIDER_URL_RE:-'^https://accounts\.google\.com/'}
CHOOSER=${CHOOSER:-'[data-identifier]'}
# a key is a long token that appears on the page after we confirm and wasn't there before
TOKEN_RE=${TOKEN_RE:-'[A-Za-z0-9][A-Za-z0-9_-]{31,}'}

tab=""
step="start"
key_made=0
fail() {
  echo "FAIL at step '$step': $*" >&2
  if [ -n "$tab" ] && [ "$key_made" = 0 ]; then
    shot=$(mktemp -t browser-use-fail).png
    "$W" shot "$tab" "$shot" >/dev/null 2>&1 && echo "screenshot of the failing page (0600): $shot" >&2
  fi
  [ -n "$tab" ] && "$W" close "$tab" >/dev/null 2>&1
  exit 1
}
url() { "$W" eval "${1:-$tab}" 'return location.href' --raw; }
# first selector (one per line in $2) that `$1` accepts; the rest of the args follow the selector
first_of() {
  cmd=$1; list=$2; shift 2
  printf '%s\n' "$list" | while IFS= read -r sel; do
    [ -n "$sel" ] && "$W" "$cmd" "$tab" "$sel" "$@" >/dev/null 2>&1 && exit 0
  done
}

step="open sign-in page"
tab=$("$W" open "$SIGNIN_URL" | sed -E 's/.*"tab":"([^"]+)".*/\1/') || fail "could not open $SIGNIN_URL"
case "$tab" in t*) ;; *) fail "no tab id from open" ;; esac

if url | grep -Eq "$SIGNED_OUT_RE"; then
  step="click '$GOOGLE_BUTTON'"
  "$W" click "$tab" "$GOOGLE_BUTTON" >/dev/null || fail "button not found"

  # Google may: go straight back (already consented), show an account chooser, or a consent page.
  # A popup variant would show up as an extra tab in `webkit-cli tabs`.
  step="finish Google sign-in"
  i=0
  while :; do
    i=$((i + 1)); [ $i -le 10 ] || fail "still not back on browser-use after 10 sign-in steps (at $(url))"
    # the provider may run in a popup (window.open): it shows up as a tab whose opener is ours
    popup=$("$W" tabs | grep -o "{[^}]*\"opener\":\"$tab\"[^}]*}" | sed -E 's/.*"tab":"([^"]+)".*/\1/' | head -1)
    cur=${popup:-$tab}
    if ! "$W" wait "$cur" --timeout 30 >/dev/null 2>&1; then
      [ -n "$popup" ] && continue # the popup finished and closed itself meanwhile
      fail "page did not finish loading"
    fi
    here=$(url "$tab")
    if [ -z "$popup" ] && echo "$here" | grep -Eq "$APP_ORIGIN_RE" && ! echo "$here" | grep -Eq "$SIGNED_OUT_RE"; then
      break
    fi
    if url "$cur" 2>/dev/null | grep -Eq "$PROVIDER_URL_RE"; then
        page=$("$W" text "$cur")
        if echo "$page" | grep -Eqi "verify it.s you|enter your password|passkey|2-step|use your phone"; then
          fail "Google wants you to re-verify — run: webkit-cli auth google.com (sign in, click Done), then re-run this script"
        fi
        # rehearsal hook: a fake provider that asks for a username (never used for Google)
        if [ -n "${PROVIDER_TYPE_SELECTOR:-}" ]; then
          "$W" type "$cur" "$PROVIDER_TYPE_SELECTOR" "$PROVIDER_TYPE_TEXT" >/dev/null 2>&1 || true
        fi
        if [ -n "${GOOGLE_EMAIL:-}" ] && "$W" click "$cur" "[data-identifier=\"$GOOGLE_EMAIL\"]" >/dev/null 2>&1; then continue; fi
        if "$W" click "$cur" "$CHOOSER" >/dev/null 2>&1; then continue; fi
        if "$W" click "$cur" 'text=Continue' >/dev/null 2>&1; then continue; fi
        if "$W" click "$cur" 'text=Allow' >/dev/null 2>&1; then continue; fi
        fail "Google shows a page this script doesn't know how to get past — if it asks you to sign in, run: webkit-cli auth google.com"
    fi
    sleep 2
  done
fi

step="reach dashboard"
"$W" wait "$tab" --until-url "$APP_URL_RE" --timeout 60 >/dev/null || fail "not on the dashboard"
echo "signed in: $(url)" >&2

step="open API keys page"
"$W" goto "$tab" "$API_KEYS_URL" >/dev/null || fail "could not load $API_KEYS_URL"
# remember the tokens already on the page, inside the page (never passed through the shell)
"$W" eval "$tab" "window.__wkBefore = new Set(document.body.innerText.match(/$TOKEN_RE/g) || []); return true" >/dev/null

step="open the create dialog"
if ! "$W" eval "$tab" 'return !!document.querySelector("[role=dialog]")' --raw | grep -q true; then
  first_of click "$CREATE_BUTTONS" || fail "no create button (tried: $(echo "$CREATE_BUTTONS" | tr '\n' '|'))"
fi

if "$W" eval "$tab" 'return !!document.querySelector("[role=dialog]")' --raw | grep -q true; then
  step="type the key name"
  first_of type "$NAME_INPUTS" "$KEY_NAME" || echo "no name field found — creating without a name" >&2

  step="confirm"
  first_of click "$CONFIRM_BUTTONS" || fail "no confirm button in the dialog (tried: $(echo "$CONFIRM_BUTTONS" | tr '\n' '|'))"
else
  echo "no dialog after create — the button created the key directly" >&2
fi
key_made=1

step="read the new key into $KEY_FILE"
mkdir -p "$(dirname "$KEY_FILE")" && chmod 700 "$(dirname "$KEY_FILE")"
found=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  # the key never leaves the page except into the 0600 file
  if "$W" eval "$tab" --raw --out "$KEY_FILE" "
    const before = window.__wkBefore || new Set();
    const fields = [...document.querySelectorAll('input, textarea, code, pre')].map(e => e.value || e.textContent || '');
    const fresh = [...new Set((fields.join(' ') + ' ' + document.body.innerText).match(/$TOKEN_RE/g) || [])]
      .filter(t => !before.has(t) && /[0-9]/.test(t) && /[A-Za-z]/.test(t));
    if (fresh.length !== 1) throw new Error(fresh.length + ' new key-like tokens on the page');
    return fresh[0]" >/dev/null 2>&1; then found=1; break; fi
  sleep 1
done
[ $found = 1 ] || fail "confirmed, but no single new key appeared on the page (nothing saved; check the Browser Use UI)"
chmod 600 "$KEY_FILE"

step="close"
"$W" close "$tab" >/dev/null
echo "saved browser-use API key '$KEY_NAME' → $KEY_FILE (mode $(stat -f %Lp "$KEY_FILE"), sha256 $(shasum -a 256 "$KEY_FILE" | cut -c1-8))"
