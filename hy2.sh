#!/usr/bin/env bash
# ============================================================
# Hysteria2 多节点管理脚本 v2.0.0
# 功能：多节点、每节点独立 DIRECT/SOCKS5、在线更新、开机自启、彻底卸载
# 依赖：bash、curl、openssl；不需要 jq / Python / Docker
# ============================================================

set -Eeuo pipefail
umask 077

# ======================== 用户可修改区域 ========================
SCRIPT_VERSION="2.0.0"

# 在线更新地址：将下面地址改成你自己仓库中 hy2.sh 的 Raw 地址
# 例如：https://raw.githubusercontent.com/用户名/仓库名/main/hy2.sh
UPDATE_URL="https://raw.githubusercontent.com/你的用户名/你的仓库/main/hy2.sh"

# 固定数据目录。旧版如果使用了自定义 HY2_BASE_DIR，卸载前需确认旧目录。
HY2_BASE_DIR="${HY2_BASE_DIR:-/opt/hy2-multi}"

HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.5}"
SNI="${SNI:-www.bing.com}"
ALPN="${ALPN:-h3}"
UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"

SERVICE_NAME="hy2-multi.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
# ===============================================================

BASE_DIR="$HY2_BASE_DIR"
NODES_DIR="$BASE_DIR/nodes"
AUTH_FILE="$BASE_DIR/hy2-uuid.conf"
CERT_FILE="$BASE_DIR/cert.pem"
KEY_FILE="$BASE_DIR/key.pem"
BIN_PATH="$BASE_DIR/hysteria-linux-$(uname -m 2>/dev/null | sed -E 's/x86_64/amd64/;s/aarch64/arm64/')"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_PATH=""
[[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]] && SCRIPT_PATH="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")"

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
REPLY=""

has_cmd(){ command -v "$1" >/dev/null 2>&1; }
ensure_root(){ [[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行：bash $0"; exit 1; }; }
pause_enter(){ [[ -t 0 ]] && { read -r -p $'\n按回车键继续...' _ || true; }; }
read_value(){
    local prompt="$1" def="${2:-}" value=""
    if [[ -n "$def" ]]; then read -r -p "$prompt [$def]: " value; REPLY="${value:-$def}"
    else read -r -p "$prompt: " value; REPLY="$value"; fi
}
read_secret(){ local value=""; read -r -s -p "$1: " value; printf '\n'; REPLY="$value"; }
ask_yes_no(){
    local prompt="$1" def="${2:-n}" value="" hint="y/N"
    [[ "$def" == "y" ]] && hint="Y/n"
    while true; do
        read -r -p "$prompt [$hint]: " value
        value="${value:-$def}"
        case "${value,,}" in y|yes) REPLY=y; return;; n|no) REPLY=n; return;; *) echo "请输入 y 或 n。";; esac
    done
}
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_node_name(){ [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$ ]]; }
yaml_quote(){
    local v="$1"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//$'\r'/}"; v="${v//$'\n'/\\n}"
    printf '"%s"' "$v"
}
normalize_host_port(){
    local host="$1" port="$2"
    if [[ "$host" == \[*\] ]]; then printf '%s:%s' "$host" "$port"
    elif [[ "$host" == *:* ]]; then printf '[%s]:%s' "$host" "$port"
    else printf '%s:%s' "$host" "$port"; fi
}

