#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 部署脚本（支持 SOCKS5 代理转发）
# 典型链路：客户端 -> Hysteria2 -> SOCKS5 代理（可选）-> 目标网站

set -euo pipefail

# ---------- 默认配置 ----------
HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.5}"
DEFAULT_PORT="${DEFAULT_PORT:-22222}"          # Hysteria2 默认监听端口
AUTH_PASSWORD="${AUTH_PASSWORD:-ieshare2025}"  # Hysteria2 默认连接密码
CERT_FILE="${CERT_FILE:-cert.pem}"             # 证书文件路径
KEY_FILE="${KEY_FILE:-key.pem}"                # 私钥文件路径
SNI="${SNI:-www.bing.com}"                     # 伪装域名
ALPN="${ALPN:-h3}"
UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"

# SOCKS5 默认配置，兼容旧环境变量名
SOCKS_IP="${SOCKS_IP:-${AIMILI_SOCKS_IP:-}}"
SOCKS5_PORT="${SOCKS5_PORT:-${AIMILI_SOCKS5_PORT:-7928}}"
SOCKS5_USER="${SOCKS5_USER:-${AIMILI_SOCKS5_USER:-}}"
SOCKS5_PASS="${SOCKS5_PASS:-${AIMILI_SOCKS5_PASS:-}}"
MODE="${MODE:-tcp_only}"                       # tcp_only | all_proxy
USE_SOCKS5="${USE_SOCKS5:-auto}"
ACTION="install"
BIN_PATH=""
PID_FILE="hysteria.pid"
LOG_FILE="hysteria.log"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 部署脚本（支持 SOCKS5 代理转发）"
echo "链路: 客户端 -> Hysteria2 -> SOCKS5 代理（可选）-> 目标网站"
echo "支持参数: bash hy2.sh [监听端口] [socksIP|local] [SOCKS5_PORT] [模式]"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

usage() {
    cat <<'EOF'
用法:
  bash hy2.sh
  bash hy2.sh [监听端口]
  bash hy2.sh [监听端口] [socksIP|local]
  bash hy2.sh [监听端口] [socksIP|local] [SOCKS5_PORT]
  bash hy2.sh [监听端口] [socksIP|local] [SOCKS5_PORT] [模式]
  bash hy2.sh del
  bash hy2.sh --uninstall

模式:
  tcp_only   仅 TCP 走代理，UDP 直连当前服务器（推荐，最稳）
  all_proxy  尽量 TCP/UDP 都走代理（取决于上游 SOCKS5 是否支持 UDP）

示例:
  bash hy2.sh 443 local 7928
  bash hy2.sh 443 1.2.3.4 7928
  bash hy2.sh 443 1.2.3.4 7928 all_proxy
  SOCKS5_USER=user SOCKS5_PASS=pass bash hy2.sh 443 1.2.3.4 7928
  bash hy2.sh del

环境变量:
  SOCKS_IP
  SOCKS5_PORT
  SOCKS5_USER
  SOCKS5_PASS
  MODE=tcp_only|all_proxy
EOF
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

tty_print() {
    printf '%s' "$1" >/dev/tty
}

tty_prompt_read() {
    local prompt="$1"
    local silent="${2:-0}"
    local value=""

    # 直接写到 /dev/tty，避免 read -p 走 stderr 后在网页终端里延迟显示
    tty_print "$prompt"
    if [ "$silent" = "1" ]; then
        IFS= read -r -s value </dev/tty || true
        tty_print $'\n'
    else
        IFS= read -r value </dev/tty || true
    fi
    REPLY="$value"
}

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 当前操作需要 root 权限，请切换到 root 后重试。"
        exit 1
    fi
}

detect_pkg_manager() {
    if has_cmd apt-get; then
        echo "apt"
    elif has_cmd dnf; then
        echo "dnf"
    elif has_cmd yum; then
        echo "yum"
    elif has_cmd apk; then
        echo "apk"
    elif has_cmd zypper; then
        echo "zypper"
    else
        echo ""
    fi
}

