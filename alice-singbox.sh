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
OS_TYPE=""      # debian 或 alpine
ARCH=""         # amd64, arm64, armv7 等
GITHUB_PROXY="" # GitHub 加速源

# SOCKS5 出口配置 (固定)
SOCKS5_SERVER="2a14:67c0:116::1"
SOCKS5_USER="alice"
SOCKS5_PASS="alicefofo123..OVO"
SOCKS5_PORTS=(10001 10002 10003 10004 10005 10006 10007 10008)

# GitHub 加速源列表
GITHUB_PROXIES=(
    "https://ghfile.geekertao.top/"
    "https://github.dpik.top/"
    "https://gh.dpik.top/"
    "https://gh.felicity.ac.cn/"
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

# 生成 Shadowsocks 2022 密钥 (Base64)
generate_ss2022_key() {
    local bits=${1:-128}
    local bytes=$((bits / 8))
    dd if=/dev/urandom bs=1 count=$bytes 2>/dev/null | base64
}

# 检查命令是否存在
check_command() {
    command -v "$1" &>/dev/null
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

check_github_proxy() {
    print_info "检测 GitHub 加速源..."
    
    # 先测试是否可以直接访问 GitHub
    if curl -s --connect-timeout 5 -o /dev/null "https://github.com" 2>/dev/null; then
        print_success "可以直接访问 GitHub"
        GITHUB_PROXY=""
        return 0
    fi
    
    # 测试加速源
    for proxy in "${GITHUB_PROXIES[@]}"; do
        print_info "测试加速源: $proxy"
        local test_url="${proxy}https://github.com/SagerNet/sing-box/releases"
        if curl -s --connect-timeout 10 -o /dev/null "$test_url" 2>/dev/null; then
            print_success "可用加速源: $proxy"
            GITHUB_PROXY="$proxy"
            return 0
        fi
    done
    
    print_error "所有 GitHub 加速源均不可用"
    return 1
}

# 获取加速后的 URL
get_proxied_url() {
    local url="$1"
    if [ -n "$GITHUB_PROXY" ]; then
        echo "${GITHUB_PROXY}${url}"
    else
        echo "$url"
    fi
}

# ============================================
# 安装依赖
# ============================================

install_dependencies() {
    print_info "安装依赖..."
    
    if [ "$OS_TYPE" = "debian" ]; then
        apt-get update -qq
        apt-get install -y -qq curl wget jq openssl qrencode
    elif [ "$OS_TYPE" = "alpine" ]; then
        apk update
        apk add curl wget jq openssl libqrencode-tools
    fi
    
    print_success "依赖安装完成"
}

# ============================================
# Sing-box 安装
# ============================================

# 默认版本号 (可根据需要更新)
DEFAULT_SINGBOX_VERSION="1.12.14"

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
    
    # 选择加速源
    echo ""
    echo "选择 GitHub 加速源:"
    for i in "${!GITHUB_PROXIES[@]}"; do
        if [ "$i" -eq 0 ]; then
            echo "$((i+1)). ${GITHUB_PROXIES[$i]} (默认)"
        else
            echo "$((i+1)). ${GITHUB_PROXIES[$i]}"
        fi
    done
    echo "$((${#GITHUB_PROXIES[@]}+1)). 自定义加速源"
    echo ""
    read -rp "选择 [1-$((${#GITHUB_PROXIES[@]}+1))] (默认 1): " proxy_choice
    proxy_choice=${proxy_choice:-1}
    
    if [ "$proxy_choice" -eq "$((${#GITHUB_PROXIES[@]}+1))" ]; then
        # 自定义输入
        read -rp "输入加速源 URL (需以 / 结尾): " custom_proxy
        if [ -z "$custom_proxy" ]; then
            print_error "加速源不能为空"
            return 1
        fi
        # 确保以 / 结尾
        if [[ "$custom_proxy" != */ ]]; then
            custom_proxy="${custom_proxy}/"
        fi
        GITHUB_PROXY="$custom_proxy"
    elif [ "$proxy_choice" -ge 1 ] && [ "$proxy_choice" -le "${#GITHUB_PROXIES[@]}" ]; then
        GITHUB_PROXY="${GITHUB_PROXIES[$((proxy_choice-1))]}"
    else
        GITHUB_PROXY="${GITHUB_PROXIES[0]}"
    fi
    print_info "使用加速源: $GITHUB_PROXY"
    
    # 输入版本号
    echo ""
    read -rp "输入Sing-box版本号 (默认 $DEFAULT_SINGBOX_VERSION): " version
    version=${version:-$DEFAULT_SINGBOX_VERSION}
    
    print_info "安装版本: v$version"
    
    # 下载文件名
    local filename="sing-box-${version}-linux-${ARCH}.tar.gz"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${filename}"
    local proxied_url="${GITHUB_PROXY}${download_url}"
    
    print_info "下载: $proxied_url"
    
    # 下载并解压
    local tmp_dir="/tmp/sing-box-install"
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
        mkdir -p "$tmp_dir"
        
        print_info "解压文件..."
        tar -xzf "$file_path" -C "$tmp_dir"
        
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
Restart=on-failure
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
command_background="yes"
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
}

# ============================================
# 配置生成 (追加模式)
# ============================================

# 生成固定的 8 个 SOCKS5 出口
generate_socks5_outbounds() {
    local outbounds_json=""
    
    for i in {1..8}; do
        local port="${SOCKS5_PORTS[$((i-1))]}"
        local socks_tag="socks-out-$i"
        
        local outbound="{\"type\":\"socks\",\"tag\":\"${socks_tag}\",\"server\":\"${SOCKS5_SERVER}\",\"server_port\":${port},\"version\":\"5\",\"username\":\"${SOCKS5_USER}\",\"password\":\"${SOCKS5_PASS}\"}"
        
        if [ -n "$outbounds_json" ]; then
            outbounds_json="${outbounds_json},"
        fi
        outbounds_json="${outbounds_json}${outbound}"
    done
    
    echo "$outbounds_json"
}

# 初始化基础配置 (如果不存在)
init_base_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # 配置已存在，检查格式是否正确
        if jq empty "$CONFIG_FILE" 2>/dev/null; then
            return 0
        fi
    fi
    
    # 创建基础配置
    local outbounds_json=$(generate_socks5_outbounds)
    
    cat > "$CONFIG_FILE" <<EOF
{
    "log": {
        "level": "info",
        "output": "$LOG_FILE",
        "timestamp": true
    },
    "inbounds": [],
    "outbounds": [
        $outbounds_json,
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
    ],
    "route": {
        "rules": [],
        "final": "socks-out-1"
    }
}
EOF
    print_success "初始化基础配置完成"
}

