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
printf '%s %s\n' "$command_name" "$*" >> "${MACMONITOR_APP_SUPPORT%/*}/gateway-calls.log"
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

: > "$FIXTURE/gateway-calls.log"
bash "$FIXTURE/scripts/configure-gateway.sh" --also-origin https://203.0.113.5:8443 \
    https://192.168.0.7:8443 "$FIXTURE/cert.pem" "$FIXTURE/key.pem" >/dev/null 2>&1 || {
    echo 'FAIL: configure-gateway.sh refused --also-origin'
    exit 1
}
grep -q '^init .*-origin https://192.168.0.7:8443 -also-origin https://203.0.113.5:8443 ' "$FIXTURE/gateway-calls.log" || {
    echo 'FAIL: configure-gateway.sh did not pass --also-origin to the gateway init'
    cat "$FIXTURE/gateway-calls.log"
    exit 1
}
if bash "$FIXTURE/scripts/configure-gateway.sh" --also-origin >/dev/null 2>&1; then
    echo 'FAIL: configure-gateway.sh accepted --also-origin without a value'
    exit 1
fi
echo 'PASS: configure-gateway.sh passes each --also-origin to the gateway'

# Exercise the actual pipelines extracted from both production scripts.
for script in build-app.sh diagnose.sh; do
    # The first -encoders line is the VideoToolbox gate; the audio encoder lines after it only warn.
    check="$(sed -n '/-hide_banner -encoders/ { s/^[[:space:]]*if //; p; q; }' "$ROOT_DIR/scripts/$script")"
    check="${check#"${check%%[![:space:]]*}"}"
    check="${check% || \\}"
    check="${check%; then}"
    [[ -n "$check" ]]
    cat > "$FIXTURE/bin/ffmpeg" <<'SH'
#!/bin/bash
if [[ "$TEST_ENCODERS" != missing ]]; then
    printf ' V..... h264_videotoolbox VideoToolbox H.264 Encoder\n'
    printf ' A....D libopus              libopus Opus (codec opus)\n'
    printf ' A....D aac                  AAC (Advanced Audio Coding)\n'
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
# github.com and the REST API fail independently, as on 2026-11-08 when every release
# download answered 504 while the API served the same assets.
cat > "$FIXTURE/bin/curl" <<'SH'
#!/bin/bash
set -eu
url=""
destination=""
binary=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) destination="$2"; shift 2 ;;
        -H) [[ "$2" != "Accept: application/octet-stream" ]] || binary=1; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
source=""
case "$url" in
    https://github.com/*)
        [[ "${TEST_GITHUB_DOWNLOAD_DOWN:-0}" != 1 ]] || exit 22
        case "$url" in
            */checksums.sha256) source="$TEST_RELEASE_CHECKSUMS" ;;
            */mediamtx_*.tar.gz) source="$TEST_RELEASE_ARCHIVE" ;;
        esac ;;
    https://api.github.com/repos/bluenviron/mediamtx/releases/assets/*)
        [[ "${TEST_GITHUB_API_DOWN:-0}" != 1 ]] || exit 22
        # Without the octet-stream Accept header the API answers with JSON metadata.
        if [[ "$binary" != 1 ]]; then
            printf '{"name":"metadata"}\n' > "$destination"
            exit 0
        fi
        case "$url" in
            */577109429) source="$TEST_RELEASE_CHECKSUMS" ;;
            */577109449) source="$TEST_RELEASE_ARCHIVE" ;;
        esac ;;
esac
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
printf '%s *%s\n' "$release_hash" "${TEST_RELEASE_ARCHIVE##*/}" > "$TEST_RELEASE_CHECKSUMS"
if ! TEST_GITHUB_DOWNLOAD_DOWN=1 bash "$FIXTURE/scripts/fetch-mediamtx.sh" >/dev/null 2>&1; then
    echo 'FAIL: MediaMTX fetch did not fall back to the GitHub API when release downloads failed'
    exit 1
fi
[[ "$("$FIXTURE/vendor/mediamtx/mediamtx" --version)" == v1.21.1 ]]
[[ -f "$FIXTURE/vendor/mediamtx/LICENSE" ]]
echo 'PASS: MediaMTX falls back to the GitHub API when release downloads fail'
printf 'original\n' > "$FIXTURE/vendor/mediamtx/mediamtx"
if TEST_GITHUB_DOWNLOAD_DOWN=1 TEST_GITHUB_API_DOWN=1 bash "$FIXTURE/scripts/fetch-mediamtx.sh" >/dev/null 2>&1; then
    echo 'FAIL: MediaMTX fetch reported success with every download source down'
    exit 1
fi
[[ "$(cat "$FIXTURE/vendor/mediamtx/mediamtx")" == original ]]
echo 'PASS: MediaMTX fetch with every source down preserves the previous binary'

# Uninstall runs against a fixture root and HOME so no real Mac state is read
# or deleted. Every macOS-only tool is mocked and logs the argv it received.
UNINSTALL_ROOT="$FIXTURE/uninstall-root"
UNINSTALL_HOME="$FIXTURE/uninstall-home"
UNINSTALL_LOG="$FIXTURE/uninstall-calls.log"
mkdir -p "$UNINSTALL_ROOT/scripts"
cp "$ROOT_DIR/scripts/uninstall.sh" "$UNINSTALL_ROOT/scripts/"
for tool in osascript pkill launchctl security tccutil sudo; do
    cat > "$FIXTURE/bin/$tool" <<SH
#!/bin/bash
printf '$tool %s\n' "\$*" >> "$UNINSTALL_LOG"
exit 0
SH
    chmod +x "$FIXTURE/bin/$tool"
done
cat > "$FIXTURE/bin/pmset" <<SH
#!/bin/bash
printf 'pmset %s\n' "\$*" >> "$UNINSTALL_LOG"
if [[ "\${1:-}" == "-g" ]]; then
    printf 'Repeating power events:\n'
    [[ "\${TEST_PMSET_REPEAT:-none}" == repeat ]] && printf '  sleep at 23:00PM every day\n'
    printf 'Scheduled power events:\n'
    [[ "\${TEST_PMSET_WAKE:-none}" == wake ]] && printf " [0]  wake at 11/08/2026 14:30:00 by 'MacMonitor'\n"
    exit 0
fi
exit 0
SH
chmod +x "$FIXTURE/bin/pmset"

