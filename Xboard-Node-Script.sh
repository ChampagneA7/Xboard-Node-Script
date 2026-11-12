#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="Xboard-Node-Script"
SCRIPT_VERSION="1.1.0"
SCRIPT_RAW_BASE="${XBOARD_SCRIPT_RAW_BASE:-https://raw.githubusercontent.com/ChampagneA7/Xboard-Node-Script/main}"
OFFICIAL_INSTALL_URL="${XBOARD_NODE_INSTALL_URL:-https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh}"
SS2022_INSTALL_URL="${XBOARD_SS2022_INSTALL_URL:-https://raw.githubusercontent.com/yahuisme/ss-2022/main/install.sh}"

XBOARD_ROOT="${XBOARD_ROOT:-/etc/xboard-node}"
XBOARD_CONFIG="${XBOARD_CONFIG:-${XBOARD_ROOT}/config.yml}"
XBOARD_SERVICE="${XBOARD_SERVICE:-xboard-node.service}"
XBOARD_BIN="${XBOARD_BIN:-/usr/local/bin/xboard-node}"
XBCTL_BIN="${XBCTL_BIN:-/usr/local/bin/xbctl}"
RELAY_ROOT="${XBOARD_RELAY_ROOT:-/etc/xboard-node/relay}"
RELAY_LANDING_PROFILE="${RELAY_ROOT}/landing.env"
RELAY_TRANSIT_PROFILE="${RELAY_ROOT}/transit.env"
RELAY_DEFAULT_PORT="8388"
RELAY_DEFAULT_METHOD="2022-blake3-aes-128-gcm"
RELAY_DEFAULT_TAG="landing-ss2022"
SS2022_SERVICE="${XBOARD_SS2022_SERVICE:-ss-rust}"
SS2022_BIN="${XBOARD_SS2022_BIN:-/usr/local/bin/ss-rust}"
SS2022_CONFIG="${XBOARD_SS2022_CONFIG:-/etc/ss-rust/config.json}"
SS2022_VERSION_FILE="${XBOARD_SS2022_VERSION_FILE:-/etc/ss-rust/ver.txt}"
SS2022_RELEASE_API="${XBOARD_SS2022_RELEASE_API:-https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest}"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;36m'
    PLAIN='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PLAIN=''
fi

log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$PLAIN" "$*"; }
log_ok() { printf '%b[OK]%b %s\n' "$GREEN" "$PLAIN" "$*"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$PLAIN" "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行（sudo xns）。"
}

require_linux_systemd() {
    [[ $(uname -s) == "Linux" ]] || die "当前脚本只支持 Linux。"
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，暂不支持。"
}

check_platform() {
    local arch
    arch=$(uname -m 2>/dev/null || true)
    case "$arch" in
        x86_64|amd64|aarch64|arm64) ;;
        *) log_warn "检测到架构 ${arch:-unknown}，请确认 Xboard-Node 官方安装器支持该架构。" ;;
    esac
    if [[ $(getconf LONG_BIT 2>/dev/null || printf '64') == "32" ]]; then
        die "Xboard-Node 不支持 32 位系统。"
    fi
}

read_line() {
    local prompt=$1
    local value=""
    if [[ -r /dev/tty ]]; then
        IFS= read -r -p "$prompt" value </dev/tty
    else
        IFS= read -r -p "$prompt" value
    fi
    printf '%s' "$value"
}

prompt_value() {
    local __result=$1
    local prompt=$2
    local default_value=${3:-}
    local suffix=": "
    local value

    [[ -n $default_value ]] && suffix=" [${default_value}]: "
    value=$(read_line "${prompt}${suffix}")
    [[ -z $value ]] && value=$default_value
    printf -v "$__result" '%s' "$value"
}

confirm() {
    local prompt=$1
    local default_value=${2:-n}
    local hint="[y/N]"
    local value

    [[ $default_value == "y" ]] && hint="[Y/n]"
    value=$(read_line "${prompt} ${hint}: ")
    [[ -z $value ]] && value=$default_value
    [[ $value =~ ^[Yy]([Ee][Ss])?$ ]]
}

