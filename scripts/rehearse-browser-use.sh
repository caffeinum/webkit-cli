#!/bin/sh
# Dress rehearsal of browser-use-apikey.sh against the local fake OAuth fixture
# (scripts/fixtures/oauth_server.py on 127.0.0.1:8765/8766). Usage: rehearse-browser-use.sh <profile> <key-file>
set -eu
cd "$(dirname "$0")"
profile=$1
wrapper=$(mktemp -t wk-rehearse)
trap 'rm -f "$wrapper"' EXIT
printf '#!/bin/sh\nexec %s "$@" --account %s\n' "${WEBKIT_CLI:-webkit-cli}" "$profile" >"$wrapper"
chmod +x "$wrapper"
WEBKIT_CLI=$wrapper SIGNIN_URL=http://127.0.0.1:8765/signin GOOGLE_BUTTON='text=Continue with IdP' SIGNED_OUT_RE='/signin' \
APP_ORIGIN_RE='^http://127\.0\.0\.1:8765/' APP_URL_RE='^http://127\.0\.0\.1:8765/dashboard' PROVIDER_URL_RE='^http://127\.0\.0\.1:8766/' \
PROVIDER_TYPE_SELECTOR='#user' PROVIDER_TYPE_TEXT='alice' CHOOSER='button[type=submit]' \
API_KEYS_URL=http://127.0.0.1:8765/dashboard CREATE_BUTTONS='#create' CONFIRM_BUTTONS='#create' TOKEN_RE='sk-qa-[0-9a-f]{24}' \
sh ./browser-use-apikey.sh "$2"
