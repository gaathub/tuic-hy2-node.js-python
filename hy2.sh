#!/usr/bin/env bash
# TUIC 多节点管理脚本
# 功能：多个 TUIC 节点共用一个 UUID 和证书；每个节点独立端口、SOCKS5 配置（仅记录）、日志和 PID。

set -Eeuo pipefail
umask 077

# -------------------- 全局参数（一般无需修改） --------------------
TUIC_VERSION="${TUIC_VERSION:-v1.4.5}"
SNI="${SNI:-www.bing.com}"
ALPN="${ALPN:-h3}"
UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"

# 数据目录选择
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "${TUIC_BASE_DIR:-}" ]]; then
    BASE_DIR="$TUIC_BASE_DIR"
elif [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != /proc/* && "$SCRIPT_SOURCE" != /dev/fd/* && "$SCRIPT_SOURCE" != /dev/stdin ]]; then
    BASE_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
else
    BASE_DIR="/opt/tuic-multi"
fi
NODES_DIR="$BASE_DIR/nodes"
AUTH_FILE="$BASE_DIR/tuic-auth.conf"
CERT_FILE="$BASE_DIR/cert.pem"
KEY_FILE="$BASE_DIR/key.pem"

ARCH=""
BIN_NAME=""
BIN_PATH=""
NODE_NAME=""
NODE_DIR=""
NODE_PORT=""
USE_SOCKS5="n"
SOCKS_HOST=""
SOCKS_PORT="1080"
SOCKS_USER=""
SOCKS_PASS=""
PROXY_MODE="all_proxy"
AUTH_UUID=""
AUTH_PASS=""

# -------------------- 通用小工具 --------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "❌ 请使用 root 运行此脚本，例如：sudo bash tuic-multi.sh"
        exit 1
    fi
}

pause_enter() {
    if [[ -t 0 ]]; then
        read -r -p $'\n按回车键继续...' _ || true
    fi
}

read_value() {
    local prompt="$1" default_value="${2:-}" value=""
    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " value
        REPLY="${value:-$default_value}"
    else
        read -r -p "$prompt: " value
        REPLY="$value"
    fi
}

read_secret() {
    local prompt="$1" value=""
    read -r -s -p "$prompt: " value
    printf '\n'
    REPLY="$value"
}

ask_yes_no() {
    local prompt="$1" default_value="${2:-n}" value=""
    local hint="y/N"
    [[ "$default_value" == "y" ]] && hint="Y/n"
    while true; do
        read -r -p "$prompt [$hint]: " value
        value="${value:-$default_value}"
        case "${value,,}" in
            y|yes) REPLY="y"; return 0 ;;
            n|no)  REPLY="n"; return 0 ;;
            *) echo "请输入 y 或 n。" ;;
        esac
    done
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_node_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$ ]]
}

normalize_host_port() {
    local host="$1" port="$2"
    if [[ "$host" == \[*\] ]]; then
        printf '%s:%s' "$host" "$port"
    elif [[ "$host" == *:* ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/}"
    value="${value//$'\n'/\\n}"
    printf '"%s"' "$value"
}

# -------------------- 系统依赖、UUID、二进制和证书 --------------------
install_missing_dependencies() {
    local missing=()
    has_cmd curl || missing+=(curl)
    has_cmd openssl || missing+=(openssl)
    if (( ${#missing[@]} == 0 )); then return 0; fi

    echo "需要安装依赖：${missing[*]}"
    if has_cmd apt-get; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    elif has_cmd dnf; then
        dnf install -y "${missing[@]}"
    elif has_cmd yum; then
        yum install -y "${missing[@]}"
    elif has_cmd apk; then
        apk add --no-cache "${missing[@]}"
    elif has_cmd zypper; then
        zypper --non-interactive install "${missing[@]}"
    else
        echo "❌ 找不到受支持的包管理器，请手动安装 curl 和 openssl。" >&2
        exit 1
    fi
}

get_arch() {
    case "$(uname -m | tr '[:upper:]' '[:lower:]')" in
        x86_64|amd64) printf 'x86_64-linux' ;;
        aarch64|arm64) printf 'aarch64-linux' ;;
        *) return 1 ;;
    esac
}

generate_uuid() {
    local uuid=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        IFS= read -r uuid < /proc/sys/kernel/random/uuid || true
    elif has_cmd uuidgen; then
        uuid="$(uuidgen 2>/dev/null || true)"
    else
        uuid="$(openssl rand -hex 16)"
        uuid="${uuid:0:8}-${uuid:8:4}-4${uuid:13:3}-8${uuid:17:3}-${uuid:20:12}"
    fi
    uuid="${uuid,,}"
    [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
        echo "❌ 生成 UUID 失败。" >&2
        return 1
    }
    printf '%s\n' "$uuid"
}

ensure_auth() {
    local saved_uuid="" saved_pass=""
    mkdir -p "$BASE_DIR"
    if [[ -f "$AUTH_FILE" ]]; then
        { read -r saved_uuid; read -r saved_pass; } < "$AUTH_FILE" || true
    fi
    if [[ "$saved_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ && -n "$saved_pass" ]]; then
        AUTH_UUID="${saved_uuid,,}"
        AUTH_PASS="$saved_pass"
        chmod 600 "$AUTH_FILE" 2>/dev/null || true
        return 0
    fi
    if [[ -n "$saved_uuid" ]]; then
        cp -a "$AUTH_FILE" "${AUTH_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        echo "⚠️ 原 tuic-auth.conf 内容格式不正确，已备份原文件。"
    fi
    AUTH_UUID="$(generate_uuid)"
    AUTH_PASS="$(openssl rand -hex 16)"
    printf '%s\n%s\n' "$AUTH_UUID" "$AUTH_PASS" > "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    echo "✅ 已生成公共 UUID 及密码，并保存到：$AUTH_FILE"
}

ensure_binary() {
    ARCH="$(get_arch)" || {
        echo "❌ 不支持当前 CPU 架构：$(uname -m)" >&2
        exit 1
    }
    BIN_NAME="tuic-server-${ARCH}"
    BIN_PATH="$BASE_DIR/tuic-server"
    if [[ -x "$BIN_PATH" ]]; then return 0; fi

    local url="https://github.com/Itsusinn/tuic/releases/download/${TUIC_VERSION}/${BIN_NAME}"
    local tmp="${BIN_PATH}.download"
    echo "⏳ 正在下载 TUIC ${TUIC_VERSION}（${ARCH}）..."
    if ! curl -fL --retry 3 --connect-timeout 30 --output "$tmp" "$url"; then
        rm -f "$tmp"
        echo "❌ 下载失败：$url" >&2
        exit 1
    fi
    chmod 755 "$tmp"
    mv -f "$tmp" "$BIN_PATH"
    echo "✅ TUIC 内核已准备好：$BIN_PATH"
}

ensure_certificate() {
    if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
        chmod 600 "$KEY_FILE" 2>/dev/null || true
        return 0
    fi
    echo "🔐 正在生成共享自签名证书（SNI：$SNI）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}" >/dev/null 2>&1
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    echo "✅ 共享证书已生成。客户端链接会使用 insecure=1。"
}

ensure_common_files() {
    ensure_root
    install_missing_dependencies
    mkdir -p "$NODES_DIR"
    ensure_auth
    ensure_binary
    ensure_certificate
}

# -------------------- 节点配置文件 --------------------
save_node_meta() {
    local file="$NODE_DIR/node.conf"
    mkdir -p "$NODE_DIR"
    {
        printf 'NODE_NAME=%q\n' "$NODE_NAME"
        printf 'NODE_PORT=%q\n' "$NODE_PORT"
        printf 'USE_SOCKS5=%q\n' "$USE_SOCKS5"
        printf 'SOCKS_HOST=%q\n' "$SOCKS_HOST"
        printf 'SOCKS_PORT=%q\n' "$SOCKS_PORT"
        printf 'SOCKS_USER=%q\n' "$SOCKS_USER"
        printf 'SOCKS_PASS=%q\n' "$SOCKS_PASS"
        printf 'PROXY_MODE=%q\n' "$PROXY_MODE"
    } > "$file"
    chmod 600 "$file"
}

load_node() {
    local name="$1"
    if ! valid_node_name "$name"; then
        echo "❌ 节点名称格式不正确。只允许英文、数字、点、下划线和短横线。" >&2
        return 1
    fi
    NODE_DIR="$NODES_DIR/$name"
    if [[ ! -f "$NODE_DIR/node.conf" ]]; then
        echo "❌ 找不到节点：$name" >&2
        return 1
    fi
    source "$NODE_DIR/node.conf"
    return 0
}

port_already_managed() {
    local wanted="$1" conf port
    shopt -s nullglob
    for conf in "$NODES_DIR"/*/node.conf; do
        port="$( ( unset NODE_PORT; source "$conf"; printf '%s' "${NODE_PORT:-}" ) )"
        if [[ "$port" == "$wanted" ]]; then
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

port_in_use_by_system() {
    local port="$1"
    if has_cmd ss; then
        ss -H -lntu "sport = :$port" 2>/dev/null | grep . >/dev/null
    elif has_cmd lsof; then
        lsof -nP -iTCP:"$port" -iUDP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

choose_port() {
    local value default_port="${1:-22222}"
    while true; do
        read_value "请输入 TUIC 监听端口" "$default_port"
        value="$REPLY"
        if ! valid_port "$value"; then
            echo "❌ 端口必须是 1-65535 的整数。"
            continue
        fi
        if port_already_managed "$value"; then
            echo "❌ 这个端口已经被本脚本的其他节点使用。"
            continue
        fi
        if port_in_use_by_system "$value"; then
            echo "❌ 检测到端口 $value 已被系统中的其他程序监听。"
            continue
        fi
        NODE_PORT="$value"
        return 0
    done
}

write_node_config() {
    local toml_file="$NODE_DIR/server.toml"
    mkdir -p "$NODE_DIR"
    
    cat > "$toml_file" <<EOF
log_level = "warn"
server = "0.0.0.0:${NODE_PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${AUTH_UUID} = "${AUTH_PASS}"

[tls]
certificate = "${CERT_FILE}"
private_key = "${KEY_FILE}"
alpn = ["${ALPN}"]
EOF

    if [[ "$USE_SOCKS5" == "y" ]]; then
        cat <<EOF >> "$toml_file"

# 提示：保留了您选择的 SOCKS5 代理参数记录，但 TUIC v1.4.5 服务端原生并不直接支持 SOCKS5 出站分流，此配置将直连。
# SOCKS_HOST = "${SOCKS_HOST}"
# SOCKS_PORT = "${SOCKS_PORT}"
EOF
    fi

    chmod 600 "$toml_file"
}

# -------------------- 显示信息、节点生命周期 --------------------
get_server_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    fi
    printf '%s' "${ip:-YOUR_SERVER_IP}"
}

print_link() {
    local ip="$1" url_ip="$1" label="$2"
    if [[ "$url_ip" == *:* && "$url_ip" != \[*\] ]]; then url_ip="[$url_ip]"; fi
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=%s&allowInsecure=1&sni=%s&udp_relay_mode=native#TUIC-%s\n' \
        "$AUTH_UUID" "$AUTH_PASS" "$url_ip" "$NODE_PORT" "$ALPN" "$SNI" "$label"
}

node_is_running() {
    local pid="" command_line=""
    [[ -f "$NODE_DIR/tuic.pid" ]] || return 1
    IFS= read -r pid < "$NODE_DIR/tuic.pid" || true
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [[ -r "/proc/$pid/cmdline" ]]; then
        command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    else
        command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    fi
    [[ "$command_line" == *"$NODE_DIR/server.toml"* && "$command_line" == *"tuic"* ]]
}

create_node() {
    ensure_common_files
    local name_value="" use_auth="n" mode_value="2" server_ip=""
    echo ""
    echo "创建新 TUIC 节点"
    echo "节点名称只能使用英文、数字、点、下划线和短横线，例如 A、B、Tokyo-2。"
    while true; do
        read_value "请输入节点名称" "A"
        name_value="$REPLY"
        if ! valid_node_name "$name_value"; then
            echo "❌ 名称不合法，请重新输入。"
        elif [[ -e "$NODES_DIR/$name_value" ]]; then
            echo "❌ 这个节点名称已经存在。"
        else
            break
        fi
    done
    NODE_NAME="$name_value"
    NODE_DIR="$NODES_DIR/$NODE_NAME"
    choose_port "22222"

    echo ""
    echo "请选择这个节点的出站方式："
    echo "1. 不使用 SOCKS5，直接从本 VPS 出口连接"
    echo "2. 使用本机 SOCKS5（例如 127.0.0.1:1080）"
    echo "3. 使用远程 SOCKS5"
    while true; do
        read_value "请输入选项" "1"
        case "$REPLY" in
            1) USE_SOCKS5="n"; SOCKS_HOST=""; SOCKS_USER=""; SOCKS_PASS=""; break ;;
            2) USE_SOCKS5="y"; SOCKS_HOST="127.0.0.1"; break ;;
            3) USE_SOCKS5="y"; read_value "请输入 SOCKS5 地址（IP 或域名；IPv6 可直接填地址）"; SOCKS_HOST="$REPLY"; [[ -n "$SOCKS_HOST" ]] && break; echo "地址不能为空。" ;;
            *) echo "请输入 1、2 或 3。" ;;
        esac
    done

    if [[ "$USE_SOCKS5" == "y" ]]; then
        if [[ "$SOCKS_HOST" == "127.0.0.1" ]]; then
            read_value "请输入本机 SOCKS5 端口" "1080"
        else
            read_value "请输入 SOCKS5 端口" "1080"
        fi
        while ! valid_port "$REPLY"; do
            echo "❌ 端口必须是 1-65535 的整数。"
            read_value "请输入 SOCKS5 端口" "1080"
        done
        SOCKS_PORT="$REPLY"

        ask_yes_no "SOCKS5 是否需要用户名和密码认证" "n"
        use_auth="$REPLY"
        if [[ "$use_auth" == "y" ]]; then
            while true; do
                read_value "请输入 SOCKS5 用户名"
                SOCKS_USER="$REPLY"
                [[ -n "$SOCKS_USER" ]] && break
                echo "用户名不能为空。"
            done
            while true; do
                read_secret "请输入 SOCKS5 密码"
                SOCKS_PASS="$REPLY"
                [[ -n "$SOCKS_PASS" ]] && break
                echo "密码不能为空。"
            done
        else
            SOCKS_USER=""
            SOCKS_PASS=""
        fi

        echo ""
        echo "请选择代理分流模式："
        echo "1. 仅 TCP 走代理，UDP 直连"
        echo "2. TCP 和 UDP 都尽可能走 SOCKS5（推荐按你的需求选择）"
        read_value "请输入选项" "2"
        while [[ "$REPLY" != "1" && "$REPLY" != "2" ]]; do
            echo "请输入 1 或 2。"
            read_value "请输入选项" "2"
        done
        mode_value="$REPLY"
        [[ "$mode_value" == "2" ]] && PROXY_MODE="all_proxy" || PROXY_MODE="tcp_only"
    else
        SOCKS_PORT="1080"
        SOCKS_USER=""
        SOCKS_PASS=""
        PROXY_MODE="all_proxy"
    fi

    save_node_meta
    write_node_config
    echo ""
    echo "节点配置已生成：$NODE_DIR/server.toml"
    echo "端口：$NODE_PORT/UDP"
    if [[ "$USE_SOCKS5" == "y" ]]; then
        echo "SOCKS5：$SOCKS_HOST:$SOCKS_PORT"
        echo "模式：$PROXY_MODE"
    else
        echo "出站：直连 VPS"
    fi
    ask_yes_no "立即启动这个节点" "y"
    if [[ "$REPLY" == "y" ]]; then
        start_node "$NODE_NAME"
    fi
    server_ip="$(get_server_ip)"
    echo ""
    echo "✅ 节点创建完成。"
    echo "共享 UUID：$AUTH_UUID"
    echo "共享 密码：$AUTH_PASS"
    echo "节点链接（客户端需允许不安全证书 insecure=1）："
    print_link "$server_ip" "$NODE_NAME"
    echo "⚠️ 请在云厂商防火墙/安全组和 VPS 防火墙中放行 UDP 端口 $NODE_PORT。"
}

