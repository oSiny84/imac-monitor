#!/bin/bash
set -uo pipefail

# Finder/Terminal sessions opened before the Go .pkg was installed may not have
# reloaded /etc/paths.d/go yet.
export PATH="/usr/local/go/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$ROOT_DIR/dist"
LOG_FILE="$LOG_DIR/build-$(date '+%Y%m%d-%H%M%S').log"

mkdir -p "$LOG_DIR"

finish() {
    local status=$?
    trap - EXIT
    printf '\n'
    if [[ "$status" -eq 0 ]]; then
        printf 'MacMonitor 빌드와 진단이 완료되었습니다.\n'
    else
        printf 'MacMonitor 빌드가 실패했습니다. 위 오류와 다음 로그를 확인하세요.\n%s\n' "$LOG_FILE"
    fi
    if [[ -t 0 ]]; then
        printf '이 창을 닫으려면 아무 키나 누르세요.\n'
        read -r -n 1 _
        printf '\n'
    fi
    exit "$status"
}
trap finish EXIT

exec > >(/usr/bin/tee "$LOG_FILE") 2>&1
set -e

printf 'MacMonitor 원클릭 빌드를 시작합니다.\n'
printf '작업 폴더: %s\n' "$ROOT_DIR"
printf '로그: %s\n\n' "$LOG_FILE"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo '이 빌드 파일은 macOS에서만 실행할 수 있습니다.' >&2
    exit 1
fi

chmod +x "$ROOT_DIR"/scripts/*.sh

MEDIAMTX="$ROOT_DIR/vendor/mediamtx/mediamtx"
MEDIAMTX_VERSION=""
if [[ -x "$MEDIAMTX" ]]; then
    MEDIAMTX_VERSION="$("$MEDIAMTX" --version 2>/dev/null | tr -d '\r' || true)"
fi
if [[ "$MEDIAMTX_VERSION" != "v1.21.1" ]]; then
    printf 'MediaMTX 1.21.1을 준비합니다.\n'
    "$ROOT_DIR/scripts/fetch-mediamtx.sh"
fi

printf '\n전체 테스트와 Intel 앱 빌드를 실행합니다.\n'
MACMONITOR_TSAN=1 "$ROOT_DIR/scripts/build-app.sh"

printf '\n실행 전 진단을 시작합니다.\n'
"$ROOT_DIR/scripts/diagnose.sh"

printf '\n빌드된 앱을 실행합니다.\n'
/usr/bin/open "$ROOT_DIR/dist/MacMonitor.app"
