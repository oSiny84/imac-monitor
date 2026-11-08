#!/bin/bash
# Connect the owner's Telegram chat to the gateway bot. Writes telegram.json beside
# gateway.json; the running gateway picks the file up within about ten seconds.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <bot-token-from-@BotFather> [view-minutes]" >&2
    exit 2
fi

TOKEN="$1"
VIEW_MINUTES="${2:-10}"
APP_SUPPORT="${MACMONITOR_APP_SUPPORT:-$HOME/Library/Application Support/MacMonitor}"
API="${MACMONITOR_TELEGRAM_API:-https://api.telegram.org}"

fail() {
    echo "error: $*" >&2
    exit 1
}

# The token is a secret: it never goes into echo, set -x or the gateway log.
[[ "$TOKEN" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]] || \
    fail "the token must look like 123456789:AAH... exactly as @BotFather printed it"
[[ "$VIEW_MINUTES" =~ ^[0-9]+$ && "$VIEW_MINUTES" -ge 1 && "$VIEW_MINUTES" -le 120 ]] || \
    fail "view-minutes must be a whole number from 1 to 120"
command -v curl >/dev/null 2>&1 || fail "curl is required"

ME="$(curl -fsS --max-time 15 "$API/bot$TOKEN/getMe" 2>/dev/null)" || \
    fail "could not reach Telegram or the token was rejected"
printf '%s' "$ME" | grep -q '"ok":true' || fail "Telegram rejected the token"
BOT_NAME="$(printf '%s' "$ME" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')"
echo "봇 @${BOT_NAME:-unknown} 이(가) 응답합니다."
echo
echo "1. 휴대폰 텔레그램 앱에서 @${BOT_NAME:-봇} 채팅을 열고 아무 말이나 보내세요."
echo "2. 보낸 뒤 이 터미널에서 Return 키만 누르세요. 이 터미널에는 아무것도 입력하지 마세요."
if [[ -t 0 ]]; then
    printf '메시지를 보냈으면 Return... '
    read -r _
    echo
else
    echo "(터미널이 아니므로 메시지를 이미 보낸 것으로 간주합니다)"
fi

UPDATES="$(curl -fsS --max-time 15 "$API/bot$TOKEN/getUpdates?timeout=0" 2>/dev/null)" || \
    fail "텔레그램에서 메시지를 읽지 못했습니다"
# The Bot API returns compact JSON, so the chat ids can be read without jq. An empty match
# must not stop the script here (set -e), or the explanation below is never printed.
CHAT_IDS="$(printf '%s' "$UPDATES" | grep -oE '"chat":\{"id":-?[0-9]+' | sed 's/.*://' | sort -u || true)"
if [[ -z "$CHAT_IDS" ]]; then
    fail "봇에 도착한 메시지가 없습니다. 휴대폰 텔레그램에서 봇에게 메시지를 보낸 뒤 이 스크립트를 다시 실행하세요"
fi
CHAT_COUNT="$(printf '%s\n' "$CHAT_IDS" | wc -l | tr -d ' ')"
if [[ "$CHAT_COUNT" -eq 1 ]]; then
    CHAT_ID="$CHAT_IDS"
    echo "채팅 하나를 찾았습니다: $CHAT_ID"
else
    echo "이 봇에 여러 채팅이 메시지를 보냈습니다:"
    printf '  %s\n' $CHAT_IDS
    [[ -t 0 ]] || fail "채팅이 여러 개입니다. 터미널에서 실행해 하나를 고르세요"
    printf '내 채팅 번호를 입력하세요: '
    read -r CHAT_ID
    printf '%s\n' "$CHAT_IDS" | grep -qx -- "$CHAT_ID" || fail "목록에 없는 번호입니다"
fi

umask 077
mkdir -p "$APP_SUPPORT"
chmod 700 "$APP_SUPPORT"
# Same pattern as configure-gateway.sh: a candidate on the same filesystem replaces the
# old file only once it is complete.
CANDIDATE="$(mktemp "$APP_SUPPORT/.telegram-config.XXXXXX")"
trap 'rm -f "$CANDIDATE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '{\n  "botToken": "%s",\n  "chatID": %s,\n  "viewMinutes": %s\n}\n' \
    "$TOKEN" "$CHAT_ID" "$VIEW_MINUTES" > "$CANDIDATE"
chmod 600 "$CANDIDATE"
mv -f "$CANDIDATE" "$APP_SUPPORT/telegram.json"

CONFIRMATION="MacMonitor가 이 채팅에 연결되었습니다. 명령: 카메라 (켜고 링크 받기) · 그만 (요청 끝내기) · 상태 (앱 상태 보기)"
curl -fsS --max-time 15 -X POST "$API/bot$TOKEN/sendMessage" \
    --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$CONFIRMATION" >/dev/null 2>&1 || \
    echo "warning: the confirmation message could not be sent; the configuration was still saved" >&2

echo "$APP_SUPPORT/telegram.json 에 채팅 $CHAT_ID 을(를) 저장했습니다 (요청마다 카메라 ${VIEW_MINUTES}분 유지)."
echo "게이트웨이가 실행 중이면 약 10초 안에 봇이 시작됩니다. '카메라'를 보내 확인하세요."
