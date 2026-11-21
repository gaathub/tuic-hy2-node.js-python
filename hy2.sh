#!/usr/bin/env bash
# ============================================================
# HY2 轻量化多节点管理脚本（增强版）
# 功能：DIRECT / SOCKS5、多节点、共享认证、开机自启、流量统计及限额
# 依赖：bash、curl、openssl、systemd、awk、grep、sed；不需要 jq / Python / Docker
# 支持：Debian / Ubuntu / Rocky / AlmaLinux / CentOS Stream / Fedora
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -------------------------- 基础路径 --------------------------
# 在线更新脚本的链接地址
SCRIPT_URL="https://raw.githubusercontent.com/kystor/tuic-hy2-node.js-python/refs/heads/main/hy2.sh"

HY2_HOME="/opt/hy2"
HY2_BIN="${HY2_HOME}/bin/hysteria"
NODES_DIR="${HY2_HOME}/nodes"
CERT_DIR="${HY2_HOME}/cert"
DATA_DIR="${HY2_HOME}/data"
AUTH_FILE="${DATA_DIR}/auth.password"
SERVER_ADDR_FILE="${DATA_DIR}/server.addr"

CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"
FINGERPRINT_FILE="${CERT_DIR}/server.sha256"
CERT_FINGERPRINT=""
SERVICE_FILE="/etc/systemd/system/hy2@.service"
TRAFFIC_SERVICE_FILE="/etc/systemd/system/hy2-traffic-monitor.service"
SERVICE_PREFIX="hy2@"
TRAFFIC_SERVICE="hy2-traffic-monitor.service"
SNI_HOST="www.bing.com"
MIGRATION_FILE="${DATA_DIR}/traffic_migrated_v1"
# 普通文件启动时更新当前脚本；使用 bash <(curl ...) 时，
# BASH_SOURCE 指向 /dev/fd 或 /proc 管道，不能作为持久化脚本路径。
SOURCE_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
if [[ -n "$SOURCE_SCRIPT_PATH" && -f "$SOURCE_SCRIPT_PATH" &&
      "$SOURCE_SCRIPT_PATH" != /proc/* && "$SOURCE_SCRIPT_PATH" != /dev/fd/* ]]; then
    SCRIPT_PATH="$SOURCE_SCRIPT_PATH"
else
    # 进程替换启动时，将脚本安装到固定位置，供 sr 快捷命令和 systemd 监控服务调用。
    SCRIPT_PATH="/usr/local/bin/hy2"
fi

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
        error "当前环境看起来不是由 systemd 启动；请在正常的 VPS 系统中运行。"
        exit 1
    fi
}

install_missing_commands() {
    local missing=() cmd
    for cmd in curl openssl awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0

    info "正在安装缺少的依赖：${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y curl openssl gawk grep sed ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl openssl gawk grep sed ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl openssl gawk grep sed ca-certificates
    else
        error "无法识别包管理器，请手动安装 curl、openssl、awk、grep、sed。"
        exit 1
    fi
}

# -------------------------- 核心架构识别 --------------------------
get_hy2_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "arm" ;;
        i386|i686) echo "386" ;;
        *) error "暂不支持当前 CPU 架构：$(uname -m)"; return 1 ;;
    esac
}

# -------------------------- 核心安装 / 更新 --------------------------
install_or_update_core() {
    local arch github_url official_url tmp old_version new_version source_url downloaded=no
    arch="$(get_hy2_arch)" || return 1

    github_url="https://github.com/HyNetworks/hysteria/releases/latest/download/hysteria-linux-${arch}"
    official_url="https://download.hysteria.network/app/latest/hysteria-linux-${arch}"
    mkdir -p "${HY2_HOME}/bin"

    old_version="未安装"
    if [[ -x "$HY2_BIN" ]]; then
        old_version="$("$HY2_BIN" version 2>/dev/null | head -n 1 || echo 已安装)"
    fi

    echo
    info "正在下载 Hysteria 最新核心，CPU 架构：${arch}"
    # 按用户要求：先 GitHub，失败后再尝试官方源。
    for source_url in "$github_url" "$official_url"; do
        tmp="$(mktemp "${HY2_HOME}/bin/hysteria.tmp.XXXXXX")"
        if curl -fL --retry 1 --retry-delay 2 --connect-timeout 12 --max-time 180 \
            "$source_url" -o "$tmp"; then
            chmod 755 "$tmp"
            if [[ -s "$tmp" ]] && "$tmp" version >/dev/null 2>&1; then
                mv -f "$tmp" "$HY2_BIN"
                chmod 755 "$HY2_BIN"
                downloaded=yes
                ok "核心下载成功：${source_url}"
                break
            fi
        fi
        rm -f "$tmp"
        if [[ "$source_url" == "$github_url" ]]; then
            warn "GitHub 下载失败或文件验证失败，切换到 Hysteria 官方下载源。"
        fi
    done

    if [[ "$downloaded" != yes ]]; then
        error "GitHub 和官方地址均下载失败，原有核心未被替换。"
        return 1
    fi

    new_version="$("$HY2_BIN" version 2>/dev/null | head -n 1 || echo 已安装)"
    echo
    ok "Hysteria 核心更新成功。"
    echo "旧版本：${old_version}"
    echo "新版本：${new_version}"

    local d node_id unit
    for d in "${NODES_DIR}"/node-*; do
        [[ -d "$d" ]] || continue
        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"
        # 只重启原本正在运行且没有被流量限制锁定的节点。
        if systemctl is-active --quiet "$unit" && [[ "$(read_node_value "$d/traffic_blocked" no)" != "yes" ]]; then
            info "正在重启节点：${node_id}"
            systemctl restart "$unit" || warn "节点 ${node_id} 重启失败，请检查日志。"
        fi
    done
}

# -------------------------- 通用文件 / 数值工具 --------------------------
read_node_value() {
    local file="$1" default_value="${2:-}"
    if [[ -s "$file" ]]; then
        cat "$file"
    else
        printf '%s' "$default_value"
    fi
}

write_node_value() {
    local file="$1" value="$2"
    printf '%s\n' "$value" > "$file"
    chmod 600 "$file" 2>/dev/null || true
}

read_number_file() {
    local value
    value="$(read_node_value "$1" 0)"
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s' "$value"
}

# 将用户输入的 GB 转为字节。这里 1GB 按 1024^3 字节计算。
gb_to_bytes() {
    local value="$1"
    awk -v gb="$value" 'BEGIN { printf "%.0f", gb * 1024 * 1024 * 1024 }'
}

bytes_to_gb() {
    local value="$1"
    awk -v bytes="$value" 'BEGIN { printf "%.2f", bytes / 1073741824 }'
}

format_limit() {
    local bytes="$1"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]] || ((bytes == 0)); then
        printf '不限'
    else
        printf '%s GB' "$(bytes_to_gb "$bytes")"
    fi
}

prompt_limit_bytes() {
    local label="$1" input bytes
    while true; do
        read -r -p "${label}（GB，直接回车表示不限）: " input
        if [[ -z "$input" ]]; then
            PROMPT_BYTES=0
            return 0
        fi
        if [[ ! "$input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            warn "请输入大于 0 的数字，例如 50 或 1.5；直接回车表示不限。"
            continue
        fi
        bytes="$(gb_to_bytes "$input")"
        if [[ ! "$bytes" =~ ^[0-9]+$ ]] || ((bytes <= 0)); then
            warn "额度必须大于 0。"
            continue
        fi
        PROMPT_BYTES="$bytes"
        return 0
    done
}

# -------------------------- 共享认证及证书 --------------------------
create_shared_auth() {
    if [[ ! -s "$AUTH_FILE" ]]; then
        openssl rand -hex 16 > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
    fi
}

# 计算并保存服务器证书的 SHA256 指纹。
# 使用 OpenSSL 标准格式（大写十六进制，字节之间以冒号分隔）。
save_cert_fingerprint() {
    local fingerprint
    mkdir -p "$CERT_DIR"

    if [[ ! -s "$CERT_FILE" ]]; then
        error "证书文件不存在，无法计算 SHA256 指纹：${CERT_FILE}"
        return 1
    fi

    fingerprint="$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//')"
    if [[ ! "$fingerprint" =~ ^([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}$ ]]; then
        error "无法从证书中解析有效的 SHA256 指纹。"
        return 1
    fi

    printf '%s\n' "$fingerprint" > "$FINGERPRINT_FILE"
    chmod 600 "$FINGERPRINT_FILE"
    CERT_FINGERPRINT="$fingerprint"
}

create_self_signed_cert() {
    mkdir -p "$CERT_DIR"

    # 已有证书和私钥时直接沿用，在线更新脚本不会重新生成证书。
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        info "正在生成自签名 TLS 证书（SNI：${SNI_HOST}）..."
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=${SNI_HOST}" -addext "subjectAltName=DNS:${SNI_HOST}" >/dev/null 2>&1 || {
                error "TLS 证书生成失败。"
                return 1
            }
        chmod 600 "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        ok "TLS 证书生成成功。"
    else
        info "检测到已有 TLS 证书，继续使用旧证书，不重新生成。"
    fi

    # 每次启动时都从实际证书重新计算，兼容旧版本没有指纹文件的安装。
    save_cert_fingerprint || return 1
    ok "证书 SHA256 指纹：${CERT_FINGERPRINT}"
}

# -------------------------- systemd 节点模板 --------------------------
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

systemd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

# -------------------------- 持久化脚本文件 --------------------------
ensure_persistent_script() {
    local tmp
    # 普通文件启动时，当前脚本已经存在，无需额外下载。
    [[ -f "$SCRIPT_PATH" && -s "$SCRIPT_PATH" ]] && return 0

    # bash <(curl ...) 启动时，原始脚本来自管道，无法可靠复制当前进程输入流。
    # 因此首次运行时从固定 Raw 地址下载持久化副本，供快捷命令和 systemd 使用。
    info "检测到当前通过在线命令启动，正在安装持久化脚本..."
    tmp="$(mktemp)"
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"
        error "无法下载持久化脚本。请检查 VPS 网络，或先将脚本保存为普通文件后运行。"
        return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        error "下载的脚本语法检查失败，未安装持久化副本。"
        return 1
    fi
    install -m 755 "$tmp" "$SCRIPT_PATH"
    rm -f "$tmp"
    ok "持久化脚本已安装：${SCRIPT_PATH}"
}

# -------------------------- sr 快捷命令 --------------------------
install_shortcut() {
    [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]] || return 0
    mkdir -p /usr/local/bin
    chmod 755 "$SCRIPT_PATH" 2>/dev/null || true
    ln -sfn "$SCRIPT_PATH" /usr/local/bin/sr
    chmod 755 /usr/local/bin/sr 2>/dev/null || true
    ok "快捷命令已设置：输入 sr 即可打开 HY2 管理菜单。"
}

# -------------------------- 流量 API 配置 --------------------------
# 每个 HY2 节点使用独立的本机回环地址和密钥，API 不暴露到公网。
api_tcp_port_in_use() {
    local port="$1" d saved
    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" && -s "$d/traffic_api_port" ]] || continue
        saved="$(cat "$d/traffic_api_port")"
        [[ "$saved" == "$port" ]] && return 0
    done
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
    fi
    return 1
}

allocate_traffic_api_port() {
    local seed="$1" port try
    port=$((35000 + seed))
    for ((try=0; try<25000; try++)); do
        ((port > 60000)) && port=35000
        if ! api_tcp_port_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
        port=$((port + 1))
    done
    error "无法为流量 API 找到可用的本机 TCP 端口。"
    return 1
}

write_traffic_api_config() {
    local node_dir="$1" config_file="${1}/config.yaml" port secret tmp
    port="$(read_node_value "$node_dir/traffic_api_port" '')"
    secret="$(read_node_value "$node_dir/traffic_api_secret" '')"
    [[ -n "$port" && -n "$secret" ]] || return 1

    tmp="$(mktemp "${node_dir}/config.yaml.tmp.XXXXXX")"
    # trafficStats 块始终追加在配置文件末尾，因此可以安全删除旧块再重写。
    awk '/^trafficStats:[[:space:]]*$/ { skip=1 } !skip { print }' "$config_file" > "$tmp"
    cat >> "$tmp" <<EOF_TRAFFIC

trafficStats:
  listen: "127.0.0.1:${port}"
  secret: "${secret}"
EOF_TRAFFIC
    chmod 600 "$tmp"
    mv -f "$tmp" "$config_file"
}

ensure_node_traffic_api() {
    local node_dir="$1" node_num port secret config_file="${1}/config.yaml"
    node_num="${node_dir##*/node-}"
    if [[ ! -s "$node_dir/traffic_api_port" ]]; then
        port="$(allocate_traffic_api_port "$node_num")" || return 1
        write_node_value "$node_dir/traffic_api_port" "$port"
    fi
    if [[ ! -s "$node_dir/traffic_api_secret" ]]; then
        secret="$(openssl rand -hex 24)"
        write_node_value "$node_dir/traffic_api_secret" "$secret"
    fi
    port="$(read_node_value "$node_dir/traffic_api_port" '')"
    secret="$(read_node_value "$node_dir/traffic_api_secret" '')"
    # 配置和本地元数据一致时不重复改写配置，也避免无意义重启。
    if grep -q '^trafficStats:[[:space:]]*$' "$config_file" 2>/dev/null && \
       grep -qF "127.0.0.1:${port}" "$config_file" && \
       grep -qF "${secret}" "$config_file"; then
        return 0
    fi
    write_traffic_api_config "$node_dir"
}

