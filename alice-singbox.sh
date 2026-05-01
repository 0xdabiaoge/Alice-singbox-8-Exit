#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
DATA_DIR="/var/lib/sing-box"
LOG_FILE="/var/log/sing-box.log"
SOCKS_CONFIG_FILE="${DATA_DIR}/socks5-outbounds.json"
WATCHDOG_PAUSE_FILE="${DATA_DIR}/watchdog.paused"
WATCHDOG_SCRIPT="/usr/local/bin/sing-box-watchdog"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARED_DIR="/etc/cloudflared"
CLOUDFLARED_RUNNER="/usr/local/bin/cloudflared-alice-run"
CLOUDFLARED_TOKEN_FILE="${CLOUDFLARED_DIR}/alice-token"
CLOUDFLARED_MARKER_FILE="${CLOUDFLARED_DIR}/alice-installed"
CLOUDFLARED_LOG_FILE="/var/log/cloudflared-alice.log"
CLOUDFLARED_PID_FILE="/run/cloudflared-alice.pid"
ARGO_METADATA_FILE="${DATA_DIR}/argo_metadata.json"
OS_TYPE=""      # debian 或 alpine
ARCH=""         # amd64, arm64, armv7 等
GITHUB_PROXY="" # GitHub 加速源
CLOUDFLARED_EDGE_IP_VERSION="6" # 纯 IPv6 机器必须强制 cloudflared 连接 IPv6 edge

# SOCKS5 出口默认配置，运行时可按回车沿用，也可自定义
SOCKS5_SERVER="2a14:67c0:116::1"
SOCKS5_USER="alice"
SOCKS5_PASS="alicefofo123..OVO"
SOCKS5_PORTS=(10001 10002 10003 10004 10005 10006 10007 10008)

# GitHub 加速源列表
GITHUB_PROXIES=(
    "https://ghfast.top/"
    "https://gitproxy.goodvps.org/"
    "https://ghproxylist.com/"
    "https://gh-proxy.com/"
    "https://hub.814560.xyz/"
    "https://hub.glowp.xyz/"
    "https://gh-v6.com/"
    "https://ghfile.geekertao.top/"
    "https://gh.felicity.ac.cn/"
    "https://proxy.vvvv.ee/"
    "https://ghproxy.lvedong.eu.org/"
    "https://proxy.ooo.vg/"
)

# ============================================
# 工具函数
# ============================================

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 生成 UUID
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        # 使用 /dev/urandom 生成
        od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}'
    fi
}

# 生成随机字符串
generate_random_string() {
    local length=${1:-16}
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
}

generate_random_hex() {
    local length=${1:-16}
    if command -v sing-box &>/dev/null; then
        sing-box generate rand --hex "$length"
    else
        od -An -tx1 -N "$length" /dev/urandom | tr -d ' \n' | cut -c 1-"$length"
    fi
}

generate_random_port() {
    local port
    for _ in {1..20}; do
        port=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 50001 + 10000 ))
        if ! config_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

# 生成 Shadowsocks 2022 密钥 (Base64)
generate_ss2022_key() {
    local bits=${1:-128}
    local bytes=$((bits / 8))
    dd if=/dev/urandom bs=1 count=$bytes 2>/dev/null | base64_no_wrap
}

# 检查命令是否存在
check_command() {
    command -v "$1" &>/dev/null
}

require_command() {
    if ! command -v "$1" &>/dev/null; then
        print_error "缺少依赖命令: $1，请先执行菜单 1 安装依赖/更新 sing-box"
        return 1
    fi
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_valid_port() {
    is_integer "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_port() {
    local port="$1"
    local name="${2:-端口}"

    if ! is_valid_port "$port"; then
        print_error "${name}必须是 1-65535 的数字"
        return 1
    fi

    if [ "$port" -lt 1000 ]; then
        print_error "${name}建议 > 1000"
        return 1
    fi
}

validate_public_port() {
    local port="$1"
    local name="${2:-端口}"

    if ! is_valid_port "$port"; then
        print_error "${name}必须是 1-65535 的数字"
        return 1
    fi
}

validate_domain() {
    local domain="$1"
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        return 1
    fi

    if [[ ! "$domain" =~ ^[A-Za-z0-9._-]+$ ]]; then
        print_error "域名只能包含字母、数字、点、下划线和连字符"
        return 1
    fi
}

normalize_ws_path() {
    local path="$1"
    if [ -z "$path" ]; then
        path="/"
    fi
    if [[ "$path" != /* ]]; then
        path="/${path}"
    fi
    echo "$path"
}

base64_no_wrap() {
    base64 | tr -d '\n'
}

urlencode() {
    local value="$1"
    if command -v jq &>/dev/null; then
        jq -rn --arg v "$value" '$v|@uri'
    else
        echo "$value" | sed 's|/|%2F|g; s| |%20|g'
    fi
}

format_address() {
    local address="$1"
    if [[ "$address" == *:* && "$address" != \[*\] ]]; then
        echo "[${address}]"
    else
        echo "$address"
    fi
}

normalize_connect_address() {
    local address="$1"
    address=$(printf '%s' "$address" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    address="${address#http://}"
    address="${address#https://}"
    address="${address%%/*}"
    address="${address#[}"
    address="${address%]}"
    printf '%s' "$address"
}

socks5_proxy_url() {
    local port="$1"
    local server
    server=$(format_address "$SOCKS5_SERVER")
    printf 'socks5h://%s:%s' "$server" "$port"
}

ensure_runtime_ready() {
    require_command jq || return 1
    require_command sing-box || return 1
    ensure_dirs
}

# 按回车继续
press_enter() {
    echo ""
    read -rp "按 Enter 键继续..."
}

# 生成自签名证书
generate_self_signed_cert() {
    local domain="$1"
    local cert_dir="${DATA_DIR}/certs"
    local cert_file="${cert_dir}/${domain}.pem"
    local key_file="${cert_dir}/${domain}.key"
    
    mkdir -p "$cert_dir"
    
    # 检查 openssl 是否可用
    if ! command -v openssl &>/dev/null; then
        print_error "openssl 未安装，无法生成自签名证书"
        return 1
    fi
    
    print_info "正在生成自签名证书..."
    
    # 生成自签名证书 (有效期 3650 天)
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain},DNS:*.${domain}" \
        2>/dev/null
    
    if [ $? -eq 0 ] && [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        chmod 644 "$cert_file" 2>/dev/null || true
        chmod 600 "$key_file" 2>/dev/null || true
        print_success "自签名证书生成成功"
        print_info "证书路径: $cert_file"
        print_info "密钥路径: $key_file"
        
        # 设置全局变量供调用者使用
        GENERATED_CERT_PATH="$cert_file"
        GENERATED_KEY_PATH="$key_file"
        return 0
    else
        print_error "自签名证书生成失败"
        return 1
    fi
}

# ============================================
# 系统检测
# ============================================

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu|linuxmint)
                OS_TYPE="debian"
                ;;
            alpine)
                OS_TYPE="alpine"
                ;;
            *)
                print_error "不支持的操作系统: $ID"
                exit 1
                ;;
        esac
    else
        print_error "无法检测操作系统"
        exit 1
    fi
    print_success "检测到系统: $OS_TYPE"
}

detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armv7"
            ;;
        i386|i686)
            ARCH="386"
            ;;
        *)
            print_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
    print_success "检测到架构: $ARCH"
}

# ============================================
# GitHub 加速源检测
# ============================================

normalize_github_proxy() {
    local proxy="$1"
    proxy=$(printf '%s' "$proxy" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$proxy" ] && [[ "$proxy" != */ ]]; then
        proxy="${proxy}/"
    fi
    printf '%s' "$proxy"
}

is_success_http_code() {
    local code="$1"
    [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

check_github_proxy() {
    local target_url="${1:-https://github.com/SagerNet/sing-box/releases/latest}"
    local best_proxy=""
    local best_latency=""
    local candidates=("" "${GITHUB_PROXIES[@]}")
    local seen="|"

    print_info "检测 GitHub 直连和加速源延迟..."

    for raw_proxy in "${candidates[@]}"; do
        local proxy
        proxy=$(normalize_github_proxy "$raw_proxy")
        local key="${proxy:-DIRECT}"
        case "$seen" in
            *"|${key}|"*) continue ;;
        esac
        seen="${seen}${key}|"

        local name="${proxy:-直连 GitHub}"
        local url="${proxy}${target_url}"
        local result http_code latency

        result=$(curl -L -s -o /dev/null -H 'Range: bytes=0-0' --connect-timeout 5 --max-time 15 -w '%{http_code} %{time_total}' "$url" 2>/dev/null) || {
            print_warning "$name 不可达"
            continue
        }

        http_code="${result%% *}"
        latency="${result##* }"

        if ! is_success_http_code "$http_code"; then
            print_warning "$name 不可用 (HTTP $http_code)"
            continue
        fi

        print_info "$name 可达，延迟 ${latency}s，HTTP $http_code"

        if [ -z "$best_latency" ] || awk -v a="$latency" -v b="$best_latency" 'BEGIN { exit !(a < b) }'; then
            best_latency="$latency"
            best_proxy="$proxy"
        fi
    done

    if [ -n "$best_latency" ]; then
        GITHUB_PROXY="$best_proxy"
        if [ -n "$GITHUB_PROXY" ]; then
            print_success "选择延迟最低加速源: $GITHUB_PROXY (${best_latency}s)"
        else
            print_success "选择 GitHub 直连 (${best_latency}s)"
        fi
        return 0
    fi

    print_error "GitHub 直连和所有加速源均不可用"
    return 1
}

# 获取加速后的 URL
get_proxied_url() {
    local url="$1"
    if [ -n "$GITHUB_PROXY" ]; then
        echo "$(normalize_github_proxy "$GITHUB_PROXY")${url}"
    else
        echo "$url"
    fi
}

fetch_latest_singbox_version() {
    local proxy="$1"
    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local latest_url="https://github.com/SagerNet/sing-box/releases/latest"
    local response tag location effective_url

    response=$(curl -fsSL --connect-timeout 8 --max-time 20 "${proxy}${api_url}" 2>/dev/null) || response=""
    tag=$(printf '%s\n' "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)

    if [[ "$tag" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]]; then
        echo "$tag"
        return 0
    fi

    effective_url=$(curl -fsSL -o /dev/null --connect-timeout 8 --max-time 20 -w '%{url_effective}' "${proxy}${latest_url}" 2>/dev/null) || effective_url=""
    tag=$(printf '%s\n' "$effective_url" | sed -n 's|.*releases/tag/v\{0,1\}\([0-9][0-9A-Za-z._-]*\).*|\1|p' | head -n 1)

    if [[ "$tag" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]]; then
        echo "$tag"
        return 0
    fi

    location=$(curl -fsSLI --connect-timeout 8 --max-time 20 "${proxy}${latest_url}" 2>/dev/null | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tail -n 1 | tr -d '\r')
    tag="${location##*/}"
    tag="${tag#v}"

    if [[ "$tag" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]]; then
        echo "$tag"
        return 0
    fi

    response=$(curl -fsSL --connect-timeout 8 --max-time 20 "${proxy}${latest_url}" 2>/dev/null) || response=""
    tag=$(printf '%s\n' "$response" | sed -n 's|.*releases/tag/v\{0,1\}\([0-9][0-9A-Za-z._-]*\).*|\1|p' | head -n 1)

    if [[ "$tag" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]]; then
        echo "$tag"
        return 0
    fi

    return 1
}

get_latest_singbox_version() {
    local allow_fallback="${1:-1}"
    local candidates
    if [ "$allow_fallback" -eq 1 ]; then
        candidates=("$GITHUB_PROXY" "" "${GITHUB_PROXIES[@]}")
    else
        candidates=("$GITHUB_PROXY")
    fi
    local seen="|"
    local raw_proxy proxy key tag

    for raw_proxy in "${candidates[@]}"; do
        proxy=$(normalize_github_proxy "$raw_proxy")
        key="${proxy:-DIRECT}"
        case "$seen" in
            *"|${key}|"*) continue ;;
        esac
        seen="${seen}${key}|"

        tag=$(fetch_latest_singbox_version "$proxy") || tag=""
        if [[ "$tag" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]]; then
            GITHUB_PROXY="$proxy"
            echo "$tag"
            return 0
        fi
    done

    return 1
}

# ============================================
# 安装依赖
# ============================================

install_dependencies() {
    print_info "安装依赖..."
    
    if [ "$OS_TYPE" = "debian" ]; then
        apt-get update -qq
        apt-get install -y -qq bash curl wget jq openssl qrencode tar gzip iproute2 coreutils file ca-certificates
    elif [ "$OS_TYPE" = "alpine" ]; then
        apk update
        apk add bash curl wget jq openssl libqrencode-tools tar gzip iproute2 coreutils file ca-certificates
    fi
    
    print_success "依赖安装完成"
}

# ============================================
# Sing-box 安装
# ============================================

install_singbox() {
    echo ""
    print_info "=== 安装 sing-box ==="
    echo ""
    echo "请选择安装方式:"
    echo "1. 在线安装 (通过 GitHub 加速源下载)"
    echo "2. 本地安装 (使用已下载的文件)"
    echo ""
    read -rp "选择 [1-2] (默认 1): " install_mode
    install_mode=${install_mode:-1}
    
    case "$install_mode" in
        1)
            install_singbox_online
            ;;
        2)
            install_singbox_local
            ;;
        *)
            install_singbox_online
            ;;
    esac
}