seed_uninstall() {
    rm -rf "$UNINSTALL_HOME" "$UNINSTALL_ROOT/dist" "$FIXTURE/uninstall-data"
    : > "$UNINSTALL_LOG"
    mkdir -p "$UNINSTALL_HOME/Library/LaunchAgents"
    printf 'agent\n' > "$UNINSTALL_HOME/Library/LaunchAgents/local.macmonitor.app.plist"
    mkdir -p "$UNINSTALL_ROOT/dist/MacMonitor.app/Contents"
    mkdir -p "$FIXTURE/uninstall-data/Recordings" "$FIXTURE/uninstall-data/Diagnostics"
    printf 'config\n' > "$FIXTURE/uninstall-data/config.json"
    printf 'clip\n' > "$FIXTURE/uninstall-data/Recordings/event.mp4"
}

run_uninstall() {
    env HOME="$UNINSTALL_HOME" \
        MACMONITOR_APP_SUPPORT="$FIXTURE/uninstall-data" \
        TEST_PMSET_REPEAT="${1:-none}" \
        TEST_PMSET_WAKE="${2:-none}" \
        MACMONITOR_SUDOERS_DIR="$FIXTURE/sudoers.d" \
        bash "$UNINSTALL_ROOT/scripts/uninstall.sh" --yes </dev/null
}

seed_uninstall
run_uninstall none > "$FIXTURE/uninstall-out.txt" 2>&1 || {
    echo 'FAIL: uninstall reported a failure on a clean fixture'
    cat "$FIXTURE/uninstall-out.txt"
    exit 1
}
[[ -f "$FIXTURE/uninstall-data/Recordings/event.mp4" ]] || {
    echo 'FAIL: uninstall deleted recordings without --recordings'
    exit 1
}
[[ ! -e "$FIXTURE/uninstall-data/config.json" ]] || {
    echo 'FAIL: uninstall left the configuration behind'
    exit 1
}
[[ ! -e "$FIXTURE/uninstall-data/Diagnostics" ]] || {
    echo 'FAIL: uninstall left the diagnostics directory behind'
    exit 1
}
[[ ! -e "$UNINSTALL_HOME/Library/LaunchAgents/local.macmonitor.app.plist" ]] || {
    echo 'FAIL: uninstall left the launch agent behind'
    exit 1
}
[[ ! -e "$UNINSTALL_ROOT/dist/MacMonitor.app" ]] || {
    echo 'FAIL: uninstall left the built app behind'
    exit 1
}
grep -q 'security delete-generic-password' "$UNINSTALL_LOG" || {
    echo 'FAIL: uninstall did not remove the keychain item'
    exit 1
}
echo 'PASS: uninstall clears app state and keeps recordings by default'

# A schedule the user set must never be cancelled on our own initiative.
grep -q 'pmset repeat cancel' "$UNINSTALL_LOG" && {
    echo 'FAIL: uninstall cancelled the power schedule without a repeat entry'
    exit 1
}
seed_uninstall
run_uninstall repeat > /dev/null 2>&1
grep -q 'pmset repeat cancel' "$UNINSTALL_LOG" && {
    echo 'FAIL: uninstall cancelled the power schedule without a separate confirmation'
    exit 1
}
echo 'PASS: uninstall never cancels the machine-wide power schedule unprompted'

seed_uninstall
run_uninstall none > /dev/null 2>&1
rm -rf "$FIXTURE/uninstall-data/Recordings"
run_uninstall none > /dev/null 2>&1 || {
    echo 'FAIL: a second uninstall run reported a failure'
    exit 1
}
[[ ! -e "$FIXTURE/uninstall-data" ]] || {
    echo 'FAIL: uninstall left an empty data directory once recordings were gone'
    exit 1
}
echo 'PASS: uninstall is idempotent and removes the data directory once empty'

seed_uninstall
env HOME="$UNINSTALL_HOME" \
    MACMONITOR_APP_SUPPORT="$FIXTURE/uninstall-data" \
    TEST_PMSET_REPEAT=none \
    bash "$UNINSTALL_ROOT/scripts/uninstall.sh" --yes --recordings </dev/null > /dev/null 2>&1
[[ ! -e "$FIXTURE/uninstall-data" ]] || {
    echo 'FAIL: --recordings left the data directory behind'
    exit 1
}
echo 'PASS: uninstall --recordings removes recorded video too'

# "pkill -f MacMonitor" also matches this script: a double-clicked
# Uninstall MacMonitor.command runs from a path containing the folder name,
# so the uninstall would kill its own shell before finishing.
seed_uninstall
run_uninstall none > /dev/null 2>&1
if grep -q 'pkill -f MacMonitor' "$UNINSTALL_LOG"; then
    echo 'FAIL: uninstall matches its own command line when stopping the app'
    exit 1
fi
grep -q 'pkill -x MacMonitor' "$UNINSTALL_LOG" || {
    echo 'FAIL: uninstall does not stop the app by exact process name'
    exit 1
}
echo 'PASS: uninstall stops the app by name without matching its own path'

# AppleScript "quit" launches an application that is not running, so a plain
# quit would start the very app the uninstall is removing.
seed_uninstall
run_uninstall none > /dev/null 2>&1
if grep -q 'osascript -e quit' "$UNINSTALL_LOG"; then
    echo 'FAIL: uninstall quits the app without checking that it is running'
    exit 1
fi
grep -q 'is running then tell application id "local.macmonitor.app" to quit' "$UNINSTALL_LOG" || {
    echo 'FAIL: uninstall does not quit a running app through osascript'
    exit 1
}
echo 'PASS: uninstall quits the app only when it is running'

# Telegram setup talks to the Bot API only through curl. The mock answers like the API and
# records every URL so the checks can see which calls were made.
TELEGRAM_DATA="$FIXTURE/telegram-data"
TELEGRAM_LOG="$FIXTURE/telegram-calls.log"
export TELEGRAM_LOG
cp "$ROOT_DIR/scripts/configure-telegram.sh" "$FIXTURE/scripts/"
cat > "$FIXTURE/bin/curl" <<'SH'
#!/bin/bash
url=""
for arg in "$@"; do
    case "$arg" in http://*|https://*) url="$arg" ;; esac
done
printf '%s\n' "$url" >> "$TELEGRAM_LOG"
case "$url" in
    */getMe) printf '{"ok":true,"result":{"id":12345,"is_bot":true,"first_name":"Mac","username":"macmonitor_test_bot"}}' ;;
    */getUpdates*)
        if [[ "${TEST_TELEGRAM_UPDATES:-one}" == none ]]; then
            printf '{"ok":true,"result":[]}'
        else
            printf '{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"from":{"id":42,"is_bot":false,"first_name":"J"},"chat":{"id":42,"first_name":"J","type":"private"},"date":1762560000,"text":"hi"}}]}'
        fi ;;
    */sendMessage) printf '{"ok":true,"result":{"message_id":2}}' ;;
    *) exit 22 ;;
