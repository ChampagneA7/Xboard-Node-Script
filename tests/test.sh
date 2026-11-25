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
export XBOARD_RELAY_ROOT="${TEST_ROOT}/relay"
export XBOARD_SS2022_VERSION_FILE="${TEST_ROOT}/ss-rust-version"
export XBOARD_SS2022_CONFIG="${TEST_ROOT}/ss-rust/config.json"
export XBOARD_FIREWALL_ROOT="${TEST_ROOT}/firewall"
export XBOARD_FIREWALL_SERVICE_FILE="${TEST_ROOT}/xns-firewall.service"

# shellcheck disable=SC1090
source "$SCRIPT"

require_root() { :; }
require_linux_systemd() { :; }
check_platform() { :; }
# shellcheck disable=SC2317 # Invoked indirectly by the sourced script.
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
is_ipv4 203.0.113.10 || fail "valid IPv4"
if is_ipv4 203.0.113.256; then fail "IPv4 octet above 255"; fi
if is_ipv4 203.0.113; then fail "incomplete IPv4"; fi
is_service_port 1 || fail "port 1"
if is_service_port 0; then fail "port 0 should not be accepted"; fi
[[ $(normalize_port_specs '80,443/tcp,53/udp') == "80/tcp,80/udp,443/tcp,53/udp" ]] \
    || fail "normalize port specs"
[[ $(normalize_port_specs '80 80') == "80/tcp,80/udp" ]] \
    || fail "deduplicate port specs"
[[ $(normalize_port_specs '1000-2000/tcp') == "1000-2000/tcp" ]] \
    || fail "port range normalization"
[[ $(merge_port_specs '22/tcp,80/tcp' '22/tcp,80/udp') == "22/tcp,80/tcp,80/udp" ]] \
    || fail "merge port specs"
if normalize_port_specs '0'; then fail "zero port spec accepted"; fi
if normalize_port_specs '2000-1000/tcp'; then fail "reverse port range accepted"; fi
if normalize_port_specs '80/icmp'; then fail "invalid port protocol accepted"; fi
port_specs_overlap '20-30/tcp' '22/tcp' || fail "overlapping TCP port range"
if port_specs_overlap '20-30/tcp' '22/udp'; then fail "protocol mismatch counted as overlap"; fi
ssh_specs=$(SSH_CONNECTION='198.51.100.10 40000 203.0.113.10 2222' \
    detect_ssh_port_specs)
grep -q '2222/tcp' <<<"$ssh_specs" || fail "SSH connection port detection"
grep -q '22/tcp' <<<"$ssh_specs" || fail "port 22 SSH protection"
port_specs_overlap "$(normalize_port_specs '22')" "$ssh_specs" \
    || fail "blacklist port 22 should overlap SSH protection"
whitelist_rules=$(firewall_rules_text whitelist '22/tcp,80/tcp,80/udp') \
    || fail "generate whitelist rules"
grep -q 'priority -250' <<<"$whitelist_rules" || fail "whitelist priority"
grep -q 'tcp dport 80 accept' <<<"$whitelist_rules" || fail "whitelist TCP rule"
grep -q 'udp dport 80 accept' <<<"$whitelist_rules" || fail "whitelist UDP rule"
grep -q 'counter drop' <<<"$whitelist_rules" || fail "whitelist default deny"
blacklist_rules=$(firewall_rules_text blacklist '52/tcp,52/udp') \
    || fail "generate blacklist rules"
grep -q 'tcp dport 52 drop' <<<"$blacklist_rules" || fail "blacklist TCP rule"
grep -q 'udp dport 52 drop' <<<"$blacklist_rules" || fail "blacklist UDP rule"
ufw_block=$(firewall_ufw_block_text whitelist '22/tcp,80/tcp' ufw-before-input) \
    || fail "generate UFW block"
grep -q -- "-A ufw-before-input -j ${UFW_CHAIN_NAME}" <<<"$ufw_block" || fail "UFW input jump"
grep -q -- "-A ${UFW_CHAIN_NAME} -p tcp --dport 80 -j ACCEPT" <<<"$ufw_block" \
    || fail "UFW whitelist rule"
grep -q -- "-A ${UFW_CHAIN_NAME} -j DROP" <<<"$ufw_block" || fail "UFW default drop"
ufw_source="${TEST_ROOT}/ufw-before.rules"
ufw_candidate="${TEST_ROOT}/ufw-before.candidate"
ufw_rules_file="${TEST_ROOT}/ufw-block.txt"
cat >"$ufw_source" <<'EOF'
*filter
:ufw-before-input - [0:0]
# End required lines
COMMIT
EOF
printf '%s\n' "$ufw_block" >"$ufw_rules_file"
firewall_insert_ufw_block "$ufw_source" "$ufw_rules_file" "$ufw_candidate" \
    || fail "insert UFW managed block"
