#!/usr/bin/env bash
# ============================================================
# HY2 轻量化多节点管理脚本
# 功能：DIRECT / SOCKS5 出站、多节点、共享认证、systemd 开机启动
# 依赖：bash、curl、openssl、systemd；不需要 jq / Python / Docker
# 支持：Debian / Ubuntu / Rocky / AlmaLinux / CentOS Stream / Fedora
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -------------------------- 基础路径 --------------------------
HY2_HOME="/opt/hy2"
HY2_BIN="${HY2_HOME}/bin/hysteria"
NODES_DIR="${HY2_HOME}/nodes"
CERT_DIR="${HY2_HOME}/cert"
DATA_DIR="${HY2_HOME}/data"
AUTH_FILE="${DATA_DIR}/auth.password"
SERVER_ADDR_FILE="${DATA_DIR}/server.addr"
UPDATE_URL_FILE="${DATA_DIR}/script.raw_url"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"
SERVICE_FILE="/etc/systemd/system/hy2@.service"
SERVICE_PREFIX="hy2@"
SNI_HOST="www.bing.com"

# 当前脚本文件真实路径
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

# -------------------------- 输出函数 --------------------------
info()    { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()      { printf '\033[32m[成功]\033[0m %s\n' "$*"; }
warn()    { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
error()   { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }

pause() {
    echo
    read -r -p "按回车键返回菜单..." _ || true
}

# -------------------------- 环境检查 --------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 用户运行本脚本。"
        exit 1
    fi
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        error "没有检测到 systemctl。本脚本需要使用 systemd 管理节点。"
        exit 1
    fi

    if [[ ! -d /run/systemd/system ]]; then
        warn "当前环境看起来不是由 systemd 启动；请在正常的 VPS 系统中运行。"
        exit 1
    fi
}

# 自动安装必要依赖
install_missing_commands() {
    local missing=()
    local cmd

    for cmd in curl openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    info "正在安装缺少的依赖：${missing[*]}"

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y curl openssl ca-certificates

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl openssl ca-certificates

    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl openssl ca-certificates

    else
        error "无法识别包管理器，请手动安装 curl 和 openssl 后重新运行。"
        exit 1
    fi
}

# 根据 CPU 架构选择官方 HY2 核心
get_hy2_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armv7)
            echo "arm"
            ;;
        i386|i686)
            echo "386"
            ;;
        *)
            error "暂不支持当前 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac
}

# -------------------------- 核心安装 / 更新 --------------------------

install_or_update_core() {
    local arch url tmp old_version new_version

    arch="$(get_hy2_arch)" || return 1

    # 官方 latest 下载地址，不固定核心版本
    url="https://download.hysteria.network/app/latest/hysteria-linux-${arch}"

    mkdir -p "${HY2_HOME}/bin"

    tmp="$(mktemp "${HY2_HOME}/bin/hysteria.tmp.XXXXXX")"

    old_version="未安装"

    if [[ -x "$HY2_BIN" ]]; then
        old_version="$("$HY2_BIN" version 2>/dev/null | head -n 1 || echo 已安装)"
    fi

    info "正在从 Hysteria 官方下载地址获取最新核心..."
    info "CPU 架构：${arch}"

    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
        "$url" -o "$tmp"; then

        rm -f "$tmp"
        error "核心下载失败，请检查 VPS 网络后重试。"
        return 1
    fi

    chmod 755 "$tmp"

    # 检查新核心是否可以正常运行
    if ! "$tmp" version >/dev/null 2>&1; then
        rm -f "$tmp"
        error "下载的文件无法正常执行，已取消替换现有核心。"
        return 1
    fi

    # 验证通过以后才替换旧核心
    mv -f "$tmp" "$HY2_BIN"
    chmod 755 "$HY2_BIN"

    new_version="$("$HY2_BIN" version 2>/dev/null | head -n 1 || echo 已安装)"

    ok "Hysteria 核心已更新。"

    echo "旧版本：${old_version}"
    echo "新版本：${new_version}"

    # 仅重启当前正在运行的节点
    local d node_id unit

    for d in "${NODES_DIR}"/node-*; do
        [[ -d "$d" ]] || continue

        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"

        if systemctl is-active --quiet "$unit"; then
            systemctl restart "$unit" || warn "节点 ${node_id} 重启失败，请查看日志。"
        fi
    done
}

