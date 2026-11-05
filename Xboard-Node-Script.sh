#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="Xboard-Node-Script"
SCRIPT_VERSION="1.0.12"
SCRIPT_RAW_BASE="${XBOARD_SCRIPT_RAW_BASE:-https://raw.githubusercontent.com/ChampagneA7/Xboard-Node-Script/main}"
OFFICIAL_INSTALL_URL="${XBOARD_NODE_INSTALL_URL:-https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh}"

XBOARD_ROOT="${XBOARD_ROOT:-/etc/xboard-node}"
XBOARD_CONFIG="${XBOARD_CONFIG:-${XBOARD_ROOT}/config.yml}"
XBOARD_SERVICE="${XBOARD_SERVICE:-xboard-node.service}"
XBOARD_BIN="${XBOARD_BIN:-/usr/local/bin/xboard-node}"
XBCTL_BIN="${XBCTL_BIN:-/usr/local/bin/xbctl}"

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
    printf '  %b14.%b 更新管理脚本           xns update-script\n' "$GREEN" "$PLAIN"
    printf '  %b15.%b 退出\n' "$GREEN" "$PLAIN"
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
        choice=$(read_line "请输入选择 [1-15]: ")
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
            14) cmd_update_script ;;
            15|q|Q|exit|quit) exit 0 ;;
            *) log_warn "请输入正确的数字 [1-15]。" ;;
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
        update-script) cmd_update_script ;;
        help|--help|-h) show_usage ;;
        *) show_usage; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
