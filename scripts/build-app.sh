#!/bin/bash
set -euo pipefail

export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ARCH="${MACMONITOR_ARCH:-x86_64}"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_DIR="$OUTPUT_DIR/MacMonitor.app"
STAGING_DIR="$OUTPUT_DIR/.MacMonitor-staging-$$.app"
BACKUP_DIR="$OUTPUT_DIR/.MacMonitor-previous-$$.app"
EXPECTED_MEDIAMTX_VERSION="v1.21.1"

fail() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

cleanup() {
    case "$STAGING_DIR" in
        "$OUTPUT_DIR"/.MacMonitor-staging-*.app) rm -rf "$STAGING_DIR" ;;
    esac
    if [[ -e "$BACKUP_DIR" && ! -e "$APP_DIR" ]]; then
        mv "$BACKUP_DIR" "$APP_DIR" || \
            echo "warning: previous app remains at $BACKUP_DIR" >&2
    fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

[[ "$(uname -s)" == "Darwin" ]] || fail "build-app.sh must run on macOS"
[[ "$TARGET_ARCH" == "x86_64" ]] || fail "only the Intel x86_64 target is supported"
[[ "$(uname -m)" == "x86_64" ]] || fail "the release build must run on the target Intel Mac"

for command_name in swift xcodebuild go codesign lipo plutil; do
    require_command "$command_name"
done

# Command Line Tools ship an xcodebuild shim that only prints an xcode-select error.
DEVELOPER_PATH="$(xcode-select -p 2>/dev/null || true)"
[[ "$DEVELOPER_PATH" == *.app/Contents/Developer ]] || \
    fail "Xcode 14.2 is not the active developer directory (found ${DEVELOPER_PATH:-none}); install Xcode 14.2, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
[[ "$XCODE_VERSION" == "14.2" ]] || fail "Xcode 14.2 is required; found ${XCODE_VERSION:-unknown}"

# Xcode 14 prints "swift-driver version: 1.62.15 Apple Swift version 5.7.2 (...)".
SWIFT_VERSION="$(swift --version 2>&1 | awk '{ for (i = 1; i + 2 <= NF; i++) if (v == "" && $i == "Swift" && $(i + 1) == "version") v = $(i + 2) } END { print v }')"
[[ "$SWIFT_VERSION" == 5.7* ]] || fail "Swift 5.7.x is required; found ${SWIFT_VERSION:-unknown}"

GO_VERSION="$(go env GOVERSION)"
[[ "$GO_VERSION" == go1.26.* ]] || fail "Go 1.26.x is required for Monterey compatibility; found $GO_VERSION"

FFMPEG_PATH=""
for candidate in /usr/local/bin/ffmpeg /opt/homebrew/bin/ffmpeg; do
    if [[ -x "$candidate" ]]; then
        FFMPEG_PATH="$candidate"
        break
    fi
done
[[ -n "$FFMPEG_PATH" ]] || fail "FFmpeg is missing from an app-visible path (/usr/local/bin or /opt/homebrew/bin)"
"$FFMPEG_PATH" -hide_banner -encoders 2>/dev/null | grep '[[:space:]]h264_videotoolbox[[:space:]]' >/dev/null || \
    fail "FFmpeg does not provide the h264_videotoolbox encoder"

if [[ ! -x "$ROOT_DIR/vendor/mediamtx/mediamtx" ]]; then
    fail "MediaMTX is missing. Run ./scripts/fetch-mediamtx.sh first"
fi
MEDIAMTX_VERSION="$("$ROOT_DIR/vendor/mediamtx/mediamtx" --version | tr -d '\r')"
[[ "$MEDIAMTX_VERSION" == "$EXPECTED_MEDIAMTX_VERSION" ]] || \
    fail "MediaMTX $EXPECTED_MEDIAMTX_VERSION is required; found ${MEDIAMTX_VERSION:-unknown}"

plutil -lint "$ROOT_DIR/Resources/Info.plist" >/dev/null
plutil -lint "$ROOT_DIR/Resources/MacMonitor.entitlements" >/dev/null
plutil -lint "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" >/dev/null

bash "$ROOT_DIR/scripts/test-script-regressions.sh"
swift test
if [[ "${MACMONITOR_TSAN:-0}" == "1" ]]; then
    swift test --sanitize=thread
fi
swift build -c release --arch "$TARGET_ARCH"
BIN_DIR="$(swift build -c release --arch "$TARGET_ARCH" --show-bin-path)"
lipo -verify_arch "$TARGET_ARCH" "$BIN_DIR/MacMonitor"

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Contents/MacOS" "$STAGING_DIR/Contents/Resources/ThirdParty" "$STAGING_DIR/Contents/Helpers"
cp "$BIN_DIR/MacMonitor" "$STAGING_DIR/Contents/MacOS/MacMonitor"
cp "$ROOT_DIR/Resources/Info.plist" "$STAGING_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$STAGING_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ROOT_DIR/vendor/mediamtx/mediamtx" "$STAGING_DIR/Contents/Helpers/mediamtx"
cp "$ROOT_DIR/vendor/mediamtx/LICENSE" "$STAGING_DIR/Contents/Resources/ThirdParty/MediaMTX-LICENSE.txt"

(
    cd "$ROOT_DIR/gateway"
    CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go test ./...
    CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build \
        -trimpath -ldflags="-s -w" \
        -o "$STAGING_DIR/Contents/Helpers/macmonitor-gateway" \
        ./cmd/macmonitor-gateway
)

chmod 755 \
    "$STAGING_DIR/Contents/MacOS/MacMonitor" \
    "$STAGING_DIR/Contents/Helpers/mediamtx" \
    "$STAGING_DIR/Contents/Helpers/macmonitor-gateway"

for executable in \
    "$STAGING_DIR/Contents/MacOS/MacMonitor" \
    "$STAGING_DIR/Contents/Helpers/mediamtx" \
    "$STAGING_DIR/Contents/Helpers/macmonitor-gateway"; do
    lipo -verify_arch "$TARGET_ARCH" "$executable"
done

codesign --force --sign - "$STAGING_DIR/Contents/Helpers/mediamtx"
codesign --force --sign - "$STAGING_DIR/Contents/Helpers/macmonitor-gateway"
codesign --force --sign - \
    --entitlements "$ROOT_DIR/Resources/MacMonitor.entitlements" \
    "$STAGING_DIR"

plutil -lint "$STAGING_DIR/Contents/Info.plist" >/dev/null
plutil -lint "$STAGING_DIR/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
codesign --verify --deep --strict --verbose=2 "$STAGING_DIR"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$STAGING_DIR" 2>&1)"
echo "$SIGNED_ENTITLEMENTS" | grep 'com.apple.security.device.camera' >/dev/null || \
    fail "signed app is missing the camera entitlement"

if [[ -e "$APP_DIR" ]]; then
    mv "$APP_DIR" "$BACKUP_DIR"
fi
if mv "$STAGING_DIR" "$APP_DIR"; then
    rm -rf "$BACKUP_DIR"
else
    if [[ -e "$BACKUP_DIR" ]]; then
        mv "$BACKUP_DIR" "$APP_DIR"
    fi
    fail "could not publish the verified app bundle"
fi

echo "Built and verified $APP_DIR for $TARGET_ARCH"
echo "Run ./scripts/diagnose.sh before the first monitoring session."