normalize_panel_url() {
    local url=$1
    url="${url%/}"
    if [[ $url != http://* && $url != https://* ]]; then
        url="https://${url}"
    fi
    printf '%s' "$url"
}

is_positive_int() {
    [[ ${1:-} =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_int() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

is_port() {
    local port=${1:-}
    is_non_negative_int "$port" || return 1
    ((${#port} <= 5)) || return 1
    ((10#$port >= 0 && 10#$port <= 65535))
}

ensure_downloader() {
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        return 0
    fi

    log_warn "未检测到 curl/wget，尝试安装 curl..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates >/dev/null
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates >/dev/null
    else
        die "请先安装 curl 或 wget。"
    fi
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || die "curl/wget 安装失败。"
}

fetch_file() {
    local url=$1
    local output=$2

    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 3 --connect-timeout 15 --max-time 180 -o "$output" "$url"
        return
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
        return
    fi
    die "未找到 curl 或 wget。"
}

service_active() {
    systemctl is-active --quiet "$1"
}

service_enabled() {
    systemctl is-enabled --quiet "$1" >/dev/null 2>&1
}

xboard_installed() {
    [[ -f $XBOARD_CONFIG || -x $XBOARD_BIN ]]
}

run_official_installer() {
    local tmp
    local result

    ensure_downloader
    tmp=$(mktemp "${TMPDIR:-/tmp}/xboard-node-install.XXXXXX") || return 1

    log_info "下载 Xboard-Node 官方安装器..."
    if ! fetch_file "$OFFICIAL_INSTALL_URL" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        log_error "官方安装器语法校验失败，未执行安装。"
        return 1
    fi

    bash "$tmp" "$@"
    result=$?
    rm -f "$tmp"
    return "$result"
}

current_health_port() {
    local port=""
    if [[ -x $XBCTL_BIN ]]; then
        port=$("$XBCTL_BIN" config health-port --config "$XBOARD_CONFIG" 2>/dev/null || true)
        if [[ $port =~ ^[0-9]+$ ]]; then
            printf '%s' "$port"
            return 0
        fi
    fi
    port=$(awk '
        /health_port:[[:space:]]*[0-9]+/ {
            value=$0
            sub(/^.*health_port:[[:space:]]*/, "", value)
            sub(/[^0-9].*$/, "", value)
            print value
            exit
        }
    ' "$XBOARD_CONFIG" 2>/dev/null)
    printf '%s' "${port:-65530}"
}

wait_for_health() {
    local port
    local deadline=$((SECONDS + 45))

    service_active "$XBOARD_SERVICE" || return 1
    port=$(current_health_port)
    if [[ -z $port || $port -eq 0 ]] || ! command -v curl >/dev/null 2>&1; then
        sleep 3
        service_active "$XBOARD_SERVICE"
        return
    fi

    log_info "等待健康检查：http://127.0.0.1:${port}/healthz"
    while ((SECONDS < deadline)); do
        if curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
            sleep 3
            service_active "$XBOARD_SERVICE"
            return
        fi
        sleep 1
    done
    return 1
}

runtime_log_has_fatal_error() {
    grep -Eq 'machine instance exited with error|machine nodes status (401|403)|Machine not found or disabled'
}

extract_node_summaries() {
    LC_ALL=C sed -n 's/.*machine: starting node \([0-9][0-9]*\) (\([[:alnum:]_-]*\)\/.*/node_id=\1 protocol=\2/p' \
        | sort -u
}

extract_listener_summaries() {
    LC_ALL=C sed -n 's/.*\[\([a-z0-9][a-z0-9-]*:[0-9][0-9]*\)\] started.*/\1/p' \
        | sort -u
}

show_runtime_summary() {
    local remaining=5 recent_log nodes listeners

    while ((remaining > 0)); do
        recent_log=$(journalctl -u "$XBOARD_SERVICE" --since "5 minutes ago" --no-pager 2>/dev/null || true)
        nodes=$(printf '%s\n' "$recent_log" | extract_node_summaries | paste -sd ',' -)
        listeners=$(printf '%s\n' "$recent_log" | extract_listener_summaries | paste -sd ',' -)
        if [[ -n $nodes || -n $listeners ]]; then
            break
        fi
        remaining=$((remaining - 1))
        sleep 1
    done

    if [[ -n $nodes ]]; then
        log_info "当前 Machine 节点：${nodes}"
    fi
    if [[ -n $listeners ]]; then
        log_info "当前监听端口：${listeners}"
    fi
}

start_xboard() {
    local discovered started_at

    systemctl daemon-reload
    if ! systemctl enable "$XBOARD_SERVICE" >/dev/null 2>&1; then
        log_error "Xboard-Node 开机自启设置失败。"
        return 1
    fi
    if ! systemctl is-enabled --quiet "$XBOARD_SERVICE"; then
        log_error "Xboard-Node 开机自启状态验证失败。"
        return 1
    fi
    log_ok "Xboard-Node 已设置开机自启。"
    started_at=$(date +%s)
    if ! systemctl restart "$XBOARD_SERVICE"; then
        log_error "Xboard-Node 重启失败。"
        return 1
    fi
    if ! wait_for_health; then
        log_error "Xboard-Node 健康检查失败。"
        return 1
    fi
    if journalctl -u "$XBOARD_SERVICE" --since "@${started_at}" --no-pager 2>/dev/null | runtime_log_has_fatal_error; then
        log_error "Xboard-Node 已启动但运行时报错，最近日志："
        journalctl -u "$XBOARD_SERVICE" --since "@${started_at}" -n 30 --no-pager -l || true
        return 1
    fi
    log_ok "Xboard-Node 已启动，开机自启已启用。"
    discovered=$(journalctl -u "$XBOARD_SERVICE" --since "2 minutes ago" --no-pager 2>/dev/null \
        | sed -n 's/.*discovered \([0-9][0-9]*\) nodes.*/\1/p' \
        | tail -n 1)
    if [[ -n $discovered && $discovered -eq 0 ]]; then
        log_warn "当前没有发现节点，请确认面板已完成节点绑定。"
    elif [[ -n $discovered ]]; then
        log_ok "当前发现 ${discovered} 个节点。"
    fi
    show_runtime_summary
}

choose_mode() {
    local __result=$1
    local choice
    printf '%s\n' "请选择运行模式：" >&2
    printf '%s\n' "  1. Machine mode（推荐，可查看机器状态）" >&2
    printf '%s\n' "  2. Node mode" >&2
    prompt_value choice "请输入选择" "1"
    case "$choice" in
        1|machine|MACHINE) printf -v "$__result" '%s' "machine" ;;
        2|node|NODE) printf -v "$__result" '%s' "node" ;;
        *) die "无效选择：${choice}" ;;
    esac
}

cmd_install() {
    local panel="" token="" mode="" machine_id="" node_id="" node_type=""
    local kernel="singbox" health_port=65530 force=0

    require_root
    require_linux_systemd
    check_platform

    prompt_value panel "面板地址" ""
    [[ -n $panel ]] || die "面板地址不能为空。"
    panel=$(normalize_panel_url "$panel")
    choose_mode mode

    if [[ $mode == "machine" ]]; then
        prompt_value machine_id "Machine ID" ""
        is_positive_int "$machine_id" || die "Machine ID 必须是正整数。"
        prompt_value token "Machine Token" ""
    else
        prompt_value node_id "Node ID" ""
        is_positive_int "$node_id" || die "Node ID 必须是正整数。"
        prompt_value node_type "节点协议（可留空）" ""
        prompt_value token "服务器 Token" ""
    fi
    [[ -n $token ]] || die "Token 不能为空。"
    prompt_value kernel "内核 (singbox/xray)" "$kernel"
    case "$kernel" in
        singbox|xray) ;;
        *) die "内核仅支持 singbox 或 xray。" ;;
    esac
    prompt_value health_port "健康检查端口" "$health_port"
    is_port "$health_port" || die "健康检查端口必须在 0-65535 之间。"
    xboard_installed && force=1
    local args=(install --mode "$mode" --panel "$panel" --token "$token" --kernel "$kernel" --health-port "$health_port" --yes)
    [[ $force -eq 1 ]] && args+=(--force-reconfigure)
    if [[ $mode == "machine" ]]; then
        args+=(--machine-id "$machine_id")
    else
        args+=(--node-id "$node_id")
        [[ -n $node_type ]] && args+=(--node-type "$node_type")
    fi
    run_official_installer "${args[@]}" || die "安装失败。"
    start_xboard || die "安装完成，但开机自启或启动验证失败。"
    log_ok "Xboard-Node 安装完成，开机自启和启动验证已通过。"
}

cmd_start() {
    require_root
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    if ! systemctl start "$XBOARD_SERVICE"; then
        log_error "Xboard-Node 启动失败。"
        return 1
    fi
    if ! wait_for_health; then
        log_error "Xboard-Node 启动后健康检查失败。"
        return 1
    fi
    log_ok "Xboard-Node 已启动。"
    show_runtime_summary
}

cmd_stop() {
    require_root
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    if ! systemctl stop "$XBOARD_SERVICE"; then
        log_error "Xboard-Node 停止失败。"
        return 1
    fi
    if service_active "$XBOARD_SERVICE"; then
        log_error "Xboard-Node 停止命令完成，但服务仍在运行。"
        return 1
    fi
    log_ok "Xboard-Node 已停止。"
}

cmd_restart() {
    require_root
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    if ! systemctl restart "$XBOARD_SERVICE"; then
        log_error "Xboard-Node 重启命令失败。"
        return 1
    fi
    if wait_for_health; then
        log_ok "Xboard-Node 重启成功。"
        show_runtime_summary
    else
        log_error "Xboard-Node 重启后健康检查失败。"
        return 1
    fi
}

cmd_status() {
    require_linux_systemd
    xboard_installed || {
        log_warn "Xboard-Node 尚未安装。"
        return 1
    }
    systemctl status "$XBOARD_SERVICE" --no-pager -l || true
    if [[ -x $XBCTL_BIN ]]; then
        "$XBCTL_BIN" list || true
    fi
}

cmd_log() {
    require_linux_systemd
    journalctl -u "$XBOARD_SERVICE" -n 200 --no-pager -l -f
}

cmd_enable() {
    require_root
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    if ! systemctl enable "$XBOARD_SERVICE"; then
        log_error "设置开机自启失败。"
        return 1
    fi
    log_ok "已设置开机自启。"
}

cmd_disable() {
    require_root
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    if ! systemctl disable "$XBOARD_SERVICE"; then
        log_error "取消开机自启失败。"
        return 1
    fi
    log_ok "已取消开机自启。"
}

cmd_update() {
    require_root
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    run_official_installer upgrade || die "升级失败。"
    wait_for_health || die "升级完成，但健康检查失败，请查看：xns log"
    log_ok "Xboard-Node 升级完成。"
}

cmd_uninstall() {
    local args=(uninstall --yes)

    require_root
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    confirm "确认卸载 Xboard-Node（默认保留配置）" "n" || return 0
    if confirm "是否同时删除 /etc/xboard-node 配置" "n"; then
        args+=(--purge)
    fi
    run_official_installer "${args[@]}" || die "卸载失败。"
    log_ok "Xboard-Node 已卸载。"
}

cmd_version() {
    if [[ -x $XBOARD_BIN ]]; then
        "$XBOARD_BIN" -v || true
    fi
    if [[ -x $XBCTL_BIN ]]; then
        "$XBCTL_BIN" version || true
    fi
    if [[ ! -x $XBOARD_BIN && ! -x $XBCTL_BIN ]]; then
        log_warn "Xboard-Node 尚未安装。"
        return 1
    fi
}

cmd_health() {
    local port
    require_linux_systemd
    xboard_installed || die "Xboard-Node 尚未安装。"
    command -v curl >/dev/null 2>&1 || die "未找到 curl。"
    port=$(current_health_port)
    if [[ -z $port || $port -eq 0 ]]; then
        if systemctl is-active "$XBOARD_SERVICE"; then
            log_ok "服务正在运行，健康检查端口已禁用。"
            return 0
        fi
        log_error "服务未运行。"
        return 1
    fi
    if ! curl -fsS "http://127.0.0.1:${port}/healthz"; then
        log_error "健康检查失败。"
        return 1
    fi
    printf '\n'
    log_ok "健康检查通过。"
}

cmd_list() {
    [[ -x $XBCTL_BIN ]] || die "未找到 xbctl。"
    "$XBCTL_BIN" list "$@"
}

is_ipv4() {
    local ip=${1:-} octet
    local -a octets

    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

is_service_port() {
    local port=${1:-}
    is_port "$port" || return 1
    ((10#$port >= 1))
}

is_outbound_tag() {
    [[ ${1:-} =~ ^[A-Za-z0-9._-]+$ ]]
}

is_ss2022_method() {
    case "${1:-}" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            return 0
            ;;
        *) return 1 ;;
    esac
}

ss2022_key_bytes() {
    case "${1:-}" in
        2022-blake3-aes-128-gcm) printf '16' ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf '32' ;;
        *) return 1 ;;
    esac
}

is_ss2022_password() {
    local password=${1:-} method=${2:-} expected decoded

    expected=$(ss2022_key_bytes "$method") || return 1
    [[ $password =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    decoded=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [[ $decoded == "$expected" ]]
}

generate_ss2022_password() {
    local method=${1:-$RELAY_DEFAULT_METHOD} bytes

    bytes=$(ss2022_key_bytes "$method") || return 1
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 "$bytes" | tr -d '\r\n'
    else
        head -c "$bytes" /dev/urandom | base64 | tr -d '\r\n'
    fi
}

prompt_secret_value() {
    local __result=$1
    local prompt=$2
    local default_value=${3:-}
    local suffix=": "
    local value=""

    [[ -n $default_value ]] && suffix=" [留空保留]: "
    if [[ -r /dev/tty ]]; then
        IFS= read -r -s -p "${prompt}${suffix}" value </dev/tty
        printf '\n' >&2
    else
        IFS= read -r -s -p "${prompt}${suffix}" value
        printf '\n' >&2
    fi
    [[ -z $value ]] && value=$default_value
    printf -v "$__result" '%s' "$value"
}

detect_public_ipv4() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        ip=$(wget -4 -qO- --timeout=10 https://api.ipify.org 2>/dev/null || true)
    fi
    is_ipv4 "$ip" && printf '%s' "$ip"
}

load_relay_profile() {
    local path=$1
    [[ -f $path ]] || return 1
    # Profiles are root-managed files written by this script.
    # shellcheck disable=SC1090
    source "$path"
}

write_relay_profile() {
    local path=$1 role=$2 transit_ip=$3 landing_ip=$4 port=$5 method=$6 password=$7 tag=$8
    local tmp

    mkdir -p "$RELAY_ROOT" || return 1
    chmod 700 "$RELAY_ROOT" || return 1
    tmp=$(mktemp "${RELAY_ROOT}/.relay-profile.XXXXXX") || return 1
    {
        printf 'XNS_RELAY_ROLE=%q\n' "$role"
        printf 'XNS_RELAY_TRANSIT_IP=%q\n' "$transit_ip"
        printf 'XNS_RELAY_LANDING_IP=%q\n' "$landing_ip"
        printf 'XNS_RELAY_SS_PORT=%q\n' "$port"
        printf 'XNS_RELAY_SS_METHOD=%q\n' "$method"
        printf 'XNS_RELAY_SS_PASSWORD=%q\n' "$password"
        printf 'XNS_RELAY_OUTBOUND_TAG=%q\n' "$tag"
        printf 'XNS_RELAY_UPDATED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 600 "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$path" || {
        rm -f "$tmp"
        return 1
    }
}

relay_outbounds_json() {
    local tag=$1 landing_ip=$2 port=$3 method=$4 password=$5
    cat <<EOF
[
  {
    "tag": "${tag}",
    "protocol": "shadowsocks",
    "settings": {
      "server": "${landing_ip}",
      "server_port": ${port},
      "method": "${method}",
      "password": "${password}"
    }
  }
]
EOF
}

relay_routes_json() {
    local tag=$1
    cat <<EOF
[
  {
    "outbound": "${tag}"
  }
]
EOF
}

make_relay_pair_code() {
    local landing_ip=$1 port=$2 method=$3 password=$4 tag=$5 payload encoded

    payload=$(printf '%s|%s|%s|%s|%s' "$landing_ip" "$port" "$method" "$password" "$tag")
    encoded=$(printf '%s' "$payload" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')
    printf 'XNS1:%s' "$encoded"
}

decode_relay_pair_code() {
    local code=${1:-} encoded raw padding

    RELAY_PAIR_LANDING_IP=""
    RELAY_PAIR_PORT=""
    RELAY_PAIR_METHOD=""
    RELAY_PAIR_PASSWORD=""
    RELAY_PAIR_TAG=""
    [[ $code == XNS1:* ]] || return 1
    encoded=${code#XNS1:}
    [[ $encoded =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    encoded=${encoded//-/+}
    encoded=${encoded//_/\/}
    case $((${#encoded} % 4)) in
        0) padding="" ;;
        2) padding="==" ;;
        3) padding="=" ;;
        *) return 1 ;;
    esac
    raw=$(printf '%s%s' "$encoded" "$padding" | base64 -d 2>/dev/null) || return 1
    IFS='|' read -r RELAY_PAIR_LANDING_IP RELAY_PAIR_PORT RELAY_PAIR_METHOD RELAY_PAIR_PASSWORD RELAY_PAIR_TAG <<<"$raw"
    is_ipv4 "$RELAY_PAIR_LANDING_IP" \
        && is_service_port "$RELAY_PAIR_PORT" \
        && is_ss2022_method "$RELAY_PAIR_METHOD" \
        && is_ss2022_password "$RELAY_PAIR_PASSWORD" "$RELAY_PAIR_METHOD" \
        && is_outbound_tag "$RELAY_PAIR_TAG"
}

auto_ss2022_method() {
    if grep -qw aes /proc/cpuinfo 2>/dev/null; then
        printf '2022-blake3-aes-128-gcm'
    else
        printf '2022-blake3-chacha20-poly1305'
    fi
}

print_relay_panel_config() {
    local tag=$1 landing_ip=$2 port=$3 method=$4 password=$5

    log_info "以下 JSON 适用于 sing-box 内核。"
    log_warn "下面的 JSON 含 SS2022 密钥，请只粘贴到自己的 Xboard 面板。"
    printf '\n%s\n' '=== 自定义 Outbounds (JSON) ==='
    relay_outbounds_json "$tag" "$landing_ip" "$port" "$method" "$password"
    printf '\n%s\n' '=== 自定义 Routes (JSON) ==='
    relay_routes_json "$tag"
    printf '\n'
}

test_tcp_endpoint() {
    local ip=$1 port=$2
    is_ipv4 "$ip" && is_service_port "$port" || return 1
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/${ip}/${port}" 2>/dev/null
}

restart_xboard_for_relay() {
    local restart_at
    restart_at=$(date +%s)
    cmd_restart || return 1
    sleep 3
    if journalctl -u "$XBOARD_SERVICE" --since "@${restart_at}" --no-pager 2>/dev/null \
        | grep -q 'outbound not found'; then
        log_error "节点日志仍提示 Outbound 不存在，请检查面板里的 Outbound tag 和 Routes。"
        return 1
    fi
    log_ok "中转配置已生效。"
}

ss2022_binary_present() {
    [[ -x $SS2022_BIN ]]
}

ss2022_installed() {
    [[ -x $SS2022_BIN && -f $SS2022_CONFIG ]]
}

write_ss2022_config() {
    local port=$1 password=$2 method=$3 tmp config_dir

    config_dir=$(dirname "$SS2022_CONFIG")
    mkdir -p "$config_dir" || return 1
    tmp=$(mktemp "${SS2022_CONFIG}.tmp.XXXXXX") || return 1
    if ! cat >"$tmp" <<EOF
{
  "server": "::",
  "server_port": ${port},
  "password": "${password}",
  "method": "${method}",
  "fast_open": false,
  "mode": "tcp_and_udp",
  "timeout": 300,
  "no_delay": true
}
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$SS2022_CONFIG" || {
        rm -f "$tmp"
        return 1
    }
}

run_ss2022_installer() {
    local port=$1 password=$2 method=$3 tmp

    ensure_downloader
    tmp=$(mktemp "${TMPDIR:-/tmp}/ss2022-install.XXXXXX") || return 1
    log_info "下载 SS2022 上游安装器..."
    if ! fetch_file "$SS2022_INSTALL_URL" "$tmp"; then
        rm -f "$tmp"
        log_error "下载 SS2022 安装器失败。"
        return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        log_error "SS2022 安装器语法校验失败，未执行。"
        return 1
    fi
    # Run the upstream GPLv3 installer as an external tool instead of
    # embedding its source in this script.
    if ! bash "$tmp" --port "$port" --password "$password" --method "$method"; then
        rm -f "$tmp"
        log_error "SS2022 无交互安装失败。"
        return 1
    fi
    rm -f "$tmp"
}

ensure_ss2022_landing() {
    local port=$1 password=$2 method=$3

    if ss2022_binary_present && ! ss2022_installed; then
        log_error "检测到 ${SS2022_BIN}，但缺少 ${SS2022_CONFIG}。请先清理残留安装后重试。"
        return 1
    fi
    if ! ss2022_binary_present; then
        run_ss2022_installer "$port" "$password" "$method" || return 1
    fi
    ss2022_installed || {
        log_error "SS2022 安装后未找到程序或配置文件。"
        return 1
    }
    write_ss2022_config "$port" "$password" "$method" || {
        log_error "写入 SS2022 配置失败。"
        return 1
    }
    if ! systemctl cat "$SS2022_SERVICE" >/dev/null 2>&1; then
        log_error "未找到 ${SS2022_SERVICE} 服务。"
        return 1
    fi
    systemctl enable "$SS2022_SERVICE" >/dev/null 2>&1 || return 1
    systemctl restart "$SS2022_SERVICE" || return 1
    sleep 2
    systemctl is-active --quiet "$SS2022_SERVICE"
}

ss2022_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64-unknown-linux-musl' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-musl' ;;
        armv7l) printf 'armv7-unknown-linux-musleabihf' ;;
        *) return 1 ;;
    esac
}

current_ss2022_version() {
    local output=""
    if [[ -x $SS2022_BIN ]]; then
        output=$("$SS2022_BIN" --version 2>/dev/null | awk '{print $2}')
    fi
    if [[ -z $output && -f $SS2022_VERSION_FILE ]]; then
        output=$(tr -d '[:space:]' <"$SS2022_VERSION_FILE")
    fi
    printf '%s' "$output"
}

latest_ss2022_version() {
    local json="" version=""

    if command -v curl >/dev/null 2>&1; then
        json=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$SS2022_RELEASE_API" 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        json=$(wget -qO- --timeout=60 "$SS2022_RELEASE_API" 2>/dev/null || true)
    fi
    version=$(printf '%s' "$json" | tr -d '\n' \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p')
    [[ $version =~ ^[0-9][0-9A-Za-z._-]*$ ]] || return 1
    printf '%s' "$version"
}

prepare_ss2022_update() {
    local version=$1 arch=$2 tmpdir archive checksum_file checksum binary

    SS2022_PREPARED_BINARY=""
    SS2022_UPDATE_TMPDIR=""
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/xns-ss2022-update.XXXXXX") || return 1
    archive="${tmpdir}/shadowsocks.tar.xz"
    checksum_file="${archive}.sha256"
    if ! fetch_file "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/shadowsocks-v${version}.${arch}.tar.xz" "$archive"; then
        rm -rf "$tmpdir"
        return 1
    fi
    if ! fetch_file "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/shadowsocks-v${version}.${arch}.tar.xz.sha256" "$checksum_file"; then
        rm -rf "$tmpdir"
        return 1
    fi
    read -r checksum _ <"$checksum_file" || {
        rm -rf "$tmpdir"
        return 1
    }
    [[ $checksum =~ ^[0-9A-Fa-f]{64}$ ]] || {
        rm -rf "$tmpdir"
        return 1
    }
    if ! printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c - >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        return 1
    fi
    if ! tar -xJf "$archive" -C "$tmpdir" ssserver; then
        rm -rf "$tmpdir"
        return 1
    fi
    binary="${tmpdir}/ssserver"
    [[ -f $binary && ! -L $binary ]] || {
        rm -rf "$tmpdir"
        return 1
    }
    chmod 0755 "$binary" || {
        rm -rf "$tmpdir"
        return 1
    }
    [[ $("$binary" --version 2>/dev/null) == "shadowsocks ${version}" ]] || {
        rm -rf "$tmpdir"
        return 1
    }
    SS2022_PREPARED_BINARY=$binary
    SS2022_UPDATE_TMPDIR=$tmpdir
}

restore_ss2022_binary() {
    local backup=$1
    if [[ -n $backup && -f $backup ]]; then
        install -m 0755 "$backup" "$SS2022_BIN" || return 1
        systemctl restart "$SS2022_SERVICE" >/dev/null 2>&1 || true
    fi
}

update_ss2022_binary() {
    local force=${1:-0} latest current arch backup staged version_tmp

    ss2022_installed || die "SS2022 尚未安装。"
    ensure_downloader
    arch=$(ss2022_arch) || die "当前 CPU 架构不支持自动更新。"
    latest=$(latest_ss2022_version) || die "获取 shadowsocks-rust 最新版本失败。"
    current=$(current_ss2022_version)
    if [[ $current == "$latest" ]] && ((force == 0)); then
        log_ok "SS2022 已是最新版本：${current}"
        return 0
    fi

    log_info "准备更新 SS2022：${current:-unknown} -> ${latest}"
    prepare_ss2022_update "$latest" "$arch" || die "下载或校验 SS2022 新版本失败。"
    backup=$(mktemp "${SS2022_BIN}.backup.XXXXXX") || die "创建 SS2022 备份失败。"
    cp -p "$SS2022_BIN" "$backup" || die "备份 SS2022 二进制失败。"
    staged=$(mktemp "${SS2022_BIN}.new.XXXXXX") || {
        rm -f "$backup"
        die "创建 SS2022 更新文件失败。"
    }
    if ! install -m 0755 "$SS2022_PREPARED_BINARY" "$staged" \
        || ! mv -f "$staged" "$SS2022_BIN"; then
        rm -f "$staged"
        rm -rf "${SS2022_UPDATE_TMPDIR:-}"
        restore_ss2022_binary "$backup"
        rm -f "$backup"
        die "替换 SS2022 二进制失败，已尝试回滚。"
    fi
    mkdir -p "$(dirname "$SS2022_VERSION_FILE")"
    version_tmp=$(mktemp "${SS2022_VERSION_FILE}.new.XXXXXX") || version_tmp=""
    if [[ -n $version_tmp ]]; then
        printf '%s\n' "$latest" >"$version_tmp"
        chmod 0644 "$version_tmp"
        mv -f "$version_tmp" "$SS2022_VERSION_FILE" || true
    fi
    rm -rf "${SS2022_UPDATE_TMPDIR:-}"

    if ! systemctl restart "$SS2022_SERVICE" || ! sleep 2 \
        || ! systemctl is-active --quiet "$SS2022_SERVICE" \
        || [[ $(current_ss2022_version) != "$latest" ]]; then
        restore_ss2022_binary "$backup"
        rm -f "$backup"
        die "SS2022 新版本启动验证失败，已恢复旧版本。"
    fi
    rm -f "$backup"
    log_ok "SS2022 已更新到 ${latest}，原有端口、密钥和防火墙保持不变。"
}

remove_old_ufw_relay_rules() {
    local old_ip=${1:-} old_port=${2:-}
    [[ -n $old_ip && -n $old_port ]] || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    ufw delete allow proto tcp from "$old_ip" to any port "$old_port" >/dev/null 2>&1 || true
    ufw delete allow proto udp from "$old_ip" to any port "$old_port" >/dev/null 2>&1 || true
}

configure_ufw_relay() {
    local transit_ip=$1 port=$2 old_ip=${3:-} old_port=${4:-}
    local ssh_server_port

    command -v ufw >/dev/null 2>&1 || return 1
    remove_old_ufw_relay_rules "$old_ip" "$old_port"
    ufw default deny incoming >/dev/null || return 1
    ufw default allow outgoing >/dev/null || return 1
    ufw allow 22/tcp >/dev/null || return 1
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r _ _ _ ssh_server_port <<<"$SSH_CONNECTION"
        if is_service_port "$ssh_server_port"; then
            ufw allow "${ssh_server_port}/tcp" >/dev/null || return 1
        fi
    fi
    ufw allow proto tcp from "$transit_ip" to any port "$port" >/dev/null || return 1
    ufw allow proto udp from "$transit_ip" to any port "$port" >/dev/null || return 1
    ufw --force enable >/dev/null || return 1
    ufw status | grep -q 'Status: active'
}

remove_old_firewalld_relay_rules() {
    local old_ip=${1:-} old_port=${2:-}
    local rule

    [[ -n $old_ip && -n $old_port ]] || return 0
    for rule in tcp udp; do
        firewall-cmd --permanent --remove-rich-rule="rule family=ipv4 source address=${old_ip} port port=${old_port} protocol=${rule} accept" >/dev/null 2>&1 || true
    done
}

configure_firewalld_relay() {
    local transit_ip=$1 port=$2 old_ip=${3:-} old_port=${4:-}

    command -v firewall-cmd >/dev/null 2>&1 || return 1
    firewall-cmd --state >/dev/null 2>&1 || return 1
    remove_old_firewalld_relay_rules "$old_ip" "$old_port"
    firewall-cmd --permanent --add-service=ssh >/dev/null || return 1
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${transit_ip} port port=${port} protocol=tcp accept" >/dev/null || return 1
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${transit_ip} port port=${port} protocol=udp accept" >/dev/null || return 1
    firewall-cmd --reload >/dev/null || return 1
}

configure_relay_firewall() {
    local transit_ip=$1 port=$2 old_ip=${3:-} old_port=${4:-}

    if configure_ufw_relay "$transit_ip" "$port" "$old_ip" "$old_port"; then
        log_ok "UFW 已限制 SS2022 ${port}/TCP+UDP 仅允许 ${transit_ip} 访问。"
        return 0
    fi
    if configure_firewalld_relay "$transit_ip" "$port" "$old_ip" "$old_port"; then
        log_ok "firewalld 已限制 SS2022 ${port}/TCP+UDP 仅允许 ${transit_ip} 访问。"
        return 0
    fi
    log_warn "未检测到可用的 UFW 或 firewalld。请手动限制 SS2022 端口来源 IP。"
    return 1
}

cmd_relay_landing() {
    local transit_ip="" landing_ip="" port="" method="" password="" tag="$RELAY_DEFAULT_TAG"
    local update_binary=0 old_transit_ip="" old_port="" pair_code

    require_root
    require_linux_systemd
    check_platform
    if load_relay_profile "$RELAY_LANDING_PROFILE"; then
        transit_ip=${XNS_RELAY_TRANSIT_IP:-}
        landing_ip=${XNS_RELAY_LANDING_IP:-}
        port=${XNS_RELAY_SS_PORT:-}
        method=${XNS_RELAY_SS_METHOD:-}
        password=${XNS_RELAY_SS_PASSWORD:-}
        tag=${XNS_RELAY_OUTBOUND_TAG:-$RELAY_DEFAULT_TAG}
    fi
    old_transit_ip=$transit_ip
    old_port=$port

    while (($# > 0)); do
        case "$1" in
            --transit-ip|--allow-from)
                transit_ip=${2:-}
                shift 2
                ;;
            --landing-ip|--server-ip)
                landing_ip=${2:-}
                shift 2
                ;;
            --port)
                port=${2:-}
                shift 2
                ;;
            --method)
                method=${2:-}
                shift 2
                ;;
            --password)
                password=${2:-}
                shift 2
                ;;
            --tag)
                tag=${2:-}
                shift 2
                ;;
            --update)
                update_binary=1
                shift
                ;;
            --help|-h)
                printf '%s\n' "用法: xns relay landing [--transit-ip IP] [--port 8388] [--method METHOD] [--password KEY] [--update]"
                return 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done

    if [[ -z $transit_ip ]]; then
        prompt_value transit_ip "中转机公网 IPv4（只允许它访问落地端口）" "$transit_ip"
    fi
    is_ipv4 "$transit_ip" || die "中转机 IP 无效：${transit_ip}"
    port=${port:-$RELAY_DEFAULT_PORT}
    is_service_port "$port" || die "端口必须在 1-65535 之间。"
    if [[ -z $method ]]; then
        method=$(auto_ss2022_method)
    fi
    is_ss2022_method "$method" || die "不支持的 SS2022 加密方式：${method}"

    if [[ -z $password ]]; then
        password=$(generate_ss2022_password "$method") || die "生成 SS2022 密钥失败。"
    fi
    is_ss2022_password "$password" "$method" || die "SS2022 密钥格式或长度不符合 ${method}。"

    if [[ -z $landing_ip ]]; then
        landing_ip=$(detect_public_ipv4)
    fi
    if [[ -z $landing_ip ]]; then
        prompt_value landing_ip "落地机公网 IPv4" ""
    fi
    is_ipv4 "$landing_ip" || die "落地机 IP 无效：${landing_ip}"
    is_outbound_tag "$tag" || die "Outbound tag 只能包含字母、数字、点、下划线和短横线。"

    log_info "落地配置：${landing_ip}:${port}，来源仅允许 ${transit_ip}"

    ensure_ss2022_landing "$port" "$password" "$method" || die "SS2022 落地服务安装失败。"
    if ((update_binary == 1)); then
        update_ss2022_binary 0 || die "SS2022 更新失败。"
    fi
    configure_relay_firewall "$transit_ip" "$port" "$old_transit_ip" "$old_port" \
        || log_warn "本机防火墙未自动配置，请检查云安全组和系统防火墙。"
    write_relay_profile "$RELAY_LANDING_PROFILE" landing "$transit_ip" "$landing_ip" "$port" "$method" "$password" "$tag" \
        || die "保存落地配置失败。"

    log_ok "SS2022 已启动并设置为开机自启。"
    log_info "云厂商安全组仍需放行：来源 ${transit_ip} -> TCP/UDP ${port}。"
    pair_code=$(make_relay_pair_code "$landing_ip" "$port" "$method" "$password" "$tag")
    log_warn "配对码包含 SS2022 密钥，请只粘贴到自己的中转机，不要公开分享。"
    printf '\n%s\n' '落地配对码（只复制下面一行）：'
    printf '%s\n\n' "$pair_code"
    printf '%s\n' '在中转机运行 xns，选择 15，并粘贴上面的配对码。'
}

cmd_relay_update() {
    local force=0 assume_yes=0

    require_root
    require_linux_systemd
    while (($# > 0)); do
        case "$1" in
            --force)
                force=1
                shift
                ;;
            --yes|-y)
                assume_yes=1
                shift
                ;;
            --help|-h)
                printf '%s\n' "用法: xns relay update [--force] [--yes]"
                return 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done
    ss2022_installed || die "SS2022 尚未安装，请先运行 xns relay landing。"
    if ((assume_yes == 0)); then
        confirm "更新 shadowsocks-rust 并重启 SS2022 服务" "y" || return 0
    fi
    update_ss2022_binary "$force"
}

cmd_relay_transit() {
    local transit_ip="" landing_ip="" port="" method="" password="" tag="$RELAY_DEFAULT_TAG"
    local force=0 restart_mode="ask" pair_code="" manual_values=0

    require_root
    require_linux_systemd
    if load_relay_profile "$RELAY_TRANSIT_PROFILE"; then
        transit_ip=${XNS_RELAY_TRANSIT_IP:-}
        landing_ip=${XNS_RELAY_LANDING_IP:-}
        port=${XNS_RELAY_SS_PORT:-}
        method=${XNS_RELAY_SS_METHOD:-}
        password=${XNS_RELAY_SS_PASSWORD:-}
        tag=${XNS_RELAY_OUTBOUND_TAG:-$RELAY_DEFAULT_TAG}
    fi

    while (($# > 0)); do
        case "$1" in
            --pair)
                pair_code=${2:-}
                shift 2
                ;;
            --landing-ip|--server-ip)
                landing_ip=${2:-}
                manual_values=1
                shift 2
                ;;
            --port)
                port=${2:-}
                manual_values=1
                shift 2
                ;;
            --method)
                method=${2:-}
                manual_values=1
                shift 2
                ;;
            --password)
                password=${2:-}
                manual_values=1
                shift 2
                ;;
            --tag)
                tag=${2:-}
                manual_values=1
                shift 2
                ;;
            --force)
                force=1
                shift
                ;;
            --restart)
                restart_mode="yes"
                shift
                ;;
            --no-restart)
                restart_mode="no"
                shift
                ;;
            --help|-h)
                printf '%s\n' "用法: xns relay transit [--pair CODE] [--landing-ip IP] [--port 8388] [--method METHOD] [--password KEY] [--tag TAG] [--restart|--no-restart]"
                return 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done

    if [[ -z $pair_code && $manual_values -eq 0 && -r /dev/tty ]]; then
        prompt_value pair_code "落地配对码（直接粘贴；留空沿用上次配置）" ""
    fi
    if [[ -n $pair_code ]]; then
        decode_relay_pair_code "$pair_code" || die "落地配对码无效。"
        landing_ip=$RELAY_PAIR_LANDING_IP
        port=$RELAY_PAIR_PORT
        method=$RELAY_PAIR_METHOD
        password=$RELAY_PAIR_PASSWORD
        tag=$RELAY_PAIR_TAG
    fi
    if [[ -z $landing_ip ]]; then
        prompt_value landing_ip "落地机公网 IPv4" ""
    fi
    is_ipv4 "$landing_ip" || die "落地机 IP 无效：${landing_ip}"
    if [[ -z $port ]]; then
        prompt_value port "SS2022 端口" "$RELAY_DEFAULT_PORT"
    fi
    is_service_port "$port" || die "端口必须在 1-65535 之间。"
    if [[ -z $method ]]; then
        method=$(auto_ss2022_method)
    fi
    is_ss2022_method "$method" || die "不支持的 SS2022 加密方式：${method}"
    if [[ -z $password ]]; then
        prompt_secret_value password "SS2022 密钥" "$password"
    fi
    is_ss2022_password "$password" "$method" || die "SS2022 密钥格式或长度不符合 ${method}。"
    if [[ -z $tag ]]; then
        prompt_value tag "Outbound tag" "$RELAY_DEFAULT_TAG"
    fi
    is_outbound_tag "$tag" || die "Outbound tag 只能包含字母、数字、点、下划线和短横线。"

    if test_tcp_endpoint "$landing_ip" "$port"; then
        log_ok "落地端口 ${landing_ip}:${port} 可达。"
    else
        log_warn "无法连接落地端口 ${landing_ip}:${port}，请检查云安全组和落地防火墙。"
        if ((force == 0)); then
            confirm "仍然生成面板配置" "n" || return 0
        fi
    fi

    transit_ip=$(detect_public_ipv4)
    write_relay_profile "$RELAY_TRANSIT_PROFILE" transit "$transit_ip" "$landing_ip" "$port" "$method" "$password" "$tag" \
        || die "保存中转配置失败。"
    print_relay_panel_config "$tag" "$landing_ip" "$port" "$method" "$password"

    if xboard_installed; then
        log_warn "sing-box 热更新通常不会重新加载新增 Outbound，需要在面板保存后重启 Xboard-Node。"
        if [[ $restart_mode == "yes" ]]; then
            restart_xboard_for_relay
        elif [[ $restart_mode == "ask" ]] && confirm "已在面板保存并提交，现在重启 Xboard-Node" "y"; then
            restart_xboard_for_relay
        else
            log_info "完成面板保存后运行 xns restart 使配置生效。"
        fi
    fi
}

