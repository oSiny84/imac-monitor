#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.21.1"
ARCHIVE="mediamtx_v${VERSION}_darwin_amd64.tar.gz"
RELEASE_URL="https://github.com/bluenviron/mediamtx/releases/download/v${VERSION}"
TARGET_DIR="$ROOT_DIR/vendor/mediamtx"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

curl --fail --location --proto '=https' --tlsv1.2 \
    "$RELEASE_URL/$ARCHIVE" --output "$TEMP_DIR/$ARCHIVE"
curl --fail --location --proto '=https' --tlsv1.2 \
    "$RELEASE_URL/checksums.sha256" --output "$TEMP_DIR/checksums.sha256"

EXPECTED="$(awk -v file="$ARCHIVE" '$2 == file { print $1 }' "$TEMP_DIR/checksums.sha256")"
ACTUAL="$(shasum -a 256 "$TEMP_DIR/$ARCHIVE" | awk '{ print $1 }')"
if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    echo "MediaMTX checksum verification failed" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"
tar -xzf "$TEMP_DIR/$ARCHIVE" -C "$TARGET_DIR"
chmod 755 "$TARGET_DIR/mediamtx"
echo "Fetched MediaMTX v$VERSION for darwin/amd64"
