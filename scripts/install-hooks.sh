#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push scripts/check-sensitive-data.sh
echo "core.hooksPath -> $(git config --get core.hooksPath)"
echo "Sensitive-data check installed for commit and push."