esac
SH
chmod +x "$FIXTURE/bin/curl"
TELEGRAM_TOKEN='12345:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
run_telegram() {
    env MACMONITOR_APP_SUPPORT="$TELEGRAM_DATA" bash "$FIXTURE/scripts/configure-telegram.sh" "$@" </dev/null
}

rm -rf "$TELEGRAM_DATA"
: > "$TELEGRAM_LOG"
if run_telegram 'not-a-token' > /dev/null 2>&1; then
    echo 'FAIL: telegram setup accepted a malformed token'
    exit 1
fi
[[ ! -e "$TELEGRAM_DATA/telegram.json" && ! -s "$TELEGRAM_LOG" ]] || {
    echo 'FAIL: telegram setup contacted Telegram or wrote a file for a malformed token'
    exit 1
}
echo 'PASS: telegram setup rejects a malformed token before contacting Telegram'

export TEST_TELEGRAM_UPDATES=none
if run_telegram "$TELEGRAM_TOKEN" > "$FIXTURE/telegram-nochat.txt" 2>&1; then
    echo 'FAIL: telegram setup saved a configuration without any chat'
    exit 1
fi
[[ ! -e "$TELEGRAM_DATA/telegram.json" ]] || {
    echo 'FAIL: telegram setup wrote telegram.json without a chat id'
    exit 1
}
# A silent exit left the owner guessing on 2026-11-08: set -e stopped the script at the empty
# grep before the explanation was printed.
grep -q '봇에 도착한 메시지가 없습니다' "$FIXTURE/telegram-nochat.txt" || {
    echo 'FAIL: telegram setup exited without explaining that no message reached the bot'
    cat "$FIXTURE/telegram-nochat.txt"
    exit 1
}
echo 'PASS: telegram setup refuses to guess a chat and says why'

export TEST_TELEGRAM_UPDATES=one
: > "$TELEGRAM_LOG"
run_telegram "$TELEGRAM_TOKEN" > "$FIXTURE/telegram-out.txt" 2>&1 || {
    echo 'FAIL: telegram setup failed with a valid token and one chat'
    cat "$FIXTURE/telegram-out.txt"
    exit 1
}
grep -q '"chatID": 42' "$TELEGRAM_DATA/telegram.json" || {
    echo 'FAIL: telegram setup did not save the chat it found'
    exit 1
}
grep -q "\"botToken\": \"$TELEGRAM_TOKEN\"" "$TELEGRAM_DATA/telegram.json" || {
    echo 'FAIL: telegram setup did not save the token'
    exit 1
}
grep -q '"viewMinutes": 10' "$TELEGRAM_DATA/telegram.json" || {
    echo 'FAIL: telegram setup did not save the default viewing window'
    exit 1
}
grep -q 'sendMessage' "$TELEGRAM_LOG" || {
    echo 'FAIL: telegram setup did not confirm in the chat'
    exit 1
}
if grep -q "$TELEGRAM_TOKEN" "$FIXTURE/telegram-out.txt"; then
    echo 'FAIL: telegram setup printed the token'
    exit 1
fi
[[ -z "$(find "$TELEGRAM_DATA" -name '.telegram-config.*' -print)" ]] || {
    echo 'FAIL: telegram setup leaked a candidate file'
    exit 1
}
echo 'PASS: telegram setup saves the single chat it finds and confirms in the chat'

# Slim mode leaves a sudoers rule and one-shot wake events behind. Like the repeating
# schedule they need sudo, so --yes must not remove them, and a one-shot MacMonitor wake
# must not be mistaken for a repeating schedule the user set.
mkdir -p "$FIXTURE/sudoers.d"
seed_uninstall
printf 'rule\n' > "$FIXTURE/sudoers.d/macmonitor"
run_uninstall none wake > "$FIXTURE/uninstall-slim.txt" 2>&1 || {
    echo 'FAIL: uninstall failed with slim mode items present'
    cat "$FIXTURE/uninstall-slim.txt"
    exit 1
}
[[ -e "$FIXTURE/sudoers.d/macmonitor" ]] || {
    echo 'FAIL: uninstall removed the sudoers rule without a separate confirmation'
    exit 1
}
if grep -q 'pmset schedule cancel' "$UNINSTALL_LOG"; then
    echo 'FAIL: uninstall cancelled a wake without a separate confirmation'
    exit 1
fi
if grep -q 'repeating power schedule is still set' "$FIXTURE/uninstall-slim.txt"; then
    echo 'FAIL: a one-shot MacMonitor wake was reported as a repeating schedule'
    exit 1
fi
grep -q "by 'MacMonitor'" "$FIXTURE/uninstall-slim.txt" || {
    echo 'FAIL: uninstall did not show the scheduled wake it found'
    exit 1
}
echo 'PASS: uninstall shows slim mode items and leaves them for a confirmed removal'
rm -f "$FIXTURE/sudoers.d/macmonitor"

# The sudoers rule is installed only after visudo accepts it, because a bad file breaks sudo
# for the whole Mac. The sudo mock runs whatever command it is handed.
cp "$ROOT_DIR/scripts/enable-slim-mode.sh" "$FIXTURE/scripts/"
SLIM_LOG="$FIXTURE/slim-calls.log"
export SLIM_LOG
cat > "$FIXTURE/bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$SLIM_LOG"
case "${1:-}" in
    -v) exit 0 ;;
    -n)
        if [[ "${2:-}" == -l ]]; then exit "${TEST_SUDO_RULE_STATUS:-0}"; fi
        shift
        exec "$@" ;;
    *) exec "$@" ;;
esac
SH
cat > "$FIXTURE/bin/visudo" <<'SH'
#!/bin/bash
printf 'visudo %s\n' "$*" >> "$SLIM_LOG"
[[ "${1:-}" == -cf ]] || exit 2
grep -q 'NOPASSWD: /usr/bin/pmset schedule wake \*, /usr/bin/pmset schedule cancel wake \*' "$2" || exit 1
[[ "${TEST_VISUDO:-ok}" == ok ]]
SH
cat > "$FIXTURE/bin/install" <<'SH'
#!/bin/bash
printf 'install %s\n' "$*" >> "$SLIM_LOG"
skip=0
src=""
dst=""
for arg in "$@"; do
    if [[ "$skip" == 1 ]]; then skip=0; continue; fi
    case "$arg" in
        -o|-g|-m) skip=1 ;;
        -*) ;;
        *) src="$dst"; dst="$arg" ;;
    esac
done
cp "$src" "$dst"
SH
chmod +x "$FIXTURE/bin/sudo" "$FIXTURE/bin/visudo" "$FIXTURE/bin/install"
run_slim() {
    env MACMONITOR_SUDOERS_DIR="$FIXTURE/sudoers.d" MACMONITOR_USER=june \
        bash "$FIXTURE/scripts/enable-slim-mode.sh" </dev/null
}

