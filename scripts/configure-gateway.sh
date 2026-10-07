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
APP_SUPPORT="$HOME/Library/Application Support/MacMonitor"
GATEWAY="$ROOT_DIR/dist/MacMonitor.app/Contents/Helpers/macmonitor-gateway"

if [[ ! -x "$GATEWAY" ]]; then
    echo "Build the app first: ./scripts/build-app.sh" >&2
    exit 1
fi
if [[ "$CERTIFICATE_PATH" != /* || "$PRIVATE_KEY_PATH" != /* ]]; then
    echo "Certificate and key paths must be absolute" >&2
    exit 1
fi

mkdir -p "$APP_SUPPORT/Recordings"
"$GATEWAY" init \
    -output "$APP_SUPPORT/gateway.json" \
    -origin "$PUBLIC_ORIGIN" \
    -listen "$LISTEN_ADDRESS" \
    -cert "$CERTIFICATE_PATH" \
    -key "$PRIVATE_KEY_PATH" \
    -recordings "$APP_SUPPORT/Recordings"
