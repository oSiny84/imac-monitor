#!/bin/bash
set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

finish() {
    local status=$?
    trap - EXIT
    printf '\n'
    if [[ "$status" -eq 0 ]]; then
        printf 'MacMonitor 제거가 끝났습니다.\n'
    else
        printf 'MacMonitor 제거 중 일부 항목이 실패했습니다. 위 [FAILED] 줄을 확인하세요.\n'
    fi
    if [[ -t 0 ]]; then
        printf '이 창을 닫으려면 아무 키나 누르세요.\n'
        read -r -n 1 _
        printf '\n'
    fi
    exit "$status"
}
trap finish EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo '이 파일은 macOS에서만 실행할 수 있습니다.' >&2
    exit 1
fi

printf 'MacMonitor를 이 Mac에서 제거합니다.\n'
printf '작업 폴더: %s\n\n' "$ROOT_DIR"
printf '녹화 파일은 기본으로 남깁니다.\n'
printf '녹화까지 지우려면 터미널에서 다음을 실행하세요.\n'
printf '  "%s/scripts/uninstall.sh" --recordings\n\n' "$ROOT_DIR"

chmod +x "$ROOT_DIR"/scripts/*.sh

"$ROOT_DIR/scripts/uninstall.sh"