rm -f "$FIXTURE/sudoers.d/macmonitor"
: > "$SLIM_LOG"
export TEST_VISUDO=fail
if run_slim > /dev/null 2>&1; then
    echo 'FAIL: enable-slim-mode installed a rule that visudo rejected'
    exit 1
fi
[[ ! -e "$FIXTURE/sudoers.d/macmonitor" ]] || {
    echo 'FAIL: enable-slim-mode wrote the rule although visudo rejected it'
    exit 1
}
echo 'PASS: enable-slim-mode installs nothing when visudo rejects the rule'

# Under sudo the rule would name root, which the app's `sudo -n` never matches.
if SUDO_USER=someone MACMONITOR_SUDOERS_DIR="$FIXTURE/sudoers.d" PATH="$FIXTURE/bin:$PATH" \
    bash "$FIXTURE/scripts/enable-slim-mode.sh" </dev/null >"$FIXTURE/sudo-run.log" 2>&1; then
    echo 'FAIL: enable-slim-mode ran under sudo instead of refusing'
    exit 1
fi
grep -q "without sudo" "$FIXTURE/sudo-run.log" || { echo 'FAIL: enable-slim-mode did not say to run without sudo'; cat "$FIXTURE/sudo-run.log"; exit 1; }
echo 'PASS: enable-slim-mode refuses to run under sudo'

export TEST_VISUDO=ok
: > "$SLIM_LOG"
run_slim > "$FIXTURE/slim-out.txt" 2>&1 || {
    echo 'FAIL: enable-slim-mode failed with a valid rule'
    cat "$FIXTURE/slim-out.txt"
    exit 1
}
grep -q '^june ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake \*, /usr/bin/pmset schedule cancel wake \*$' "$FIXTURE/sudoers.d/macmonitor" || {
    echo 'FAIL: the installed rule is not the two pmset commands for the user'
    cat "$FIXTURE/sudoers.d/macmonitor"
    exit 1
}
VISUDO_LINE="$(grep -n '^sudo visudo' "$SLIM_LOG" | head -n 1 | cut -d: -f1)"
INSTALL_LINE="$(grep -n '^sudo install' "$SLIM_LOG" | head -n 1 | cut -d: -f1)"
[[ -n "$VISUDO_LINE" && -n "$INSTALL_LINE" && "$VISUDO_LINE" -lt "$INSTALL_LINE" ]] || {
    echo 'FAIL: enable-slim-mode must run visudo before install'
    cat "$SLIM_LOG"
    exit 1
}
echo 'PASS: enable-slim-mode checks the rule with visudo and then installs exactly it'
rm -f "$FIXTURE/sudoers.d/macmonitor"

# --ask reads the token without an argument, so the install can ask for it. The answers come
# from stdin here (printf format, so '' is end of input).
ask_telegram() {
    local answers="$1"
    printf -- "$answers" | env MACMONITOR_APP_SUPPORT="$TELEGRAM_DATA" \
        bash "$FIXTURE/scripts/configure-telegram.sh" --ask
}
TELEGRAM_TOKEN_2='67890:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
rm -rf "$TELEGRAM_DATA"
: > "$TELEGRAM_LOG"
for answers in '\n' ''; do
    ask_telegram "$answers" > "$FIXTURE/ask-out.txt" 2>&1 || {
        echo 'FAIL: --ask must skip, not fail, when no token is given'
        cat "$FIXTURE/ask-out.txt"
        exit 1
    }
    grep -q '건너뜁니다' "$FIXTURE/ask-out.txt" && [[ ! -e "$TELEGRAM_DATA/telegram.json" && ! -s "$TELEGRAM_LOG" ]] || {
        echo 'FAIL: --ask without a token must say it skips, write nothing and contact nobody'
        cat "$FIXTURE/ask-out.txt"
        exit 1
    }
done
echo 'PASS: telegram --ask skips on Return or end of input when nothing is configured'

# A pasted token often carries a trailing space or a Windows line ending.
ask_telegram " $TELEGRAM_TOKEN \r\n" > "$FIXTURE/ask-out.txt" 2>&1 || {
    echo 'FAIL: --ask failed with a valid token'
    cat "$FIXTURE/ask-out.txt"
    exit 1
}
grep -q "\"botToken\": \"$TELEGRAM_TOKEN\"" "$TELEGRAM_DATA/telegram.json" && grep -q '"chatID": 42' "$TELEGRAM_DATA/telegram.json" || {
    echo 'FAIL: --ask did not save the token it was given'
    exit 1
}
if grep -q "$TELEGRAM_TOKEN" "$FIXTURE/ask-out.txt"; then
    echo 'FAIL: --ask printed the token, which would put it in the build log'
    exit 1
fi
echo 'PASS: telegram --ask saves a pasted token without printing it'

cp "$TELEGRAM_DATA/telegram.json" "$FIXTURE/telegram-before.json"
: > "$TELEGRAM_LOG"
ask_telegram '\n' > "$FIXTURE/ask-out.txt" 2>&1 && grep -q '그대로 둡니다' "$FIXTURE/ask-out.txt" &&
    cmp -s "$TELEGRAM_DATA/telegram.json" "$FIXTURE/telegram-before.json" && [[ ! -s "$TELEGRAM_LOG" ]] || {
    echo 'FAIL: --ask must keep an existing configuration on Return'
    cat "$FIXTURE/ask-out.txt"
    exit 1
}
# Three malformed answers end the question; the old configuration stays.
if ask_telegram 'abc\nnot-a-token\n12345:short\n' > "$FIXTURE/ask-out.txt" 2>&1; then
    echo 'FAIL: --ask accepted a malformed token'
    exit 1
fi
cmp -s "$TELEGRAM_DATA/telegram.json" "$FIXTURE/telegram-before.json" && [[ ! -s "$TELEGRAM_LOG" ]] || {
    echo 'FAIL: malformed tokens must not change the configuration or reach Telegram'
    exit 1
}
if grep -q 'not-a-token\|12345:short' "$FIXTURE/ask-out.txt"; then
    echo 'FAIL: --ask echoed what was typed'
    exit 1
fi
# A second try after a malformed first one replaces the configuration.
ask_telegram "oops\n$TELEGRAM_TOKEN_2\n" > "$FIXTURE/ask-out.txt" 2>&1 &&
    grep -q "\"botToken\": \"$TELEGRAM_TOKEN_2\"" "$TELEGRAM_DATA/telegram.json" &&
    ! grep -q "$TELEGRAM_TOKEN" "$TELEGRAM_DATA/telegram.json" || {
    echo 'FAIL: --ask did not replace the configuration with the new token'
    cat "$FIXTURE/ask-out.txt"
    exit 1
}
if grep -q "$TELEGRAM_TOKEN_2" "$FIXTURE/ask-out.txt"; then
    echo 'FAIL: --ask printed the replacement token'
    exit 1
