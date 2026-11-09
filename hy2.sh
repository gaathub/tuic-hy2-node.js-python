#!/usr/bin/env bash
# ============================================================
# Hysteria2 Multi Node Manager v2.1.0
# 多节点管理 / SOCKS5 / DIRECT / systemd / 在线更新
# 依赖：bash curl openssl systemd
# ============================================================

set -Eeuo pipefail
umask 077

# ======================== 基础配置 ========================

SCRIPT_VERSION="2.1.0"

GITHUB_REPO="gaathub/tuic-hy2-node.js-python"
UPDATE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/refs/heads/main/hy2.sh"

HY2_BASE_DIR="${HY2_BASE_DIR:-/opt/hy2-multi}"
HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.5}"

DEFAULT_SCRIPT_PATH="/usr/local/bin/hy2-multi"
SHORTCUT_PATH="/usr/local/bin/star"

SERVICE_NAME="hy2-multi.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

SNI="${SNI:-www.bing.com}"
ALPN="${ALPN:-h3}"

UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"

BASE_DIR="$HY2_BASE_DIR"
NODES_DIR="$BASE_DIR/nodes"
AUTH_FILE="$BASE_DIR/hy2-uuid.conf"
CERT_FILE="$BASE_DIR/cert.pem"
KEY_FILE="$BASE_DIR/key.pem"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        echo "不支持的 CPU 架构：$ARCH"
        exit 1
        ;;
esac

BIN_PATH="$BASE_DIR/hysteria-linux-${ARCH}"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_PATH=""

if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || true)"
fi

NODE_NAME=""
NODE_DIR=""
NODE_PORT=""
USE_SOCKS5="n"

SOCKS_HOST=""
SOCKS_PORT="1080"
SOCKS_USER=""
SOCKS_PASS=""

# tcp_only：TCP走代理，UDP直连
# all_proxy：TCP/UDP都走代理
PROXY_MODE="tcp_only"

AUTH_UUID=""
REPLY=""

NODE_FILE_LIST=()

# ======================== 基础函数 ========================

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ensure_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "请使用 root 用户运行。"
        exit 1
    fi
}

pause_enter() {
    if [[ -t 0 ]]; then
        read -r -p $'\n按回车键继续...' _ || true
    fi
}

read_value() {
    local prompt="$1"
    local def="${2:-}"
    local value=""

    if [[ -n "$def" ]]; then
        read -r -p "$prompt [$def]: " value
        REPLY="${value:-$def}"
    else
        read -r -p "$prompt: " value
        REPLY="$value"
    fi
}

read_secret() {
    local value=""
    read -r -s -p "$1: " value
    printf '\n'
    REPLY="$value"
}

ask_yes_no() {
    local prompt="$1"
    local def="${2:-n}"
    local value=""
    local hint="y/N"

    [[ "$def" == "y" ]] && hint="Y/n"

    while true; do
        read -r -p "$prompt [$hint]: " value
        value="${value:-$def}"

        case "${value,,}" in
            y|yes)
                REPLY="y"
                return 0
                ;;
            n|no)
                REPLY="n"
                return 0
                ;;
            *)
                echo "请输入 y 或 n。"
                ;;
        esac
    done
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_node_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$ ]]
}

yaml_quote() {
    local v="$1"

    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\r'/}"
    v="${v//$'\n'/\\n}"

    printf '"%s"' "$v"
}