# 在线安装
install_singbox_online() {
    print_info "开始在线安装 sing-box..."
    local auto_proxy=1
    
    echo ""
    read -rp "GitHub 加速源 (回车自动测速选择最快；输入 custom 手动指定): " proxy_choice

    if [ "$proxy_choice" = "custom" ]; then
        read -rp "输入加速源 URL: " custom_proxy
        if [ -z "$custom_proxy" ]; then
            print_error "加速源不能为空"
            return 1
        fi
        GITHUB_PROXY="$(normalize_github_proxy "$custom_proxy")"
        auto_proxy=0
    else
        check_github_proxy || return 1
    fi

    if [ -n "$GITHUB_PROXY" ]; then
        print_info "使用加速源: $GITHUB_PROXY"
    else
        print_info "使用 GitHub 直连"
    fi
    
    # 自动使用最新稳定版本
    echo ""
    local version=""
    print_info "获取 sing-box 最新稳定版本..."
    version=$(get_latest_singbox_version "$auto_proxy") || version=""

    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]]; then
        print_error "无法获取 sing-box 最新稳定版本，请检查 GitHub 连通性或加速源"
        return 1
    fi
    
    print_success "安装最新稳定版本: v$version"
    
    # 下载文件名
    local filename="sing-box-${version}-linux-${ARCH}.tar.gz"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${filename}"
    local proxied_url
    if [ "$auto_proxy" -eq 1 ]; then
        check_github_proxy "$download_url" || return 1
    fi
    proxied_url=$(get_proxied_url "$download_url")
    
    print_info "下载: $proxied_url"
    
    # 下载并解压
    local tmp_dir="/tmp/sing-box-install"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    
    if ! curl -Lf --progress-bar -o "${tmp_dir}/${filename}" "$proxied_url"; then
        print_error "下载失败: 请检查网络连接或更换 GitHub 加速源"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    print_info "解压文件..."
    if ! tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir"; then
        print_error "解压失败: 文件可能已损坏"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # 安装二进制
    # 首先尝试标准路径
    local bin_path="${tmp_dir}/sing-box-${version}-linux-${ARCH}/sing-box"
    
    # 如果标准路径不存在，尝试自动查找
    if [ ! -f "$bin_path" ]; then
        print_info "标准路径未找到二进制文件，尝试搜索..."
        local found_bin=$(find "$tmp_dir" -name "sing-box" -type f | head -n 1)
        if [ -n "$found_bin" ]; then
            bin_path="$found_bin"
            print_success "已找到 sing-box 二进制文件: $bin_path"
        else
            print_error "解压失败，无法找到 sing-box 二进制文件"
            ls -R "$tmp_dir"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    
    cp "$bin_path" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    
    # 创建目录
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$DATA_DIR"
    
    # 安装服务
    install_service
    
    # 清理
    rm -rf "$tmp_dir"
    
    print_success "sing-box v$version 安装完成"
    sing-box version
}

# 本地安装
install_singbox_local() {
    print_info "本地安装 sing-box..."
    echo ""
    echo "请提供 sing-box 文件:"
    echo "1. 提供 tar.gz 压缩包路径"
    echo "2. 提供已解压的 sing-box 二进制文件路径"
    echo ""
    read -rp "选择 [1-2] (默认 2): " file_type
    file_type=${file_type:-2}
    
    read -rp "文件路径: " file_path
    
    if [ ! -f "$file_path" ]; then
        print_error "文件不存在: $file_path"
        return 1
    fi
    
    local bin_path=""
    
    if [ "$file_type" = "1" ]; then
        # 解压 tar.gz
        local tmp_dir="/tmp/sing-box-install"
        rm -rf "$tmp_dir"
        mkdir -p "$tmp_dir"
        
        print_info "解压文件..."
        if ! tar -xzf "$file_path" -C "$tmp_dir"; then
            print_error "解压失败: 文件可能已损坏"
            rm -rf "$tmp_dir"
            return 1
        fi
        
        # 查找 sing-box 二进制
        bin_path=$(find "$tmp_dir" -name "sing-box" -type f | head -1)
        
        if [ -z "$bin_path" ]; then
            print_error "在压缩包中找不到 sing-box 二进制文件"
            return 1
        fi
    else
        bin_path="$file_path"
    fi
    
    # 验证是否是有效的二进制文件
    if ! file "$bin_path" | grep -q "executable"; then
        print_warning "文件可能不是有效的可执行文件"
    fi
    
    # 安装
    cp "$bin_path" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    
    # 创建目录
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$DATA_DIR"
    
    # 安装服务
    install_service
    
    # 清理临时目录
    rm -rf /tmp/sing-box-install
    
    print_success "sing-box 安装完成"
    sing-box version
}

install_watchdog() {
    ensure_dirs

    cat > "$WATCHDOG_SCRIPT" <<EOF
#!/bin/sh
PAUSE_FILE="$WATCHDOG_PAUSE_FILE"
CONFIG_FILE="$CONFIG_FILE"
ARGO_METADATA_FILE="$ARGO_METADATA_FILE"
CLOUDFLARED_BIN="$CLOUDFLARED_BIN"
CLOUDFLARED_EDGE_IP_VERSION="$CLOUDFLARED_EDGE_IP_VERSION"

[ -f "\$PAUSE_FILE" ] && exit 0
[ -x /usr/local/bin/sing-box ] || exit 0
[ -f "\$CONFIG_FILE" ] || exit 0

if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet sing-box || systemctl start sing-box >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1; then
    rc-service sing-box status >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1
fi

if [ -x "\$CLOUDFLARED_BIN" ] && [ -f "\$ARGO_METADATA_FILE" ] && command -v jq >/dev/null 2>&1; then
    jq -r 'to_entries[] | [.value.local_port, .value.type, (.value.token // "")] | @tsv' "\$ARGO_METADATA_FILE" 2>/dev/null | while IFS='	' read -r port argo_type token; do
        [ -n "\$port" ] || continue
        pid_file="/tmp/singbox_argo_\${port}.pid"
        log_file="/tmp/singbox_argo_\${port}.log"
        running=false

        if [ -f "\$pid_file" ]; then
            pid=\$(cat "\$pid_file" 2>/dev/null)
            if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then
                running=true
            fi
        fi

        [ "\$running" = true ] && continue

        if [ "\$argo_type" = "fixed" ] && [ -n "\$token" ]; then
            nohup "\$CLOUDFLARED_BIN" tunnel --edge-ip-version "\$CLOUDFLARED_EDGE_IP_VERSION" --protocol http2 --no-autoupdate run --token "\$token" > "\$log_file" 2>&1 &
        else
            nohup "\$CLOUDFLARED_BIN" tunnel --edge-ip-version "\$CLOUDFLARED_EDGE_IP_VERSION" --protocol http2 --no-autoupdate --url "http://127.0.0.1:\${port}" --logfile "\$log_file" > /dev/null 2>&1 &
        fi
        echo \$! > "\$pid_file"
    done
fi
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    if [ "$OS_TYPE" = "debian" ]; then
        cat > /etc/systemd/system/sing-box-watchdog.service <<EOF
[Unit]
Description=sing-box watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

        cat > /etc/systemd/system/sing-box-watchdog.timer <<EOF
[Unit]
Description=Run sing-box watchdog every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=sing-box-watchdog.service

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now sing-box-watchdog.timer
        print_success "systemd watchdog 已安装"
    elif [ "$OS_TYPE" = "alpine" ]; then
        if ! grep -Fq "$WATCHDOG_SCRIPT" /etc/crontabs/root 2>/dev/null; then
            echo "* * * * * $WATCHDOG_SCRIPT >/dev/null 2>&1" >> /etc/crontabs/root
        fi
        if command -v rc-service &>/dev/null; then
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
        fi
        print_success "OpenRC/cron watchdog 已安装"
    fi
}

install_service() {
    if [ "$OS_TYPE" = "debian" ]; then
        # systemd 服务
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
        print_success "systemd 服务已安装"
        
    elif [ "$OS_TYPE" = "alpine" ]; then
        # OpenRC 服务
        cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -o root:root -m 0644 "$output_log"
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        print_success "OpenRC 服务已安装"
    fi

    install_watchdog
}