fi
echo 'PASS: telegram --ask keeps the configuration on Return and replaces it with a new token'

# The install runs both owner setups. Neither may fail it: a skipped bot, a bot that got no
# message and a rejected sudoers rule all leave the exit status at 0.
cp "$ROOT_DIR/scripts/install-setup.sh" "$FIXTURE/scripts/"
run_install_setup() {
    local answers="$1"
    printf -- "$answers" | env MACMONITOR_APP_SUPPORT="$TELEGRAM_DATA" MACMONITOR_SUDOERS_DIR="$FIXTURE/sudoers.d" \
        MACMONITOR_USER=june bash "$FIXTURE/scripts/install-setup.sh"
}
rm -rf "$TELEGRAM_DATA"
rm -f "$FIXTURE/sudoers.d/macmonitor"
: > "$SLIM_LOG"
run_install_setup "$TELEGRAM_TOKEN\n" > "$FIXTURE/setup-out.txt" 2>&1 || {
    echo 'FAIL: install setup failed on a first install'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}
grep -q "\"botToken\": \"$TELEGRAM_TOKEN\"" "$TELEGRAM_DATA/telegram.json" &&
    grep -q '^june ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake' "$FIXTURE/sudoers.d/macmonitor" || {
    echo 'FAIL: a first install must save the bot and install the slim mode rule'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}
if grep -q "$TELEGRAM_TOKEN" "$FIXTURE/setup-out.txt"; then
    echo 'FAIL: install setup printed the token'
    exit 1
fi
echo 'PASS: install setup configures the bot and the slim mode rule on a first install'

cp "$TELEGRAM_DATA/telegram.json" "$FIXTURE/telegram-before.json"
: > "$SLIM_LOG"
: > "$TELEGRAM_LOG"
run_install_setup '\n' > "$FIXTURE/setup-out.txt" 2>&1 &&
    cmp -s "$TELEGRAM_DATA/telegram.json" "$FIXTURE/telegram-before.json" && [[ ! -s "$TELEGRAM_LOG" ]] &&
    grep -q '이미 설치되어 있습니다' "$FIXTURE/setup-out.txt" || {
    echo 'FAIL: a repeated install must keep the bot on Return and skip the installed rule'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}
if grep -q '^sudo -v\|^sudo install\|^install ' "$SLIM_LOG"; then
    echo 'FAIL: a repeated install asked for the password or reinstalled the rule'
    cat "$SLIM_LOG"
    exit 1
fi
echo 'PASS: install setup changes nothing on a repeated install'

# A rule file that sudo does not accept (written for another account) is installed again.
: > "$SLIM_LOG"
TEST_SUDO_RULE_STATUS=1 run_install_setup '\n' > "$FIXTURE/setup-out.txt" 2>&1 || {
    echo 'FAIL: install setup must exit 0 when the rule is not accepted afterwards'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}
grep -q '^sudo install' "$SLIM_LOG" && grep -q '설치하지 못했습니다' "$FIXTURE/setup-out.txt" || {
    echo 'FAIL: install setup must retry a rule sudo rejects and report that it still fails'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}

rm -rf "$TELEGRAM_DATA"
rm -f "$FIXTURE/sudoers.d/macmonitor"
: > "$SLIM_LOG"
TEST_TELEGRAM_UPDATES=none TEST_VISUDO=fail run_install_setup "$TELEGRAM_TOKEN\n" > "$FIXTURE/setup-out.txt" 2>&1 || {
    echo 'FAIL: install setup must exit 0 when both steps fail'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}
[[ ! -e "$TELEGRAM_DATA/telegram.json" && ! -e "$FIXTURE/sudoers.d/macmonitor" ]] &&
    grep -q '텔레그램 설정을 마치지 못했습니다' "$FIXTURE/setup-out.txt" &&
    grep -q '^sudo visudo' "$SLIM_LOG" && grep -q '슬림 모드 권한을 설치하지 못했습니다' "$FIXTURE/setup-out.txt" || {
    echo 'FAIL: a failed bot setup must be reported and must not stop the slim mode step'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}
echo 'PASS: install setup reports a failed step and still finishes'

# Control-C reaches every process of the terminal. The step in progress dies of it; the setup
# itself must go on to the next step. The stand-in step interrupts its caller the same way.
INTERRUPT="$FIXTURE/interrupt"
mkdir -p "$INTERRUPT"
cp "$ROOT_DIR/scripts/install-setup.sh" "$INTERRUPT/"
cat > "$INTERRUPT/configure-telegram.sh" <<'SH'
#!/bin/bash
kill -INT "$PPID"
kill -INT "$$"
sleep 5
SH
cat > "$INTERRUPT/enable-slim-mode.sh" <<'SH'
#!/bin/bash
echo 'slim step ran'
SH
rm -f "$FIXTURE/sudoers.d/macmonitor"
env MACMONITOR_SUDOERS_DIR="$FIXTURE/sudoers.d" bash "$INTERRUPT/install-setup.sh" </dev/null > "$FIXTURE/setup-out.txt" 2>&1 &&
    grep -q '텔레그램 설정을 마치지 못했습니다' "$FIXTURE/setup-out.txt" && grep -q 'slim step ran' "$FIXTURE/setup-out.txt" || {
    echo 'FAIL: Control-C during the bot step must be reported and must not end the whole setup'
    cat "$FIXTURE/setup-out.txt"
    exit 1
}
echo 'PASS: install setup survives Control-C in a step and runs the next one'

# Hiding what is typed needs a terminal, which these checks do not have, so the option itself
# is checked: without -s the pasted token would show in the window.
grep -q '^        IFS= read -r -s TOKEN' "$ROOT_DIR/scripts/configure-telegram.sh" || {
    echo 'FAIL: --ask must read the token with read -s'
    exit 1
}

# The double-click build asks only at a terminal, before the app starts, and cannot fail on it.
BUILD_COMMAND="$ROOT_DIR/Build MacMonitor.command"
SETUP_LINE="$(grep -n 'scripts/install-setup.sh" || true' "$BUILD_COMMAND" | head -n 1 | cut -d: -f1)"
OPEN_LINE="$(grep -n '^/usr/bin/open ' "$BUILD_COMMAND" | head -n 1 | cut -d: -f1)"
DIAGNOSE_LINE="$(grep -n 'scripts/diagnose.sh"$' "$BUILD_COMMAND" | head -n 1 | cut -d: -f1)"
[[ -n "$SETUP_LINE" && -n "$OPEN_LINE" && -n "$DIAGNOSE_LINE" && "$DIAGNOSE_LINE" -lt "$SETUP_LINE" && "$SETUP_LINE" -lt "$OPEN_LINE" ]] &&
    sed -n "$((SETUP_LINE - 3)),${SETUP_LINE}p" "$BUILD_COMMAND" | grep -q '^if \[\[ -t 0 \]\]; then$' || {
    echo 'FAIL: the build must run install-setup.sh after the diagnosis, before opening the app, only at a terminal'
    exit 1
}
echo 'PASS: the one-click build runs the owner setup at a terminal between diagnosis and launch'
unset TEST_VISUDO