cmd_relay_show() {
    local role=""

    if load_relay_profile "$RELAY_LANDING_PROFILE"; then
        role=${XNS_RELAY_ROLE:-landing}
    elif load_relay_profile "$RELAY_TRANSIT_PROFILE"; then
        role=${XNS_RELAY_ROLE:-transit}
    else
        log_warn "尚未找到中转配置，请先运行 xns relay landing 或 xns relay transit。"
        return 1
    fi
    is_ipv4 "${XNS_RELAY_LANDING_IP:-}" || die "已保存的落地 IP 无效。"
    is_service_port "${XNS_RELAY_SS_PORT:-}" || die "已保存的端口无效。"
    is_ss2022_method "${XNS_RELAY_SS_METHOD:-}" || die "已保存的加密方式无效。"
    is_ss2022_password "${XNS_RELAY_SS_PASSWORD:-}" "${XNS_RELAY_SS_METHOD:-}" \
        || die "已保存的 SS2022 密钥无效。"
    is_outbound_tag "${XNS_RELAY_OUTBOUND_TAG:-}" || die "已保存的 Outbound tag 无效。"

    log_info "配置角色：${role}，更新时间：${XNS_RELAY_UPDATED_AT:-unknown}"
    print_relay_panel_config "${XNS_RELAY_OUTBOUND_TAG}" "${XNS_RELAY_LANDING_IP}" \
        "${XNS_RELAY_SS_PORT}" "${XNS_RELAY_SS_METHOD}" "${XNS_RELAY_SS_PASSWORD}"
}

