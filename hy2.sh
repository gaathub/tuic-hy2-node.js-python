#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 多节点部署脚本（支持每个节点独立自定义 SOCKS5 代理）

set -euo pipefail

# ==========================================
# ---------- 核心多节点配置区 ----------
# 注意：以下所有数组的元素个数必须完全一致（一一对应）
# ==========================================

# 1. 节点基础配置
NODE_PORTS=(22222 33333 44444)
NODE_PASSWORDS=("ieshare2025" "ieshare2025" "ieshare2025")

# 2. 节点独立的 SOCKS5 代理配置
# 是否使用代理: y 表示使用，n 表示直连
NODE_USE_SOCKS=("n" "y" "y")
# 代理 IP: 如果不用代理填 ""，本机填 "127.0.0.1"
NODE_SOCKS_IPS=("" "127.0.0.1" "198.51.100.1")
# 代理端口: 如果不用代理填 ""
NODE_SOCKS_PORTS=("" "7928" "1080")
# 代理账号: 没有则填 ""
NODE_SOCKS_USERS=("" "" "myuser")
# 代理密码: 没有则填 ""
NODE_SOCKS_PASSWORDS=("" "" "mypass")
# 代理模式: tcp_only (仅TCP代理) 或 all_proxy (TCP/UDP全代理)
NODE_SOCKS_MODES=("tcp_only" "tcp_only" "all_proxy")

# ==========================================
# ---------- 默认全局配置 ----------
HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.5}"
CERT_FILE="${CERT_FILE:-cert.pem}"             
KEY_FILE="${KEY_FILE:-key.pem}"                
SNI="${SNI:-www.bing.com}"                     
ALPN="${ALPN:-h3}"
UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"
ACTION="install"
BIN_PATH=""
# ==========================================

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 多节点部署脚本（支持节点独立 SOCKS5 代理）"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 当前操作需要 root 权限，请切换到 root 后重试。"
        exit 1
    fi
}

install_openssl() {
    local pkg_manager
    if has_cmd apt-get; then pkg_manager="apt-get"
    elif has_cmd dnf; then pkg_manager="dnf"
    elif has_cmd yum; then pkg_manager="yum"
    elif has_cmd apk; then pkg_manager="apk"
    else
        echo "❌ 未找到支持的包管理器，无法自动安装 openssl。"
        exit 1
    fi
    ensure_root
    echo "📦 正在自动安装 openssl..."
    if [ "$pkg_manager" = "apt-get" ]; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
    elif [ "$pkg_manager" = "apk" ]; then
        apk add --no-cache openssl
    else
        $pkg_manager install -y openssl
    fi
}

ensure_openssl() { has_cmd openssl || install_openssl; }

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