# Same-Wi-Fi HTTPS setup. Every macOS tool it uses is mocked, and configure-gateway.sh is a
# stub that records its arguments and writes the gateway.json keys the setup reads back.
LAN="$FIXTURE/lan"
LAN_DATA="$LAN/data"
LAN_LOG="$LAN/calls.log"
export LAN_LOG
mkdir -p "$LAN/scripts" "$LAN/bin"
cp "$ROOT_DIR/scripts/setup-lan-https.sh" "$LAN/scripts/"
cat > "$LAN/scripts/configure-gateway.sh" <<'SH'
#!/bin/bash
set -eu
also=()
while [[ "$1" == --also-origin ]]; do also+=("$2"); shift 2; done
printf 'configure %s|%s|%s\n' "$1" "$2" "$3" >> "$LAN_LOG"
for origin in ${also[@]+"${also[@]}"}; do printf 'also %s\n' "$origin" >> "$LAN_LOG"; done
[[ "${TEST_CONFIGURE_FAIL:-0}" != 1 ]] || exit 1
mkdir -p "$MACMONITOR_APP_SUPPORT"
{
    printf '{\n  "listenAddress": ":8443",\n  "tlsCertificateFile": "%s",\n  "tlsPrivateKeyFile": "%s",\n  "publicOrigin": "%s",\n' "$2" "$3" "$1"
    if [[ ${#also[@]} -gt 0 ]]; then
        printf '  "additionalOrigins": [\n'
        printf '    "%s"\n' "${also[@]}"
        printf '  ],\n'
    fi
    printf '  "mediaMTXURL": "http://127.0.0.1:8889"\n}\n'
} > "$MACMONITOR_APP_SUPPORT/gateway.json"
SH
cat > "$LAN/bin/route" <<'SH'
#!/bin/bash
[[ -n "${TEST_ROUTE_IFACE:-}" ]] || exit 1
printf '   route to: default\n  interface: %s\n' "$TEST_ROUTE_IFACE"
SH
cat > "$LAN/bin/ipconfig" <<'SH'
#!/bin/bash
[[ "$1" == getifaddr && "$2" == "${TEST_LAN_IFACE:-none}" ]] || exit 1
printf '%s\n' "$TEST_LAN_IP"
SH
cat > "$LAN/bin/openssl" <<'SH'
#!/bin/bash
set -eu
case "$1" in
    req)
        key="" out="" cnf="" days=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -keyout) key="$2"; shift 2 ;;
                -out) out="$2"; shift 2 ;;
                -config) cnf="$2"; shift 2 ;;
                -days) days="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        printf 'req days=%s\n' "$days" >> "$LAN_LOG"
        cat "$cnf" >> "$LAN_LOG"
        printf 'KEY\n' > "$key"
        printf 'CERT\n' > "$out" ;;
    x509)
        printf 'x509 %s\n' "$*" >> "$LAN_LOG"
        exit "${TEST_CERT_EXPIRING:-0}" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$LAN/scripts/"*.sh "$LAN/bin/"*
