#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="Xboard-Node-Script"
SCRIPT_VERSION="1.0.8"
SCRIPT_RAW_BASE="${XBOARD_SCRIPT_RAW_BASE:-https://raw.githubusercontent.com/ChampagneA7/Xboard-Node-Script/main}"
OFFICIAL_INSTALL_URL="${XBOARD_NODE_INSTALL_URL:-https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh}"

XBOARD_ROOT="${XBOARD_ROOT:-/etc/xboard-node}"
XBOARD_CONFIG="${XBOARD_CONFIG:-${XBOARD_ROOT}/config.yml}"
XBOARD_CUSTOM_CONFIG="${XBOARD_CUSTOM_CONFIG:-${XBOARD_ROOT}/sing_origin.json}"
XBOARD_STATE_FILE="${XBOARD_STATE_FILE:-${XBOARD_ROOT}/migration-state.env}"
XBOARD_SERVICE="${XBOARD_SERVICE:-xboard-node.service}"
XBOARD_BIN="${XBOARD_BIN:-/usr/local/bin/xboard-node}"
XBCTL_BIN="${XBCTL_BIN:-/usr/local/bin/xbctl}"

V2BX_CONFIG="${V2BX_CONFIG:-/etc/V2bX/config.json}"
V2BX_ORIGIN="${V2BX_ORIGIN:-/etc/V2bX/sing_origin.json}"
V2BX_SERVICE="${V2BX_SERVICE:-V2bX.service}"
V2BX_BIN="${V2BX_BIN:-/usr/local/V2bX/V2bX}"

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

