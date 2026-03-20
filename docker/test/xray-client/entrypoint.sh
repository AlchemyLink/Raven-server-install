#!/bin/sh
set -eu

CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"

if [ -n "${SUBSCRIPTION_URL:-}" ]; then
  echo "==> Fetching subscription: $SUBSCRIPTION_URL"
  RAW="$(curl -fsS --connect-timeout 15 --max-time 120 "$SUBSCRIPTION_URL")"
  TRIM="$(echo "$RAW" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  DECODED="$(printf '%s' "$TRIM" | base64 -d 2>/dev/null || true)"
  if [ -z "$DECODED" ]; then
    echo "ERROR: failed to base64-decode subscription body"
    exit 1
  fi
  if echo "$DECODED" | jq -e . >/dev/null 2>&1; then
    echo "$DECODED" > /tmp/config-from-sub.json
    CONFIG=/tmp/config-from-sub.json
    echo "==> Using JSON config from subscription ($(wc -c < "$CONFIG") bytes)"
  else
    echo "ERROR: Subscription is not a JSON Xray config (3x-ui often returns vless:// links)."
    echo "Use a client app to import, or mount a static config.json."
    echo "---- first 120 chars ----"
    printf '%s' "$DECODED" | head -c 120
    echo
    exit 1
  fi
fi

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: No config at $CONFIG (set SUBSCRIPTION_URL for JSON base64 or mount config)"
  exit 1
fi

echo "==> xray -test"
/usr/local/bin/xray -test -c "$CONFIG"

echo "==> xray run"
exec /usr/local/bin/xray run -c "$CONFIG"
