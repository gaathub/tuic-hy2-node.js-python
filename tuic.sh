#!/usr/bin/env bash
# ============================================================
# TUIC 轻量化多节点管理脚本
# 一个 sing-box 进程管理全部 TUIC 节点
#
# 功能：
#   1. 多 TUIC 节点，共用 UUID / 密码
#   2. 每个节点独立选择 DIRECT 或 SOCKS5
#   3. SOCKS5 出站不限制 network，默认同时支持 TCP + UDP
#   4. 每个 TUIC 入站按 inbound 标签独立路由
#   5. 节点增删改采用配置备份/回滚
#   6. 自动生成 TUIC 分享链接
#   7. systemd 单服务管理
#   8. 卸载时清理服务、快捷命令、配置；核心程序可选择保留
#
# 注意：
#   SOCKS5 UDP 依赖上游服务器支持 UDP ASSOCIATE。
#   本脚本不会把 UDP 强制转换为 TCP；上游不支持 UDP 时，
#   sing-box 无法凭空让该 SOCKS5 服务器转发 UDP。
# ============================================================

set -Eeuo pipefail
umask 077
shopt -s nullglob

VERSION="2.0.0"
SB_VERSION="1.14.4"

BASE="/opt/tuic"
NODE_DIR="$BASE/nodes"
DATA_DIR="$BASE/data"
CERT_DIR="$BASE/cert"
CONFIG="$BASE/config.json"
AUTH_FILE="$DATA_DIR/auth.conf"
IP_FILE="$DATA_DIR/ip"
CERT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"

SERVICE="tuic.service"
BIN="/usr/local/bin/sing-box"
SHORTCUT="/usr/local/bin/tuic"
SNI="www.bing.com"

UUID=""
PASSWORD=""
PUBLIC_IP=""

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[信息]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*" >&2; }

pause() {
    read -r -p "按回车键继续..." _
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 用户运行：sudo bash $0"
        exit 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        error "当前系统没有 systemd，无法使用本脚本的服务管理功能。"
        exit 1
    fi
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

normalize_port() {
    # 把 0080 这种输入规范成 80，避免 JSON 数字出现前导零。
    printf '%d' "$((10#$1))"
}

valid_name() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]
}

init_dirs() {
    mkdir -p "$NODE_DIR" "$DATA_DIR" "$CERT_DIR"
    chmod 700 "$BASE" "$NODE_DIR" "$DATA_DIR" "$CERT_DIR"
}