# Leading NAME=value arguments become the mocks' settings; the rest go to the script. The
# array expansion form keeps macOS bash 3.2 quiet about an empty array under set -u.
run_lan() {
    local settings=()
    while [[ $# -gt 0 && "$1" == TEST_*=* ]]; do settings+=("$1"); shift; done
    env PATH="$LAN/bin:$PATH" MACMONITOR_APP_SUPPORT="$LAN_DATA" ${settings[@]+"${settings[@]}"} \
        bash "$LAN/scripts/setup-lan-https.sh" "$@" </dev/null
}
configure_count() { grep -c '^configure ' "$LAN_LOG" || true; }
: > "$LAN_LOG"

if run_lan TEST_LAN_IFACE=none > "$LAN/out.txt" 2>&1; then
    echo 'FAIL: LAN setup succeeded without any network address'
    exit 1
fi
grep -q '네트워크 주소를 찾지 못했습니다' "$LAN/out.txt" && [[ ! -e "$LAN_DATA/gateway.json" && "$(configure_count)" == 0 ]] || {
    echo 'FAIL: LAN setup without an address must explain and write nothing'
    cat "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup explains a missing network address and writes nothing'

run_lan TEST_ROUTE_IFACE=en1 TEST_LAN_IFACE=en1 TEST_LAN_IP=192.168.0.7 > "$LAN/out.txt" 2>&1 || {
    echo 'FAIL: first LAN setup failed'
    cat "$LAN/out.txt"
    exit 1
}
grep -q '^configure https://192.168.0.7:8443|'"$LAN_DATA"'/LAN-HTTPS/[0-9A-Za-z-]*/cert.pem|'"$LAN_DATA"'/LAN-HTTPS/[0-9A-Za-z-]*/key.pem$' "$LAN_LOG" &&
    grep -q '^subjectAltName = IP:192.168.0.7$' "$LAN_LOG" && grep -q '^extendedKeyUsage = serverAuth$' "$LAN_LOG" &&
    grep -q '^req days=365$' "$LAN_LOG" && grep -q 'https://192.168.0.7:8443' "$LAN/out.txt" &&
    grep -q '웹: 외부 TCP 8443 → 이 Mac의 TCP 8443' "$LAN/out.txt" && grep -q 'https://공인IP:8443' "$LAN/out.txt" &&
    grep -q 'Tailscale(권장)' "$LAN/out.txt" && grep -q '경고가 다시 나오면 진행하지 마세요' "$LAN/out.txt" || {
    echo 'FAIL: first LAN setup did not use the default-route address, a server certificate and the gateway setup'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup certifies the default-route address and configures the gateway with it'

run_lan TEST_ROUTE_IFACE=en1 TEST_LAN_IFACE=en1 TEST_LAN_IP=192.168.0.7 > "$LAN/out.txt" 2>&1 || {
    echo 'FAIL: repeated LAN setup failed'
    cat "$LAN/out.txt"
    exit 1
}
[[ "$(configure_count)" == 1 ]] && grep -q '이미 이 주소로 설정되어 있습니다' "$LAN/out.txt" && grep -q 'https://192.168.0.7:8443' "$LAN/out.txt" || {
    echo 'FAIL: an unchanged address must only print the address, without asking for the password again'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup with an unchanged address and a valid certificate only prints the address'

run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.9 > "$LAN/out.txt" 2>&1 || {
    echo 'FAIL: LAN setup after an address change failed'
    cat "$LAN/out.txt"
    exit 1
}
grep -q '^configure https://192.168.0.9:8443|' "$LAN_LOG" && grep -q '주소가 바뀌었습니다' "$LAN/out.txt" &&
    [[ "$(configure_count)" == 2 && "$(find "$LAN_DATA/LAN-HTTPS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 1 ]] || {
    echo 'FAIL: an address change must certify the new address and keep only the certificate in use'
    cat "$LAN_LOG" "$LAN/out.txt"
    ls -R "$LAN_DATA/LAN-HTTPS"
    exit 1
}
echo 'PASS: LAN setup follows an address change and removes the old certificate'

run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.9 TEST_CERT_EXPIRING=1 > "$LAN/out.txt" 2>&1 || {
    echo 'FAIL: LAN setup with an expiring certificate failed'
    cat "$LAN/out.txt"
    exit 1
}
[[ "$(configure_count)" == 3 ]] || {
    echo 'FAIL: a certificate expiring within 30 days must be renewed'
    cat "$LAN_LOG"
    exit 1
}
echo 'PASS: LAN setup renews a certificate that expires within 30 days'

cp "$LAN_DATA/gateway.json" "$LAN/gateway-before.json"
if run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.11 TEST_CONFIGURE_FAIL=1 > "$LAN/out.txt" 2>&1; then
    echo 'FAIL: LAN setup reported success when the gateway setup failed'
    exit 1
fi
cmp -s "$LAN_DATA/gateway.json" "$LAN/gateway-before.json" &&
    [[ "$(find "$LAN_DATA/LAN-HTTPS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 1 ]] &&
    grep -q '기존 설정은 그대로입니다' "$LAN/out.txt" || {
    echo 'FAIL: a failed gateway setup must keep the working configuration and its certificate'
    cat "$LAN/out.txt"
    ls -R "$LAN_DATA/LAN-HTTPS"
    exit 1
}
echo 'PASS: a failed LAN setup keeps the working configuration and certificate'

printf '{\n  "tlsCertificateFile": "/etc/ssl/camera.pem",\n  "publicOrigin": "https://camera.example.net:8443"\n}\n' > "$LAN_DATA/gateway.json"
before="$(configure_count)"
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.9 > "$LAN/out.txt" 2>&1 || {
    echo 'FAIL: LAN setup failed beside a domain configuration'
    cat "$LAN/out.txt"
    exit 1
}
[[ "$(configure_count)" == "$before" ]] && grep -q 'camera.example.net' "$LAN_DATA/gateway.json" && grep -q '도메인' "$LAN/out.txt" || {
    echo 'FAIL: LAN setup replaced a domain configuration without being asked'
    cat "$LAN/out.txt"
    exit 1
}
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.9 --replace > "$LAN/out.txt" 2>&1 &&
    [[ "$(configure_count)" == "$((before + 1))" ]] || {
    echo 'FAIL: --replace did not switch a domain configuration to the LAN address'
    cat "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup leaves a domain configuration alone unless --replace is given'

# Outside access: one external address beside the home Wi-Fi one. The setup names both in the
# certificate and passes the external one to the gateway, and keeps it on later runs.
also_count() { grep -c '^also ' "$LAN_LOG" || true; }
before="$(configure_count)"
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.9 --external 203.0.113.5 > "$LAN/out.txt" 2>&1 || {
    echo 'FAIL: LAN setup with an external address failed'
    cat "$LAN/out.txt"
    exit 1
}
[[ "$(configure_count)" == "$((before + 1))" ]] && [[ "$(tail -n 1 "$LAN_LOG")" == 'also https://203.0.113.5:8443' ]] &&
    grep -q '^subjectAltName = IP:192.168.0.9, IP:203.0.113.5$' "$LAN_LOG" &&
    grep -q '"https://203.0.113.5:8443"' "$LAN_DATA/gateway.json" &&
    grep -q 'https://192.168.0.9:8443' "$LAN/out.txt" && grep -q '밖(휴대폰 데이터망)에서는 여세요: *https://203.0.113.5:8443' "$LAN/out.txt" &&
    grep -q '공유기 포트포워딩: 이 Mac(192.168.0.9)으로' "$LAN/out.txt" && grep -q '웹: 외부 TCP 8443 → 이 Mac의 TCP 8443' "$LAN/out.txt" &&
    ! grep -q 'https://공인IP' "$LAN/out.txt" || {
    echo 'FAIL: an external address must be certified, allowed by the gateway and explained'
    cat "$LAN_LOG" "$LAN/out.txt" "$LAN_DATA/gateway.json"
    exit 1
}
echo 'PASS: LAN setup certifies and allows an external address beside the home address'

before="$(configure_count)"
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.9 > "$LAN/out.txt" 2>&1 &&
    [[ "$(configure_count)" == "$before" ]] && grep -q '이미 이 주소로 설정되어 있습니다' "$LAN/out.txt" &&
    grep -q 'https://203.0.113.5:8443' "$LAN/out.txt" || {
    echo 'FAIL: a run without options must keep the external address and ask nothing'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 > "$LAN/out.txt" 2>&1 &&
    [[ "$(configure_count)" == "$((before + 1))" ]] && [[ "$(tail -n 1 "$LAN_LOG")" == 'also https://203.0.113.5:8443' ]] &&
    grep -q '^configure https://192.168.0.12:8443|' "$LAN_LOG" &&
    grep -q '^subjectAltName = IP:192.168.0.12, IP:203.0.113.5$' "$LAN_LOG" || {
    echo 'FAIL: a home address change must keep the external address'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup keeps the external address across reruns and home address changes'

before="$(configure_count)"
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 --external=HTTPS://Cam.Example.net:443/ > "$LAN/out.txt" 2>&1 &&
    [[ "$(configure_count)" == "$((before + 1))" ]] && [[ "$(tail -n 1 "$LAN_LOG")" == 'also https://cam.example.net' ]] &&
    grep -q '^subjectAltName = IP:192.168.0.12, DNS:cam.example.net$' "$LAN_LOG" &&
    grep -q '밖에서 쓸 주소가 바뀝니다: https://203.0.113.5:8443 → https://cam.example.net' "$LAN/out.txt" &&
    grep -q '웹: 외부 TCP 443 → ' "$LAN/out.txt" || {
    echo 'FAIL: a DDNS name with port 443 must become https://cam.example.net with a DNS name in the certificate'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup reads a DDNS name typed as a URL and certifies it by name'

cp "$LAN_DATA/gateway.json" "$LAN/gateway-before.json"
before="$(configure_count)"
for bad in 'bad host!' 203.0.113.300 203.0.113.010 0xcb.0.113.10 cam.example.123 cam.example.net:70000 cam.example.net:0 localhost \
    192.168.0.12 192.168.0.12:8443 192.168.0.1 10.0.0.1 172.20.1.1 127.0.0.1 169.254.1.1 0.1.2.3 224.0.0.1 \
    2001:db8::1 '[2001:db8::1]:8443' 'https://cam.example.net/live' '-'; do
    if run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 --external "$bad" > "$LAN/out.txt" 2>&1; then
        echo "FAIL: LAN setup accepted the external address '$bad'"
        cat "$LAN/out.txt"
        exit 1
    fi
    [[ "$(configure_count)" == "$before" ]] && cmp -s "$LAN_DATA/gateway.json" "$LAN/gateway-before.json" || {
        echo "FAIL: a refused external address '$bad' changed the configuration"
        exit 1
    }
done
if run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 --external > "$LAN/out.txt" 2>&1; then
    echo 'FAIL: --external without an address was accepted'
    exit 1
fi
echo 'PASS: LAN setup refuses unreadable external addresses and changes nothing'

before="$(configure_count)"
before_also="$(also_count)"
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 --no-external > "$LAN/out.txt" 2>&1 &&
    [[ "$(configure_count)" == "$((before + 1))" && "$(also_count)" == "$before_also" ]] &&
    ! grep -q additionalOrigins "$LAN_DATA/gateway.json" &&
    grep -q '^subjectAltName = IP:192.168.0.12$' "$LAN_LOG" &&
    grep -q '밖에서 쓸 주소가 바뀝니다: https://cam.example.net → 없음' "$LAN/out.txt" &&
    ! grep -q '밖(휴대폰 데이터망)에서는' "$LAN/out.txt" || {
    echo 'FAIL: --no-external must remove the external address'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup removes the external address with --no-external'

grep -q 'IPv6 주소는 지원하지 않습니다' <(run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 --external 2001:db8::1 2>&1 || true) &&
    grep -q 'curl -4 -s https://ifconfig.me' <(run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 --external 192.168.0.1 2>&1 || true) || {
    echo 'FAIL: an IPv6 or home address must be refused with a reason the owner can act on'
    exit 1
}
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 --external 100.70.1.2 > "$LAN/out.txt" 2>&1 &&
    [[ "$(tail -n 1 "$LAN_LOG")" == 'also https://100.70.1.2:8443' ]] && grep -q 'CGNAT' "$LAN/out.txt" &&
    grep -q '휴대폰과 Mac 모두 Tailscale을 켜 두면 됩니다' "$LAN/out.txt" && ! grep -q '2) 공유기 포트포워딩' "$LAN/out.txt" || {
    echo 'FAIL: a 100.64/10 address must be accepted with a carrier-NAT warning'
    cat "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup explains refused IPv6 and home addresses and warns about carrier NAT'

run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.12 > "$LAN/out.txt" 2>&1 && ! grep -q '밖에서 쓸 주소:' "$LAN/out.txt" || {
    echo 'FAIL: the setup must not ask for an external address'
    cat "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup asks nothing about outside access'

# Several external addresses written by hand survive a home address change, and a home
# address listed among them is dropped instead of being certified as external.
write_gateway() {
    {
        printf '{\n  "tlsCertificateFile": "%s",\n  "publicOrigin": "%s",\n' "$LAN/cert.pem" "$1"
        shift
        printf '  "additionalOrigins": [\n'
        local index=0
        for origin in "$@"; do
            index=$((index + 1))
            if [[ $index -lt $# ]]; then printf '    "%s",\n' "$origin"; else printf '    "%s"\n' "$origin"; fi
        done
        printf '  ]\n}\n'
    } > "$LAN_DATA/gateway.json"
}
write_gateway https://192.168.0.12:8443 https://203.0.113.5:8443 https://cam.example.net https://192.168.0.7:8443
before="$(configure_count)"
before_also="$(also_count)"
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.20 > "$LAN/out.txt" 2>&1 &&
    [[ "$(configure_count)" == "$((before + 1))" && "$(also_count)" == "$((before_also + 2))" ]] &&
    [[ "$(tail -n 2 "$LAN_LOG" | tr '\n' ' ')" == 'also https://203.0.113.5:8443 also https://cam.example.net ' ]] &&
    grep -q '^subjectAltName = IP:192.168.0.20, IP:203.0.113.5, DNS:cam.example.net$' "$LAN_LOG" &&
    grep -q '집 안 주소 https://192.168.0.7:8443 는 밖에서 쓸 주소에서 뺍니다' "$LAN/out.txt" &&
    grep -q '웹: 외부 TCP 8443 → ' "$LAN/out.txt" && grep -q '웹: 외부 TCP 443 → ' "$LAN/out.txt" || {
    echo 'FAIL: a rerun must keep every external address and drop listed home addresses'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup keeps every external address and drops home addresses listed among them'

# Switching a domain configuration to the home address keeps the domain for outside use. A
# home address listed with the domain (the documented --also-origin example) is dropped
# instead of stopping the run as "the same as the home address".
write_gateway https://cam.example.com:8443 https://192.168.0.20:8443
before="$(configure_count)"
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.20 --replace > "$LAN/out.txt" 2>&1 &&
    [[ "$(configure_count)" == "$((before + 1))" && "$(tail -n 1 "$LAN_LOG")" == 'also https://cam.example.com:8443' ]] &&
    grep -q '^configure https://192.168.0.20:8443|' "$LAN_LOG" &&
    grep -q '^subjectAltName = IP:192.168.0.20, DNS:cam.example.com$' "$LAN_LOG" &&
    grep -q '도메인 주소 https://cam.example.com:8443 는 밖에서 쓸 주소로 남깁니다' "$LAN/out.txt" || {
    echo 'FAIL: --replace must keep the replaced domain as an external address'
    cat "$LAN_LOG" "$LAN/out.txt"
    exit 1
}
write_gateway https://cam.example.com:8443 https://192.168.0.20:8443
run_lan TEST_LAN_IFACE=en0 TEST_LAN_IP=192.168.0.20 --replace --no-external > "$LAN/out.txt" 2>&1 &&
    ! grep -q additionalOrigins "$LAN_DATA/gateway.json" || {
    echo 'FAIL: --replace --no-external must leave no external address'
    cat "$LAN/out.txt"
    exit 1
}
echo 'PASS: LAN setup keeps a replaced domain for outside use unless --no-external is given'