cmd_relay() {
    local action=${1:-help}
    [[ $# -gt 0 ]] && shift
    case "$action" in
        landing) cmd_relay_landing "$@" ;;
        update) cmd_relay_update "$@" ;;
        transit) cmd_relay_transit "$@" ;;
        show|json) cmd_relay_show "$@" ;;
        help|--help|-h)
            cat <<EOF
用法:
  xns relay landing [选项]   在落地机安装 SS2022 并输出配对码
  xns relay transit [选项]   在中转机粘贴配对码、检测落地并输出面板 JSON
  xns relay update           更新 shadowsocks-rust，保留现有配置
  xns relay show             查看已保存的 JSON

落地机常用参数:
  --transit-ip IP            允许访问 SS2022 的中转机公网 IP
  --port 8388                SS2022 端口
  --method METHOD            AES-128-GCM 或 ChaCha20-Poly1305
  --password KEY             指定现有 SS2022 密钥
  --update                   同时更新 shadowsocks-rust

中转机常用参数:
  --pair CODE                直接传入落地配对码
  --landing-ip IP            落地机公网 IP
  --port 8388                SS2022 端口
  --password KEY             SS2022 密钥
  --tag landing-ss2022       Outbound tag
  --restart                  输出后立即重启 Xboard-Node
  --no-restart               不重启 Xboard-Node