grep -A2 '^# End required lines$' "$ufw_candidate" | grep -q "^:${UFW_CHAIN_NAME}" \
    || fail "UFW chain declaration position"
grep -q -- "-A ufw-before-input -j ${UFW_CHAIN_NAME}" "$ufw_candidate" \
    || fail "UFW jump insertion"
firewall_remove_ufw_block "$ufw_candidate" "${TEST_ROOT}/ufw-before.cleared"
if grep -q 'XNS_PORT' "${TEST_ROOT}/ufw-before.cleared"; then
    fail "UFW managed block cleanup"
fi
firewalld_rules=$(firewall_firewalld_rich_rules_text whitelist '22/tcp,80/tcp') \
    || fail "generate firewalld rules"
grep -q 'priority="-31999".*port port="80".*protocol="tcp" accept' <<<"$firewalld_rules" \
    || fail "firewalld whitelist rule"
grep -q 'priority="-31998".*family="ipv6".*drop' <<<"$firewalld_rules" \
    || fail "firewalld default drop"
mkdir -p "${TEST_ROOT}/fakebin"
cat >"${TEST_ROOT}/fakebin/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_FIREWALLD_VERSION:-2.1.1}"
EOF
cat >"${TEST_ROOT}/fakebin/ufw" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${TEST_ROOT}/fakebin/firewall-cmd"
chmod 0755 "${TEST_ROOT}/fakebin/ufw"
PATH="${TEST_ROOT}/fakebin:${PATH}" firewall_firewalld_priority_supported \
    || fail "modern firewalld priority support"
FAKE_FIREWALLD_VERSION="0.8.2" PATH="${TEST_ROOT}/fakebin:${PATH}" \
    firewall_firewalld_priority_supported \
    && fail "legacy firewalld priority should be rejected"
if (
    PATH="${TEST_ROOT}/fakebin:${PATH}"
    firewall_apply_policy blacklist '22' "" 1 ufw
) >/dev/null 2>&1; then
    fail "blacklist accepted protected port 22"
fi
iptables_helper=$(firewall_iptables_helper_text whitelist '22/tcp,80/tcp') \
    || fail "generate iptables helper"
bash -n <<<"$iptables_helper" || fail "iptables helper syntax"
grep -q -- '-I INPUT 1 -j XNS_PORTS' <<<"$iptables_helper" \
    || fail "iptables input jump"
grep -q -- '-A XNS_PORTS -p tcp --dport 80 -j ACCEPT' <<<"$iptables_helper" \
    || fail "iptables whitelist rule"
is_outbound_tag landing-ss2022 || fail "valid outbound tag"
if is_outbound_tag 'landing ss2022'; then fail "outbound tag with space"; fi
is_ss2022_method 2022-blake3-aes-128-gcm || fail "AES-128 method"
is_ss2022_password 'Q2XjcK9PCzYTNZ2hTTPiEQ==' 2022-blake3-aes-128-gcm \
    || fail "valid AES-128 key"
is_ss2022_password 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' 2022-blake3-chacha20-poly1305 \
    || fail "valid ChaCha key"
if is_ss2022_password 'bad-key' 2022-blake3-aes-128-gcm; then
    fail "invalid key should be rejected"
fi
is_ss2022_method "$(auto_ss2022_method)" || fail "automatic SS2022 method"

write_ss2022_config 8388 'Q2XjcK9PCzYTNZ2hTTPiEQ==' 2022-blake3-aes-128-gcm \
    || fail "write SS2022 config"
python3 - "$XBOARD_SS2022_CONFIG" <<'PY' || fail "SS2022 config JSON"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
assert config["server_port"] == 8388
assert config["method"] == "2022-blake3-aes-128-gcm"
assert config["mode"] == "tcp_and_udp"
PY

relay_outbounds=$(relay_outbounds_json landing-ss2022 203.0.113.10 8388 \
    2022-blake3-aes-128-gcm 'Q2XjcK9PCzYTNZ2hTTPiEQ==')
grep -q '"tag": "landing-ss2022"' <<<"$relay_outbounds" || fail "relay outbound tag"
grep -q '"server_port": 8388' <<<"$relay_outbounds" || fail "relay outbound port"
relay_routes=$(relay_routes_json landing-ss2022)
grep -q '"outbound": "landing-ss2022"' <<<"$relay_routes" || fail "relay route"
pair_code=$(make_relay_pair_code 203.0.113.10 8388 \
    2022-blake3-aes-128-gcm 'Q2XjcK9PCzYTNZ2hTTPiEQ==' landing-ss2022)
