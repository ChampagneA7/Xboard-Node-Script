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
export XBOARD_SERVICE="xboard-node.service"

# shellcheck disable=SC1090
source "$SCRIPT"

require_root() { :; }
require_linux_systemd() { :; }
check_platform() { :; }
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

node_summary=$(printf '%s\n' \
    'machine: starting node 9 (vless/🇭🇰香港测试)' \
    'machine: starting node 10 (trojan/测试节点)' | extract_node_summaries)
grep -qx 'node_id=9 protocol=vless' <<<"$node_summary" || fail "vless node summary"
grep -qx 'node_id=10 protocol=trojan' <<<"$node_summary" || fail "trojan node summary"

listener_summary=$(printf '%s\n' \
    '[vless:9011] started, 1 users' \
    '[trojan:9443] started, 1 users' | extract_listener_summaries)
grep -qx 'vless:9011' <<<"$listener_summary" || fail "vless listener summary"
grep -qx 'trojan:9443' <<<"$listener_summary" || fail "trojan listener summary"

printf '%s\n' 'ERROR machine instance exited with error' | runtime_log_has_fatal_error \
    || fail "machine fatal runtime error not detected"
printf '%s\n' 'machine nodes status 403' | runtime_log_has_fatal_error \
    || fail "machine 403 error not detected"
if printf '%s\n' 'INFO service started' | runtime_log_has_fatal_error; then
    fail "normal startup log marked fatal"
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

# The menu must only expose the commands that still exist.
menu_output=$(show_menu)
grep -q '14.*update-script' <<<"$menu_output" || fail "update-script menu item missing"
grep -q '15.*退出' <<<"$menu_output" || fail "exit menu item missing"

help_output=$(bash "$SCRIPT" help)
grep -q 'update-script' <<<"$help_output" || fail "update-script help entry missing"

# Installation still invokes the official installer with the selected mode.
install_args=""
prompt_value() {
    case "$2" in
        "面板地址") printf -v "$1" '%s' "import.example.com" ;;
        "Machine ID") printf -v "$1" '%s' "4" ;;
        "Machine Token") printf -v "$1" '%s' "token" ;;
        "内核 (singbox/xray)") printf -v "$1" '%s' "singbox" ;;
        "健康检查端口") printf -v "$1" '%s' "65530" ;;
        *) return 1 ;;
    esac
}
choose_mode() { printf -v "$1" '%s' "machine"; }
run_official_installer() { install_args="$*"; return 0; }
start_xboard() { return 0; }
xboard_installed() { return 1; }
cmd_install >/dev/null || fail "cmd_install failed with mocked installer"
grep -q -- '--mode machine' <<<"$install_args" || fail "install mode missing"
grep -q -- '--machine-id 4' <<<"$install_args" || fail "machine id missing"
grep -q -- '--health-port 65530' <<<"$install_args" || fail "health port missing"

printf '[PASS] all tests passed\n'