EOF
            ;;
        *)
            show_usage
            return 2
            ;;
    esac
}

cmd_update_script() {
    local current pending source_url
    require_root
    ensure_downloader
    current=$(readlink -f "${BASH_SOURCE[0]}")
    pending=$(mktemp "${current}.update.XXXXXX") || return 1
    source_url="${SCRIPT_RAW_BASE}/Xboard-Node-Script.sh?ts=$(date +%s)"

    if ! fetch_file "$source_url" "$pending"; then
        rm -f "$pending"
        die "下载管理脚本失败。"
    fi
    if ! bash -n "$pending"; then
        rm -f "$pending"
        die "新脚本语法校验失败，当前脚本未改动。"
    fi
    if ! chmod 0755 "$pending" || ! mv -f "$pending" "$current"; then
        rm -f "$pending"
        die "替换管理脚本失败。"
    fi
    SCRIPT_RELOAD_PATH=$current
    log_ok "管理脚本已更新。"
}

show_status_line() {
    if ! xboard_installed; then
        printf '状态: %b未安装%b\n' "$RED" "$PLAIN"
        return
    fi
    if service_active "$XBOARD_SERVICE"; then
        printf '状态: %b运行中%b\n' "$GREEN" "$PLAIN"
    else
        printf '状态: %b已停止%b\n' "$YELLOW" "$PLAIN"
    fi
    if service_enabled "$XBOARD_SERVICE"; then
        printf '开机自启: %b是%b\n' "$GREEN" "$PLAIN"
    else
        printf '开机自启: %b否%b\n' "$RED" "$PLAIN"
    fi
}

