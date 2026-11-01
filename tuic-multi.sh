#!/usr/bin/env bash

# ==========================================================
# TUIC Multi-Node Manager
# 基于 sing-box
# 支持多节点、SOCKS5、TCP/UDP、systemd、卸载
# ==========================================================

set -Eeuo pipefail

BASE="/opt/tuic"
NODE_DIR="$BASE/nodes"
CERT_DIR="$BASE/cert"
DATA_DIR="$BASE/data"
LOG_DIR="$BASE/logs"
GLOBAL="$DATA_DIR/global.env"

BIN="/usr/bin/sing-box"
SERVICE_PREFIX="tuic-node-"

# ==========================================================
# 基础函数
# ==========================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[信息]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[警告]${NC} $*"
}

error() {
    echo -e "${RED}[错误]${NC} $*"
}

pause() {
    read -rp "按回车键继续..."
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "请使用 root 用户运行！"
        exit 1
    fi
}

check_dependencies() {
    for cmd in curl jq openssl systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "缺少依赖：$cmd"
            return 1
        fi
    done
}

# ==========================================================
# 初始化目录
# ==========================================================

init_dirs() {
    mkdir -p \
        "$NODE_DIR" \
        "$CERT_DIR" \
        "$DATA_DIR" \
        "$LOG_DIR"
}

# ==========================================================
# 安装 sing-box
# ==========================================================

install_singbox() {

    if [[ -x "$BIN" ]]; then
        info "检测到 sing-box 已安装"
        "$BIN" version
        return
    fi

    info "正在安装 sing-box..."

    local arch
    arch="$(uname -m)"

    case "$arch" in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            error "暂不支持该 CPU 架构：$arch"
            return 1
            ;;
    esac

    local api
    api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

    local url

    url="$(
        curl -fsSL "$api" |
        jq -r --arg arch "$arch" '
        [
            .assets[].browser_download_url
            | select(test("_linux_" + $arch + "\\.deb$"))
        ][0] // empty
        '
    )"

    if [[ -z "$url" ]]; then
        error "无法获取 sing-box 安装包"
        return 1
    fi

    local tmp="/tmp/sing-box.deb"

    curl -fL "$url" -o "$tmp"

    apt-get update
    apt-get install -y "$tmp"

    rm -f "$tmp"

    if [[ ! -x "$BIN" ]]; then
        error "sing-box 安装失败"
        return 1
    fi

    info "sing-box 安装完成"
}

# ==========================================================
# 初始化全局 UUID 和密码
# ==========================================================

init_global() {

    if [[ -f "$GLOBAL" ]]; then
        source "$GLOBAL"
        return
    fi

    UUID="$(cat /proc/sys/kernel/random/uuid)"

    PASSWORD="$(openssl rand -hex 16)"

    cat > "$GLOBAL" <<EOF
UUID='$UUID'
PASSWORD='$PASSWORD'
EOF

    chmod 600 "$GLOBAL"

    info "已生成全局 UUID 和密码"
}

# ==========================================================
# 获取服务器公网 IP
# ==========================================================

get_public_ip() {

    local ip

    ip="$(curl -4 -fsSL --max-time 8 https://api.ipify.org || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -6 -fsSL --max-time 8 https://api64.ipify.org || true)"
    fi

    if [[ -z "$ip" ]]; then
        read -rp "请输入服务器公网 IP 或域名：" ip
    fi

    echo "$ip"
}

# ==========================================================
# 生成 TLS 证书
# ==========================================================

create_cert() {

    if [[ -f "$CERT_DIR/server.crt" &&
          -f "$CERT_DIR/server.key" ]]; then
        return
    fi

    local sni

    read -rp "请输入 TLS SNI（默认 www.bing.com）：" sni

    sni="${sni:-www.bing.com}"

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -days 3650 \
        -subj "/CN=$sni" \
        -addext "subjectAltName=DNS:$sni"

    chmod 600 "$CERT_DIR/server.key"

    echo "$sni" > "$DATA_DIR/sni"

    info "TLS 证书生成成功"
}