cloudflared_arch() {
    case "$ARCH" in
        amd64|arm64|386)
            echo "$ARCH"
            ;;
        armv7)
            echo "arm"
            ;;
        *)
            return 1
            ;;
    esac
}

install_cloudflared() {
    if [ -x "$CLOUDFLARED_BIN" ]; then
        return 0
    fi

    local cf_arch
    cf_arch=$(cloudflared_arch) || {
        print_error "cloudflared 不支持当前架构: $ARCH"
        return 1
    }

    print_info "安装 cloudflared..."

    local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    local proxied_url
    check_github_proxy "$download_url" || return 1
    proxied_url=$(get_proxied_url "$download_url")
    local tmp_file="/tmp/cloudflared-linux-${cf_arch}"

    if ! curl -Lf --progress-bar -o "$tmp_file" "$proxied_url"; then
        print_error "cloudflared 下载失败"
        rm -f "$tmp_file"
        return 1
    fi

    chmod +x "$tmp_file"
    cp "$tmp_file" "$CLOUDFLARED_BIN"
    chmod +x "$CLOUDFLARED_BIN"
    rm -f "$tmp_file"
    mkdir -p "$CLOUDFLARED_DIR"
    touch "$CLOUDFLARED_MARKER_FILE"

    print_success "cloudflared 安装完成"
}

