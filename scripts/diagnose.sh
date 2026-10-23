#!/bin/bash
set -uo pipefail

export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/MacMonitor.app"
APP_SUPPORT="${MACMONITOR_APP_SUPPORT:-$HOME/Library/Application Support/MacMonitor}"
EXPECTED_ARCH="x86_64"
EXPECTED_MEDIAMTX_VERSION="v1.21.1"
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
    local exit_code="${1:-2}"
    echo "usage: $0 [--app /absolute/path/MacMonitor.app]" >&2
    exit "$exit_code"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || usage
            APP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            usage
            ;;
    esac
done

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '[PASS] %s\n' "$*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf '[WARN] %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[FAIL] %s\n' "$*"
}

has_command() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "$1 found"
        return 0
    fi
    fail "$1 not found"
    return 1
}

version_at_least() {
    awk -v have="$1" -v need="$2" 'BEGIN {
        split(have, h, "."); split(need, n, ".")
        for (i = 1; i <= 3; i++) {
            hv = h[i] + 0; nv = n[i] + 0
            if (hv > nv) exit 0
            if (hv < nv) exit 1
        }
        exit 0
    }'
}

check_mode() {
    local path="$1"
    local expected="$2"
    local mode
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
    if [[ "$mode" == "$expected" ]]; then
        pass "$path permissions are $expected"
    else
        fail "$path permissions are ${mode:-unknown}; expected $expected"
    fi
}

printf 'MacMonitor preflight diagnostics\n'
printf 'app: %s\n' "$APP_DIR"
printf 'data: %s\n\n' "$APP_SUPPORT"

if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
    pass "running on macOS"
else
    fail "diagnostics must run on macOS"
fi

if [[ "$(uname -m 2>/dev/null || true)" == "$EXPECTED_ARCH" ]]; then
    pass "host architecture is $EXPECTED_ARCH"
else
    fail "host architecture is $(uname -m 2>/dev/null || echo unknown); expected $EXPECTED_ARCH"
fi

if has_command sw_vers; then
    OS_VERSION="$(sw_vers -productVersion)"
    if version_at_least "$OS_VERSION" "12.5"; then
        pass "macOS $OS_VERSION is supported"
    else
        fail "macOS $OS_VERSION is too old; 12.5 or newer is required"
    fi
fi

if has_command xcodebuild; then
    XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
    if [[ "$XCODE_VERSION" == "14.2" ]]; then
        pass "Xcode 14.2 selected"
    else
        fail "Xcode 14.2 must be selected; found ${XCODE_VERSION:-unknown}"
    fi
fi

if has_command swift; then
    # Xcode 14 prints "swift-driver version: 1.62.15 Apple Swift version 5.7.2 (...)".
    SWIFT_VERSION="$(swift --version 2>&1 | awk '{ for (i = 1; i + 2 <= NF; i++) if (v == "" && $i == "Swift" && $(i + 1) == "version") v = $(i + 2) } END { print v }')"
    if [[ "$SWIFT_VERSION" == 5.7* ]]; then
        pass "Swift $SWIFT_VERSION is supported"
    else
        fail "Swift 5.7.x is required; found ${SWIFT_VERSION:-unknown}"
    fi
fi

if has_command go; then
    GO_VERSION="$(go env GOVERSION 2>/dev/null || true)"
    if [[ "$GO_VERSION" == go1.26.* ]]; then
        pass "$GO_VERSION is supported"
    else
        fail "Go 1.26.x is required; found ${GO_VERSION:-unknown}"
    fi
fi

for command_name in codesign lipo plutil; do
    has_command "$command_name" || true
done

FFMPEG_PATH=""
for candidate in \
    "$APP_DIR/Contents/Helpers/ffmpeg" \
    /usr/local/bin/ffmpeg \
    /opt/homebrew/bin/ffmpeg; do
    if [[ -x "$candidate" ]]; then
        FFMPEG_PATH="$candidate"
        break
    fi
done

if [[ -n "$FFMPEG_PATH" ]]; then
    pass "FFmpeg found at $FFMPEG_PATH"
    if "$FFMPEG_PATH" -hide_banner -encoders 2>/dev/null | grep '[[:space:]]h264_videotoolbox[[:space:]]' >/dev/null; then
        pass "FFmpeg provides h264_videotoolbox"
    else
        fail "FFmpeg does not provide h264_videotoolbox"
    fi
    if "$FFMPEG_PATH" -hide_banner -loglevel error -nostdin \
        -f lavfi -i 'color=c=black:s=1280x720:r=15:d=0.1' \
        -frames:v 1 -an -c:v h264_videotoolbox -realtime true -allow_sw 1 \
        -f null - >/dev/null 2>&1; then
        pass "VideoToolbox encoded a synthetic 720p frame"
    else
        fail "VideoToolbox synthetic encode failed"
    fi
else
    fail "FFmpeg is not installed in a path visible to the app"
fi

MAIN_EXECUTABLE="$APP_DIR/Contents/MacOS/MacMonitor"
MEDIAMTX_EXECUTABLE="$APP_DIR/Contents/Helpers/mediamtx"
GATEWAY_EXECUTABLE="$APP_DIR/Contents/Helpers/macmonitor-gateway"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
PRIVACY_MANIFEST="$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"

if [[ -d "$APP_DIR" ]]; then
    pass "app bundle exists"
else
    fail "app bundle does not exist; run ./scripts/build-app.sh"