take_arg_value() {
    local option=$1
    local count=$2
    local value=${3:-}
    [[ $count -ge 2 && -n $value && $value != --* ]] \
        || die "参数 ${option} 缺少值。"
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

v2bx_installed() {
    [[ -f $V2BX_CONFIG || -x $V2BX_BIN || -f "/etc/systemd/system/${V2BX_SERVICE}" ]]
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

backup_file() {
    local source_path=$1
    local label=$2
    local backup_dir="${XBOARD_ROOT}/backups/migrations"
    local stamp
    local destination

    [[ -f $source_path ]] || return 0
    stamp=$(date +%Y%m%d-%H%M%S)-${BASHPID:-$$}
    destination="${backup_dir}/${label}-${stamp}"
    if ! mkdir -p "$backup_dir"; then
        log_error "创建备份目录失败：${backup_dir}"
        return 1
    fi
    if ! cp -a "$source_path" "$destination"; then
        log_error "备份失败：${source_path}"
        return 1
    fi
    log_ok "已备份到 ${destination}"
}

record_v2bx_state() {
    local active=0
    local enabled=0
    local previous_active=0
    local previous_enabled=0
    local tmp

    service_active "$V2BX_SERVICE" && active=1
    service_enabled "$V2BX_SERVICE" && enabled=1

    if [[ -f $XBOARD_STATE_FILE ]]; then
        # Preserve the original rollback state across repeated migrations.
        # shellcheck disable=SC1090
        source "$XBOARD_STATE_FILE"
        previous_active=${V2BX_WAS_ACTIVE:-0}
        previous_enabled=${V2BX_WAS_ENABLED:-0}
    fi
    if [[ $active -eq 0 && $enabled -eq 0 ]] \
        && [[ $previous_active -eq 1 || $previous_enabled -eq 1 ]]; then
        active=$previous_active
        enabled=$previous_enabled
    fi

    if ! mkdir -p "$XBOARD_ROOT"; then
        log_error "创建目录失败：${XBOARD_ROOT}"
        return 1
    fi
    tmp=$(mktemp "${XBOARD_STATE_FILE}.XXXXXX") || return 1
    if ! cat >"$tmp" <<EOF
V2BX_WAS_ACTIVE=${active}
V2BX_WAS_ENABLED=${enabled}
MIGRATION_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    then
        rm -f "$tmp"
        log_error "写入迁移状态失败。"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$XBOARD_STATE_FILE"; then
        rm -f "$tmp"
        log_error "保存迁移状态失败。"
        return 1
    fi
    log_info "已记录 V2bX 状态：active=${active}, enabled=${enabled}"
}

copy_sing_origin() {
    local source_path=${1:-$V2BX_ORIGIN}
    local tmp

    if [[ ! -f $source_path ]]; then
        log_warn "未找到 ${source_path}，跳过自定义 DNS 迁移。"
        return 0
    fi
    if ! mkdir -p "$XBOARD_ROOT"; then
        log_error "创建目录失败：${XBOARD_ROOT}"
        return 1
    fi
    source_path=$(readlink -f "$source_path")
    if [[ -z $source_path || ! -f $source_path ]]; then
        log_error "无法解析自定义配置文件路径。"
        return 1
    fi
    if [[ $source_path == "$XBOARD_CUSTOM_CONFIG" ]]; then
        log_info "自定义配置已在目标位置：${XBOARD_CUSTOM_CONFIG}"
        return 0
    fi

    tmp=$(mktemp "${XBOARD_CUSTOM_CONFIG}.XXXXXX") || return 1
    if ! cp -f "$source_path" "$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$XBOARD_CUSTOM_CONFIG"; then
        rm -f "$tmp"
        log_error "迁移自定义配置失败：${source_path}"
        return 1
    fi
    log_ok "已迁移 ${source_path} -> ${XBOARD_CUSTOM_CONFIG}"
}

top_kernel_has_custom_config() {
    awk '
        /^kernel:[[:space:]]*$/ { inside=1; next }
        inside && /^[^[:space:]]/ { exit }
        inside && /^[[:space:]]+custom_config:/ { found=1; exit }
        END { exit found ? 0 : 1 }
    ' "$XBOARD_CONFIG"
}

ensure_custom_config_reference() {
    local tmp

    [[ -f $XBOARD_CONFIG ]] || die "配置文件不存在：$XBOARD_CONFIG"
    [[ -f $XBOARD_CUSTOM_CONFIG ]] || return 0
    if grep -qE '^kernel:[[:space:]]*[^[:space:]]' "$XBOARD_CONFIG"; then
        log_error "当前 config.yml 使用行内 kernel 配置，脚本无法安全插入 custom_config。"
        return 1
    fi
    if grep -q '^kernel:' "$XBOARD_CONFIG" && top_kernel_has_custom_config; then
        log_info "config.yml 已启用 kernel.custom_config。"
        return 0
    fi

    backup_file "$XBOARD_CONFIG" "config.yml" || return 1
    tmp=$(mktemp "${XBOARD_CONFIG}.XXXXXX") || return 1

    if grep -q '^kernel:' "$XBOARD_CONFIG"; then
        awk -v custom_path="$XBOARD_CUSTOM_CONFIG" '
            BEGIN { inside=0; inserted=0 }
            {
                if (inside && /^[^[:space:]]/) {
                    if (!inserted) {
                        print "  custom_config: \"" custom_path "\""
                        inserted=1
                    }
                    inside=0
                }
                if ($0 ~ /^kernel:[[:space:]]*$/) {
                    print
                    if (!inserted) {
                        print "  custom_config: \"" custom_path "\""
                        inserted=1
                    }
                    inside=1
                    next
                }
                print
            }
            END {
                if (inside && !inserted) {
                    print "  custom_config: \"" custom_path "\""
                }
            }
        ' "$XBOARD_CONFIG" >"$tmp"
    else
        {
            printf 'kernel:\n  custom_config: "%s"\n\n' "$XBOARD_CUSTOM_CONFIG"
            cat "$XBOARD_CONFIG"
        } >"$tmp"
    fi

    if [[ ! -s $tmp ]]; then
        rm -f "$tmp"
        log_error "生成 config.yml 失败。"
        return 1
    fi
    if ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$XBOARD_CONFIG"; then
        rm -f "$tmp"
        log_error "写入 config.yml 失败。"
        return 1
    fi
    log_ok "已在 config.yml 中启用 kernel.custom_config。"
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

stop_v2bx() {
    if ! v2bx_installed; then
        log_info "未检测到 V2bX，跳过停止步骤。"
        return 0
    fi
    systemctl stop "$V2BX_SERVICE" 2>/dev/null || true
    if service_active "$V2BX_SERVICE"; then
        log_error "V2bX 仍在运行。"
        return 1
    fi
    systemctl disable "$V2BX_SERVICE" >/dev/null 2>&1 || true
    log_ok "V2bX 已停止并取消开机自启，文件未删除。"
}

cleanup_failed_migration() {
    local active=1
    local enabled=1

    log_warn "清理未完成的迁移：停止 Xboard-Node，恢复 V2bX。"
    if ! systemctl stop "$XBOARD_SERVICE"; then
        log_error "停止 Xboard-Node 失败，为避免端口冲突，未启动 V2bX。"
        return 1
    fi

    if [[ -f $XBOARD_STATE_FILE ]]; then
        # shellcheck disable=SC1090
        source "$XBOARD_STATE_FILE"
        active=${V2BX_WAS_ACTIVE:-1}
        enabled=${V2BX_WAS_ENABLED:-1}
    fi
    if ! v2bx_installed; then
        log_error "未找到 V2bX，无法恢复原服务。"
        return 1
    fi
    if [[ $enabled -eq 1 ]]; then
        systemctl enable "$V2BX_SERVICE" >/dev/null 2>&1 || true
    fi
    if [[ $active -eq 1 ]] && ! systemctl start "$V2BX_SERVICE"; then
        log_error "恢复 V2bX 失败，请手动检查。"
        return 1
    fi
    log_ok "V2bX 已恢复。"
}

rollback_to_v2bx() {
    local active=1
    local enabled=1

    require_root
    require_linux_systemd
    v2bx_installed || die "未找到 V2bX，无法回滚；Xboard-Node 未停止。"

    if [[ -f $XBOARD_STATE_FILE ]]; then
        # shellcheck disable=SC1090
        source "$XBOARD_STATE_FILE"
        active=${V2BX_WAS_ACTIVE:-1}
        enabled=${V2BX_WAS_ENABLED:-1}
    fi

    if ! systemctl stop "$XBOARD_SERVICE"; then
        log_error "停止 Xboard-Node 失败，回滚未完成。"
        return 1
    fi
    systemctl disable "$XBOARD_SERVICE" >/dev/null 2>&1 || true

    if [[ $enabled -eq 1 ]]; then
        systemctl enable "$V2BX_SERVICE" >/dev/null 2>&1 || true
    fi
    if [[ $active -eq 1 ]]; then
        if ! systemctl start "$V2BX_SERVICE"; then
            log_error "V2bX 启动失败，尝试恢复 Xboard-Node。"
            systemctl start "$XBOARD_SERVICE" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    log_ok "已回滚到 V2bX；Xboard-Node 文件保留。"
}

install_machine() {
    local panel=$1
    local token=$2
    local machine_id=$3
    local health_port=$4
    local force=$5
    local args=(install --mode machine --panel "$panel" --token "$token" --machine-id "$machine_id" --health-port "$health_port" --yes)

    [[ $force -eq 1 ]] && args+=(--force-reconfigure)
    run_official_installer "${args[@]}"
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

cmd_migrate() {
    local panel="" token="" machine_id="" custom_source=$V2BX_ORIGIN
    local health_port=65530 non_interactive=0 force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --panel) take_arg_value "$1" "$#" "${2:-}"; panel=$2; shift 2 ;;
            --token) take_arg_value "$1" "$#" "${2:-}"; token=$2; shift 2 ;;
            --machine-id) take_arg_value "$1" "$#" "${2:-}"; machine_id=$2; shift 2 ;;
            --health-port) take_arg_value "$1" "$#" "${2:-}"; health_port=$2; shift 2 ;;
            --custom-config) take_arg_value "$1" "$#" "${2:-}"; custom_source=$2; shift 2 ;;
            --yes|-y) non_interactive=1; shift ;;
            *) die "未知参数：$1" ;;
        esac
    done

    if [[ $non_interactive -eq 1 ]]; then
        [[ -n $panel && -n $token && -n $machine_id ]] \
            || die "--yes 模式必须同时提供 --panel、--token 和 --machine-id。"
    fi

    require_root
    require_linux_systemd
    check_platform

    [[ -n $panel ]] || prompt_value panel "面板地址" ""
    [[ -n $panel ]] || die "面板地址不能为空。"
    panel=$(normalize_panel_url "$panel")

    [[ -n $token ]] || prompt_value token "Machine Token" ""
    [[ -n $token ]] || die "Machine Token 不能为空。"

    [[ -n $machine_id ]] || prompt_value machine_id "Machine ID" ""
    is_positive_int "$machine_id" || die "Machine ID 必须是正整数。"
    is_port "$health_port" || die "健康检查端口必须在 0-65535 之间。"

    printf '\n'
    log_info "迁移配置："
    printf '  面板地址: %s\n' "$panel"
    printf '  Machine ID: %s\n' "$machine_id"
    printf '  sing_origin: %s\n' "$custom_source"
    printf '\n'
    if [[ $non_interactive -ne 1 ]] && ! confirm "确认安装并迁移到 Xboard-Node Machine mode" "y"; then
        return 0
    fi

    record_v2bx_state || die "无法记录 V2bX 状态，迁移未开始。"
    backup_file "$V2BX_CONFIG" "V2bX-config.json" || die "V2bX 配置备份失败，迁移未开始。"
    backup_file "$XBOARD_CONFIG" "config.yml" || die "Xboard-Node 配置备份失败，迁移未开始。"
    backup_file "$XBOARD_CUSTOM_CONFIG" "sing_origin.json" || die "Xboard-Node 自定义配置备份失败，迁移未开始。"
    xboard_installed && force=1

    log_info "执行官方 Machine mode 安装..."
    if ! install_machine "$panel" "$token" "$machine_id" "$health_port" "$force"; then
        log_error "Xboard-Node 安装失败，V2bX 尚未停止。"
        return 1
    fi

    if ! copy_sing_origin "$custom_source"; then
        cleanup_failed_migration || true
        return 1
    fi
    if ! ensure_custom_config_reference; then
        cleanup_failed_migration || true
        return 1
    fi

    if ! stop_v2bx; then
        log_error "停止 V2bX 失败，切换未完成。"
        cleanup_failed_migration || true
        return 1
    fi

    if ! start_xboard; then
        log_error "Xboard-Node 启动验证失败。"
        if [[ $non_interactive -eq 1 ]] || confirm "是否立即回滚到 V2bX" "y"; then
            if ! rollback_to_v2bx; then
                log_error "自动回滚失败，请立即手动检查。"
            fi
        fi
        return 1
    fi

    log_ok "迁移完成。"
    log_info "请确认面板中节点已经绑定到 machine_id=${machine_id}。"
    log_info "回滚命令：xns rollback"
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
    wait_for_health || die "安装完成，但健康检查失败，请查看：xns log"
    log_ok "Xboard-Node 安装完成。"
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