install_dependencies() {
    local missing=()
    has_cmd curl || missing+=(curl)
    has_cmd openssl || missing+=(openssl)
    has_cmd tar || missing+=(tar)

    (( ${#missing[@]} == 0 )) && return 0

    info "安装缺失依赖：${missing[*]}"
    if has_cmd apt-get; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    elif has_cmd dnf; then
        dnf install -y "${missing[@]}"
    elif has_cmd yum; then
        yum install -y "${missing[@]}"
    elif has_cmd apk; then
        apk add --no-cache "${missing[@]}"
    else
        error "无法识别包管理器，请手动安装：${missing[*]}"
        return 1
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            error "暂不支持 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac
}

install_core() {
    if [[ -x "$BIN" ]]; then
        info "检测到 sing-box 已安装，沿用现有核心："
        "$BIN" version || {
            error "$BIN 无法正常运行，请先检查或移除损坏的二进制文件。"
            return 1
        }
        return 0
    fi

    local arch filename url tmp extracted
    arch="$(get_arch)"
    filename="sing-box-${SB_VERSION}-linux-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${filename}"
    tmp="$(mktemp -d /tmp/tuic-singbox.XXXXXX)"

    info "下载 sing-box ${SB_VERSION}（${arch}）"
    if ! curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp/sing-box.tar.gz"; then
        rm -rf "$tmp"
        error "sing-box 下载失败"
        return 1
    fi

    if ! tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"; then
        rm -rf "$tmp"
        error "sing-box 压缩包解压失败"
        return 1
    fi

    extracted="$(find "$tmp" -type f -name sing-box -print -quit)"
    if [[ -z "$extracted" ]]; then
        rm -rf "$tmp"
        error "压缩包中找不到 sing-box 二进制文件"
        return 1
    fi

    install -m 755 "$extracted" "$BIN"
    rm -rf "$tmp"
    info "sing-box 安装完成"
    "$BIN" version
}

init_auth() {
    if [[ -f "$AUTH_FILE" ]]; then
        IFS= read -r UUID < "$AUTH_FILE" || true
        PASSWORD="$(sed -n '2p' "$AUTH_FILE" 2>/dev/null || true)"
    fi

    # 校验标准 UUID 格式；不合法或密码为空时重新生成。
    if [[ ! "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
       [[ -z "$PASSWORD" ]]; then
        UUID="$(cat /proc/sys/kernel/random/uuid)"
        PASSWORD="$(openssl rand -hex 16)"
        {
            printf '%s\n' "$UUID"
            printf '%s\n' "$PASSWORD"
        } > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
        info "已生成全局 UUID 和密码"
    fi
}

get_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    fi
    printf '%s' "$ip"
}

init_ip() {
    if [[ -s "$IP_FILE" ]]; then
        PUBLIC_IP="$(cat "$IP_FILE")"
    else
        PUBLIC_IP="$(get_ip)"
        if [[ -z "$PUBLIC_IP" ]]; then
            read -r -p "无法自动获取公网地址，请输入 VPS 公网 IP 或域名：" PUBLIC_IP
        fi
        [[ -n "$PUBLIC_IP" ]] || {
            error "公网 IP / 域名不能为空"
            return 1
        }
        printf '%s\n' "$PUBLIC_IP" > "$IP_FILE"
        chmod 600 "$IP_FILE"
    fi
}

init_cert() {
    if [[ -s "$CERT" && -s "$KEY" ]]; then
        return 0
    fi

    info "生成 TLS 自签证书"
    openssl req \
        -x509 -nodes -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 \
        -keyout "$KEY" \
        -out "$CERT" \
        -subj "/CN=$SNI" \
        -addext "subjectAltName=DNS:$SNI" \
        >/dev/null 2>&1

    chmod 600 "$KEY"
    chmod 644 "$CERT"
    info "TLS 证书生成成功"
}

json_quote() {
    # 把任意字符串安全转换成 JSON 字符串，防止引号、反斜杠破坏 JSON。
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/}"
    value="${value//$'\n'/\\n}"
    printf '"%s"' "$value"
}

save_node() {
    local file="$NODE_DIR/$NODE_NAME/node.conf"
    mkdir -p "$NODE_DIR/$NODE_NAME"
    {
        printf 'NODE_NAME=%q\n' "$NODE_NAME"
        printf 'NODE_PORT=%q\n' "$NODE_PORT"
        printf 'MODE=%q\n' "$MODE"
        printf 'SOCKS_HOST=%q\n' "$SOCKS_HOST"
        printf 'SOCKS_PORT=%q\n' "$SOCKS_PORT"
        printf 'SOCKS_USER=%q\n' "$SOCKS_USER"
        printf 'SOCKS_PASS=%q\n' "$SOCKS_PASS"
    } > "$file"
    chmod 600 "$file"
}

load_node() {
    local node_name="$1"
    if ! valid_name "$node_name"; then
        error "节点名称不合法"
        return 1
    fi

    local file="$NODE_DIR/$node_name/node.conf"
    if [[ ! -f "$file" ]]; then
        error "节点不存在：$node_name"
        return 1
    fi

    # node.conf 由本脚本用 printf %q 生成。
    # 注意：不要让不可信用户拥有修改该文件的权限。
    source "$file"
}

check_port() {
    local port="$1"
    local dir saved_port

    if has_cmd ss; then
        if ss -H -lntu "sport = :$port" 2>/dev/null | grep -q .; then
            return 1
        fi
    else
        warn "系统没有 ss，无法完整检测系统中其他程序占用的端口。"
    fi

    for dir in "$NODE_DIR"/*; do
        [[ -f "$dir/node.conf" ]] || continue
        # 在子 Shell 中读取节点端口，避免 source 覆盖正在创建的节点变量。
        saved_port="$( ( source "$dir/node.conf"; printf '%s' "$NODE_PORT" ) )"
        if [[ "$saved_port" == "$port" ]]; then
            return 1
        fi
    done
    return 0
}

install_service() {
    cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=TUIC Multi Node Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "/etc/systemd/system/$SERVICE"
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null
}

restart_service() {
    install_service

    if ! systemctl restart "$SERVICE"; then
        error "systemd 执行重启命令失败"
        journalctl -u "$SERVICE" -n 40 --no-pager || true
        return 1
    fi

    sleep 2
    if systemctl is-active --quiet "$SERVICE"; then
        info "TUIC 服务运行正常"
        return 0
    fi

    error "TUIC 服务启动失败，最近日志如下："
    journalctl -u "$SERVICE" -n 50 --no-pager || true
    return 1
}

stop_service() {
    systemctl stop "$SERVICE" 2>/dev/null || true
}

# ==================== 生成 sing-box 配置 ====================
build_config() {
    local tmp dir first=1
    tmp="$(mktemp "$BASE/config.json.XXXXXX")"

    {
        cat <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
EOF

        # 每个节点创建一个 TUIC 入站。
        for dir in "$NODE_DIR"/*; do
            [[ -f "$dir/node.conf" ]] || continue
            source "$dir/node.conf"

            (( first == 0 )) && printf ',\n'
            first=0

            cat <<EOF
    {
      "type": "tuic",
      "tag": $(json_quote "in-$NODE_NAME"),
      "listen": "::",
      "listen_port": $NODE_PORT,
      "users": [
        {
          "name": "default",
          "uuid": $(json_quote "$UUID"),
          "password": $(json_quote "$PASSWORD")
        }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "certificate_path": $(json_quote "$CERT"),
        "key_path": $(json_quote "$KEY")
      }
    }
EOF
        done

        cat <<'EOF'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
EOF

        # 每个使用 SOCKS5 的节点创建独立出站。
        # 不设置 network：sing-box 默认同时启用 TCP 和 UDP。
        # 不设置 udp_over_tcp：使用 SOCKS5 原生 UDP ASSOCIATE。
        for dir in "$NODE_DIR"/*; do
            [[ -f "$dir/node.conf" ]] || continue
            source "$dir/node.conf"
            [[ "$MODE" == "socks" ]] || continue

            cat <<EOF
    ,
    {
      "type": "socks",
      "tag": $(json_quote "socks-$NODE_NAME"),
      "server": $(json_quote "$SOCKS_HOST"),
      "server_port": $SOCKS_PORT,
      "version": "5"
EOF
            if [[ -n "$SOCKS_USER" ]]; then
                cat <<EOF
      ,
      "username": $(json_quote "$SOCKS_USER"),
      "password": $(json_quote "$SOCKS_PASS")
EOF
            fi
            printf '    }\n'
        done

        cat <<'EOF'
  ],
  "route": {
    "rules": [
EOF

        first=1
        # 按 TUIC 入站标签分流；同一个入站的 TCP / UDP 都会匹配。
        for dir in "$NODE_DIR"/*; do
            [[ -f "$dir/node.conf" ]] || continue
            source "$dir/node.conf"
            [[ "$MODE" == "socks" ]] || continue

            (( first == 0 )) && printf ',\n'
            first=0
            cat <<EOF
      {
        "inbound": [$(json_quote "in-$NODE_NAME")],
        "action": "route",
        "outbound": $(json_quote "socks-$NODE_NAME")
      }
EOF
        done

        cat <<'EOF'
    ],
    "final": "direct"
  }
}
EOF
    } > "$tmp"

    # 使用当前安装的 sing-box 核心检查配置；检查失败不覆盖旧配置。
    if ! "$BIN" check -c "$tmp"; then
        rm -f "$tmp"
        error "sing-box 配置检查失败，旧配置保持不变。"
        return 1
    fi

    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG"
    info "sing-box 配置生成并检查通过"
}

# 配置变更后重启；重启失败时恢复变更前的配置文件。
apply_config() {
    local backup="$BASE/config.rollback.$$"
    local had_config=0

    if [[ -f "$CONFIG" ]]; then
        cp -a "$CONFIG" "$backup"
        had_config=1
    fi

    if ! build_config; then
        rm -f "$backup"
        return 1
    fi

    if restart_service; then
        rm -f "$backup"
        return 0
    fi

    error "服务未能正常启动，正在恢复旧配置"
    if (( had_config == 1 )); then
        cp -a "$backup" "$CONFIG"
        rm -f "$backup"
        restart_service || true
    else
        rm -f "$CONFIG" "$backup"
    fi
    return 1
}

ask_socks_settings() {
    local auth_choice

    read -r -p "SOCKS5 地址（域名或 IP）：" SOCKS_HOST
    [[ -n "$SOCKS_HOST" ]] || {
        error "SOCKS5 地址不能为空"
        return 1
    }

    read -r -p "SOCKS5 端口 [1080]：" SOCKS_PORT
    SOCKS_PORT="${SOCKS_PORT:-1080}"
    if ! valid_port "$SOCKS_PORT"; then
        error "SOCKS5 端口不合法"
        return 1
    fi
    SOCKS_PORT="$(normalize_port "$SOCKS_PORT")"

    echo
    echo "SOCKS5 认证方式："
    echo "1. 无认证"
    echo "2. 用户名密码"
    read -r -p "选择 [1-2]：" auth_choice

    SOCKS_USER=""
    SOCKS_PASS=""
    case "$auth_choice" in
        1) ;;
        2)
            read -r -p "用户名：" SOCKS_USER
            read -r -s -p "密码：" SOCKS_PASS
            echo
            if [[ -z "$SOCKS_USER" || -z "$SOCKS_PASS" ]]; then
                error "用户名和密码不能为空"
                return 1
            fi
            ;;
        *)
            error "认证方式选择错误"
            return 1
            ;;
    esac
}

create_node() {
    local choice

    echo
    echo "========== 创建 TUIC 节点 =========="
    read -r -p "节点名称（字母/数字/_/-，最多 32 位）：" NODE_NAME
    if ! valid_name "$NODE_NAME"; then
        error "节点名称不合法"
        return 1
    fi
    if [[ -e "$NODE_DIR/$NODE_NAME" ]]; then
        error "节点已经存在"
        return 1
    fi

    read -r -p "TUIC 监听端口：" NODE_PORT
    if ! valid_port "$NODE_PORT"; then
        error "TUIC 端口不合法"
        return 1
    fi
    NODE_PORT="$(normalize_port "$NODE_PORT")"

    if ! check_port "$NODE_PORT"; then
        error "端口 $NODE_PORT 已被占用"
        return 1
    fi

    echo
    echo "请选择该节点的出站模式："
    echo "1. DIRECT 直接连接"
    echo "2. 本机 SOCKS5（默认 127.0.0.1）"
    echo "3. 远程 SOCKS5"
    read -r -p "选择 [1-3]：" choice

    MODE="direct"
    SOCKS_HOST=""
    SOCKS_PORT="1080"
    SOCKS_USER=""
    SOCKS_PASS=""

    case "$choice" in
        1)
            MODE="direct"
            ;;
        2)
            MODE="socks"
            SOCKS_HOST="127.0.0.1"
            read -r -p "本机 SOCKS5 端口 [1080]：" SOCKS_PORT
            SOCKS_PORT="${SOCKS_PORT:-1080}"
            if ! valid_port "$SOCKS_PORT"; then
                error "SOCKS5 端口不合法"
                return 1
            fi
            SOCKS_PORT="$(normalize_port "$SOCKS_PORT")"
            echo "本机 SOCKS5 是否需要认证？"
            echo "1. 无认证"
            echo "2. 用户名密码"
            read -r -p "选择 [1-2]：" auth_choice
            if [[ "$auth_choice" == "2" ]]; then
                read -r -p "用户名：" SOCKS_USER
                read -r -s -p "密码：" SOCKS_PASS
                echo
                [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]] || {
                    error "用户名和密码不能为空"
                    return 1
                }
            elif [[ "$auth_choice" != "1" ]]; then
                error "认证方式选择错误"
                return 1
            fi
            ;;
        3)
            MODE="socks"
            ask_socks_settings || return 1
            ;;
        *)
            error "出站模式选择错误"
            return 1
            ;;
    esac

    save_node

    if ! apply_config; then
        rm -rf "$NODE_DIR/$NODE_NAME"
        build_config || true
        error "节点创建失败，已撤销节点文件"
        return 1
    fi

    print_link "$NODE_NAME"
    info "节点创建完成"
}

print_link() {
    local name="$1"
    load_node "$name" || return 1

    local link_ip="$PUBLIC_IP"
    if [[ "$link_ip" == *:* && "$link_ip" != \[*\] ]]; then
        link_ip="[$link_ip]"
    fi

    echo
    echo "================ TUIC 分享链接 ================"
    echo "节点名称：$NODE_NAME"
    echo "服务器：$PUBLIC_IP"
    echo "端口：$NODE_PORT"
    echo "出站模式：$MODE"
    echo "UUID：$UUID"
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1#%s\n' \
        "$UUID" "$PASSWORD" "$link_ip" "$NODE_PORT" "$SNI" "$NODE_NAME"
    echo "================================================"
}

list_nodes() {
    local dir count=0 status
    echo
    printf '%-18s %-9s %-10s %-12s\n' "节点名称" "端口" "出站" "服务状态"
    echo "------------------------------------------------------"

    for dir in "$NODE_DIR"/*; do
        [[ -f "$dir/node.conf" ]] || continue
        source "$dir/node.conf"
        count=$((count + 1))
        status="已停止"
        systemctl is-active --quiet "$SERVICE" && status="运行中"
        printf '%-18s %-9s %-10s %-12s\n' \
            "$NODE_NAME" "$NODE_PORT" "$MODE" "$status"
    done

    (( count > 0 )) || echo "目前没有节点"
    echo "------------------------------------------------------"
    echo "提示：服务状态是整个 sing-box 进程的状态，不代表每个端口都经过外部连通性测试。"
}

select_node() {
    read -r -p "请输入节点名称：" NODE_NAME
    load_node "$NODE_NAME"
}

delete_node() {
    local name backup_dir
    select_node || return 1
    name="$NODE_NAME"

    echo
    read -r -p "确定删除节点 $name？输入 YES 确认：" confirm
    [[ "$confirm" == "YES" ]] || return 0

    # 暂存到 NODE_DIR 外面，避免配置生成器把待删除备份当成节点。
    backup_dir="$BASE/delete-rollback-$name-$$"
    mv "$NODE_DIR/$name" "$backup_dir"

    if apply_config; then
        rm -rf "$backup_dir"
        info "节点 $name 已删除"
    else
        mv "$backup_dir" "$NODE_DIR/$name"
        build_config || true
        restart_service || true
        error "删除操作失败，已恢复节点"
        return 1
    fi
}

modify_proxy() {
    local name old_file backup_file

    select_node || return 1
    name="$NODE_NAME"
    old_file="$NODE_DIR/$name/node.conf"
    backup_file="$old_file.rollback"

    cp -a "$old_file" "$backup_file"

    echo
    echo "1. DIRECT 直接连接"
    echo "2. SOCKS5 代理"
    read -r -p "选择 [1-2]：" choice

    case "$choice" in
        1)
            MODE="direct"
            SOCKS_HOST=""
            SOCKS_PORT="1080"
            SOCKS_USER=""
            SOCKS_PASS=""
            ;;
        2)
            MODE="socks"
            ask_socks_settings || {
                rm -f "$backup_file"
                return 1
            }
            ;;
        *)
            error "选择错误"
            rm -f "$backup_file"
            return 1
            ;;
    esac

    save_node

    if apply_config; then
        rm -f "$backup_file"
        info "节点 $name 出站设置修改完成"
    else
        cp -a "$backup_file" "$old_file"
        rm -f "$backup_file"
        build_config || true
        restart_service || true
        error "修改失败，已恢复原设置"
        return 1
    fi
}

modify_ip() {
    echo "当前分享地址：$PUBLIC_IP"
    read -r -p "请输入新的公网 IP 或域名：" new_ip
    [[ -n "$new_ip" ]] || return 0

    PUBLIC_IP="$new_ip"
    printf '%s\n' "$PUBLIC_IP" > "$IP_FILE"
    chmod 600 "$IP_FILE"
    info "分享地址已更新；现有节点无需重启"
}

modify_auth() {
    local backup_file="$BASE/auth.rollback.$$"
    echo
    warn "修改全局 UUID / 密码后，所有客户端都必须重新导入。"
    read -r -p "输入 YES 确认：" confirm
    [[ "$confirm" == "YES" ]] || return 0

    cp -a "$AUTH_FILE" "$backup_file"
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    PASSWORD="$(openssl rand -hex 16)"
    {
        printf '%s\n' "$UUID"
        printf '%s\n' "$PASSWORD"
    } > "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"

    if apply_config; then
        rm -f "$backup_file"
        info "全局认证信息已更新："
        echo "UUID：$UUID"
        echo "密码：$PASSWORD"
    else
        cp -a "$backup_file" "$AUTH_FILE"
        rm -f "$backup_file"
        init_auth
        build_config || true
        restart_service || true
        error "认证修改失败，已恢复旧认证信息"
        return 1
    fi
}

show_logs() {
    journalctl -u "$SERVICE" -n 100 --no-pager
}

restart_all() {
    if restart_service; then
        info "全部节点已重启"
    else
        error "重启失败，请查看日志"
    fi
}

uninstall() {
    local answer
    echo
    warn "即将卸载 TUIC 管理脚本、全部节点、证书、配置和 systemd 服务。"
    read -r -p "输入 UNINSTALL 确认：" confirm
    [[ "$confirm" == "UNINSTALL" ]] || return 0

    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true

    # 清理本脚本创建的快捷命令，避免卸载后留下失效入口。
    rm -f "$SHORTCUT"

    # 删除 TUIC 自身目录，不触碰其他路径。
    rm -rf "$BASE"

    echo
    warn "TUIC 节点、证书、配置、服务和快捷命令已卸载。"
    echo "sing-box 核心程序默认保留，避免误删其他程序共用的核心。"
    read -r -p "是否同时删除 $BIN？[y/N]：" answer
    if [[ "${answer,,}" == "y" ]]; then
        rm -f "$BIN"
        info "sing-box 核心程序已删除"
    else
        info "已保留 sing-box 核心程序"
    fi
}

menu() {
    clear 2>/dev/null || true
    echo -e "${BLUE}"
    echo "======================================"
    echo "       TUIC 轻量化多节点管理 v${VERSION}"
    echo "======================================"
    echo -e "${NC}"
    echo " 1. 创建 TUIC 节点"
    echo " 2. 查看所有节点"
    echo " 3. 修改节点 DIRECT / SOCKS5"
    echo " 4. 删除指定节点"
    echo " 5. 查看节点分享链接"
    echo
    echo " 6. 启动全部节点"
    echo " 7. 停止全部节点"
    echo " 8. 重启全部节点"
    echo " 9. 查看运行日志"
    echo
    echo "10. 修改全局 UUID / 密码"
    echo "11. 修改公网 IP / 域名"
    echo
    echo "12. 卸载 TUIC"
    echo
    echo " 0. 退出"
    echo "======================================"

    read -r -p "请选择：" choice
    case "$choice" in
        1) create_node ;;
        2) list_nodes ;;
        3) modify_proxy ;;
        4) delete_node ;;
        5)
            select_node && print_link "$NODE_NAME"
            ;;
        6)
            systemctl start "$SERVICE" && info "服务启动命令已执行"
            ;;
        7)
            systemctl stop "$SERVICE" && info "服务已停止"
            ;;
        8) restart_all ;;
        9) show_logs ;;
        10) modify_auth ;;
        11) modify_ip ;;
        12)
            uninstall
            exit 0
            ;;
        0) exit 0 ;;
        *) warn "无效选择" ;;
    esac

    pause
}

main() {
    check_root
    init_dirs
    install_dependencies
    install_core
    init_auth
    init_ip
    init_cert

    if [[ ! -f "$CONFIG" ]]; then
        build_config
    else
        # 已存在配置时先校验；若旧配置损坏，则尝试按节点文件重新生成。
        if ! "$BIN" check -c "$CONFIG" >/dev/null 2>&1; then
            warn "检测到现有配置无法通过检查，尝试重新生成"
            build_config
        fi
    fi

    install_service

    local script_path
    script_path="$(readlink -f "${BASH_SOURCE[0]}")"
    ln -sf "$script_path" "$SHORTCUT"

    while true; do
        menu
    done
}

main "$@"