show_menu() {
    printf '\n'
    printf '  %b%s%b  %bv%s%b\n' "$GREEN" "$SCRIPT_NAME" "$PLAIN" "$YELLOW" "$SCRIPT_VERSION" "$PLAIN"
    printf '%s\n' '------------------------------------------------------------'
    printf '  %b1.%b 启动 Xboard-Node        xns start\n' "$GREEN" "$PLAIN"
    printf '  %b2.%b 停止 Xboard-Node        xns stop\n' "$GREEN" "$PLAIN"
    printf '  %b3.%b 重启 Xboard-Node        xns restart\n' "$GREEN" "$PLAIN"
    printf '  %b4.%b 查看状态                xns status\n' "$GREEN" "$PLAIN"
    printf '  %b5.%b 查看日志                xns log\n' "$GREEN" "$PLAIN"
    printf '%s\n' '------------------------------------------------------------'
    printf '  %b6.%b 安装/重新配置           xns install\n' "$GREEN" "$PLAIN"
    printf '  %b7.%b 升级 Xboard-Node        xns update\n' "$GREEN" "$PLAIN"
    printf '  %b8.%b 卸载 Xboard-Node        xns uninstall\n' "$GREEN" "$PLAIN"
    printf '%s\n' '------------------------------------------------------------'
    printf '  %b9.%b 设置开机自启            xns enable\n' "$GREEN" "$PLAIN"
    printf '  %b10.%b 取消开机自启           xns disable\n' "$GREEN" "$PLAIN"
    printf '  %b11.%b 查看版本               xns version\n' "$GREEN" "$PLAIN"
    printf '  %b12.%b 健康检查               xns health\n' "$GREEN" "$PLAIN"
    printf '  %b13.%b 实例列表               xns list\n' "$GREEN" "$PLAIN"
    printf '%s\n' '------------------------------------------------------------'
    printf '  %b14.%b 搭建 SS2022 落地       xns relay landing\n' "$GREEN" "$PLAIN"
    printf '  %b15.%b 验证中转并生成配置     xns relay transit\n' "$GREEN" "$PLAIN"
    printf '  %b16.%b 更新 SS2022            xns relay update\n' "$GREEN" "$PLAIN"
    printf '  %b17.%b 更新管理脚本           xns update-script\n' "$GREEN" "$PLAIN"
    printf '  %b18.%b 退出\n' "$GREEN" "$PLAIN"
    printf '%s\n' '------------------------------------------------------------'
    show_status_line
    printf '\n'
}