# ==========================================================
# 节点名称处理
# ==========================================================

valid_name() {

    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# ==========================================================
# 生成节点配置
# ==========================================================

generate_config() {

    local name="$1"
    local port="$2"
    local mode="$3"
    local host="${4:-}"
    local socks_port="${5:-}"
    local username="${6:-}"
    local password="${7:-}"

    local config="$NODE_DIR/$name/config.json"

    local outbound

    if [[ "$mode" == "socks" ]]; then

        if [[ -n "$username" ]]; then

            outbound="$(
                jq -n \
                --arg host "$host" \
                --argjson port "$socks_port" \
                --arg user "$username" \
                --arg pass "$password" '
                {
                    type: "socks",
                    tag: "socks-out",
                    server: $host,
                    server_port: $port,
                    version: "5",
                    username: $user,
                    password: $pass
                }'
            )"

        else

            outbound="$(
                jq -n \
                --arg host "$host" \
                --argjson port "$socks_port" '
                {
                    type: "socks",
                    tag: "socks-out",
                    server: $host,
                    server_port: $port,
                    version: "5"
                }'
            )"

        fi

    else

        outbound='{"type":"direct","tag":"direct-out"}'

    fi

    local target

    if [[ "$mode" == "socks" ]]; then
        target="socks-out"
    else
        target="direct-out"
    fi

    jq -n \
        --arg uuid "$UUID" \
        --arg pass "$PASSWORD" \
        --argjson port "$port" \
        --arg target "$target" \
        --argjson outbound "$outbound" \
        '
        {
            log: {
                level: "info",
                timestamp: true
            },

            inbounds: [
                {
                    type: "tuic",
                    tag: "tuic-in",
                    listen: "::",
                    listen_port: $port,

                    users: [
                        {
                            name: "default",
                            uuid: $uuid,
                            password: $pass
                        }
                    ],

                    congestion_control: "bbr",
                    auth_timeout: "3s",
                    zero_rtt_handshake: false,
                    heartbeat: "10s",

                    tls: {
                        enabled: true,
                        certificate_path: "/opt/tuic/cert/server.crt",
                        key_path: "/opt/tuic/cert/server.key"
                    }
                }
            ],

            outbounds: [
                $outbound,
                {
                    type: "direct",
                    tag: "direct-out"
                }
            ],

            route: {
                rules: [
                    {
                        inbound: ["tuic-in"],
                        action: "route",
                        outbound: $target
                    }
                ],

                final: "direct-out"
            }
        }
        ' > "$config"

    chmod 600 "$config"

    # 检查 sing-box 配置是否合法
    "$BIN" check -c "$config"
}

# ==========================================================
# 创建 systemd 服务
# ==========================================================

create_service() {

    local name="$1"

    local service="${SERVICE_PREFIX}${name}.service"

    local config="$NODE_DIR/$name/config.json"

    cat > "/etc/systemd/system/$service" <<EOF
[Unit]
Description=TUIC Node $name
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $config
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable "$service"

    systemctl restart "$service"

    sleep 1

    if systemctl is-active --quiet "$service"; then
        info "节点 $name 启动成功"
    else
        error "节点启动失败，请查看日志"
        journalctl -u "$service" -n 30 --no-pager
    fi
}

# ==========================================================
# 生成分享链接
# ==========================================================

generate_link() {

    local name="$1"

    source "$NODE_DIR/$name/node.env"

    local ip
    ip="$(cat "$DATA_DIR/public_ip")"

    local sni
    sni="$(cat "$DATA_DIR/sni")"

    local encoded_name
    encoded_name="$(jq -rn --arg v "$name" '$v | @uri')"

    local encoded_sni
    encoded_sni="$(jq -rn --arg v "$sni" '$v | @uri')"

    echo
    echo "=========================================="
    echo "节点名称：$name"
    echo "服务器地址：$ip"
    echo "监听端口：$PORT"
    echo "SOCKS5：$MODE"
    echo "=========================================="

    echo "tuic://$UUID:$PASSWORD@$ip:$PORT?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$encoded_sni&allow_insecure=1#$encoded_name"

    echo "=========================================="
}

