#!/bin/bash
# Sets up HTTPS for phones on the same Wi-Fi: a self-signed certificate for this Mac's current
# local address and the gateway configuration that uses it.
#
# Outside home needs nothing here: the gateway accepts the address the phone opened and gives
# the video that address too, so after port forwarding the owner opens https://<public IP>:8443.
# --external still lists an address (the public IP or a DDNS name) in the certificate and in
# the Telegram reply; it is optional and kept on later runs until --no-external.
#
# Safe to run any time. When nothing changed and the certificate is good for another 30 days,
# it only prints the addresses and asks nothing. A domain configuration made with
# configure-gateway.sh is left alone unless --replace is given; the domain then stays listed as
# an external address.
#
# Options: --replace, --external <IP or name[:port]>, --no-external.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="${MACMONITOR_APP_SUPPORT:-$HOME/Library/Application Support/MacMonitor}"
CERT_ROOT="$APP_SUPPORT/LAN-HTTPS"
PORT=8443
VALID_DAYS=365
RENEW_BEFORE_SECONDS=$((30 * 24 * 3600))
# The gateway refuses more extra origins than this (config.MaxAdditionalOrigins).
MAX_EXTERNAL=4
REPLACE=0
# keep: the external addresses already configured; set: EXTERNAL_INPUT only; clear: none.
EXTERNAL_MODE=keep
EXTERNAL_INPUT=""

fail() {
    echo "오류: $*" >&2
    exit 1
}

usage_text="사용법: $0 [--replace] [--external 공인IP또는DDNS주소[:포트] | --no-external]"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --replace) REPLACE=1; shift ;;
        --external)
            [[ $# -ge 2 && -n "$2" ]] || fail "--external 뒤에 주소가 필요합니다 ($usage_text)"
            EXTERNAL_MODE=set
            EXTERNAL_INPUT="$2"
            shift 2 ;;
        --external=*)
            EXTERNAL_MODE=set
            EXTERNAL_INPUT="${1#--external=}"
            [[ -n "$EXTERNAL_INPUT" ]] || fail "--external 뒤에 주소가 필요합니다 ($usage_text)"
            shift ;;
        --no-external) EXTERNAL_MODE=clear; shift ;;
        *) fail "알 수 없는 옵션: $1 ($usage_text)" ;;
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

# The gateway writes a list one entry per line between "additionalOrigins": [ and ]. Prints
# every entry on one line, separated by spaces.
config_additional_origins() {
    awk '/"additionalOrigins"[[:space:]]*:/ { inside = 1; next }
        inside && /\]/ { exit }
        inside { gsub(/[[:space:]",]/, ""); if (length($0) > 0) printf "%s%s", (n++ ? " " : ""), $0 }' \
        "$APP_SUPPORT/gateway.json" 2>/dev/null || true
}

# Dotted decimal only. A leading zero is refused: browsers read 010 as octal 8 and would open
# a different address than the one allowed.
is_ipv4() {
    local a b c d octet
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ ! "$octet" =~ ^0[0-9] ]] || return 1
        (( octet <= 255 )) || return 1
    done
}

# Addresses that only exist inside a home or on this Mac. None can be reached from outside.
is_home_ipv4() {
    local a b rest
    is_ipv4 "$1" || return 1
    IFS=. read -r a b rest <<< "$1"
    (( a == 10 || a == 127 )) && return 0
    (( a == 172 && b >= 16 && b <= 31 )) && return 0
    (( a == 192 && b == 168 )) && return 0
    (( a == 169 && b == 254 )) && return 0
    return 1
}

