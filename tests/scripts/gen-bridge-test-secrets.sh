#!/usr/bin/env sh
# Генерирует bridge_test_secrets.yml для тестов xray_bridge роли.
# Использует уже скачанный Xray из tests/.cache (gen-reality-keys.sh качает его первым).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${ROOT}/tests/.cache"
VER="${XRAY_VERSION:-26.2.6}"
XRAY_BIN="${CACHE}/xray-${VER}"
if [ ! -x "$XRAY_BIN" ]; then
  echo "ERROR: xray binary not found at ${XRAY_BIN}. Run gen-reality-keys.sh first." >&2
  exit 1
fi

# Bridge Reality keys (RU VPS inbound)
OUT_BRIDGE="${CACHE}/x25519-bridge.txt"
"$XRAY_BIN" x25519 > "$OUT_BRIDGE"
BRIDGE_PRIV=$(grep '^PrivateKey:' "$OUT_BRIDGE" | sed 's/^PrivateKey:[[:space:]]*//' | tr -d '\r')
BRIDGE_PUB=$(grep '^Password:' "$OUT_BRIDGE" | sed 's/^Password:[[:space:]]*//' | tr -d '\r')
BRIDGE_SID=$(openssl rand -hex 8 2>/dev/null || echo "b1c2d3e4f5a67890")

# EU Reality public key (what the bridge outbound connects to — simulate EU side)
OUT_EU="${CACHE}/x25519-eu.txt"
"$XRAY_BIN" x25519 > "$OUT_EU"
EU_PUB=$(grep '^Password:' "$OUT_EU" | sed 's/^Password:[[:space:]]*//' | tr -d '\r')
EU_SID=$(openssl rand -hex 8 2>/dev/null || echo "cc8ec8e23620ea90")

cat <<EOF
# SPDX-License-Identifier: MIT-0
# Сгенерировано tests/scripts/gen-bridge-test-secrets.sh — только для тестов CI.
---
xray_bridge_reality:
  private_key: "${BRIDGE_PRIV}"
  public_key:  "${BRIDGE_PUB}"
  spiderX: "/"
  short_id:
    - "${BRIDGE_SID}"

xray_bridge_users:
  - id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    flow: "xtls-rprx-vision"
    email: "bridge-test@raven.local"

xray_bridge_eu_host: "1.2.3.4"
xray_bridge_eu_reality_public_key: "${EU_PUB}"
xray_bridge_eu_reality_short_id: "${EU_SID}"
xray_bridge_eu_user_id: "11111111-2222-3333-4444-555555555555"
EOF
