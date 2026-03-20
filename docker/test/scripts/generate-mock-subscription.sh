#!/usr/bin/env bash
# Generates mock-sub/sub.b64 from a minimal Xray JSON (for nginx /sub endpoint).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON="$ROOT/mock-sub/sample-client-config.json"
OUT="$ROOT/mock-sub/sub.b64"

if [[ ! -f "$JSON" ]]; then
  echo "Missing $JSON"
  exit 1
fi

base64 -w0 "$JSON" > "$OUT" 2>/dev/null || base64 "$JSON" | tr -d '\n' > "$OUT"
echo "Wrote $OUT ($(wc -c < "$OUT") bytes base64)"