[[ $pair_code == XNS1:* ]] || fail "relay pair prefix"
decode_relay_pair_code "$pair_code" || fail "decode relay pair"
[[ $RELAY_PAIR_LANDING_IP == "203.0.113.10" ]] || fail "relay pair IP"
[[ $RELAY_PAIR_PORT == "8388" ]] || fail "relay pair port"
[[ $RELAY_PAIR_TAG == "landing-ss2022" ]] || fail "relay pair tag"
if decode_relay_pair_code 'XNS1:not-valid'; then fail "invalid relay pair accepted"; fi

write_relay_profile "${XBOARD_RELAY_ROOT}/landing.env" landing \
    198.51.100.20 203.0.113.10 8388 2022-blake3-aes-128-gcm \
    'Q2XjcK9PCzYTNZ2hTTPiEQ==' landing-ss2022 \
    || fail "write relay profile"
[[ $(stat -c '%a' "${XBOARD_RELAY_ROOT}/landing.env") == "600" ]] \
    || fail "relay profile permissions"
relay_show_output=$(cmd_relay_show 2>/dev/null) || fail "relay show"
grep -q '"server": "203.0.113.10"' <<<"$relay_show_output" || fail "relay show server"
relay_help_output=$(cmd_relay help) || fail "relay help"
grep -q 'xns relay update' <<<"$relay_help_output" || fail "relay update help"
[[ -n $(ss2022_arch) ]] || fail "SS2022 architecture mapping"

tcpfit_url_file="${TEST_ROOT}/tcpfit-url"
fetch_file() {
    local url=$1 output=$2
    printf '%s\n' "$url" >"$tcpfit_url_file"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1"' >"$output"
}
tcpfit_output=$(cmd_tcp_tune probe) || fail "TCP tuning wrapper"
[[ $(tail -n 1 <<<"$tcpfit_output") == "probe" ]] || fail "TCP tuning arguments"
[[ $(cat "$tcpfit_url_file") == "https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh" ]] \
    || fail "TCP tuning URL"

firewall_help_output=$(cmd_firewall help) || fail "firewall help"
grep -q 'xns firewall whitelist' <<<"$firewall_help_output" || fail "firewall whitelist help"
grep -q 'xns firewall blacklist' <<<"$firewall_help_output" || fail "firewall blacklist help"
grep -q 'xns firewall list' <<<"$firewall_help_output" || fail "firewall list help"
grep -q -- '--backend' <<<"$firewall_help_output" || fail "firewall backend help"
numeric_firewall_help=$(main 19 help) || fail "numeric firewall shortcut"
grep -q 'xns firewall clear' <<<"$numeric_firewall_help" || fail "numeric firewall output"

mkdir -p "$XBOARD_FIREWALL_ROOT"
cat >"${XBOARD_FIREWALL_ROOT}/policy.conf" <<'EOF'
XNS_FIREWALL_BACKEND='ufw'
XNS_FIREWALL_MODE='whitelist'
XNS_FIREWALL_PORTS='80/tcp,22/tcp'
XNS_FIREWALL_SSH_PORTS='22/tcp'
XNS_FIREWALL_UPDATED_AT='2026-11-25T00:00:00Z'
EOF
policy_list=$(firewall_show_policy_list) || fail "firewall policy list"
grep -q '80/tcp' <<<"$policy_list" || fail "policy list application port"
grep -q '22/tcp.*SSH 保护' <<<"$policy_list" || fail "policy list SSH protection"
rm -f "${XBOARD_FIREWALL_ROOT}/policy.conf"

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
grep -q '14.*relay landing' <<<"$menu_output" || fail "relay landing menu item missing"
grep -q '15.*relay transit' <<<"$menu_output" || fail "relay transit menu item missing"
grep -q '16.*relay update' <<<"$menu_output" || fail "relay update menu item missing"
grep -q '17.*update-script' <<<"$menu_output" || fail "update-script menu item missing"
grep -q '18.*TCP 调优' <<<"$menu_output" || fail "TCP menu item missing"
grep -q '19.*firewall' <<<"$menu_output" || fail "firewall menu item missing"
grep -q '20.*退出' <<<"$menu_output" || fail "exit menu item missing"

help_output=$(bash "$SCRIPT" help)
grep -q 'update-script' <<<"$help_output" || fail "update-script help entry missing"
grep -q 'xns relay' <<<"$help_output" || fail "relay help entry missing"
grep -q 'xns tcp' <<<"$help_output" || fail "TCP help entry missing"
grep -q 'xns firewall' <<<"$help_output" || fail "firewall help entry missing"

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