# -------------------------- 周期重置时间计算 --------------------------
# 重置时间使用 VPS 本地时区的 00:00。
calculate_next_reset_epoch() {
    local node_dir="$1" period now weekday target_day target_day_num delta
    local year month month_day first_this first_next last_day candidate
    local target_month target_year target_date

    period="$(read_node_value "$node_dir/traffic_period" none)"
    now="$(date +%s)"
    case "$period" in
        weekly)
            weekday="$(read_node_value "$node_dir/traffic_weekday" 1)"
            [[ "$weekday" =~ ^[1-7]$ ]] || weekday=1
            target_day="$(date -d 'today 00:00:00' +%s)"
            target_day_num="$(date +%u)"
            delta=$(((weekday - target_day_num + 7) % 7))
            candidate=$((target_day + delta * 86400))
            ((candidate <= now)) && candidate=$((candidate + 7 * 86400))
            ;;
        monthly)
            month_day="$(read_node_value "$node_dir/traffic_monthday" 1)"
            [[ "$month_day" =~ ^[0-9]+$ ]] || month_day=1
            ((month_day < 1)) && month_day=1
            ((month_day > 31)) && month_day=31
            year="$(date +%Y)"
            month="$(date +%m)"
            first_this="${year}-${month}-01"
            last_day="$(date -d "${first_this} +1 month -1 day" +%d)"
            target_day="$month_day"
            ((10#$target_day > 10#$last_day)) && target_day="$last_day"
            candidate="$(date -d "${year}-${month}-$(printf '%02d' "$((10#$target_day))") 00:00:00" +%s)"
            if ((candidate <= now)); then
                first_next="$(date -d "${first_this} +1 month" +%Y-%m-01)"
                year="${first_next:0:4}"
                month="${first_next:5:2}"
                last_day="$(date -d "${first_next} +1 month -1 day" +%d)"
                target_day="$month_day"
                ((10#$target_day > 10#$last_day)) && target_day="$last_day"
                candidate="$(date -d "${year}-${month}-$(printf '%02d' "$((10#$target_day))") 00:00:00" +%s)"
            fi
            ;;
        yearly)
            target_month="$(read_node_value "$node_dir/traffic_yearmonth" 1)"
            target_day="$(read_node_value "$node_dir/traffic_yearday" 1)"
            [[ "$target_month" =~ ^[0-9]+$ ]] || target_month=1
            [[ "$target_day" =~ ^[0-9]+$ ]] || target_day=1
            ((target_month < 1 || target_month > 12)) && target_month=1
            ((target_day < 1)) && target_day=1
            ((target_day > 31)) && target_day=31
            year="$(date +%Y)"
            month="$(printf '%02d' "$((10#$target_month))")"
            first_this="${year}-${month}-01"
            last_day="$(date -d "${first_this} +1 month -1 day" +%d)"
            month_day="$target_day"
            ((10#$month_day > 10#$last_day)) && month_day="$last_day"
            candidate="$(date -d "${year}-${month}-$(printf '%02d' "$((10#$month_day))") 00:00:00" +%s)"
            if ((candidate <= now)); then
                year=$((year + 1))
                first_this="${year}-${month}-01"
                last_day="$(date -d "${first_this} +1 month -1 day" +%d)"
                month_day="$target_day"
                ((10#$month_day > 10#$last_day)) && month_day="$last_day"
                candidate="$(date -d "${year}-${month}-$(printf '%02d' "$((10#$month_day))") 00:00:00" +%s)"
            fi
            ;;
        *)
            candidate=0
            ;;
    esac
    printf '%s' "$candidate"
}

set_next_reset() {
    local node_dir="$1" next
    next="$(calculate_next_reset_epoch "$node_dir")"
    write_node_value "$node_dir/traffic_next_reset" "$next"
}

format_next_reset() {
    local epoch="$1"
    if [[ ! "$epoch" =~ ^[0-9]+$ ]] || ((epoch == 0)); then
        printf '不自动重置'
    else
        date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S'
    fi
}

prompt_reset_schedule() {
    local choice value
    echo
    echo "流量重置周期："
    echo "  1. 永不自动重置"
    echo "  2. 每周重置"
    echo "  3. 每月重置"
    echo "  4. 每年重置"
    read -r -p "请选择 [1-4]（默认 1）: " choice
    choice="${choice:-1}"

    TRAFFIC_PERIOD="none"
    TRAFFIC_WEEKDAY=1
    TRAFFIC_MONTHDAY=1
    TRAFFIC_YEARMONTH=1
    TRAFFIC_YEARDAY=1

    case "$choice" in
        1) TRAFFIC_PERIOD="none" ;;
        2)
            TRAFFIC_PERIOD="weekly"
            echo "  1. 星期一  2. 星期二  3. 星期三  4. 星期四"
            echo "  5. 星期五  6. 星期六  7. 星期日"
            read -r -p "每周哪一天重置 [1-7]（默认星期一）: " value
            value="${value:-1}"
            [[ "$value" =~ ^[1-7]$ ]] || { warn "输入无效，使用星期一。"; value=1; }
            TRAFFIC_WEEKDAY="$value"
            ;;
        3)
            TRAFFIC_PERIOD="monthly"
            read -r -p "每月几号重置 [1-31]（默认 1；当月不存在该日期时按月末重置）: " value
            value="${value:-1}"
            [[ "$value" =~ ^[0-9]+$ ]] || value=1
            ((10#$value < 1 || 10#$value > 31)) && value=1
            TRAFFIC_MONTHDAY="$((10#$value))"
            ;;
        4)
            TRAFFIC_PERIOD="yearly"
            read -r -p "每年几月重置 [1-12]（默认 1）: " value
            value="${value:-1}"
            [[ "$value" =~ ^[0-9]+$ ]] || value=1
            ((10#$value < 1 || 10#$value > 12)) && value=1
            TRAFFIC_YEARMONTH="$((10#$value))"
            read -r -p "每月几号重置 [1-31]（默认 1；该月不存在该日期时按月末重置）: " value
            value="${value:-1}"
            [[ "$value" =~ ^[0-9]+$ ]] || value=1
            ((10#$value < 1 || 10#$value > 31)) && value=1
            TRAFFIC_YEARDAY="$((10#$value))"
            ;;
        *)
            warn "选择无效，使用永不自动重置。"
            TRAFFIC_PERIOD="none"
            ;;
    esac
}

save_traffic_schedule() {
    local node_dir="$1"
    write_node_value "$node_dir/traffic_period" "$TRAFFIC_PERIOD"
    write_node_value "$node_dir/traffic_weekday" "$TRAFFIC_WEEKDAY"
    write_node_value "$node_dir/traffic_monthday" "$TRAFFIC_MONTHDAY"
    write_node_value "$node_dir/traffic_yearmonth" "$TRAFFIC_YEARMONTH"
    write_node_value "$node_dir/traffic_yearday" "$TRAFFIC_YEARDAY"
    set_next_reset "$node_dir"
}

# -------------------------- 流量额度交互 --------------------------
prompt_traffic_limits() {
    local choice
    TRAFFIC_LIMIT_TOTAL=0
    TRAFFIC_LIMIT_TX=0
    TRAFFIC_LIMIT_RX=0
    TRAFFIC_ENABLED=no

    echo
    echo "========== 节点流量统计与限制 =========="
    read -r -p "是否启用该节点的流量统计/限额？[y/N]（直接回车默认不启用）: " choice
    case "$choice" in
        y|Y|yes|YES)
            TRAFFIC_ENABLED=yes
            prompt_limit_bytes "总流量限制"
            TRAFFIC_LIMIT_TOTAL="$PROMPT_BYTES"
            prompt_limit_bytes "出站流量限制（VPS 发往目标网站）"
            TRAFFIC_LIMIT_TX="$PROMPT_BYTES"
            prompt_limit_bytes "入站流量限制（目标网站返回 VPS）"
            TRAFFIC_LIMIT_RX="$PROMPT_BYTES"
            prompt_reset_schedule
            ;;
        *)
            TRAFFIC_ENABLED=no
            ;;
    esac
}

initialize_node_traffic_files() {
    local node_dir="$1"
    write_node_value "$node_dir/traffic_enabled" yes
    write_node_value "$node_dir/traffic_limit_total" "${TRAFFIC_LIMIT_TOTAL:-0}"
    write_node_value "$node_dir/traffic_limit_tx" "${TRAFFIC_LIMIT_TX:-0}"
    write_node_value "$node_dir/traffic_limit_rx" "${TRAFFIC_LIMIT_RX:-0}"
    write_node_value "$node_dir/traffic_used_tx" 0
    write_node_value "$node_dir/traffic_used_rx" 0
    write_node_value "$node_dir/traffic_api_last_tx" 0
    write_node_value "$node_dir/traffic_api_last_rx" 0
    write_node_value "$node_dir/traffic_api_mainpid" 0
    write_node_value "$node_dir/traffic_api_loaded" no
    write_node_value "$node_dir/traffic_blocked" no
    save_traffic_schedule "$node_dir"
    ensure_node_traffic_api "$node_dir"
}

# -------------------------- 公网 IP / 分享链接 --------------------------
valid_ipv4() {
    local ip="$1" a b c d part
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    for part in "$a" "$b" "$c" "$d"; do
        ((10#$part <= 255)) || return 1
    done
    return 0
}

valid_ip() {
    local ip="$1"
    valid_ipv4 "$ip" && return 0
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]
}

get_public_ip() {
    local family url ip attempt
    local urls4=("https://api.ipify.org" "https://ipv4.icanhazip.com" "https://checkip.amazonaws.com" "https://ifconfig.co/ip")
    local urls6=("https://api6.ipify.org" "https://ipv6.icanhazip.com" "https://v6.ident.me")

    # 多接口轮询，每个接口重试两次，先 IPv4 再 IPv6。
    for family in 4 6; do
        if [[ "$family" == 4 ]]; then
            for url in "${urls4[@]}"; do
                for attempt in 1 2; do
                    ip="$(curl -"$family" -fsS --connect-timeout 4 --max-time 7 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
                    if valid_ip "$ip"; then printf '%s' "$ip"; return 0; fi
                done
            done
        else
            for url in "${urls6[@]}"; do
                for attempt in 1 2; do
                    ip="$(curl -"$family" -fsS --connect-timeout 4 --max-time 7 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
                    if valid_ip "$ip"; then printf '%s' "$ip"; return 0; fi
                done
            done
        fi
    done
    return 1
}

valid_server_addr() {
    local value="$1"
    [[ -n "$value" && "$value" != *[[:space:]/?#@]* ]]
}

ensure_server_addr() {
    local current="" detected="" input=""
    if [[ -s "$SERVER_ADDR_FILE" ]]; then
        current="$(cat "$SERVER_ADDR_FILE")"
        valid_server_addr "$current" && return 0
    fi

    echo
    info "请输入客户端连接 VPS 时使用的公网 IP 或域名。"
    detected="$(get_public_ip || true)"
    if [[ -n "$detected" ]]; then
        read -r -p "连接地址 [自动检测：${detected}]（直接回车使用自动检测结果）: " input
        input="${input:-$detected}"
    else
        warn "多个公网 IP 查询接口均未成功，请手动输入域名或公网 IP。"
        read -r -p "连接地址: " input
    fi
    if ! valid_server_addr "$input"; then
        error "连接地址为空或格式不正确。"
        return 1
    fi
    printf '%s\n' "$input" > "$SERVER_ADDR_FILE"
    chmod 600 "$SERVER_ADDR_FILE"
    ok "连接地址已保存：${input}"
}

uri_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then printf '[%s]' "$host"; else printf '%s' "$host"; fi
}

url_encode() {
    local LC_ALL=C input="$1" output="" ch code i
    for ((i=0; i<${#input}; i++)); do
        ch="${input:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-]) output+="$ch" ;;
            *) printf -v code '%%%02X' "'${ch}"; output+="$code" ;;
        esac
    done
    printf '%s' "$output"
}

make_share_link() {
    local node_name="$1" port="$2" server_addr encoded_name encoded_pin
    server_addr="$(cat "$SERVER_ADDR_FILE")"
    server_addr="$(uri_host "$server_addr")"
    encoded_name="$(url_encode "$node_name")"

    # 所有节点共用同一张证书，因此所有节点使用同一个指纹。
    if [[ -z "${CERT_FINGERPRINT:-}" ]]; then
        CERT_FINGERPRINT="$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "${CERT_FINGERPRINT:-}" ]]; then
        error "证书指纹不存在，无法生成分享链接。"
        return 1
    fi
    encoded_pin="$(url_encode "$CERT_FINGERPRINT")"

    # 使用 insecure=1，并通过 pinSHA256 校验服务器证书指纹。
    printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1&pinSHA256=%s#%s' \
        "$AUTH_PASS" "$server_addr" "$port" "$SNI_HOST" "$encoded_pin" "$encoded_name"
}

# -------------------------- 节点列表及选择 --------------------------
load_node_dirs() {
    NODE_DIRS=()
    local d
    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" ]] && NODE_DIRS+=("$d")
    done
    ((${#NODE_DIRS[@]} > 0)) || return 1
    mapfile -t NODE_DIRS < <(printf '%s\n' "${NODE_DIRS[@]}" | sort -V)
    return 0
}

next_node_number() {
    local d base number max=0
    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" ]] || continue
        base="${d##*/node-}"
        if [[ "$base" =~ ^[0-9]+$ ]]; then
            number=$((10#$base))
            ((number > max)) && max="$number"
        fi
    done
    echo $((max + 1))
}

node_port_exists() {
    local wanted="$1" d saved_port
    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" && -f "$d/port" ]] || continue
        saved_port="$(cat "$d/port")"
        [[ "$saved_port" == "$wanted" ]] && return 0
    done
    return 1
}

udp_port_is_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
        return $?
    fi
    return 1
}

show_node_choices() {
    local i d name port mode status
    echo
    echo "节点列表："
    for i in "${!NODE_DIRS[@]}"; do
        d="${NODE_DIRS[$i]}"
        name="$(read_node_value "$d/name" 未命名)"
        port="$(read_node_value "$d/port" -)"
        mode="$(read_node_value "$d/mode" -)"
        if systemctl is-active --quiet "${SERVICE_PREFIX}${d##*/}.service"; then status="运行中"; else status="已停止"; fi
        printf '  %2d. %-20s %-7s UDP:%-6s %s\n' "$((i+1))" "$name" "$mode" "$port" "$status"
    done
}

load_node_choice() {
    local choice index
    if ! load_node_dirs; then warn "目前还没有创建任何节点。"; return 1; fi
    show_node_choices
    read -r -p "请输入节点序号（0 返回）: " choice
    [[ "$choice" == 0 ]] && return 1
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then warn "请输入正确的数字序号。"; return 1; fi
    index=$((10#$choice))
    if ((index < 1 || index > ${#NODE_DIRS[@]})); then warn "序号超出范围。"; return 1; fi
    SELECTED_NODE="${NODE_DIRS[$((index-1))]}"
    return 0
}

# -------------------------- 创建节点 --------------------------
create_node() {
    local node_name port default_port node_num mode_choice mode
    local proxy_addr proxy_user proxy_pass proxy_port
    local node_id node_dir config_file quoted_addr quoted_user quoted_pass unit

    ensure_server_addr || return 1
    node_num="$(next_node_number)"
    default_port=$((20000 + node_num))

    echo
    read -r -p "节点名称（例如 Google、Netflix）: " node_name
    if [[ -z "$node_name" || "$node_name" == */* ]]; then error "节点名称不能为空，也不能包含 /。"; return 1; fi

    read -r -p "UDP 监听端口 [${default_port}]: " port
    port="${port:-$default_port}"
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then error "端口必须是 1 到 65535 之间的数字。"; return 1; fi
    port=$((10#$port))
    if ((port < 1 || port > 65535)); then error "端口范围必须为 1-65535。"; return 1; fi
    if node_port_exists "$port"; then error "本脚本已有节点使用 UDP 端口 ${port}。"; return 1; fi
    if udp_port_is_listening "$port"; then error "检测到 UDP 端口 ${port} 已被其他程序占用，请更换端口。"; return 1; fi

    echo
    echo "选择节点出口："
    echo "  1. DIRECT（VPS 本机直连）"
    echo "  2. SOCKS5（通过 SOCKS5 代理出站）"
    read -r -p "请选择 [1/2]: " mode_choice

    proxy_addr=""
    proxy_user=""
    proxy_pass=""
    case "$mode_choice" in
        1) mode="DIRECT" ;;
        2)
            mode="SOCKS5"
            while true; do
                read -r -p "SOCKS5 地址（例如 127.0.0.1:1080）: " proxy_addr
                if [[ "$proxy_addr" =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):([0-9]{1,5})$ ]]; then
                    proxy_port="${BASH_REMATCH[2]}"
                    proxy_port=$((10#$proxy_port))
                    ((proxy_port >= 1 && proxy_port <= 65535)) && break
                fi
                warn "地址格式不正确，请使用 host:port 或 [IPv6]:port。"
            done
            read -r -p "SOCKS5 用户名（无认证直接回车）: " proxy_user
            if [[ -n "$proxy_user" ]]; then
                read -r -s -p "SOCKS5 密码: " proxy_pass
                echo
                [[ -n "$proxy_pass" ]] || { error "填写了用户名时，密码也不能为空。"; return 1; }
            fi
            ;;
        *) warn "选择无效，已取消创建。"; return 1 ;;
    esac

    # 节点创建阶段询问是否开启独立流量统计和限额。
    prompt_traffic_limits

    node_id="node-${node_num}"
    node_dir="${NODES_DIR}/${node_id}"
    config_file="${node_dir}/config.yaml"
    unit="${SERVICE_PREFIX}${node_id}.service"
    mkdir -p "$node_dir"

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

    cat >> "$config_file" <<'EOF_ACL'

acl:
  inline:
    - node_out(all)
EOF_ACL

    printf '%s\n' "$node_name" > "$node_dir/name"
    printf '%s\n' "$port" > "$node_dir/port"
    printf '%s\n' "$mode" > "$node_dir/mode"
    chmod 600 "$config_file" "$node_dir/name" "$node_dir/port" "$node_dir/mode"

    if [[ "$TRAFFIC_ENABLED" == yes ]]; then
        initialize_node_traffic_files "$node_dir" || return 1
    else
        write_node_value "$node_dir/traffic_enabled" no
    fi

    # 创建时直接 enable --now，确保服务立即启动且服务器重启后自动启动。
    if ! systemctl enable --now "$unit"; then
        error "节点服务启动命令失败，最近日志："
        journalctl -u "$unit" -n 30 --no-pager || true
        return 1
    fi

    sleep 1
    if systemctl is-active --quiet "$unit"; then
        ok "节点创建成功并已启动：${node_name}"
        [[ "$TRAFFIC_ENABLED" == yes ]] && write_node_value "$node_dir/traffic_api_loaded" yes
        echo "出口类型：${mode}"
        echo "监听端口：${port}/UDP"
        echo "开机启动：已启用"
        if [[ "$TRAFFIC_ENABLED" == yes ]]; then
            echo "流量统计：已启用"
            echo "总额度：$(format_limit "$TRAFFIC_LIMIT_TOTAL")"
            echo "出站额度：$(format_limit "$TRAFFIC_LIMIT_TX")"
            echo "入站额度：$(format_limit "$TRAFFIC_LIMIT_RX")"
            echo "下次重置：$(format_next_reset "$(read_node_value "$node_dir/traffic_next_reset" 0)")"
        else
            echo "流量统计：未启用"
        fi
        echo
        echo "分享链接："
        make_share_link "$node_name" "$port"
        echo
        warn "请同时在 VPS 服务商防火墙/安全组放行 UDP ${port}。"
        [[ "$mode" == SOCKS5 ]] && warn "SOCKS5 上游必须支持 UDP；否则 UDP 流量可能无法正常转发。"
        refresh_traffic_monitor
    else
        error "节点服务未能正常启动，配置文件已保留。"
        journalctl -u "$unit" -n 30 --no-pager || true
        return 1
    fi
}

# YAML 双引号字符串转义。
yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

# -------------------------- 流量统计 API 数据解析 --------------------------
# Hysteria API 的 traffic JSON 是按认证 ID 分组；一个节点可能返回一个或多个 ID。
# 不依赖 jq/Python，直接把所有 tx/rx 数值分别相加。
sum_json_metric() {
    local json="$1" key="$2" number total=0
    while IFS= read -r number; do
        [[ "$number" =~ ^[0-9]+$ ]] || continue
        total=$((total + number))
    done < <(printf '%s' "$json" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" | sed -E 's/.*:[[:space:]]*//')
    printf '%s' "$total"
}

fetch_api_traffic() {
    local node_dir="$1" port secret response
    port="$(read_node_value "$node_dir/traffic_api_port" '')"
    secret="$(read_node_value "$node_dir/traffic_api_secret" '')"
    [[ -n "$port" && -n "$secret" ]] || return 1
    response="$(curl -fsS --connect-timeout 2 --max-time 4 \
        -H "Authorization: ${secret}" "http://127.0.0.1:${port}/traffic" 2>/dev/null)" || return 1
    API_CURRENT_TX="$(sum_json_metric "$response" tx)"
    API_CURRENT_RX="$(sum_json_metric "$response" rx)"
    return 0
}

node_limit_is_reached() {
    local node_dir="$1" tx rx total limit_total limit_tx limit_rx
    tx="$(read_number_file "$node_dir/traffic_used_tx")"
    rx="$(read_number_file "$node_dir/traffic_used_rx")"
    total=$((tx + rx))
    limit_total="$(read_number_file "$node_dir/traffic_limit_total")"
    limit_tx="$(read_number_file "$node_dir/traffic_limit_tx")"
    limit_rx="$(read_number_file "$node_dir/traffic_limit_rx")"
    ((limit_total > 0 && total >= limit_total)) && return 0
    ((limit_tx > 0 && tx >= limit_tx)) && return 0
    ((limit_rx > 0 && rx >= limit_rx)) && return 0
    return 1
}

stop_node_for_limit() {
    local node_dir="$1" node_id unit name
    node_id="${node_dir##*/}"
    unit="${SERVICE_PREFIX}${node_id}.service"
    name="$(read_node_value "$node_dir/name" "$node_id")"
    if systemctl is-active --quiet "$unit"; then
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        write_node_value "$node_dir/traffic_blocked" yes
        logger -t hy2-traffic "节点 ${name} (${node_id}) 已达到流量额度，自动停止。" 2>/dev/null || true
    fi
}

reset_node_usage_files() {
    local node_dir="$1"
    write_node_value "$node_dir/traffic_used_tx" 0
    write_node_value "$node_dir/traffic_used_rx" 0
}

# -------------------------- 流量采集、限制和自动周期重置 --------------------------
process_node_traffic() {
    local node_dir="$1" node_id unit
    local last_tx last_rx delta_tx delta_rx used_tx used_rx next_reset now blocked current_pid saved_pid
    node_id="${node_dir##*/}"
    unit="${SERVICE_PREFIX}${node_id}.service"

    [[ "$(read_node_value "$node_dir/traffic_enabled" no)" == yes ]] || return 0

    # 先读取 API 累计值，再与上次保存值比较。
    # 不使用 /traffic?clear=1，避免程序在清零后异常退出造成统计丢失。
    if fetch_api_traffic "$node_dir"; then
        # Hysteria 进程重启后，API 内部累计值会从 0 开始。
        # 通过 systemd MainPID 检测进程是否更换，避免新进程的计数刚好大于旧值时漏算。
        current_pid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"
        saved_pid="$(read_node_value "$node_dir/traffic_api_mainpid" 0)"
        if [[ "$current_pid" =~ ^[1-9][0-9]*$ && "$saved_pid" != 0 && "$saved_pid" != "$current_pid" ]]; then
            write_node_value "$node_dir/traffic_api_last_tx" 0
            write_node_value "$node_dir/traffic_api_last_rx" 0
        fi
        if [[ "$current_pid" =~ ^[1-9][0-9]*$ ]]; then
            write_node_value "$node_dir/traffic_api_mainpid" "$current_pid"
        fi
        last_tx="$(read_number_file "$node_dir/traffic_api_last_tx")"
        last_rx="$(read_number_file "$node_dir/traffic_api_last_rx")"
        if ((API_CURRENT_TX >= last_tx)); then delta_tx=$((API_CURRENT_TX - last_tx)); else delta_tx="$API_CURRENT_TX"; fi
        if ((API_CURRENT_RX >= last_rx)); then delta_rx=$((API_CURRENT_RX - last_rx)); else delta_rx="$API_CURRENT_RX"; fi
        used_tx="$(read_number_file "$node_dir/traffic_used_tx")"
        used_rx="$(read_number_file "$node_dir/traffic_used_rx")"
        write_node_value "$node_dir/traffic_used_tx" "$((used_tx + delta_tx))"
        write_node_value "$node_dir/traffic_used_rx" "$((used_rx + delta_rx))"
        write_node_value "$node_dir/traffic_api_last_tx" "$API_CURRENT_TX"
        write_node_value "$node_dir/traffic_api_last_rx" "$API_CURRENT_RX"
    fi

    # 到达周期时清零统计。若节点此前因额度被自动停止，则在重置后自动恢复。
    next_reset="$(read_number_file "$node_dir/traffic_next_reset")"
    now="$(date +%s)"
    if ((next_reset > 0 && now >= next_reset)); then
        reset_node_usage_files "$node_dir"
        set_next_reset "$node_dir"
        blocked="$(read_node_value "$node_dir/traffic_blocked" no)"
        if [[ "$blocked" == yes ]]; then
            write_node_value "$node_dir/traffic_blocked" no
            if systemctl enable --now "$unit"; then
                write_node_value "$node_dir/traffic_api_loaded" yes
                logger -t hy2-traffic "节点 ${node_id} 到达流量周期重置时间，额度已清零并自动恢复。" 2>/dev/null || true
            else
                logger -t hy2-traffic "节点 ${node_id} 流量已重置，但自动启动失败。" 2>/dev/null || true
            fi
        fi
        return 0
    fi

    # 只有仍在运行时才执行自动停机，避免把用户手动停止的节点误标记为流量封锁。
    if node_limit_is_reached "$node_dir" && systemctl is-active --quiet "$unit"; then
        stop_node_for_limit "$node_dir"
    fi
}

traffic_monitor_loop() {
    require_root
    while true; do
        local d
        for d in "$NODES_DIR"/node-*; do
            [[ -d "$d" ]] || continue
            process_node_traffic "$d" || true
        done
        sleep 5
    done
}

write_traffic_monitor_service() {
    local script_arg
    [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]] || { error "无法定位脚本路径，不能配置流量监控服务。"; return 1; }
    script_arg="$(systemd_quote "$SCRIPT_PATH")"
    cat > "$TRAFFIC_SERVICE_FILE" <<EOF_MONITOR
[Unit]
Description=HY2 Per-Node Traffic Monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash ${script_arg} --traffic-monitor
Restart=always
RestartSec=5
Nice=10
NoNewPrivileges=true
PrivateTmp=true
# 监控进程需要读取可能位于 /root 的脚本，并通过 systemctl 修改节点启停状态，
# 因此不能对它启用 ProtectHome/ProtectSystem 的只读隔离。

[Install]
WantedBy=multi-user.target
EOF_MONITOR
    chmod 644 "$TRAFFIC_SERVICE_FILE"
    systemctl daemon-reload
}

refresh_traffic_monitor() {
    local d has_enabled=no
    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" ]] || continue
        if [[ "$(read_node_value "$d/traffic_enabled" no)" == yes ]]; then
            has_enabled=yes
            break
        fi
    done
    if [[ "$has_enabled" == yes ]]; then
        write_traffic_monitor_service || return 1
        systemctl enable --now "$TRAFFIC_SERVICE" >/dev/null 2>&1 || systemctl restart "$TRAFFIC_SERVICE" || true
    else
        systemctl disable --now "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    fi
}

# -------------------------- 旧节点升级迁移 --------------------------
# 第一次运行增强版时，为旧节点开启流量统计（不自动添加额度限制）。
# 统计从迁移完成后开始，不能补算升级之前的流量。
migrate_existing_nodes_traffic() {
    local d node_id unit active needs_restart migration_failed=no
    [[ -f "$MIGRATION_FILE" ]] && return 0
    info "正在检查旧节点并初始化流量统计功能..."
    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" && -s "$d/config.yaml" ]] || continue
        node_id="${d##*/}"
        needs_restart=no
        if [[ ! -s "$d/traffic_api_port" || ! -s "$d/traffic_api_secret" ]] || \
           ! grep -q '^trafficStats:[[:space:]]*$' "$d/config.yaml" 2>/dev/null || \
           [[ "$(read_node_value "$d/traffic_api_loaded" no)" != yes ]]; then
            needs_restart=yes
        fi
        if [[ "$(read_node_value "$d/traffic_enabled" no)" != yes ]]; then
            write_node_value "$d/traffic_enabled" yes
            write_node_value "$d/traffic_limit_total" 0
            write_node_value "$d/traffic_limit_tx" 0
            write_node_value "$d/traffic_limit_rx" 0
            write_node_value "$d/traffic_used_tx" 0
            write_node_value "$d/traffic_used_rx" 0
            write_node_value "$d/traffic_api_last_tx" 0
            write_node_value "$d/traffic_api_last_rx" 0
            write_node_value "$d/traffic_api_mainpid" 0
            write_node_value "$d/traffic_blocked" no
            write_node_value "$d/traffic_period" none
            write_node_value "$d/traffic_weekday" 1
            write_node_value "$d/traffic_monthday" 1
            write_node_value "$d/traffic_yearmonth" 1
            write_node_value "$d/traffic_yearday" 1
            write_node_value "$d/traffic_next_reset" 0
        fi
        if ! ensure_node_traffic_api "$d"; then
            warn "节点 ${node_id} 流量 API 初始化失败。"
            migration_failed=yes
            continue
        fi
        unit="${SERVICE_PREFIX}${node_id}.service"
        if systemctl is-active --quiet "$unit"; then
            active=yes
            if [[ "$needs_restart" == yes ]]; then
                if systemctl restart "$unit"; then
                    write_node_value "$d/traffic_api_loaded" yes
                else
                    warn "节点 ${node_id} 重启失败，请查看日志。"
                    migration_failed=yes
                fi
            fi
        else
            active=no
            # 节点当前未运行；配置文件已写入，今后启动时自然会加载 API。
            write_node_value "$d/traffic_api_loaded" yes
        fi
        info "旧节点 ${node_id} 流量统计已初始化；原运行状态：${active}。"
    done
    if [[ "$migration_failed" == no ]]; then
        touch "$MIGRATION_FILE"
        chmod 600 "$MIGRATION_FILE"
    else
        warn "部分旧节点迁移未完成；下次运行脚本会自动重试。"
    fi
}

# -------------------------- 查看所有节点 --------------------------
show_traffic_summary() {
    local d node_id name tx rx total limit_total limit_tx limit_rx period next blocked
    local unit status
    if ! load_node_dirs; then warn "目前还没有创建任何节点。"; return 0; fi
    echo
    echo "============================== HY2 节点列表 =============================="
    for d in "${NODE_DIRS[@]}"; do
        node_id="${d##*/}"
        name="$(read_node_value "$d/name" "$node_id")"
        tx="$(read_number_file "$d/traffic_used_tx")"
        rx="$(read_number_file "$d/traffic_used_rx")"
        total=$((tx + rx))
        limit_total="$(read_number_file "$d/traffic_limit_total")"
        limit_tx="$(read_number_file "$d/traffic_limit_tx")"
        limit_rx="$(read_number_file "$d/traffic_limit_rx")"
        period="$(read_node_value "$d/traffic_period" none)"
        next="$(read_node_value "$d/traffic_next_reset" 0)"
        blocked="$(read_node_value "$d/traffic_blocked" no)"
        unit="${SERVICE_PREFIX}${node_id}.service"
        if systemctl is-active --quiet "$unit"; then status="运行中"; else status="已停止"; fi
        echo
        echo "节点：${name}（${node_id}）"
        echo "状态：${status}"
        echo "流量统计：$( [[ "$(read_node_value "$d/traffic_enabled" no)" == yes ]] && echo 已启用 || echo 未启用 )"
        echo "出站：$(bytes_to_gb "$tx") GB / $(format_limit "$limit_tx")"
        echo "入站：$(bytes_to_gb "$rx") GB / $(format_limit "$limit_rx")"
        echo "总计：$(bytes_to_gb "$total") GB / $(format_limit "$limit_total")"
        echo "重置周期：${period}；下次重置：$(format_next_reset "$next")"
        [[ "$blocked" == yes ]] && echo "限制状态：已因流量超额自动停止"
        [[ "$blocked" != yes ]] && echo "限制状态：正常"
    done
    echo
    echo "说明：出站/入站按 Hysteria 统计 API 的 VPS-目标服务器方向统计；监控通常每 5 秒检查一次。"
}

list_nodes() {
    local d node_id name port mode unit status boot traffic
    if ! load_node_dirs; then warn "目前还没有创建任何节点。"; return 0; fi
    echo
    echo "============================== HY2 节点列表 =============================="
    for d in "${NODE_DIRS[@]}"; do
        node_id="${d##*/}"
        name="$(read_node_value "$d/name" "$node_id")"
        port="$(read_node_value "$d/port" -)"
        mode="$(read_node_value "$d/mode" -)"
        unit="${SERVICE_PREFIX}${node_id}.service"
        if systemctl is-active --quiet "$unit"; then status="运行中"; else status="已停止"; fi
        if systemctl is-enabled --quiet "$unit"; then boot="已启用"; else boot="未启用"; fi
        if [[ "$(read_node_value "$d/traffic_enabled" no)" == yes ]]; then traffic="已启用"; else traffic="未启用"; fi
        echo
        echo "节点：${name}（${node_id}）"
        echo "出口：${mode}"
        echo "状态：${status}"
        echo "开机启动：${boot}"
        echo "端口：${port}/UDP"
        echo "流量统计：${traffic}"
        echo "链接："
        make_share_link "$name" "$port"
        echo
    done
    echo "========================================================================="
}

# -------------------------- 节点启动 / 停止选择 --------------------------
select_nodes_for_action() {
    local choice index
    if ! load_node_dirs; then warn "目前还没有创建任何节点。"; return 1; fi
    show_node_choices
    echo "  A. 所有节点"
    echo "  0. 返回"
    read -r -p "请输入节点序号或 A: " choice
    SELECTED_NODES=()
    if [[ "$choice" =~ ^[Aa]$ ]]; then
        SELECTED_NODES=("${NODE_DIRS[@]}")
        return 0
    fi
    [[ "$choice" == 0 ]] && return 1
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then warn "输入无效。"; return 1; fi
    index=$((10#$choice))
    if ((index < 1 || index > ${#NODE_DIRS[@]})); then warn "序号超出范围。"; return 1; fi
    SELECTED_NODES=("${NODE_DIRS[$((index-1))]}")
    return 0
}

start_one_node() {
    local node_dir="$1" node_id unit name
    node_id="${node_dir##*/}"
    unit="${SERVICE_PREFIX}${node_id}.service"
    name="$(read_node_value "$node_dir/name" "$node_id")"
    if [[ "$(read_node_value "$node_dir/traffic_blocked" no)" == yes ]]; then
        warn "节点「${name}」仍处于流量超额锁定状态；请等待周期重置或在流量管理中手动重置。"
        return 1
    fi
    if node_limit_is_reached "$node_dir"; then
        write_node_value "$node_dir/traffic_blocked" yes
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        warn "节点「${name}」当前已达到流量额度，拒绝启动。"
        return 1
    fi
    if systemctl enable --now "$unit"; then
        [[ "$(read_node_value "$node_dir/traffic_enabled" no)" == yes ]] && write_node_value "$node_dir/traffic_api_loaded" yes
        ok "已启动：${name}（${node_id}），并启用开机启动。"
    else
        error "启动失败：${node_id}"
        return 1
    fi
}

start_nodes_interactive() {
    local d
    select_nodes_for_action || return 0
    for d in "${SELECTED_NODES[@]}"; do start_one_node "$d" || true; done
}

stop_nodes_interactive() {
    local d node_id unit name
    select_nodes_for_action || return 0
    for d in "${SELECTED_NODES[@]}"; do
        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"
        name="$(read_node_value "$d/name" "$node_id")"
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        info "已停止并取消开机启动：${name}（${node_id}）"
    done
    ok "停止操作完成。"
}

restart_all_nodes() {
    local d node_id unit
    if ! load_node_dirs; then warn "没有可重启的节点。"; return 0; fi
    for d in "${NODE_DIRS[@]}"; do
        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"
        if [[ "$(read_node_value "$d/traffic_blocked" no)" == yes ]] || node_limit_is_reached "$d"; then
            warn "跳过流量超额锁定节点：${node_id}"
            continue
        fi
        if systemctl enable --now "$unit" && systemctl restart "$unit"; then ok "已重启：${node_id}"; else error "重启失败：${node_id}"; fi
    done
}

# -------------------------- 删除节点 --------------------------
delete_node() {
    local node_id name unit confirm
    load_node_choice || return 0
    node_id="${SELECTED_NODE##*/}"
    name="$(read_node_value "$SELECTED_NODE/name" "$node_id")"
    unit="${SERVICE_PREFIX}${node_id}.service"
    read -r -p "确定删除节点「${name}」？请输入 yes 确认: " confirm
    if [[ "$confirm" != yes ]]; then warn "已取消删除。"; return 0; fi
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -rf -- "$SELECTED_NODE"
    ok "节点 ${name} 已删除。"
    warn "脚本不会自动修改系统防火墙；如之前手动放行过 UDP 端口，可自行删除对应规则。"
    refresh_traffic_monitor
}

# -------------------------- 查看日志 --------------------------
show_node_logs() {
    local node_id unit
    load_node_choice || return 0
    node_id="${SELECTED_NODE##*/}"
    unit="${SERVICE_PREFIX}${node_id}.service"
    info "正在显示 ${node_id} 的实时日志，按 Ctrl+C 返回菜单。"
    journalctl -u "$unit" -n 50 -f || true
}

# -------------------------- SOCKS5 配置修改 --------------------------
update_socks_node() {
    local node_id name port mode unit proxy_addr proxy_port proxy_user proxy_pass
    local quoted_addr quoted_user quoted_pass tmp_config backup was_active=false
    load_node_choice || return 0
    node_id="${SELECTED_NODE##*/}"
    name="$(read_node_value "$SELECTED_NODE/name" "$node_id")"
    port="$(read_node_value "$SELECTED_NODE/port" '')"
    mode="$(read_node_value "$SELECTED_NODE/mode" '')"
    unit="${SERVICE_PREFIX}${node_id}.service"
    if [[ "$mode" != SOCKS5 ]]; then warn "所选节点「${name}」是 DIRECT 直连节点，没有 SOCKS5 配置可修改。"; return 0; fi

    echo
    info "正在修改节点「${name}」的 SOCKS5 上游。"
    while true; do
        read -r -p "新的 SOCKS5 地址（例如 127.0.0.1:1080）: " proxy_addr
        if [[ "$proxy_addr" =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+):([0-9]{1,5})$ ]]; then
            proxy_port="${BASH_REMATCH[2]}"
            proxy_port=$((10#$proxy_port))
            ((proxy_port >= 1 && proxy_port <= 65535)) && break
        fi
        warn "地址格式不正确，请使用 host:port 或 [IPv6]:port。"
    done
    read -r -p "新的 SOCKS5 用户名（无认证直接回车）: " proxy_user
    proxy_pass=""
    if [[ -n "$proxy_user" ]]; then
        read -r -s -p "新的 SOCKS5 密码: " proxy_pass
        echo
        [[ -n "$proxy_pass" ]] || { error "填写了用户名时，密码也不能为空。"; return 1; }
    fi

    quoted_addr="$(yaml_quote "$proxy_addr")"
    tmp_config="${SELECTED_NODE}/config.yaml.new"
    backup="${SELECTED_NODE}/config.yaml.bak"
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

    # 先备份原配置，若新配置启动失败则回滚。
    cp -a "${SELECTED_NODE}/config.yaml" "$backup"
    mv -f "$tmp_config" "${SELECTED_NODE}/config.yaml"

    # 如果该节点已经启用流量统计，重建配置时保留其本机 API。
    if [[ "$(read_node_value "$SELECTED_NODE/traffic_enabled" no)" == yes ]]; then
        if ! write_traffic_api_config "$SELECTED_NODE"; then
            mv -f "$backup" "${SELECTED_NODE}/config.yaml"
            error "无法恢复流量统计 API 配置，已回滚原配置。"
            return 1
        fi
    fi

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
    [[ "$was_active" == true ]] && info "节点已恢复运行。"
}

# -------------------------- 修改分享地址 --------------------------
change_server_addr() {
    local old_addr="" new_addr=""
    [[ -s "$SERVER_ADDR_FILE" ]] && old_addr="$(cat "$SERVER_ADDR_FILE")"
    read -r -p "输入新的公网 IP/域名 [当前：${old_addr}]: " new_addr
    new_addr="${new_addr:-$old_addr}"
    if ! valid_server_addr "$new_addr"; then error "地址不能为空，也不能包含空格、路径或 URL 参数。"; return 1; fi
    printf '%s\n' "$new_addr" > "$SERVER_ADDR_FILE"
    chmod 600 "$SERVER_ADDR_FILE"
    ok "分享链接地址已更新。节点服务本身无需重启。"
    info "请进入「查看所有节点」重新复制分享链接。"
}

# -------------------------- 流量管理显示 / 设置 --------------------------
show_one_node_traffic() {
    local d="$1" node_id name tx rx total limit_total limit_tx limit_rx period next blocked enabled
    node_id="${d##*/}"
    name="$(read_node_value "$d/name" "$node_id")"
    enabled="$(read_node_value "$d/traffic_enabled" no)"
    tx="$(read_number_file "$d/traffic_used_tx")"
    rx="$(read_number_file "$d/traffic_used_rx")"
    total=$((tx + rx))
    limit_total="$(read_number_file "$d/traffic_limit_total")"
    limit_tx="$(read_number_file "$d/traffic_limit_tx")"
    limit_rx="$(read_number_file "$d/traffic_limit_rx")"
    period="$(read_node_value "$d/traffic_period" none)"
    next="$(read_node_value "$d/traffic_next_reset" 0)"
    blocked="$(read_node_value "$d/traffic_blocked" no)"
    echo
    echo "节点：${name}（${node_id}）"
    if [[ "$enabled" != yes ]]; then echo "流量统计：未启用"; return 0; fi
    echo "出站（VPS → 目标网站）：$(bytes_to_gb "$tx") GB / $(format_limit "$limit_tx")"
    echo "入站（目标网站 → VPS）：$(bytes_to_gb "$rx") GB / $(format_limit "$limit_rx")"
    echo "总流量：$(bytes_to_gb "$total") GB / $(format_limit "$limit_total")"
    echo "重置周期：${period}"
    echo "下次重置：$(format_next_reset "$next")"
    [[ "$blocked" == yes ]] && echo "状态：因流量超额自动停止，等待重置/手动处理" || echo "状态：正常"
}

view_all_traffic() {
    local d
    if ! load_node_dirs; then warn "目前还没有创建任何节点。"; return 0; fi
    for d in "${NODE_DIRS[@]}"; do show_one_node_traffic "$d"; done
    echo
    info "流量由 Hysteria Traffic Stats API 统计，后台每 5 秒采集一次。显示值可能有数秒延迟。"
}

view_selected_traffic() {
    load_node_choice || return 0
    show_one_node_traffic "$SELECTED_NODE"
}

activate_traffic_for_node() {
    local node_dir="$1" node_id unit was_active=no
    node_id="${node_dir##*/}"
    unit="${SERVICE_PREFIX}${node_id}.service"
    systemctl is-active --quiet "$unit" && was_active=yes
    write_node_value "$node_dir/traffic_enabled" yes
    ensure_node_traffic_api "$node_dir" || return 1
    if [[ "$was_active" == yes ]]; then
        systemctl restart "$unit" || { error "节点 ${node_id} 重启失败。"; return 1; }
    fi
    write_node_value "$node_dir/traffic_api_loaded" yes
    refresh_traffic_monitor
}

modify_traffic_limits() {
    local d
    load_node_choice || return 0
    d="$SELECTED_NODE"
    echo
    info "为节点「$(read_node_value "$d/name" "${d##*/}")」设置额度。"
    prompt_limit_bytes "总流量限制"
    TRAFFIC_LIMIT_TOTAL="$PROMPT_BYTES"
    prompt_limit_bytes "出站流量限制（VPS 发往目标网站）"
    TRAFFIC_LIMIT_TX="$PROMPT_BYTES"
    prompt_limit_bytes "入站流量限制（目标网站返回 VPS）"
    TRAFFIC_LIMIT_RX="$PROMPT_BYTES"
    prompt_reset_schedule

    write_node_value "$d/traffic_limit_total" "$TRAFFIC_LIMIT_TOTAL"
    write_node_value "$d/traffic_limit_tx" "$TRAFFIC_LIMIT_TX"
    write_node_value "$d/traffic_limit_rx" "$TRAFFIC_LIMIT_RX"
    save_traffic_schedule "$d"
    activate_traffic_for_node "$d" || return 1

    # 修改额度视为用户主动调整限制；解除旧的超额锁定，再由监控按新额度判断。
    if [[ "$(read_node_value "$d/traffic_blocked" no)" == yes ]]; then
        write_node_value "$d/traffic_blocked" no
        systemctl enable --now "${SERVICE_PREFIX}${d##*/}.service" || true
    fi
    ok "流量额度及重置周期已更新。"
}

cancel_traffic_limits() {
    local d
    load_node_choice || return 0
    d="$SELECTED_NODE"
    write_node_value "$d/traffic_limit_total" 0
    write_node_value "$d/traffic_limit_tx" 0
    write_node_value "$d/traffic_limit_rx" 0
    if [[ "$(read_node_value "$d/traffic_blocked" no)" == yes ]]; then
        write_node_value "$d/traffic_blocked" no
        systemctl enable --now "${SERVICE_PREFIX}${d##*/}.service" || true
    fi
    ok "该节点的流量限制已取消；流量统计仍会继续。"
}

manual_reset_traffic() {
    local d node_id unit blocked
    load_node_choice || return 0
    d="$SELECTED_NODE"
    node_id="${d##*/}"
    unit="${SERVICE_PREFIX}${node_id}.service"
    blocked="$(read_node_value "$d/traffic_blocked" no)"
    reset_node_usage_files "$d"
    # 当前 API 读数作为新的起点，防止手动重置后把旧计数再次累计。
    if fetch_api_traffic "$d"; then
        write_node_value "$d/traffic_api_last_tx" "$API_CURRENT_TX"
        write_node_value "$d/traffic_api_last_rx" "$API_CURRENT_RX"
    else
        write_node_value "$d/traffic_api_last_tx" 0
        write_node_value "$d/traffic_api_last_rx" 0
    fi
    if [[ "$blocked" == yes ]]; then
        write_node_value "$d/traffic_blocked" no
        systemctl enable --now "$unit" || { error "流量已重置，但节点启动失败。"; return 1; }
        ok "流量已重置，因超额停止的节点已恢复并重新启用开机启动。"
    else
        ok "节点流量已手动重置。"
    fi
}

change_traffic_schedule() {
    local d
    load_node_choice || return 0
    d="$SELECTED_NODE"
    activate_traffic_for_node "$d" || return 1
    prompt_reset_schedule
    save_traffic_schedule "$d"
    ok "流量重置周期已更新，下次重置：$(format_next_reset "$(read_node_value "$d/traffic_next_reset" 0)")"
}

traffic_management_menu() {
    local choice
    while true; do
        echo
        echo "============== 节点流量管理 =============="
        echo "  1. 查看所有节点流量"
        echo "  2. 查看指定节点流量"
        echo "  3. 设置/修改节点流量额度及周期"
        echo "  4. 取消节点流量限制（保留统计）"
        echo "  5. 手动重置指定节点流量"
        echo "  6. 修改指定节点的重置周期"
        echo "  0. 返回主菜单"
        echo "=========================================="
        read -r -p "请选择 [0-6]: " choice || return 0
        case "$choice" in
            1) view_all_traffic ;;
            2) view_selected_traffic ;;
            3) modify_traffic_limits ;;
            4) cancel_traffic_limits ;;
            5) manual_reset_traffic ;;
            6) change_traffic_schedule ;;
            0) return 0 ;;
            *) warn "无效选项，请输入 0-6。" ;;
        esac
        pause
    done
}

# -------------------------- 在线更新脚本 --------------------------
update_script() {
    local tmp backup new_file

    echo
    info "正在从 GitHub 获取最新脚本..."
    info "更新地址：${SCRIPT_URL}"

    # 进程替换启动时，SCRIPT_PATH 指向 /usr/local/bin/hy2；普通文件启动时，
    # SCRIPT_PATH 则指向用户当前运行的脚本文件。
    if [[ -z "$SCRIPT_PATH" || "$SCRIPT_PATH" != /* ]]; then
        error "无法确定脚本安装路径，已取消更新。"
        return 1
    fi

    mkdir -p "$(dirname "$SCRIPT_PATH")"
    tmp="$(mktemp)"
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"
        error "脚本下载失败，当前版本没有发生变化。"
        return 1
    fi

    # 防止 GitHub 返回错误页面或不完整内容时覆盖当前可用脚本。
    if [[ ! -s "$tmp" ]] || ! bash -n "$tmp"; then
        rm -f "$tmp"
        error "新脚本为空或语法检查未通过，已保留当前版本。"
        return 1
    fi

    backup="${SCRIPT_PATH}.bak"
    if [[ -f "$SCRIPT_PATH" ]]; then
        cp -a "$SCRIPT_PATH" "$backup" || {
            rm -f "$tmp"
            error "无法备份当前脚本，已取消更新。"
            return 1
        }
    fi

    # 临时文件与目标文件位于同一目录，mv 可在同一文件系统内原子替换。
    new_file="${SCRIPT_PATH}.new"
    install -m 755 "$tmp" "$new_file" || {
        rm -f "$tmp" "$new_file"
        error "无法写入新脚本，当前版本没有发生变化。"
        return 1
    }
    rm -f "$tmp"
    if ! mv -f "$new_file" "$SCRIPT_PATH"; then
        rm -f "$new_file"
        error "替换脚本失败，旧版本仍保留。"
        return 1
    fi

    ok "脚本在线更新成功。"
    [[ -f "$backup" ]] && echo "旧版本备份：${backup}"
    install_shortcut

    # 流量监控服务执行的是 SCRIPT_PATH；更新后重启，使其加载新版本。
    if systemctl is-enabled --quiet "$TRAFFIC_SERVICE" 2>/dev/null ||
       systemctl is-active --quiet "$TRAFFIC_SERVICE" 2>/dev/null; then
        systemctl restart "$TRAFFIC_SERVICE" >/dev/null 2>&1 ||
            warn "流量监控服务重启失败，可稍后手动重启。"
    fi

    echo
    ok "脚本更新完成，正在自动重启管理菜单并加载新版本..."

    # 用新脚本替换当前进程，不再要求用户手动退出、重新输入 sr。
    # exec 成功后当前旧版本进程会被新版本进程取代。
    if ! exec bash "$SCRIPT_PATH"; then
        error "自动重启失败，请手动执行：bash '$SCRIPT_PATH'"
        return 1
    fi
}

# -------------------------- 深度卸载 --------------------------
uninstall_all() {
    local d node_id unit confirm unit_file sr_path sr_target
    local script_to_remove=""
    local -a script_files=()

    echo
    warn "即将执行 HY2 深度卸载：此操作不可撤销。"
    echo "将删除本脚本创建的 HY2 节点、核心、证书、密码、流量统计数据、"
    echo "systemd 服务文件、开机启动链接、sr 快捷命令，以及当前脚本和本脚本的更新备份。"
    echo
    warn "不会清空整台 VPS 的系统日志、Shell 历史、文件系统日志/快照或服务商记录。"
    warn "这些记录由操作系统或 VPS 平台管理，无法只针对本脚本安全、完整地逐项清除；强行清空会影响其他服务。"
    warn "脚本没有安装防火墙规则，因此不会改动系统或云厂商防火墙。"
    echo
    read -r -p "确认深度卸载？请输入 DELETE: " confirm
    if [[ "$confirm" != DELETE ]]; then
        warn "已取消卸载，没有删除任何文件。"
        return 0
    fi

    # 先记下脚本路径。SCRIPT_PATH 是 readlink -f 得到的真实路径，
    # 只有它确实是持久化普通文件时才会在最后删除，避免误删 /proc、/dev 等路径。
    if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" && \
          "$SCRIPT_PATH" != /proc/* && "$SCRIPT_PATH" != /sys/* && \
          "$SCRIPT_PATH" != /dev/* ]]; then
        script_to_remove="$SCRIPT_PATH"
        script_files+=("$script_to_remove" "${script_to_remove}.bak" "${script_to_remove}.new")
    fi

    info "正在停止流量监控服务..."
    systemctl disable --now "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true

    # 先根据 systemd 当前登记的服务单元清理 hy2@ 实例，
    # 再根据节点目录逐个清理，兼容服务单元状态与目录不一致的情况。
    while IFS= read -r unit_file; do
        [[ "$unit_file" == hy2@*.service ]] || continue
        [[ "$unit_file" == "${SERVICE_PREFIX}.service" ]] && continue
        systemctl disable --now "$unit_file" >/dev/null 2>&1 || true
    done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}')

    for d in "$NODES_DIR"/node-*; do
        [[ -d "$d" ]] || continue
        node_id="${d##*/}"
        unit="${SERVICE_PREFIX}${node_id}.service"
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done

    info "正在删除 HY2 专属 systemd 文件及启动链接..."
    rm -f -- "$SERVICE_FILE" "$TRAFFIC_SERVICE_FILE"

    # systemctl disable 通常会删除这些链接；这里再清理本脚本命名空间下残留的链接。
    for d in /etc/systemd/system/multi-user.target.wants /etc/systemd/system/network-online.target.wants; do
        [[ -d "$d" ]] || continue
        for unit_file in "$d"/hy2@*.service "$d"/hy2-traffic-monitor.service; do
            [[ -e "$unit_file" || -L "$unit_file" ]] || continue
            rm -f -- "$unit_file"
        done
    done

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$TRAFFIC_SERVICE" 'hy2@*.service' >/dev/null 2>&1 || true

    # 仅删除指向当前脚本的 sr 符号链接，避免误删用户自己的同名命令。
    # 必须在删除 HY2_HOME 和脚本本体之前判断目标，否则链接可能已经变成断链。
    sr_path="/usr/local/bin/sr"
    if [[ -L "$sr_path" ]]; then
        sr_target="$(readlink -f "$sr_path" 2>/dev/null || true)"
        if [[ -n "$script_to_remove" && "$sr_target" == "$script_to_remove" ]]; then
            rm -f -- "$sr_path"
        fi
    fi

    info "正在删除 HY2 安装目录（包括核心、节点配置、证书、认证信息和流量数据）..."
    rm -rf -- "$HY2_HOME"

    # 删除当前正在执行的脚本以及由在线更新功能生成的备份/临时替换文件。
    # Linux 允许删除正在运行的脚本文件；当前进程退出后该文件即不再有目录项。
    if ((${#script_files[@]} > 0)); then
        rm -f -- "${script_files[@]}"
    fi

    ok "HY2 深度卸载完成。"
    echo "已删除：/opt/hy2、HY2 systemd 服务、sr 快捷命令（若指向本脚本）、当前脚本及其更新备份。"
    echo "注意：系统日志、Shell 历史、文件系统快照/日志和 VPS 平台记录不属于脚本文件，仍可能保留操作痕迹。"
    echo "退出后，HY2 本身不再保留可运行文件或配置。"
}

# -------------------------- 初始化 --------------------------
initialize() {
    require_root
    require_systemd
    install_missing_commands
    mkdir -p "${HY2_HOME}/bin" "$NODES_DIR" "$CERT_DIR" "$DATA_DIR"
    chmod 700 "$HY2_HOME" "$DATA_DIR"
    ensure_persistent_script || exit 1
    if [[ ! -x "$HY2_BIN" ]]; then install_or_update_core; fi
    create_shared_auth
    create_self_signed_cert
    write_systemd_template
    AUTH_PASS="$(cat "$AUTH_FILE")"
    install_shortcut
    migrate_existing_nodes_traffic
    refresh_traffic_monitor
}

# -------------------------- 主菜单 --------------------------
show_menu() {
    clear 2>/dev/null || true
    echo "=============================================="
    echo "          HY2 轻量化多节点管理脚本"
    echo "=============================================="
    echo "  1. 创建节点（DIRECT / SOCKS5）"
    echo "  2. 查看所有节点（显示分享链接）"
    echo "  3. 删除节点（按序号选择）"
    echo "  4. 启动节点（选择单个或所有节点）"
    echo "  5. 停止节点（选择单个或所有节点）"
    echo "  6. 重启所有节点"
    echo "  7. 查看节点实时日志"
    echo "  8. 修改 SOCKS5 节点的代理配置"
    echo "  9. 修改分享链接中的 VPS 地址"
    echo " 10. 更新 Hysteria 2 核心"
    echo " 11. 在线更新脚本"
    echo " 12. 深度卸载"
    echo " 13. 节点流量管理（统计 / 限额 / 周期重置）"
    echo "  0. 退出脚本"
    echo "=============================================="
    if [[ -x "$HY2_BIN" ]]; then printf '当前核心：%s\n' "$($HY2_BIN version 2>/dev/null | head -n 1 || echo 未知)"; fi
    echo
}

# -------------------------- 主程序 --------------------------
main() {
    initialize
    while true; do
        show_menu
        read -r -p "请输入选项 [0-13]: " choice || exit 0
        case "$choice" in
            1) create_node; pause ;;
            2) list_nodes; pause ;;
            3) delete_node; pause ;;
            4) start_nodes_interactive; pause ;;
            5) stop_nodes_interactive; pause ;;
            6) restart_all_nodes; pause ;;
            7) show_node_logs; pause ;;
            8) update_socks_node; pause ;;
            9) change_server_addr; pause ;;
            10) install_or_update_core; pause ;;
            11) update_script; pause ;;
            12) uninstall_all; exit 0 ;;
            13) traffic_management_menu ;;
            0) exit 0 ;;
            *) warn "无效选项，请输入 0-13。"; sleep 1 ;;
        esac
    done
}

# systemd 流量监控进程通过参数调用同一脚本，避免额外安装 Python/jq。
if [[ "${1:-}" == "--traffic-monitor" ]]; then
    traffic_monitor_loop
    exit 0
fi

main "$@"