#!/usr/bin/env sh
# Полный тест: секреты → validate → рендер → xray -test (Docker).
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
export ANSIBLE_CONFIG="${ROOT}/ansible.cfg"
cd "$ROOT"
# ansible-playbook ищет роли относительно tests/ansible.cfg (roles_path = ../roles)

echo "==> [1/4] Generate test_secrets.yml (x25519)"
"$ROOT/scripts/gen-reality-keys.sh" > "$ROOT/fixtures/test_secrets.yml"

echo "==> [2/4] ansible-playbook validate_vars.yml"
ansible-playbook "$ROOT/playbooks/validate_vars.yml"

OUT="$ROOT/.output/conf.d"
rm -rf "$ROOT/.output"
mkdir -p "$OUT"
export RAVEN_TEST_CONF_DIR="$OUT"

echo "==> [3/4] ansible-playbook render_conf.yml"
ansible-playbook "$ROOT/playbooks/render_conf.yml"

BRIDGE_OUT="$ROOT/.output/bridge.conf.d"
mkdir -p "$BRIDGE_OUT"
export RAVEN_TEST_BRIDGE_CONF_DIR="$BRIDGE_OUT"

echo "==> [4/5] ansible-playbook render_bridge_conf.yml"
ansible-playbook "$ROOT/playbooks/render_bridge_conf.yml"

echo "==> [5/5] xray -test"
if [ "${SKIP_XRAY_TEST:-}" = "1" ]; then
  echo "SKIP_XRAY_TEST=1 — пропуск xray -test."
  exit 0
fi

run_xray_test() {
  _dir="$1"
  _logdir="${2:-/tmp/raven-xray-test-logs}"
  mkdir -p "$_logdir"
  if command -v xray >/dev/null 2>&1; then
    echo "Using host binary: $(command -v xray)"
    xray -test -confdir "$_dir"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: нужен xray в PATH или Docker. Или: SKIP_XRAY_TEST=1 $0"
    return 1
  fi
  IMG="${RAVEN_XRAY_TEST_IMAGE:-raven-xray-test:local}"
  if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "Building $IMG from docker/test/xray-client ..."
    docker build -t "$IMG" -f "$REPO/docker/test/xray-client/Dockerfile" "$REPO/docker/test/xray-client"
  fi
  _logdir_docker="/tmp/raven-xray-test-logs"
  docker run --rm \
    -v "$_dir:/etc/xray/config.d:ro" \
    --entrypoint /bin/sh \
    "$IMG" \
    -c "mkdir -p ${_logdir_docker} && exec /usr/local/bin/xray -test -confdir /etc/xray/config.d"
}

echo "--- xray role ---"
run_xray_test "$OUT"
echo "--- xray_bridge role ---"
run_xray_test "$BRIDGE_OUT" "/tmp/raven-xray-bridge-test-logs"

echo "OK: all tests passed."
