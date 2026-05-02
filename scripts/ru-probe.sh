#!/usr/bin/env bash
#
# ru-probe.sh — out-of-band probe agent that runs on a RU mobile uplink and
# reports back to the AlchemyLink dashboard. Designed for Termux on Android,
# OpenWrt with USB modem, or a Raspberry Pi with 4G dongle.
#
# Tests three independent things, all of which are invisible to a probe sent
# from EU or RU broadband:
#   1. TCP connect to our RU VPS  → did our public IP fall out of the L3
#      whitelist on this carrier?
#   2. TLS handshake with each Reality SNI in our pool   → did the SNI fall
#      out of the L7 whitelist (DPI-level filter)?
#   3. DNS resolution of every *.zirgate.com name        → did the carrier
#      DNS resolver poison or block our domains?
#
# The result is POSTed as a single JSON document to the dashboard ingest
# endpoint. If three consecutive POSTs fail, falls back to the Telegram bot
# (set TG_BOT_TOKEN + TG_CHAT_ID in the config).
#
# Hard requirements: bash 4+, curl, openssl, nc, getent.
# Optional: dig (used when present, falls back to getent for DNS probe).

set -u
# Don't use -e — probe failures are the signal we're collecting; aborting on
# the first failed check would silently truncate the report.

VERSION="1"
USAGE="usage: $0 [-c CONFIG_PATH]"

CONFIG_PATH=""
while getopts "c:h" opt; do
    case "$opt" in
        c) CONFIG_PATH="$OPTARG" ;;
        h) echo "$USAGE"; exit 0 ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
done

# Default config search order: explicit -c, env $RU_PROBE_CONFIG, then a few
# conventional locations. First match wins.
if [ -z "$CONFIG_PATH" ]; then
    for candidate in \
        "${RU_PROBE_CONFIG:-}" \
        "$HOME/.config/ru-probe.conf" \
        "/etc/ru-probe.conf" \
        "$(dirname "$0")/ru-probe.conf"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            CONFIG_PATH="$candidate"
            break
        fi
    done
fi

if [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ]; then
    echo "ru-probe: no config found (tried ~/.config/ru-probe.conf, /etc/ru-probe.conf, alongside the script). Pass -c PATH or set RU_PROBE_CONFIG." >&2
    exit 2
fi

# shellcheck disable=SC1090
. "$CONFIG_PATH"

# Required config vars; missing ones are a hard fail because submitting
# half-blank reports would give a false sense of coverage.
required_vars="DASHBOARD_URL PROBE_TOKEN TARGET_IP TARGET_PORT SNIS DNS_NAMES"
for var in $required_vars; do
    if [ -z "${!var:-}" ]; then
        echo "ru-probe: required config var '$var' is empty in $CONFIG_PATH" >&2
        exit 2
    fi
done

STATE_DIR="${STATE_DIR:-$HOME/.local/state/ru-probe}"
mkdir -p "$STATE_DIR"
FAIL_COUNTER="$STATE_DIR/post-failures"

# ── helpers ──────────────────────────────────────────────────────────────────

# json_escape: escape a string for safe inclusion in a JSON value. Handles the
# four characters JSON specifies (\ " newline tab); other control chars get
# stripped because we never expect them in output we care about.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

now_ms() { date +%s%3N; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── carrier detection ────────────────────────────────────────────────────────
#
# Looks up the public IP, then queries ipinfo.io for the AS organization,
# then maps that to one of the recognised RU mobile carriers. Result drives
# how the dashboard groups probes — wrong-but-present is acceptable, blank
# is not, so we always fall back to "unknown".

detect_public_ip() {
    # Two providers in case one is reachability-blocked or rate-limited.
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [ -z "$ip" ]; then
        ip=$(curl -s --max-time 5 https://ifconfig.co 2>/dev/null) || true
    fi
    printf '%s' "${ip:-unknown}"
}

detect_carrier() {
    local public_ip="$1"
    if [ "$public_ip" = "unknown" ]; then
        echo "unknown"; return
    fi
    local org
    org=$(curl -s --max-time 5 "https://ipinfo.io/${public_ip}/json" 2>/dev/null \
        | grep -oE '"org"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"org"[[:space:]]*:[[:space:]]*"(.*)"/\1/')
    org=$(printf '%s' "$org" | tr '[:upper:]' '[:lower:]')

    case "$org" in
        *megafon*)              echo "megafon" ;;
        *mts*|*"mobile telesystems"*) echo "mts" ;;
        *beeline*|*vimpel*)     echo "beeline" ;;
        *tele2*|*"t2 mobile"*)  echo "tele2" ;;
        *yota*|*scartel*)       echo "yota" ;;
        *)                      echo "unknown" ;;
    esac
}

# ── probes ───────────────────────────────────────────────────────────────────

probe_tcp() {
    local target="$1" port="$2"
    local start end ok=false err=""
    start=$(now_ms)
    if nc -z -w 5 "$target" "$port" 2>/dev/null; then
        ok=true
    else
        err="tcp_refused_or_timeout"
    fi
    end=$(now_ms)
    local latency=$((end - start))
    printf '{"target":"%s:%s","ok":%s,"latency_ms":%d,"error":"%s"}' \
        "$(json_escape "$target")" "$port" "$ok" "$latency" "$(json_escape "$err")"
}