# -------------------------- 初始化配置 --------------------------

# 生成所有节点共用的密码
create_shared_auth() {
    if [[ ! -s "$AUTH_FILE" ]]; then
        openssl rand -hex 16 > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
    fi
}

# 生成自签名证书
create_self_signed_cert() {
    if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
        return 0
    fi

    info "正在生成自签名 TLS 证书（SNI：${SNI_HOST}）..."

    mkdir -p "$CERT_DIR"

    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=${SNI_HOST}" \
        -addext "subjectAltName=DNS:${SNI_HOST}" >/dev/null 2>&1

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
}

# 创建 systemd 通用节点模板
write_systemd_template() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Hysteria 2 Node (%i)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${HY2_BIN} server --config ${NODES_DIR}/%i/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload
}

# 初始化环境
initialize() {
    require_root
    require_systemd
    install_missing_commands

    mkdir -p "${HY2_HOME}/bin" "$NODES_DIR" "$CERT_DIR" "$DATA_DIR"

    chmod 700 "$HY2_HOME" "$DATA_DIR"

    if [[ ! -x "$HY2_BIN" ]]; then
        install_or_update_core
    fi

    create_shared_auth
    create_self_signed_cert
    write_systemd_template

    # 将共享密码加载到内存
    AUTH_PASS="$(cat "$AUTH_FILE")"
}

# -------------------------- 地址及 URI 工具 --------------------------