install_missing_dependencies(){
    local missing=()
    has_cmd curl || missing+=(curl)
    has_cmd openssl || missing+=(openssl)
    ((${#missing[@]} == 0)) && return 0
    echo "需要安装依赖：${missing[*]}"
    if has_cmd apt-get; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    elif has_cmd dnf; then dnf install -y "${missing[@]}"
    elif has_cmd yum; then yum install -y "${missing[@]}"
    elif has_cmd apk; then apk add --no-cache "${missing[@]}"
    elif has_cmd zypper; then zypper --non-interactive install "${missing[@]}"
    else echo "找不到包管理器，请手动安装 curl 和 openssl。" >&2; return 1; fi
}
get_arch(){
    case "$(uname -m | tr '[:upper:]' '[:lower:]')" in
        x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) return 1;;
    esac
}
generate_uuid(){
    local u=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then IFS= read -r u < /proc/sys/kernel/random/uuid || true
    elif has_cmd uuidgen; then u="$(uuidgen 2>/dev/null || true)"
    else u="$(openssl rand -hex 16)"; u="${u:0:8}-${u:8:4}-4${u:13:3}-8${u:17:3}-${u:20:12}"; fi
    u="${u,,}"
    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
    printf '%s\n' "$u"
}
ensure_uuid(){
    local saved=""
    mkdir -p "$BASE_DIR"
    [[ -f "$AUTH_FILE" ]] && IFS= read -r saved < "$AUTH_FILE" || true
    if [[ "$saved" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        AUTH_UUID="${saved,,}"; chmod 600 "$AUTH_FILE"; return
    fi
    AUTH_UUID="$(generate_uuid)"
    printf '%s\n' "$AUTH_UUID" > "$AUTH_FILE"; chmod 600 "$AUTH_FILE"
    echo "已生成公共 UUID：$AUTH_UUID"
}
ensure_binary(){
    local arch name url tmp
    arch="$(get_arch)" || { echo "不支持 CPU 架构：$(uname -m)" >&2; return 1; }
    name="hysteria-linux-${arch}"; BIN_PATH="$BASE_DIR/$name"
    [[ -x "$BIN_PATH" ]] && return 0
    url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${name}"
    tmp="${BIN_PATH}.download"
    echo "正在下载 Hysteria2 ${HYSTERIA_VERSION}..."
    curl -fL --retry 3 --connect-timeout 30 -o "$tmp" "$url" || { rm -f "$tmp"; echo "内核下载失败：$url" >&2; return 1; }
    chmod 755 "$tmp"; mv -f "$tmp" "$BIN_PATH"
}
ensure_certificate(){
    [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] && { chmod 600 "$KEY_FILE"; return; }
    echo "正在生成共享自签名证书（SNI：$SNI）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}" >/dev/null 2>&1
    chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"
}
ensure_common_files(){
    ensure_root; install_missing_dependencies
    mkdir -p "$NODES_DIR"
    ensure_uuid; ensure_binary; ensure_certificate
}

save_node_meta(){
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
load_node(){
    local name="$1"
    valid_node_name "$name" || { echo "节点名称不合法。" >&2; return 1; }
    NODE_DIR="$NODES_DIR/$name"
    [[ -f "$NODE_DIR/node.conf" ]] || { echo "找不到节点：$name" >&2; return 1; }
    # node.conf 由脚本自身用 printf %q 生成，且仅 root 可读写。
    # shellcheck disable=SC1090
    source "$NODE_DIR/node.conf"
}
port_already_managed(){
    local wanted="$1" f p
    shopt -s nullglob
    for f in "$NODES_DIR"/*/node.conf; do
        p="$( ( unset NODE_PORT; source "$f"; printf '%s' "${NODE_PORT:-}" ) )"
        [[ "$p" == "$wanted" ]] && { shopt -u nullglob; return 0; }
    done
    shopt -u nullglob; return 1
}
port_in_use(){
    local p="$1"
    if has_cmd ss; then ss -H -lntu "sport = :$p" 2>/dev/null | grep -q .
    elif has_cmd lsof; then lsof -nP -iTCP:"$p" -iUDP:"$p" >/dev/null 2>&1
    else return 1; fi
}
choose_port(){
    local v def="${1:-22222}"
    while true; do
        read_value "请输入 Hysteria2 监听端口（UDP）" "$def"; v="$REPLY"
        if ! valid_port "$v"; then echo "端口必须为 1-65535。"
        elif port_already_managed "$v"; then echo "该端口已被本脚本节点使用。"
        elif port_in_use "$v"; then echo "该端口已被系统程序占用。"
        else NODE_PORT="$v"; return; fi
    done
}
write_node_config(){
    local addr=""
    mkdir -p "$NODE_DIR"
    {
        printf 'listen: %s\n' "$(yaml_quote ":${NODE_PORT}")"
        printf 'tls:\n  cert: %s\n  key: %s\n  alpn:\n    - %s\n' \
            "$(yaml_quote "$CERT_FILE")" "$(yaml_quote "$KEY_FILE")" "$(yaml_quote "$ALPN")"
        printf 'auth:\n  type: "password"\n  password: %s\n' "$(yaml_quote "$AUTH_UUID")"
        printf 'bandwidth:\n  up: %s\n  down: %s\n' "$(yaml_quote "$UP_BANDWIDTH")" "$(yaml_quote "$DOWN_BANDWIDTH")"
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
                printf '      username: %s\n      password: %s\n' "$(yaml_quote "$SOCKS_USER")" "$(yaml_quote "$SOCKS_PASS")"
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

node_is_running(){
    local pid="" cmd=""
    [[ -f "$NODE_DIR/hysteria.pid" ]] || return 1
    IFS= read -r pid < "$NODE_DIR/hysteria.pid" || true
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmd" == *"$NODE_DIR/server.yaml"* && "$cmd" == *hysteria* ]]
}
start_node(){
    local name="$1" pid=""
    load_node "$name" || return 1
    ensure_binary
    if node_is_running; then
        touch "$NODE_DIR/autostart"; echo "节点 $name 已运行，PID：$(cat "$NODE_DIR/hysteria.pid")"; return
    fi
    rm -f "$NODE_DIR/hysteria.pid"
    [[ -s "$AUTH_FILE" ]] || { echo "UUID 文件不存在，请先创建节点或修复数据目录。"; return 1; }
    if [[ ! -f "$NODE_DIR/server.yaml" ]]; then
        IFS= read -r AUTH_UUID < "$AUTH_FILE"
        write_node_config
    fi
    echo "正在启动节点 $name（UDP/$NODE_PORT）..."
    nohup "$BIN_PATH" server -c "$NODE_DIR/server.yaml" > "$NODE_DIR/hysteria.log" 2>&1 </dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$NODE_DIR/hysteria.pid"
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        touch "$NODE_DIR/autostart"
        echo "节点 $name 已启动，PID：$pid"
    else
        rm -f "$NODE_DIR/hysteria.pid"
        echo "启动失败，最近日志："; tail -n 50 "$NODE_DIR/hysteria.log" 2>/dev/null || true
        return 1
    fi
}
stop_node(){
    local name="$1" pid="" i
    load_node "$name" || return 1
    rm -f "$NODE_DIR/autostart"
    if ! node_is_running; then rm -f "$NODE_DIR/hysteria.pid"; echo "节点 $name 当前未运行。"; return; fi
    IFS= read -r pid < "$NODE_DIR/hysteria.pid" || true
    echo "正在停止节点 $name（PID：$pid）..."
    kill "$pid" 2>/dev/null || true
    for ((i=0;i<10;i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then
        # 再次验证命令行，防止 PID 被复用后误杀其他进程。
        if [[ "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)" == *"$NODE_DIR/server.yaml"* ]]; then kill -9 "$pid" 2>/dev/null || true; fi
    fi
    rm -f "$NODE_DIR/hysteria.pid"
    echo "节点 $name 已停止；已取消该节点的开机自动启动标记。"
}
restart_node(){ stop_node "$1" && start_node "$1"; }
list_nodes(){
    local f name status proxy mode pid
    shopt -s nullglob; local files=("$NODES_DIR"/*/node.conf); shopt -u nullglob
    ((${#files[@]})) || { echo "目前没有节点。"; return; }
    printf '\n%-18s %-9s %-10s %-22s %-12s %-8s\n' "节点" "UDP端口" "状态" "SOCKS5" "代理模式" "开机启动"
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        name="${NODE_NAME:-$(basename "$(dirname "$f")")}"
        NODE_DIR="$(dirname "$f")"; status="已停止"; pid=""
        if node_is_running; then status="运行中"; fi
        proxy="DIRECT"; [[ "${USE_SOCKS5:-n}" == y ]] && proxy="${SOCKS_HOST}:${SOCKS_PORT}"
        mode="${PROXY_MODE:-direct}"; [[ -f "$NODE_DIR/autostart" ]] && auto="是" || auto="否"
        printf '%-18s %-9s %-10s %-22s %-12s %-8s\n' "$name" "${NODE_PORT:-?}" "$status" "$proxy" "$mode" "$auto"
    done
}
ask_node_name(){ read_value "请输入节点名称"; }
delete_node(){
    local name="$1" dir="$NODES_DIR/$1"
    load_node "$name" || return 1
    echo "即将删除节点 $name（仅删除此节点，不影响其他节点/公共证书）。"
    ask_yes_no "确认删除" n
    [[ "$REPLY" == y ]] || { echo "已取消。"; return; }
    stop_node "$name" || true
    rm -rf -- "$dir"
    echo "节点 $name 已删除。"
}
show_logs(){
    load_node "$1" || return 1
    [[ -f "$NODE_DIR/hysteria.log" ]] || { echo "该节点暂无日志。"; return; }
    echo "按 Ctrl+C 返回菜单。"; tail -n 100 -f "$NODE_DIR/hysteria.log"
}
show_uuid(){ ensure_uuid; echo "公共 UUID：$AUTH_UUID"; echo "文件：$AUTH_FILE"; }
get_server_ip(){
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    printf '%s' "${ip:-请手动填写服务器IP}"
}
print_link(){
    local ip="$1" url_ip="$1"
    [[ "$url_ip" == *:* && "$url_ip" != \[*\] ]] && url_ip="[$url_ip]"
    printf 'hysteria2://%s@%s:%s?sni=%s&alpn=%s&insecure=1#Hy2-%s\n' "$AUTH_UUID" "$url_ip" "$NODE_PORT" "$SNI" "$ALPN" "$NODE_NAME"
}
create_node(){
    ensure_common_files
    local name ip mode
    echo "创建节点（名称仅允许英文、数字、点、下划线、短横线）。"
    while true; do
        read_value "节点名称" "A"; name="$REPLY"
        if ! valid_node_name "$name"; then echo "名称不合法。"
        elif [[ -e "$NODES_DIR/$name" ]]; then echo "节点已存在。"
        else break; fi
    done
    NODE_NAME="$name"; NODE_DIR="$NODES_DIR/$name"
    choose_port 22222
    echo "出口方式：1.DIRECT  2.本机 SOCKS5  3.远程 SOCKS5"
    while true; do
        read_value "请选择" "1"
        case "$REPLY" in
            1) USE_SOCKS5=n; SOCKS_HOST=""; SOCKS_USER=""; SOCKS_PASS=""; break;;
            2) USE_SOCKS5=y; SOCKS_HOST=127.0.0.1; break;;
            3) USE_SOCKS5=y; read_value "SOCKS5 地址（域名/IP/IPv6）"; SOCKS_HOST="$REPLY"; [[ -n "$SOCKS_HOST" ]] && break; echo "地址不能为空。";;
            *) echo "请输入 1、2 或 3。";;
        esac
    done
    if [[ "$USE_SOCKS5" == y ]]; then
        read_value "SOCKS5 端口" 1080
        while ! valid_port "$REPLY"; do echo "端口无效。"; read_value "SOCKS5 端口" 1080; done
        SOCKS_PORT="$REPLY"
        ask_yes_no "是否需要用户名密码认证" n
        if [[ "$REPLY" == y ]]; then
            read_value "SOCKS5 用户名"; SOCKS_USER="$REPLY"
            read_secret "SOCKS5 密码"; SOCKS_PASS="$REPLY"
            [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]] || { echo "用户名和密码不能为空。"; return 1; }
        else SOCKS_USER=""; SOCKS_PASS=""; fi
        echo "代理模式：1.仅 TCP 走 SOCKS5，UDP 直连  2.TCP/UDP 尽可能走 SOCKS5"
        read_value "请选择" 2
        while [[ "$REPLY" != 1 && "$REPLY" != 2 ]]; do read_value "请输入 1 或 2" 2; done
        [[ "$REPLY" == 2 ]] && PROXY_MODE=all_proxy || PROXY_MODE=tcp_only
    else SOCKS_PORT=1080; SOCKS_USER=""; SOCKS_PASS=""; PROXY_MODE=all_proxy; fi
    save_node_meta
    IFS= read -r AUTH_UUID < "$AUTH_FILE"
    write_node_config
    echo "节点配置已生成：$NODE_DIR/server.yaml"
    echo "端口：$NODE_PORT/UDP；出站：$([[ "$USE_SOCKS5" == y ]] && echo "$SOCKS_HOST:$SOCKS_PORT ($PROXY_MODE)" || echo DIRECT)"
    ask_yes_no "立即启动节点" y
    [[ "$REPLY" == y ]] && start_node "$NODE_NAME"
    ip="$(get_server_ip)"
    echo "节点分享链接："; print_link "$ip"
    echo "请在 VPS/云厂商防火墙放行 UDP $NODE_PORT。"
}

# ----------- 开机自启：systemd oneshot + 每节点 autostart 标记 -----------
write_boot_helpers(){
    mkdir -p "$BASE_DIR"
    cat > "$BASE_DIR/start-all.sh" <<'START'
#!/usr/bin/env bash
set -u
BASE="__BASE__"
NODES="$BASE/nodes"
BIN="__BIN__"
shopt -s nullglob
for conf in "$NODES"/*/node.conf; do
    dir="$(dirname "$conf")"
    [[ -f "$dir/autostart" && -f "$dir/server.yaml" ]] || continue
    if [[ -f "$dir/hysteria.pid" ]]; then
        pid="$(cat "$dir/hysteria.pid" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
            [[ "$cmd" == *"$dir/server.yaml"* ]] && continue
        fi
    fi
    rm -f "$dir/hysteria.pid"
    nohup "$BIN" server -c "$dir/server.yaml" >> "$dir/hysteria.log" 2>&1 </dev/null &
    echo "$!" > "$dir/hysteria.pid"
done
exit 0
START
    cat > "$BASE/stop-all.sh" <<'STOP'
#!/usr/bin/env bash
set -u
BASE="__BASE__"
NODES="$BASE/nodes"
shopt -s nullglob
for conf in "$NODES"/*/node.conf; do
    dir="$(dirname "$conf")"
    [[ -f "$dir/hysteria.pid" ]] || continue
    pid="$(cat "$dir/hysteria.pid" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$dir/hysteria.pid"; continue; }
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmd" == *"$dir/server.yaml"* && "$cmd" == *hysteria* ]]; then
        kill "$pid" 2>/dev/null || true
        for _ in {1..8}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        if kill -0 "$pid" 2>/dev/null; then
            cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
            [[ "$cmd" == *"$dir/server.yaml"* ]] && kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$dir/hysteria.pid"
done
STOP
    # 将路径安全写入生成脚本
    sed -i "s|__BASE__|$BASE_DIR|g; s|__BIN__|$BIN_PATH|g" "$BASE_DIR/start-all.sh" "$BASE_DIR/stop-all.sh"
    chmod 700 "$BASE_DIR/start-all.sh" "$BASE_DIR/stop-all.sh"
}
enable_autostart(){
    ensure_root
    ensure_common_files
    local f dir
    shopt -s nullglob
    local configs=("$NODES_DIR"/*/node.conf)
    shopt -u nullglob
    ((${#configs[@]})) || { echo "还没有节点，先创建节点。"; return 1; }
    # 第一次启用时，把当前正在运行的节点标记为开机启动，避免擅自启动用户曾停止的节点。
    for f in "${configs[@]}"; do
        dir="$(dirname "$f")"
        if [[ -f "$dir/hysteria.pid" ]]; then
            local p c
            p="$(cat "$dir/hysteria.pid" 2>/dev/null || true)"
            if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then
                c="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
                [[ "$c" == *"$dir/server.yaml"* ]] && touch "$dir/autostart"
            fi
        fi
    done
    write_boot_helpers
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria2 Multi Node Auto Start
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $BASE_DIR/start-all.sh
ExecStop=/bin/bash $BASE_DIR/stop-all.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME"
    echo "已启用 VPS 重启自动启动。当前带 autostart 标记的节点会在开机时启动。"
}
disable_autostart(){
    ensure_root
    if has_cmd systemctl; then
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        # 只取消下次开机启动，不停止当前节点。
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    echo "已取消全局开机自启；节点和配置仍保留。"
}
update_script(){
    ensure_root
    if [[ -z "$SCRIPT_PATH" || ! -f "$SCRIPT_PATH" || "$SCRIPT_PATH" == /dev/fd/* ]]; then
        echo "无法定位当前脚本文件。请先保存为文件再运行在线更新。"; return 1
    fi
    if [[ -z "$UPDATE_URL" || "$UPDATE_URL" == *"你的用户名"* || "$UPDATE_URL" == *"你的仓库"* ]]; then
        echo "请先在脚本顶部填写真实 UPDATE_URL。"; return 1
    fi
    local tmp backup
    tmp="$(mktemp "${SCRIPT_PATH}.new.XXXXXX")"
    backup="${SCRIPT_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    echo "正在下载更新..."
    if ! curl -fL --retry 2 --connect-timeout 20 -o "$tmp" "$UPDATE_URL"; then
        rm -f "$tmp"; echo "下载失败，当前脚本未更改。"; return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"; echo "新脚本语法检查失败，当前脚本未更改。"; return 1
    fi
    if ! grep -q '^SCRIPT_VERSION=' "$tmp"; then
        rm -f "$tmp"; echo "下载文件未检测到版本字段，拒绝更新。"; return 1
    fi
    cp -a "$SCRIPT_PATH" "$backup"
    chmod 700 "$tmp"
    if mv -f "$tmp" "$SCRIPT_PATH"; then
        echo "更新成功。旧版本备份：$backup"
        echo "请退出当前菜单并重新运行脚本，以加载新版本。"
    else
        echo "替换失败，备份位于：$backup"; rm -f "$tmp"; return 1
    fi
}
uninstall_all(){
    ensure_root
    echo "警告：彻底卸载将删除本脚本管理的全部节点、UUID、证书、内核和配置。"
    echo "数据目录：$BASE_DIR"
    echo "systemd 服务：$SERVICE_NAME"
    ask_yes_no "确定彻底卸载？此操作不可恢复" n
    [[ "$REPLY" == y ]] || { echo "已取消。"; return; }

    # 先停止并移除本脚本专用 systemd 服务
    if has_cmd systemctl; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 只根据节点目录中的 server.yaml 路径识别进程，不使用 pkill hysteria。
    local conf dir pid cmd
    shopt -s nullglob
    local configs=("$NODES_DIR"/*/node.conf)
    shopt -u nullglob
    for conf in "${configs[@]}"; do
        dir="$(dirname "$conf")"
        [[ -f "$dir/hysteria.pid" ]] || continue
        pid="$(cat "$dir/hysteria.pid" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
            if [[ "$cmd" == *"$dir/server.yaml"* && "$cmd" == *hysteria* ]]; then
                kill "$pid" 2>/dev/null || true
                for _ in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
                if kill -0 "$pid" 2>/dev/null; then
                    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
                    [[ "$cmd" == *"$dir/server.yaml"* ]] && kill -9 "$pid" 2>/dev/null || true
                fi
            fi
        fi
    done

    # 删除本脚本专属数据目录（仅当路径为预期的绝对路径且不是根目录）
    if [[ "$BASE_DIR" == /* && "$BASE_DIR" != "/" && "$BASE_DIR" != "/opt" && "$BASE_DIR" != "/root" ]]; then
        rm -rf -- "$BASE_DIR"
    else
        echo "安全检查阻止删除异常数据目录：$BASE_DIR" >&2
        return 1
    fi
    # 删除当前脚本文件；如果是通过管道运行则 SCRIPT_PATH 为空，不会删除其他文件。
    if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then rm -f -- "$SCRIPT_PATH"; fi
    echo "彻底卸载完成。系统 curl、openssl 及其他程序未被删除。"
    exit 0
}

print_help(){
    cat <<EOF
Hysteria2 多节点管理脚本 v${SCRIPT_VERSION}
用法：bash $0 [命令]
命令：
  create                 创建节点
  list                   查看节点
  start <节点名>          启动节点
  stop <节点名>           停止节点（同时取消该节点开机启动标记）
  restart <节点名>        重启节点
  delete <节点名>         删除节点
  logs <节点名>           查看日志
  uuid                   查看公共 UUID
  update                 在线更新脚本
  enable-autostart       启用 VPS 开机自启
  disable-autostart      取消 VPS 开机自启
  uninstall              彻底卸载
数据目录：$BASE_DIR
EOF
}
menu(){
    local choice
    while true; do
        echo
        echo "===================================================="
        echo "       Hysteria2 多节点管理脚本 v${SCRIPT_VERSION}"
        echo "===================================================="
        echo "1. 创建新节点"
        echo "2. 查看所有节点"
        echo "3. 启动指定节点"
        echo "4. 停止指定节点"
        echo "5. 重启指定节点"
        echo "6. 删除指定节点"
        echo "7. 查看节点日志"
        echo "8. 查看公共 UUID"
        echo "9. 在线更新脚本"
        echo "10. 设置 VPS 重启后自动启动"
        echo "11. 取消开机自动启动"
        echo "12. 彻底卸载"
        echo "0. 退出"
        read -r -p "请选择 [0-12]：" choice
        case "$choice" in
            1) create_node; pause_enter;;
            2) list_nodes; pause_enter;;
            3) ask_node_name; start_node "$REPLY"; pause_enter;;
            4) ask_node_name; stop_node "$REPLY"; pause_enter;;
            5) ask_node_name; restart_node "$REPLY"; pause_enter;;
            6) ask_node_name; delete_node "$REPLY"; pause_enter;;
            7) ask_node_name; show_logs "$REPLY"; pause_enter;;
            8) show_uuid; pause_enter;;
            9) update_script; pause_enter;;
            10) enable_autostart; pause_enter;;
            11) disable_autostart; pause_enter;;
            12) uninstall_all;;
            0|q|Q) exit 0;;
            *) echo "请输入 0-12。";;
        esac
    done
}
main(){
    ensure_root
    local cmd="${1:-menu}"
    case "$cmd" in
        menu) menu;;
        create) create_node;;
        list) list_nodes;;
        start) [[ $# -ge 2 ]] || { echo "用法：$0 start <节点名>"; exit 2; }; start_node "$2";;
        stop) [[ $# -ge 2 ]] || { echo "用法：$0 stop <节点名>"; exit 2; }; stop_node "$2";;
        restart) [[ $# -ge 2 ]] || { echo "用法：$0 restart <节点名>"; exit 2; }; restart_node "$2";;
        delete|del|rm) [[ $# -ge 2 ]] || { echo "用法：$0 delete <节点名>"; exit 2; }; delete_node "$2";;
        logs) [[ $# -ge 2 ]] || { echo "用法：$0 logs <节点名>"; exit 2; }; show_logs "$2";;
        uuid) show_uuid;;
        update) update_script;;
        enable-autostart) enable_autostart;;
        disable-autostart) disable_autostart;;
        uninstall) uninstall_all;;
        help|-h|--help) print_help;;
        *) echo "未知命令：$cmd"; print_help; exit 2;;
    esac
}
main "$@"