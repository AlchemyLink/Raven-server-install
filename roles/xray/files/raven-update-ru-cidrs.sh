#!/bin/bash
# Refresh RU CIDR sets in the raven_geoblock nft table.
# Idempotent — safe to re-run; failures are non-fatal so a temporary
# upstream hiccup at ipdeny.com doesn't take the table down.

set -uo pipefail

V4_URL="https://www.ipdeny.com/ipblocks/data/countries/ru.zone"
V6_URL="https://www.ipdeny.com/ipv6/ipaddresses/blocks/ru.zone"
TABLE="inet raven_geoblock"
LOG_TAG="raven-geoblock"

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

fetch() {
  local url="$1"
  curl --fail --silent --show-error --max-time 30 --retry 3 --retry-delay 5 "$url"
}

# Refresh one set (v4 or v6) atomically: fetch → flush+add inside a single
# nft -f script, so even if a refresh races with a kernel match the lookup
# never sees an empty set.
refresh_set() {
  local family="$1" set_name="$2" url="$3"
  local data
  if ! data=$(fetch "$url"); then
    log "fetch $url failed; keeping previous $set_name contents"
    return 1
  fi
  local count
  count=$(echo "$data" | grep -cE '^[^[:space:]#]')
  if [[ "$count" -lt 100 ]]; then
    log "WARN: $url returned only $count $family CIDRs — refusing to apply (suspect partial fetch)"
    return 1
  fi
  local elements
  elements=$(echo "$data" | grep -E '^[^[:space:]#]' | paste -sd ',' -)
  if ! nft "flush set $TABLE $set_name; add element $TABLE $set_name { $elements }"; then
    log "ERROR: nft flush+add for $set_name failed"
    return 1
  fi
  log "refreshed $set_name with $count $family prefixes"
}

if ! nft list table $TABLE >/dev/null 2>&1; then
  log "ERROR: table $TABLE not loaded — start raven-geoblock.service first"
  exit 1
fi

refresh_set ipv4 ru_v4 "$V4_URL"
refresh_set ipv6 ru_v6 "$V6_URL"

exit 0