install_openssl() {
    local pkg_manager
    pkg_manager="$(detect_pkg_manager)"

    if [ -z "$pkg_manager" ]; then
        echo "❌ 未找到支持的包管理器，无法自动安装 openssl，请手动安装后重试。"
        exit 1
    fi

    ensure_root
    echo "📦 检测到未安装 openssl，尝试自动安装（$pkg_manager）..."

    case "$pkg_manager" in
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
            ;;
        dnf)
            dnf install -y openssl
            ;;
        yum)
            yum install -y openssl
            ;;
        apk)
            apk add --no-cache openssl
            ;;
        zypper)
            zypper --non-interactive install openssl
            ;;
    esac

    if has_cmd openssl; then
        echo "✅ openssl 安装完成。"
    else
        echo "❌ openssl 安装失败，请手动安装后重试。"
        exit 1
    fi
}

ensure_openssl() {
    if has_cmd openssl; then
        return
    fi
    install_openssl
}

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

read_text() {
    local prompt="$1"
    local default_value="${2:-}"

    if [ -n "$default_value" ]; then
        tty_prompt_read "$prompt [$default_value]: "
        REPLY="${REPLY:-$default_value}"
    else
        tty_prompt_read "$prompt: "
    fi
}

read_secret() {
    local prompt="$1"
    local default_value="${2:-}"

    if [ -n "$default_value" ]; then
        tty_prompt_read "$prompt [已有值，回车保持]: " "1"
        REPLY="${REPLY:-$default_value}"
    else
        tty_prompt_read "$prompt: " "1"
    fi
}

read_yes_no() {
    local prompt="$1"
    local default_value="${2:-y}"
    local value
    local hint

    if [ "$default_value" = "y" ]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    while true; do
        tty_prompt_read "$prompt [$hint]: "
        value="${REPLY:-$default_value}"
        case "$value" in
            y|Y|yes|YES|Yes)
                REPLY="y"
                return 0
                ;;
            n|N|no|NO|No)
                REPLY="n"
                return 0
                ;;
            *)
                echo "⚠️  请输入 y 或 n"
                ;;
        esac
    done
}

ask_port() {
    local prompt="$1"
    local default_value="$2"

    while true; do
        read_text "$prompt" "$default_value"
        if validate_port "$REPLY"; then
            return 0
        fi
        echo "⚠️  端口必须是 1-65535 之间的数字"
    done
}

normalize_mode() {
    case "${1,,}" in
        tcp_only|tcp|tcp_proxy_udp_direct|1)
            echo "tcp_only"
            ;;
        all_proxy|all|proxy_all|2)
            echo "all_proxy"
            ;;
        *)
            echo ""
            ;;
    esac
}

mode_text() {
    case "$MODE" in
        tcp_only)
            echo "仅 TCP 走代理，UDP 直连当前服务器"
            ;;
        all_proxy)
            echo "尽量 TCP/UDP 都走代理"
            ;;
        *)
            echo "$MODE"
            ;;
    esac
}

socks_proxy_text() {
    if [ "$SOCKS_IP" = "127.0.0.1" ]; then
        echo "本机 SOCKS5 代理: ${SOCKS_IP}:${SOCKS5_PORT}"
    else
        echo "远程 SOCKS5 代理: ${SOCKS_IP}:${SOCKS5_PORT}"
    fi
}

normalize_socks_host() {
    case "${1,,}" in
        local|localhost|127.0.0.1)
            echo "127.0.0.1"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

choose_mode() {
    local value
    while true; do
        echo "请选择分流模式："
        echo "1. 仅 TCP 走代理，UDP 直连当前服务器（推荐）"
        echo "2. 尽量 TCP/UDP 都走代理"
        tty_prompt_read "请输入选项 [1]: "
        value="${REPLY:-1}"
        MODE="$(normalize_mode "$value")"
        if [ -n "$MODE" ]; then
            return 0
        fi
        echo "⚠️  请输入 1 或 2"
    done
}

list_generated_files() {
    printf '%s\n' "./server.yaml"
    printf '%s\n' "./${CERT_FILE}"
    printf '%s\n' "./${KEY_FILE}"
    printf '%s\n' "./hysteria-linux-amd64"
    printf '%s\n' "./hysteria-linux-arm64"
    printf '%s\n' "./${PID_FILE}"
    printf '%s\n' "./${LOG_FILE}"
}

