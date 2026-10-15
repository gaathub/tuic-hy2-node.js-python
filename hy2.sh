#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 多节点部署脚本 (交互式菜单版 + 节点独立代理支持)

# ==========================================
# 请将这里的 URL 替换为你自己托管该脚本的真实直链（例如 Github Raw 链接）
UPDATE_URL="https://raw.githubusercontent.com/gaathub/tuic-hy2-node.js-python/refs/heads/main/hy2.sh"
# ==========================================

# 默认全局配置
HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.5}"
CERT_FILE="cert.pem"             
KEY_FILE="key.pem"                
SNI="www.bing.com"                     
ALPN="h3"
UP_BANDWIDTH="200mbps"
DOWN_BANDWIDTH="200mbps"
BIN_PATH="./hysteria-linux-amd64" # 默认先占位，后续动态检测

# 动态配置数组 (交互式收录)
NODE_PORTS=()
NODE_PASSWORDS=()
NODE_USE_SOCKS=()
NODE_SOCKS_IPS=()
NODE_SOCKS_PORTS=()
NODE_SOCKS_USERS=()
NODE_SOCKS_PASSWORDS=()
NODE_SOCKS_MODES=()

echo "======================================================"
echo "  Hysteria2 多节点部署管理脚本 (支持节点独立 SOCKS5)"
echo "======================================================"

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
    else echo "❌ 未找到支持的包管理器，无法自动安装 openssl。"; exit 1; fi
    
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

# 在线更新脚本
update_script() {
    echo "🔄 正在从远程获取最新脚本..."
    if curl -sSL -o hy2_update.sh "$UPDATE_URL"; then
        mv hy2_update.sh hy2.sh
        chmod +x hy2.sh
        echo "✅ 脚本更新成功！请重新运行 bash hy2.sh"
        exit 0
    else
        echo "❌ 更新失败！请检查 UPDATE_URL 是否正确或网络是否畅通。"
        rm -f hy2_update.sh
        exit 1
    fi
}

# 卸载清理
uninstall_files() {
    echo "🗑️  开始清理旧的 Hysteria2 相关文件和进程..."
    pkill -f "server -c server_.*\.yaml" 2>/dev/null || true
    rm -f hysteria_*.pid hysteria_*.log server_*.yaml
    rm -f "${CERT_FILE}" "${KEY_FILE}" hysteria-linux-amd64 hysteria-linux-arm64
    echo "✅ 卸载/清理完成。"
}

# 交互式配置收集
interactive_config() {
    echo ""
    read -p "请输入你想部署的节点总数 (例如 3): " node_count
    if ! [[ "$node_count" =~ ^[0-9]+$ ]] || [ "$node_count" -le 0 ]; then
        echo "❌ 节点数必须是大于 0 的数字！"
        exit 1
    fi

    for (( i=1; i<=node_count; i++ )); do
        echo "------------------------------------------------------"
        echo "📡 正在配置第 $i 个节点"
        
        # 1. 端口
        while true; do
            read -p "👉 监听端口 (1-65535): " port
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then break; fi
            echo "⚠️ 端口无效，请重新输入"
        done
        NODE_PORTS+=("$port")

        # 2. 密码
        read -p "👉 连接密码 [回车默认: ieshare2025]: " pwd
        NODE_PASSWORDS+=("${pwd:-ieshare2025}")

        # 3. 代理设置
        read -p "👉 是否套 SOCKS5 代理? (y/n) [回车默认: n]: " use_socks
        use_socks=${use_socks:-n}
        
        if [[ "${use_socks,,}" == "y" ]]; then
            NODE_USE_SOCKS+=("y")
            
            read -p "   - 代理 IP (本机代理填 127.0.0.1): " s_ip
            NODE_SOCKS_IPS+=("${s_ip}")
            
            read -p "   - 代理端口: " s_port
            NODE_SOCKS_PORTS+=("${s_port}")
            
            read -p "   - 代理账号 (没有直接回车): " s_user
            NODE_SOCKS_USERS+=("${s_user}")
            
            read -p "   - 代理密码 (没有直接回车): " s_pass
            NODE_SOCKS_PASSWORDS+=("${s_pass}")
            
            echo "   - 代理模式: 1) 仅TCP代理(推荐)  2) TCP/UDP全代理"
            read -p "   请输入选择 [回车默认: 1]: " s_mode
            if [ "$s_mode" = "2" ]; then
                NODE_SOCKS_MODES+=("all_proxy")
            else
                NODE_SOCKS_MODES+=("tcp_only")
            fi
        else
            NODE_USE_SOCKS+=("n")
            NODE_SOCKS_IPS+=("")
            NODE_SOCKS_PORTS+=("")
            NODE_SOCKS_USERS+=("")
            NODE_SOCKS_PASSWORDS+=("")
            NODE_SOCKS_MODES+=("")
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
    if [ -f "$BIN_PATH" ]; then echo "✅ 二进制核心已存在，跳过下载。"; return; fi
    local url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${arch}"
    echo "⏳ 正在下载 Hysteria2 核心组件..."
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
}