normalize_host_port() {
    local host="$1"
    local port="$2"

    if [[ "$host" == \[*\] ]]; then
        printf '%s:%s' "$host" "$port"
    elif [[ "$host" == *:* ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

# ======================== 依赖管理 ========================

install_missing_dependencies() {
    local missing=()

    has_cmd curl || missing+=(curl)
    has_cmd openssl || missing+=(openssl)

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    echo "正在安装依赖：${missing[*]}"

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
        echo "找不到系统包管理器，请手动安装 curl 和 openssl。"
        return 1
    fi
}

# ======================== UUID 管理 ========================

generate_uuid() {
    local u=""

    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        IFS= read -r u < /proc/sys/kernel/random/uuid || true
    elif has_cmd uuidgen; then
        u="$(uuidgen 2>/dev/null || true)"
    else
        u="$(openssl rand -hex 16)"
        u="${u:0:8}-${u:8:4}-4${u:13:3}-8${u:17:3}-${u:20:12}"
    fi

    u="${u,,}"

    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1

    printf '%s\n' "$u"
}

ensure_uuid() {
    local saved=""

    mkdir -p "$BASE_DIR"

    if [[ -f "$AUTH_FILE" ]]; then
        IFS= read -r saved < "$AUTH_FILE" || true
    fi

    if [[ "$saved" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        AUTH_UUID="${saved,,}"
        chmod 600 "$AUTH_FILE"
        return 0
    fi

    AUTH_UUID="$(generate_uuid)"
    printf '%s\n' "$AUTH_UUID" > "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"

    echo "已生成公共 UUID：$AUTH_UUID"
}

# ======================== Hysteria2 内核 ========================

ensure_binary() {
    local name
    local url
    local tmp

    name="hysteria-linux-${ARCH}"
    BIN_PATH="$BASE_DIR/$name"

    if [[ -x "$BIN_PATH" ]]; then
        return 0
    fi

    mkdir -p "$BASE_DIR"

    url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${name}"

    tmp="${BIN_PATH}.download"

    echo "正在下载 Hysteria2 ${HYSTERIA_VERSION}..."

    if ! curl -fL --retry 3 --connect-timeout 30 \
        -o "$tmp" "$url"; then
        rm -f "$tmp"
        echo "Hysteria2 内核下载失败。"
        return 1
    fi

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "下载文件为空。"
        return 1
    fi

    chmod 755 "$tmp"
    mv -f "$tmp" "$BIN_PATH"

    echo "Hysteria2 内核安装完成。"
}

# ======================== TLS 证书 ========================

ensure_certificate() {
    if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
        chmod 600 "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        return 0
    fi

    echo "正在生成共享 TLS 自签名证书..."

    openssl req -x509 -nodes -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=${SNI}" >/dev/null 2>&1

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"

    echo "证书生成完成。"
}

ensure_common_files() {
    ensure_root
    install_missing_dependencies

    mkdir -p "$NODES_DIR"

    ensure_uuid
    ensure_binary
    ensure_certificate
}

# ======================== SOCKS5 检测 ========================

check_socks_listener() {
    local host="$1"
    local port="$2"
    local addr

    addr="$(normalize_host_port "$host" "$port")"

    echo
    echo "正在检测 SOCKS5 监听端口..."
    echo "地址：$addr"

    if ! has_cmd timeout; then
        echo "系统缺少 timeout 命令，无法执行快速端口检测。"
        return 1
    fi

    if timeout 4 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null; then
        echo "TCP 端口连接成功。"
        return 0
    fi

    echo "TCP 端口连接失败。"
    echo "请检查："
    echo "1. SOCKS5 服务是否已经启动。"
    echo "2. 监听地址和端口是否正确。"
    echo "3. 如果是本机代理，确认 VPS 上确实有 SOCKS5 服务。"

    return 1
}

test_socks5() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local addr
    local proxy
    local code=""

    if ! check_socks_listener "$host" "$port"; then
        return 1
    fi

    addr="$(normalize_host_port "$host" "$port")"
    proxy="socks5h://${addr}"

    echo
    echo "正在测试 SOCKS5 实际网络转发..."
    echo "测试目标：www.gstatic.com"

    local args=(
        -fsS
        --connect-timeout 8
        --max-time 15
        --proxy "$proxy"
        -o /dev/null
        -w '%{http_code}'
    )

    if [[ -n "$user" && -n "$pass" ]]; then
        args+=(--proxy-user "${user}:${pass}")
    fi

    if code="$(curl "${args[@]}" https://www.gstatic.com/generate_204 2>/dev/null)"; then
        echo "SOCKS5 转发测试成功。HTTP 状态：$code"
        return 0
    fi

    echo "SOCKS5 TCP 转发测试失败。"
    echo "可能原因："
    echo "1. 代理服务器无法访问公网。"
    echo "2. SOCKS5 用户名或密码错误。"
    echo "3. 代理服务器 DNS 解析失败。"
    echo "4. 代理出口被目标网站限制。"

    return 1
}

# ======================== 节点配置管理 ========================

save_node_meta() {
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
    } > "$NODE_DIR/node.conf"

    chmod 600 "$NODE_DIR/node.conf"
}

load_node() {
    local name="$1"

    if ! valid_node_name "$name"; then
        echo "节点名称不合法。"
        return 1
    fi

    NODE_DIR="$NODES_DIR/$name"

    if [[ ! -f "$NODE_DIR/node.conf" ]]; then
        echo "找不到节点：$name"
        return 1
    fi

    # 配置文件由本脚本生成，权限仅允许 root 访问。
    source "$NODE_DIR/node.conf"
}

write_node_config() {
    local addr=""

    mkdir -p "$NODE_DIR"

    {
        printf 'listen: %s\n' "$(yaml_quote ":${NODE_PORT}")"

        printf 'tls:\n'
        printf '  cert: %s\n' "$(yaml_quote "$CERT_FILE")"
        printf '  key: %s\n' "$(yaml_quote "$KEY_FILE")"

        printf '  alpn:\n'
        printf '    - %s\n' "$(yaml_quote "$ALPN")"

        printf '\n'

        printf 'auth:\n'
        printf '  type: "password"\n'
        printf '  password: %s\n' "$(yaml_quote "$AUTH_UUID")"

        printf '\n'

        printf 'bandwidth:\n'
        printf '  up: %s\n' "$(yaml_quote "$UP_BANDWIDTH")"
        printf '  down: %s\n' "$(yaml_quote "$DOWN_BANDWIDTH")"

        cat <<'YAML'

quic:
  max_idle_timeout: "10s"
  max_concurrent_streams: 4
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144

YAML

        if [[ "$USE_SOCKS5" == "y" ]]; then

            addr="$(normalize_host_port "$SOCKS_HOST" "$SOCKS_PORT")"

            cat <<YAML
outbounds:
  - name: socks_proxy
    type: socks5
    socks5:
      addr: $(yaml_quote "$addr")
YAML

            if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
                printf '      username: %s\n' "$(yaml_quote "$SOCKS_USER")"
                printf '      password: %s\n' "$(yaml_quote "$SOCKS_PASS")"
            fi

            if [[ "$PROXY_MODE" == "all_proxy" ]]; then
                cat <<'YAML'

acl:
  inline:
    - socks_proxy(all)
YAML
            else
                cat <<'YAML'

acl:
  inline:
    - socks_proxy(all, tcp/*)
    - direct(all)
YAML
            fi

        else

            cat <<'YAML'

acl:
  inline:
    - direct(all)
YAML

        fi

    } > "$NODE_DIR/server.yaml"

    chmod 600 "$NODE_DIR/server.yaml"
}

# ======================== 节点文件列表 ========================

collect_node_files() {
    NODE_FILE_LIST=()

    [[ -d "$NODES_DIR" ]] || return 0

    local -a files=()

    shopt -s nullglob
    files=("$NODES_DIR"/*/node.conf)
    shopt -u nullglob

    if ((${#files[@]})); then
        mapfile -t NODE_FILE_LIST < <(
            printf '%s\n' "${files[@]}" | LC_ALL=C sort
        )
    fi
}

# ======================== 端口管理 ========================

port_already_managed() {
    local wanted="$1"
    local f
    local p

    shopt -s nullglob

    for f in "$NODES_DIR"/*/node.conf; do
        p="$(
            (
                unset NODE_PORT
                source "$f"
                printf '%s' "${NODE_PORT:-}"
            )
        )"

        if [[ "$p" == "$wanted" ]]; then
            shopt -u nullglob
            return 0
        fi
    done

    shopt -u nullglob
    return 1
}

port_in_use() {
    local p="$1"

    if has_cmd ss; then
        ss -H -lntu "sport = :$p" 2>/dev/null | grep -q .
    elif has_cmd lsof; then
        lsof -nP -iTCP:"$p" -iUDP:"$p" >/dev/null 2>&1
    else
        return 1
    fi
}

choose_port() {
    local v
    local def="${1:-22222}"

    while true; do
        read_value "请输入 Hysteria2 监听端口（UDP）" "$def"
        v="$REPLY"

        if ! valid_port "$v"; then
            echo "端口必须为 1-65535。"
        elif port_already_managed "$v"; then
            echo "该端口已经被本脚本使用。"
        elif port_in_use "$v"; then
            echo "该端口已被其他系统程序占用。"
        else
            NODE_PORT="$v"
            return 0
        fi
    done
}

# ======================== 进程管理 ========================

node_is_running() {
    local pid=""
    local cmd=""

    [[ -f "$NODE_DIR/hysteria.pid" ]] || return 1

    IFS= read -r pid < "$NODE_DIR/hysteria.pid" || true

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill -0 "$pid" 2>/dev/null || return 1

    [[ -r "/proc/$pid/cmdline" ]] || return 1

    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"

    [[ "$cmd" == *"$NODE_DIR/server.yaml"* &&
       "$cmd" == *hysteria* ]]
}

start_node_internal() {
    local name="$1"
    local pid=""

    load_node "$name" || return 1

    ensure_binary

    if node_is_running; then
        echo "节点 $name 已经运行。"
        return 0
    fi

    rm -f "$NODE_DIR/hysteria.pid"

    if [[ ! -s "$AUTH_FILE" ]]; then
        echo "公共 UUID 不存在。"
        return 1
    fi

    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        ensure_certificate
    fi

    if [[ ! -f "$NODE_DIR/server.yaml" ]]; then
        IFS= read -r AUTH_UUID < "$AUTH_FILE"
        write_node_config
    fi

    echo "正在启动节点 $name..."

    nohup "$BIN_PATH" server -c "$NODE_DIR/server.yaml" \
        >> "$NODE_DIR/hysteria.log" 2>&1 </dev/null &

    pid=$!

    printf '%s\n' "$pid" > "$NODE_DIR/hysteria.pid"

    sleep 2

    if node_is_running; then
        echo "节点 $name 启动成功，PID：$pid"
        return 0
    fi

    rm -f "$NODE_DIR/hysteria.pid"

    echo "节点启动失败，最近日志："
    tail -n 50 "$NODE_DIR/hysteria.log" 2>/dev/null || true

    return 1
}

stop_node_internal() {
    local name="$1"
    local remove_autostart="${2:-y}"

    local pid=""
    local cmd=""
    local i

    load_node "$name" || return 1

    if [[ "$remove_autostart" == "y" ]]; then
        rm -f "$NODE_DIR/autostart"
    fi

    if ! node_is_running; then
        rm -f "$NODE_DIR/hysteria.pid"
        echo "节点 $name 当前未运行。"
        return 0
    fi

    IFS= read -r pid < "$NODE_DIR/hysteria.pid" || true

    echo "正在停止节点 $name..."

    kill "$pid" 2>/dev/null || true

    for ((i=0; i<10; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"

        if [[ "$cmd" == *"$NODE_DIR/server.yaml"* &&
              "$cmd" == *hysteria* ]]; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$NODE_DIR/hysteria.pid"

    echo "节点 $name 已停止。"
}

start_node() {
    local name="$1"

    load_node "$name" || return 1

    touch "$NODE_DIR/autostart"

    if ! start_node_internal "$name"; then
        rm -f "$NODE_DIR/autostart"
        return 1
    fi

    enable_autostart
}

stop_node() {
    stop_node_internal "$1" y
}

restart_node() {
    stop_node "$1" || true
    start_node "$1"
}

# ======================== 开机自动启动 ========================

boot_start_all() {
    ensure_root
    ensure_binary

    collect_node_files

    if ((${#NODE_FILE_LIST[@]} == 0)); then
        return 0
    fi

    echo "正在恢复开机自动启动节点..."

    local f
    local name

    for f in "${NODE_FILE_LIST[@]}"; do
        name="$(basename "$(dirname "$f")")"

        if [[ -f "$(dirname "$f")/autostart" ]]; then
            start_node_internal "$name" || {
                echo "节点 $name 恢复失败，请检查日志。"
            }
        fi
    done
}

boot_stop_all() {
    ensure_root

    collect_node_files

    local f
    local name

    for f in "${NODE_FILE_LIST[@]}"; do
        name="$(basename "$(dirname "$f")")"

        if [[ -f "$(dirname "$f")/autostart" ]]; then
            stop_node_internal "$name" n || true
        fi
    done
}

enable_autostart() {
    ensure_root

    if ! has_cmd systemctl; then
        echo "当前系统没有 systemd，无法设置自动启动。"
        return 1
    fi

    mkdir -p "$(dirname "$DEFAULT_SCRIPT_PATH")"

    if [[ ! -f "$DEFAULT_SCRIPT_PATH" ]]; then
        echo "管理脚本尚未持久化，正在安装..."
        install_persistent_script
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria2 Multi Node Manager
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DEFAULT_SCRIPT_PATH boot-start
ExecStop=$DEFAULT_SCRIPT_PATH boot-stop
TimeoutStartSec=180
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl start "$SERVICE_NAME"
    fi

    echo "开机自动启动已配置。"
    echo "服务名称：$SERVICE_NAME"
}

# ======================== 公网 IP ========================

get_server_ip() {
    local ip=""

    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    fi

    [[ -n "$ip" ]] || return 1

    printf '%s' "$ip"
}

print_link() {
    local ip="$1"
    local url_ip="$1"

    [[ "$url_ip" == *:* && "$url_ip" != \[*\] ]] && url_ip="[$url_ip]"

    printf 'hysteria2://%s@%s:%s?sni=%s&alpn=%s&insecure=1#%s\n' \
        "$AUTH_UUID" "$url_ip" "$NODE_PORT" "$SNI" "$ALPN" "$NODE_NAME"
}

# ======================== 节点列表 ========================

list_nodes() {
    collect_node_files

    if ((${#NODE_FILE_LIST[@]} == 0)); then
        echo "目前没有节点。"
        return 0
    fi

    local i=0
    local f
    local name
    local status
    local proxy
    local boot
    local ip=""
    local link_uuid=""

    if [[ -s "$AUTH_FILE" ]]; then
        IFS= read -r link_uuid < "$AUTH_FILE" || true
    fi

    AUTH_UUID="$link_uuid"

    echo
    echo "========== Hysteria2 节点列表 =========="
    echo "节点总数：${#NODE_FILE_LIST[@]}"

    ip="$(get_server_ip 2>/dev/null || true)"

    [[ -n "$ip" ]] && echo "服务器公网 IP：$ip"

    for f in "${NODE_FILE_LIST[@]}"; do
        i=$((i + 1))

        NODE_NAME=""
        NODE_PORT=""
        USE_SOCKS5="n"
        SOCKS_HOST=""
        SOCKS_PORT="1080"
        PROXY_MODE="tcp_only"

        source "$f"

        name="${NODE_NAME:-$(basename "$(dirname "$f")")}"
        NODE_DIR="$(dirname "$f")"

        if node_is_running; then
            status="运行中"
        else
            status="已停止"
        fi

        if [[ "$USE_SOCKS5" == "y" ]]; then
            proxy="SOCKS5：$(normalize_host_port "$SOCKS_HOST" "$SOCKS_PORT")"
        else
            proxy="DIRECT"
        fi

        if [[ -f "$NODE_DIR/autostart" ]]; then
            boot="是"
        else
            boot="否"
        fi

        printf '\n┌─ [%d] %s\n' "$i" "$name"
        printf '│  UDP 端口：%s\n' "$NODE_PORT"
        printf '│  状态：%s\n' "$status"
        printf '│  出口：%s\n' "$proxy"
        printf '│  自动启动：%s\n' "$boot"

        if [[ "$USE_SOCKS5" == "y" ]]; then
            if [[ "$PROXY_MODE" == "all_proxy" ]]; then
                printf '│  模式：TCP/UDP SOCKS5\n'
            else
                printf '│  模式：TCP SOCKS5 + UDP DIRECT\n'
            fi
        fi

        if [[ -n "$ip" && -n "$AUTH_UUID" ]]; then
            printf '│  分享链接：\n'
            print_link "$ip" | sed 's/^/│  /'
        else
            printf '│  分享链接：公网 IP 或 UUID 获取失败\n'
        fi

        printf '└────────────────────────────────────\n'
    done
}

# ======================== 创建节点 ========================

create_node() {
    ensure_common_files

    local name
    local ip
    local mode

    echo
    echo "========== 创建 Hysteria2 节点 =========="

    while true; do
        read_value "节点名称" "A"
        name="$REPLY"

        if ! valid_node_name "$name"; then
            echo "节点名称不合法。"
        elif [[ -e "$NODES_DIR/$name" ]]; then
            echo "该节点已经存在。"
        else
            break
        fi
    done

    NODE_NAME="$name"
    NODE_DIR="$NODES_DIR/$name"

    choose_port 22222

    echo
    echo "出口方式："
    echo "1. DIRECT（服务器直连）"
    echo "2. 本机 SOCKS5（VPS 本地代理）"
    echo "3. 远程 SOCKS5"

    while true; do
        read_value "请选择出口方式" 1

        case "$REPLY" in
            1)
                USE_SOCKS5="n"
                SOCKS_HOST=""
                SOCKS_USER=""
                SOCKS_PASS=""
                break
                ;;

            2)
                USE_SOCKS5="y"
                read_value "本机 SOCKS5 监听地址" "127.0.0.1"
                SOCKS_HOST="$REPLY"
                break
                ;;

            3)
                USE_SOCKS5="y"
                read_value "远程 SOCKS5 地址"
                SOCKS_HOST="$REPLY"

                if [[ -n "$SOCKS_HOST" ]]; then
                    break
                fi

                echo "地址不能为空。"
                ;;

            *)
                echo "请输入 1、2 或 3。"
                ;;
        esac
    done

    if [[ "$USE_SOCKS5" == "y" ]]; then

        read_value "SOCKS5 端口" 1080

        while ! valid_port "$REPLY"; do
            echo "端口无效。"
            read_value "SOCKS5 端口" 1080
        done

        SOCKS_PORT="$REPLY"

        echo
        ask_yes_no "是否需要用户名密码认证" n

        if [[ "$REPLY" == "y" ]]; then
            read_value "SOCKS5 用户名"
            SOCKS_USER="$REPLY"

            read_secret "SOCKS5 密码"
            SOCKS_PASS="$REPLY"

            if [[ -z "$SOCKS_USER" || -z "$SOCKS_PASS" ]]; then
                echo "用户名和密码必须同时填写。"
                return 1
            fi
        else
            SOCKS_USER=""
            SOCKS_PASS=""
        fi

        echo
        echo "代理模式："
        echo "1. TCP 走 SOCKS5，UDP 直连（推荐）"
        echo "2. TCP/UDP 全部走 SOCKS5"

        read_value "请选择代理模式" 1

        while [[ "$REPLY" != "1" && "$REPLY" != "2" ]]; do
            read_value "请输入 1 或 2" 1
        done

        if [[ "$REPLY" == "2" ]]; then
            PROXY_MODE="all_proxy"
        else
            PROXY_MODE="tcp_only"
        fi

        echo
        echo "正在验证 SOCKS5..."

        if ! test_socks5 "$SOCKS_HOST" "$SOCKS_PORT" "$SOCKS_USER" "$SOCKS_PASS"; then
            echo
            ask_yes_no "代理测试失败，仍然继续创建节点吗" n

            if [[ "$REPLY" != "y" ]]; then
                echo "已取消创建。"
                return 1
            fi
        fi

    else
        SOCKS_PORT="1080"
        SOCKS_USER=""
        SOCKS_PASS=""
        PROXY_MODE="tcp_only"
    fi

    save_node_meta

    IFS= read -r AUTH_UUID < "$AUTH_FILE"

    write_node_config

    echo
    echo "节点配置生成成功。"
    echo "配置文件：$NODE_DIR/server.yaml"

    ask_yes_no "立即启动节点" y

    if [[ "$REPLY" == "y" ]]; then
        start_node "$NODE_NAME"
    fi

    ip="$(get_server_ip 2>/dev/null || true)"

    echo

    if [[ -n "$ip" ]]; then
        echo "节点分享链接："
        print_link "$ip"
    else
        echo "无法获取公网 IP，可稍后通过菜单 2 查看分享链接。"
    fi

    echo
    echo "请确保云厂商防火墙和系统防火墙放行 UDP $NODE_PORT。"
}

# ======================== 删除节点 ========================

delete_node() {
    collect_node_files

    if ((${#NODE_FILE_LIST[@]} == 0)); then
        echo "目前没有节点。"
        return 0
    fi

    echo
    echo "========== 选择删除节点 =========="

    local i=0
    local f
    local name
    local choice
    local index
    local dir

    for f in "${NODE_FILE_LIST[@]}"; do
        i=$((i + 1))

        NODE_NAME=""
        NODE_PORT=""

        source "$f"

        name="${NODE_NAME:-$(basename "$(dirname "$f")")}"

        printf '[%d] %-20s UDP:%s\n' "$i" "$name" "${NODE_PORT:-?}"
    done

    echo
    echo "输入编号删除，输入 0 取消。"

    read -r -p "请选择：" choice

    if [[ "$choice" == "0" ]]; then
        echo "已取消。"
        return 0
    fi

    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
        echo "输入无效。"
        return 1
    fi

    index=$((10#$choice - 1))

    if ((index < 0 || index >= ${#NODE_FILE_LIST[@]})); then
        echo "编号超出范围。"
        return 1
    fi

    dir="$(dirname "${NODE_FILE_LIST[$index]}")"
    name="$(basename "$dir")"

    load_node "$name" || return 1

    echo
    echo "即将删除：$name"
    echo "监听端口：$NODE_PORT"

    ask_yes_no "确认删除" n

    if [[ "$REPLY" != "y" ]]; then
        echo "已取消。"
        return 0
    fi

    stop_node_internal "$name" y || true

    rm -rf -- "$dir"

    echo "节点 $name 已删除。"
}

# ======================== 日志管理 ========================

show_logs() {
    load_node "$1" || return 1

    if [[ ! -f "$NODE_DIR/hysteria.log" ]]; then
        echo "该节点暂无日志。"
        return 0
    fi

    echo "按 Ctrl+C 返回菜单。"

    tail -n 100 -f "$NODE_DIR/hysteria.log"
}

# ======================== UUID ========================

show_uuid() {
    ensure_uuid

    echo
    echo "公共 UUID：$AUTH_UUID"
    echo "文件位置：$AUTH_FILE"
}

# ======================== 代理诊断 ========================

diagnose_node() {
    local name="$1"

    load_node "$name" || return 1

    echo
    echo "========== 节点诊断 =========="
    echo "节点：$NODE_NAME"
    echo "UDP 端口：$NODE_PORT"

    if node_is_running; then
        echo "节点进程：正常运行"
    else
        echo "节点进程：未运行"
    fi

    if [[ "$USE_SOCKS5" == "y" ]]; then
        echo
        echo "出口：SOCKS5"
        echo "代理地址：$(normalize_host_port "$SOCKS_HOST" "$SOCKS_PORT")"

        if [[ "$PROXY_MODE" == "all_proxy" ]]; then
            echo "代理模式：TCP/UDP"
        else
            echo "代理模式：TCP SOCKS5 + UDP DIRECT"
        fi

        test_socks5 "$SOCKS_HOST" "$SOCKS_PORT" "$SOCKS_USER" "$SOCKS_PASS" || true
    else
        echo "出口：DIRECT"
    fi

    echo
    echo "最近日志："

    tail -n 30 "$NODE_DIR/hysteria.log" 2>/dev/null || true
}

diagnose_all() {
    collect_node_files

    if ((${#NODE_FILE_LIST[@]} == 0)); then
        echo "没有可诊断的节点。"
        return 0
    fi

    local f
    local name

    for f in "${NODE_FILE_LIST[@]}"; do
        name="$(basename "$(dirname "$f")")"
        diagnose_node "$name"
    done
}

# ======================== 持久化脚本与快捷命令 ========================

install_persistent_script() {
    local tmp
    local source_file=""

    mkdir -p "$(dirname "$DEFAULT_SCRIPT_PATH")"

    if [[ -f "$DEFAULT_SCRIPT_PATH" ]]; then
        chmod 700 "$DEFAULT_SCRIPT_PATH"
        ln -sfn "$DEFAULT_SCRIPT_PATH" "$SHORTCUT_PATH"
        return 0
    fi

    tmp="$(mktemp "${DEFAULT_SCRIPT_PATH}.XXXXXX")"

    if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
        source_file="$SCRIPT_SOURCE"
    elif [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
        source_file="$SCRIPT_PATH"
    fi

    if [[ -n "$source_file" ]]; then
        if ! cp "$source_file" "$tmp"; then
            rm -f "$tmp"
            echo "复制当前脚本失败。"
            return 1
        fi
    else
        echo "正在从 GitHub 获取脚本..."

        if ! curl -fL --retry 2 --connect-timeout 20 \
            -o "$tmp" "$UPDATE_URL"; then
            rm -f "$tmp"
            echo "下载失败。"
            return 1
        fi
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        echo "脚本语法检查失败，拒绝安装。"
        return 1
    fi

    chmod 700 "$tmp"
    mv -f "$tmp" "$DEFAULT_SCRIPT_PATH"

    ln -sfn "$DEFAULT_SCRIPT_PATH" "$SHORTCUT_PATH"

    echo "管理脚本安装成功。"
    echo "管理路径：$DEFAULT_SCRIPT_PATH"
    echo "快捷命令：star"
}

install_shortcut() {
    install_persistent_script
}

# ======================== 在线更新 ========================

update_script() {
    ensure_root

    local target="$DEFAULT_SCRIPT_PATH"
    local tmp
    local backup
    local downloaded_version=""
    local current_version="$SCRIPT_VERSION"

    echo
    echo "========== 在线更新 =========="
    echo "当前版本：$current_version"
    echo "更新来源：$UPDATE_URL"

    tmp="$(mktemp "${target}.update.XXXXXX")"

    echo
    echo "正在下载最新脚本..."

    if ! curl -fL --retry 3 --connect-timeout 25 \
        -o "$tmp" "$UPDATE_URL"; then
        rm -f "$tmp"
        echo "下载失败，当前版本没有改变。"
        return 1
    fi

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "下载内容为空。"
        return 1
    fi

    echo "正在检查脚本语法..."

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        echo "新版本语法检查失败，拒绝更新。"
        return 1
    fi

    downloaded_version="$(
        sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n 1
    )"

    if [[ ! "$downloaded_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        rm -f "$tmp"
        echo "无法识别版本号，拒绝更新。"
        return 1
    fi

    echo "远程版本：$downloaded_version"

    if [[ -f "$target" ]]; then
        backup="${target}.bak.$(date +%Y%m%d%H%M%S)"

        if ! cp -a "$target" "$backup"; then
            rm -f "$tmp"
            echo "备份失败，取消更新。"
            return 1
        fi

        echo "旧版本备份：$backup"
    fi

    chmod 700 "$tmp"

    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        echo "替换失败。"
        return 1
    fi

    if ! bash -n "$target"; then
        echo "更新后的文件校验失败，正在回滚。"

        if [[ -f "$backup" ]]; then
            cp -af "$backup" "$target"
        fi

        return 1
    fi

    ln -sfn "$target" "$SHORTCUT_PATH"

    echo
    echo "========================================"
    echo "             更新成功"
    echo "========================================"
    echo "原版本：$current_version"
    echo "新版本：$downloaded_version"
    echo "快捷命令：star"
    echo
    echo "请退出当前菜单，重新输入 star。"
}

# ======================== 服务状态 ========================

service_status() {
    echo
    echo "========== systemd 服务状态 =========="

    if ! has_cmd systemctl; then
        echo "当前系统没有 systemd。"
        return 1
    fi

    systemctl status "$SERVICE_NAME" --no-pager || true
}

# ======================== 彻底卸载 ========================

uninstall_all() {
    ensure_root

    echo
    echo "警告：此操作将删除："
    echo "1. 所有 Hysteria2 节点"
    echo "2. UUID 和证书"
    echo "3. Hysteria2 内核"
    echo "4. 管理脚本"
    echo "5. systemd 服务"

    echo
    echo "数据目录：$BASE_DIR"

    ask_yes_no "确定彻底卸载" n

    if [[ "$REPLY" != "y" ]]; then
        echo "已取消。"
        return 0
    fi

    if has_cmd systemctl; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    collect_node_files

    local f
    local name

    for f in "${NODE_FILE_LIST[@]}"; do
        name="$(basename "$(dirname "$f")")"
        stop_node_internal "$name" y || true
    done

    if [[ "$BASE_DIR" == /* &&
          "$BASE_DIR" != "/" &&
          "$BASE_DIR" != "/opt" &&
          "$BASE_DIR" != "/root" ]]; then
        rm -rf -- "$BASE_DIR"
    else
        echo "安全检查阻止删除异常目录：$BASE_DIR"
        return 1
    fi

    rm -f "$SHORTCUT_PATH"
    rm -f "$DEFAULT_SCRIPT_PATH"

    echo
    echo "Hysteria2 管理程序已卸载。"
}

# ======================== 帮助信息 ========================

print_help() {
    cat <<EOF
Hysteria2 多节点管理 v${SCRIPT_VERSION}

用法：

  star                       打开管理菜单
  hy2-multi create           创建节点
  hy2-multi list             查看节点
  hy2-multi start <名称>     启动节点
  hy2-multi stop <名称>      停止节点
  hy2-multi restart <名称>   重启节点
  hy2-multi logs <名称>      查看日志
  hy2-multi diagnose <名称>  诊断节点
  hy2-multi uuid             查看 UUID
  hy2-multi update           在线更新
  hy2-multi uninstall        彻底卸载

systemd：

  hy2-multi boot-start       开机恢复节点
  hy2-multi boot-stop        停止节点

数据目录：

  $BASE_DIR

更新地址：

  $UPDATE_URL
EOF
}

# ======================== 主菜单 ========================

menu() {
    local choice

    while true; do
        echo
        echo "=================================================="
        echo "       Hysteria2 多节点管理 v${SCRIPT_VERSION}"
        echo "=================================================="
        echo
        echo "1.  创建新节点"
        echo "2.  查看所有节点及分享链接"
        echo "3.  启动指定节点"
        echo "4.  停止指定节点"
        echo "5.  重启指定节点"
        echo "6.  删除节点"
        echo "7.  查看节点日志"
        echo "8.  查看公共 UUID"
        echo "9.  在线更新脚本"
        echo "10. SOCKS5 / 节点故障诊断"
        echo "11. 查看开机启动服务"
        echo "12. 彻底卸载"
        echo "0.  退出"
        echo
        echo "快捷命令：star"
        echo "=================================================="

        read -r -p "请选择 [0-12]：" choice

        case "$choice" in
            1)
                create_node
                pause_enter
                ;;

            2)
                list_nodes
                pause_enter
                ;;

            3)
                read_value "请输入节点名称"
                start_node "$REPLY"
                pause_enter
                ;;

            4)
                read_value "请输入节点名称"
                stop_node "$REPLY"
                pause_enter
                ;;

            5)
                read_value "请输入节点名称"
                restart_node "$REPLY"
                pause_enter
                ;;

            6)
                delete_node
                pause_enter
                ;;

            7)
                read_value "请输入节点名称"
                show_logs "$REPLY"
                pause_enter
                ;;

            8)
                show_uuid
                pause_enter
                ;;

            9)
                update_script
                pause_enter
                ;;

            10)
                diagnose_all
                pause_enter
                ;;

            11)
                service_status
                pause_enter
                ;;

            12)
                uninstall_all
                ;;

            0|q|Q)
                exit 0
                ;;

            *)
                echo "请输入 0-12。"
                ;;
        esac
    done
}

# ======================== 程序入口 ========================

main() {
    ensure_root

    local cmd="${1:-menu}"

    case "$cmd" in

        menu|star)
            install_shortcut
            menu
            ;;

        create)
            create_node
            ;;

        list)
            list_nodes
            ;;

        start)
            [[ $# -ge 2 ]] || {
                echo "用法：hy2-multi start <节点名称>"
                exit 2
            }
            start_node "$2"
            ;;

        stop)
            [[ $# -ge 2 ]] || {
                echo "用法：hy2-multi stop <节点名称>"
                exit 2
            }
            stop_node "$2"
            ;;

        restart)
            [[ $# -ge 2 ]] || {
                echo "用法：hy2-multi restart <节点名称>"
                exit 2
            }
            restart_node "$2"
            ;;

        delete|del|rm)
            delete_node
            ;;

        logs)
            [[ $# -ge 2 ]] || {
                echo "用法：hy2-multi logs <节点名称>"
                exit 2
            }
            show_logs "$2"
            ;;

        diagnose)
            [[ $# -ge 2 ]] || {
                echo "用法：hy2-multi diagnose <节点名称>"
                exit 2
            }
            diagnose_node "$2"
            ;;

        uuid)
            show_uuid
            ;;

        update)
            update_script
            ;;

        uninstall)
            uninstall_all
            ;;

        boot-start)
            boot_start_all
            ;;

        boot-stop)
            boot_stop_all
            ;;

        help|-h|--help)
            print_help
            ;;

        *)
            echo "未知命令：$cmd"
            print_help
            exit 2
            ;;
    esac
}

main "$@"