parse_args() {
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            del|--uninstall|uninstall|remove|rm)
                ACTION="uninstall"
                shift
                ;;
            --)
                shift
                break
                ;;
            -* )
                echo "❌ 不支持的参数: $1"
                usage
                exit 1
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -ge 1 && -n "${positional[0]}" ]]; then
        SERVER_PORT="${positional[0]}"
        echo "✅ 使用命令行指定 Hysteria2 端口: $SERVER_PORT"
    else
        SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    fi

    if [[ ${#positional[@]} -ge 2 && -n "${positional[1]}" ]]; then
        SOCKS_IP="$(normalize_socks_host "${positional[1]}")"
        USE_SOCKS5="y"
        echo "✅ 使用命令行指定 SOCKS5 代理地址: $SOCKS_IP"
    fi

    if [[ ${#positional[@]} -ge 3 && -n "${positional[2]}" ]]; then
        SOCKS5_PORT="${positional[2]}"
        echo "✅ 使用命令行指定 SOCKS5 代理端口: $SOCKS5_PORT"
    fi

    if [[ ${#positional[@]} -ge 4 && -n "${positional[3]}" ]]; then
        MODE="${positional[3]}"
        echo "✅ 使用命令行指定模式: $MODE"
    fi

    if [[ ${#positional[@]} -gt 4 ]]; then
        echo "❌ 参数过多。"
        usage
        exit 1
    fi
}

interactive_config() {
    local default_auth="n"
    local proxy_choice="1"
    local value

    ask_port "请输入 Hysteria2 监听端口" "$SERVER_PORT"
    SERVER_PORT="$REPLY"

    if [ "$USE_SOCKS5" = "auto" ]; then
        if [ -n "$SOCKS_IP" ]; then
            USE_SOCKS5="y"
        else
            USE_SOCKS5="n"
        fi
    fi

    if [ "$USE_SOCKS5" = "y" ]; then
        SOCKS_IP="$(normalize_socks_host "$SOCKS_IP")"
        if [ "$SOCKS_IP" = "127.0.0.1" ]; then
            proxy_choice="2"
        else
            proxy_choice="3"
        fi
    fi

    while true; do
        echo "请选择 SOCKS5 代理方式："
        echo "1. 不使用 SOCKS5 代理，直接连接"
        echo "2. 使用本机 SOCKS5 代理（127.0.0.1）"
        echo "3. 使用远程 SOCKS5 代理"
        tty_prompt_read "请输入选项 [$proxy_choice]: "
        value="${REPLY:-$proxy_choice}"
        case "$value" in
            1|n|N|no|NO|No)
                USE_SOCKS5="n"
                SOCKS_IP=""
                break
                ;;
            2|local|localhost|127.0.0.1)
                USE_SOCKS5="y"
                SOCKS_IP="127.0.0.1"
                break
                ;;
            3|remote|r|R)
                USE_SOCKS5="y"
                if [ "$SOCKS_IP" = "127.0.0.1" ]; then
                    SOCKS_IP=""
                fi
                break
                ;;
            *)
                echo "⚠️  请输入 1、2 或 3"
                ;;
        esac
    done

    if [ "$USE_SOCKS5" = "y" ]; then
        if [ "$SOCKS_IP" != "127.0.0.1" ]; then
            while true; do
                read_text "请输入远程 SOCKS5 代理地址(IP或域名)" "$SOCKS_IP"
                SOCKS_IP="$(normalize_socks_host "$REPLY")"
                if [ -n "$SOCKS_IP" ]; then
                    break
                fi
                echo "⚠️  SOCKS5 代理地址不能为空"
            done
        fi

        ask_port "请输入 SOCKS5 代理端口" "$SOCKS5_PORT"
        SOCKS5_PORT="$REPLY"

        if [ -n "$SOCKS5_USER" ] || [ -n "$SOCKS5_PASS" ]; then
            default_auth="y"
        fi

        read_yes_no "SOCKS5 是否需要账号密码认证" "$default_auth"
        if [ "$REPLY" = "y" ]; then
            while true; do
                read_text "请输入 SOCKS5 用户名" "$SOCKS5_USER"
                SOCKS5_USER="$REPLY"
                if [ -n "$SOCKS5_USER" ]; then
                    break
                fi
                echo "⚠️  用户名不能为空"
            done

            while true; do
                read_secret "请输入 SOCKS5 密码" "$SOCKS5_PASS"
                SOCKS5_PASS="$REPLY"
                if [ -n "$SOCKS5_PASS" ]; then
                    break
                fi
                echo "⚠️  密码不能为空"
            done
        else
            SOCKS5_USER=""
            SOCKS5_PASS=""
        fi

        choose_mode
    else
        SOCKS_IP=""
        SOCKS5_USER=""
        SOCKS5_PASS=""
        MODE="tcp_only"
    fi
}

validate_config() {
    if ! validate_port "$SERVER_PORT"; then
        echo "❌ Hysteria2 监听端口无效: $SERVER_PORT"
        exit 1
    fi

    if [ "$USE_SOCKS5" = "y" ]; then
        SOCKS_IP="$(normalize_socks_host "$SOCKS_IP")"
        if [ -z "$SOCKS_IP" ]; then
            echo "❌ 已启用 SOCKS5 代理，但地址为空。"
            exit 1
        fi

        if ! validate_port "$SOCKS5_PORT"; then
            echo "❌ SOCKS5 代理端口无效: $SOCKS5_PORT"
            exit 1
        fi

        MODE="$(normalize_mode "$MODE")"
        if [ -z "$MODE" ]; then
            echo "❌ 模式无效，仅支持: tcp_only 或 all_proxy"
            exit 1
        fi

        if { [ -n "$SOCKS5_USER" ] && [ -z "$SOCKS5_PASS" ]; } || { [ -z "$SOCKS5_USER" ] && [ -n "$SOCKS5_PASS" ]; }; then
            echo "❌ SOCKS5 用户名和密码必须同时提供，或同时留空。"
            exit 1
        fi
    else
        SOCKS_IP=""
        SOCKS5_USER=""
        SOCKS5_PASS=""
        MODE="tcp_only"
    fi
}

print_summary() {
    echo "=========================================================================="
    echo "📋 配置确认:"
    echo "   🔌 Hysteria2 监听端口: $SERVER_PORT"
    echo "   🔑 Hysteria2 连接密码: $AUTH_PASSWORD"
    echo "   🌐 伪装 SNI: $SNI"
    echo "   🧩 ALPN: $ALPN"
    if [ "$USE_SOCKS5" = "y" ]; then
        echo "   🧦 $(socks_proxy_text)"
        if [ -n "$SOCKS5_USER" ] && [ -n "$SOCKS5_PASS" ]; then
            echo "   🔐 SOCKS5 认证: 已启用"
        else
            echo "   🔓 SOCKS5 认证: 未启用"
        fi
        echo "   🚦 分流模式: $(mode_text)"
    else
        echo "   🧦 SOCKS5 代理: 未使用"
        echo "   🚦 分流模式: 全部直连当前服务器"
    fi
    echo "=========================================================================="
}

uninstall_files() {
    local file

    echo "🗑️  开始卸载 Hysteria2 相关文件..."
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f -- "$PID_FILE"
    fi
    pkill -f "hysteria-linux-.* server -c server.yaml" 2>/dev/null || true

    while IFS= read -r file; do
        if [ -e "$file" ]; then
            rm -f -- "$file"
            echo "✅ 已删除: $file"
        fi
    done < <(list_generated_files)

    echo "✅ 卸载完成。"
}

start_hysteria() {
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "⚠️  检测到已有 Hysteria2 正在运行，先停止旧进程: $old_pid"
            kill "$old_pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f -- "$PID_FILE"
    fi

    echo "🚀 正在后台启动 Hysteria2..."
    nohup "$BIN_PATH" server -c server.yaml >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1

    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "✅ Hysteria2 已后台运行"
        echo "   PID: $(cat "$PID_FILE")"
        echo "   日志: $(pwd)/${LOG_FILE}"
    else
        echo "❌ Hysteria2 启动失败，请检查日志: $(pwd)/${LOG_FILE}"
        exit 1
    fi
}

# ---------- 检测架构 ----------
# 自动检测当前服务器的 CPU 架构，以决定下载哪个版本的内核
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

download_binary() {
    local arch
    local url

    if ! has_cmd curl; then
        echo "❌ 未检测到 curl，请先安装 curl 后重试。"
        exit 1
    fi

    arch="$(arch_name)"
    if [ -z "$arch" ]; then
        echo "❌ 无法识别 CPU 架构: $(uname -m)"
        exit 1
    fi

    BIN_NAME="hysteria-linux-${arch}"
    BIN_PATH="./${BIN_NAME}"

    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi

    url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $url"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi

    ensure_openssl
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件 ----------
write_config() {
    {
        cat <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
bandwidth:
  up: "${UP_BANDWIDTH}"
  down: "${DOWN_BANDWIDTH}"
quic:
  max_idle_timeout: "10s"
  max_concurrent_streams: 4
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144
EOF

        if [ "$USE_SOCKS5" = "y" ]; then
            cat <<EOF

# === SOCKS5 代理出站 ===
outbounds:
  - name: socks_proxy
    type: socks5
    socks5:
      addr: "${SOCKS_IP}:${SOCKS5_PORT}"
EOF

            if [ -n "$SOCKS5_USER" ] && [ -n "$SOCKS5_PASS" ]; then
                cat <<EOF
      username: "${SOCKS5_USER}"
      password: "${SOCKS5_PASS}"
EOF
            fi

            if [ "$MODE" = "tcp_only" ]; then
                cat <<'EOF'

# === 分流规则 ===
# TCP 走 SOCKS5 代理，UDP 由当前服务器直连
acl:
  inline:
    - socks_proxy(network:tcp)
    - direct(network:udp)
EOF
            else
                cat <<'EOF'

# === 分流规则 ===
# 尽量全走 SOCKS5 代理
acl:
  inline:
    - socks_proxy(all)
EOF
            fi
        else
            cat <<'EOF'

# === 分流规则 ===
# 未使用 SOCKS5 代理，全部由当前服务器直连
acl:
  inline:
    - direct(all)
EOF
        fi
    } > server.yaml

    echo "✅ 写入配置 server.yaml 成功。"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    local ip
    ip="$(curl --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    echo "${ip:-YOUR_SERVER_IP}"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local ip="$1"

    echo "🎉 Hysteria2 部署成功！"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 服务器公网IP: $ip"
    echo "   🔌 Hysteria2 监听端口: $SERVER_PORT"
    echo "   🔑 Hysteria2 连接密码: $AUTH_PASSWORD"
    if [ "$USE_SOCKS5" = "y" ]; then
        echo "   🧦 $(socks_proxy_text)"
        if [ -n "$SOCKS5_USER" ] && [ -n "$SOCKS5_PASS" ]; then
            echo "   🔐 SOCKS5 认证: 已启用"
        else
            echo "   🔓 SOCKS5 认证: 未启用"
        fi
        echo "   🚦 分流模式: $(mode_text)"
    else
        echo "   🧦 SOCKS5 代理: 未使用"
        echo "   🚦 分流模式: 全部直连当前服务器"
    fi
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${ip}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-SOCKS5"
    echo ""
    echo "📝 运行文件:"
    echo "   📄 配置文件: $(pwd)/server.yaml"
    echo "   📄 日志文件: $(pwd)/${LOG_FILE}"
    echo "   📄 PID 文件: $(pwd)/${PID_FILE}"
    echo ""
    if [ "$USE_SOCKS5" = "y" ]; then
        echo "⚠️ 提醒："
        echo "   1. 已启用 SOCKS5 代理，实际出口取决于该 SOCKS5 代理。"
        echo "   2. 想换出口 IP，请切换代理背后的出口节点，或更换 SOCKS5 代理地址。"
        if [ "$MODE" = "all_proxy" ]; then
            echo "   3. 当前为尽量全代理模式，UDP 是否稳定取决于 SOCKS5 代理对 UDP 的支持。"
        else
            echo "   3. 当前为 TCP 代理 / UDP 直连模式，稳定性更好。"
        fi
    fi
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    parse_args "$@"

    if [ "$ACTION" = "uninstall" ]; then
        uninstall_files
        exit 0
    fi

    if [ -t 0 ]; then
        interactive_config
        print_summary
        read_yes_no "确认以上配置并继续部署" "y"
        if [ "$REPLY" != "y" ]; then
            exit 0
        fi
    fi

    validate_config
    download_binary
    ensure_cert
    write_config
    start_hysteria
    SERVER_IP="$(get_server_ip)"
    print_connection_info "$SERVER_IP"
}

main "$@"
