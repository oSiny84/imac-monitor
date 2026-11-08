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
if run_telegram "$TELEGRAM_TOKEN" > /dev/null 2>&1; then
    echo 'FAIL: telegram setup saved a configuration without any chat'
    exit 1
fi
[[ ! -e "$TELEGRAM_DATA/telegram.json" ]] || {
    echo 'FAIL: telegram setup wrote telegram.json without a chat id'
    exit 1
}
echo 'PASS: telegram setup refuses to guess a chat'

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