# ==========================================================
# 创建节点
# ==========================================================

create_node() {

    echo
    echo "========== 创建 TUIC 节点 =========="

    read -rp "节点名称：" name

    if ! valid_name "$name"; then
        error "节点名称只能使用英文、数字、下划线和横杠"
        return
    fi

    if [[ -d "$NODE_DIR/$name" ]]; then
        error "节点已经存在"
        return
    fi

    read -rp "监听端口：" port

    if ! [[ "$port" =~ ^[0-9]+$ ]] ||
       (( port < 1 || port > 65535 )); then
        error "端口不合法"
        return
    fi

    if ss -lun | grep -qE ":${port}[[:space:]]"; then
        error "UDP 端口已经被占用"
        return
    fi

    echo
    echo "请选择出站方式："
    echo "1. DIRECT 直接连接"
    echo "2. SOCKS5 代理"

    read -rp "选择：" choice

    local mode="direct"
    local host=""
    local socks_port=""
    local username=""
    local password=""

    if [[ "$choice" == "2" ]]; then

        mode="socks"

        read -rp "SOCKS5 地址：" host
        read -rp "SOCKS5 端口：" socks_port

        if [[ -z "$host" ]] ||
           ! [[ "$socks_port" =~ ^[0-9]+$ ]] ||
           (( socks_port < 1 || socks_port > 65535 )); then
            error "SOCKS5 地址或端口不合法"
            return
        fi

        echo
        echo "SOCKS5 认证方式："
        echo "1. 无认证"
        echo "2. 用户名密码"

        read -rp "选择：" auth

        if [[ "$auth" == "2" ]]; then
            read -rp "用户名：" username
            read -rsp "密码：" password
            echo

            if [[ -z "$username" || -z "$password" ]]; then
                error "用户名和密码不能为空"
                return
            fi
        fi

    elif [[ "$choice" != "1" ]]; then

        error "无效选择"
        return

    fi

    mkdir -p "$NODE_DIR/$name"

    cat > "$NODE_DIR/$name/node.env" <<EOF
PORT='$port'
MODE='$mode'
SOCKS_HOST='$host'
SOCKS_PORT='$socks_port'
SOCKS_USER='$username'
SOCKS_PASS='$password'
EOF

    chmod 600 "$NODE_DIR/$name/node.env"

    if ! generate_config \
        "$name" \
        "$port" \
        "$mode" \
        "$host" \
        "${socks_port:-0}" \
        "$username" \
        "$password"; then

        rm -rf "$NODE_DIR/$name"
        error "配置生成失败"
        return
    fi

    create_service "$name"

    generate_link "$name"
}

# ==========================================================
# 查看节点
# ==========================================================

