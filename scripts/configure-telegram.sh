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
echo "Bot @${BOT_NAME:-unknown} answers."
echo
echo "On your phone, open a chat with @${BOT_NAME:-the bot} and send it any message now."
if [[ -t 0 ]]; then
    printf 'Press Return once the message is sent... '
    read -r _
    echo
else
    echo "(no terminal: assuming the message was already sent)"
fi

UPDATES="$(curl -fsS --max-time 15 "$API/bot$TOKEN/getUpdates?timeout=0" 2>/dev/null)" || \
    fail "could not read messages from Telegram"
# The Bot API returns compact JSON, so the chat ids can be read without jq.
CHAT_IDS="$(printf '%s' "$UPDATES" | grep -oE '"chat":\{"id":-?[0-9]+' | sed 's/.*://' | sort -u)"
if [[ -z "$CHAT_IDS" ]]; then
    fail "no message has reached the bot yet; send one from your phone and run this again"
fi
CHAT_COUNT="$(printf '%s\n' "$CHAT_IDS" | wc -l | tr -d ' ')"
if [[ "$CHAT_COUNT" -eq 1 ]]; then
    CHAT_ID="$CHAT_IDS"
    echo "Found one chat: $CHAT_ID"
else
    echo "Several chats have written to this bot:"
    printf '  %s\n' $CHAT_IDS
    [[ -t 0 ]] || fail "several chats found; run this script in a terminal to choose one"
    printf 'Type the chat id that is yours: '
    read -r CHAT_ID
    printf '%s\n' "$CHAT_IDS" | grep -qx -- "$CHAT_ID" || fail "that id is not in the list"
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

echo "Saved $APP_SUPPORT/telegram.json for chat $CHAT_ID (camera stays on $VIEW_MINUTES minutes per request)."
echo "A running gateway starts the bot within about ten seconds. Send '카메라' to test."
