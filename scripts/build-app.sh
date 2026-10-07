#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ARCH="${MACMONITOR_ARCH:-x86_64}"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_DIR="$OUTPUT_DIR/MacMonitor.app"

cd "$ROOT_DIR"

swift test
swift build -c release --arch "$TARGET_ARCH"
BIN_DIR="$(swift build -c release --arch "$TARGET_ARCH" --show-bin-path)"

if [[ ! -x "$ROOT_DIR/vendor/mediamtx/mediamtx" ]]; then
    echo "MediaMTX is missing. Run ./scripts/fetch-mediamtx.sh first." >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "FFmpeg is missing. Install it with: brew install ffmpeg" >&2
    exit 1
fi
if ! command -v go >/dev/null 2>&1; then
    echo "Go 1.26.x is required to build the HTTPS gateway." >&2
    exit 1
fi
GO_VERSION="$(go env GOVERSION)"
if [[ "$GO_VERSION" != go1.26.* ]]; then
    echo "Go 1.26.x is required for Monterey compatibility; found $GO_VERSION" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/ThirdParty" "$APP_DIR/Contents/Helpers"
cp "$BIN_DIR/MacMonitor" "$APP_DIR/Contents/MacOS/MacMonitor"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/vendor/mediamtx/mediamtx" "$APP_DIR/Contents/Helpers/mediamtx"
cp "$ROOT_DIR/vendor/mediamtx/LICENSE" "$APP_DIR/Contents/Resources/ThirdParty/MediaMTX-LICENSE.txt"

(
    cd "$ROOT_DIR/gateway"
    CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go test ./...
    CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build \
        -trimpath -ldflags="-s -w" \
        -o "$APP_DIR/Contents/Helpers/macmonitor-gateway" \
        ./cmd/macmonitor-gateway
)

codesign --force --sign - "$APP_DIR/Contents/Helpers/mediamtx"
codesign --force --sign - "$APP_DIR/Contents/Helpers/macmonitor-gateway"

codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/Resources/MacMonitor.entitlements" \
    "$APP_DIR"

echo "Built $APP_DIR for $TARGET_ARCH"
