#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.21.1"
ARCHIVE="mediamtx_v${VERSION}_darwin_amd64.tar.gz"
RELEASE_URL="https://github.com/bluenviron/mediamtx/releases/download/v${VERSION}"
# GitHub's release download redirect can fail on its own (504 for every asset on
# 2026-11-08) while the REST API serves the same files. These ids belong to the
# v1.21.1 assets and change with VERSION; the checksum below still decides.
ASSET_API_URL="https://api.github.com/repos/bluenviron/mediamtx/releases/assets"
ARCHIVE_ASSET_ID="577109449"
CHECKSUMS_ASSET_ID="577109429"
TARGET_DIR="$ROOT_DIR/vendor/mediamtx"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# download <name> <asset id>: the release URL first, then the API asset path.
download() {
    local name="$1" asset_id="$2"
    if curl --fail --location --proto '=https' --tlsv1.2 --retry 1 \
        "$RELEASE_URL/$name" --output "$TEMP_DIR/$name"; then
        return 0
    fi
    echo "GitHub release download failed for $name; trying the GitHub API asset path" >&2
    curl --fail --location --proto '=https' --tlsv1.2 --retry 1 \
        -H "Accept: application/octet-stream" \
        "$ASSET_API_URL/$asset_id" --output "$TEMP_DIR/$name"
}

download "$ARCHIVE" "$ARCHIVE_ASSET_ID"
download checksums.sha256 "$CHECKSUMS_ASSET_ID"

# Upstream generates this file with `sha256sum -b`: the filename is prefixed
# with '*'. Accept both the binary and text forms of the checksum list.
EXPECTED="$(awk -v file="$ARCHIVE" '{ name = $2; sub(/^\*/, "", name); if (name == file) print $1 }' "$TEMP_DIR/checksums.sha256")"
ACTUAL="$(shasum -a 256 "$TEMP_DIR/$ARCHIVE" | awk '{ print $1 }')"
if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    echo "MediaMTX checksum verification failed" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"
tar -xzf "$TEMP_DIR/$ARCHIVE" -C "$TARGET_DIR"
chmod 755 "$TARGET_DIR/mediamtx"
echo "Fetched MediaMTX v$VERSION for darwin/amd64"