menu_loop() {
    local choice
    require_root
    require_linux_systemd

    while true; do
        show_menu
        choice=$(read_line "请输入选择 [1-18]: ")
        case "$choice" in
            1) cmd_start ;;
            2) cmd_stop ;;
            3) cmd_restart ;;
            4) cmd_status ;;
            5) cmd_log ;;
            6) cmd_install ;;
            7) cmd_update ;;
            8) cmd_uninstall ;;
            9) cmd_enable ;;
            10) cmd_disable ;;
            11) cmd_version ;;
            12) cmd_health ;;
            13) cmd_list ;;
            14) cmd_relay_landing ;;
            15) cmd_relay_transit ;;
            16) cmd_relay_update ;;
            17) cmd_update_script ;;
            18|q|Q|exit|quit) exit 0 ;;
            *) log_warn "请输入正确的数字 [1-18]。" ;;
        esac
        if [[ -n ${SCRIPT_RELOAD_PATH:-} ]]; then
            log_info "正在重新载入新版本..."
            exec bash "$SCRIPT_RELOAD_PATH"
        fi
        read_line "按回车返回主菜单..." >/dev/null
    done
}

show_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

用法:
  xns                         打开管理菜单
  xns install                 安装或重新配置
  xns update                  升级 Xboard-Node
  xns uninstall               卸载 Xboard-Node
  xns start|stop|restart|status|log
  xns enable|disable
  xns version                 查看版本
  xns health                  健康检查
  xns list                    查看 xbctl 实例
  xns relay landing           搭建 SS2022 落地
  xns relay transit           检测落地并生成面板配置
  xns relay update            更新 shadowsocks-rust
  xns relay show              查看已保存的配置
  xns update-script           更新管理脚本
EOF
}

main() {
    local action=${1:-menu}
    [[ $# -gt 0 ]] && shift

    case "$action" in
        menu) menu_loop ;;
        install) cmd_install ;;
        update) cmd_update ;;
        uninstall) cmd_uninstall ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        restart) cmd_restart ;;
        status) cmd_status ;;
        log|logs) cmd_log ;;
        enable) cmd_enable ;;
        disable) cmd_disable ;;
        version|-v|--version) cmd_version ;;
        health) cmd_health ;;
        list) cmd_list "$@" ;;
        relay) cmd_relay "$@" ;;
        update-script) cmd_update_script ;;
        help|--help|-h) show_usage ;;
        *) show_usage; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