valid_server_addr() {
    local value="$1"

    [[ -n "$value" && "$value" != *[[:space:]/?#@]* ]]
}

# 自动获取公网 IP
get_public_ip() {
    local ip=""

    ip="$(curl -4 -fsS --connect-timeout 5 --max-time 8 \
        https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -6 -fsS --connect-timeout 5 --max-time 8 \
            https://api64.ipify.org 2>/dev/null || true)"
    fi

    printf '%s' "$ip"
}

# 第一次创建节点时设置连接地址
ensure_server_addr() {
    local current="" detected="" input=""

    if [[ -s "$SERVER_ADDR_FILE" ]]; then
        current="$(cat "$SERVER_ADDR_FILE")"

        if valid_server_addr "$current"; then
            return 0
        fi
    fi

    echo

    info "请输入客户端连接 VPS 时使用的公网 IP 或域名。"

    detected="$(get_public_ip)"

    if [[ -n "$detected" ]]; then
        read -r -p "连接地址 [自动检测：${detected}]：" input
        input="${input:-$detected}"
    else
        warn "自动检测公网 IP 失败，请手动输入域名或 IP。"
        read -r -p "连接地址：" input
    fi

    if ! valid_server_addr "$input"; then
        error "连接地址为空或格式不正确。"
        return 1
    fi

    printf '%s\n' "$input" > "$SERVER_ADDR_FILE"
    chmod 600 "$SERVER_ADDR_FILE"

    ok "连接地址已保存：${input}"
}

# IPv6 URI 格式处理
uri_host() {
    local host="$1"

    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

# URL 编码，处理中文、空格及特殊字符
url_encode() {
    local LC_ALL=C
    local input="$1"
    local output=""
    local ch code i

    for ((i = 0; i < ${#input}; i++)); do
        ch="${input:i:1}"

        case "$ch" in
            [a-zA-Z0-9.~_-])
                output+="$ch"
                ;;
            *)
                printf -v code '%%%02X' "'${ch}"
                output+="$code"
                ;;
        esac
    done

    printf '%s' "$output"
}

# 生成 HY2 分享链接
make_share_link() {
    local node_name="$1"
    local port="$2"
    local server_addr encoded_name

    server_addr="$(cat "$SERVER_ADDR_FILE")"
    server_addr="$(uri_host "$server_addr")"

    encoded_name="$(url_encode "$node_name")"

    printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1#%s' \
        "$AUTH_PASS" "$server_addr" "$port" "$SNI_HOST" "$encoded_name"
}

# -------------------------- 节点管理辅助函数 --------------------------

load_node_dirs() {
    NODE_DIRS=()

    local d

    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" ]] && NODE_DIRS+=("$d")
    done

    if ((${#NODE_DIRS[@]} == 0)); then
        return 1
    fi

    # 按 node-1、node-2、node-10 的自然顺序排列
    mapfile -t NODE_DIRS < <(
        printf '%s\n' "${NODE_DIRS[@]}" | sort -V
    )

    return 0
}

# 自动分配下一个节点编号
next_node_number() {
    local d base number max=0

    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" ]] || continue

        base="${d##*/node-}"

        if [[ "$base" =~ ^[0-9]+$ ]]; then
            number=$((10#$base))

            if ((number > max)); then
                max="$number"
            fi
        fi
    done

    echo $((max + 1))
}

# 检查已有节点是否使用此端口
node_port_exists() {
    local wanted="$1" d saved_port

    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" && -f "$d/port" ]] || continue

        saved_port="$(cat "$d/port")"

        [[ "$saved_port" == "$wanted" ]] && return 0
    done

    return 1
}

# 检查 UDP 端口是否已经被其他程序占用
udp_port_is_listening() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
        return $?
    fi

    return 1
}

# 选择节点
load_node_choice() {
    local choice index

    if ! load_node_dirs; then
        warn "目前还没有创建任何节点。"
        return 1
    fi

    echo
    echo "节点列表："

    local i d name port mode

    for i in "${!NODE_DIRS[@]}"; do
        d="${NODE_DIRS[$i]}"

        name="$(cat "$d/name")"
        port="$(cat "$d/port")"
        mode="$(cat "$d/mode")"

        printf '  %2d. %-20s  %-7s  UDP端口：%s\n' \
            "$((i + 1))" "$name" "$mode" "$port"
    done

    read -r -p "请输入节点序号：" choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
        warn "请输入正确的数字序号。"
        return 1
    fi

    index=$((10#$choice))

    if ((index < 1 || index > ${#NODE_DIRS[@]})); then
        warn "序号超出范围。"
        return 1
    fi

    SELECTED_NODE="${NODE_DIRS[$((index - 1))]}"

    return 0
}

# -------------------------- 创建节点 --------------------------

create_node() {
    local node_name port default_port node_num mode_choice mode
    local proxy_addr proxy_user proxy_pass proxy_port
    local node_id node_dir config_file quoted_addr quoted_user quoted_pass
    local unit

    ensure_server_addr || return 1

    node_num="$(next_node_number)"
    default_port=$((20000 + node_num))

    echo

    read -r -p "节点名称（例如 Google、Netflix）：" node_name

    if [[ -z "$node_name" || "$node_name" == */* ]]; then
        error "节点名称不能为空，也不能包含 /。"
        return 1
    fi

    read -r -p "UDP 监听端口 [${default_port}]：" port
    port="${port:-$default_port}"

    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then
        error "端口必须是 1 到 65535 之间的数字。"
        return 1
    fi

    port=$((10#$port))

    if ((port < 1 || port > 65535)); then
        error "端口范围必须为 1-65535。"
        return 1
    fi

    if node_port_exists "$port"; then
        error "本脚本已有节点使用 UDP 端口 ${port}。"
        return 1
    fi

    if udp_port_is_listening "$port"; then
        error "检测到 UDP 端口 ${port} 已被其他程序占用，请更换端口。"
        return 1
    fi

    echo
    echo "选择节点出口："
    echo "  1. DIRECT（VPS 本机直连）"
    echo "  2. SOCKS5（通过 SOCKS5 代理出站）"

    read -r -p "请选择 [1/2]：" mode_choice

    proxy_addr=""
    proxy_user=""
    proxy_pass=""

    case "$mode_choice" in
        1)
            mode="DIRECT"
            ;;
        2)
            mode="SOCKS5"

            while true; do
                read -r -p "SOCKS5 地址（例如 127.0.0.1:1080）：" proxy_addr

                if [[ "$proxy_addr" =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):([0-9]{1,5})$ ]]; then
                    proxy_port="${BASH_REMATCH[2]}"
                    proxy_port=$((10#$proxy_port))

                    if ((proxy_port >= 1 && proxy_port <= 65535)); then
                        break
                    fi
                fi

                warn "地址格式不正确，请使用 host:port 或 [IPv6]:port。"
            done

            read -r -p "SOCKS5 用户名（无认证直接回车）：" proxy_user

            if [[ -n "$proxy_user" ]]; then
                read -r -s -p "SOCKS5 密码：" proxy_pass
                echo

                if [[ -z "$proxy_pass" ]]; then
                    error "填写了用户名时，密码也不能为空。"
                    return 1
                fi
            fi
            ;;
        *)
            warn "选择无效，已取消创建。"
            return 1
            ;;
    esac

    node_id="node-${node_num}"
    node_dir="${NODES_DIR}/${node_id}"
    config_file="${node_dir}/config.yaml"
    unit="${SERVICE_PREFIX}${node_id}.service"

    mkdir -p "$node_dir"

    # 所有节点共享认证密码和 TLS 证书
    cat > "$config_file" <<EOF_CONFIG
listen: :${port}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: ${AUTH_PASS}

outbounds:
  - name: node_out
    type: ${mode,,}
EOF_CONFIG

    # SOCKS5 配置
    if [[ "$mode" == "SOCKS5" ]]; then

        quoted_addr="$(yaml_quote "$proxy_addr")"

        cat >> "$config_file" <<EOF_SOCKS
    socks5:
      addr: ${quoted_addr}
EOF_SOCKS

        if [[ -n "$proxy_user" ]]; then
            quoted_user="$(yaml_quote "$proxy_user")"
            quoted_pass="$(yaml_quote "$proxy_pass")"

            cat >> "$config_file" <<EOF_AUTH
      username: ${quoted_user}
      password: ${quoted_pass}
EOF_AUTH
        fi
    fi

    # 将该节点所有目标流量交给唯一 outbound
    cat >> "$config_file" <<'EOF_ACL'

acl:
  inline:
    - node_out(all)
EOF_ACL

    # 保存节点元数据
    printf '%s\n' "$node_name" > "${node_dir}/name"
    printf '%s\n' "$port" > "${node_dir}/port"
    printf '%s\n' "$mode" > "${node_dir}/mode"

    chmod 600 "$config_file"
    chmod 600 "${node_dir}/name" "${node_dir}/port" "${node_dir}/mode"

    # 启动节点并设置开机启动
    if ! systemctl enable --now "$unit"; then
        error "节点服务启动命令失败，最近日志："
        journalctl -u "$unit" -n 30 --no-pager || true
        return 1
    fi

    sleep 1

    if systemctl is-active --quiet "$unit"; then

        ok "节点创建成功并已启动：${node_name}"

        echo "出口类型：${mode}"
        echo "监听端口：${port}/UDP"
        echo "开机启动：已启用"

        echo
        echo "分享链接："

        make_share_link "$node_name" "$port"

        echo

        warn "请同时在 VPS 服务商防火墙/安全组放行 UDP ${port}。"

        if [[ "$mode" == "SOCKS5" ]]; then
            warn "SOCKS5 上游必须支持 UDP；否则 TCP 可能可用，但 UDP 流量无法正常转发。"
        fi

    else
        error "节点服务未能正常启动，配置文件已保留。"
        echo "最近日志："
        journalctl -u "$unit" -n 30 --no-pager || true
        return 1
    fi
}

# YAML 双引号字符串转义
yaml_quote() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    printf '"%s"' "$value"
}

# -------------------------- 查看节点 --------------------------

list_nodes() {
    local d node_id name port mode unit status

    if ! load_node_dirs; then
        warn "目前还没有创建任何节点。"
        return 0
    fi

    echo
    echo "============================== HY2 节点列表 =============================="

    for d in "${NODE_DIRS[@]}"; do

        node_id="${d##*/}"
        name="$(cat "$d/name")"
        port="$(cat "$d/port")"
        mode="$(cat "$d/mode")"

        unit="${SERVICE_PREFIX}${node_id}.service"

        if systemctl is-active --quiet "$unit"; then
            status="运行中"
        else
            status="已停止"
        fi

        echo
        echo "节点：${name}（${node_id}）"
        echo "出口：${mode}"
        echo "状态：${status}"
        echo "端口：${port}/UDP"

        echo "链接："

        make_share_link "$name" "$port"

        echo
    done

    echo "========================================================================="
}

# -------------------------- 删除节点 --------------------------

delete_node() {
    local node_id name unit

    if ! load_node_choice; then return 0; fi

    node_id="${SELECTED_NODE##*/}"
    name="$(cat "${SELECTED_NODE}/name")"
    unit="${SERVICE_PREFIX}${node_id}.service"

    echo

    read -r -p "确定删除节点「${name}」？请输入 yes 确认：" confirm

    if [[ "$confirm" != "yes" ]]; then
        warn "已取消删除。"
        return 0
    fi

    systemctl disable --now "$unit" >/dev/null 2>&1 || true

    rm -rf -- "$SELECTED_NODE"

    ok "节点 ${name} 已删除。"

    warn "脚本不会自动修改系统防火墙；如之前手动放行过 UDP 端口，可自行删除对应规则。"
}

# -------------------------- 批量服务管理 --------------------------

start_all_nodes() {
    local d node_id unit

    if ! load_node_dirs; then
        warn "没有可启动的节点。"
        return 0
    fi

    for d in "${NODE_DIRS[@]}"; do
        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"

        if systemctl enable --now "$unit"; then
            ok "已启动：${node_id}"
        else
            error "启动失败：${node_id}"
        fi
    done
}

stop_all_nodes() {
    local d node_id unit

    if ! load_node_dirs; then
        warn "没有可停止的节点。"
        return 0
    fi

    for d in "${NODE_DIRS[@]}"; do
        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"

        systemctl disable --now "$unit" >/dev/null 2>&1 || true

        info "已停止并取消开机启动：${node_id}"
    done

    ok "批量停止操作完成。"
}

restart_all_nodes() {
    local d node_id unit

    if ! load_node_dirs; then
        warn "没有可重启的节点。"
        return 0
    fi

    for d in "${NODE_DIRS[@]}"; do
        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"

        if systemctl enable --now "$unit"; then
            systemctl restart "$unit" && ok "已重启：${node_id}" || error "重启失败：${node_id}"
        else
            error "重启失败：${node_id}"
        fi
    done
}

# -------------------------- 查看日志 --------------------------

show_node_logs() {
    local node_id unit

    if ! load_node_choice; then return 0; fi

    node_id="${SELECTED_NODE##*/}"
    unit="${SERVICE_PREFIX}${node_id}.service"

    echo

    info "正在显示 ${node_id} 的实时日志，按 Ctrl+C 返回菜单。"

    journalctl -u "$unit" -n 50 -f || true
}

# -------------------------- 修改 SOCKS5 出站 --------------------------

update_socks_node() {
    local node_id name port mode unit proxy_addr proxy_port proxy_user proxy_pass
    local quoted_addr quoted_user quoted_pass tmp_config backup was_active=false

    if ! load_node_choice; then return 0; fi

    node_id="${SELECTED_NODE##*/}"
    name="$(cat "${SELECTED_NODE}/name")"
    port="$(cat "${SELECTED_NODE}/port")"
    mode="$(cat "${SELECTED_NODE}/mode")"
    unit="${SERVICE_PREFIX}${node_id}.service"

    if [[ "$mode" != "SOCKS5" ]]; then
        warn "所选节点「${name}」是 DIRECT 直连节点，没有 SOCKS5 配置可修改。"
        return 0
    fi

    echo

    info "正在修改节点「${name}」的 SOCKS5 上游。"

    while true; do
        read -r -p "新的 SOCKS5 地址（例如 127.0.0.1:1080）：" proxy_addr

        if [[ "$proxy_addr" =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):([0-9]{1,5})$ ]]; then

            proxy_port="${BASH_REMATCH[2]}"
            proxy_port=$((10#$proxy_port))

            if ((proxy_port >= 1 && proxy_port <= 65535)); then
                break
            fi
        fi

        warn "地址格式不正确，请使用 host:port 或 [IPv6]:port。"
    done

    read -r -p "新的 SOCKS5 用户名（无认证直接回车）：" proxy_user

    proxy_pass=""

    if [[ -n "$proxy_user" ]]; then
        read -r -s -p "新的 SOCKS5 密码：" proxy_pass
        echo

        if [[ -z "$proxy_pass" ]]; then
            error "填写了用户名时，密码也不能为空。"
            return 1
        fi
    fi

    quoted_addr="$(yaml_quote "$proxy_addr")"

    tmp_config="${SELECTED_NODE}/config.yaml.new"
    backup="${SELECTED_NODE}/config.yaml.bak"

    # 重新生成该节点配置
    cat > "$tmp_config" <<EOF_UPDATE
listen: :${port}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: ${AUTH_PASS}

outbounds:
  - name: node_out
    type: socks5
    socks5:
      addr: ${quoted_addr}
EOF_UPDATE

    if [[ -n "$proxy_user" ]]; then

        quoted_user="$(yaml_quote "$proxy_user")"
        quoted_pass="$(yaml_quote "$proxy_pass")"

        cat >> "$tmp_config" <<EOF_UPDATE_AUTH
      username: ${quoted_user}
      password: ${quoted_pass}
EOF_UPDATE_AUTH
    fi

    cat >> "$tmp_config" <<'EOF_UPDATE_ACL'

acl:
  inline:
    - node_out(all)
EOF_UPDATE_ACL

    chmod 600 "$tmp_config"

    # 先备份原配置，再替换
    cp -a "${SELECTED_NODE}/config.yaml" "$backup"
    mv -f "$tmp_config" "${SELECTED_NODE}/config.yaml"

    if systemctl is-active --quiet "$unit"; then

        was_active=true

        if systemctl restart "$unit" && systemctl is-active --quiet "$unit"; then

            rm -f "$backup"

            ok "节点「${name}」的 SOCKS5 配置已更新并重新启动。"

        else

            error "新配置启动失败，正在恢复旧配置..."

            mv -f "$backup" "${SELECTED_NODE}/config.yaml"

            systemctl restart "$unit" || true

            journalctl -u "$unit" -n 30 --no-pager || true

            return 1
        fi

    else

        rm -f "$backup"

        ok "节点「${name}」的 SOCKS5 配置已更新；该节点目前处于停止状态。"

    fi

    echo "新的 SOCKS5 上游：${proxy_addr}"

    if [[ "$was_active" == true ]]; then
        info "节点已恢复运行。"
    fi
}

# -------------------------- 修改分享地址 --------------------------

change_server_addr() {
    local old_addr="" new_addr=""

    [[ -s "$SERVER_ADDR_FILE" ]] && old_addr="$(cat "$SERVER_ADDR_FILE")"

    read -r -p "输入新的公网 IP/域名 [当前：${old_addr}]：" new_addr

    new_addr="${new_addr:-$old_addr}"

    if ! valid_server_addr "$new_addr"; then
        error "地址不能为空，也不能包含空格、路径或 URL 参数。"
        return 1
    fi

    printf '%s\n' "$new_addr" > "$SERVER_ADDR_FILE"
    chmod 600 "$SERVER_ADDR_FILE"

    ok "分享链接地址已更新。节点服务本身无需重启。"

    info "请进入「查看所有节点」重新复制分享链接。"
}

# -------------------------- 在线更新脚本 --------------------------

update_script() {
    local saved_url="" input_url="" tmp backup

    if [[ -z "$SCRIPT_PATH" || ! -f "$SCRIPT_PATH" || ! -w "$SCRIPT_PATH" ]]; then
        error "无法定位当前脚本文件。请先把脚本保存为 /root/hy2.sh，再执行它。"
        return 1
    fi

    [[ -s "$UPDATE_URL_FILE" ]] && saved_url="$(cat "$UPDATE_URL_FILE")"

    read -r -p "GitHub Raw 脚本地址 [${saved_url:-请粘贴 Raw URL}]：" input_url

    input_url="${input_url:-$saved_url}"

    if [[ ! "$input_url" =~ ^https:// ]]; then
        error "请提供 https:// 开头的 GitHub Raw 地址。"
        return 1
    fi

    tmp="$(mktemp)"

    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$input_url" -o "$tmp"; then
        rm -f "$tmp"
        error "脚本下载失败。"
        return 1
    fi

    # 更新前进行 Bash 语法检查
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        error "新脚本语法检查未通过，已保留当前脚本。"
        return 1
    fi

    backup="${SCRIPT_PATH}.bak"

    cp -a "$SCRIPT_PATH" "$backup"

    install -m 755 "$tmp" "${SCRIPT_PATH}.new"

    mv -f "${SCRIPT_PATH}.new" "$SCRIPT_PATH"

    rm -f "$tmp"

    printf '%s\n' "$input_url" > "$UPDATE_URL_FILE"
    chmod 600 "$UPDATE_URL_FILE"

    ok "脚本更新完成。旧版本备份：${backup}"

    info "重新运行脚本即可使用新版本。"
}

# -------------------------- 卸载 --------------------------

uninstall_all() {
    local d node_id unit

    echo

    warn "卸载将停止并删除所有 HY2 节点、认证密码、证书和核心文件。"

    warn "不会删除你保存的 hy2.sh 脚本文件，也不会自动清理系统/云厂商防火墙规则。"

    read -r -p "确定卸载全部内容？请输入大写 YES：" confirm

    if [[ "$confirm" != "YES" ]]; then
        warn "已取消卸载。"
        return 0
    fi

    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" ]] || continue

        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"

        systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done

    rm -f "$SERVICE_FILE"

    systemctl daemon-reload

    systemctl reset-failed >/dev/null 2>&1 || true

    rm -rf "$HY2_HOME"

    ok "HY2 管理脚本的数据、核心、节点服务及证书已卸载。"
}

# -------------------------- 主菜单 --------------------------

show_menu() {
    clear 2>/dev/null || true

    echo "================================================"
    echo "          HY2 轻量化多节点管理脚本"
    echo "================================================"
    echo "  1. 创建节点（DIRECT / SOCKS5）"
    echo "  2. 查看所有节点（显示分享链接）"
    echo "  3. 删除节点（按序号选择）"
    echo "  4. 启动所有节点（启用开机启动）"
    echo "  5. 停止所有节点（取消开机启动）"
    echo "  6. 重启所有节点"
    echo "  7. 查看节点实时日志"
    echo "  8. 修改 SOCKS5 节点的代理配置"
    echo "  9. 修改分享链接中的 VPS 地址"
    echo " 10. 更新 Hysteria 2 核心（自动获取最新版）"
    echo " 11. 在线更新本脚本（需要 GitHub Raw 地址）"
    echo " 12. 卸载全部节点及核心"
    echo "  0. 退出脚本"
    echo "================================================"

    if [[ -x "$HY2_BIN" ]]; then
        printf '当前核心：%s\n' "$("$HY2_BIN" version 2>/dev/null | head -n 1 || echo 未知)"
    fi

    echo
}

# -------------------------- 主程序 --------------------------

main() {
    initialize

    while true; do

        show_menu

        read -r -p "请输入选项 [0-12]：" choice || exit 0

        case "$choice" in

            1)
                create_node
                pause
                ;;

            2)
                list_nodes
                pause
                ;;

            3)
                delete_node
                pause
                ;;

            4)
                start_all_nodes
                pause
                ;;

            5)
                stop_all_nodes
                pause
                ;;

            6)
                restart_all_nodes
                pause
                ;;

            7)
                show_node_logs
                pause
                ;;

            8)
                update_socks_node
                pause
                ;;

            9)
                change_server_addr
                pause
                ;;

            10)
                install_or_update_core
                pause
                ;;

            11)
                update_script
                pause
                ;;

            12)
                uninstall_all
                exit 0
                ;;

            0)
                exit 0
                ;;

            *)
                warn "无效选项，请输入 0-12。"
                sleep 1
                ;;
        esac
    done
}

main "$@"