#!/usr/bin/env bash
set -euo pipefail

SCRIPT_RAW_BASE="${XBOARD_SCRIPT_RAW_BASE:-https://raw.githubusercontent.com/ChampagneA7/Xboard-Node-Script/main}"
XNS_PATH="/usr/local/bin/xns"
ALIAS_PATH="/usr/local/bin/Xboard-Node-Script"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

die() {
    printf '%b[ERROR]%b %s\n' "$red" "$plain" "$*" >&2
    exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行安装脚本。"
command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，暂不支持。"

tmp=""
cleanup() {
    [[ -n $tmp ]] && rm -f "$tmp"
}
trap cleanup EXIT

source_script=""
script_dir=""
if [[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != /dev/fd/* && ${BASH_SOURCE[0]} != /proc/self/fd/* ]]; then
    script_dir=$(dirname "${BASH_SOURCE[0]}")
    if [[ -d $script_dir ]]; then
        script_dir=$(realpath "$script_dir" 2>/dev/null || printf '%s' "$script_dir")
    fi
    if [[ -n $script_dir && -f "${script_dir}/Xboard-Node-Script.sh" ]]; then
        source_script="${script_dir}/Xboard-Node-Script.sh"
    fi
fi

if [[ -z $source_script ]]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/Xboard-Node-Script.XXXXXX")
    cache_bust=$(date +%s)
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 3 --connect-timeout 15 --max-time 180 \
            -o "$tmp" "${SCRIPT_RAW_BASE}/Xboard-Node-Script.sh?ts=${cache_bust}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$tmp" "${SCRIPT_RAW_BASE}/Xboard-Node-Script.sh?ts=${cache_bust}"
    else
        die "未找到 curl 或 wget。"
    fi
    source_script=$tmp
fi

bash -n "$source_script" || die "管理脚本语法校验失败。"
install -m 0755 "$source_script" "$XNS_PATH"
ln -sfn "$XNS_PATH" "$ALIAS_PATH"

printf '%b[OK]%b 已安装：%s\n' "$green" "$plain" "$XNS_PATH"
printf '%b[OK]%b 已创建完整名称入口：%s\n' "$green" "$plain" "$ALIAS_PATH"
printf '\n运行以下命令打开菜单：\n'
printf '  %bxns%b\n' "$yellow" "$plain"