extract_argo_token() {
    local input="$1"
    local token=""

    token=$(printf '%s' "$input" | grep -oE 'ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -n 1)
    if [ -z "$token" ]; then
        token=$(printf '%s' "$input" | grep -oE 'ey[A-Za-z0-9_-]{20,}' | head -n 1)
    fi
    if [ -z "$token" ]; then
        token="$input"
    fi

    printf '%s' "$token"
}

argo_pid_file() {
    echo "/tmp/singbox_argo_${1}.pid"
}

argo_log_file() {
    echo "/tmp/singbox_argo_${1}.log"
}

stop_argo_tunnel() {
    local target_port="$1"
    [ -n "$target_port" ] || return 0

    local pid_file log_file pid
    pid_file=$(argo_pid_file "$target_port")
    log_file=$(argo_log_file "$target_port")

    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            print_success "Argo 隧道 (端口: $target_port) 已停止"
        fi
        rm -f "$pid_file" "$log_file"
    fi
}

stop_all_argo_tunnels() {
    local pid_file filename port
    print_info "正在停止所有 Argo 隧道..."

    if [ -f "$ARGO_METADATA_FILE" ] && command -v jq &>/dev/null; then
        while IFS= read -r port; do
            [ -n "$port" ] && [ "$port" != "null" ] && stop_argo_tunnel "$port"
        done < <(jq -r 'to_entries[]?.value.local_port // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    for pid_file in /tmp/singbox_argo_*.pid; do
        [ -e "$pid_file" ] || continue
        filename=$(basename "$pid_file")
        port=${filename#singbox_argo_}
        port=${port%.pid}
        stop_argo_tunnel "$port"
    done
}

start_argo_tunnel() {
    local target_port="$1"
    local token="${2:-}"
    local pid_file log_file old_pid cf_pid tunnel_domain wait_count max_wait

    ARGO_TUNNEL_DOMAIN=""
    pid_file=$(argo_pid_file "$target_port")
    log_file=$(argo_log_file "$target_port")

    install_cloudflared || return 1

    print_info "正在启动 Argo 隧道 (端口: $target_port)..."

    if [ -f "$pid_file" ]; then
        old_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            print_warning "检测到端口 $target_port 的 Argo 隧道已在运行 (PID: $old_pid)，先停止旧进程"
            stop_argo_tunnel "$target_port"
        fi
    fi

    rm -f "$log_file"

    if [ -n "$token" ]; then
        print_info "启动固定隧道 (Token 模式)..."
        nohup "$CLOUDFLARED_BIN" tunnel --edge-ip-version "$CLOUDFLARED_EDGE_IP_VERSION" --protocol http2 --no-autoupdate run --token "$token" > "$log_file" 2>&1 &
        cf_pid=$!
        echo "$cf_pid" > "$pid_file"

        sleep 5
        if ! kill -0 "$cf_pid" 2>/dev/null; then
            print_error "cloudflared 进程已退出，Token 可能无效或网络连接被拒绝"
            tail -n 20 "$log_file" 2>/dev/null || true
            rm -f "$pid_file"
            return 1
        fi

        print_success "Argo 固定隧道 (端口: $target_port) 启动成功"
        return 0
    fi

    print_info "启动临时隧道，指向 127.0.0.1:${target_port}，Cloudflare Edge IPv${CLOUDFLARED_EDGE_IP_VERSION}..."
    nohup "$CLOUDFLARED_BIN" tunnel --edge-ip-version "$CLOUDFLARED_EDGE_IP_VERSION" --protocol http2 --no-autoupdate --url "http://127.0.0.1:${target_port}" \
        --logfile "$log_file" \
        > /dev/null 2>&1 &

    cf_pid=$!
    echo "$cf_pid" > "$pid_file"

    print_info "等待隧道建立 (最多30秒)..."
    tunnel_domain=""
    wait_count=0
    max_wait=30

    while [ "$wait_count" -lt "$max_wait" ]; do
        sleep 2
        wait_count=$((wait_count + 2))

        if ! kill -0 "$cf_pid" 2>/dev/null; then
            print_error "cloudflared 进程已退出，请检查日志: $log_file"
            tail -n 20 "$log_file" 2>/dev/null || true
            rm -f "$pid_file"
            return 1
        fi

        if [ -f "$log_file" ]; then
            tunnel_domain=$(grep -oE 'https?://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | head -n 1 | sed -E 's|https?://||')
            if [ -n "$tunnel_domain" ]; then
                break
            fi
        fi
    done

    if [ -z "$tunnel_domain" ]; then
        print_error "获取临时域名超时，请检查网络。日志最后几行:"
        tail -n 5 "$log_file" 2>/dev/null || true
        kill "$cf_pid" 2>/dev/null || true
        rm -f "$pid_file"
        return 1
    fi

    print_info "域名已获取，正在进行稳定性测试 (5秒)..."
    sleep 5
    if ! kill -0 "$cf_pid" 2>/dev/null; then
        print_error "稳定性测试失败：cloudflared 进程异常退出"
        tail -n 10 "$log_file" 2>/dev/null || true
        rm -f "$pid_file"
        return 1
    fi

    ARGO_TUNNEL_DOMAIN="$tunnel_domain"
    print_success "Argo 临时隧道建立成功: $tunnel_domain"
}

ws_probe_code() {
    local url="$1"
    local host_header="${2:-}"
    local code
    local curl_args=(
        -k
        --http1.1
        -sS
        -o /dev/null
        --connect-timeout 5
        --max-time 10
        -w '%{http_code}'
        -H 'Connection: Upgrade'
        -H 'Upgrade: websocket'
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='
        -H 'Sec-WebSocket-Version: 13'
    )

    if [ -n "$host_header" ]; then
        curl_args+=(-H "Host: $host_header")
    fi

    code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || code="${code:-000}"
    printf '%s' "${code:-000}"
}

wait_for_ws_101() {
    local url="$1"
    local host_header="${2:-}"
    local label="${3:-WebSocket}"
    local max_wait="${4:-12}"
    local waited=0
    local code="000"

    while [ "$waited" -lt "$max_wait" ]; do
        code=$(ws_probe_code "$url" "$host_header")
        if [ "$code" = "101" ]; then
            print_success "$label 自检通过 (HTTP 101)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    print_warning "$label 自检未通过，最后 HTTP 状态: $code"
    return 1
}

# ============================================
# 配置生成 (追加模式)
# ============================================

# 读取已保存的 SOCKS5 出口配置
load_socks5_config() {
    if [ ! -f "$SOCKS_CONFIG_FILE" ] || ! command -v jq &>/dev/null; then
        return 0
    fi

    if ! jq -e '.server and .username and .password and (.ports | type == "array" and length == 8)' "$SOCKS_CONFIG_FILE" >/dev/null 2>&1; then
        print_warning "SOCKS5 配置文件格式错误，继续使用脚本默认值"
        return 0
    fi

    SOCKS5_SERVER=$(jq -r '.server' "$SOCKS_CONFIG_FILE")
    SOCKS5_USER=$(jq -r '.username' "$SOCKS_CONFIG_FILE")
    SOCKS5_PASS=$(jq -r '.password' "$SOCKS_CONFIG_FILE")

    local loaded_ports=()
    while IFS= read -r port; do
        loaded_ports+=("$port")
    done < <(jq -r '.ports[]' "$SOCKS_CONFIG_FILE")

    if validate_socks5_ports "${loaded_ports[@]}"; then
        SOCKS5_PORTS=("${loaded_ports[@]}")
    fi
}

validate_socks5_ports() {
    if [ "$#" -ne 8 ]; then
        print_error "SOCKS5 出口端口必须正好填写 8 个"
        return 1
    fi

    local seen=" "
    local port
    for port in "$@"; do
        if ! is_valid_port "$port"; then
            print_error "无效 SOCKS5 端口: $port"
            return 1
        fi
        if [[ "$seen" == *" $port "* ]]; then
            print_error "SOCKS5 端口重复: $port"
            return 1
        fi
        seen="${seen}${port} "
    done
}

save_socks5_config() {
    require_command jq || return 1
    ensure_dirs

    local ports_json
    ports_json=$(printf '%s\n' "${SOCKS5_PORTS[@]}" | jq -R 'tonumber' | jq -s .) || return 1

    jq -n \
        --arg server "$SOCKS5_SERVER" \
        --arg username "$SOCKS5_USER" \
        --arg password "$SOCKS5_PASS" \
        --argjson ports "$ports_json" \
        '{server:$server, username:$username, password:$password, ports:$ports}' > "$SOCKS_CONFIG_FILE"
    chmod 600 "$SOCKS_CONFIG_FILE" 2>/dev/null || true
}

configure_socks5_outbounds() {
    local apply_to_config="${1:-true}"

    require_command jq || return 1
    ensure_dirs
    load_socks5_config

    echo ""
    print_info "=== 配置 SOCKS5 出口 ==="
    print_info "直接回车将沿用当前默认值"

    local server username password ports_input
    read -rp "SOCKS5 服务器 (默认 $SOCKS5_SERVER): " server
    read -rp "SOCKS5 用户名 (默认 $SOCKS5_USER): " username
    read -rsp "SOCKS5 密码 (默认使用当前密码): " password
    echo ""
    read -rp "8 个 SOCKS5 端口，逗号分隔 (默认 ${SOCKS5_PORTS[*]}): " ports_input

    SOCKS5_SERVER="${server:-$SOCKS5_SERVER}"
    SOCKS5_USER="${username:-$SOCKS5_USER}"
    SOCKS5_PASS="${password:-$SOCKS5_PASS}"

    if [ -n "$ports_input" ]; then
        ports_input="${ports_input// /}"
        local new_ports=()
        IFS=',' read -r -a new_ports <<< "$ports_input"
        validate_socks5_ports "${new_ports[@]}" || return 1
        SOCKS5_PORTS=("${new_ports[@]}")
    else
        validate_socks5_ports "${SOCKS5_PORTS[@]}" || return 1
    fi

    save_socks5_config || return 1
    print_success "SOCKS5 出口配置已保存: $SOCKS_CONFIG_FILE"

    if [ "$apply_to_config" = "true" ] && [ -f "$CONFIG_FILE" ]; then
        update_socks5_outbounds_in_config || return 1
        restart_service
    fi
}

# 生成 8 个 SOCKS5 出口 JSON 数组
generate_socks5_outbounds() {
    require_command jq || return 1
    load_socks5_config

    local outbounds_json="[]"
    
    for i in {1..8}; do
        local port="${SOCKS5_PORTS[$((i-1))]}"
        local socks_tag="socks-out-$i"

        outbounds_json=$(echo "$outbounds_json" | jq -c \
            --arg tag "$socks_tag" \
            --arg server "$SOCKS5_SERVER" \
            --arg username "$SOCKS5_USER" \
            --arg password "$SOCKS5_PASS" \
            --argjson port "$port" \
            '. + [{type:"socks", tag:$tag, server:$server, server_port:$port, version:"5", username:$username, password:$password}]') || return 1
    done
    
    echo "$outbounds_json"
}

commit_config_file() {
    local tmp_file="$1"

    if ! jq empty "$tmp_file" >/dev/null 2>&1; then
        print_error "生成的配置不是有效 JSON"
        rm -f "$tmp_file"
        return 1
    fi

    if command -v sing-box &>/dev/null; then
        if ! sing-box check -c "$tmp_file"; then
            print_error "sing-box 配置校验失败，原配置保持不变"
            rm -f "$tmp_file"
            return 1
        fi
    else
        print_warning "未找到 sing-box，跳过 sing-box check"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    mv "$tmp_file" "$CONFIG_FILE"
}

update_socks5_outbounds_in_config() {
    require_command jq || return 1
    init_base_config || return 1

    local socks_json tmp_file
    socks_json=$(generate_socks5_outbounds) || return 1
    tmp_file=$(mktemp "${CONFIG_DIR}/config.XXXXXX") || return 1

    if ! jq --argjson socks "$socks_json" '
        .outbounds = (
            $socks + [
                .outbounds[]? |
                select(((.tag // "") | test("^socks-out-[1-8]$")) | not)
            ]
        )
        | .route.final = "socks-out-1"
    ' "$CONFIG_FILE" > "$tmp_file"; then
        print_error "更新 SOCKS5 出口失败"
        rm -f "$tmp_file"
        return 1
    fi

    commit_config_file "$tmp_file"
}

# 初始化基础配置 (如果不存在)
init_base_config() {
    require_command jq || return 1
    ensure_dirs

    if [ -f "$CONFIG_FILE" ]; then
        # 配置已存在，检查格式是否正确
        if jq empty "$CONFIG_FILE" 2>/dev/null; then
            return 0
        fi

        print_error "配置文件存在但 JSON 格式错误: $CONFIG_FILE"
        print_error "请先修复或备份后删除该文件"
        return 1
    fi

    configure_socks5_outbounds false || return 1
    
    # 创建基础配置
    local outbounds_json tmp_file
    outbounds_json=$(generate_socks5_outbounds) || return 1
    tmp_file=$(mktemp "${CONFIG_DIR}/config.XXXXXX") || return 1

    jq -n \
        --arg log_file "$LOG_FILE" \
        --argjson socks "$outbounds_json" \
        '{
            log: {
                level: "info",
                output: $log_file,
                timestamp: true
            },
            inbounds: [],
            outbounds: ($socks + [
                {type: "direct", tag: "direct"},
                {type: "block", tag: "block"}
            ]),
            route: {
                rules: [],
                final: "socks-out-1"
            }
        }' > "$tmp_file" || {
            rm -f "$tmp_file"
            return 1
        }

    commit_config_file "$tmp_file" || return 1
    print_success "初始化基础配置完成"
}

# 添加 inbound 到现有配置
add_inbound_to_config() {
    local inbound_json="$1"
    local route_rules_json="$2"
    
    # 确保基础配置存在
    init_base_config || return 1
    
    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/config.XXXXXX") || return 1

    if ! jq --argjson inbound "$inbound_json" --argjson rules "${route_rules_json:-[]}" \
        '.inbounds += [$inbound] | .route.rules += $rules' "$CONFIG_FILE" > "$tmp_file"; then
        print_error "写入 inbound 失败"
        rm -f "$tmp_file"
        return 1
    fi

    commit_config_file "$tmp_file"
}

# 添加多个 inbound 到现有配置 (用于 SS 多端口)
add_inbounds_to_config() {
    local inbounds_json="$1"  # JSON 数组
    local route_rules_json="$2"  # JSON 数组
    
    # 确保基础配置存在
    init_base_config || return 1
    
    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/config.XXXXXX") || return 1

    if ! jq --argjson inbounds "$inbounds_json" --argjson rules "${route_rules_json:-[]}" \
        '.inbounds += $inbounds | .route.rules += $rules' "$CONFIG_FILE" > "$tmp_file"; then
        print_error "写入 inbounds 失败"
        rm -f "$tmp_file"
        return 1
    fi

    commit_config_file "$tmp_file"
}

remove_inbound_from_config() {
    local inbound_tag="$1"
    [ -f "$CONFIG_FILE" ] || return 0

    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/config.XXXXXX") || return 1

    if ! jq --arg tag "$inbound_tag" \
        'del(.inbounds[] | select(.tag == $tag)) | .route.rules = ([.route.rules[]? | select((.inbound // []) | index($tag) | not)])' \
        "$CONFIG_FILE" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    commit_config_file "$tmp_file"
}

# 生成 VLESS/Trojan 的路由规则 (8 用户)
generate_user_route_rules() {
    local inbound_tag="$1"
    local route_rules_json="[]"
    
    for i in {1..8}; do
        local user_name="user-$i"
        local socks_tag="socks-out-$i"

        route_rules_json=$(echo "$route_rules_json" | jq -c \
            --arg inbound "$inbound_tag" \
            --arg user "$user_name" \
            --arg outbound "$socks_tag" \
            '. + [{action:"route", inbound:[$inbound], auth_user:[$user], outbound:$outbound}]') || return 1
    done
    
    echo "$route_rules_json"
}

tag_exists() {
    local tag="$1"
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1
}

next_inbound_tag() {
    local base="$1"
    local candidate="$base"
    local idx=2

    while tag_exists "$candidate"; do
        candidate="${base}-${idx}"
        idx=$((idx + 1))
    done

    echo "$candidate"
}

config_port_in_use() {
    local port="$1"
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e --argjson port "$port" '.inbounds[]? | select(.listen_port == $port)' "$CONFIG_FILE" >/dev/null 2>&1
}

ensure_config_ports_available() {
    local port
    for port in "$@"; do
        if config_port_in_use "$port"; then
            print_error "配置中已存在监听端口: $port"
            return 1
        fi
    done
}

# 添加 VLESS-WS-TLS 节点
add_vless_ws_tls() {
    echo ""
    print_info "=== 添加 VLESS-WS-TLS 节点 ==="
    echo ""

    ensure_runtime_ready || return 1
    
    # 获取用户输入
    read -rp "回源端口 (Sing-box 监听端口): " listen_port
    
    validate_port "$listen_port" "回源端口" || return 1
    
    # 获取连接 IP
    local connection_ip
    connection_ip=$(get_connection_ip) || return 1
    
    # 获取连接端口
    read -rp "连接端口 (用于生成链接, 默认 443): " show_port
    show_port=${show_port:-443}
    validate_public_port "$show_port" "连接端口" || return 1
    
    read -rp "WebSocket 路径 (默认 /vless): " ws_path
    ws_path=${ws_path:-/vless}
    ws_path=$(normalize_ws_path "$ws_path")
    
    read -rp "域名 (CF 代理的域名): " domain
    validate_domain "$domain" || return 1
    
    # 证书选择
    echo ""
    echo "证书配置方式:"
    echo "1. 自签名证书 (自动生成)"
    echo "2. 上传证书文件"
    echo ""
    read -rp "选择 [1-2] (默认 1): " cert_mode
    cert_mode=${cert_mode:-1}
    
    local cert_path=""
    local key_path=""
    
    if [ "$cert_mode" = "1" ]; then
        # 生成自签名证书
        if ! generate_self_signed_cert "$domain"; then
            return 1
        fi
        cert_path="$GENERATED_CERT_PATH"
        key_path="$GENERATED_KEY_PATH"
    else
        # 上传证书
        read -rp "证书文件路径: " cert_path
        if [ ! -f "$cert_path" ]; then
            print_error "证书文件不存在: $cert_path"
            return 1
        fi
        
        read -rp "密钥文件路径: " key_path
        if [ ! -f "$key_path" ]; then
            print_error "密钥文件不存在: $key_path"
            return 1
        fi
    fi
    
    init_base_config || return 1
    ensure_config_ports_available "$listen_port" || return 1

    # 生成 8 个用户 UUID
    local users_json="[]"
    local uuids=()
    
    for i in {1..8}; do
        local uuid=$(generate_uuid)
        uuids+=("$uuid")
        users_json=$(echo "$users_json" | jq -c \
            --arg name "user-$i" \
            --arg uuid "$uuid" \
            '. + [{name:$name, uuid:$uuid}]') || return 1
    done

    local inbound_tag
    inbound_tag=$(next_inbound_tag "vless-in")
    
    local inbound_json
    inbound_json=$(jq -cn \
        --arg tag "$inbound_tag" \
        --arg domain "$domain" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        --arg path "$ws_path" \
        --argjson port "$listen_port" \
        --argjson users "$users_json" \
        '{type:"vless", tag:$tag, listen:"::", listen_port:$port, users:$users, tls:{enabled:true, server_name:$domain, certificate_path:$cert, key_path:$key}, transport:{type:"ws", path:$path}}') || return 1
    
    # 生成路由规则
    local route_rules_json
    route_rules_json=$(generate_user_route_rules "$inbound_tag") || return 1
    
    # 追加到配置
    add_inbound_to_config "$inbound_json" "$route_rules_json" || return 1
    
    print_success "VLESS-WS-TLS 节点配置完成 (追加模式)"
    
    # 保存节点信息用于导出
    save_node_info "vless" "$domain" "$connection_ip" "$show_port" "$listen_port" "$ws_path" "" "${uuids[@]}"
    
    # 重启服务
    restart_service
    
    # 显示节点链接
    echo ""
    print_info "=== 节点链接 (共 8 个) ==="
    export ALL_LINKS=""
    export_vless_links "$domain" "$connection_ip" "$show_port" "$ws_path" "${uuids[@]}"
    generate_subscription
}

# 添加 Trojan-WS-TLS 节点
add_trojan_ws_tls() {
    echo ""
    print_info "=== 添加 Trojan-WS-TLS 节点 ==="
    echo ""

    ensure_runtime_ready || return 1
    
    read -rp "回源端口 (Sing-box 监听端口): " listen_port
    
    validate_port "$listen_port" "回源端口" || return 1
    
    # 获取连接 IP
    local connection_ip
    connection_ip=$(get_connection_ip) || return 1
    
    # 获取连接端口
    read -rp "连接端口 (用于生成链接, 默认 443): " show_port
    show_port=${show_port:-443}
    validate_public_port "$show_port" "连接端口" || return 1
    
    read -rp "WebSocket 路径 (默认 /trojan): " ws_path
    ws_path=${ws_path:-/trojan}
    ws_path=$(normalize_ws_path "$ws_path")
    
    read -rp "域名 (CF 代理的域名): " domain
    validate_domain "$domain" || return 1
    
    # 证书选择
    echo ""
    echo "证书配置方式:"
    echo "1. 自签名证书 (自动生成)"
    echo "2. 上传证书文件"
    echo ""
    read -rp "选择 [1-2] (默认 1): " cert_mode
    cert_mode=${cert_mode:-1}
    
    local cert_path=""
    local key_path=""
    
    if [ "$cert_mode" = "1" ]; then
        # 生成自签名证书
        if ! generate_self_signed_cert "$domain"; then
            return 1
        fi
        cert_path="$GENERATED_CERT_PATH"
        key_path="$GENERATED_KEY_PATH"
    else
        # 上传证书
        read -rp "证书文件路径: " cert_path
        if [ ! -f "$cert_path" ]; then
            print_error "证书文件不存在: $cert_path"
            return 1
        fi
        
        read -rp "密钥文件路径: " key_path
        if [ ! -f "$key_path" ]; then
            print_error "密钥文件不存在: $key_path"
            return 1
        fi
    fi
    
    init_base_config || return 1
    ensure_config_ports_available "$listen_port" || return 1

    # 生成 8 个用户密码
    local users_json="[]"
    local passwords=()
    
    for i in {1..8}; do
        local password=$(generate_random_string 16)
        passwords+=("$password")
        users_json=$(echo "$users_json" | jq -c \
            --arg name "user-$i" \
            --arg password "$password" \
            '. + [{name:$name, password:$password}]') || return 1
    done

    local inbound_tag
    inbound_tag=$(next_inbound_tag "trojan-in")
    
    local inbound_json
    inbound_json=$(jq -cn \
        --arg tag "$inbound_tag" \
        --arg domain "$domain" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        --arg path "$ws_path" \
        --argjson port "$listen_port" \
        --argjson users "$users_json" \
        '{type:"trojan", tag:$tag, listen:"::", listen_port:$port, users:$users, tls:{enabled:true, server_name:$domain, certificate_path:$cert, key_path:$key}, transport:{type:"ws", path:$path}}') || return 1
    
    # 生成路由规则
    local route_rules_json
    route_rules_json=$(generate_user_route_rules "$inbound_tag") || return 1
    
    # 追加到配置
    add_inbound_to_config "$inbound_json" "$route_rules_json" || return 1
    
    print_success "Trojan-WS-TLS 节点配置完成 (追加模式)"
    
    # 保存节点信息
    save_node_info "trojan" "$domain" "$connection_ip" "$show_port" "$listen_port" "$ws_path" "" "${passwords[@]}"
    
    # 重启服务
    restart_service
    
    # 显示节点链接
    echo ""
    print_info "=== 节点链接 (共 8 个) ==="
    export ALL_LINKS=""
    export_trojan_links "$domain" "$connection_ip" "$show_port" "$ws_path" "${passwords[@]}"
    generate_subscription
}

# 添加 Cloudflare Tunnel 节点
add_cloudflare_tunnel_node() {
    echo ""
    print_info "=== 添加 Cloudflare Tunnel 节点 ==="
    echo ""

    ensure_runtime_ready || return 1
    install_cloudflared || return 1

    echo "协议类型:"
    echo "1. VLESS-WS"
    echo "2. Trojan-WS"
    echo ""
    read -rp "选择 [1-2] (默认 1): " protocol_choice
    protocol_choice=${protocol_choice:-1}

    local protocol
    case "$protocol_choice" in
        1)
            protocol="vless"
            ;;
        2)
            protocol="trojan"
            ;;
        *)
            print_error "无效协议类型"
            return 1
            ;;
    esac

    echo ""
    echo "隧道类型:"
    echo "1. 临时隧道 (trycloudflare.com，适合测试)"
    echo "2. 固定隧道 (需 Token，自定义域名，重启后可重新拉起)"
    echo ""
    read -rp "选择 [1-2] (默认 1): " tunnel_mode
    tunnel_mode=${tunnel_mode:-1}

    read -rp "Argo 内部监听端口 (回车随机生成): " listen_port
    if [ -z "$listen_port" ]; then
        init_base_config || return 1
        listen_port=$(generate_random_port) || {
            print_error "随机端口生成失败"
            return 1
        }
        print_info "已生成随机内部端口: $listen_port"
    fi
    validate_port "$listen_port" "Argo 内部监听端口" || return 1

    read -rp "WebSocket 路径 (回车随机生成): " ws_path
    if [ -z "$ws_path" ]; then
        ws_path="/$(generate_random_hex 8)"
        print_info "已生成随机路径: $ws_path"
    else
        ws_path=$(normalize_ws_path "$ws_path")
    fi

    local hostname=""
    local token=""
    local tunnel_note=""

    if [ "$tunnel_mode" = "2" ]; then
        tunnel_note="fixed"

        echo ""
        print_info "请粘贴 Cloudflare Tunnel Token，支持直接粘贴 CF 网页端给出的安装命令:"
        read -rp "Token: " input_token
        token=$(extract_argo_token "$input_token")
        if [ -z "$token" ]; then
            print_error "Token 不能为空"
            return 1
        fi
        print_info "已识别 Token (前20位): ${token:0:20}..."

        echo ""
        read -rp "固定隧道域名 (例如 node.example.com): " hostname
        validate_domain "$hostname" || return 1

        echo ""
        print_info "Cloudflare Dashboard 中 Public Hostname 的 Service 需要指向: http://127.0.0.1:${listen_port}"
        read -n 1 -s -r -p "确认配置无误后，按任意键继续..."
        echo ""
    elif [ "$tunnel_mode" = "1" ]; then
        tunnel_note="temporary"
    else
        print_error "无效隧道类型"
        return 1
    fi

    init_base_config || return 1
    ensure_config_ports_available "$listen_port" || return 1

    local users_json="[]"
    local credentials=()
    local i

    for i in {1..8}; do
        if [ "$protocol" = "vless" ]; then
            local uuid
            uuid=$(generate_uuid)
            credentials+=("$uuid")
            users_json=$(echo "$users_json" | jq -c \
                --arg name "user-$i" \
                --arg uuid "$uuid" \
                '. + [{name:$name, uuid:$uuid}]') || return 1
        else
            local password
            password=$(generate_random_string 16)
            credentials+=("$password")
            users_json=$(echo "$users_json" | jq -c \
                --arg name "user-$i" \
                --arg password "$password" \
                '. + [{name:$name, password:$password}]') || return 1
        fi
    done

    local inbound_tag
    if [ "$protocol" = "vless" ]; then
        inbound_tag=$(next_inbound_tag "cf-vless-in")
    else
        inbound_tag=$(next_inbound_tag "cf-trojan-in")
    fi

    local inbound_json
    inbound_json=$(jq -cn \
        --arg type "$protocol" \
        --arg tag "$inbound_tag" \
        --arg path "$ws_path" \
        --argjson port "$listen_port" \
        --argjson users "$users_json" \
        '{type:$type, tag:$tag, listen:"127.0.0.1", listen_port:$port, users:$users, transport:{type:"ws", path:$path}}') || return 1

    local route_rules_json
    route_rules_json=$(generate_user_route_rules "$inbound_tag") || return 1

    add_inbound_to_config "$inbound_json" "$route_rules_json" || return 1
    restart_service

    if ! wait_for_ws_101 "http://127.0.0.1:${listen_port}${ws_path}" "" "本地 sing-box WS 回源" 12; then
        print_error "本地回源自检失败，正在回滚 sing-box 配置。"
        print_info "请先查看 sing-box 日志，确认 /etc/sing-box/config.json 已存在且服务正常监听 ${listen_port}。"
        remove_inbound_from_config "$inbound_tag" >/dev/null 2>&1 || true
        restart_service
        return 1
    fi

    if [ "$tunnel_mode" = "1" ]; then
        if ! start_argo_tunnel "$listen_port"; then
            print_error "隧道启动失败，正在回滚 sing-box 配置..."
            remove_inbound_from_config "$inbound_tag" >/dev/null 2>&1 || true
            restart_service
            return 1
        fi
        hostname="$ARGO_TUNNEL_DOMAIN"
        if [ -z "$hostname" ]; then
            print_error "临时隧道域名为空，请查看日志: $(argo_log_file "$listen_port")"
            remove_inbound_from_config "$inbound_tag" >/dev/null 2>&1 || true
            restart_service
            return 1
        fi
        print_success "临时隧道域名: $hostname"
        print_info "如需使用 CF 优选域名/IP，只能替换连接地址；Host/SNI 必须保留该隧道域名。"
    else
        if ! start_argo_tunnel "$listen_port" "$token"; then
            print_error "隧道启动失败，正在回滚 sing-box 配置..."
            remove_inbound_from_config "$inbound_tag" >/dev/null 2>&1 || true
            restart_service
            return 1
        fi
    fi

    local connect_address
    read -rp "CF 优选连接地址/域名/IP (回车使用隧道域名 ${hostname}): " connect_address
    connect_address=$(normalize_connect_address "${connect_address:-$hostname}")
    if [ -z "$connect_address" ]; then
        connect_address="$hostname"
    fi

    save_argo_metadata "$inbound_tag" "$protocol" "$hostname" "$listen_port" "$ws_path" "$tunnel_note" "$token" "$connect_address" "${credentials[@]}"
    install_watchdog
    save_node_info "${protocol}-cf" "$hostname" "$connect_address" 443 "$listen_port" "$ws_path" "$tunnel_note" "${credentials[@]}"

    echo ""
    print_info "=== Cloudflare Tunnel 节点链接 (共 8 个) ==="
    export ALL_LINKS=""
    if [ "$protocol" = "vless" ]; then
        export_vless_cf_links "$hostname" 443 "$ws_path" "$connect_address" "${credentials[@]}"
    else
        export_trojan_cf_links "$hostname" 443 "$ws_path" "$connect_address" "${credentials[@]}"
    fi
    generate_subscription
}

# 添加 Shadowsocks 节点 (8 端口模式)
add_shadowsocks() {
    echo ""
    print_info "=== 添加 Shadowsocks 节点 (8 端口模式) ==="
    echo ""

    ensure_runtime_ready || return 1
    
    read -rp "起始端口 (将监听 8 个连续端口): " start_port
    
    validate_port "$start_port" "起始端口" || return 1

    local listen_ports=()
    for i in {1..8}; do
        local candidate_port=$((start_port + i - 1))
        validate_port "$candidate_port" "监听端口" || return 1
        listen_ports+=("$candidate_port")
    done
    
    # 获取连接 IP
    local connection_ip
    connection_ip=$(get_connection_ip) || return 1
    
    echo ""
    echo "选择加密方式:"
    echo "1. aes-256-gcm"
    echo "2. 2022-blake3-aes-128-gcm"
    read -rp "选择 [1-2] (默认 1): " method_choice
    method_choice=${method_choice:-1}
    
    local method
    local key_bits
    case "$method_choice" in
        1)
            method="aes-256-gcm"
            key_bits=0
            ;;
        2)
            method="2022-blake3-aes-128-gcm"
            key_bits=128
            ;;
        *)
            method="aes-256-gcm"
            key_bits=0
            ;;
    esac
    
    # 生成服务器密钥 (2022 协议需要)
    local server_key=""
    if [ "$key_bits" -gt 0 ]; then
        server_key=$(generate_ss2022_key $key_bits)
        print_info "服务器密钥: $server_key"
    fi
    
    init_base_config || return 1
    ensure_config_ports_available "${listen_ports[@]}" || return 1

    # 生成 8 个用户密码和 8 个 inbound (JSON 数组格式)
    local inbounds_arr="[]"
    local route_rules_arr="[]"
    local passwords=()
    local ss_base_tag
    ss_base_tag=$(next_inbound_tag "ss-in-${start_port}")
    
    for i in {1..8}; do
        local port=$((start_port + i - 1))
        local socks_tag="socks-out-$i"
        local inbound_tag="${ss_base_tag}-${i}"
        
        local password
        if [ "$key_bits" -gt 0 ]; then
            password=$(generate_ss2022_key $key_bits)
        else
            password=$(generate_random_string 16)
        fi
        passwords+=("$password")
        
        local inbound server_password
        if [ -n "$server_key" ]; then
            server_password="$server_key"
        else
            server_password="$password"
        fi

        if [ -n "$server_key" ]; then
            inbound=$(jq -cn \
                --arg tag "$inbound_tag" \
                --arg method "$method" \
                --arg password "$server_password" \
                --arg user_name "user-${i}" \
                --arg user_password "$password" \
                --argjson port "$port" \
                '{type:"shadowsocks", tag:$tag, listen:"::", listen_port:$port, method:$method, password:$password, users:[{name:$user_name, password:$user_password}]}') || return 1
        else
            inbound=$(jq -cn \
                --arg tag "$inbound_tag" \
                --arg method "$method" \
                --arg password "$password" \
                --argjson port "$port" \
                '{type:"shadowsocks", tag:$tag, listen:"::", listen_port:$port, method:$method, password:$password}') || return 1
        fi

        inbounds_arr=$(echo "$inbounds_arr" | jq -c --argjson inbound "$inbound" '. + [$inbound]') || return 1
        
        # 路由规则
        route_rules_arr=$(echo "$route_rules_arr" | jq -c \
            --arg inbound "$inbound_tag" \
            --arg outbound "$socks_tag" \
            '. + [{action:"route", inbound:[$inbound], outbound:$outbound}]') || return 1
    done
    
    # 追加到配置 (使用 JSON 数组)
    add_inbounds_to_config "$inbounds_arr" "$route_rules_arr" || return 1
    
    print_success "Shadowsocks 节点配置完成 (追加模式, 端口: $start_port - $((start_port + 7)))"
    
    # 保存节点信息
    save_node_info "shadowsocks" "" "$connection_ip" "$start_port" "$start_port" "" "$method:$server_key" "${passwords[@]}"
    
    # 重启服务
    restart_service
    
    # 显示节点链接
    echo ""
    print_info "=== 节点链接 (共 8 个) ==="
    export ALL_LINKS=""
    export_shadowsocks_links "$connection_ip" "$start_port" "$method" "$server_key" "${passwords[@]}"
    generate_subscription
}

