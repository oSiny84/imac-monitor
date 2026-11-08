#!/bin/bash
# Double-click: set up (or check) HTTPS for phones on the same Wi-Fi. Runs
# scripts/setup-lan-https.sh, which asks nothing when the setup is already current.
set -uo pipefail

# System tools first: route and ipconfig live in /usr/sbin, and a conda or Homebrew openssl
# earlier in PATH is not needed.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

finish() {
    local status=$?
    trap - EXIT
    printf '\n'
    if [[ "$status" -ne 0 ]]; then
        printf '원격 웹 설정이 끝나지 않았습니다. 위 메시지를 확인하세요.\n'
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

chmod +x "$ROOT_DIR"/scripts/*.sh
"$ROOT_DIR/scripts/setup-lan-https.sh" "$@"
