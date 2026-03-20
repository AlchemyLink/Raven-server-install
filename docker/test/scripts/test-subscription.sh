#!/usr/bin/env bash
# Test subscription URL: HTTP 200, body decodes from base64, optional JSON or vless links.
set -eo pipefail

SUB_URL="${1:-http://subscription-mock:80/sub}"
echo "==> Fetching: $SUB_URL"

RAW="$(curl -fsS --connect-timeout 10 --max-time 60 "$SUB_URL")" || {
  echo "ERROR: curl failed (TLS/firewall/DNS?)"
  exit 1
}

echo "==> Body length: ${#RAW} bytes"

# Trim whitespace
TRIM="$(echo "$RAW" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

decode_b64() {
  echo "$1" | base64 -d 2>/dev/null || echo "$1" | base64 --decode 2>/dev/null
}

DECODED="$(decode_b64 "$TRIM" 2>/dev/null || true)"
if [[ -z "$DECODED" || "$DECODED" == "$TRIM" ]]; then
  echo "WARN: Treating body as plain text (not base64 or decode failed)"
  DECODED="$TRIM"
fi

if echo "$DECODED" | jq -e . >/dev/null 2>&1; then
  echo "==> Valid JSON (jq ok)"
  echo "$DECODED" | jq -c '{has_outbounds: (.outbounds != null), has_inbounds: (.inbounds != null)}' 2>/dev/null || true
  exit 0
fi

if echo "$DECODED" | grep -qE '^vless://|^vmess://|^trojan://|^ss://'; then
  N="$(echo "$DECODED" | grep -cE '^vless://|^vmess://|^trojan://|^ss://' || true)"
  echo "==> Subscription contains $N share link(s) (vless/vmess/trojan/ss)"
  exit 0
fi

echo "ERROR: Decoded payload is neither JSON nor known share links"
echo "---- first 200 chars ----"
echo "${DECODED:0:200}"
exit 1
