#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 <https-origin> <absolute-certificate-path> <absolute-private-key-path> [listen-address]" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_ORIGIN="$1"
CERTIFICATE_PATH="$2"
PRIVATE_KEY_PATH="$3"
LISTEN_ADDRESS="${4:-:8443}"
APP_SUPPORT="${MACMONITOR_APP_SUPPORT:-$HOME/Library/Application Support/MacMonitor}"
GATEWAY="$ROOT_DIR/dist/MacMonitor.app/Contents/Helpers/macmonitor-gateway"

if [[ ! -x "$GATEWAY" ]]; then
    echo "Build the app first: ./scripts/build-app.sh" >&2
    exit 1
fi
if [[ "$CERTIFICATE_PATH" != /* || "$PRIVATE_KEY_PATH" != /* ]]; then
    echo "Certificate and key paths must be absolute" >&2
    exit 1
fi
if [[ ! -r "$CERTIFICATE_PATH" ]]; then
    echo "Certificate is missing or unreadable: $CERTIFICATE_PATH" >&2
    exit 1
fi
if [[ ! -r "$PRIVATE_KEY_PATH" ]]; then
    echo "Private key is missing or unreadable: $PRIVATE_KEY_PATH" >&2
    exit 1
fi
KEY_MODE="$(stat -f '%Lp' "$PRIVATE_KEY_PATH")"
if [[ "$KEY_MODE" != "600" && "$KEY_MODE" != "400" ]]; then
    echo "Private key permissions must be 600 or 400; found $KEY_MODE" >&2
    exit 1
fi

umask 077
mkdir -p "$APP_SUPPORT/Recordings"
chmod 700 "$APP_SUPPORT"
# Keep the candidate on the same filesystem so the final rename replaces the old
# configuration only after every check succeeds. EXIT also cleans failed attempts.
CANDIDATE="$(mktemp "$APP_SUPPORT/.gateway-config.XXXXXX")"
trap 'rm -f "$CANDIDATE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$GATEWAY" init \
    -output "$CANDIDATE" \
    -origin "$PUBLIC_ORIGIN" \
    -listen "$LISTEN_ADDRESS" \
    -cert "$CERTIFICATE_PATH" \
    -key "$PRIVATE_KEY_PATH" \
    -recordings "$APP_SUPPORT/Recordings"

"$GATEWAY" check-config -config "$CANDIDATE"
chmod 600 "$CANDIDATE"
mv -f "$CANDIDATE" "$APP_SUPPORT/gateway.json"
echo "Gateway configuration and TLS identity verified."