start_node() {
    local name="$1" pid=""
    load_node "$name" || return 1
    if [[ ! -x "$BIN_PATH" ]]; then ensure_common_files; fi
    if node_is_running; then
        echo "ℹ️ 节点 $NODE_NAME 已在运行，PID：$(cat "$NODE_DIR/tuic.pid")"
        return 0
    fi
    rm -f "$NODE_DIR/tuic.pid"
    if [[ ! -f "$NODE_DIR/server.toml" ]]; then
        { read -r AUTH_UUID; read -r AUTH_PASS; } < "$AUTH_FILE"
        write_node_config
    fi
    echo "🚀 正在启动节点 $NODE_NAME（UDP/$NODE_PORT）..."
    nohup "$BIN_PATH" -c "$NODE_DIR/server.toml" > "$NODE_DIR/tuic.log" 2>&1 </dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$NODE_DIR/tuic.pid"
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "✅ 节点 $NODE_NAME 已启动，PID：$pid"
        echo "日志：$NODE_DIR/tuic.log"
    else
        rm -f "$NODE_DIR/tuic.pid"
        echo "❌ 节点启动失败，请查看日志："
        tail -n 60 "$NODE_DIR/tuic.log" 2>/dev/null || true
        return 1
    fi
}

stop_node() {
    local name="$1" pid="" i
    load_node "$name" || return 1
    if ! node_is_running; then
        rm -f "$NODE_DIR/tuic.pid"
        echo "ℹ️ 节点 $NODE_NAME 当前没有运行。"
        return 0
    fi
    IFS= read -r pid < "$NODE_DIR/tuic.pid" || true
    echo "🛑 正在停止节点 $NODE_NAME（PID：$pid）..."
    kill "$pid" 2>/dev/null || true
    for ((i=0; i<10; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$NODE_DIR/tuic.pid"
    echo "✅ 节点 $NODE_NAME 已停止。"
}

restart_node() {
    local name="$1"
    stop_node "$name" || return 1
    start_node "$name"
}

list_nodes() {
    local conf name status port proxy mode
    shopt -s nullglob
    local files=("$NODES_DIR"/*/node.conf)
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then
        echo "目前还没有节点，请先选择‘创建新节点’。"
        return 0
    fi
    printf '\n%-18s %-8s %-10s %-12s %-12s\n' '节点名称' '端口/UDP' '运行状态' 'SOCKS5' '模式'
    printf '%-18s %-8s %-10s %-12s %-12s\n' '------------------' '--------' '----------' '------------' '------------'
    for conf in "${files[@]}"; do
        source "$conf"
        name="${NODE_NAME:-$(basename "$(dirname "$conf")")}"
        port="${NODE_PORT:-?}"
        proxy="否"
        [[ "${USE_SOCKS5:-n}" == "y" ]] && proxy="${SOCKS_HOST:-?}:${SOCKS_PORT:-?}"
        mode="${PROXY_MODE:-direct}"
        if [[ -f "$(dirname "$conf")/tuic.pid" ]] && kill -0 "$(cat "$(dirname "$conf")/tuic.pid" 2>/dev/null)" 2>/dev/null; then
            status="运行中"
        else
            status="已停止"
        fi
        printf '%-18s %-8s %-10s %-12s %-12s\n' "$name" "$port" "$status" "$proxy" "$mode"
    done
    echo ""
}

ask_node_name() {
    read_value "请输入节点名称"
    REPLY="$REPLY"
}

delete_node() {
    local name="$1" dir="$NODES_DIR/$1"
    load_node "$name" || return 1
    echo "即将删除节点 $NODE_NAME（端口 $NODE_PORT），这不会删除其他节点、公共账号信息或共享证书。"
    ask_yes_no "确认删除" "n"
    [[ "$REPLY" == "y" ]] || { echo "已取消。"; return 0; }
    stop_node "$name" || true
    rm -rf -- "$dir"
    echo "✅ 节点 $name 已删除。"
}

show_logs() {
    local name="$1"
    load_node "$name" || return 1
    if [[ ! -f "$NODE_DIR/tuic.log" ]]; then
        echo "该节点尚无日志文件。"
        return 0
    fi
    echo "显示 $name 的最近日志；按 Ctrl+C 返回菜单。"
    tail -n 100 -f "$NODE_DIR/tuic.log"
}

show_auth() {
    ensure_auth
    echo "公共 TUIC UUID：$AUTH_UUID"
    echo "公共 TUIC 密码：$AUTH_PASS"
    echo "文件：$AUTH_FILE（权限应为 600，请勿公开分享）"
}

print_help() {
    cat <<EOF
TUIC 多节点管理脚本

交互式菜单：
  bash "${BASH_SOURCE[0]}"

命令行模式：
  bash "${BASH_SOURCE[0]}" create
  bash "${BASH_SOURCE[0]}" list
  bash "${BASH_SOURCE[0]}" start <节点名>
  bash "${BASH_SOURCE[0]}" stop <节点名>
  bash "${BASH_SOURCE[0]}" restart <节点名>
  bash "${BASH_SOURCE[0]}" delete <节点名>
  bash "${BASH_SOURCE[0]}" logs <节点名>
  bash "${BASH_SOURCE[0]}" auth
  bash "${BASH_SOURCE[0]}" help

数据目录：${BASE_DIR}/nodes/<节点名>/
公共鉴权：${AUTH_FILE}
公共证书：${CERT_FILE} 和 ${KEY_FILE}
EOF
}

menu() {
    local choice
    while true; do
        echo ""
        echo "===================================================="
        echo "          TUIC 多节点管理脚本"
        echo "===================================================="
        echo "1. 创建新节点"
        echo "2. 查看所有节点"
        echo "3. 启动指定节点"
        echo "4. 停止指定节点"
        echo "5. 重启指定节点"
        echo "6. 删除指定节点"
        echo "7. 查看节点日志"
        echo "8. 查看公共验证信息"
        echo "9. 退出"
        read -r -p "请输入选项 [1-9]：" choice
        case "$choice" in
            1) create_node; pause_enter ;;
            2) list_nodes; pause_enter ;;
            3) ask_node_name; start_node "$REPLY"; pause_enter ;;
            4) ask_node_name; stop_node "$REPLY"; pause_enter ;;
            5) ask_node_name; restart_node "$REPLY"; pause_enter ;;
            6) ask_node_name; delete_node "$REPLY"; pause_enter ;;
            7) ask_node_name; show_logs "$REPLY"; pause_enter ;;
            8) show_auth; pause_enter ;;
            9|q|Q) exit 0 ;;
            *) echo "❌ 请输入 1-9 之间的选项。" ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"
    ensure_root
    case "$cmd" in
        menu) menu ;;
        create) create_node ;;
        list) list_nodes ;;
        start) [[ $# -ge 2 ]] || { echo "用法：$0 start <节点名>"; exit 2; }; start_node "$2" ;;
        stop) [[ $# -ge 2 ]] || { echo "用法：$0 stop <节点名>"; exit 2; }; stop_node "$2" ;;
        restart) [[ $# -ge 2 ]] || { echo "用法：$0 restart <节点名>"; exit 2; }; restart_node "$2" ;;
        delete|del|rm) [[ $# -ge 2 ]] || { echo "用法：$0 delete <节点名>"; exit 2; }; delete_node "$2" ;;
        logs) [[ $# -ge 2 ]] || { echo "用法：$0 logs <节点名>"; exit 2; }; show_logs "$2" ;;
        auth|uuid) show_auth ;;
        help|-h|--help) print_help ;;
        *) echo "❌ 未知命令：$cmd"; print_help; exit 2 ;;
    esac
}

main "$@"