cmd_config() {
    require_root
    [[ -f $XBOARD_CONFIG ]] || die "配置文件不存在：$XBOARD_CONFIG"
    "${EDITOR:-vi}" "$XBOARD_CONFIG"
    if confirm "是否重启 Xboard-Node 使配置生效" "y"; then
        if ! cmd_restart; then
            log_warn "配置可能无效，查看日志：xns log"
            return 1
        fi
    fi
}

cmd_dns() {
    require_root
    [[ -f $XBOARD_CUSTOM_CONFIG ]] || die "配置文件不存在：$XBOARD_CUSTOM_CONFIG"
    "${EDITOR:-vi}" "$XBOARD_CUSTOM_CONFIG"
    if confirm "是否重启 Xboard-Node 使配置生效" "y"; then
        cmd_restart || return 1
    fi
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
    log_ok "管理脚本已更新，请重新运行。"
}

cmd_rollback() {
    require_root
    require_linux_systemd
    confirm "确认停止 Xboard-Node 并回滚到 V2bX" "n" || return 0
    rollback_to_v2bx
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
    if v2bx_installed; then
        if service_active "$V2BX_SERVICE"; then
            printf 'V2bX: %b仍在运行%b\n' "$YELLOW" "$PLAIN"
        else
            printf 'V2bX: 已停止（可回滚）\n'
        fi
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
    printf '  %b14.%b 编辑 config.yml        xns config\n' "$GREEN" "$PLAIN"
    printf '  %b15.%b 编辑 sing_origin.json  xns dns\n' "$GREEN" "$PLAIN"
    printf '%s\n' '------------------------------------------------------------'
    printf '  %b16.%b 从 V2bX 一键迁移       xns migrate\n' "$GREEN" "$PLAIN"
    printf '  %b17.%b 回滚到 V2bX            xns rollback\n' "$GREEN" "$PLAIN"
    printf '  %b18.%b 更新管理脚本           xns update-script\n' "$GREEN" "$PLAIN"
    printf '  %b19.%b 退出\n' "$GREEN" "$PLAIN"
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
        choice=$(read_line "请输入选择 [1-19]: ")
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
            14) cmd_config ;;
            15) cmd_dns ;;
            16) cmd_migrate ;;
            17) cmd_rollback ;;
            18) cmd_update_script ;;
            19|q|Q|exit|quit) exit 0 ;;
            *) log_warn "请输入正确的数字 [1-19]。" ;;
        esac
        read_line "按回车返回主菜单..." >/dev/null
    done
}

show_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

用法:
  xns                         打开管理菜单
  xns migrate                 从 V2bX 一键迁移
  xns install                 安装或重新配置
  xns update                  升级 Xboard-Node
  xns uninstall               卸载 Xboard-Node
  xns start|stop|restart|status|log
  xns enable|disable
  xns version                 查看版本
  xns health                  健康检查
  xns list                    查看 xbctl 实例
  xns config                  编辑 config.yml
  xns dns                     编辑 sing_origin.json
  xns rollback                回滚到 V2bX
  xns update-script           更新管理脚本

迁移参数:
  xns migrate --panel URL --token TOKEN --machine-id ID
              [--custom-config PATH] [--health-port PORT] [--yes]

一键迁移固定使用 Machine mode。
EOF
}

main() {
    local action=${1:-menu}
    [[ $# -gt 0 ]] && shift

    case "$action" in
        menu) menu_loop ;;
        migrate) cmd_migrate "$@" ;;
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
        config) cmd_config ;;
        dns) cmd_dns ;;
        rollback) cmd_rollback ;;
        update-script) cmd_update_script ;;
        help|--help|-h) show_usage ;;
        *) show_usage; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
