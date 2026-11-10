#!/bin/bash
# Owner setup that Build MacMonitor.command runs after a successful build, so a first install
# needs no terminal commands:
#   1. Remote web: when gateway.json is missing, runs setup-lan-https.sh (certificate and web
#      password). The Telegram bot runs inside that web server, so without it the bot is
#      saved but never answers. An existing configuration is left alone.
#   2. Telegram bot: asks for the token when telegram.json is missing, offers to replace it
#      when it exists (Return keeps or skips).
#   3. Slim mode: installs the wake-up sudoers rule unless it is already in place.
# Every step is optional. A step that fails or is skipped is reported and the install goes
# on, so this script always exits 0. Control-C ends the step in progress only: the handler
# below keeps this script alive while the step's own process still dies of the signal
# (an ignored signal, trap '', would be inherited and Control-C would do nothing).
set -uo pipefail
trap ':' INT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="${MACMONITOR_APP_SUPPORT:-$HOME/Library/Application Support/MacMonitor}"
SUDOERS_DIR="${MACMONITOR_SUDOERS_DIR:-/etc/sudoers.d}"

# Hidden reads ended by Control-C can leave the terminal with echo off.
restore_echo() {
    if [[ -t 0 ]]; then
        stty echo 2>/dev/null || true
    fi
}

echo "[설정 1/3] 원격 웹(휴대폰 접속, 텔레그램 봇이 이 안에서 돕니다)"
if [[ -f "$APP_SUPPORT/gateway.json" ]]; then
    echo "이미 설정되어 있습니다. 건너뜁니다. 주소가 바뀌었으면 Setup Remote Web.command를 실행하세요."
else
    echo "원격 웹이 아직 설정되지 않았습니다. 휴대폰에서 로그인할 웹 비밀번호를 정합니다."
    echo "건너뛰려면 비밀번호 대신 Control-C를 누르세요. 그러면 텔레그램 봇도 답하지 않습니다."
    # Same PATH as Setup Remote Web.command: route and ipconfig live in /usr/sbin, and the
    # system openssl comes before a conda or Homebrew one.
    if env PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}" bash "$SCRIPT_DIR/setup-lan-https.sh"; then
        :
    else
        echo
        echo "원격 웹 설정을 마치지 못했습니다. 텔레그램 봇도 이 설정이 있어야 답합니다."
        echo "나중에 Setup Remote Web.command를 더블클릭하거나 Build MacMonitor.command를 다시 실행하세요."
    fi
    restore_echo
fi

echo
echo "[설정 2/3] 텔레그램 봇"
if ! bash "$SCRIPT_DIR/configure-telegram.sh" --ask; then
    echo
    echo "텔레그램 설정을 마치지 못했습니다. 이전 설정이 있었다면 그대로입니다."
    echo "같은 봇을 쓰는 MacMonitor가 실행 중이면 종료한 뒤 Build MacMonitor.command를 다시 실행하세요."
fi
restore_echo

echo
echo "[설정 3/3] 슬림 모드 깨우기 권한"
# The file check comes first: with a fresh sudo timestamp `sudo -n -l` succeeds for an
# administrator even when the rule is missing.
if [[ -e "$SUDOERS_DIR/macmonitor" ]] && sudo -n -l /usr/bin/pmset schedule wake probe >/dev/null 2>&1; then
    echo "이미 설치되어 있습니다. 건너뜁니다."
else
    echo "MacMonitor가 스스로 깨우기를 예약할 수 있게 규칙 한 줄을 설치합니다."
    echo "Mac 로그인 비밀번호를 한 번 묻습니다. 입력해도 화면에는 표시되지 않습니다."
    echo "설치하지 않으려면 비밀번호 대신 Control-C를 누르세요."
    if bash "$SCRIPT_DIR/enable-slim-mode.sh"; then
        echo "설치했습니다. 앱 설정에서 '슬림 모드'를 켜면 사용됩니다."
    else
        echo
        echo "슬림 모드 권한을 설치하지 못했습니다. 다른 기능은 그대로 쓸 수 있습니다."
        echo "나중에 Build MacMonitor.command를 다시 실행하면 다시 시도합니다."
    fi
fi
exit 0
