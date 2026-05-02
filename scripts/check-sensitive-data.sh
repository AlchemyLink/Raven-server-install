#!/usr/bin/env bash
# Block sensitive data from leaking into a public mirror.
# Modes:
#   --staged           scan `git diff --cached` (pre-commit)
#   --push <range>     scan commits in <range> (pre-push); range defaults to @{u}..HEAD
set -uo pipefail

mode="${1:---staged}"
range="${2:-}"

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "check-sensitive-data: not in a git repo" >&2
    exit 0
}
cd "$repo_root"

# --- Build IP list from inventory ---
# Source of truth: roles/hosts.yml (gitignored). Without it, IP scanning is a
# no-op — that is fine: anyone without inventory has nothing to leak.
# Do NOT hardcode real IPs here; this script is committed to a public repo.
ips=()
if [ -f roles/hosts.yml ]; then
    while IFS= read -r ip; do
        [ -n "$ip" ] && ips+=("$ip")
    done < <(grep -oE 'ansible_host:[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' roles/hosts.yml \
             | awk '{print $2}' | sort -u)
fi

# --- Collect added lines from the relevant diff ---
case "$mode" in
    --staged)
        added=$(git diff --cached -U0 -- ':(exclude)scripts/check-sensitive-data.sh' \
                | grep -E '^\+' | grep -v '^+++ ' || true)
        ;;
    --push)
        if [ -z "$range" ]; then
            upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
            if [ -n "$upstream" ]; then
                range="${upstream}..HEAD"
            else
                # No upstream yet — this is the first push of a new branch.
                # Scan only the commits that this branch adds on top of the
                # default base (origin/main, then origin/master), not the
                # entire reachable history from HEAD which would re-flag every
                # placeholder/test-fixture already on the default branch.
                base=""
                for candidate in origin/main origin/master; do
                    if git rev-parse --verify --quiet "$candidate" >/dev/null; then
                        base=$(git merge-base "$candidate" HEAD 2>/dev/null || true)
                        [ -n "$base" ] && break
                    fi
                done
                if [ -n "$base" ]; then
                    range="${base}..HEAD"
                else
                    # No origin/main or origin/master visible — fall back to
                    # the original "scan everything" behaviour. Last resort.
                    range="HEAD"
                fi
            fi
        fi
        added=$(git log -p -U0 "$range" -- ':(exclude)scripts/check-sensitive-data.sh' \
                | grep -E '^\+' | grep -v '^+++ ' || true)
        ;;
    *)
        echo "Usage: $0 [--staged | --push <range>]" >&2
        exit 2
        ;;
esac

[ -z "$added" ] && exit 0

findings=""

# 1. Real IPs (with placeholder allowlist 0.0.0.0 / 127.0.0.1 / 10.x / 192.168.x)
for ip in "${ips[@]:-}"; do
    pat=${ip//./\\.}
    matches=$(printf '%s\n' "$added" | grep -nE "(^|[^0-9.])${pat}([^0-9.]|$)" || true)
    if [ -n "$matches" ]; then
        findings+="REAL_IP[${ip}]:
${matches}

"
    fi
done

# 2. Telegram bot token
matches=$(printf '%s\n' "$added" | grep -nE '\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\b' || true)
[ -n "$matches" ] && findings+="TELEGRAM_BOT_TOKEN:
${matches}

"

# 3. PEM private key block
matches=$(printf '%s\n' "$added" | grep -nE 'BEGIN (RSA |OPENSSH |EC |DSA |)PRIVATE KEY' || true)
[ -n "$matches" ] && findings+="PEM_PRIVATE_KEY:
${matches}

"

# 4. Reality private_key / public_key assignments outside vault
matches=$(printf '%s\n' "$added" \
          | grep -nE '(private_key|publicKey|short_id):[[:space:]]*["'\'']?[A-Za-z0-9_/+=-]{20,}' \
          | grep -v '^\$ANSIBLE_VAULT' || true)
[ -n "$matches" ] && findings+="POSSIBLE_REALITY_KEY:
${matches}

"

# 5. mldsa65_seed assignment
matches=$(printf '%s\n' "$added" | grep -nE 'mldsa65_seed:[[:space:]]*["'\'']?[A-Fa-f0-9]{30,}' || true)
[ -n "$matches" ] && findings+="MLDSA65_SEED:
${matches}

"

# 6. Generic admin/jwt/api token assignment (hex 32+ near token-like key)
matches=$(printf '%s\n' "$added" \
          | grep -niE '(admin_token|jwt_secret|api_token|bot_token|secret_key)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Fa-f0-9]{32,}' \
          | grep -v '^\$ANSIBLE_VAULT' || true)
[ -n "$matches" ] && findings+="POSSIBLE_TOKEN:
${matches}

"

# 7. UUID assignment (xray user IDs) outside vault — best-effort, expect noise in fixtures
matches=$(printf '%s\n' "$added" \
          | grep -nE '\bid:[[:space:]]*["'\'']?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
          | grep -v '^\$ANSIBLE_VAULT' || true)
[ -n "$matches" ] && findings+="POSSIBLE_USER_UUID:
${matches}

"

# 8. Plaintext secrets.yml (only meaningful in --staged mode)
if [ "$mode" = "--staged" ]; then
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
            */secrets.yml|*/secrets.yaml|secrets.yml|secrets.yaml|*_secrets.yml|*_secrets.yaml)
                if [ -f "$f" ] && ! head -n1 "$f" | grep -q '^\$ANSIBLE_VAULT;'; then
                    findings+="UNENCRYPTED_SECRETS_FILE: ${f}

"
                fi
                ;;
        esac
    done < <(git diff --cached --name-only --diff-filter=AM)
fi

if [ -n "$findings" ]; then
    {
        echo
        echo "================================================================"
        echo " check-sensitive-data: BLOCKED — sensitive data in ${mode#--}"
        echo "================================================================"
        printf '%s' "$findings"
        echo "If this is intentional, bypass with --no-verify (and double-check)."
        echo
    } >&2
    exit 1
fi

exit 0