start_nodes() {
    download_binary
    ensure_cert
    # 杀掉旧的 Hysteria 进程避免端口占用
    pkill -f "server -c server_.*\.yaml" 2>/dev/null || true

    echo "======================================================"
    for i in "${!NODE_PORTS[@]}"; do
        local port="${NODE_PORTS[$i]}"
        local pid_file="hysteria_${port}.pid"
        local log_file="hysteria_${port}.log"
        local conf_file="server_${port}.yaml"

        write_config "${NODE_PORTS[$i]}" "${NODE_PASSWORDS[$i]}" "${NODE_USE_SOCKS[$i]}" "${NODE_SOCKS_IPS[$i]}" "${NODE_SOCKS_PORTS[$i]}" "${NODE_SOCKS_USERS[$i]}" "${NODE_SOCKS_PASSWORDS[$i]}" "${NODE_SOCKS_MODES[$i]}"
        
        nohup "$BIN_PATH" server -c "$conf_file" >"$log_file" 2>&1 &
        echo $! > "$pid_file"
        sleep 1

        if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            echo "✅ 节点 $port 已启动"
        else
            echo "❌ 节点 $port 启动失败"
        fi
    done
}

show_links() {
    local ip=$(curl -s --max-time 10 https://api.ipify.org || echo "127.0.0.1")
    echo "======================================================"
    echo "🎉 部署完毕！分享链接如下："
    for i in "${!NODE_PORTS[@]}"; do
        echo "------------------------------------------------------"
        echo "🚀 节点 $((i+1)) (端口: ${NODE_PORTS[$i]})"
        if [ "${NODE_USE_SOCKS[$i]}" = "y" ]; then
            echo "   🔗 代理状态: 转发至 SOCKS5 -> ${NODE_SOCKS_IPS[$i]}:${NODE_SOCKS_PORTS[$i]} (${NODE_SOCKS_MODES[$i]})"
        else
            echo "   🔗 代理状态: 服务器直连"
        fi
        echo "   👉 订阅链接: hysteria2://${NODE_PASSWORDS[$i]}@${ip}:${NODE_PORTS[$i]}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Node-$((i+1))"
    done
    echo "======================================================"
}

# ================= 主菜单 =================
echo "1. 交互式部署多节点 (支持各自独立代理)"
echo "2. 卸载并清理所有节点"
echo "3. 在线更新本脚本"
echo "0. 退出"
read -p "请选择数字 [0-3]: " choice

case $choice in
    1)
        interactive_config
        start_nodes
        show_links
        ;;
    2)
        uninstall_files
        ;;
    3)
        update_script
        ;;
    0|*)
        echo "已退出。"
        exit 0
        ;;
esac