# 添加 inbound 到现有配置
add_inbound_to_config() {
    local inbound_json="$1"
    local route_rules_json="$2"
    
    # 确保基础配置存在
    init_base_config
    
    # 使用 jq 追加 inbound
    local new_config=$(jq --argjson inbound "$inbound_json" \
        '.inbounds += [$inbound]' "$CONFIG_FILE")
    
    echo "$new_config" > "$CONFIG_FILE"
    
    # 追加路由规则
    if [ -n "$route_rules_json" ]; then
        new_config=$(jq --argjson rules "$route_rules_json" \
            '.route.rules += $rules' "$CONFIG_FILE")
        echo "$new_config" > "$CONFIG_FILE"
    fi
}

# 添加多个 inbound 到现有配置 (用于 SS 多端口)
add_inbounds_to_config() {
    local inbounds_json="$1"  # JSON 数组
    local route_rules_json="$2"  # JSON 数组
    
    # 确保基础配置存在
    init_base_config
    
    # 使用 jq 追加 inbounds
    local new_config=$(jq --argjson inbounds "$inbounds_json" \
        '.inbounds += $inbounds' "$CONFIG_FILE")
    
    echo "$new_config" > "$CONFIG_FILE"
    
    # 追加路由规则
    if [ -n "$route_rules_json" ]; then
        new_config=$(jq --argjson rules "$route_rules_json" \
            '.route.rules += $rules' "$CONFIG_FILE")
        echo "$new_config" > "$CONFIG_FILE"
    fi
}

# 生成 VLESS/Trojan 的路由规则 (8 用户)
generate_user_route_rules() {
    local inbound_tag="$1"
    local use_auth_user="$2"  # true for shadowsocks
    local route_rules_json=""
    
    for i in {1..8}; do
        local user_name="user-$i"
        local socks_tag="socks-out-$i"
        
        local rule
        if [ "$use_auth_user" = "true" ]; then
            rule="{\"inbound\":[\"${inbound_tag}\"],\"auth_user\":[\"${user_name}\"],\"outbound\":\"${socks_tag}\"}"
        else
            rule="{\"inbound\":[\"${inbound_tag}\"],\"user\":[\"${user_name}\"],\"outbound\":\"${socks_tag}\"}"
        fi
        
        if [ -n "$route_rules_json" ]; then
            route_rules_json="${route_rules_json},"
        fi
        route_rules_json="${route_rules_json}${rule}"
    done
    
    echo "[$route_rules_json]"
}

