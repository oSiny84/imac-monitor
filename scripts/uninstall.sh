#!/bin/bash
# Remove MacMonitor from this Mac. Recordings are kept unless --recordings.
# The machine-wide pmset repeat schedule always needs its own confirmation:
# this script cannot tell whether MacMonitor or the user created it.
set -uo pipefail

# Every tool used here lives in /usr/bin or /usr/sbin, so this script does not
# rewrite PATH the way the build scripts must for Go and FFmpeg.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/MacMonitor.app"
APP_SUPPORT="${MACMONITOR_APP_SUPPORT:-$HOME/Library/Application Support/MacMonitor}"
BUNDLE_ID="local.macmonitor.app"
KEYCHAIN_SERVICE="local.macmonitor.app.password"
KEYCHAIN_ACCOUNT="owner"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
SAVED_STATE="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
PREFERENCES="$HOME/Library/Preferences/$BUNDLE_ID.plist"

ASSUME_YES=0
REMOVE_RECORDINGS=0
REMOVED_COUNT=0
ABSENT_COUNT=0
FAIL_COUNT=0

usage() {
    local exit_code="${1:-2}"
    echo "usage: $0 [--yes] [--recordings]" >&2
    echo "  --yes         skip the confirmation prompt; never covers the power schedule" >&2
    echo "  --recordings  delete recorded video as well; kept by default" >&2
    exit "$exit_code"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) ASSUME_YES=1; shift ;;
        --recordings) REMOVE_RECORDINGS=1; shift ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

removed() { REMOVED_COUNT=$((REMOVED_COUNT + 1)); printf '[REMOVED] %s\n' "$*"; }
absent() { ABSENT_COUNT=$((ABSENT_COUNT + 1)); printf '[ABSENT]  %s\n' "$*"; }
failed() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAILED]  %s\n' "$*" >&2; }

echo "MacMonitor uninstall"
echo
echo "This will remove:"
echo "  the running app and its helper processes"
echo "  launch agent   $LAUNCH_AGENT"
echo "  keychain item  $KEYCHAIN_SERVICE"
echo "  app data       $APP_SUPPORT"
if [[ "$REMOVE_RECORDINGS" -eq 1 ]]; then
    echo "                 including Recordings (--recordings)"
else
    echo "                 Recordings are kept"
fi
echo "  built app      $APP_DIR"
echo "  camera permission record (TCC)"
echo

if [[ "$ASSUME_YES" -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
        echo "No terminal available for confirmation; rerun with --yes." >&2
        exit 2
    fi
    printf 'Continue? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
    echo
fi

# 1. Stop the app first, otherwise it rewrites Runtime/ while we delete it.
if command -v osascript >/dev/null 2>&1; then
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1
fi
STOPPED=0
for pattern in "MacMonitor" "Contents/Helpers/mediamtx" "Contents/Helpers/macmonitor-gateway"; do
    if pkill -f "$pattern" >/dev/null 2>&1; then STOPPED=1; fi
done
if [[ "$STOPPED" -eq 1 ]]; then
    removed "running app and helper processes"
else
    absent "running app and helper processes"
fi

# 2. Launch agent. Its plist stores the absolute path of the app that wrote it,
#    so a stale one keeps starting an old build after a reinstall elsewhere.
if [[ -f "$LAUNCH_AGENT" ]]; then
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1
    if rm -f "$LAUNCH_AGENT"; then
        removed "launch agent $LAUNCH_AGENT"
    else
        failed "could not remove $LAUNCH_AGENT"
    fi
else
    absent "launch agent"
fi

# 3. Keychain verifier for the app password.
if command -v security >/dev/null 2>&1; then
    if security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
        removed "keychain item $KEYCHAIN_SERVICE"
    else
        absent "keychain item"
    fi
else
    absent "keychain item (security command missing)"
fi

# 4. Application data. Recorded video is the user's own material, so it stays
#    unless it was asked for explicitly.
if [[ -d "$APP_SUPPORT" ]]; then
    if [[ "$REMOVE_RECORDINGS" -eq 1 ]]; then
        if rm -rf "$APP_SUPPORT"; then
            removed "app data including recordings: $APP_SUPPORT"
        else
            failed "could not remove $APP_SUPPORT"
        fi
    else
        if find "$APP_SUPPORT" -mindepth 1 -maxdepth 1 ! -name Recordings -exec rm -rf {} + 2>/dev/null; then
            removed "app data (configuration, diagnostics, spool): $APP_SUPPORT"
        else
            failed "could not remove app data under $APP_SUPPORT"
        fi
        if [[ -d "$APP_SUPPORT/Recordings" ]]; then
            echo "          kept $APP_SUPPORT/Recordings"
        else
            rm -rf "$APP_SUPPORT" 2>/dev/null
        fi
    fi
else
    absent "app data"
fi

# 5. Window state and preferences. The app writes no UserDefaults, but AppKit
#    can still create these.
for path in "$SAVED_STATE" "$PREFERENCES"; do
    if [[ -e "$path" ]]; then
        if rm -rf "$path"; then removed "$path"; else failed "could not remove $path"; fi
    else
        absent "$path"
    fi
done

# 6. The built bundle inside this source folder.
if [[ -d "$APP_DIR" ]]; then
    if rm -rf "$APP_DIR"; then
        removed "built app $APP_DIR"
    else
        failed "could not remove $APP_DIR"
    fi
else
    absent "built app $APP_DIR"
fi

# 7. Camera permission record, so a reinstall asks for it again.
if command -v tccutil >/dev/null 2>&1; then
    if tccutil reset Camera "$BUNDLE_ID" >/dev/null 2>&1; then
        removed "camera permission record"
    else
        absent "camera permission record"
    fi
else
    absent "camera permission record (tccutil command missing)"
fi

# 8. Machine-wide repeating power schedule, last and never automatic. It
#    outlives every other item here and needs sudo, so a refusal must not
#    affect the steps above.
REPEAT_FOUND=0
SCHEDULE=""
if command -v pmset >/dev/null 2>&1; then
    SCHEDULE="$(pmset -g sched 2>/dev/null)"
    if printf '%s\n' "$SCHEDULE" | awk '
        /[Rr]epeating power events/ { seen = 1; next }
        seen && NF { found = 1 }
        END { exit found ? 0 : 1 }
    '; then
        REPEAT_FOUND=1
    fi
fi
if [[ "$REPEAT_FOUND" -eq 1 ]]; then
    echo
    echo "A machine-wide repeating power schedule is still set:"
    printf '%s\n' "$SCHEDULE"
    echo "MacMonitor may have created it, or you may have set it yourself."
    if [[ -t 0 ]]; then
        printf 'Cancel it? This needs your administrator password. [y/N] '
        read -r answer
        case "$answer" in
            y|Y|yes|YES)
                if sudo pmset repeat cancel; then
                    removed "repeating power schedule"
                else
                    failed "could not cancel it; run: sudo pmset repeat cancel"
                fi
                ;;
            *) absent "repeating power schedule (left in place)" ;;
        esac
    else
        absent "repeating power schedule - to cancel: sudo pmset repeat cancel"
    fi
else
    absent "repeating power schedule"
fi

echo
printf 'removed %d, absent %d, failed %d\n' "$REMOVED_COUNT" "$ABSENT_COUNT" "$FAIL_COUNT"
echo "This source folder is still here; drag it to the Trash:"
echo "  $ROOT_DIR"
[[ "$FAIL_COUNT" -eq 0 ]]