# 获取本机 IPv6 地址 (兼容 BusyBox)
get_ipv6() {
    local ipv6=$(ip -6 addr show scope global | awk '/inet6/ {print $2}' | cut -d'/' -f1 | head -1)
    if [ -z "$ipv6" ]; then
        # 尝试其他方式
        ipv6=$(curl -s -6 https://ifconfig.co)
    fi
    echo "$ipv6"
}

# 获取连接 IP (用户交互)
get_connection_ip() {
    local default_ip=$(get_ipv6)
    read -rp "请输入连接 IP (默认: $default_ip): " input_ip
    input_ip=${input_ip:-$default_ip}
    if [ -z "$input_ip" ]; then
        print_error "连接 IP 不能为空"
        return 1
    fi
    echo "$input_ip"
}

# 节点信息保存与导出
# ============================================

save_node_info() {
    local protocol="$1"
    local domain="$2"
    local ipv6="$3"
    local port="$4"      # 显示用的端口
    local real_port="$5" # 实际监听端口
    local path="$6"
    local extra="$7"     # method:server_key for ss
    shift 7
    local credentials=("$@")
    
    local node_info_file="${DATA_DIR}/node_info.json"

    ensure_dirs
    require_command jq || return 1

    local credentials_json new_node tmp_file
    credentials_json=$(printf '%s\n' "${credentials[@]}" | jq -R . | jq -s .) || return 1

    new_node=$(jq -n \
        --arg protocol "$protocol" \
        --arg domain "$domain" \
        --arg ipv6 "$ipv6" \
        --arg path "$path" \
        --arg extra "$extra" \
        --argjson port "$port" \
        --argjson real_port "$real_port" \
        --argjson credentials "$credentials_json" \
        '{protocol:$protocol, domain:$domain, ipv6:$ipv6, port:$port, real_port:$real_port, path:$path, extra:$extra, credentials:$credentials}') || return 1

    tmp_file=$(mktemp "${DATA_DIR}/node_info.XXXXXX") || return 1
    
    # 如果文件存在且是有效的 JSON 数组，追加；否则创建新数组
    if [ -f "$node_info_file" ] && jq -e 'type == "array"' "$node_info_file" >/dev/null 2>&1; then
        jq --argjson node "$new_node" '. += [$node]' "$node_info_file" > "$tmp_file" || {
            rm -f "$tmp_file"
            return 1
        }
    else
        jq --argjson node "$new_node" -n '[$node]' > "$tmp_file" || {
            rm -f "$tmp_file"
            return 1
        }
    fi

    mv "$tmp_file" "$node_info_file"
    chmod 600 "$node_info_file" 2>/dev/null || true
}

save_argo_metadata() {
    local tag="$1"
    local protocol="$2"
    local domain="$3"
    local port="$4"
    local path="$5"
    local argo_type="$6"
    local token="$7"
    local connect_address="${8:-$domain}"
    shift 8
    local credentials=("$@")

    ensure_dirs
    require_command jq || return 1

    local credential_key credentials_json argo_meta tmp_file
    if [ "$protocol" = "vless" ]; then
        credential_key="uuids"
    else
        credential_key="passwords"
    fi

    credentials_json=$(printf '%s\n' "${credentials[@]}" | jq -R . | jq -s .) || return 1
    argo_meta=$(jq -n \
        --arg tag "$tag" \
        --arg protocol "${protocol}-ws" \
        --arg domain "$domain" \
        --argjson port "$port" \
        --arg path "$path" \
        --arg type "$argo_type" \
        --arg token "$token" \
        --arg connect_address "$connect_address" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        --arg key "$credential_key" \
        --argjson credentials "$credentials_json" \
        '.[$tag] = ({protocol:$protocol, domain:$domain, connect_address:$connect_address, local_port:$port, path:$path, type:$type, token:$token, created_at:$created} | .[$key] = $credentials)') || return 1

    if [ -f "$ARGO_METADATA_FILE" ] && jq -e 'type == "object"' "$ARGO_METADATA_FILE" >/dev/null 2>&1; then
        tmp_file=$(mktemp "${DATA_DIR}/argo_metadata.XXXXXX") || return 1
        jq --argjson meta "$argo_meta" '. + $meta' "$ARGO_METADATA_FILE" > "$tmp_file" || {
            rm -f "$tmp_file"
            return 1
        }
    else
        tmp_file=$(mktemp "${DATA_DIR}/argo_metadata.XXXXXX") || return 1
        printf '%s\n' "$argo_meta" > "$tmp_file"
    fi

    mv "$tmp_file" "$ARGO_METADATA_FILE"
    chmod 600 "$ARGO_METADATA_FILE" 2>/dev/null || true
}

# 导出 VLESS 链接
export_vless_links() {
    local domain="$1"
    local connection_ip="$2"
    local port="$3"
    local path="$4"
    shift 4
    local uuids=("$@")
    
    local encoded_path
    encoded_path=$(urlencode "$path")
    local all_links=""
    
    # 格式化地址：如果是 IPv6 (包含 :) 则添加 []，否则直接使用
    local formatted_address
    formatted_address=$(format_address "$connection_ip")
    
    for i in {1..8}; do
        local uuid="${uuids[$((i-1))]}"
        local socks_port="${SOCKS5_PORTS[$((i-1))]}"
        local remark="VLESS-出口${i}-端口${socks_port}"
        local encoded_remark
        encoded_remark=$(urlencode "$remark")
        
        # 使用格式化后的地址
        local link="vless://${uuid}@${formatted_address}:${port}?encryption=none&security=tls&sni=${domain}&allowInsecure=1&type=ws&host=${domain}&path=${encoded_path}#${encoded_remark}"
        
        echo -e "${GREEN}出口 $i (端口 $socks_port):${NC}"
        echo "$link"
        echo ""
        all_links="${all_links}${link}\n"
    done
    export ALL_LINKS="$all_links"
}

# 导出 Trojan 链接
export_trojan_links() {
    local domain="$1"
    local connection_ip="$2"
    local port="$3"
    local path="$4"
    shift 4
    local passwords=("$@")
    
    local encoded_path
    encoded_path=$(urlencode "$path")
    local all_links=""
    
    # 格式化地址
    local formatted_address
    formatted_address=$(format_address "$connection_ip")
    
    for i in {1..8}; do
        local password="${passwords[$((i-1))]}"
        local socks_port="${SOCKS5_PORTS[$((i-1))]}"
        local remark="Trojan-出口${i}-端口${socks_port}"
        local encoded_remark
        encoded_remark=$(urlencode "$remark")
        
        # 使用格式化后的地址
        local link="trojan://${password}@${formatted_address}:${port}?security=tls&sni=${domain}&allowInsecure=1&type=ws&host=${domain}&path=${encoded_path}#${encoded_remark}"
        
        echo -e "${GREEN}出口 $i (端口 $socks_port):${NC}"
        echo "$link"
        echo ""
        all_links="${all_links}${link}\n"
    done
    export ALL_LINKS="$all_links"
}

export_vless_cf_links() {
    local hostname="$1"
    local port="$2"
    local path="$3"
    local connect_address="${4:-$hostname}"
    if [ "$#" -ge 4 ]; then
        shift 4
    else
        shift 3
    fi
    local uuids=("$@")

    local encoded_path
    encoded_path=$(urlencode "$path")
    local all_links=""
    local formatted_address
    formatted_address=$(format_address "$connect_address")

    for i in {1..8}; do
        local uuid="${uuids[$((i-1))]}"
        local socks_port="${SOCKS5_PORTS[$((i-1))]}"
        local remark="CF-VLESS-出口${i}-端口${socks_port}"
        local encoded_remark
        encoded_remark=$(urlencode "$remark")

        local link="vless://${uuid}@${formatted_address}:${port}?encryption=none&security=tls&sni=${hostname}&type=ws&host=${hostname}&path=${encoded_path}#${encoded_remark}"

        echo -e "${GREEN}出口 $i (端口 $socks_port):${NC}"
        [ "$connect_address" != "$hostname" ] && echo "连接地址: $connect_address | Host/SNI: $hostname"
        echo "$link"
        echo ""
        all_links="${all_links}${link}\n"
    done
    export ALL_LINKS="$all_links"
}

export_trojan_cf_links() {
    local hostname="$1"
    local port="$2"
    local path="$3"
    local connect_address="${4:-$hostname}"
    if [ "$#" -ge 4 ]; then
        shift 4
    else
        shift 3
    fi
    local passwords=("$@")

    local encoded_path
    encoded_path=$(urlencode "$path")
    local all_links=""
    local formatted_address
    formatted_address=$(format_address "$connect_address")

    for i in {1..8}; do
        local password="${passwords[$((i-1))]}"
        local socks_port="${SOCKS5_PORTS[$((i-1))]}"
        local remark="CF-Trojan-出口${i}-端口${socks_port}"
        local encoded_remark
        encoded_remark=$(urlencode "$remark")

        local link="trojan://${password}@${formatted_address}:${port}?security=tls&sni=${hostname}&type=ws&host=${hostname}&path=${encoded_path}#${encoded_remark}"

        echo -e "${GREEN}出口 $i (端口 $socks_port):${NC}"
        [ "$connect_address" != "$hostname" ] && echo "连接地址: $connect_address | Host/SNI: $hostname"
        echo "$link"
        echo ""
        all_links="${all_links}${link}\n"
    done
    export ALL_LINKS="$all_links"
}

# 导出 Shadowsocks 链接 (8 端口模式)
export_shadowsocks_links() {
    local connection_ip="$1"
    local start_port="$2"
    local method="$3"
    local server_key="$4"
    shift 4
    local passwords=("$@")
    
    local all_links=""
    
    # 格式化地址
    local formatted_address
    formatted_address=$(format_address "$connection_ip")
    
    for i in {1..8}; do
        local password="${passwords[$((i-1))]}"
        local port=$((start_port + i - 1))
        local socks_port="${SOCKS5_PORTS[$((i-1))]}"
        local remark="SS-出口${i}-端口${socks_port}"
        
        local user_info
        if [ -n "$server_key" ]; then
            user_info="${method}:${server_key}:${password}"
        else
            user_info="${method}:${password}"
        fi
        
        local encoded encoded_remark
        encoded=$(printf '%s' "$user_info" | base64_no_wrap)
        encoded_remark=$(urlencode "$remark")
        local link="ss://${encoded}@${formatted_address}:${port}#${encoded_remark}"
        
        echo -e "${GREEN}出口 $i (监听端口 $port -> SOCKS5 端口 $socks_port):${NC}"
        echo "$link"
        echo ""
        all_links="${all_links}${link}\n"
    done
    export ALL_LINKS="$all_links"
}

# 生成并显示 Base64 订阅
generate_subscription() {
    if [ -n "$ALL_LINKS" ]; then
        echo -e "${YELLOW}=== Base64 订阅内容 (可直接导入 v2rayN) ===${NC}"
        echo -e "${ALL_LINKS}" | sed '/^$/d' | base64_no_wrap
        echo ""
        echo ""
    fi
}

# 显示已保存的节点链接 (支持多协议)
show_node_links() {
    require_command jq || return 1
    load_socks5_config

    if [ ! -f "${DATA_DIR}/node_info.json" ]; then
        print_error "未找到节点信息，请先添加节点"
        return 1
    fi
    
    local info_file="${DATA_DIR}/node_info.json"
    
    # 检查是否是数组格式
    if ! jq -e 'type == "array"' "$info_file" >/dev/null 2>&1; then
        print_error "节点信息格式错误"
        return 1
    fi
    
    local node_count=$(jq 'length' "$info_file")
    
    if [ "$node_count" -eq 0 ]; then
        print_error "没有保存的节点"
        return 1
    fi
    
    echo ""
    print_info "=== 所有节点链接 (共 $node_count 个协议) ==="
    
    export ALL_LINKS=""
    local combined_links=""
    
    # 遍历每个节点
    for ((idx=0; idx<node_count; idx++)); do
        local node=$(jq ".[$idx]" "$info_file")
        local protocol=$(echo "$node" | jq -r '.protocol')
        local domain=$(echo "$node" | jq -r '.domain')
        local ipv6=$(echo "$node" | jq -r '.ipv6')
        local port=$(echo "$node" | jq -r '.port')
        local path=$(echo "$node" | jq -r '.path')
        local extra=$(echo "$node" | jq -r '.extra')
        local credentials=$(echo "$node" | jq -r '.credentials[]')
        
        echo ""
        print_info "--- 协议: $protocol ---"
        echo ""
        
        local creds_array=()
        while IFS= read -r line; do
            [ -n "$line" ] && creds_array+=("$line")
        done <<< "$credentials"
        
        case "$protocol" in
            vless)
                export_vless_links "$domain" "$ipv6" "$port" "$path" "${creds_array[@]}"
                ;;
            trojan)
                export_trojan_links "$domain" "$ipv6" "$port" "$path" "${creds_array[@]}"
                ;;
            vless-cf)
                export_vless_cf_links "$domain" "$port" "$path" "$ipv6" "${creds_array[@]}"
                ;;
            trojan-cf)
                export_trojan_cf_links "$domain" "$port" "$path" "$ipv6" "${creds_array[@]}"
                ;;
            shadowsocks)
                local method=$(echo "$extra" | cut -d':' -f1)
                local server_key=$(echo "$extra" | cut -d':' -f2-)
                export_shadowsocks_links "$ipv6" "$port" "$method" "$server_key" "${creds_array[@]}"
                ;;
        esac
        
        combined_links="${combined_links}${ALL_LINKS}"
    done
    
    # 生成合并的订阅
    export ALL_LINKS="$combined_links"
    generate_subscription
}