# 添加 VLESS-WS-TLS 节点
add_vless_ws_tls() {
    echo ""
    print_info "=== 添加 VLESS-WS-TLS 节点 ==="
    echo ""
    
    # 获取用户输入
    read -rp "回源端口 (Sing-box 监听端口): " listen_port
    
    if [ -z "$listen_port" ]; then
        print_error "端口不能为空"
        return 1
    fi

    if [ "$listen_port" -lt 1000 ]; then
        print_error "端口建议 > 1000"
        return 1
    fi
    
    # 获取连接 IP
    local connection_ip=$(get_connection_ip)
    
    # 获取连接端口
    read -rp "连接端口 (用于生成链接, 默认 443): " show_port
    show_port=${show_port:-443}
    
    read -rp "WebSocket 路径 (默认 /vless): " ws_path
    ws_path=${ws_path:-/vless}
    
    read -rp "域名 (CF 代理的域名): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        return 1
    fi
    
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
    
    # 生成 8 个用户 UUID
    local users_json=""
    local uuids=()
    
    for i in {1..8}; do
        local uuid=$(generate_uuid)
        uuids+=("$uuid")
        local user="{\"name\":\"user-$i\",\"uuid\":\"$uuid\"}"
        if [ -n "$users_json" ]; then
            users_json="${users_json},"
        fi
        users_json="${users_json}${user}"
    done
    
    # 构建 inbound JSON (单行格式确保 jq 正确解析)
    local inbound_json="{\"type\":\"vless\",\"tag\":\"vless-in\",\"listen\":\"::\",\"listen_port\":${listen_port},\"users\":[${users_json}],\"tls\":{\"enabled\":true,\"server_name\":\"${domain}\",\"certificate_path\":\"${cert_path}\",\"key_path\":\"${key_path}\"},\"transport\":{\"type\":\"ws\",\"path\":\"${ws_path}\"}}"
    
    # 生成路由规则
    local route_rules_json=$(generate_user_route_rules "vless-in" "false")
    
    # 追加到配置
    add_inbound_to_config "$inbound_json" "$route_rules_json"
    
    # 验证配置
    if ! sing-box check -c "$CONFIG_FILE" 2>/dev/null; then
        print_error "配置文件验证失败"
        sing-box check -c "$CONFIG_FILE"
        return 1
    fi
    
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
    
    read -rp "回源端口 (Sing-box 监听端口): " listen_port
    
    if [ -z "$listen_port" ]; then
        print_error "端口不能为空"
        return 1
    fi
    
    if [ "$listen_port" -lt 1000 ]; then
        print_error "端口建议 > 1000"
        return 1
    fi
    
    # 获取连接 IP
    local connection_ip=$(get_connection_ip)
    
    # 获取连接端口
    read -rp "连接端口 (用于生成链接, 默认 443): " show_port
    show_port=${show_port:-443}
    
    read -rp "WebSocket 路径 (默认 /trojan): " ws_path
    ws_path=${ws_path:-/trojan}
    
    read -rp "域名 (CF 代理的域名): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        return 1
    fi
    
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
    
    # 生成 8 个用户密码
    local users_json=""
    local passwords=()
    
    for i in {1..8}; do
        local password=$(generate_random_string 16)
        passwords+=("$password")
        local user="{\"name\":\"user-$i\",\"password\":\"$password\"}"
        if [ -n "$users_json" ]; then
            users_json="${users_json},"
        fi
        users_json="${users_json}${user}"
    done
    
    # 构建 inbound JSON (单行格式确保 jq 正确解析)
    local inbound_json="{\"type\":\"trojan\",\"tag\":\"trojan-in\",\"listen\":\"::\",\"listen_port\":${listen_port},\"users\":[${users_json}],\"tls\":{\"enabled\":true,\"server_name\":\"${domain}\",\"certificate_path\":\"${cert_path}\",\"key_path\":\"${key_path}\"},\"transport\":{\"type\":\"ws\",\"path\":\"${ws_path}\"}}"
    
    # 生成路由规则
    local route_rules_json=$(generate_user_route_rules "trojan-in" "false")
    
    # 追加到配置
    add_inbound_to_config "$inbound_json" "$route_rules_json"
    
    # 验证配置
    if ! sing-box check -c "$CONFIG_FILE" 2>/dev/null; then
        print_error "配置文件验证失败"
        sing-box check -c "$CONFIG_FILE"
        return 1
    fi
    
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

# 添加 Shadowsocks 节点 (8 端口模式)
add_shadowsocks() {
    echo ""
    print_info "=== 添加 Shadowsocks 节点 (8 端口模式) ==="
    echo ""
    
    read -rp "起始端口 (将监听 8 个连续端口): " start_port
    
    if [ -z "$start_port" ]; then
        print_error "端口不能为空"
        return 1
    fi

    if [ "$start_port" -lt 1000 ]; then
        print_error "端口建议 > 1000"
        return 1
    fi
    
    # 获取连接 IP
    local connection_ip=$(get_connection_ip)
    
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
    
    # 生成 8 个用户密码和 8 个 inbound (JSON 数组格式)
    local inbounds_arr=""
    local route_rules_arr=""
    local passwords=()
    
    for i in {1..8}; do
        local port=$((start_port + i - 1))
        local socks_tag="socks-out-$i"
        
        local password
        if [ "$key_bits" -gt 0 ]; then
            password=$(generate_ss2022_key $key_bits)
        else
            password=$(generate_random_string 16)
        fi
        passwords+=("$password")
        
        # 构建 inbound JSON
        local password_field
        if [ -n "$server_key" ]; then
            password_field="\"password\":\"$server_key\","
        else
            password_field="\"password\":\"$password\","
        fi
        
        local inbound="{\"type\":\"shadowsocks\",\"tag\":\"ss-in-${i}\",\"listen\":\"::\",\"listen_port\":${port},\"method\":\"${method}\",${password_field}\"users\":[{\"name\":\"user-${i}\",\"password\":\"${password}\"}]}"
        
        if [ -n "$inbounds_arr" ]; then
            inbounds_arr="${inbounds_arr},"
        fi
        inbounds_arr="${inbounds_arr}${inbound}"
        
        # 路由规则
        local rule="{\"inbound\":[\"ss-in-${i}\"],\"outbound\":\"${socks_tag}\"}"
        if [ -n "$route_rules_arr" ]; then
            route_rules_arr="${route_rules_arr},"
        fi
        route_rules_arr="${route_rules_arr}${rule}"
    done
    
    # 追加到配置 (使用 JSON 数组)
    add_inbounds_to_config "[$inbounds_arr]" "[$route_rules_arr]"
    
    # 验证配置
    if ! sing-box check -c "$CONFIG_FILE" 2>/dev/null; then
        print_error "配置文件验证失败"
        sing-box check -c "$CONFIG_FILE"
        return 1
    fi
    
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
    
    # 创建新节点的 JSON
    local new_node=$(cat <<EOF
{
    "protocol": "$protocol",
    "domain": "$domain",
    "ipv6": "$ipv6",
    "port": $port,
    "real_port": $real_port,
    "path": "$path",
    "extra": "$extra",
    "credentials": $(printf '%s\n' "${credentials[@]}" | jq -R . | jq -s .)
}
EOF
)
    
    # 如果文件存在且是有效的 JSON 数组，追加；否则创建新数组
    if [ -f "$node_info_file" ] && jq -e 'type == "array"' "$node_info_file" >/dev/null 2>&1; then
        # 追加到现有数组
        local updated=$(jq --argjson node "$new_node" '. += [$node]' "$node_info_file")
        echo "$updated" > "$node_info_file"
    else
        # 创建新数组
        echo "[$new_node]" | jq '.' > "$node_info_file"
    fi
}

# 导出 VLESS 链接
export_vless_links() {
    local domain="$1"
    local connection_ip="$2"
    local port="$3"
    local path="$4"
    shift 4
    local uuids=("$@")
    
    local encoded_path=$(echo "$path" | sed 's|/|%2F|g')
    local all_links=""
    
    # 格式化地址：如果是 IPv6 (包含 :) 则添加 []，否则直接使用
    local formatted_address="$connection_ip"
    if [[ "$connection_ip" == *:* ]]; then
        formatted_address="[${connection_ip}]"
    fi
    
    for i in {1..8}; do
        local uuid="${uuids[$((i-1))]}"
        local socks_port="${SOCKS5_PORTS[$((i-1))]}"
        local remark="VLESS-出口${i}-端口${socks_port}"
        local encoded_remark=$(echo "$remark" | sed 's/ /%20/g')
        
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
    
    local encoded_path=$(echo "$path" | sed 's|/|%2F|g')
    local all_links=""
    
    # 格式化地址
    local formatted_address="$connection_ip"
    if [[ "$connection_ip" == *:* ]]; then
        formatted_address="[${connection_ip}]"
    fi
    
    for i in {1..8}; do
        local password="${passwords[$((i-1))]}"
        local socks_port="${SOCKS5_PORTS[$((i-1))]}"
        local remark="Trojan-出口${i}-端口${socks_port}"
        local encoded_remark=$(echo "$remark" | sed 's/ /%20/g')
        
        # 使用格式化后的地址
        local link="trojan://${password}@${formatted_address}:${port}?security=tls&sni=${domain}&allowInsecure=1&type=ws&host=${domain}&path=${encoded_path}#${encoded_remark}"
        
        echo -e "${GREEN}出口 $i (端口 $socks_port):${NC}"
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
    local formatted_address="$connection_ip"
    if [[ "$connection_ip" == *:* ]]; then
        formatted_address="[${connection_ip}]"
    fi
    
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
        
        local encoded=$(echo -n "$user_info" | base64 | tr -d '\n')
        local link="ss://${encoded}@${formatted_address}:${port}#${remark}"
        
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
        echo -e "${ALL_LINKS}" | sed '/^$/d' | base64 -w 0
        echo ""
        echo ""
    fi
}

# 显示已保存的节点链接 (支持多协议)
show_node_links() {
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
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl stop sing-box
    else
        rc-service sing-box stop
    fi
    print_success "服务已停止"
}

restart_service() {
    print_info "重启 sing-box 服务..."
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
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    else
        rc-service sing-box stop 2>/dev/null
        rc-update del sing-box default 2>/dev/null
        rm -f /etc/init.d/sing-box
    fi
    
    # 删除文件
    print_info "删除文件..."
    rm -f /usr/local/bin/sing-box
    rm -rf "$CONFIG_DIR"
    rm -rf "$DATA_DIR"
    rm -f "$LOG_FILE"
    
    print_success "sing-box 已卸载"
    
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
    
    # 删除配置
    rm -f "$CONFIG_FILE"
    rm -f "${DATA_DIR}/node_info.json"
    
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
    echo ""
    echo -e "${CYAN}1.${NC} 安装/更新 Sing-box"
    echo ""
    echo -e "${YELLOW}--- 节点管理 ---${NC}"
    echo -e "${CYAN}2.${NC} 添加 VLESS-WS-TLS 节点"
    echo -e "${CYAN}3.${NC} 添加 Trojan-WS-TLS 节点"
    echo -e "${CYAN}4.${NC} 添加 Shadowsocks 节点"
    echo -e "${CYAN}5.${NC} 查看当前节点"
    echo -e "${CYAN}6.${NC} 删除节点"
    echo ""
    echo -e "${YELLOW}--- 服务管理 ---${NC}"
    echo -e "${CYAN}7.${NC} 启动服务"
    echo -e "${CYAN}8.${NC} 停止服务"
    echo -e "${CYAN}9.${NC} 重启服务"
    echo -e "${CYAN}10.${NC} 查看服务状态"
    echo -e "${CYAN}11.${NC} 查看日志"
    echo ""
    echo -e "${YELLOW}--- 导出 ---${NC}"
    echo -e "${CYAN}12.${NC} 导出节点链接"
    echo ""
    echo -e "${RED}13.${NC} 卸载 Sing-box"
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
    
    while true; do
        show_menu
        read -rp "请选择 [0-13]: " choice
        
        case "$choice" in
            1)
                install_dependencies
                install_singbox
                press_enter
                ;;
            2)
                add_vless_ws_tls
                press_enter
                ;;
            3)
                add_trojan_ws_tls
                press_enter
                ;;
            4)
                add_shadowsocks
                press_enter
                ;;
            5)
                show_nodes
                press_enter
                ;;
            6)
                delete_node
                press_enter
                ;;
            7)
                start_service
                press_enter
                ;;
            8)
                stop_service
                press_enter
                ;;
            9)
                restart_service
                press_enter
                ;;
            10)
                show_service_status
                press_enter
                ;;
            11)
                show_logs
                press_enter
                ;;
            12)
                show_node_links
                press_enter
                ;;
            13)
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
