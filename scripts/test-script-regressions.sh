#!/bin/bash
# Portable regression checks. Helpers are simulated; no real app data is touched.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/scripts" "$FIXTURE/bin" "$FIXTURE/dist/MacMonitor.app/Contents/Helpers"
cp "$ROOT_DIR/scripts/configure-gateway.sh" "$FIXTURE/scripts/"
cp "$ROOT_DIR/scripts/fetch-mediamtx.sh" "$FIXTURE/scripts/"
export MACMONITOR_APP_SUPPORT="$FIXTURE/data"
export PATH="$FIXTURE/bin:$PATH"

# Only BSD stat's permission query needs mocking on Linux/Windows.
cat > "$FIXTURE/bin/stat" <<'SH'
#!/bin/bash
printf '600\n'
SH
cat > "$FIXTURE/dist/MacMonitor.app/Contents/Helpers/macmonitor-gateway" <<'SH'
#!/bin/bash
set -eu
command_name="$1"
shift
candidate=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -output|-config) candidate="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ "$candidate" != "$MACMONITOR_APP_SUPPORT/gateway.json" ]] || exit 90
case "$command_name" in
    init)
        printf 'candidate\n' > "$candidate"
        [[ "$TEST_FAILURE" != init ]]
        ;;
    check-config)
        [[ "$(cat "$candidate")" == candidate ]]
        [[ "$TEST_FAILURE" != validation ]]
        ;;
    *) exit 91 ;;
esac
SH
chmod +x "$FIXTURE/bin/stat" "$FIXTURE/dist/MacMonitor.app/Contents/Helpers/macmonitor-gateway"
touch "$FIXTURE/cert.pem" "$FIXTURE/key.pem"
mkdir -p "$MACMONITOR_APP_SUPPORT"

run_configure() {
    bash "$FIXTURE/scripts/configure-gateway.sh" \
        https://camera.example "$FIXTURE/cert.pem" "$FIXTURE/key.pem" >/dev/null 2>&1
}
assert_no_candidate() {
    local leftovers
    leftovers="$(find "$MACMONITOR_APP_SUPPORT" -name '.gateway-config.*' -print)"
    [[ -z "$leftovers" ]] || { echo 'FAIL: candidate leaked'; exit 1; }
}
for failure in init validation; do
    printf 'original\n' > "$MACMONITOR_APP_SUPPORT/gateway.json"
    export TEST_FAILURE="$failure"
    if run_configure; then
        echo "FAIL: $failure failure reported success"
        exit 1
    fi
    [[ "$(cat "$MACMONITOR_APP_SUPPORT/gateway.json")" == original ]]
    assert_no_candidate
    echo "PASS: $failure failure preserves original configuration"
done
rm "$MACMONITOR_APP_SUPPORT/gateway.json"
export TEST_FAILURE=validation
if run_configure; then exit 1; fi
[[ ! -e "$MACMONITOR_APP_SUPPORT/gateway.json" ]]
assert_no_candidate
echo 'PASS: failed first setup does not publish a configuration'

printf 'original\n' > "$MACMONITOR_APP_SUPPORT/gateway.json"
export TEST_FAILURE=none
run_configure
[[ "$(cat "$MACMONITOR_APP_SUPPORT/gateway.json")" == candidate ]]
assert_no_candidate
echo 'PASS: valid candidate replaces original configuration'

# Exercise the actual pipelines extracted from both production scripts.
for script in build-app.sh diagnose.sh; do
    check="$(sed -n '/-hide_banner -encoders/ { s/^[[:space:]]*if //; p; }' "$ROOT_DIR/scripts/$script")"
    check="${check#"${check%%[![:space:]]*}"}"
    check="${check% || \\}"
    check="${check%; then}"
    [[ -n "$check" ]]
    cat > "$FIXTURE/bin/ffmpeg" <<'SH'
#!/bin/bash
if [[ "$TEST_ENCODERS" != missing ]]; then
    printf ' V..... h264_videotoolbox VideoToolbox H.264 Encoder\n'
fi
awk 'BEGIN { for (i=0; i<100000; i++) print " V..... other_encoder Additional encoder entry" }'
[[ "$TEST_ENCODERS" != failure ]]
SH
    chmod +x "$FIXTURE/bin/ffmpeg"
    export FFMPEG_PATH="$FIXTURE/bin/ffmpeg"
    export TEST_ENCODERS=present
    bash -o pipefail -c "$check"
    for mode in missing failure; do
        export TEST_ENCODERS="$mode"
        if bash -o pipefail -c "$check"; then
            echo "FAIL: $script accepted $mode"
            exit 1
        fi
    done
    echo "PASS: $script handles long encoder output, missing encoder, and command failure"
done

