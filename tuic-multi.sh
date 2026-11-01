#!/usr/bin/env bash
# 基于 sing-box 的 TUIC 多节点管理脚本
# 功能：多个 TUIC 节点共用一个 UUID 和证书；每个节点独立端口、SOCKS5 代理路由、日志和 PID。

set -Eeuo pipefail
umask 077

# -------------------- 全局参数（一般无需修改） --------------------
SINGBOX_VERSION="1.10.1" # 默认使用的 sing-box 版本
SNI="${SNI:-www.bing.com}"
ALPN="${ALPN:-h3}"

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
        echo "❌ 请使用 root 运行此脚本"
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

# -------------------- 系统依赖、鉴权、二进制和证书 --------------------
install_missing_dependencies() {
    local missing=()
    has_cmd curl || missing+=(curl)
    has_cmd openssl || missing+=(openssl)
    has_cmd tar || missing+=(tar)
    if (( ${#missing[@]} == 0 )); then return 0; fi

    echo "需要安装依赖：${missing[*]}"
    if has_cmd apt-get; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    elif has_cmd yum; then
        yum install -y "${missing[@]}"
    elif has_cmd apk; then
        apk add --no-cache "${missing[@]}"
    else
        echo "❌ 找不到受支持的包管理器，请手动安装 ${missing[*]}。" >&2
        exit 1
    fi
}

get_arch() {
    case "$(uname -m | tr '[:upper:]' '[:lower:]')" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
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
    AUTH_UUID="$(generate_uuid)"
    AUTH_PASS="$(openssl rand -hex 16)"
    printf '%s\n%s\n' "$AUTH_UUID" "$AUTH_PASS" > "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    echo "✅ 已生成公共 UUID 及密码。"
}

ensure_binary() {
    ARCH="$(get_arch)" || { echo "❌ 不支持架构：$(uname -m)" >&2; exit 1; }
    BIN_PATH="$BASE_DIR/sing-box"
    if [[ -x "$BIN_PATH" ]]; then return 0; fi

    local release_file="sing-box-${SINGBOX_VERSION}-linux-${ARCH}"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${release_file}.tar.gz"
    local tmp_dir="${BASE_DIR}/tmp_singbox"
    mkdir -p "$tmp_dir"
    
    echo "⏳ 正在下载 sing-box v${SINGBOX_VERSION}（${ARCH}）..."
    if ! curl -fL --retry 3 --connect-timeout 30 --output "$tmp_dir/sb.tar.gz" "$url"; then
        echo "❌ 下载失败：$url" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    tar -xzf "$tmp_dir/sb.tar.gz" -C "$tmp_dir"
    mv -f "$tmp_dir/${release_file}/sing-box" "$BIN_PATH"
    chmod 755 "$BIN_PATH"
    rm -rf "$tmp_dir"
    echo "✅ sing-box 内核已准备好。"
}

ensure_certificate() {
    if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then return 0; fi
    echo "🔐 正在生成自签名证书（SNI：$SNI）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}" >/dev/null 2>&1
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
}

ensure_common_files() {
    ensure_root
    install_missing_dependencies
    mkdir -p "$NODES_DIR"
    ensure_auth
    ensure_binary
    ensure_certificate
}

# -------------------- 节点配置文件 (JSON 格式) --------------------
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
    if ! valid_node_name "$name"; then return 1; fi
    NODE_DIR="$NODES_DIR/$name"
    if [[ ! -f "$NODE_DIR/node.conf" ]]; then return 1; fi
    source "$NODE_DIR/node.conf"
    return 0
}

port_already_managed() {
    local wanted="$1" conf port
    shopt -s nullglob
    for conf in "$NODES_DIR"/*/node.conf; do
        port="$( ( unset NODE_PORT; source "$conf"; printf '%s' "${NODE_PORT:-}" ) )"
        if [[ "$port" == "$wanted" ]]; then shopt -u nullglob; return 0; fi
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
        if ! valid_port "$value"; then echo "❌ 端口不合法。"; continue; fi
        if port_already_managed "$value"; then echo "❌ 端口被其他节点占用。"; continue; fi
        if port_in_use_by_system "$value"; then echo "❌ 端口被系统其他程序占用。"; continue; fi
        NODE_PORT="$value"
        return 0
    done
}

write_node_config() {
    local json_file="$NODE_DIR/config.json"
    mkdir -p "$NODE_DIR"
    
    # 构建基础的出站配置
    local outbounds_json='[{"type": "direct", "tag": "direct"}]'
    local route_json='{"rules": []}'

    # 如果启用了 SOCKS5，动态组装 JSON
    if [[ "$USE_SOCKS5" == "y" ]]; then
        local auth_block=""
        if [[ -n "$SOCKS_USER" ]]; then
            auth_block=",\"username\": \"$SOCKS_USER\", \"password\": \"$SOCKS_PASS\""
        fi
        outbounds_json="[
            {\"type\": \"socks\", \"tag\": \"socks-out\", \"server\": \"$SOCKS_HOST\", \"server_port\": $SOCKS_PORT $auth_block},
            {\"type\": \"direct\", \"tag\": \"direct\"}
        ]"
        
        if [[ "$PROXY_MODE" == "all_proxy" ]]; then
            route_json='{"rules": [{"inbound": ["tuic-in"], "outbound": "socks-out"}]}'
        else
            # TCP走SOCKS5，UDP直连
            route_json='{"rules": [
                {"network": ["udp"], "outbound": "direct"},
                {"inbound": ["tuic-in"], "outbound": "socks-out"}
            ]}'
        fi
    fi

    # 写入最终的 sing-box 配置文件
    cat > "$json_file" <<EOF
{
  "log": {
    "level": "warn",
    "output": "${NODE_DIR}/singbox.log"
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${NODE_PORT},
      "users": [
        {
          "uuid": "${AUTH_UUID}",
          "password": "${AUTH_PASS}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}",
        "alpn": ["${ALPN}"]
      }
    }
  ],
  "outbounds": ${outbounds_json},
  "route": ${route_json}
}
EOF
    chmod 600 "$json_file"
}

# -------------------- 显示信息、节点生命周期 --------------------
get_server_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then ip="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"; fi
    printf '%s' "${ip:-YOUR_SERVER_IP}"
}

print_link() {
    local ip="$1" url_ip="$1" label="$2"
    if [[ "$url_ip" == *:* && "$url_ip" != \[*\] ]]; then url_ip="[$url_ip]"; fi
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=%s&allowInsecure=1&sni=%s#TUIC-%s\n' \
        "$AUTH_UUID" "$AUTH_PASS" "$url_ip" "$NODE_PORT" "$ALPN" "$SNI" "$label"
}

node_is_running() {
    local pid="" command_line=""
    [[ -f "$NODE_DIR/node.pid" ]] || return 1
    IFS= read -r pid < "$NODE_DIR/node.pid" || true
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [[ -r "/proc/$pid/cmdline" ]]; then
        command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    else
        command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    fi
    [[ "$command_line" == *"$NODE_DIR/config.json"* && "$command_line" == *"sing-box"* ]]
}

create_node() {
    ensure_common_files
    local name_value="" use_auth="n" mode_value="2" server_ip=""
    echo -e "\n=== 创建新 TUIC 节点 ==="
    while true; do
        read_value "请输入节点名称 (限英文、数字、中划线)" "A"
        name_value="$REPLY"
        if ! valid_node_name "$name_value"; then echo "❌ 名称不合法。"; elif [[ -e "$NODES_DIR/$name_value" ]]; then echo "❌ 节点名已存在。"; else break; fi
    done
    NODE_NAME="$name_value"
    NODE_DIR="$NODES_DIR/$NODE_NAME"
    choose_port "22222"

    echo -e "\n请选择这个节点的出站方式："
    echo "1. 不使用 SOCKS5，直接从本 VPS 出口连接"
    echo "2. 使用本机 SOCKS5（例如 127.0.0.1:1080）"
    echo "3. 使用远程 SOCKS5"
    while true; do
        read_value "请输入选项 [1/2/3]" "1"
        case "$REPLY" in
            1) USE_SOCKS5="n"; SOCKS_HOST=""; SOCKS_USER=""; SOCKS_PASS=""; break ;;
            2) USE_SOCKS5="y"; SOCKS_HOST="127.0.0.1"; break ;;
            3) USE_SOCKS5="y"; read_value "SOCKS5 IP/域名"; SOCKS_HOST="$REPLY"; [[ -n "$SOCKS_HOST" ]] && break; echo "不能为空。" ;;
            *) echo "输入错误。" ;;
        esac
    done

    if [[ "$USE_SOCKS5" == "y" ]]; then
        read_value "请输入 SOCKS5 端口" "1080"
        SOCKS_PORT="$REPLY"
        ask_yes_no "SOCKS5 是否需要账号密码认证？" "n"
        if [[ "$REPLY" == "y" ]]; then
            read_value "SOCKS5 用户名"; SOCKS_USER="$REPLY"
            read_secret "SOCKS5 密码"; SOCKS_PASS="$REPLY"
        fi

        echo -e "\n请选择代理分流模式："
        echo "1. 仅 TCP 走代理，UDP 直连"
        echo "2. TCP 和 UDP 都尽可能走 SOCKS5"
        read_value "选项" "2"
        [[ "$REPLY" == "2" ]] && PROXY_MODE="all_proxy" || PROXY_MODE="tcp_only"
    else
        PROXY_MODE="direct"
    fi

    save_node_meta
    write_node_config
    echo -e "\n✅ 配置生成：$NODE_DIR/config.json"
    
    ask_yes_no "立即启动这个节点？" "y"
    if [[ "$REPLY" == "y" ]]; then start_node "$NODE_NAME"; fi
    
    server_ip="$(get_server_ip)"
    echo -e "\n🎉 节点创建完成！"
    echo "节点链接 (客户端需允许不安全证书 insecure=1):"
    print_link "$server_ip" "$NODE_NAME"
}

start_node() {
    local name="$1" pid=""
    load_node "$name" || return 1
    if [[ ! -x "$BIN_PATH" ]]; then ensure_common_files; fi
    if node_is_running; then
        echo "ℹ️ 节点 $NODE_NAME 已在运行。"
        return 0
    fi
    if [[ ! -f "$NODE_DIR/config.json" ]]; then
        { read -r AUTH_UUID; read -r AUTH_PASS; } < "$AUTH_FILE"
        write_node_config
    fi
    echo "🚀 启动节点 $NODE_NAME（端口 $NODE_PORT）..."
    nohup "$BIN_PATH" run -c "$NODE_DIR/config.json" > /dev/null 2>&1 </dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$NODE_DIR/node.pid"
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "✅ 节点已启动，PID：$pid"
    else
        echo "❌ 启动失败，请检查配置或端口是否冲突。"
        return 1
    fi
}

stop_node() {
    local name="$1" pid=""
    load_node "$name" || return 1
    if ! node_is_running; then
        echo "ℹ️ 节点 $NODE_NAME 未运行。"
        return 0
    fi
    IFS= read -r pid < "$NODE_DIR/node.pid" || true
    kill "$pid" 2>/dev/null || true
    rm -f "$NODE_DIR/node.pid"
    echo "✅ 节点 $NODE_NAME 已停止。"
}

restart_node() { stop_node "$1" || return 1; start_node "$1"; }

list_nodes() {
    shopt -s nullglob
    local files=("$NODES_DIR"/*/node.conf)
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then echo "暂无节点。"; return 0; fi
    
    printf '\n%-15s %-10s %-10s %-15s\n' '节点名称' '端口' '状态' 'SOCKS5/模式'
    printf '%-15s %-10s %-10s %-15s\n' '---------------' '--------' '----------' '---------------'
    for conf in "${files[@]}"; do
        source "$conf"
        local name="${NODE_NAME:-$(basename "$(dirname "$conf")")}"
        local port="${NODE_PORT:-?}"
        local proxy="直连"
        [[ "${USE_SOCKS5:-n}" == "y" ]] && proxy="${SOCKS_PORT}(${PROXY_MODE})"
        local status="已停止"
        if [[ -f "$(dirname "$conf")/node.pid" ]] && kill -0 "$(cat "$(dirname "$conf")/node.pid" 2>/dev/null)" 2>/dev/null; then status="运行中"; fi
        printf '%-15s %-10s %-10s %-15s\n' "$name" "$port" "$status" "$proxy"
    done
    echo ""
}

ask_node_name() { read_value "请输入节点名称"; REPLY="$REPLY"; }

delete_node() {
    local name="$1" dir="$NODES_DIR/$1"
    load_node "$name" || return 1
    ask_yes_no "确认删除节点 $NODE_NAME 吗？" "n"
    [[ "$REPLY" == "y" ]] || return 0
    stop_node "$name" || true
    rm -rf -- "$dir"
    echo "✅ 节点已删除。"
}

show_logs() {
    load_node "$1" || return 1
    if [[ ! -f "$NODE_DIR/singbox.log" ]]; then echo "暂无日志。"; return 0; fi
    tail -n 100 -f "$NODE_DIR/singbox.log"
}

show_auth() {
    ensure_auth
    echo -e "UUID: $AUTH_UUID\n密码: $AUTH_PASS"
}

menu() {
    while true; do
        echo -e "\n========================================"
        echo "   TUIC (sing-box 核心) 多节点管理"[cite: 7]
        echo "========================================"
        echo "1. 创建新节点"[cite: 7]
        echo "2. 查看所有节点"[cite: 7]
        echo "3. 启动指定节点"[cite: 7]
        echo "4. 停止指定节点"[cite: 7]
        echo "5. 重启指定节点"[cite: 7]
        echo "6. 删除指定节点"[cite: 7]
        echo "7. 查看节点日志"[cite: 7]
        echo "8. 查看公共 UUID 与密码"[cite: 7]
        echo "9. 退出"[cite: 7]
        read -r -p "选项 [1-9]: " choice
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
            *) echo "❌ 错误选项。" ;;
        esac
    done
}

main() {
    ensure_root
    [[ $# -eq 0 ]] && menu || "$@"
}
main "$@"