list_nodes() {

    echo
    echo "========== 节点列表 =========="

    local found=0

    for dir in "$NODE_DIR"/*; do

        [[ -d "$dir" ]] || continue

        [[ -f "$dir/node.env" ]] || continue

        found=1

        source "$dir/node.env"

        local name
        name="$(basename "$dir")"

        local service="${SERVICE_PREFIX}${name}.service"

        local status="停止"

        if systemctl is-active --quiet "$service"; then
            status="运行中"
        fi

        printf "%-15s %-10s %-10s %-10s\n" \
            "$name" "$PORT" "$MODE" "$status"

    done

    if [[ "$found" == "0" ]]; then
        echo "目前没有节点"
    fi

    echo "================================"
}

# ==========================================================
# 节点选择
# ==========================================================

select_node() {

    read -rp "请输入节点名称：" NODE

    if [[ ! -f "$NODE_DIR/$NODE/node.env" ]]; then
        error "节点不存在"
        return 1
    fi

    return 0
}

# ==========================================================
# 节点启动、停止、重启
# ==========================================================

node_action() {

    select_node || return

    local service="${SERVICE_PREFIX}${NODE}.service"

    echo
    echo "1. 启动"
    echo "2. 停止"
    echo "3. 重启"
    echo "4. 查看状态"

    read -rp "选择：" choice

    case "$choice" in
        1)
            systemctl start "$service"
            ;;
        2)
            systemctl stop "$service"
            ;;
        3)
            systemctl restart "$service"
            ;;
        4)
            systemctl status "$service" --no-pager
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

# ==========================================================
# 修改节点 SOCKS5 设置
# ==========================================================

modify_proxy() {

    select_node || return

    source "$NODE_DIR/$NODE/node.env"

    echo
    echo "1. DIRECT"
    echo "2. SOCKS5"

    read -rp "选择：" choice

    local mode="direct"
    local host=""
    local port="0"
    local username=""
    local password=""

    if [[ "$choice" == "2" ]]; then

        mode="socks"

        read -rp "SOCKS5 地址：" host
        read -rp "SOCKS5 端口：" port

        if [[ -z "$host" ]] ||
           ! [[ "$port" =~ ^[0-9]+$ ]] ||
           (( port < 1 || port > 65535 )); then
            error "代理地址或端口不合法"
            return
        fi

        echo "1. 无认证"
        echo "2. 用户名密码"

        read -rp "选择：" auth

        if [[ "$auth" == "2" ]]; then
            read -rp "用户名：" username
            read -rsp "密码：" password
            echo
        fi

    elif [[ "$choice" != "1" ]]; then

        return
    fi

    generate_config \
        "$NODE" \
        "$PORT" \
        "$mode" \
        "$host" \
        "$port" \
        "$username" \
        "$password" || return

    cat > "$NODE_DIR/$NODE/node.env" <<EOF
PORT='$PORT'
MODE='$mode'
SOCKS_HOST='$host'
SOCKS_PORT='$port'
SOCKS_USER='$username'
SOCKS_PASS='$password'
EOF

    chmod 600 "$NODE_DIR/$NODE/node.env"

    systemctl restart "${SERVICE_PREFIX}${NODE}.service"

    info "节点代理配置已更新"
}

# ==========================================================
# 删除节点
# ==========================================================

delete_node() {

    select_node || return

    echo
    read -rp "确认删除节点 $NODE？输入 YES 确认：" confirm

    [[ "$confirm" == "YES" ]] || return

    systemctl disable --now \
        "${SERVICE_PREFIX}${NODE}.service" 2>/dev/null || true

    rm -f "/etc/systemd/system/${SERVICE_PREFIX}${NODE}.service"

    rm -rf "$NODE_DIR/$NODE"

    systemctl daemon-reload

    info "节点删除成功"
}

# ==========================================================
# 查看日志
# ==========================================================

show_logs() {

    select_node || return

    journalctl \
        -u "${SERVICE_PREFIX}${NODE}.service" \
        -n 100 \
        --no-pager
}

# ==========================================================
# 查看分享链接
# ==========================================================

show_link() {

    select_node || return

    generate_link "$NODE"
}

# ==========================================================
# 修改全局 UUID 和密码
# ==========================================================

modify_auth() {

    source "$GLOBAL"

    echo
    echo "当前 UUID：$UUID"
    echo "当前密码：$PASSWORD"

    read -rp "确认重新生成 UUID 和密码？YES：" confirm

    [[ "$confirm" == "YES" ]] || return

    UUID="$(cat /proc/sys/kernel/random/uuid)"
    PASSWORD="$(openssl rand -hex 16)"

    cat > "$GLOBAL" <<EOF
UUID='$UUID'
PASSWORD='$PASSWORD'
EOF

    chmod 600 "$GLOBAL"

    # 所有节点使用同一组新认证信息
    for dir in "$NODE_DIR"/*; do

        [[ -d "$dir" ]] || continue
        [[ -f "$dir/node.env" ]] || continue

        local name
        name="$(basename "$dir")"

        source "$dir/node.env"

        generate_config \
            "$name" \
            "$PORT" \
            "$MODE" \
            "$SOCKS_HOST" \
            "${SOCKS_PORT:-0}" \
            "$SOCKS_USER" \
            "$SOCKS_PASS" || continue

        systemctl restart "${SERVICE_PREFIX}${name}.service"

    done

    info "全局认证信息已更新"
}

# ==========================================================
# 修改公网 IP
# ==========================================================

modify_ip() {

    echo
    echo "当前公网地址：$(cat "$DATA_DIR/public_ip")"

    read -rp "请输入新的公网 IP 或域名：" ip

    if [[ -z "$ip" ]]; then
        return
    fi

    echo "$ip" > "$DATA_DIR/public_ip"

    info "公网地址已更新"
}

# ==========================================================
# 修改 TLS SNI
# ==========================================================

modify_sni() {

    read -rp "请输入新的 SNI：" sni

    [[ -n "$sni" ]] || return

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -days 3650 \
        -subj "/CN=$sni" \
        -addext "subjectAltName=DNS:$sni"

    chmod 600 "$CERT_DIR/server.key"

    echo "$sni" > "$DATA_DIR/sni"

    for dir in "$NODE_DIR"/*; do

        [[ -d "$dir" ]] || continue
        [[ -f "$dir/node.env" ]] || continue

        name="$(basename "$dir")"

        systemctl restart "${SERVICE_PREFIX}${name}.service"

    done

    info "SNI 和证书已更新"
}

# ==========================================================
# 卸载
# ==========================================================

uninstall() {

    echo
    warn "即将卸载所有 TUIC 节点！"

    read -rp "请输入 UNINSTALL 确认：" confirm

    [[ "$confirm" == "UNINSTALL" ]] || return

    for dir in "$NODE_DIR"/*; do

        [[ -d "$dir" ]] || continue

        name="$(basename "$dir")"

        systemctl disable --now \
            "${SERVICE_PREFIX}${name}.service" 2>/dev/null || true

        rm -f "/etc/systemd/system/${SERVICE_PREFIX}${name}.service"

    done

    systemctl daemon-reload

    rm -rf "$BASE"

    rm -f /usr/local/bin/tuic

    echo
    info "TUIC 数据、配置、节点和服务已删除"
    warn "sing-box 核心程序没有自动删除，避免影响其他服务。"
}

# ==========================================================
# 主菜单
# ==========================================================

menu() {

    clear

    echo -e "${BLUE}"
    echo "======================================"
    echo "          TUIC 多节点管理脚本"
    echo "======================================"
    echo -e "${NC}"

    echo " 1. 安装 / 检查 sing-box"
    echo " 2. 创建 TUIC 节点"
    echo " 3. 查看所有节点"
    echo " 4. 启动 / 停止 / 重启节点"
    echo " 5. 修改节点 SOCKS5 设置"
    echo " 6. 删除指定节点"
    echo " 7. 查看节点日志"
    echo " 8. 查看节点分享链接"
    echo
    echo " 9. 修改全局 UUID / 密码"
    echo "10. 修改公网 IP"
    echo "11. 修改 TLS SNI"
    echo
    echo "12. 卸载 TUIC"
    echo " 0. 退出"
    echo
    echo "======================================"

    read -rp "请选择操作：" choice

    case "$choice" in
        1) install_singbox ;;
        2) create_node ;;
        3) list_nodes ;;
        4) node_action ;;
        5) modify_proxy ;;
        6) delete_node ;;
        7) show_logs ;;
        8) show_link ;;
        9) modify_auth ;;
        10) modify_ip ;;
        11) modify_sni ;;
        12) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) warn "无效选择" ;;
    esac

    pause
}

# ==========================================================
# 程序入口
# ==========================================================

check_root

init_dirs

check_dependencies

install_singbox

init_global

if [[ ! -f "$DATA_DIR/public_ip" ]]; then
    get_public_ip > "$DATA_DIR/public_ip"
fi

if [[ ! -f "$DATA_DIR/sni" ]]; then
    create_cert
fi

# 创建快捷命令
if [[ ! -e /usr/local/bin/tuic ]]; then
    ln -s "$(readlink -f "$0")" /usr/local/bin/tuic
fi

while true; do
    menu
done
