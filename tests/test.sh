#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT_DIR}/Xboard-Node-Script.sh"
INSTALL_SCRIPT="${ROOT_DIR}/install.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xboard-node-script-test.XXXXXX")

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

bash -n "$SCRIPT" || fail "Xboard-Node-Script.sh syntax"
bash -n "$INSTALL_SCRIPT" || fail "install.sh syntax"

export XBOARD_ROOT="${TEST_ROOT}/xboard"
export XBOARD_CONFIG="${XBOARD_ROOT}/config.yml"
export XBOARD_CUSTOM_CONFIG="${XBOARD_ROOT}/sing_origin.json"
export XBOARD_STATE_FILE="${XBOARD_ROOT}/migration-state.env"

# shellcheck disable=SC1090
source "$SCRIPT"

[[ $(normalize_panel_url import.example.com/) == "https://import.example.com" ]] || fail "panel URL normalization"
is_positive_int 4 || fail "positive integer"
if is_positive_int 0; then fail "zero should not be a positive integer"; fi

mkdir -p "$XBOARD_ROOT"
cat >"$XBOARD_CONFIG" <<'EOF'
instances:
  - id: example
    panel:
      url: https://panel.example.com
    kernel:
      type: singbox
      log_level: warn
EOF

cp "${ROOT_DIR}/tests/fixtures/sing_origin.json" "$XBOARD_CUSTOM_CONFIG"
ensure_custom_config_reference

grep -q '^kernel:$' "$XBOARD_CONFIG" || fail "top-level kernel missing"
grep -q "custom_config: \"$XBOARD_CUSTOM_CONFIG\"" "$XBOARD_CONFIG" || fail "custom_config missing"
grep -q '^instances:$' "$XBOARD_CONFIG" || fail "instances block missing"

# A second invocation must not duplicate the key.
ensure_custom_config_reference
count=$(grep -c "custom_config: \"$XBOARD_CUSTOM_CONFIG\"" "$XBOARD_CONFIG")
[[ $count -eq 1 ]] || fail "custom_config duplicated"

printf '[PASS] all tests passed\n'
