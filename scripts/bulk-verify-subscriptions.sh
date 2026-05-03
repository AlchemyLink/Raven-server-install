#!/usr/bin/env bash
# Read-only health check: fetch every active user's subscription URL through
# the public path (Cloudflare → RU stream → EU) and assert HTTP 200 with a
# non-trivial body. Catches DB↔Xray drift the Sync Health card misses —
# e.g. user enabled in DB but missing from inbound clients[] array, which
# returns 404 from raven-subscribe even though everything else looks healthy.
#
# Usage:
#   ./bulk-verify-subscriptions.sh [--db PATH] [--primary URL] [--fallback URL]
#                                  [--sleep-ms N] [--min-primary BYTES]
#                                  [--min-fallback BYTES] [--quiet]
#
# Exits 0 if all URLs are 200 with body >= min size, 1 if any fail.
# Designed for cron + Telegram alert hookup. Tokens are NEVER logged.
#
# Stdout: TSV per-user line + summary on the last line.
# Stderr: progress + failure detail.

set -euo pipefail

db="/var/lib/xray-subscription/db.sqlite"
primary_base="https://my.zirgate.com"
fallback_base="https://sub.zirgate.com"
sleep_ms=500
min_primary=1000
min_fallback=500
quiet=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db) db="$2"; shift 2 ;;
        --primary) primary_base="$2"; shift 2 ;;
        --fallback) fallback_base="$2"; shift 2 ;;
        --sleep-ms) sleep_ms="$2"; shift 2 ;;
        --min-primary) min_primary="$2"; shift 2 ;;
        --min-fallback) min_fallback="$2"; shift 2 ;;
        --quiet) quiet=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

for cmd in sqlite3 curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not found" >&2; exit 1; }
done
[[ -r "$db" ]] || { echo "cannot read $db (need root or xrayuser)" >&2; exit 1; }

log() { [[ $quiet -eq 1 ]] || echo "$@" >&2; }

users=$(sqlite3 -separator $'\t' "$db" \
    "SELECT email, token, COALESCE(fallback_token,'') FROM users
     WHERE enabled=1 AND token IS NOT NULL AND token != ''
     ORDER BY email;")

total=0; primary_ok=0; fallback_ok=0; failures=()

while IFS=$'\t' read -r email token fallback_token; do
    [[ -z "$email" ]] && continue
    total=$((total + 1))

    p_url="${primary_base}/c/${token}/links.txt"
    p_result=$(curl -so /dev/null -w '%{http_code}|%{size_download}' \
        --max-time 15 "$p_url" 2>/dev/null || echo '000|0')
    p_code="${p_result%%|*}"; p_size="${p_result##*|}"
    if [[ "$p_code" == "200" && "$p_size" -ge "$min_primary" ]]; then
        primary_ok=$((primary_ok + 1)); p_status="OK"
    else
        p_status="FAIL"
        failures+=("$email primary=${p_code}/${p_size}B")
    fi

    if [[ -n "$fallback_token" ]]; then
        f_url="${fallback_base}/c/fallback/${fallback_token}/links.txt"
        f_result=$(curl -so /dev/null -w '%{http_code}|%{size_download}' \
            --max-time 15 "$f_url" 2>/dev/null || echo '000|0')
        f_code="${f_result%%|*}"; f_size="${f_result##*|}"
        if [[ "$f_code" == "200" && "$f_size" -ge "$min_fallback" ]]; then
            fallback_ok=$((fallback_ok + 1)); f_status="OK"
        else
            f_status="FAIL"
            failures+=("$email fallback=${f_code}/${f_size}B")
        fi
    else
        f_code="-"; f_size="-"; f_status="SKIP"
    fi

    printf '%s\tprimary=%s/%sB\tfallback=%s/%sB\n' \
        "$email" "$p_code" "$p_size" "$f_code" "$f_size"

    sleep "0.$(printf '%03d' "$sleep_ms")"
done <<< "$users"

log ""
log "═══ Summary ═══"
log "Total active users: $total"
log "Primary OK:         $primary_ok / $total"
log "Fallback OK:        $fallback_ok / (users with fallback_token)"

if [[ ${#failures[@]} -gt 0 ]]; then
    log ""
    log "Failures (${#failures[@]}):"
    for f in "${failures[@]}"; do log "  $f"; done
    printf 'SUMMARY\tFAIL\t%d_users\tprimary_ok=%d/%d\n' \
        "${#failures[@]}" "$primary_ok" "$total"
    exit 1
fi

printf 'SUMMARY\tOK\t%d_users\tprimary_ok=%d/%d\tfallback_ok=%d\n' \
    "$total" "$primary_ok" "$total" "$fallback_ok"
exit 0
