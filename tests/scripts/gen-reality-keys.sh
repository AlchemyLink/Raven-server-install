#!/usr/bin/env sh
# Скачивает Xray (linux-amd64), генерирует пару x25519 и печатает YAML-фрагмент для test_secrets.yml
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${ROOT}/tests/.cache"
VER="${XRAY_VERSION:-26.2.6}"
ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/v${VER}/Xray-linux-64.zip"
mkdir -p "$CACHE"
XRAY_BIN="${CACHE}/xray-${VER}"
if [ ! -x "$XRAY_BIN" ]; then
  echo "Downloading Xray ${VER}..." >&2
  curl -fsSL "$ZIP_URL" -o "${CACHE}/xray.zip"
  unzip -p "${CACHE}/xray.zip" xray > "$XRAY_BIN"
  chmod +x "$XRAY_BIN"
fi
OUT="${CACHE}/x25519.txt"
"$XRAY_BIN" x25519 > "$OUT"
PRIV=$(grep '^PrivateKey:' "$OUT" | sed 's/^PrivateKey:[[:space:]]*//' | tr -d '\r')
# Xray 26+: "Password:" is the public key material (see main/commands/all/curve25519.go)
PUB=$(grep '^Password:' "$OUT" | sed 's/^Password:[[:space:]]*//' | tr -d '\r')
if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
  echo "Failed to parse x25519 output:" >&2
  cat "$OUT" >&2
  exit 1
fi
SID=$(openssl rand -hex 8 2>/dev/null || echo "a1b2c3d4e5f67890")

# v2 Reality keypair for primary inbounds (must be isolated from xray_reality).
"$XRAY_BIN" x25519 > "${OUT}.v2"
V2_PRIV=$(grep '^PrivateKey:' "${OUT}.v2" | sed 's/^PrivateKey:[[:space:]]*//' | tr -d '\r')
V2_PUB=$(grep '^Password:' "${OUT}.v2" | sed 's/^Password:[[:space:]]*//' | tr -d '\r')
V2_SID=$(openssl rand -hex 8 2>/dev/null || echo "abcd1234ef567890")

# Fallback Reality keypair (must be isolated from primary).
"$XRAY_BIN" x25519 > "${OUT}.fallback"
FB_PRIV=$(grep '^PrivateKey:' "${OUT}.fallback" | sed 's/^PrivateKey:[[:space:]]*//' | tr -d '\r')
FB_PUB=$(grep '^Password:' "${OUT}.fallback" | sed 's/^Password:[[:space:]]*//' | tr -d '\r')
FB_SID=$(openssl rand -hex 8 2>/dev/null || echo "f1e2d3c4b5a69708")

cat <<EOF
# SPDX-License-Identifier: MIT-0
# Сгенерировано tests/scripts/gen-reality-keys.sh — только для тестов.
---
xray_reality:
  private_key: "${PRIV}"
  public_key: "${PUB}"
  spiderX: "/"
  short_id:
    - "${SID}"

xray_v2_reality:
  private_key: "${V2_PRIV}"
  public_key: "${V2_PUB}"
  spiderX: "/"
  short_id:
    - "${V2_SID}"

xray_fallback_reality:
  private_key: "${FB_PRIV}"
  public_key: "${FB_PUB}"
  spiderX: "/"
  short_id:
    - "${FB_SID}"

xray_users:
  - id: "11111111-2222-3333-4444-555555555555"
    flow: "xtls-rprx-vision"
    email: "test@raven.local"
EOF
