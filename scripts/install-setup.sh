#!/bin/bash
# Owner setup that Build MacMonitor.command runs after a successful build, so a first install
# needs no terminal commands:
#   1. Telegram bot: asks for the token when telegram.json is missing, offers to replace it
#      when it exists (Return keeps or skips).
#   2. Slim mode: installs the wake-up sudoers rule unless it is already in place.
# Both steps are optional. A step that fails or is skipped is reported and the install goes
# on, so this script always exits 0. Control-C ends the step in progress only: the handler
# below keeps this script alive while the step's own process still dies of the signal
# (an ignored signal, trap '', would be inherited and Control-C would do nothing).
set -uo pipefail
trap ':' INT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUDOERS_DIR="${MACMONITOR_SUDOERS_DIR:-/etc/sudoers.d}"

echo "[설정 1/2] 텔레그램 봇"
if ! bash "$SCRIPT_DIR/configure-telegram.sh" --ask; then
    echo
    echo "텔레그램 설정을 마치지 못했습니다. 이전 설정이 있었다면 그대로입니다."
    echo "같은 봇을 쓰는 MacMonitor가 실행 중이면 종료한 뒤 Build MacMonitor.command를 다시 실행하세요."
fi
# A hidden read ended by Control-C can leave the terminal with echo off.
if [[ -t 0 ]]; then
    stty echo 2>/dev/null || true
fi

echo
echo "[설정 2/2] 슬림 모드 깨우기 권한"
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