probe_tls() {
    local target="$1" port="$2" sni="$3"
    local start end ok=false err="" out
    start=$(now_ms)
    out=$(echo | timeout 10 openssl s_client \
        -connect "$target:$port" \
        -servername "$sni" \
        -verify_return_error 2>&1 < /dev/null)
    local rc=$?
    end=$(now_ms)
    local latency=$((end - start))

    if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q -E 'Verify return code: 0|^---$'; then
        ok=true
    else
        # Capture only the first line of openssl error — full output is noisy
        # and the first line carries the diagnostic ("connect: Connection
        # refused", "no peer certificate available", etc.).
        err=$(printf '%s' "$out" | grep -m1 -E 'error|refused|timeout|unable|verify return code' | head -c 200)
        if [ -z "$err" ]; then err="tls_handshake_failed_rc=$rc"; fi
    fi
    printf '{"target":"%s:%s","sni":"%s","ok":%s,"handshake_ms":%d,"error":"%s"}' \
        "$(json_escape "$target")" "$port" \
        "$(json_escape "$sni")" "$ok" "$latency" \
        "$(json_escape "$err")"
}

probe_dns() {
    local name="$1"
    local answers="" ok=false err=""
    if command -v dig >/dev/null 2>&1; then
        answers=$(dig +short +time=3 +tries=1 "$name" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    else
        # getent hosts returns one line per A/AAAA record: "<ip>  <name>".
        answers=$(getent hosts "$name" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')
    fi
    if [ -n "$answers" ]; then
        ok=true
    else
        err="no_answer"
    fi
    # Build JSON answers array.
    local answers_json="["
    local first=true
    for a in $answers; do
        if $first; then first=false; else answers_json="$answers_json,"; fi
        answers_json="$answers_json\"$(json_escape "$a")\""
    done
    answers_json="$answers_json]"

    printf '{"name":"%s","ok":%s,"answers":%s,"error":"%s"}' \
        "$(json_escape "$name")" "$ok" "$answers_json" "$(json_escape "$err")"
}

# ── main probe sweep ─────────────────────────────────────────────────────────

run_probes() {
    local public_ip carrier client_ts
    client_ts=$(now_iso)
    public_ip=$(detect_public_ip)
    carrier=$(detect_carrier "$public_ip")

    # TCP: just one (the RU VPS at $TARGET_IP:$TARGET_PORT).
    local tcp_results
    tcp_results="[$(probe_tcp "$TARGET_IP" "$TARGET_PORT")]"

    # TLS: one per SNI.
    local tls_results="["
    local first=true
    for sni in $SNIS; do
        if $first; then first=false; else tls_results="$tls_results,"; fi
        tls_results="$tls_results$(probe_tls "$TARGET_IP" "$TARGET_PORT" "$sni")"
    done
    tls_results="$tls_results]"

    # DNS: one per name.
    local dns_results="["
    first=true
    for name in $DNS_NAMES; do
        if $first; then first=false; else dns_results="$dns_results,"; fi
        dns_results="$dns_results$(probe_dns "$name")"
    done
    dns_results="$dns_results]"

    cat <<EOF
{
  "schema": $VERSION,
  "carrier": "$(json_escape "$carrier")",
  "public_ip": "$(json_escape "$public_ip")",
  "client_ts": "$client_ts",
  "results": {
    "tcp": $tcp_results,
    "tls": $tls_results,
    "dns": $dns_results
  }
}
EOF
}

# ── delivery ─────────────────────────────────────────────────────────────────

post_dashboard() {
    local payload="$1"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 30 \
        -X POST \
        -H "X-Probe-Token: $PROBE_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "${DASHBOARD_URL%/}/api/external/probe-result")
    [ "$code" = "204" ]
}

# Telegram fallback path — used only when post_dashboard has failed N times in
# a row. The bot needs sendMessage scope and TG_CHAT_ID must be a chat the bot
# already participates in (start a private chat first).
post_telegram_fallback() {
    local payload="$1"
    if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        return 1
    fi
    # Trim payload preview so it fits Telegram's 4096-char message limit.
    local preview
    preview=$(printf '%s' "$payload" | head -c 3500)
    local msg
    msg="📡 ru-probe fallback delivery (dashboard unreachable)
\`\`\`json
$preview
\`\`\`"
    curl -s --max-time 20 \
        -X POST \
        -d "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${msg}" \
        -d "parse_mode=Markdown" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        >/dev/null
}

read_failure_count() {
    if [ -f "$FAIL_COUNTER" ]; then cat "$FAIL_COUNTER"; else echo 0; fi
}

bump_failure_count() {
    local n
    n=$(read_failure_count)
    echo $((n + 1)) > "$FAIL_COUNTER"
}

reset_failure_count() {
    rm -f "$FAIL_COUNTER"
}

# ── entrypoint ───────────────────────────────────────────────────────────────

main() {
    payload=$(run_probes)

    if post_dashboard "$payload"; then
        reset_failure_count
        echo "ru-probe: ok ($(now_iso))"
        return 0
    fi

    bump_failure_count
    fails=$(read_failure_count)
    echo "ru-probe: dashboard POST failed (attempt $fails)" >&2

    # Fall back to Telegram once we have three consecutive failures — that's
    # the threshold where the dashboard is more likely down than the network
    # being flaky for one cron tick.
    if [ "$fails" -ge 3 ]; then
        if post_telegram_fallback "$payload"; then
            echo "ru-probe: telegram fallback sent" >&2
            reset_failure_count
            return 0
        fi
        echo "ru-probe: telegram fallback also failed" >&2
    fi
    return 1
}

main "$@"
