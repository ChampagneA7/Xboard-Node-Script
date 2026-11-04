#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT_DIR}/Xboard-Node-Script.sh"
INSTALL_SCRIPT="${ROOT_DIR}/install.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xboard-node-script-test.XXXXXX")
SYSTEMCTL_RESULT=0
SYSTEMCTL_LOG="${TEST_ROOT}/systemctl.log"

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
export XBOARD_SERVICE="xboard-node.service"
export V2BX_SERVICE="V2bX.service"

# shellcheck disable=SC1090
source "$SCRIPT"

require_root() { :; }
require_linux_systemd() { :; }
xboard_installed() { return 0; }

systemctl() {
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    return "$SYSTEMCTL_RESULT"
}

[[ $(normalize_panel_url import.example.com/) == "https://import.example.com" ]] || fail "panel URL normalization"
is_positive_int 4 || fail "positive integer"
if is_positive_int 0; then fail "zero should not be a positive integer"; fi
is_port 65535 || fail "max port"
is_port 0 || fail "zero port"
if is_port 65536; then fail "port above max"; fi
if is_port abc; then fail "non-numeric port"; fi
if is_port 999999999999999999999999; then fail "oversized port"; fi

if bash "$SCRIPT" migrate --panel >/dev/null 2>&1; then
    fail "missing --panel value should fail"
fi
if bash "$SCRIPT" migrate --panel --yes >/dev/null 2>&1; then
    fail "option token must not be accepted as --panel value"
fi
if bash "$SCRIPT" migrate --yes >/dev/null 2>&1; then
    fail "--yes without required parameters should fail"
fi

for command_name in cmd_start cmd_stop cmd_enable cmd_disable; do
    SYSTEMCTL_RESULT=1
    if "$command_name" >/dev/null 2>&1; then
        fail "${command_name} should fail when systemctl fails"
    fi
done

wait_for_health() { return 0; }
SYSTEMCTL_RESULT=1
if cmd_restart >/dev/null 2>&1; then
    fail "cmd_restart should fail when systemctl restart fails"
fi

current_health_port() { printf '65530'; }
curl() { return 1; }
if cmd_health >/dev/null 2>&1; then
    fail "cmd_health should fail when curl fails"
fi

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

# Copying sing_origin should produce the same file atomically.
source_custom="${TEST_ROOT}/source-sing_origin.json"
rm -f "$XBOARD_CUSTOM_CONFIG"
cp "${ROOT_DIR}/tests/fixtures/sing_origin.json" "$source_custom"
copy_sing_origin "$source_custom"
cmp -s "$source_custom" "$XBOARD_CUSTOM_CONFIG" || fail "sing_origin copy mismatch"

# rollback must not stop Xboard-Node when V2bX is unavailable.
: >"$SYSTEMCTL_LOG"
(
    # shellcheck disable=SC2317
    v2bx_installed() { return 1; }
    rollback_to_v2bx
) >/dev/null 2>&1 || true
if grep -q "stop ${XBOARD_SERVICE}" "$SYSTEMCTL_LOG"; then
    fail "rollback stopped Xboard-Node before checking V2bX"
fi

# rollback must not start V2bX if Xboard-Node could not be stopped.
: >"$SYSTEMCTL_LOG"
# shellcheck disable=SC2317
(
    v2bx_installed() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
        if [[ $1 == "stop" && $2 == "$XBOARD_SERVICE" ]]; then
            return 1
        fi
        return 0
    }
    rollback_to_v2bx
) >/dev/null 2>&1 || true
if grep -q "start ${V2BX_SERVICE}" "$SYSTEMCTL_LOG"; then
    fail "rollback started V2bX after failing to stop Xboard-Node"
fi

# Repeated migrations must preserve the original rollback state.
MOCK_V2BX_ACTIVE=1
MOCK_V2BX_ENABLED=1
service_active() { [[ $MOCK_V2BX_ACTIVE -eq 1 ]]; }
service_enabled() { [[ $MOCK_V2BX_ENABLED -eq 1 ]]; }
record_v2bx_state
MOCK_V2BX_ACTIVE=0
MOCK_V2BX_ENABLED=0
record_v2bx_state
# shellcheck disable=SC1090
source "$XBOARD_STATE_FILE"
[[ $V2BX_WAS_ACTIVE -eq 1 && $V2BX_WAS_ENABLED -eq 1 ]] || fail "rollback state was overwritten"

rm -f "$XBOARD_STATE_FILE"
MOCK_V2BX_ACTIVE=0
MOCK_V2BX_ENABLED=1
record_v2bx_state
MOCK_V2BX_ACTIVE=0
MOCK_V2BX_ENABLED=0
record_v2bx_state
# shellcheck disable=SC1090
source "$XBOARD_STATE_FILE"
[[ $V2BX_WAS_ACTIVE -eq 0 && $V2BX_WAS_ENABLED -eq 1 ]] || fail "stopped-enabled state was overwritten"

# A failed post-install migration step must clean up and must not stop V2bX.
migration_trace="${TEST_ROOT}/migration-trace"
# shellcheck disable=SC2317
(
    require_root() { :; }
    require_linux_systemd() { :; }
    check_platform() { :; }
    record_v2bx_state() { :; }
    backup_file() { :; }
    xboard_installed() { return 1; }
    install_machine() { return 0; }
    copy_sing_origin() { return 1; }
    ensure_custom_config_reference() { return 0; }
    stop_v2bx() { printf 'stop-v2bx\n' >>"$migration_trace"; return 0; }
    cleanup_failed_migration() { printf 'cleanup\n' >>"$migration_trace"; return 0; }
    start_xboard() { return 0; }
    if cmd_migrate --panel https://panel.example.com --token token --machine-id 4 --yes >/dev/null 2>&1; then
        exit 1
    fi
    exit 0
) || fail "migration copy failure should return non-zero"
[[ $(cat "$migration_trace") == "cleanup" ]] || fail "migration did not clean up after copy failure"

# Inline top-level kernel mappings are rejected instead of being corrupted.
inline_config="${TEST_ROOT}/inline-config.yml"
printf 'kernel: {type: singbox}\ninstances: []\n' >"$inline_config"
XBOARD_CONFIG="$inline_config" ensure_custom_config_reference >/dev/null 2>&1 && \
    fail "inline kernel config should be rejected"

printf '[PASS] all tests passed\n'
