#!/usr/bin/env bash
# Bulk-rotate sub_tokens for all (or filtered) users in xray-subscription.
#
# Touches ONLY users.token via POST /api/users/{id}/token. Does NOT change
# UUIDs, fallback_token, Reality keys, or VLESS encryption — active VPN
# sessions stay alive; only the subscription URL changes.
#
# Usage:
#   RAVEN_ADMIN_TOKEN=... ./bulk-rotate-subtokens.sh [--dry-run] [--yes]
#                                                    [--api URL] [--exclude RE]
#                                                    [--include-disabled]
#                                                    [--sleep-ms N]
#
# CSV output (stdout): id,username,enabled,old_token,new_token,new_sub_url
# Progress + errors:   stderr
#
# Exit codes:
#   0 — all rotations succeeded (or dry-run completed)
#   1 — usage / pre-flight error
#   2 — at least one rotation failed; CSV still written for successful ones

set -euo pipefail

api="${RAVEN_API:-http://127.0.0.1:8080}"
exclude_re=""
dry_run=0
assume_yes=0
include_disabled=0
sleep_ms=100

while (($#)); do
    case "$1" in
        --dry-run)           dry_run=1 ;;
        --yes|-y)            assume_yes=1 ;;
        --api)               api="$2"; shift ;;
        --exclude)           exclude_re="$2"; shift ;;
        --include-disabled)  include_disabled=1 ;;
        --sleep-ms)          sleep_ms="$2"; shift ;;
        -h|--help)
            sed -n '2,18p' "$0" >&2
            exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

: "${RAVEN_ADMIN_TOKEN:?env RAVEN_ADMIN_TOKEN is required}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

# 1. Fetch user list
users_json=$(curl -fsS -H "X-Admin-Token: $RAVEN_ADMIN_TOKEN" "$api/api/users")

# 2. Filter (API returns [{user: {...}, sub_url, sub_urls}, ...])
filter='.[] | .user'
((include_disabled)) || filter="$filter | select(.enabled == 1 or .enabled == true)"
[[ -n "$exclude_re" ]] && filter="$filter | select(.username | test(\"$exclude_re\") | not)"

mapfile -t rows < <(jq -r "$filter | [.id, .username, (.enabled|tostring), .token] | @tsv" <<<"$users_json")

total=${#rows[@]}
if ((total == 0)); then
    echo "no users matched filters" >&2
    exit 0
fi

echo "matched users: $total" >&2
((dry_run)) && echo "DRY RUN — no rotation will happen" >&2

if ! ((assume_yes || dry_run)); then
    printf "rotate sub_token for %d users? [y/N] " "$total" >&2
    read -r reply
    [[ "$reply" =~ ^[yY]$ ]] || { echo "aborted" >&2; exit 1; }
fi

# 3. CSV header
echo "id,username,enabled,old_token,new_token,new_sub_url"

failed=0
done=0
for row in "${rows[@]}"; do
    IFS=$'\t' read -r id username enabled old_token <<<"$row"
    done=$((done + 1))

    if ((dry_run)); then
        printf "%s,%s,%s,%s,DRY,DRY\n" "$id" "$username" "$enabled" "$old_token"
        continue
    fi

    if ! resp=$(curl -fsS -X POST \
                     -H "X-Admin-Token: $RAVEN_ADMIN_TOKEN" \
                     "$api/api/users/$id/token" 2>/dev/null); then
        echo "[$done/$total] FAIL id=$id user=$username" >&2
        failed=$((failed + 1))
        continue
    fi

    new_token=$(jq -r '.token // empty' <<<"$resp")
    sub_url=$(jq -r '.sub_url // empty' <<<"$resp")

    if [[ -z "$new_token" ]]; then
        echo "[$done/$total] FAIL id=$id user=$username (empty token in response)" >&2
        failed=$((failed + 1))
        continue
    fi

    printf "%s,%s,%s,%s,%s,%s\n" "$id" "$username" "$enabled" "$old_token" "$new_token" "$sub_url"
    echo "[$done/$total] ok id=$id user=$username" >&2

    ((sleep_ms > 0)) && sleep "$(awk "BEGIN{print $sleep_ms/1000}")"
done

echo "done: $((total - failed)) ok, $failed failed" >&2
((failed == 0)) || exit 2
