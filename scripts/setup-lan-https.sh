#!/bin/bash
# Sets up HTTPS for phones on the same Wi-Fi: a self-signed certificate for this Mac's current
# local address and the gateway configuration that uses it. Safe to run any time. When the
# configuration already matches the current address and the certificate is good for another
# 30 days, it only prints the address and asks nothing. A domain configuration made with
# configure-gateway.sh is left alone unless --replace is given.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="${MACMONITOR_APP_SUPPORT:-$HOME/Library/Application Support/MacMonitor}"
CERT_ROOT="$APP_SUPPORT/LAN-HTTPS"
PORT=8443
VALID_DAYS=365
RENEW_BEFORE_SECONDS=$((30 * 24 * 3600))
REPLACE=0

fail() {
    echo "오류: $*" >&2
    exit 1
}

for argument in "$@"; do
    case "$argument" in
        --replace) REPLACE=1 ;;
        *) fail "알 수 없는 옵션: $argument (사용법: $0 [--replace])" ;;
    esac
done

command -v openssl >/dev/null 2>&1 || fail "openssl이 필요합니다"

# Phones on the same network reach the interface that carries the default route. An iMac may
# have both Ethernet (en0) and Wi-Fi (en1), so the route decides before the usual names.
address=""
interface="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }' || true)"
if [[ -n "$interface" ]]; then
    address="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
fi
for candidate in en0 en1; do
    [[ -z "$address" ]] || break
    address="$(ipconfig getifaddr "$candidate" 2>/dev/null || true)"
done
[[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "이 Mac의 네트워크 주소를 찾지 못했습니다. Wi-Fi나 유선 연결을 확인하고 다시 실행하세요"
ORIGIN="https://$address:$PORT"

# gateway.json is written by the gateway with one key per line, so sed can read a value.
config_value() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$APP_SUPPORT/gateway.json" 2>/dev/null | head -n 1
}

print_address() {
    echo
    echo "같은 Wi-Fi의 휴대폰 브라우저에서 여세요:  $ORIGIN"
    echo "텔레그램 봇에게 '카메라'를 보내면 이 주소가 답장으로도 옵니다."
}

if [[ -f "$APP_SUPPORT/gateway.json" ]]; then
    current_origin="$(config_value publicOrigin)"
    current_cert="$(config_value tlsCertificateFile)"
    current_host="${current_origin#https://}"
    current_host="${current_host%%:*}"
    if [[ -n "$current_host" && ! "$current_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$REPLACE" != 1 ]]; then
        echo "도메인 주소($current_origin)로 이미 설정되어 있어 바꾸지 않습니다."
        echo "같은 Wi-Fi 시험용 주소로 바꾸려면 터미널에서 다음을 실행하세요:"
        echo "  \"$SCRIPT_DIR/setup-lan-https.sh\" --replace"
        exit 0
    fi
    if [[ "$current_origin" == "$ORIGIN" && -n "$current_cert" && -r "$current_cert" ]] &&
        openssl x509 -checkend "$RENEW_BEFORE_SECONDS" -noout -in "$current_cert" >/dev/null 2>&1; then
        echo "이미 이 주소로 설정되어 있습니다. 바꿀 것이 없습니다."
        print_address
        exit 0
    fi
    if [[ -n "$current_origin" && "$current_origin" != "$ORIGIN" ]]; then
        echo "주소가 바뀌었습니다: $current_origin → $ORIGIN"
    else
        echo "인증서가 없거나 30일 안에 만료되어 새로 만듭니다."
    fi
fi

# Each certificate gets its own folder, so a failed setup never touches the files the working
# configuration points at. The old folders go only after the new configuration is saved. The
# random suffix keeps two runs within one second from sharing, and then deleting, a folder.
umask 077
mkdir -p "$CERT_ROOT"
chmod 700 "$APP_SUPPORT" "$CERT_ROOT"
NEW_DIR="$(mktemp -d "$CERT_ROOT/$(date '+%Y%m%d-%H%M%S')-XXXXXX")" || fail "인증서 폴더를 만들지 못했습니다"
cat > "$NEW_DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = MacMonitor $address
[v3]
subjectAltName = IP:$address
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
if ! openssl req -x509 -newkey rsa:2048 -nodes -days "$VALID_DAYS" \
    -keyout "$NEW_DIR/key.pem" -out "$NEW_DIR/cert.pem" -config "$NEW_DIR/cert.cnf" >/dev/null 2>&1; then
    rm -rf "$NEW_DIR"
    fail "인증서를 만들지 못했습니다"
fi
chmod 600 "$NEW_DIR/key.pem"

echo
echo "웹 접속 비밀번호를 정합니다. 휴대폰에서 로그인할 때 쓰며 12자 이상입니다."
echo "같은 비밀번호를 두 번 입력하세요. 입력하는 글자는 화면에 보이지 않습니다."
if ! "$SCRIPT_DIR/configure-gateway.sh" "$ORIGIN" "$NEW_DIR/cert.pem" "$NEW_DIR/key.pem"; then
    rm -rf "$NEW_DIR"
    fail "웹 서버 설정이 저장되지 않았습니다. 위 메시지를 확인하세요. 기존 설정은 그대로입니다"
fi

shopt -s nullglob
for old in "$CERT_ROOT"/*/; do
    [[ "${old%/}" == "$NEW_DIR" ]] || rm -rf "${old%/}"
done

echo
echo "설정했습니다. 앱이 약 10초 안에 웹 서버를 새 설정으로 다시 켭니다."
print_address
echo "처음 열 때 인증서 경고가 나오면 이 주소에서만 진행을 고르세요."
echo "공유기에서 이 Mac에 고정 주소(DHCP 예약)를 주면 주소가 바뀌지 않아 다시 실행할 일이 거의 없습니다."