fi

for file in "$MAIN_EXECUTABLE" "$MEDIAMTX_EXECUTABLE" "$GATEWAY_EXECUTABLE"; do
    if [[ -x "$file" ]]; then
        pass "$file is executable"
        if command -v lipo >/dev/null 2>&1 && lipo "$file" -verify_arch "$EXPECTED_ARCH" >/dev/null 2>&1; then
            pass "$file contains $EXPECTED_ARCH"
        else
            fail "$file does not contain $EXPECTED_ARCH"
        fi
    else
        fail "$file is missing or not executable"
    fi
done

for plist in "$INFO_PLIST" "$PRIVACY_MANIFEST"; do
    if [[ -f "$plist" ]] && command -v plutil >/dev/null 2>&1 && plutil -lint "$plist" >/dev/null 2>&1; then
        pass "$plist is valid"
    else
        fail "$plist is missing or invalid"
    fi
done

if [[ -f "$INFO_PLIST" ]] && command -v plutil >/dev/null 2>&1; then
    BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST" 2>/dev/null || true)"
    MINIMUM_OS="$(plutil -extract LSMinimumSystemVersion raw -o - "$INFO_PLIST" 2>/dev/null || true)"
    [[ "$BUNDLE_ID" == "local.macmonitor.app" ]] && pass "bundle identifier is $BUNDLE_ID" || fail "unexpected bundle identifier: ${BUNDLE_ID:-missing}"
    [[ "$MINIMUM_OS" == "12.0" ]] && pass "deployment target is macOS $MINIMUM_OS" || fail "unexpected deployment target: ${MINIMUM_OS:-missing}"
fi

if command -v codesign >/dev/null 2>&1 && codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1; then
    pass "app code signature is structurally valid"
else
    fail "app code signature verification failed"
fi
if command -v codesign >/dev/null 2>&1; then
    SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_DIR" 2>&1 || true)"
    if echo "$SIGNED_ENTITLEMENTS" | grep 'com.apple.security.device.camera' >/dev/null; then
        pass "app signature contains the camera entitlement"
    else
        fail "app signature is missing the camera entitlement"
    fi
fi

if [[ -x "$MEDIAMTX_EXECUTABLE" ]]; then
    MEDIAMTX_VERSION="$("$MEDIAMTX_EXECUTABLE" --version 2>/dev/null | tr -d '\r')"
    if [[ "$MEDIAMTX_VERSION" == "$EXPECTED_MEDIAMTX_VERSION" ]]; then
        pass "MediaMTX $MEDIAMTX_VERSION is pinned"
    else
        fail "unexpected MediaMTX version: ${MEDIAMTX_VERSION:-unknown}"
    fi
fi

if [[ -x "$GATEWAY_EXECUTABLE" ]] && "$GATEWAY_EXECUTABLE" check-config -h >/dev/null 2>&1; then
    pass "gateway diagnostic command starts"
elif [[ -x "$GATEWAY_EXECUTABLE" ]]; then
    fail "gateway diagnostic command could not start"
fi

if [[ -d "$APP_SUPPORT" ]]; then
    pass "application data directory exists"
    check_mode "$APP_SUPPORT" "700"
    AVAILABLE_KB="$(df -Pk "$APP_SUPPORT" 2>/dev/null | awk 'END { print $4 }')"
    if [[ "$AVAILABLE_KB" =~ ^[0-9]+$ ]]; then
        AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
        pass "approximately ${AVAILABLE_GB} GiB is available"
    else
        warn "could not determine available disk space"
    fi
else
    warn "application data directory does not exist yet; it will be created on first launch"
fi

APP_CONFIG="$APP_SUPPORT/config.json"
if [[ -f "$APP_CONFIG" ]]; then
    if plutil -lint "$APP_CONFIG" >/dev/null 2>&1; then
        pass "app configuration JSON is structurally valid"
    else
        fail "app configuration JSON is invalid"
    fi
    check_mode "$APP_CONFIG" "600"
else
    warn "app configuration does not exist; defaults will be created on first launch"
fi

GATEWAY_CONFIG="$APP_SUPPORT/gateway.json"
if [[ -f "$GATEWAY_CONFIG" ]]; then
    check_mode "$GATEWAY_CONFIG" "600"
    if [[ -x "$GATEWAY_EXECUTABLE" ]] && "$GATEWAY_EXECUTABLE" check-config -config "$GATEWAY_CONFIG"; then
        pass "gateway JSON, TLS identity, hostname, and recordings path are valid"
    else
        fail "gateway configuration validation failed"
    fi
else
    warn "gateway is not configured; remote HTTPS access will stay disabled"
fi

MEDIAMTX_CONFIG="$APP_SUPPORT/Runtime/mediamtx.yml"
if [[ -f "$MEDIAMTX_CONFIG" ]]; then
    check_mode "$MEDIAMTX_CONFIG" "600"
    if [[ -x "$MEDIAMTX_EXECUTABLE" ]] && "$MEDIAMTX_EXECUTABLE" --validate-conf="$MEDIAMTX_CONFIG" >/dev/null 2>&1; then
        pass "generated MediaMTX configuration is valid"
    else
        fail "generated MediaMTX configuration is invalid"
    fi
else
    warn "generated MediaMTX configuration is not present until monitoring starts once"
fi

printf '\nSummary: %d passed, %d warnings, %d failed\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
