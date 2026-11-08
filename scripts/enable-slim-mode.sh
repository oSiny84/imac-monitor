#!/bin/bash
# Let MacMonitor schedule its own wake-ups without a password. Installs one sudoers rule for
# the current user that allows exactly two commands:
#   pmset schedule wake <date> MacMonitor
#   pmset schedule cancel wake <date> MacMonitor
# Nothing else gains root. Remove with: sudo rm /etc/sudoers.d/macmonitor
set -euo pipefail

SUDOERS_DIR="${MACMONITOR_SUDOERS_DIR:-/etc/sudoers.d}"
RULE_FILE="$SUDOERS_DIR/macmonitor"
USER_NAME="${MACMONITOR_USER:-$(id -un)}"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || fail "the user name '$USER_NAME' cannot be written into a sudoers rule"
command -v visudo >/dev/null 2>&1 || fail "visudo is required"
command -v sudo >/dev/null 2>&1 || fail "sudo is required"

CANDIDATE="$(mktemp)"
trap 'rm -f "$CANDIDATE"' EXIT
cat > "$CANDIDATE" <<RULE
# MacMonitor slim mode: schedule and cancel its own wake-ups. Installed by scripts/enable-slim-mode.sh.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *
RULE
chmod 0440 "$CANDIDATE"

echo "This installs $RULE_FILE so MacMonitor can schedule wake-ups. Administrator password:"
sudo -v || fail "administrator authentication failed"
# A syntax error in sudoers.d breaks sudo for the whole Mac, so the file is checked first.
sudo visudo -cf "$CANDIDATE" >/dev/null || fail "the generated rule did not pass visudo; nothing was installed"
sudo install -o root -g wheel -m 0440 "$CANDIDATE" "$RULE_FILE" || fail "could not install $RULE_FILE"

if sudo -n -l /usr/bin/pmset schedule wake probe >/dev/null 2>&1; then
    echo "Installed. MacMonitor can now schedule wake-ups without a password."
else
    fail "the rule was installed but sudo -n does not accept it; check $RULE_FILE"
fi
echo "Next: open MacMonitor settings and turn on 슬림 모드. Remove the rule with: sudo rm $RULE_FILE"