# ============================================
# 服务管理
# ============================================

start_service() {
    print_info "启动 sing-box 服务..."
    rm -f "$WATCHDOG_PAUSE_FILE"
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl start sing-box
    else
        rc-service sing-box start
    fi
    sleep 1
    show_service_status
}

stop_service() {
    print_info "停止 sing-box 服务..."
    ensure_dirs
    touch "$WATCHDOG_PAUSE_FILE"
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl stop sing-box
    else
        rc-service sing-box stop
    fi
    print_success "服务已停止"
}

restart_service() {
    print_info "重启 sing-box 服务..."
    rm -f "$WATCHDOG_PAUSE_FILE"
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl restart sing-box
    else
        rc-service sing-box restart
    fi
    sleep 1
    show_service_status
}

show_service_status() {
    echo ""
    print_info "=== 服务状态 ==="
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl status sing-box --no-pager -l
    else
        rc-service sing-box status
    fi
}

is_singbox_running() {
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl is-active --quiet sing-box 2>/dev/null
    else
        rc-service sing-box status >/dev/null 2>&1
    fi
}

status_text() {
    if "$@"; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

argo_tunnel_running() {
    local target_port="$1"
    local pid_file pid
    pid_file=$(argo_pid_file "$target_port")
    [ -f "$pid_file" ] || return 1
    pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

argo_counts() {
    local total=0
    local running=0
    local port pid_file filename

    if [ -f "$ARGO_METADATA_FILE" ] && command -v jq &>/dev/null; then
        while IFS= read -r port; do
            [ -n "$port" ] && [ "$port" != "null" ] || continue
            total=$((total + 1))
            if argo_tunnel_running "$port"; then
                running=$((running + 1))
            fi
        done < <(jq -r 'to_entries[]?.value.local_port // empty' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    for pid_file in /tmp/singbox_argo_*.pid; do
        [ -e "$pid_file" ] || continue
        filename=$(basename "$pid_file")
        port=${filename#singbox_argo_}
        port=${port%.pid}
        if [ -f "$ARGO_METADATA_FILE" ] && command -v jq &>/dev/null && jq -e --argjson port "$port" 'to_entries[]?.value.local_port == $port' "$ARGO_METADATA_FILE" >/dev/null 2>&1; then
            continue
        fi
        total=$((total + 1))
        if argo_tunnel_running "$port"; then
            running=$((running + 1))
        fi
    done

    echo "$total $running"
}

show_runtime_summary() {
    local counts total running
    counts=$(argo_counts)
    total=${counts%% *}
    running=${counts##* }

    echo -ne "${CYAN}运行状态:${NC} sing-box "
    if is_singbox_running; then
        echo -ne "${GREEN}运行中${NC}"
    else
        echo -ne "${RED}未运行${NC}"
    fi
    echo -ne " | Argo "
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}未配置${NC}"
    elif [ "$running" -eq "$total" ]; then
        echo -e "${GREEN}${running}/${total} 运行中${NC}"
    elif [ "$running" -gt 0 ]; then
        echo -e "${YELLOW}${running}/${total} 运行中${NC}"
    else
        echo -e "${RED}0/${total} 运行中${NC}"
    fi
}

show_argo_status() {
    local has_item=0
    local tag type domain connect_address port path pid_file pid state log_file current_domain

    echo ""
    print_info "=== Argo 隧道状态 ==="

    if [ -f "$ARGO_METADATA_FILE" ] && command -v jq &>/dev/null; then
        while IFS=$'\t' read -r tag type domain connect_address port path; do
            [ -n "$port" ] && [ "$port" != "null" ] || continue
            has_item=1
            pid_file=$(argo_pid_file "$port")
            log_file=$(argo_log_file "$port")
            pid=$(cat "$pid_file" 2>/dev/null || true)
            if argo_tunnel_running "$port"; then
                state="${GREEN}运行中${NC}"
            else
                state="${RED}未运行${NC}"
            fi
            echo -e "${CYAN}${tag}:${NC} $state"
            echo "  类型: ${type:-unknown}"
            echo "  域名: ${domain:-unknown}"
            if [ -n "$connect_address" ] && [ "$connect_address" != "null" ] && [ "$connect_address" != "$domain" ]; then
                echo "  优选连接地址: $connect_address"
            fi
            current_domain=$(grep -oE 'https?://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | head -n 1 | sed -E 's|https?://||')
            if [ -n "$current_domain" ] && [ "$current_domain" != "$domain" ]; then
                echo "  当前临时域名: $current_domain"
            fi
            echo "  本地端口: $port"
            echo "  WS 路径: ${path:-/}"
            echo "  PID: ${pid:-无}"
            echo "  日志: $log_file"
        done < <(jq -r 'to_entries[]? | [.key, (.value.type // "unknown"), (.value.domain // "unknown"), (.value.connect_address // .value.domain // "unknown"), (.value.local_port // empty), (.value.path // "/")] | @tsv' "$ARGO_METADATA_FILE" 2>/dev/null)
    fi

    for pid_file in /tmp/singbox_argo_*.pid; do
        [ -e "$pid_file" ] || continue
        port=$(basename "$pid_file")
        port=${port#singbox_argo_}
        port=${port%.pid}
        if [ -f "$ARGO_METADATA_FILE" ] && command -v jq &>/dev/null && jq -e --argjson port "$port" 'to_entries[]?.value.local_port == $port' "$ARGO_METADATA_FILE" >/dev/null 2>&1; then
            continue
        fi
        has_item=1
        log_file=$(argo_log_file "$port")
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if argo_tunnel_running "$port"; then
            state="${GREEN}运行中${NC}"
        else
            state="${RED}未运行${NC}"
        fi
        echo -e "${CYAN}未登记隧道:${NC} $state"
        echo "  本地端口: $port"
        echo "  PID: ${pid:-无}"
        echo "  日志: $log_file"
    done

    if [ "$has_item" -eq 0 ]; then
        echo "未发现 Argo 隧道配置或进程。"
    fi
}

show_runtime_status() {
    echo ""
    print_info "=== 运行状态总览 ==="
    echo -e "sing-box: $(status_text is_singbox_running)"
    show_argo_status
    show_service_status
}

show_logs() {
    echo ""
    print_info "=== 最新日志 (最后 50 行) ==="
    if [ "$OS_TYPE" = "debian" ]; then
        journalctl -u sing-box -n 50 --no-pager
    else
        tail -n 50 "$LOG_FILE"
    fi
}

# ============================================
# 卸载
# ============================================

uninstall_singbox() {
    echo ""
    print_warning "此操作将删除:"
    echo "  - sing-box 二进制文件"
    echo "  - cloudflared / CF Argo 隧道程序与进程"
    echo "  - sing-box 守护脚本与系统服务"
    echo "  - 配置目录: $CONFIG_DIR"
    echo "  - 数据目录: $DATA_DIR"
    echo "  - 日志文件: $LOG_FILE"
    echo "  - 本脚本文件"
    echo ""
    
    read -rp "确定要卸载吗? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消卸载"
        return
    fi
    
    # 停止服务
    print_info "停止服务..."
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl stop cloudflared-alice 2>/dev/null
        systemctl disable cloudflared-alice 2>/dev/null
        systemctl stop sing-box-watchdog.timer 2>/dev/null
        systemctl disable sing-box-watchdog.timer 2>/dev/null
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        rm -f /etc/systemd/system/cloudflared-alice.service
        rm -f /etc/systemd/system/sing-box-watchdog.service
        rm -f /etc/systemd/system/sing-box-watchdog.timer
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    else
        rc-service cloudflared-alice stop 2>/dev/null
        rc-update del cloudflared-alice default 2>/dev/null
        rc-service sing-box stop 2>/dev/null
        rc-update del sing-box default 2>/dev/null
        if [ -f /etc/crontabs/root ]; then
            sed -i '\|/usr/local/bin/sing-box-watchdog|d' /etc/crontabs/root
            rc-service crond restart >/dev/null 2>&1 || true
        fi
        rm -f /etc/init.d/cloudflared-alice
        rm -f /etc/init.d/sing-box
    fi
    
    # 删除文件
    print_info "删除文件..."
    stop_all_argo_tunnels
    pkill -f 'cloudflared.*tunnel' 2>/dev/null || true
    rm -f /usr/local/bin/sing-box
    rm -f "$CLOUDFLARED_BIN"
    rm -f "$CLOUDFLARED_RUNNER"
    rm -f "$CLOUDFLARED_PID_FILE"
    rm -f "$WATCHDOG_SCRIPT"
    rm -f "$CLOUDFLARED_TOKEN_FILE"
    rm -f "$CLOUDFLARED_MARKER_FILE"
    rm -f /tmp/singbox_argo_*.pid /tmp/singbox_argo_*.log
    rm -rf "$CLOUDFLARED_DIR"
    rm -rf "$CONFIG_DIR"
    rm -rf "$DATA_DIR"
    rm -f "$LOG_FILE"
    rm -f "$CLOUDFLARED_LOG_FILE"
    
    print_success "脚本相关组件已卸载"
    
    # 删除脚本自身
    print_info "删除脚本文件..."
    rm -f "$SCRIPT_PATH"
    
    print_success "卸载完成，再见！"
    exit 0
}

# ============================================
# 查看节点
# ============================================

show_nodes() {
    require_command jq || return 1

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "配置文件不存在"
        return 1
    fi
    
    echo ""
    print_info "=== 当前节点配置 ==="
    
    local inbounds=$(jq '.inbounds' "$CONFIG_FILE")
    local count=$(echo "$inbounds" | jq 'length')
    
    for ((i=0; i<count; i++)); do
        local inbound=$(echo "$inbounds" | jq ".[$i]")
        local type=$(echo "$inbound" | jq -r '.type')
        local tag=$(echo "$inbound" | jq -r '.tag')
        local port=$(echo "$inbound" | jq -r '.listen_port')
        local users_count=$(echo "$inbound" | jq '.users | length')
        
        echo -e "${CYAN}节点 $((i+1)):${NC}"
        echo "  类型: $type"
        echo "  标签: $tag"
        echo "  端口: $port"
        echo "  用户数: $users_count"
        echo ""
    done
}

# 删除节点 (重置配置)
delete_node() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "配置文件不存在"
        return 1
    fi
    
    read -rp "确定要删除所有节点配置吗? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return
    fi
    
    # 停止服务
    stop_service
    stop_all_argo_tunnels
    
    # 删除配置
    rm -f "$CONFIG_FILE"
    rm -f "${DATA_DIR}/node_info.json"
    rm -f "$ARGO_METADATA_FILE"
    
    print_success "节点配置已删除"
}

# ============================================
# 菜单
# ============================================

show_menu() {
    clear
    echo -e "${PURPLE}========================================${NC}"
    echo -e "${PURPLE}   Alice IPv6Only专用singbox八出口版${NC}"
    echo -e "${PURPLE}   系统: $OS_TYPE | 架构: $ARCH${NC}"
    echo -e "${PURPLE}========================================${NC}"
    show_runtime_summary
    echo ""
    echo -e "${CYAN}1.${NC} 安装/更新 Sing-box"
    echo ""
    echo -e "${YELLOW}--- 基础配置 ---${NC}"
    echo -e "${CYAN}2.${NC} 配置 SOCKS5 出口"
    echo ""
    echo -e "${YELLOW}--- 节点管理 ---${NC}"
    echo -e "${CYAN}3.${NC} 添加 Cloudflare Tunnel 节点"
    echo -e "${CYAN}4.${NC} 添加 VLESS-WS-TLS 节点"
    echo -e "${CYAN}5.${NC} 添加 Trojan-WS-TLS 节点"
    echo -e "${CYAN}6.${NC} 添加 Shadowsocks 节点"
    echo -e "${CYAN}7.${NC} 查看当前节点"
    echo -e "${CYAN}8.${NC} 导出节点链接"
    echo -e "${CYAN}9.${NC} 删除节点配置"
    echo ""
    echo -e "${YELLOW}--- 服务管理 ---${NC}"
    echo -e "${CYAN}10.${NC} 启动服务"
    echo -e "${CYAN}11.${NC} 停止服务"
    echo -e "${CYAN}12.${NC} 重启服务"
    echo -e "${CYAN}13.${NC} 查看运行状态"
    echo -e "${CYAN}14.${NC} 查看日志"
    echo ""
    echo -e "${RED}15.${NC} 卸载脚本"
    echo -e "${CYAN}0.${NC} 退出"
    echo ""
    echo -e "${PURPLE}========================================${NC}"
}

main() {
    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    # 系统检测
    detect_os
    detect_arch
    load_socks5_config
    
    while true; do
        show_menu
        read -rp "请选择 [0-15]: " choice
        
        case "$choice" in
            1)
                install_dependencies
                install_singbox
                press_enter
                ;;
            2)
                configure_socks5_outbounds true
                press_enter
                ;;
            3)
                add_cloudflare_tunnel_node
                press_enter
                ;;
            4)
                add_vless_ws_tls
                press_enter
                ;;
            5)
                add_trojan_ws_tls
                press_enter
                ;;
            6)
                add_shadowsocks
                press_enter
                ;;
            7)
                show_nodes
                press_enter
                ;;
            8)
                show_node_links
                press_enter
                ;;
            9)
                delete_node
                press_enter
                ;;
            10)
                start_service
                press_enter
                ;;
            11)
                stop_service
                press_enter
                ;;
            12)
                restart_service
                press_enter
                ;;
            13)
                show_runtime_status
                press_enter
                ;;
            14)
                show_logs
                press_enter
                ;;
            15)
                uninstall_singbox
                ;;
            0)
                print_info "再见！"
                exit 0
                ;;
            *)
                print_error "无效选项"
                press_enter
                ;;
        esac
    done
}

# 运行主程序
main "$@"