# Xcode 14's swift-driver writes its own version to stderr without a newline,
# so a terminal shows it joined to the Swift version line.
cat > "$FIXTURE/bin/swift" <<'SH'
#!/bin/bash
if [[ "$TEST_SWIFT_OUTPUT" == split ]]; then
    printf 'swift-driver version: 1.62.15 ' >&2
else
    printf 'swift-driver version: 1.62.15 '
fi
printf 'Apple Swift version 5.7.2 (swiftlang-5.7.2.135.5 clang-1400.0.29.51)\n'
printf 'Target: x86_64-apple-macosx12.0\n'
SH
chmod +x "$FIXTURE/bin/swift"
for script in build-app.sh diagnose.sh; do
    check="$(grep -F -m 1 'SWIFT_VERSION="$(swift --version' "$ROOT_DIR/scripts/$script")"
    check="${check#"${check%%[![:space:]]*}"}"
    [[ -n "$check" ]]
    for mode in split joined; do
        export TEST_SWIFT_OUTPUT="$mode"
        if [[ "$(bash -o pipefail -c "$check; printf '%s' \"\$SWIFT_VERSION\"" 2>&1)" != 5.7.2 ]]; then
            echo "FAIL: $script misread or leaked the Xcode 14.2 Swift version ($mode)"
            exit 1
        fi
    done
    echo "PASS: $script reads the Swift version from Xcode 14.2 output without leaking it"
done

# lipo reads every argument after -verify_arch as an architecture name.
if grep -n 'lipo -verify_arch' "$ROOT_DIR/scripts/build-app.sh" "$ROOT_DIR/scripts/diagnose.sh"; then
    echo 'FAIL: lipo -verify_arch must follow the input file'
    exit 1
fi
echo 'PASS: lipo -verify_arch calls name the input file first'

# Exercise the release download/checksum path without network access. The
# official release uses sha256sum -b, which prefixes archive names with '*'.
mkdir -p "$FIXTURE/downloads" "$FIXTURE/archive"
printf '#!/bin/bash\nprintf "v1.21.1\\n"\n' > "$FIXTURE/archive/mediamtx"
printf 'test license\n' > "$FIXTURE/archive/LICENSE"
export TEST_RELEASE_ARCHIVE="$FIXTURE/downloads/mediamtx_v1.21.1_darwin_amd64.tar.gz"
export TEST_RELEASE_CHECKSUMS="$FIXTURE/downloads/checksums.sha256"
tar -czf "$TEST_RELEASE_ARCHIVE" -C "$FIXTURE/archive" mediamtx LICENSE
if command -v shasum >/dev/null 2>&1; then
    release_hash="$(shasum -a 256 "$TEST_RELEASE_ARCHIVE" | awk '{ print $1 }')"
else
    release_hash="$(sha256sum "$TEST_RELEASE_ARCHIVE" | awk '{ print $1 }')"
    # Git Bash has sha256sum, while macOS provides shasum.
    cat > "$FIXTURE/bin/shasum" <<'SH'
#!/bin/bash
[[ "$1" == -a && "$2" == 256 ]] || exit 1
sha256sum "$3"
SH
    chmod +x "$FIXTURE/bin/shasum"
fi
cat > "$FIXTURE/bin/curl" <<'SH'
#!/bin/bash
set -eu
source=""
destination=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) destination="$2"; shift 2 ;;
        https://*/checksums.sha256) source="$TEST_RELEASE_CHECKSUMS"; shift ;;
        https://*/mediamtx_*.tar.gz) source="$TEST_RELEASE_ARCHIVE"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$source" && -n "$destination" ]] || exit 1
cp "$source" "$destination"
SH
chmod +x "$FIXTURE/bin/curl"
for marker in '*' ''; do
    printf '%s %s%s\n' "$release_hash" "$marker" "${TEST_RELEASE_ARCHIVE##*/}" > "$TEST_RELEASE_CHECKSUMS"
    bash "$FIXTURE/scripts/fetch-mediamtx.sh" >/dev/null
    [[ "$("$FIXTURE/vendor/mediamtx/mediamtx" --version)" == v1.21.1 ]]
    [[ -f "$FIXTURE/vendor/mediamtx/LICENSE" ]]
done
echo 'PASS: MediaMTX accepts upstream binary and text checksum formats'
printf 'original\n' > "$FIXTURE/vendor/mediamtx/mediamtx"
printf '%064d *%s\n' 0 "${TEST_RELEASE_ARCHIVE##*/}" > "$TEST_RELEASE_CHECKSUMS"
if bash "$FIXTURE/scripts/fetch-mediamtx.sh" >/dev/null 2>&1; then
    echo 'FAIL: MediaMTX accepted a checksum mismatch'
    exit 1
fi
[[ "$(cat "$FIXTURE/vendor/mediamtx/mediamtx")" == original ]]
echo 'PASS: MediaMTX checksum mismatch preserves the previous binary'