validate_config() {
    local count=${#NODE_PORTS[@]}
    if [ ${#NODE_PASSWORDS[@]} -ne $count ] || [ ${#NODE_USE_SOCKS[@]} -ne $count ] || [ ${#NODE_SOCKS_IPS[@]} -ne $count ] || [ ${#NODE_SOCKS_PORTS[@]} -ne $count ]; then
        echo "❌ 配置错误: 顶部的各个数组元素数量不一致，请检查是否一一对应！"
        exit 1
    fi

    for port in "${NODE_PORTS[@]}"; do
        if ! validate_port "$port"; then
            echo "❌ Hysteria2 监听端口无效: $port"
            exit 1
        fi
    done
}

uninstall_files() {
    echo "🗑️  开始清理旧的 Hysteria2 相关文件和进程..."
    pkill -f "server -c server_.*\.yaml" 2>/dev/null || true
    rm -f hysteria_*.pid hysteria_*.log server_*.yaml
    rm -f "${CERT_FILE}" "${KEY_FILE}" hysteria-linux-amd64 hysteria-linux-arm64
    echo "✅ 卸载/清理完成。"
}

start_hysteria() {
    for i in "${!NODE_PORTS[@]}"; do
        local port="${NODE_PORTS[$i]}"
        local pid_file="hysteria_${port}.pid"
        local log_file="hysteria_${port}.log"
        local conf_file="server_${port}.yaml"

        if [ -f "$pid_file" ]; then
            local old_pid="$(cat "$pid_file" 2>/dev/null || true)"
            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                kill "$old_pid" 2>/dev/null || true
                sleep 1
            fi
            rm -f -- "$pid_file"
        fi

        echo "🚀 正在后台启动节点 (端口: $port)..."
        nohup "$BIN_PATH" server -c "$conf_file" >"$log_file" 2>&1 &
        echo $! > "$pid_file"
        sleep 1

        if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            echo "✅ 节点 $port 已后台运行 (PID: $(cat "$pid_file"))"
        else
            echo "❌ 节点 $port 启动失败，请检查日志: $(pwd)/${log_file}"
        fi
    done
}

arch_name() {
    local machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then echo "amd64"
    fi
}

download_binary() {
    if ! has_cmd curl; then echo "❌ 未检测到 curl，请先安装。"; exit 1; fi
    local arch="$(arch_name)"
    if [ -z "$arch" ]; then echo "❌ 无法识别 CPU 架构。"; exit 1; fi
    BIN_PATH="./hysteria-linux-${arch}"
    if [ -f "$BIN_PATH" ]; then echo "✅ 二进制已存在，跳过下载。"; return; fi
    local url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${arch}"
    echo "⏳ 下载核心组件..."
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"
    chmod +x "$BIN_PATH"
}

ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then return; fi
    ensure_openssl
    echo "🔑 正在生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}" >/dev/null 2>&1
}

write_config() {
    local port="$1"
    local password="$2"
    local use_socks="$3"
    local s_ip="$4"
    local s_port="$5"
    local s_user="$6"
    local s_pass="$7"
    local s_mode="$8"
    local conf_file="server_${port}.yaml"

    {
        cat <<EOF
listen: ":${port}"
tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${password}"
bandwidth:
  up: "${UP_BANDWIDTH}"
  down: "${DOWN_BANDWIDTH}"
quic:
  max_idle_timeout: "10s"
EOF

        if [ "$use_socks" = "y" ]; then
            cat <<EOF

outbounds:
  - name: socks_proxy
    type: socks5
    socks5:
      addr: "${s_ip}:${s_port}"
EOF
            if [ -n "$s_user" ] && [ -n "$s_pass" ]; then
                cat <<EOF
      username: "${s_user}"
      password: "${s_pass}"
EOF
            fi

            if [ "$s_mode" = "tcp_only" ]; then
                cat <<'EOF'
acl:
  inline:
    - socks_proxy(network:tcp)
    - direct(network:udp)
EOF
            else
                cat <<'EOF'
acl:
  inline:
    - socks_proxy(all)
EOF
            fi
        else
            cat <<'EOF'
acl:
  inline:
    - direct(all)
EOF
        fi
    } > "$conf_file"
    echo "✅ 写入配置 $conf_file 成功 (SOCKS代理: ${use_socks})。"
}

get_server_ip() {
    curl --max-time 10 https://api.ipify.org 2>/dev/null || echo "127.0.0.1"
}

main() {
    if [[ "${1:-}" == "del" ]] || [[ "${1:-}" == "--uninstall" ]]; then
        uninstall_files
        exit 0
    fi

    validate_config
    download_binary
    ensure_cert
    pkill -f "server -c server_.*\.yaml" 2>/dev/null || true

    for i in "${!NODE_PORTS[@]}"; do
        write_config "${NODE_PORTS[$i]}" "${NODE_PASSWORDS[$i]}" "${NODE_USE_SOCKS[$i]}" "${NODE_SOCKS_IPS[$i]}" "${NODE_SOCKS_PORTS[$i]}" "${NODE_SOCKS_USERS[$i]}" "${NODE_SOCKS_PASSWORDS[$i]}" "${NODE_SOCKS_MODES[$i]}"
    done
    
    start_hysteria
    SERVER_IP="$(get_server_ip)"
    
    echo "=========================================================================="
    echo "🎉 多节点部署完毕！"
    for i in "${!NODE_PORTS[@]}"; do
        echo "------------------------------------------------------"
        echo "🚀 节点 $((i+1)) (端口: ${NODE_PORTS[$i]})"
        if [ "${NODE_USE_SOCKS[$i]}" = "y" ]; then
            echo "   🔗 代理状态: 转发至 SOCKS5 -> ${NODE_SOCKS_IPS[$i]}:${NODE_SOCKS_PORTS[$i]} (${NODE_SOCKS_MODES[$i]})"
        else
            echo "   🔗 代理状态: 服务器直连"
        fi
        echo "   👉 订阅链接: hysteria2://${NODE_PASSWORDS[$i]}@${SERVER_IP}:${NODE_PORTS[$i]}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Node-$((i+1))"
    done
    echo "=========================================================================="
}

main "$@"