# 100.64.0.0/10: carrier-grade NAT, also used by Tailscale and similar VPNs.
is_shared_ipv4() {
    is_ipv4 "$1" && [[ "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

# Turns what the owner typed (1.2.3.4, cam.ddns.net:8443, https://cam.ddns.net/) into the
# origin a browser sends. A bare address gets this gateway's port; after https:// a missing
# port means 443, as in any URL and in origins read back from gateway.json. Port 443 is left
# out, as browsers do. Prints nothing on bad input.
external_origin_for() {
    local value host port last
    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    port="$PORT"
    if [[ "$value" == https://* ]]; then
        port=443
    fi
    value="${value#https://}"
    value="${value#http://}"
    value="${value%/}"
    host="$value"
    if [[ "$value" == *:* ]]; then
        host="${value%:*}"
        port="${value##*:}"
    fi
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    port=$((10#$port))
    (( port >= 1 && port <= 65535 )) || return 1
    if ! is_ipv4 "$host"; then
        [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || return 1
        # Browsers read a name whose last label is a number (or 0x hex) as an IPv4 address.
        last="${host##*.}"
        [[ ! "$last" =~ ^[0-9]+$ && ! "$last" =~ ^0x[0-9a-f]*$ ]] || return 1
    fi
    if [[ "$port" == 443 ]]; then
        printf 'https://%s\n' "$host"
    else
        printf 'https://%s:%s\n' "$host" "$port"
    fi
}

# Host and port of an origin made by external_origin_for (no IPv6 there, so the last colon is
# the port).
origin_host() {
    local rest="${1#https://}"
    printf '%s\n' "${rest%:*}"
}

origin_port() {
    local rest="${1#https://}"
    if [[ "$rest" == *:* ]]; then printf '%s\n' "${rest##*:}"; else printf '443\n'; fi
}

# Reads an address the owner typed, or fails with the reason.
typed_external_origin() {
    local typed="$1" bare origin host a rest
    bare="$(printf '%s' "$typed" | tr '[:upper:]' '[:lower:]')"
    bare="${bare#https://}"
    bare="${bare#http://}"
    if [[ "$bare" == \[* || "$bare" == *:*:* ]]; then
        fail "IPv6 주소는 지원하지 않습니다. 공인 IPv4 주소(Mac 터미널에서 curl -4 -s https://ifconfig.me)나 DDNS 주소를 넣으세요"
    fi
    origin="$(external_origin_for "$typed" || true)"
    [[ -n "$origin" ]] || \
        fail "밖에서 쓸 주소 '$typed'를 읽지 못했습니다. 203.0.113.5나 cam.example.net처럼 IP나 도메인을 넣으세요(포트는 :8443처럼 붙일 수 있습니다)"
    host="$(origin_host "$origin")"
    if is_home_ipv4 "$host"; then
        fail "$host 는 집 안에서만 쓰는 주소라 밖에서는 열리지 않습니다. 공유기 관리 주소가 아니라 공인 IP가 필요합니다. Mac 터미널에서 curl -4 -s https://ifconfig.me 로 확인하세요"
    fi
    if is_ipv4 "$host"; then
        IFS=. read -r a rest <<< "$host"
        (( a != 0 && a < 224 )) || fail "$host 는 휴대폰이 접속할 수 있는 주소가 아닙니다"
        if is_shared_ipv4 "$host"; then
            echo "주의: $host 는 통신사 NAT(CGNAT)나 Tailscale 같은 VPN 주소입니다. 공유기 포트포워딩으로는 밖에서 들어올 수 없을 수 있습니다." >&2
        fi
    fi
    printf '%s\n' "$origin"
}

current_origin=""
current_cert=""
current_externals=""
replaced_domain=""
if [[ -f "$APP_SUPPORT/gateway.json" ]]; then
    current_origin="$(config_value publicOrigin)"
    current_cert="$(config_value tlsCertificateFile)"
    current_externals="$(config_additional_origins)"
    current_host="${current_origin#https://}"
    current_host="${current_host%%:*}"
    if [[ -n "$current_host" && ! "$current_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ "$REPLACE" != 1 ]]; then
            echo "도메인 주소($current_origin)로 이미 설정되어 있어 바꾸지 않습니다."
            echo "같은 Wi-Fi 시험용 주소로 바꾸려면 터미널에서 다음을 실행하세요:"
            echo "  \"$SCRIPT_DIR/setup-lan-https.sh\" --replace"
            exit 0
        fi
        replaced_domain="$current_origin"
    fi
fi

# What a run without options keeps: the configured external addresses, plus the domain being
# replaced. A home address that was listed (an old Wi-Fi address, or this Mac's own) is not an
# external address and is dropped with a note.
kept_externals=""
for listed in $replaced_domain $current_externals; do
    normalized="$(external_origin_for "$listed" || true)"
    [[ -n "$normalized" ]] || \
        fail "gateway.json의 밖 주소 '$listed'를 읽지 못했습니다. --external 주소나 --no-external을 붙여 다시 실행하세요"
    if [[ "$normalized" == "$ORIGIN" ]] || is_home_ipv4 "$(origin_host "$normalized")"; then
        [[ "$EXTERNAL_MODE" != keep ]] || echo "집 안 주소 $listed 는 밖에서 쓸 주소에서 뺍니다."
        continue
    fi
    case " $kept_externals " in *" $normalized "*) continue ;; esac
    kept_externals="${kept_externals:+$kept_externals }$normalized"
done
if [[ -n "$replaced_domain" && "$EXTERNAL_MODE" == keep ]]; then
    echo "도메인 주소 $replaced_domain 는 밖에서 쓸 주소로 남깁니다(이제 자체 서명 인증서). 지우려면 --no-external을 붙입니다."
fi

case "$EXTERNAL_MODE" in
    keep) EXTERNALS="$kept_externals" ;;
    clear) EXTERNALS="" ;;
    set) EXTERNALS="$(typed_external_origin "$EXTERNAL_INPUT")" || exit 1 ;;
esac
for external in $EXTERNALS; do
    [[ "$external" != "$ORIGIN" ]] || \
        fail "밖에서 쓸 주소가 이 Mac의 집 Wi-Fi 주소($address)와 같습니다. 공유기의 공인 IP나 DDNS 주소를 넣으세요"
done
# shellcheck disable=SC2086
set -- $EXTERNALS
(( $# <= MAX_EXTERNAL )) || \
    fail "밖에서 쓸 주소가 $#개입니다. 최대 ${MAX_EXTERNAL}개라서 --external 주소 하나로 다시 실행하세요"

print_address() {
    local external ports="" port
    echo
    echo "같은 Wi-Fi의 휴대폰 브라우저에서 여세요:  $ORIGIN"
    for external in $EXTERNALS; do
        echo "밖(휴대폰 데이터망)에서는 여세요:        $external"
    done
    echo "텔레그램 봇에게 '카메라'를 보내면 이 주소가 답장으로도 옵니다."
    local forwarded=0 shared=0
    for external in $EXTERNALS; do
        if is_shared_ipv4 "$(origin_host "$external")"; then
            shared=1
            continue
        fi
        forwarded=1
        port="$(origin_port "$external")"
        case " $ports " in *" $port "*) ;; *) ports="${ports:+$ports }$port" ;; esac
    done
    echo
    if [[ "$forwarded" == 1 || -z "$EXTERNALS" ]]; then
        echo "밖(휴대폰 데이터망)에서 쓰는 방법은 둘입니다."
        echo "  1) Tailscale(권장): 휴대폰과 Mac에 Tailscale을 켜고 Mac의 Tailscale 주소(https://100.x.x.x:$PORT)를 엽니다."
        echo "     포트포워딩이 필요 없고 통신사 NAT 회선에서도 됩니다."
        echo "  2) 공유기 포트포워딩: 이 Mac($address)으로 다음을 엽니다."
        for port in ${ports:-$PORT}; do
            echo "     - 웹: 외부 TCP $port → 이 Mac의 TCP $PORT"
        done
        echo "     - 영상: UDP·TCP 8189 → 이 Mac의 같은 8189"
        if [[ -z "$EXTERNALS" ]]; then
            echo "     그다음 https://공인IP:$PORT 를 엽니다. 공인 IP는 Mac 터미널에서 curl -4 -s https://ifconfig.me"
        fi
        echo "     인터넷에 바로 열리므로 신뢰할 수 있는 도메인 인증서(docs/SETUP_MAC.md 4절)를 권합니다."
    fi
    if [[ "$shared" == 1 ]]; then
        echo "100.x 주소는 Tailscale 같은 VPN 주소로 보고 포트포워딩을 안내하지 않습니다. 휴대폰과 Mac 모두 Tailscale을 켜 두면 됩니다."
        echo "통신사 NAT(CGNAT) 주소라면 밖에서 들어올 수 없으니 Tailscale을 쓰세요."
    fi
}

if [[ -n "$current_origin" ]]; then
    if [[ "$current_origin" == "$ORIGIN" && "$current_externals" == "$EXTERNALS" &&
        -n "$current_cert" && -r "$current_cert" ]] &&
        openssl x509 -checkend "$RENEW_BEFORE_SECONDS" -noout -in "$current_cert" >/dev/null 2>&1; then
        echo "이미 이 주소로 설정되어 있습니다. 바꿀 것이 없습니다."
        print_address
        exit 0
    fi
    if [[ "$current_origin" != "$ORIGIN" ]]; then
        echo "주소가 바뀌었습니다: $current_origin → $ORIGIN"
    fi
    if [[ "$current_externals" != "$EXTERNALS" ]]; then
        echo "밖에서 쓸 주소가 바뀝니다: ${current_externals:-없음} → ${EXTERNALS:-없음}"
    fi
    if [[ "$current_origin" == "$ORIGIN" && "$current_externals" == "$EXTERNALS" ]]; then
        echo "인증서가 없거나 30일 안에 만료되어 새로 만듭니다."
    fi
fi

# The certificate names every address the phone may open, so each one passes after the
# one-time warning.
SUBJECT_ALT_NAMES="IP:$address"
CONFIGURE_OPTIONS=()
for external in $EXTERNALS; do
    external_host="$(origin_host "$external")"
    if is_ipv4 "$external_host"; then
        name="IP:$external_host"
    else
        name="DNS:$external_host"
    fi
    case ", $SUBJECT_ALT_NAMES, " in *", $name, "*) ;; *) SUBJECT_ALT_NAMES="$SUBJECT_ALT_NAMES, $name" ;; esac
    CONFIGURE_OPTIONS+=(--also-origin "$external")
done

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
subjectAltName = $SUBJECT_ALT_NAMES
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
if ! "$SCRIPT_DIR/configure-gateway.sh" ${CONFIGURE_OPTIONS[@]+"${CONFIGURE_OPTIONS[@]}"} \
    "$ORIGIN" "$NEW_DIR/cert.pem" "$NEW_DIR/key.pem"; then
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
echo
echo "처음 열 때 인증서 경고가 나오면 이 주소에서만 진행을 고르세요."
echo "이미 진행한 주소에서 경고가 다시 나오면 진행하지 마세요. 누군가 중간에서 가로채고 있을 수 있습니다."
echo "공유기에서 이 Mac에 고정 주소(DHCP 예약)를 주면 주소가 바뀌지 않아 다시 실행할 일이 거의 없습니다."
