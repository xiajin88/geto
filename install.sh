#!/usr/bin/env bash
# NodeProtocol v1.8.1
# Ubuntu / Debian / CentOS 一键节点（IP 直连，无域名/CDN）
#
#   bash <(curl -fsSL https://你的地址/install.sh)
#   装好后: np   或   nodeprotocol
#
# 仅安装到你自己的 VPS。必须用 bash <(curl ...)，不要用 curl | bash。

set -o pipefail
set +o histexpand
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
if locale -a 2>/dev/null | grep -qiE 'C\.UTF-8|C\.utf8'; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qiE 'en_US\.utf8|en_US\.UTF-8'; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
else
    export LANG=C LC_ALL=C
fi

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1
NP_VERSION="1.8.1"
VERSION="$NP_VERSION"
NODE_HOME="/usr/local/nodeprotocol"
META_DIR="$NODE_HOME/meta"
CLASH_DIR="$NODE_HOME/clash"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
HY2_CONF="/etc/hysteria/config.yaml"
HY2_BIN="/usr/local/bin/hysteria"

RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*" >&2; }
info() { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [[ $(id -u) -eq 0 ]] || die "请使用 root 运行：sudo -i 后再执行"; }

need_tty() {
    if [[ ! -t 0 ]]; then
        cat >&2 <<'EOF'
请使用进程替换运行（不要 curl | bash，否则无法交互）：
  bash <(curl -fsSL https://你的地址/install.sh)
EOF
        exit 1
    fi
}

pause() { echo; read -rp "按回车返回菜单..." _; }

ask() {
    local prompt="$1" default="${2-}" input
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " input
        printf '%s' "${input:-$default}"
    else
        read -rp "$prompt: " input
        printf '%s' "$input"
    fi
}

rand_alnum() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-16}"; }
rand_hex()   { tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c "${1:-16}"; }
rand_path()  { echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"; }

rand_fp() {
    local fps=(chrome firefox safari ios edge)
    echo "${fps[$(( $(od -An -N1 -tu1 </dev/urandom | tr -d ' ') % ${#fps[@]} ))]}"
}

rand_port() {
    local p i
    for i in $(seq 1 50); do
        p=$(( ( $(od -An -N2 -tu2 </dev/urandom | tr -d ' ') % 40000 ) + 20000 ))
        if ! port_taken "$p"; then
            echo "$p"; return 0
        fi
    done
    echo "$((RANDOM % 20000 + 30000))"
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) && [[ "$p" != "22" ]]
}

port_used_tcp() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lnt "( sport = :$p )" 2>/dev/null | grep -q .
    else
        netstat -lnt 2>/dev/null | grep -qE "[.:]${p}[[:space:]]"
    fi
}

port_used_udp() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lnu "( sport = :$p )" 2>/dev/null | grep -q .
    else
        netstat -lnu 2>/dev/null | grep -qE "[.:]${p}[[:space:]]"
    fi
}

xray_port_used() {
    local p="$1"
    [[ -f "$XRAY_CONF" ]] || return 1
    python3 - "$XRAY_CONF" "$p" <<'PY' 2>/dev/null
import json,sys
try:
    conf=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception:
    sys.exit(1)
port=int(sys.argv[2])
sys.exit(0 if any(int(i.get("port") or 0)==port for i in conf.get("inbounds",[])) else 1)
PY
}

meta_port_used() {
    local p="$1" f cur
    [[ -d "$META_DIR" ]] || return 1
    shopt -s nullglob
    for f in "$META_DIR"/*.json; do
        cur="$(load_meta "$f" port)"
        [[ "$cur" == "$p" ]] && return 0
    done
    return 1
}

# TCP/UDP 同一端口号也算冲突，避免 VLESS 443 和 Hy2 443 同时占用
port_taken() {
    local p="$1"
    port_used_tcp "$p" || port_used_udp "$p" || xray_port_used "$p" || meta_port_used "$p"
}

meta_exists() { [[ -f "$META_DIR/$1.json" ]]; }

detect_os() {
    OS_ID=""; OS_VER=""; OS_PRETTY=""; PKG=""
    if [[ -f /etc/os-release ]]; then
        OS_ID="$(. /etc/os-release; printf '%s' "${ID:-unknown}")"
        OS_VER="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
        OS_PRETTY="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-}")"
    fi
    [[ -n "$OS_PRETTY" ]] || OS_PRETTY="${OS_ID:-unknown} ${OS_VER}"
    VERSION="$NP_VERSION"
    case "$OS_ID" in
        ubuntu|debian) PKG="apt" ;;
        centos|rhel|rocky|almalinux|fedora|ol|anolis|opencloudos|alinux) PKG="yum" ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then PKG="apt"
            elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then PKG="yum"
            else die "不支持的系统，仅支持 Ubuntu / Debian / CentOS 系"
            fi
            ;;
    esac
}

install_deps() {
    if command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        echo "依赖已存在，跳过软件包安装"
        mkdir -p "$NODE_HOME" "$META_DIR" "$CLASH_DIR" /var/log/xray
        ok "依赖就绪"
        return 0
    fi
    if [[ "$PKG" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl wget ca-certificates unzip openssl python3 jq qrencode \
            iproute2 net-tools tar gzip coreutils procps
    else
        local yumcmd="yum"
        command -v dnf >/dev/null 2>&1 && yumcmd="dnf"
        $yumcmd install -y curl wget ca-certificates unzip openssl python3 tar gzip \
            iproute net-tools procps-ng || true
        $yumcmd install -y epel-release || true
        $yumcmd install -y jq qrencode python3 || true
    fi
    command -v python3 >/dev/null || die "python3 安装失败"
    command -v openssl >/dev/null || die "openssl 安装失败"
    command -v curl >/dev/null || die "curl 安装失败"
    if ! command -v jq >/dev/null 2>&1; then
        echo "正在下载 jq..."
        local arch jqurl
        arch="$(uname -m)"
        case "$arch" in
            x86_64) jqurl="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" ;;
            aarch64|arm64) jqurl="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-arm64" ;;
            *) die "请手动安装 jq" ;;
        esac
        curl -fL "$jqurl" -o /usr/local/bin/jq && chmod +x /usr/local/bin/jq
        command -v jq >/dev/null || die "jq 安装失败"
    fi
    mkdir -p "$NODE_HOME" "$META_DIR" "$CLASH_DIR" /var/log/xray
    ok "依赖就绪"
}

persist_self() {
    mkdir -p "$NODE_HOME"
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -r "$src" ]]; then
        cat "$src" > "$NODE_HOME/install.sh" 2>/dev/null || true
        chmod +x "$NODE_HOME/install.sh" 2>/dev/null || true
        ln -sf "$NODE_HOME/install.sh" /usr/local/bin/np
        ln -sf "$NODE_HOME/install.sh" /usr/local/bin/nodeprotocol
    fi
}

enable_bbr() {
    mkdir -p /etc/sysctl.d
    if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        printf 'net.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
        ok "BBR 已启用"
    else
        printf 'net.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
        warn "当前内核可能不支持 BBR，已写入 /etc/sysctl.d/99-bbr.conf"
    fi
}

# 稳定性 / 低延迟 / 带宽：不改协议指纹。故意不用 TCP Fast Open，避免握手特征变化。
enable_net_tune() {
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-nodeprotocol-net.conf <<'EOF'
net.core.default.qdisc=fq
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=4096
net.core.netdev_max_backlog=16384
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
    sysctl -p /etc/sysctl.d/99-nodeprotocol-net.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true
    local _rp
    for _rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
        [[ -f "$_rp" ]] || continue
        echo 2 > "$_rp" 2>/dev/null || true
    done
    ok "已应用网络稳定性与延迟参数"
}

detect_hy2_bandwidth() {
    local iface speed
    iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    speed="$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)"
    if [[ "$speed" =~ ^[0-9]+$ ]] && (( speed >= 100 && speed <= 100000 )); then
        echo "${speed} mbps"
    else
        echo "1000 mbps"
    fi
}

install_speedtest_cli() {
    if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>/dev/null | grep -qi ookla; then
        return 0
    fi
    local arch url tmp
    case "$(uname -m)" in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) warn "当前架构暂无官方 Speedtest CLI，跳过测速"; return 1 ;;
    esac
    url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${arch}.tgz"
    tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 60 "$url" | tar -xz -C "$tmp"; then
        rm -rf "$tmp"
        warn "官方 Speedtest CLI 下载失败，跳过测速"
        return 1
    fi
    if [[ -x "$tmp/speedtest" ]]; then
        install -m 0755 "$tmp/speedtest" /usr/local/bin/speedtest
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    warn "官方 Speedtest CLI 安装失败，跳过测速"
    return 1
}

run_speedtest() {
    echo
    echo "正在测速，请稍候..."
    install_speedtest_cli || return 0
    local json
    json="$(speedtest --accept-license --accept-gdpr --format=json --progress=no 2>/dev/null)" || true
    if [[ -z "$json" ]]; then
        warn "测速失败，不影响节点使用"
        return 0
    fi
    local stmp
    stmp="$(mktemp)"
    printf '%s' "$json" > "$stmp"
    python3 - "$stmp" <<'PY'
# -*- coding: utf-8 -*-
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.stdout.buffer.write("测速失败\n".encode("utf-8"))
    sys.exit(0)

def mbps(b):
    try:
        return float(b) * 8.0 / 1e6
    except Exception:
        return 0.0

def wrap(color, text):
    return "\033[%sm%s\033[0m" % (color, text)

ping = (d.get("ping") or {})
down = mbps((d.get("download") or {}).get("bandwidth"))
up = mbps((d.get("upload") or {}).get("bandwidth"))
try:
    lat = float(ping.get("latency") or 0)
except Exception:
    lat = 0.0

if lat <= 80:
    lat_s = wrap("1;32", "%.1f 毫秒" % lat)
elif lat <= 180:
    lat_s = wrap("1;33", "%.1f 毫秒" % lat)
else:
    lat_s = wrap("1;31", "%.1f 毫秒" % lat)

def speed_s(v):
    t = "%.2f Mbps/秒" % v
    if v >= 100:
        return wrap("1;32", t)
    if v >= 20:
        return wrap("1;33", t)
    return wrap("1;31", t)

out = "延迟    %s\n下载    %s\n上传    %s\n测速完成\n" % (lat_s, speed_s(down), speed_s(up))
sys.stdout.buffer.write(out.encode("utf-8"))
PY
    rm -f "$stmp"
}

get_public_ip() {
    if [[ -n "${PUBLIC_IP:-}" ]]; then
        echo "$PUBLIC_IP"
        return 0
    fi
    local ip="" src
    for src in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ip.sb; do
        ip="$(curl -4 -fsS --max-time 6 "$src" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { PUBLIC_IP="$ip"; echo "$ip"; return 0; }
    done
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    PUBLIC_IP="${ip:-127.0.0.1}"
    echo "$PUBLIC_IP"
}

is_public_ipv4() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
    (( a<=255 && b<=255 && c<=255 && d<=255 )) || return 1
    (( a==0 || a==10 || a==127 || a>=224 )) && return 1
    (( a==169 && b==254 )) && return 1
    (( a==192 && b==168 )) && return 1
    (( a==172 && b>=16 && b<=31 )) && return 1
    (( a==100 && b>=64 && b<=127 )) && return 1
    return 0
}

collect_public_ips() {
    local ip primary seen="" out=()
    primary="$(get_public_ip)"
    if is_public_ipv4 "$primary"; then
        out+=("$primary")
        seen="|$primary|"
    fi
    while read -r ip; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        is_public_ipv4 "$ip" || continue
        [[ "$seen" == *"|$ip|"* ]] && continue
        out+=("$ip")
        seen="${seen}|$ip|"
    done < <(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    if [[ ${#out[@]} -eq 0 ]]; then
        out+=("${primary:-127.0.0.1}")
    fi
    PUBLIC_IPS=("${out[@]}")
}

choose_install_ips() {
    local i c nips idx ch sel seen
    collect_public_ips
    INSTALL_IPS=()
    nips=${#PUBLIC_IPS[@]}
    if (( nips <= 1 )); then
        INSTALL_IPS=("${PUBLIC_IPS[@]}")
        return 0
    fi
    echo >&2
    echo -e "${BOLD}检测到多个公网 IP${NC}" >&2
    echo "请选择要安装的 IP（每个 IP 独立端口、独立密钥；同一协议不会在同一 IP 上重复安装）" >&2
    echo "  0) 全部IP安装" >&2
    i=1
    for ip in "${PUBLIC_IPS[@]}"; do
        echo "  $i) ${ip}" >&2
        i=$((i+1))
    done
    echo >&2
    echo "说明：" >&2
    echo "  直接回车或输入 0  = 全部 IP 都生成链接（输入1-2，就只安装第1个跟第2个，不生成第3个）" >&2
    while true; do
        read -rp "请输入数字 [0]: " c
        c="${c//[[:space:]]/}"
        if [[ -z "$c" || "$c" == "0" ]]; then
            INSTALL_IPS=("${PUBLIC_IPS[@]}")
            return 0
        fi
        local ok=1 tokens t a b j
        sel=()
        seen="|"
        IFS=',' read -ra tokens <<< "$c"
        for t in "${tokens[@]}"; do
            if [[ "$t" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]; then
                a="${t%%-*}"
                b="${t##*-}"
                if (( a > b )); then warn "区间无效：$t"; ok=0; break; fi
                for ((j=a; j<=b; j++)); do
                    if ! (( j >= 1 && j <= nips )); then
                        warn "没有第 ${j} 个 IP"
                        ok=0
                        break
                    fi
                    [[ "$seen" == *"|$j|"* ]] && continue
                    sel+=("${PUBLIC_IPS[$((j-1))]}")
                    seen="${seen}${j}|"
                done
                [[ "$ok" == 1 ]] || break
            elif [[ "$t" =~ ^[1-9][0-9]*$ ]]; then
                if ! (( t >= 1 && t <= nips )); then
                    warn "没有第 ${t} 个 IP"
                    ok=0
                    break
                fi
                [[ "$seen" == *"|$t|"* ]] && continue
                sel+=("${PUBLIC_IPS[$((t-1))]}")
                seen="${seen}${t}|"
            else
                warn "请输入 0、序号或区间，例如 1-2 或 1,3"
                ok=0
                break
            fi
        done
        if [[ "$ok" != 1 || ${#sel[@]} -eq 0 ]]; then
            continue
        fi
        INSTALL_IPS=("${sel[@]}")
        echo "已选择：${INSTALL_IPS[*]}" >&2
        return 0
    done
}

ip_to_tag() {
    printf '%s-%s' "$1" "$(printf '%s' "$2" | tr '.' '-')"
}

np_proto_tag() {
    local prefix="$1" ip="$2"
    if (( ${#PUBLIC_IPS[@]} > 1 )); then
        ip_to_tag "$prefix" "$ip"
    else
        printf '%s' "$prefix"
    fi
}

np_listen_addr() {
    local ip="$1"
    if (( ${#PUBLIC_IPS[@]} > 1 )); then
        printf '%s' "$ip"
    else
        printf '%s' "0.0.0.0"
    fi
}

filter_install_ips() {
    local prefix="$1" ip tag kept=()
    if (( ${#PUBLIC_IPS[@]} > 1 )) && meta_exists "$prefix"; then
        warn "检测到旧版整机节点（多 IP 共用同一端口）。请先到菜单 9 卸载后再按 IP 分别安装。"
        return 1
    fi
    for ip in "${INSTALL_IPS[@]}"; do
        tag="$(np_proto_tag "$prefix" "$ip")"
        if meta_exists "$tag"; then
            warn "${ip} 已安装该协议，跳过"
        else
            kept+=("$ip")
        fi
    done
    INSTALL_IPS=("${kept[@]}")
    if (( ${#INSTALL_IPS[@]} == 0 )); then
        warn "所选 IP 都已安装该协议"
        return 1
    fi
    return 0
}

print_nodes_with_sep() {
    local n=$# t
    if (( n > 1 )); then
        for t in "$@"; do
            echo
            echo "---------------------"
            print_node "$t"
        done
        echo
        echo "---------------------"
    elif (( n == 1 )); then
        print_node "$1"
    fi
}

open_firewall() {
    local port="$1" proto="${2:-tcp}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
        firewall-cmd --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    fi
    if command -v semanage >/dev/null 2>&1; then
        semanage port -a -t http_port_t -p "$proto" "$port" >/dev/null 2>&1 || \
        semanage port -m -t http_port_t -p "$proto" "$port" >/dev/null 2>&1 || true
    fi
}

close_firewall() {
    local port="$1" proto="${2:-tcp}"
    command -v ufw >/dev/null 2>&1 && ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    command -v iptables >/dev/null 2>&1 && iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
}

choose_mode() {
    echo >&2
    echo -e "${BOLD}安装模式${NC}" >&2
    echo "  1) 小白全自动（推荐）" >&2
    echo "  2) 自定义配置" >&2
    local c
    read -rp "请选择 [1]: " c
    [[ "${c:-1}" == "2" ]] && echo custom || echo auto
}

choose_tcp_port() {
    local preferred="$1" mode="$2" p
    if [[ "$mode" == "auto" ]]; then
        local cands=()
        [[ -n "$preferred" ]] && cands+=("$preferred")
        cands+=(443 8443 2053 2083 2087 2096)
        for p in "${cands[@]}"; do
            if valid_port "$p" && ! port_taken "$p"; then
                echo "$p"; return
            fi
        done
        rand_port; return
    fi
    while true; do
        p="$(ask "请输入 TCP 端口" "${preferred:-443}")"
        if ! valid_port "$p"; then warn "端口不合法（1-65535，不要用 22）"; continue; fi
        if port_taken "$p"; then warn "端口 $p 已被占用"; continue; fi
        echo "$p"; return
    done
}

choose_udp_port() {
    local preferred="$1" mode="$2" p
    if [[ "$mode" == "auto" ]]; then
        local cands=()
        [[ -n "$preferred" ]] && cands+=("$preferred")
        cands+=(443 8443 2053 2083 2087 2096)
        for p in "${cands[@]}"; do
            if valid_port "$p" && ! port_taken "$p"; then
                echo "$p"; return
            fi
        done
        rand_port; return
    fi
    while true; do
        p="$(ask "请输入 UDP 端口" "${preferred:-443}")"
        if ! valid_port "$p"; then warn "端口不合法"; continue; fi
        if port_taken "$p"; then warn "端口 $p 已被占用"; continue; fi
        echo "$p"; return
    done
}

# ---------------- 伪装域名随机池 ----------------
host_pool() {
    cat <<'EOF'
www.microsoft.com
www.office.com
www.xbox.com
www.minecraft.net
learn.microsoft.com
azure.microsoft.com
visualstudio.microsoft.com
onedrive.live.com
outlook.live.com
outlook.office.com
www.linkedin.com
github.com
www.bing.com
www.msn.com
www.windows.com
www.skype.com
teams.microsoft.com
www.apple.com
www.icloud.com
itunes.apple.com
developer.apple.com
apps.apple.com
music.apple.com
tv.apple.com
support.apple.com
www.amazon.com
www.amazon.co.uk
www.amazon.de
www.amazon.co.jp
aws.amazon.com
docs.aws.amazon.com
www.twitch.tv
www.imdb.com
www.nvidia.com
developer.nvidia.com
www.intel.com
www.amd.com
www.qualcomm.com
www.broadcom.com
www.cisco.com
www.oracle.com
www.ibm.com
www.sap.com
www.salesforce.com
www.adobe.com
www.autodesk.com
www.vmware.com
www.dell.com
www.hp.com
www.hpe.com
www.lenovo.com
www.asus.com
www.acer.com
www.samsung.com
www.lg.com
www.sony.com
www.panasonic.com
www.nintendo.com
www.playstation.com
www.ea.com
www.epicgames.com
www.blizzard.com
store.steampowered.com
www.steampowered.com
www.ubisoft.com
www.tesla.com
www.bmw.com
www.mercedes-benz.com
www.toyota.com
www.honda.com
www.hyundai.com
www.dropbox.com
www.box.com
www.zoom.us
www.slack.com
www.atlassian.com
bitbucket.org
gitlab.com
www.shopify.com
www.ebay.com
www.paypal.com
www.stripe.com
www.visa.com
www.mastercard.com
www.booking.com
www.airbnb.com
www.cloudflare.com
www.fastly.com
www.akamai.com
cdn.jsdelivr.net
www.mozilla.org
addons.mozilla.org
www.wikipedia.org
en.wikipedia.org
www.wikimedia.org
stackoverflow.com
www.reddit.com
www.harvard.edu
www.mit.edu
www.stanford.edu
www.berkeley.edu
www.yale.edu
www.princeton.edu
www.columbia.edu
www.cornell.edu
www.ucla.edu
www.nyu.edu
www.cmu.edu
www.gatech.edu
www.umich.edu
www.washington.edu
www.utexas.edu
www.illinois.edu
www.wisc.edu
www.purdue.edu
www.psu.edu
www.osu.edu
www.unc.edu
www.duke.edu
www.northwestern.edu
www.jhu.edu
www.caltech.edu
www.uchicago.edu
www.brown.edu
www.rice.edu
www.usc.edu
www.bu.edu
www.northeastern.edu
www.vt.edu
www.umd.edu
www.arizona.edu
www.colorado.edu
www.utoronto.ca
www.ubc.ca
www.mcgill.ca
www.sfu.ca
www.cam.ac.uk
www.ox.ac.uk
www.ed.ac.uk
www.ucl.ac.uk
www.imperial.ac.uk
www.tum.de
www.lmu.de
www.ethz.ch
www.epfl.ch
www.u-tokyo.ac.jp
www.kyoto-u.ac.jp
www.nus.edu.sg
www.ntu.edu.sg
www.sydney.edu.au
www.unimelb.edu.au
www.anu.edu.au
www.auckland.ac.nz
www.kaist.ac.kr
www.snu.ac.kr
www.ust.hk
www.hku.hk
www.cuhk.edu.hk
www.ntu.edu.tw
www.siemens.com
www.philips.com
www.bosch.com
www.abb.com
www.schneider-electric.com
www.3m.com
www.ge.com
www.honeywell.com
www.boeing.com
www.airbus.com
www.nike.com
www.adidas.com
www.ikea.com
www.costco.com
www.walmart.com
www.target.com
www.bestbuy.com
www.homedepot.com
www.netflix.com
www.spotify.com
www.discord.com
www.notion.so
www.figma.com
www.canva.com
www.digitalocean.com
www.hetzner.com
www.snowflake.com
www.databricks.com
www.mongodb.com
www.elastic.co
www.docker.com
www.kubernetes.io
www.hashicorp.com
www.jetbrains.com
code.visualstudio.com
www.python.org
www.nodejs.org
www.rust-lang.org
www.go.dev
www.php.net
www.npmjs.com
pypi.org
www.debian.org
www.ubuntu.com
www.kernel.org
www.gnu.org
www.openssl.org
www.letsencrypt.org
www.ietf.org
www.w3.org
www.ieee.org
www.acm.org
www.nature.com
www.science.org
arxiv.org
www.nih.gov
www.nasa.gov
www.nist.gov
www.who.int
www.un.org
www.imf.org
www.worldbank.org
www.oecd.org
www.bbc.com
www.reuters.com
www.bloomberg.com
www.ft.com
www.economist.com
www.nytimes.com
www.theguardian.com
www.nhk.or.jp
www.nikkei.com
www.redhat.com
www.canonical.com
www.iana.org
www.icann.org
www.verisign.com
www.archive.org
www.eff.org
www.medium.com
www.vimeo.com
www.soundcloud.com
www.postgresql.org
www.mysql.com
www.redis.io
www.terraform.io
www.opera.com
www.fedex.com
www.ups.com
www.dhl.com
www.expedia.com
www.tripadvisor.com
www.uber.com
www.quora.com
www.stackexchange.com
www.wordpress.com
www.jsdelivr.com
www.unpkg.com
www.arm.com
www.lockheedmartin.com
www.caterpillar.com
www.puma.com
www.hulu.com
www.bandcamp.com
www.fsf.org
www.apnic.net
www.ripe.net
www.arin.net
www.godaddy.com
www.namecheap.com
www.servicenow.com
www.intuit.com
www.adp.com
www.workday.com
www.square.com
www.lyft.com
www.maersk.com
www.zara.com
www.hm.com
www.uniqlo.com
www.lowes.com
www.suse.com
www.firefox.com
www.brave.com
pages.github.com
www.gitlab.com
www.cloudflarestatus.com
speed.cloudflare.com
www.gstatic.com
ajax.googleapis.com
fonts.gstatic.com
cdnjs.cloudflare.com
www.bootcdn.cn
www.bootcss.com
www.staticfile.org
cdn.staticfile.org
www.jsdelivr.net
fastly.jsdelivr.net
gcore.jsdelivr.net
www.cloudfront.net
d1.awsstatic.com
www.msftconnecttest.com
www.msftncsi.com
www.microsoftonline.com
login.microsoftonline.com
portal.azure.com
www.office365.com
www.live.com
www.outlook.com
account.microsoft.com
support.microsoft.com
www.xboxlive.com
www.minecraft.net
education.github.com
docs.github.com
skills.github.com
www.visualstudio.com
azure.microsoft.com
learn.microsoft.com
techcommunity.microsoft.com
devblogs.microsoft.com
www.bing.com
cn.bing.com
www.duckduckgo.com
www.startpage.com
www.ecosia.org
www.qwant.com
www.wolframalpha.com
www.weather.com
www.accuweather.com
www.timeanddate.com
www.worldtimebuddy.com
www.speedtest.net
www.fast.com
www.nperf.com
www.cloudflare.com
one.one.one.one
1.1.1.1
dns.google
quad9.net
www.quad9.net
www.opendns.com
www.cloudflare-dns.com
EOF
}

pick_random_host() {
    local given="${1-}"
    if [[ -n "$given" ]]; then
        printf '%s\n' "$given" | sed 's#^https\?://##; s#[/:].*##'
        return
    fi
    host_pool | python3 -c 'import sys,random,os
lines=[x.strip() for x in sys.stdin if x.strip()]
random.seed(os.urandom(16))
print(random.choice(lines))'
}

urlenc() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

b64() {
    python3 -c 'import sys,base64; print(base64.b64encode(sys.argv[1].encode()).decode().rstrip("="))' "$1"
}

print_qr() {
    local text="$1"
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${BOLD}二维码${NC}"
        qrencode -t ANSIUTF8 "$text" 2>/dev/null || qrencode -t UTF8 "$text" 2>/dev/null || warn "二维码生成失败"
    else
        warn "未安装 qrencode，跳过二维码"
    fi
}

save_meta() {
    local tag="$1"
    local tmp="$META_DIR/.$tag.json.tmp"
    mkdir -p "$META_DIR"
    cat > "$tmp"
    python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$tmp" \
        || { rm -f "$tmp"; die "内部配置 JSON 无效"; }
    mv -f "$tmp" "$META_DIR/$tag.json"
}

load_meta() {
    PYTHONIOENCODING=utf-8 python3 -c 'import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8")).get(sys.argv[2],"")
if v is None:
    v=""
sys.stdout.buffer.write((str(v)+"\n").encode("utf-8"))
' "$1" "$2" 2>/dev/null || true
}

# ---------------- Xray ----------------
install_xray() {
    mkdir -p /var/log/xray
    touch /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null || true
    chown nobody:nobody /var/log/xray /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null || true
    if [[ -x "$XRAY_BIN" ]]; then
        ok "Xray 已安装: $($XRAY_BIN version 2>/dev/null | head -n1)"
        return 0
    fi
    echo "======== 正在安装 Xray，下方滚动输出属于正常，请等待 ========"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || \
        die "Xray 安装失败（请确认服务器能访问 GitHub）"
    [[ -x "$XRAY_BIN" ]] || die "Xray 安装后未找到二进制"
    ok "Xray 安装完成"
}

ensure_xray_base() {
    mkdir -p /usr/local/etc/xray /var/log/xray
    if [[ -f "$XRAY_CONF" ]]; then
        if python3 - "$XRAY_CONF" <<'PY' 2>/dev/null
import json,sys
json.load(open(sys.argv[1],encoding="utf-8"))
PY
        then
            patch_xray_privacy
            return 0
        fi
        warn "现有 Xray 配置损坏，将重建（会保留能解析的 inbound）"
    fi
    cat > "$XRAY_CONF" <<'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
    patch_xray_privacy
}

patch_xray_privacy() {
    [[ -f "$XRAY_CONF" ]] || return 0
    python3 - "$XRAY_CONF" <<'PY'
import json,sys
path=sys.argv[1]
conf=json.load(open(path,encoding="utf-8"))
conf["dns"]={
  "servers": ["1.1.1.1","8.8.8.8","https://1.1.1.1/dns-query","https://8.8.8.8/dns-query"],
  "queryStrategy": "UseIPv4"
}
outs=[]
has_direct=False
for ob in conf.get("outbounds") or []:
    if ob.get("tag")=="direct" or ob.get("protocol")=="freedom":
        if ob.get("tag")=="direct":
            has_direct=True
        st=ob.setdefault("settings", {}) or {}
        st["domainStrategy"]="UseIPv4"
        ob["settings"]=st
    outs.append(ob)
if not has_direct:
    outs.insert(0, {"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}})
conf["outbounds"]=outs
rt=conf.setdefault("routing", {})
rt["domainStrategy"]="IPIfNonMatch"
rules=rt.get("rules") or []
if not any("geoip:private" in str(r.get("ip")) for r in rules):
    rules.insert(0, {"type":"field","ip":["geoip:private"],"outboundTag":"block"})
rt["rules"]=rules
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

xray_bind_inbound_ip() {
    local tag="$1" ip="$2" out_tag
    [[ -n "$tag" && -n "$ip" ]] || return 0
    [[ "$ip" == "0.0.0.0" || "$ip" == "127.0.0.1" ]] && return 0
    (( ${#PUBLIC_IPS[@]} > 1 )) || return 0
    [[ -f "$XRAY_CONF" ]] || return 0
    python3 - "$XRAY_CONF" "$tag" "$ip" <<'PY'
import json,sys
path,tag,ip=sys.argv[1],sys.argv[2],sys.argv[3]
out_tag="direct-"+ip.replace(".","-")
conf=json.load(open(path,encoding="utf-8"))
ob={
  "tag": out_tag,
  "protocol": "freedom",
  "sendThrough": ip,
  "settings": {"domainStrategy": "UseIPv4"}
}
outs=[o for o in (conf.get("outbounds") or []) if o.get("tag")!=out_tag]
# 追加在 direct/block 之后，避免变成默认出站
outs.append(ob)
conf["outbounds"]=outs
rt=conf.setdefault("routing", {})
rules=[]
for r in (rt.get("rules") or []):
    tags=list(r.get("inboundTag") or [])
    if tag in tags and r.get("outboundTag","").startswith("direct-"):
        continue
    rules.append(r)
rule={"type":"field","inboundTag":[tag],"outboundTag":out_tag}
idx=0
for i,r in enumerate(rules):
    if "geoip:private" in str(r.get("ip") or []):
        idx=i+1
rules.insert(idx, rule)
rt["rules"]=rules
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

xray_add_inbound() {
    python3 - "$XRAY_CONF" <<'PY'
import json,sys
path=sys.argv[1]
inbound=json.loads(sys.stdin.read())
conf=json.load(open(path,encoding="utf-8"))
conf.setdefault("inbounds", [])
tag=inbound.get("tag")
conf["inbounds"]=[i for i in conf["inbounds"] if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

xray_remove_inbound() {
    local tag="$1"
    [[ -f "$XRAY_CONF" ]] || return 0
    python3 - "$XRAY_CONF" "$tag" <<'PY'
import json,sys
path,tag=sys.argv[1],sys.argv[2]
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
rt=conf.setdefault("routing", {})
drop_outs=set()
rules=[]
for r in (rt.get("rules") or []):
    tags=list(r.get("inboundTag") or [])
    if tag in tags:
        rest=[t for t in tags if t!=tag]
        ot=r.get("outboundTag") or ""
        if ot.startswith("direct-") and ot!="direct":
            drop_outs.add(ot)
        if rest:
            r=dict(r)
            r["inboundTag"]=rest
            rules.append(r)
        continue
    rules.append(r)
still=set()
for r in rules:
    ot=r.get("outboundTag") or ""
    if ot:
        still.add(ot)
drop_outs={x for x in drop_outs if x not in still}
keep=("direct","block")
conf["outbounds"]=[o for o in (conf.get("outbounds") or []) if o.get("tag") in keep or o.get("tag") not in drop_outs]
rt["rules"]=rules
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
print(len(conf["inbounds"]))
PY
}

xray_remove_relay() {
    local tag="$1" out_tag="${2:-}"
    [[ -f "$XRAY_CONF" ]] || return 0
    python3 - "$XRAY_CONF" "$tag" "$out_tag" <<'PY'
import json,sys
path,tag,out_tag=sys.argv[1],sys.argv[2],sys.argv[3]
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
if out_tag:
    conf["outbounds"]=[o for o in conf.get("outbounds",[]) if o.get("tag")!=out_tag]
rt=conf.setdefault("routing", {})
rules=[]
for r in rt.get("rules") or []:
    tags=r.get("inboundTag") or []
    if tag in tags:
        continue
    rules.append(r)
rt["rules"]=rules
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
print(len(conf.get("inbounds") or []))
PY
}

np_share() {
    python3 - "$@" <<'PY'
# -*- coding: utf-8 -*-
from __future__ import print_function
import base64, json, re, sys
try:
    from urllib.parse import urlparse, parse_qs, quote, unquote, urlencode
except ImportError:
    from urlparse import urlparse, parse_qs
    from urllib import quote, unquote, urlencode

def b64decode(s):
    s = (s or "").strip().replace("-", "+").replace("_", "/")
    s += "=" * ((4 - len(s) % 4) % 4)
    return base64.b64decode(s.encode("utf-8"))

def b64encode_str(s):
    return base64.b64encode(s.encode("utf-8")).decode("ascii")

def hostport(netloc):
    netloc = netloc or ""
    if netloc.startswith("["):
        m = re.match(r"^\[(.+)\]:(\d+)$", netloc)
        if m:
            return m.group(1), int(m.group(2))
        if netloc.startswith("[") and netloc.endswith("]"):
            return netloc[1:-1], None
    if ":" in netloc:
        h, p = netloc.rsplit(":", 1)
        if p.isdigit():
            return h, int(p)
    return netloc, None

def parse_ss(link):
    rest = link.split(":", 1)[1]
    if rest.startswith("//"):
        rest = rest[2:]
    name = ""
    if "#" in rest:
        rest, name = rest.split("#", 1)
        name = unquote(name)
    plugin = ""
    if "/?" in rest or "?" in rest:
        if "/?" in rest:
            rest, q = rest.split("/?", 1)
        else:
            rest, q = rest.split("?", 1)
        qs = parse_qs(q)
        plugin = (qs.get("plugin") or [""])[0]
    userinfo, host, port = "", "", None
    if "@" in rest:
        userinfo, hp = rest.rsplit("@", 1)
        host, port = hostport(hp)
        try:
            dec = b64decode(userinfo).decode("utf-8", "replace")
            if ":" in dec:
                userinfo = dec
        except Exception:
            userinfo = unquote(userinfo)
    else:
        try:
            dec = b64decode(rest).decode("utf-8", "replace")
        except Exception:
            dec = ""
        if "@" in dec:
            return parse_ss("ss://" + dec + (("#" + quote(name)) if name else ""))
        userinfo = dec
    method, password = "", ""
    if ":" in userinfo:
        method, password = userinfo.split(":", 1)
    return {
        "scheme": "ss", "host": host, "port": port, "method": method,
        "password": password, "name": name, "plugin": plugin,
        "user": "", "is_socks": False
    }

def parse_vmess(link):
    raw = link.split("://", 1)[1]
    if "#" in raw:
        raw = raw.split("#", 1)[0]
    obj = json.loads(b64decode(raw).decode("utf-8"))
    port = obj.get("port") or 0
    try:
        port = int(port)
    except Exception:
        port = 0
    return {
        "scheme": "vmess", "host": obj.get("add") or "", "port": port,
        "uuid": obj.get("id") or "", "name": obj.get("ps") or "",
        "obj": obj, "user": "", "password": "", "is_socks": False
    }

def parse_generic(link):
    u = urlparse(link.strip())
    scheme = (u.scheme or "").lower()
    if scheme in ("hy2",):
        scheme = "hysteria2"
    user = unquote(u.username or "")
    password = unquote(u.password or "") if u.password is not None else ""
    host = u.hostname or ""
    port = u.port
    name = unquote(u.fragment or "")
    qs = parse_qs(u.query)
    params = {k: (v[0] if v else "") for k, v in qs.items()}
    is_socks = scheme in ("socks", "socks5", "socks5h", "socks4", "socks4a")
    return {
        "scheme": scheme, "host": host, "port": port, "user": user,
        "password": password, "name": name, "params": params,
        "is_socks": is_socks, "path": u.path or ""
    }

def parse(link):
    link = (link or "").strip().replace("\r", "").replace("\n", "")
    try:
        low = link.lower()
        if low.startswith("vmess://"):
            return parse_vmess(link)
        if low.startswith("ss://"):
            return parse_ss(link)
        return parse_generic(link)
    except Exception:
        return {"scheme": "", "host": "", "port": 0, "user": "", "password": "", "name": "", "is_socks": False}

def fmt_host(host, port):
    h = host or ""
    if ":" in h and not h.startswith("["):
        h = "[%s]" % h
    return "%s:%s" % (h, port)

def rewrite(link, new_host, new_port, new_name):
    info = parse(link)
    scheme = info["scheme"]
    new_port = int(new_port)
    if scheme == "vmess":
        obj = dict(info.get("obj") or {})
        obj["add"] = new_host
        obj["port"] = str(new_port)
        obj["ps"] = new_name
        return "vmess://" + b64encode_str(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
    if scheme == "ss":
        userinfo = "%s:%s" % (info.get("method") or "", info.get("password") or "")
        out = "ss://%s@%s" % (b64encode_str(userinfo).rstrip("="), fmt_host(new_host, new_port))
        if info.get("plugin"):
            out += "/?plugin=" + quote(info["plugin"], safe="")
        return out + "#" + quote(new_name)
    u = urlparse(link.strip().replace("\r", ""))
    auth = u.username or ""
    if u.password is not None:
        auth += ":" + (u.password or "")
    netloc = fmt_host(new_host, new_port)
    if auth:
        netloc = "%s@%s" % (auth, netloc)
    q = u.query
    path = u.path or ""
    if scheme in ("hysteria2", "hy2", "hysteria"):
        if not path:
            path = "/"
    return "%s://%s%s%s%s#%s" % (
        u.scheme, netloc, path,
        ("?" + q) if q else "",
        "",
        quote(new_name)
    )

def qbool(v):
    return str(v).lower() in ("1", "true", "yes", "on")

def clash_from_link(link, name, server, port):
    info = parse(link)
    scheme = info["scheme"]
    port = int(port)
    if scheme == "vmess":
        o = info.get("obj") or {}
        net = o.get("net") or "tcp"
        tls = o.get("tls") or ""
        lines = [
            "  - name: %s" % name,
            "    type: vmess",
            "    server: %s" % server,
            "    port: %s" % port,
            "    uuid: %s" % (o.get("id") or ""),
            "    alterId: %s" % (o.get("aid") or 0),
            "    cipher: %s" % (o.get("scy") or "auto"),
            "    udp: true",
            "    network: %s" % net,
        ]
        if tls:
            lines.append("    tls: true")
            if qbool(o.get("skip-cert-verify") or o.get("allowInsecure")):
                lines.append("    skip-cert-verify: true")
        if o.get("sni"):
            lines.append("    servername: %s" % o.get("sni"))
        if o.get("fp"):
            lines.append("    client-fingerprint: %s" % o.get("fp"))
        if tls == "reality" and o.get("pbk"):
            lines.append("    reality-opts:")
            lines.append("      public-key: %s" % o.get("pbk"))
            lines.append("      short-id: %s" % (o.get("sid") or ""))
        if net == "ws":
            lines.append("    ws-opts:")
            lines.append("      path: %s" % (o.get("path") or "/"))
            if o.get("host"):
                lines.append("      headers:")
                lines.append("        Host: %s" % o.get("host"))
        if net == "grpc":
            lines.append("    grpc-opts:")
            lines.append("      grpc-service-name: %s" % (o.get("path") or ""))
        return "\n".join(lines)
    if scheme == "ss":
        return "\n".join([
            "  - name: %s" % name,
            "    type: ss",
            "    server: %s" % server,
            "    port: %s" % port,
            "    cipher: %s" % (info.get("method") or ""),
            "    password: %s" % (info.get("password") or ""),
            "    udp: true",
        ])
    if scheme in ("hysteria2", "hy2"):
        p = info.get("params") or {}
        lines = [
            "  - name: %s" % name,
            "    type: hysteria2",
            "    server: %s" % server,
            "    port: %s" % port,
            "    password: %s" % (info.get("user") or info.get("password") or ""),
            "    skip-cert-verify: true",
        ]
        sni = p.get("sni") or p.get("peer") or ""
        if sni:
            lines.append("    sni: %s" % sni)
        obfs = p.get("obfs") or ""
        opw = p.get("obfs-password") or p.get("obfsPassword") or ""
        if obfs:
            lines.append("    obfs: %s" % obfs)
            if opw:
                lines.append("    obfs-password: %s" % opw)
        lines.append("    alpn:")
        lines.append("      - h3")
        return "\n".join(lines)
    if scheme == "trojan":
        p = info.get("params") or {}
        net = p.get("type") or "tcp"
        lines = [
            "  - name: %s" % name,
            "    type: trojan",
            "    server: %s" % server,
            "    port: %s" % port,
            "    password: %s" % (info.get("user") or info.get("password") or ""),
            "    udp: true",
            "    sni: %s" % (p.get("sni") or p.get("peer") or server),
            "    skip-cert-verify: %s" % ("true" if qbool(p.get("allowInsecure") or p.get("insecure")) else "false"),
        ]
        if net == "ws":
            lines.append("    network: ws")
            lines.append("    ws-opts:")
            lines.append("      path: %s" % (p.get("path") or "/"))
            if p.get("host"):
                lines.append("      headers:")
                lines.append("        Host: %s" % p.get("host"))
        return "\n".join(lines)
    if scheme == "vless":
        p = info.get("params") or {}
        net = p.get("type") or "tcp"
        sec = p.get("security") or "none"
        uuid = info.get("user") or ""
        lines = [
            "  - name: %s" % name,
            "    type: vless",
            "    server: %s" % server,
            "    port: %s" % port,
            "    uuid: %s" % uuid,
            "    network: %s" % net,
            "    udp: true",
        ]
        flow = p.get("flow") or ""
        if flow:
            lines.append("    flow: %s" % flow)
        if sec in ("tls", "reality"):
            lines.append("    tls: true")
            if p.get("sni"):
                lines.append("    servername: %s" % p.get("sni"))
            if p.get("fp"):
                lines.append("    client-fingerprint: %s" % p.get("fp"))
            if qbool(p.get("allowInsecure") or p.get("insecure")):
                lines.append("    skip-cert-verify: true")
        if sec == "reality":
            lines.append("    reality-opts:")
            lines.append("      public-key: %s" % (p.get("pbk") or ""))
            lines.append("      short-id: %s" % (p.get("sid") or ""))
        if net == "ws":
            lines.append("    ws-opts:")
            lines.append("      path: %s" % (p.get("path") or "/"))
            host = p.get("host") or p.get("sni") or ""
            if host:
                lines.append("      headers:")
                lines.append("        Host: %s" % host)
        if net == "grpc":
            lines.append("    grpc-opts:")
            lines.append("      grpc-service-name: %s" % (p.get("serviceName") or p.get("path") or ""))
        if net == "xhttp":
            lines.append("    xhttp-opts:")
            lines.append("      host: %s" % (p.get("host") or p.get("sni") or ""))
            lines.append("      path: %s" % (p.get("path") or "/"))
            lines.append("      mode: %s" % (p.get("mode") or "auto"))
        return "\n".join(lines)
    return ""

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "info":
    info = parse(sys.argv[2] if len(sys.argv) > 2 else "")
    out = {
        "scheme": info.get("scheme") or "",
        "host": info.get("host") or "",
        "port": info.get("port") or 0,
        "user": info.get("user") or "",
        "password": info.get("password") or "",
        "name": info.get("name") or "",
        "is_socks": bool(info.get("is_socks")),
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
elif cmd == "rewrite":
    sys.stdout.write(rewrite(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]))
elif cmd == "clash":
    sys.stdout.write(clash_from_link(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]))
else:
    sys.exit(2)
PY
}

xray_test_restart() {
    if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/np-xray-test.log 2>&1 \
       && ! "$XRAY_BIN" -test -config "$XRAY_CONF" >/tmp/np-xray-test.log 2>&1; then
        err "Xray 配置校验失败："
        cat /tmp/np-xray-test.log >&2
        return 1
    fi
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; return 1; }
    ok "Xray 已运行"
}

gen_reality_keys() {
    local out priv pub
    out="$("$XRAY_BIN" x25519 2>/dev/null)" || die "生成 Reality 密钥失败"
    priv="$(echo "$out" | awk -F': *' 'tolower($1) ~ /private/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    pub="$(echo "$out" | awk -F': *' 'tolower($1) ~ /public/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    [[ -z "$pub" ]] && pub="$(echo "$out" | awk -F': *' 'tolower($1) ~ /^password/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    [[ -n "$priv" && -n "$pub" ]] || die "解析 Reality 密钥失败: $out"
    REALITY_PRIV="$priv"
    REALITY_PUB="$pub"
}

gen_uuid() {
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" uuid 2>/dev/null && return
    fi
    cat /proc/sys/kernel/random/uuid
}

# ---------------- Hysteria2 ----------------
install_hy2_bin() {
    if [[ -x "$HY2_BIN" ]] || command -v hysteria >/dev/null 2>&1; then
        command -v hysteria >/dev/null 2>&1 && HY2_BIN="$(command -v hysteria)"
        ok "Hysteria2 已安装"
        return 0
    fi
    echo "======== 正在安装 Hysteria2，下方滚动输出属于正常，请等待 ========"
    bash <(curl -fsSL https://get.hy2.sh/) || die "Hysteria2 安装失败"
    if [[ -x /usr/local/bin/hysteria ]]; then
        HY2_BIN=/usr/local/bin/hysteria
    elif command -v hysteria >/dev/null 2>&1; then
        HY2_BIN="$(command -v hysteria)"
    else
        die "Hysteria2 安装后未找到二进制"
    fi
    ok "Hysteria2 安装完成"
}

hy2_restart() {
    systemctl enable hysteria-server.service >/dev/null 2>&1 || true
    systemctl restart hysteria-server.service
    sleep 1
    if systemctl is-active --quiet hysteria-server.service; then
        ok "Hysteria2 已运行"
    else
        journalctl -u hysteria-server -n 40 --no-pager
        die "Hysteria2 启动失败"
    fi
}

hy2_start_tagged() {
    local tag="$1" conf="$2"
    if [[ "$tag" == "hysteria2" ]]; then
        if [[ "$conf" != "$HY2_CONF" ]]; then
            cp -f "$conf" "$HY2_CONF"
        fi
        hy2_restart
        return
    fi
    local unit="np-${tag}.service"
    cat > "/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=NodeProtocol Hysteria2 ${tag}
After=network.target

[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${conf}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit"
    sleep 1
    if systemctl is-active --quiet "$unit"; then
        ok "Hysteria2 ${tag} 已运行"
    else
        journalctl -u "$unit" -n 40 --no-pager
        die "Hysteria2 启动失败"
    fi
}

hy2_stop_tagged() {
    local tag="$1"
    if [[ "$tag" == "hysteria2" ]]; then
        systemctl stop hysteria-server >/dev/null 2>&1 || true
        systemctl disable hysteria-server >/dev/null 2>&1 || true
        rm -f "$HY2_CONF" /etc/hysteria/server.crt /etc/hysteria/server.key
        return
    fi
    local unit="np-${tag}.service"
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}"
    rm -f "/etc/hysteria/${tag}.yaml" "/etc/hysteria/${tag}.crt" "/etc/hysteria/${tag}.key"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

make_selfsigned() {
    local cn="$1" crt="$2" key="$3"
    mkdir -p "$(dirname "$crt")"
    if openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$key" -out "$crt" -subj "/CN=${cn}" \
        -addext "subjectAltName=DNS:${cn}" -days 3650 >/dev/null 2>&1; then
        return 0
    fi
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key" -out "$crt" \
        -subj "/CN=${cn}" -days 3650 >/dev/null 2>&1 || die "生成自签证书失败"
}

# ---------------- 输出 ----------------
print_node() {
    local tag="$1"
    local f="$META_DIR/$tag.json"
    [[ -f "$f" ]] || { warn "没有找到 $tag"; return 1; }

    local proto server port share clash_name
    proto="$(load_meta "$f" protocol)"
    server="$(load_meta "$f" server)"
    port="$(load_meta "$f" port)"
    share="$(build_share "$tag")"
    clash_name="$(load_meta "$f" name)"

    echo
    echo -e "${BOLD}========== ${proto}信息 ==========${NC}"
    echo
    print_qr "$share"
    echo
    if [[ "$tag" == socks5* ]]; then
        echo -e "${GREEN}+--------------------------------------------+${NC}"
        echo -e "${GREEN}| 名称   : ${clash_name}${NC}"
        echo -e "${GREEN}| 服务器 : ${server}${NC}"
        echo -e "${GREEN}| 端口   : ${port}${NC}"
        echo -e "${GREEN}| 用户   : $(load_meta "$f" user)${NC}"
        echo -e "${GREEN}| 密码   : $(load_meta "$f" password)${NC}"
        echo -e "${GREEN}+--------------------------------------------+${NC}"
        echo
    fi
    echo -e "${BOLD}分享链接${NC}"
    echo -e "${GREEN}${share}${NC}"
    echo
    echo -e "${BOLD}Clash Meta 一键导入${NC}"
    mkdir -p "$CLASH_DIR"
    NP_SERVER="$server" write_clash_yaml "$CLASH_DIR/$tag.yaml" "$tag"
    NP_SERVER="$server" print_clash_import "$tag" "$clash_name"
}

write_clash_yaml() {
    local out="$1"
    shift
    python3 - "$out" "$@" <<'PY'
import json, os, sys
out = sys.argv[1]
tags = sys.argv[2:]
items = []
names = []
for tag in tags:
    path = os.path.join("/usr/local/nodeprotocol/meta", tag + ".json")
    m = json.load(open(path, encoding="utf-8"))
    servers = m.get("servers") if isinstance(m.get("servers"), list) else []
    servers = [x for x in servers if x]
    if not servers and m.get("server"):
        servers = [m.get("server")]
    one = os.environ.get("NP_SERVER") or ""
    if one:
        servers = [one]
    if not servers:
        continue
    port = int(m.get("port") or 0)
    base_name = m.get("name", tag)
    kind = m.get("kind") or ""
    if m.get("clash_item") and kind not in ("socks-vless",) and not (
        tag.startswith("vless-xhttp") or tag.startswith("vless-reality")
        or tag.startswith("vmess-reality") or tag.startswith("hysteria2")
        or tag.startswith("ss2022") or tag.startswith("socks5")
    ):
        names.append(base_name)
        items.append(m.get("clash_item"))
        continue
    for server in servers:
        name = base_name if len(servers) == 1 else ("%s-%s" % (base_name, server))
        block = ""
        if tag.startswith("vless-xhttp"):
            block = f"""  - name: {name}
    type: vless
    server: {server}
    port: {port}
    uuid: {m['uuid']}
    network: xhttp
    tls: true
    udp: true
    servername: {m['sni']}
    client-fingerprint: {m['fp']}
    reality-opts:
      public-key: {m['pbk']}
      short-id: {m['sid']}
    xhttp-opts:
      host: {m['sni']}
      path: {m['path']}
      mode: auto"""
        elif tag.startswith("vless-reality") or kind == "socks-vless":
            block = f"""  - name: {name}
    type: vless
    server: {server}
    port: {port}
    uuid: {m['uuid']}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: {m['sni']}
    client-fingerprint: {m['fp']}
    reality-opts:
      public-key: {m['pbk']}
      short-id: {m['sid']}"""
        elif tag.startswith("vmess-reality"):
            block = f"""  - name: {name}
    type: vmess
    server: {server}
    port: {port}
    uuid: {m['uuid']}
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    network: tcp
    servername: {m['sni']}
    client-fingerprint: {m['fp']}
    reality-opts:
      public-key: {m['pbk']}
      short-id: {m['sid']}"""
        elif tag.startswith("hysteria2"):
            block = f"""  - name: {name}
    type: hysteria2
    server: {server}
    port: {port}
    password: {m['password']}
    sni: {m['sni']}
    skip-cert-verify: true
    obfs: salamander
    obfs-password: {m['obfs']}
    alpn:
      - h3"""
        elif tag.startswith("ss2022"):
            block = f"""  - name: {name}
    type: ss
    server: {server}
    port: {port}
    cipher: {m['method']}
    password: {m['password']}
    udp: true"""
        elif tag.startswith("socks5"):
            block = f"""  - name: {name}
    type: socks5
    server: {server}
    port: {port}
    username: {m['user']}
    password: {m['password']}
    udp: true"""
        else:
            continue
        items.append(block)
        names.append(name)
proxy_list = "\n".join("      - %s" % n for n in names)
body = """mixed-port: 7890
allow-lan: false
bind-address: '*'
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: strict

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  default-nameserver:
    - 8.8.8.8
    - 1.1.1.1
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback:
    - https://dns.google/dns-query
    - tls://1.1.1.1:853
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - localhost
    - time.*.com
    - ntp.*.com
    - '+.market.xiaomi.com'

tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - any:53
    - tcp://any:53

proxies:
""" + "\n".join(items) + """
proxy-groups:
  - name: PROXY
    type: select
    proxies:
""" + proxy_list + """
rules:
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  - MATCH,PROXY
"""
open(out, "w", encoding="utf-8").write(body)
PY
}

ensure_clash_sub() {
    mkdir -p "$CLASH_DIR" "$NODE_HOME"
    local subj="$NODE_HOME/sub.json" py="$NODE_HOME/clash_sub.py" port token
    if [[ -f "$subj" ]]; then
        port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("port",""))' "$subj" 2>/dev/null || true)"
        token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("token",""))' "$subj" 2>/dev/null || true)"
    fi
    if [[ -z "$port" || -z "$token" ]]; then
        port="$(rand_port)"
        token="$(rand_alnum 20)"
        python3 - "$subj" "$port" "$token" <<'PY'
import json,sys
json.dump({"port": sys.argv[2], "token": sys.argv[3]}, open(sys.argv[1],"w",encoding="utf-8"))
PY
    fi
    cat > "$py" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, os, re
CONF = "/usr/local/nodeprotocol/sub.json"
DIR = "/usr/local/nodeprotocol/clash"

class H(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        try:
            c = json.load(open(CONF, encoding="utf-8"))
        except Exception:
            self.send_error(500)
            return
        token = str(c.get("token") or "")
        path = self.path.split("?", 1)[0].strip("/")
        parts = [p for p in path.split("/") if p]
        if not token or not parts or parts[0] != token:
            self.send_error(404)
            return
        name = "all.yaml"
        if len(parts) >= 2:
            name = parts[1]
            if not name.endswith(".yaml"):
                name += ".yaml"
        if not re.match(r"^[\w.-]+$", name):
            self.send_error(404)
            return
        fp = os.path.join(DIR, name)
        if not os.path.isfile(fp):
            self.send_error(404)
            return
        data = open(fp, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

if __name__ == "__main__":
    c = json.load(open(CONF, encoding="utf-8"))
    HTTPServer(("0.0.0.0", int(c["port"])), H).serve_forever()
PY
    chmod +x "$py"
    local pybin
    pybin="$(command -v python3)"
    cat > /etc/systemd/system/np-clash-sub.service <<EOF
[Unit]
Description=NodeProtocol Clash subscription
After=network.target
[Service]
Type=simple
ExecStart=${pybin} ${py}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable np-clash-sub >/dev/null 2>&1 || true
    systemctl restart np-clash-sub >/dev/null 2>&1 || true
    open_firewall "$port" tcp
    if systemctl is-active --quiet np-clash-sub; then
        return 0
    fi
    return 1
}

print_clash_import() {
    local file_tag="$1" disp_name="${2:-$1}"
    local subj="$NODE_HOME/sub.json" ip port token url click
    if ! ensure_clash_sub; then
        echo -e "配置文件: ${CLASH_DIR}/${file_tag}.yaml"
        warn "订阅服务未启动，请把该文件复制到 Clash Meta 导入"
        return 0
    fi
    ip="${NP_SERVER:-$(get_public_ip)}"
    port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["port"])' "$subj")"
    token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["token"])' "$subj")"
    url="http://${ip}:${port}/${token}/${file_tag}.yaml"
    click="clash://install-config?url=$(urlenc "$url")&name=$(urlenc "$disp_name")"
    echo "Clash Meta / Clash Verge：新建配置 → 从 URL 导入，粘贴下面链接"
    echo -e "${GREEN}${url}${NC}"
    echo "或把下面整段粘贴到浏览器 / Clash 导入："
    echo -e "${GREEN}${click}${NC}"
    echo "若打不开，请在云安全组放行 TCP ${port}"
}

print_clash_import_all() {
    local subj="$NODE_HOME/sub.json" ip port token url click
    if ! ensure_clash_sub; then
        echo -e "配置文件: ${CLASH_DIR}/all.yaml"
        warn "订阅服务未启动，请把该文件复制到 Clash Meta 导入"
        return 0
    fi
    ip="$(get_public_ip)"
    port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["port"])' "$subj")"
    token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["token"])' "$subj")"
    url="http://${ip}:${port}/${token}/all.yaml"
    click="clash://install-config?url=$(urlenc "$url")&name=$(urlenc "NP-All")"
    echo
    echo -e "${CYAN}+--------------------------------------------+${NC}"
    echo -e "${CYAN}| Clash Meta 全部节点一键导入${NC}"
    echo -e "${CYAN}|${NC}"
    echo -e "${CYAN}| 从 URL 导入，粘贴下面链接${NC}"
    echo -e "${CYAN}| ${GREEN}${url}${NC}"
    echo -e "${CYAN}| 或粘贴到浏览器 / Clash：${NC}"
    echo -e "${CYAN}| ${GREEN}${click}${NC}"
    echo -e "${CYAN}| 若打不开，请在云安全组放行 TCP ${port}${NC}"
    echo -e "${CYAN}+--------------------------------------------+${NC}"
    echo
}

build_share() {
    local tag="$1" f="$META_DIR/$tag.json"
    local server port uuid sni pbk sid fp path flow name password method user
    server="$(load_meta "$f" server)"; port="$(load_meta "$f" port)"
    [[ -n "${NP_SERVER:-}" ]] && server="$NP_SERVER"
    name="$(load_meta "$f" name)"
    case "$tag" in
        vless-xhttp*)
            uuid="$(load_meta "$f" uuid)"; sni="$(load_meta "$f" sni)"
            pbk="$(load_meta "$f" pbk)"; sid="$(load_meta "$f" sid)"; fp="$(load_meta "$f" fp)"
            path="$(load_meta "$f" path)"
            local spx; spx="$(load_meta "$f" spx)"
            echo "vless://${uuid}@${server}:${port}?encryption=none&security=reality&sni=$(urlenc "$sni")&fp=${fp}&pbk=$(urlenc "$pbk")&sid=${sid}&type=xhttp&path=$(urlenc "$path")&host=$(urlenc "$sni")&mode=auto&spx=$(urlenc "${spx:-/}")#$(urlenc "$name")"
            ;;
        vless-reality*)
            uuid="$(load_meta "$f" uuid)"; sni="$(load_meta "$f" sni)"
            pbk="$(load_meta "$f" pbk)"; sid="$(load_meta "$f" sid)"; fp="$(load_meta "$f" fp)"
            local spx; spx="$(load_meta "$f" spx)"
            echo "vless://${uuid}@${server}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlenc "$sni")&fp=${fp}&pbk=$(urlenc "$pbk")&sid=${sid}&type=tcp&headerType=none&spx=$(urlenc "${spx:-/}")#$(urlenc "$name")"
            ;;
        hysteria2*)
            password="$(load_meta "$f" password)"; sni="$(load_meta "$f" sni)"
            local obfs; obfs="$(load_meta "$f" obfs)"
            echo "hysteria2://${password}@${server}:${port}/?insecure=1&sni=$(urlenc "$sni")&obfs=salamander&obfs-password=$(urlenc "$obfs")#$(urlenc "$name")"
            ;;
        vmess-reality*)
            uuid="$(load_meta "$f" uuid)"; sni="$(load_meta "$f" sni)"
            pbk="$(load_meta "$f" pbk)"; sid="$(load_meta "$f" sid)"; fp="$(load_meta "$f" fp)"
            PYTHONIOENCODING=utf-8 python3 - "$uuid" "$server" "$port" "$name" "$sni" "$fp" "$pbk" "$sid" <<'PY'
import json,base64,sys
uuid,server,port,name,sni,fp,pbk,sid=sys.argv[1:9]
obj={
  "v":"2","ps":name,"add":server,"port":str(port),"id":uuid,
  "aid":"0","scy":"auto","net":"tcp","type":"none","host":sni,
  "path":"","tls":"reality","sni":sni,"fp":fp,"pbk":pbk,"sid":sid
}
sys.stdout.buffer.write(("vmess://"+base64.b64encode(json.dumps(obj,separators=(",",":"),ensure_ascii=False).encode("utf-8")).decode("ascii")+"\n").encode("utf-8"))
PY
            ;;
        ss2022*)
            method="$(load_meta "$f" method)"; password="$(load_meta "$f" password)"
            echo "ss://$(b64 "${method}:${password}")@${server}:${port}#$(urlenc "$name")"
            ;;
        socks5*)
            user="$(load_meta "$f" user)"; password="$(load_meta "$f" password)"
            echo "socks5://${user}:${password}@${server}:${port}#$(urlenc "$name")"
            ;;
        *)
            local kind
            kind="$(load_meta "$f" kind)"
            if [[ "$kind" == "socks-vless" ]]; then
                uuid="$(load_meta "$f" uuid)"; sni="$(load_meta "$f" sni)"
                pbk="$(load_meta "$f" pbk)"; sid="$(load_meta "$f" sid)"; fp="$(load_meta "$f" fp)"
                local spx; spx="$(load_meta "$f" spx)"
                echo "vless://${uuid}@${server}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(urlenc "$sni")&fp=${fp}&pbk=$(urlenc "$pbk")&sid=${sid}&type=tcp&headerType=none&spx=$(urlenc "${spx:-/}")#$(urlenc "$name")"
            elif [[ "$kind" == "dokodemo" ]]; then
                load_meta "$f" client_share | tr -d '\n'
                echo
            fi
            ;;
    esac
}

build_clash_item() {
    local tag="$1" f="$META_DIR/$tag.json"
    python3 - "$f" "$tag" <<'PY'
import json,sys
m=json.load(open(sys.argv[1],encoding="utf-8"))
tag=sys.argv[2]
name=m.get("name","node")
server=m.get("server"); port=int(m.get("port"))
if tag.startswith("vless-xhttp"):
    print(f"- name: {name}")
    print(f"  type: vless")
    print(f"  server: {server}")
    print(f"  port: {port}")
    print(f"  uuid: {m['uuid']}")
    print(f"  network: xhttp")
    print(f"  tls: true")
    print(f"  udp: true")
    print(f"  servername: {m['sni']}")
    print(f"  client-fingerprint: {m['fp']}")
    print(f"  reality-opts:")
    print(f"    public-key: {m['pbk']}")
    print(f"    short-id: {m['sid']}")
    print(f"  xhttp-opts:")
    print(f"    host: {m['sni']}")
    print(f"    path: {m['path']}")
    print(f"    mode: auto")
elif tag.startswith("vless-reality"):
    print(f"- name: {name}")
    print(f"  type: vless")
    print(f"  server: {server}")
    print(f"  port: {port}")
    print(f"  uuid: {m['uuid']}")
    print(f"  network: tcp")
    print(f"  tls: true")
    print(f"  udp: true")
    print(f"  flow: xtls-rprx-vision")
    print(f"  servername: {m['sni']}")
    print(f"  client-fingerprint: {m['fp']}")
    print(f"  reality-opts:")
    print(f"    public-key: {m['pbk']}")
    print(f"    short-id: {m['sid']}")
elif tag.startswith("vmess-reality"):
    print(f"- name: {name}")
    print(f"  type: vmess")
    print(f"  server: {server}")
    print(f"  port: {port}")
    print(f"  uuid: {m['uuid']}")
    print(f"  alterId: 0")
    print(f"  cipher: auto")
    print(f"  udp: true")
    print(f"  tls: true")
    print(f"  network: tcp")
    print(f"  servername: {m['sni']}")
    print(f"  client-fingerprint: {m['fp']}")
    print(f"  reality-opts:")
    print(f"    public-key: {m['pbk']}")
    print(f"    short-id: {m['sid']}")
elif tag.startswith("hysteria2"):
    print(f"- name: {name}")
    print(f"  type: hysteria2")
    print(f"  server: {server}")
    print(f"  port: {port}")
    print(f"  password: {m['password']}")
    print(f"  sni: {m['sni']}")
    print(f"  skip-cert-verify: true")
    print(f"  obfs: salamander")
    print(f"  obfs-password: {m['obfs']}")
    print(f"  alpn:")
    print(f"    - h3")
elif tag.startswith("ss2022"):
    print(f"- name: {name}")
    print(f"  type: ss")
    print(f"  server: {server}")
    print(f"  port: {port}")
    print(f"  cipher: {m['method']}")
    print(f"  password: {m['password']}")
    print(f"  udp: true")
elif tag.startswith("socks5"):
    print(f"- name: {name}")
    print(f"  type: socks5")
    print(f"  server: {server}")
    print(f"  port: {port}")
    print(f"  username: {m['user']}")
    print(f"  password: {m['password']}")
    print(f"  udp: true")
PY
}

list_installed_tags() {
    local t f
    shopt -s nullglob
    for t in vless-reality vless-xhttp hysteria2 ss2022 socks5 vmess-reality; do
        meta_exists "$t" && echo "$t"
        for f in "$META_DIR"/${t}-*.json; do
            [[ -f "$f" ]] && basename "$f" .json
        done
    done
    for f in "$META_DIR"/relay-*.json; do
        [[ -f "$f" ]] || continue
        basename "$f" .json
    done
}

prepare_common() {
    persist_self
    install_deps
    enable_bbr
    enable_net_tune
}

install_vless_reality() {
    local mode dest_in dest sni fp spx ip tag port uuid sid listen name
    local done_tags=() first=1
    choose_install_ips || return 1
    filter_install_ips vless-reality || return 1
    mode="$(choose_mode)"
    prepare_common || return 1
    install_xray
    ensure_xray_base

    dest_in=""
    [[ "$mode" == "custom" ]] && dest_in="$(ask "伪装域名（留空则随机）" "")"
    dest="$(pick_random_host "$dest_in")"
    sni="$dest"
    [[ "$mode" == "custom" ]] && sni="$(ask "SNI / serverName" "$sni")"
    [[ -n "$dest" && -n "$sni" ]] || { err "伪装域名不能为空"; return 1; }
    fp="$(rand_fp)"
    [[ "$mode" == "custom" ]] && fp="$(ask "客户端指纹 chrome/firefox/safari/ios/edge" "$fp")"
    spx="$(rand_path)"

    for ip in "${INSTALL_IPS[@]}"; do
        tag="$(np_proto_tag vless-reality "$ip")"
        listen="$(np_listen_addr "$ip")"
        if [[ "$first" == 1 ]]; then
            port="$(choose_tcp_port "443" "$mode")"
            first=0
        else
            port="$(choose_tcp_port "" auto)"
        fi
        uuid="$(gen_uuid)"
        sid="$(rand_hex 8)"
        gen_reality_keys
        info "写入 Xray inbound（${ip}:${port}）..."
        python3 - "$XRAY_CONF" "$tag" "$listen" "$port" "$uuid" "$dest" "$sni" "$REALITY_PRIV" "$sid" <<'PY'
import json,sys
path,tag,listen=sys.argv[1],sys.argv[2],sys.argv[3]
port=int(sys.argv[4]); uuid=sys.argv[5]; dest=sys.argv[6]; sni=sys.argv[7]
priv=sys.argv[8]; sid=sys.argv[9]
inbound={
  "tag": tag,
  "listen": listen,
  "port": port,
  "protocol": "vless",
  "settings": {
    "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": False,
      "dest": dest+":443",
      "target": dest+":443",
      "xver": 0,
      "serverNames": [sni],
      "privateKey": priv,
      "shortIds": [sid]
    },
    "sockopt": {
      "tcpNoDelay": True,
      "tcpKeepAliveIdle": 15
    }
  },
  "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        xray_bind_inbound_ip "${tag:-}" "${ip:-}"
        xray_test_restart || die "Xray 启动失败"
        open_firewall "$port" tcp
        name="NP-Reality-${port}"
        save_meta "$tag" <<EOF
{
  "tag": "$tag",
  "protocol": "VLESS + TCP + Reality + Vision",
  "name": "$name",
  "server": "$ip",
  "port": "$port",
  "uuid": "$uuid",
  "sni": "$sni",
  "dest": "${dest}:443",
  "pbk": "$REALITY_PUB",
  "sid": "$sid",
  "fp": "$fp",
  "spx": "$spx",
  "priv": "$REALITY_PRIV"
}
EOF
        ok "安装完成 ${ip}:${port}  伪装站 ${dest}  SNI=${sni}"
        done_tags+=("$tag")
    done
    print_nodes_with_sep "${done_tags[@]}"
    run_speedtest
}

install_vless_xhttp() {
    local mode dest_in dest sni fp path spx ip tag port uuid sid listen name pref
    local done_tags=() first=1
    choose_install_ips || return 1
    filter_install_ips vless-xhttp || return 1
    mode="$(choose_mode)"
    prepare_common || return 1
    install_xray
    ensure_xray_base

    dest_in=""
    [[ "$mode" == "custom" ]] && dest_in="$(ask "伪装域名（留空则随机）" "")"
    dest="$(pick_random_host "$dest_in")"
    sni="$dest"
    [[ -n "$dest" && -n "$sni" ]] || { err "伪装域名不能为空"; return 1; }
    [[ "$mode" == "custom" ]] && sni="$(ask "SNI / serverName" "$sni")"
    fp="$(rand_fp)"
    [[ "$mode" == "custom" ]] && fp="$(ask "客户端指纹" "$fp")"
    path="$(rand_path)"
    [[ "$mode" == "custom" ]] && path="$(ask "XHTTP path" "$path")"
    [[ "$path" == /* ]] || path="/$path"
    spx="$(rand_path)"

    pref=""
    if ! meta_exists vless-reality; then
        local _f _any=0
        shopt -s nullglob
        for _f in "$META_DIR"/vless-reality-*.json; do
            [[ -f "$_f" ]] && _any=1 && break
        done
        [[ "$_any" == 0 ]] && pref="443"
    fi

    for ip in "${INSTALL_IPS[@]}"; do
        tag="$(np_proto_tag vless-xhttp "$ip")"
        listen="$(np_listen_addr "$ip")"
        if [[ "$first" == 1 ]]; then
            port="$(choose_tcp_port "$pref" "$mode")"
            first=0
        else
            port="$(choose_tcp_port "" auto)"
        fi
        uuid="$(gen_uuid)"
        sid="$(rand_hex 8)"
        gen_reality_keys
        info "写入 Xray inbound（${ip}:${port}）..."
        python3 - "$XRAY_CONF" "$tag" "$listen" "$port" "$uuid" "$dest" "$sni" "$REALITY_PRIV" "$sid" "$path" <<'PY'
import json,sys
path,tag,listen=sys.argv[1],sys.argv[2],sys.argv[3]
port=int(sys.argv[4]); uuid=sys.argv[5]; dest=sys.argv[6]; sni=sys.argv[7]
priv=sys.argv[8]; sid=sys.argv[9]; xpath=sys.argv[10]
inbound={
  "tag": tag,
  "listen": listen,
  "port": port,
  "protocol": "vless",
  "settings": {
    "clients": [{"id": uuid}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "show": False,
      "dest": dest+":443",
      "target": dest+":443",
      "xver": 0,
      "serverNames": [sni],
      "privateKey": priv,
      "shortIds": [sid]
    },
    "xhttpSettings": {
      "path": xpath,
      "host": sni,
      "mode": "auto"
    }
  },
  "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        xray_bind_inbound_ip "${tag:-}" "${ip:-}"
        xray_test_restart || die "Xray 启动失败"
        open_firewall "$port" tcp
        name="NP-XHTTP-${port}"
        save_meta "$tag" <<EOF
{
  "tag": "$tag",
  "protocol": "VLESS + XHTTP + Reality",
  "name": "$name",
  "server": "$ip",
  "port": "$port",
  "uuid": "$uuid",
  "sni": "$sni",
  "dest": "${dest}:443",
  "pbk": "$REALITY_PUB",
  "sid": "$sid",
  "fp": "$fp",
  "path": "$path",
  "spx": "$spx",
  "priv": "$REALITY_PRIV"
}
EOF
        ok "安装完成 ${ip}:${port}  伪装站 ${dest}  SNI=${sni}  path=${path}"
        done_tags+=("$tag")
    done
    print_nodes_with_sep "${done_tags[@]}"
    run_speedtest
}

install_hysteria2() {
    local mode masq_in masq ip tag port password obfs name bw conf crt key listen
    local done_tags=() first=1
    choose_install_ips || return 1
    filter_install_ips hysteria2 || return 1
    mode="$(choose_mode)"
    prepare_common || return 1
    install_hy2_bin

    masq_in=""
    [[ "$mode" == "custom" ]] && masq_in="$(ask "伪装站点（留空则随机）" "")"
    masq="$(pick_random_host "$masq_in")"
    [[ -n "$masq" ]] || { err "伪装站点不能为空"; return 1; }
    [[ "$mode" == "custom" ]] && masq="$(ask "伪装 / SNI 域名" "$masq")"
    bw="$(detect_hy2_bandwidth)"

    for ip in "${INSTALL_IPS[@]}"; do
        tag="$(np_proto_tag hysteria2 "$ip")"
        listen="$(np_listen_addr "$ip")"
        if [[ "$first" == 1 ]]; then
            port="$(choose_udp_port "443" "$mode")"
            first=0
        else
            port="$(choose_udp_port "" auto)"
        fi
        password="$(rand_alnum 24)"
        obfs="$(rand_alnum 20)"
        mkdir -p /etc/hysteria
        if [[ "$tag" == "hysteria2" ]]; then
            conf="$HY2_CONF"
            crt="/etc/hysteria/server.crt"
            key="/etc/hysteria/server.key"
        else
            conf="/etc/hysteria/${tag}.yaml"
            crt="/etc/hysteria/${tag}.crt"
            key="/etc/hysteria/${tag}.key"
        fi
        make_selfsigned "$masq" "$crt" "$key"
        if id hysteria >/dev/null 2>&1; then
            chown hysteria:hysteria "$crt" "$key" 2>/dev/null || true
        fi
        chmod 600 "$key"
        cat > "$conf" <<EOF
listen: ${listen}:${port}

tls:
  cert: ${crt}
  key: ${key}
  sniGuard: disable

auth:
  type: password
  password: ${password}

obfs:
  type: salamander
  salamander:
    password: ${obfs}

masquerade:
  type: proxy
  proxy:
    url: https://${masq}/
    rewriteHost: true
    insecure: true

bandwidth:
  up: ${bw}
  down: ${bw}

ignoreClientBandwidth: true
EOF
        if [[ "$listen" != "0.0.0.0" ]]; then
            cat >> "$conf" <<EOF

outbounds:
  - name: default
    type: direct
    direct:
      mode: auto
      bindIPv4: ${ip}
EOF
        fi
        if id hysteria >/dev/null 2>&1; then
            chown hysteria:hysteria "$conf" "$crt" "$key" 2>/dev/null || true
        fi
        hy2_start_tagged "$tag" "$conf"
        open_firewall "$port" udp
        name="NP-Hy2-${port}"
        save_meta "$tag" <<EOF
{
  "tag": "$tag",
  "protocol": "Hysteria2",
  "name": "$name",
  "server": "$ip",
  "port": "$port",
  "password": "$password",
  "sni": "$masq",
  "masq": "https://${masq}/",
  "obfs": "$obfs"
}
EOF
        ok "安装完成 ${ip}:${port}  伪装 ${masq}，UDP ${port}，带宽 ${bw}"
        done_tags+=("$tag")
    done
    print_nodes_with_sep "${done_tags[@]}"
    run_speedtest
}

install_ss2022() {
    local mode method password ip tag port listen name
    local done_tags=() first=1
    choose_install_ips || return 1
    filter_install_ips ss2022 || return 1
    mode="$(choose_mode)"
    prepare_common || return 1
    install_xray
    ensure_xray_base
    method="2022-blake3-aes-128-gcm"
    if [[ "$mode" == "custom" ]]; then
        method="$(ask "加密（2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm）" "$method")"
    fi

    for ip in "${INSTALL_IPS[@]}"; do
        tag="$(np_proto_tag ss2022 "$ip")"
        listen="$(np_listen_addr "$ip")"
        if [[ "$method" == *256* ]]; then
            password="$(openssl rand -base64 32 | tr -d '\n')"
        else
            password="$(openssl rand -base64 16 | tr -d '\n')"
        fi
        if [[ "$first" == 1 ]]; then
            port="$(choose_tcp_port "" "$mode")"
            first=0
        else
            port="$(choose_tcp_port "" auto)"
        fi
        info "写入 Xray inbound（${ip}:${port}）..."
        python3 - "$XRAY_CONF" "$tag" "$listen" "$port" "$method" "$password" <<'PY'
import json,sys
path,tag,listen=sys.argv[1],sys.argv[2],sys.argv[3]
port=int(sys.argv[4]); method=sys.argv[5]; password=sys.argv[6]
inbound={
  "tag": tag,
  "listen": listen,
  "port": port,
  "protocol": "shadowsocks",
  "settings": {
    "method": method,
    "password": password,
    "network": "tcp,udp"
  },
  "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        xray_bind_inbound_ip "${tag:-}" "${ip:-}"
        xray_test_restart || die "Xray 启动失败"
        open_firewall "$port" tcp
        open_firewall "$port" udp
        name="NP-SS2022-${port}"
        save_meta "$tag" <<EOF
{
  "tag": "$tag",
  "protocol": "Shadowsocks 2022",
  "name": "$name",
  "server": "$ip",
  "port": "$port",
  "method": "$method",
  "password": "$password"
}
EOF
        ok "安装完成 ${ip}:${port}"
        done_tags+=("$tag")
    done
    print_nodes_with_sep "${done_tags[@]}"
    run_speedtest
}

install_socks5() {
    local mode ip tag port user password listen name
    local done_tags=() first=1
    choose_install_ips || return 1
    filter_install_ips socks5 || return 1
    mode="$(choose_mode)"
    prepare_common || return 1
    install_xray
    ensure_xray_base

    for ip in "${INSTALL_IPS[@]}"; do
        tag="$(np_proto_tag socks5 "$ip")"
        listen="$(np_listen_addr "$ip")"
        if [[ "$first" == 1 ]]; then
            port="$(choose_tcp_port "" "$mode")"
            first=0
        else
            port="$(choose_tcp_port "" auto)"
        fi
        user="np$(rand_alnum 8)"
        password="$(rand_alnum 16)"
        if [[ "$mode" == "custom" && ${#done_tags[@]} -eq 0 ]]; then
            user="$(ask "用户名" "$user")"
            password="$(ask "密码" "$password")"
        fi
        info "写入 Xray inbound（${ip}:${port}）..."
        python3 - "$XRAY_CONF" "$tag" "$listen" "$port" "$user" "$password" <<'PY'
import json,sys
path,tag,listen=sys.argv[1],sys.argv[2],sys.argv[3]
port=int(sys.argv[4]); user=sys.argv[5]; password=sys.argv[6]
inbound={
  "tag": tag,
  "listen": listen,
  "port": port,
  "protocol": "socks",
  "settings": {
    "auth": "password",
    "accounts": [{"user": user, "pass": password}],
    "udp": True
  },
  "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        xray_bind_inbound_ip "${tag:-}" "${ip:-}"
        xray_test_restart || die "Xray 启动失败"
        open_firewall "$port" tcp
        open_firewall "$port" udp
        name="NP-SOCKS5-${port}"
        save_meta "$tag" <<EOF
{
  "tag": "$tag",
  "protocol": "SOCKS5",
  "name": "$name",
  "server": "$ip",
  "port": "$port",
  "user": "$user",
  "password": "$password"
}
EOF
        ok "安装完成 ${ip}:${port}"
        done_tags+=("$tag")
    done
    print_nodes_with_sep "${done_tags[@]}"
    run_speedtest
}

install_vmess_reality() {
    local mode dest_in dest sni fp ip tag port uuid sid listen name
    local done_tags=() first=1
    choose_install_ips || return 1
    filter_install_ips vmess-reality || return 1
    mode="$(choose_mode)"
    prepare_common || return 1
    install_xray
    ensure_xray_base

    dest_in=""
    [[ "$mode" == "custom" ]] && dest_in="$(ask "伪装域名（留空则随机）" "")"
    dest="$(pick_random_host "$dest_in")"
    sni="$dest"
    [[ -n "$dest" && -n "$sni" ]] || { err "伪装域名不能为空"; return 1; }
    [[ "$mode" == "custom" ]] && sni="$(ask "SNI / serverName" "$sni")"
    fp="$(rand_fp)"
    [[ "$mode" == "custom" ]] && fp="$(ask "客户端指纹 chrome/firefox/safari/ios/edge" "$fp")"

    for ip in "${INSTALL_IPS[@]}"; do
        tag="$(np_proto_tag vmess-reality "$ip")"
        listen="$(np_listen_addr "$ip")"
        if [[ "$first" == 1 ]]; then
            port="$(choose_tcp_port "" "$mode")"
            first=0
        else
            port="$(choose_tcp_port "" auto)"
        fi
        uuid="$(gen_uuid)"
        sid="$(rand_hex 8)"
        gen_reality_keys
        info "写入 Xray inbound（${ip}:${port}）..."
        python3 - "$XRAY_CONF" "$tag" "$listen" "$port" "$uuid" "$dest" "$sni" "$REALITY_PRIV" "$sid" <<'PY'
import json,sys
path,tag,listen=sys.argv[1],sys.argv[2],sys.argv[3]
port=int(sys.argv[4]); uuid=sys.argv[5]; dest=sys.argv[6]; sni=sys.argv[7]
priv=sys.argv[8]; sid=sys.argv[9]
inbound={
  "tag": tag,
  "listen": listen,
  "port": port,
  "protocol": "vmess",
  "settings": {
    "clients": [{"id": uuid, "alterId": 0, "security": "auto"}],
    "disableInsecureEncryption": True
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": False,
      "dest": dest+":443",
      "target": dest+":443",
      "xver": 0,
      "serverNames": [sni],
      "privateKey": priv,
      "shortIds": [sid]
    }
  },
  "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        xray_bind_inbound_ip "${tag:-}" "${ip:-}"
        xray_test_restart || die "Xray 启动失败"
        open_firewall "$port" tcp
        name="NP-VMess-${port}"
        save_meta "$tag" <<EOF
{
  "tag": "$tag",
  "protocol": "VMess + TCP + Reality",
  "name": "$name",
  "server": "$ip",
  "port": "$port",
  "uuid": "$uuid",
  "sni": "$sni",
  "dest": "${dest}:443",
  "pbk": "$REALITY_PUB",
  "sid": "$sid",
  "fp": "$fp",
  "priv": "$REALITY_PRIV"
}
EOF
        ok "安装完成 ${ip}:${port}  伪装站 ${dest}  SNI=${sni}"
        done_tags+=("$tag")
    done
    print_nodes_with_sep "${done_tags[@]}"
    run_speedtest
}

install_relay() {
    echo
    echo -e "${BOLD}添加中转${NC}"
    echo "粘贴落地节点分享链接（任意来源均可）"
    echo "SOCKS 会转成 VLESS + Reality，其他协议走任意门转发"
    local link
    read -rp "节点链接: " link
    link="$(printf '%s' "$link" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$link" ]] || { warn "链接为空"; return 1; }

    local info rhost rport is_socks ruser rpass scheme
    info="$(np_share info "$link")" || { err "无法解析链接"; return 1; }
    scheme="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("scheme") or "")')"
    rhost="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("host") or "")')"
    rport="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("port") or 0)')"
    is_socks="$(printf '%s' "$info" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("is_socks") else "0")')"
    ruser="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("user") or "")')"
    rpass="$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("password") or "")')"
    [[ -n "$rhost" && "$rport" =~ ^[1-9][0-9]*$ ]] || { err "链接里没有有效的服务器地址/端口"; return 1; }

    prepare_common || return 1
    install_xray
    ensure_xray_base

    local tag port server name dest sni uuid sid fp spx out_tag
    tag="relay-$(rand_hex 6)"
    while meta_exists "$tag"; do tag="relay-$(rand_hex 6)"; done
    port="$(choose_tcp_port "" auto)"
    server="$(get_public_ip)"
    name="NP-Relay-${port}"

    if [[ "$is_socks" == "1" ]]; then
        dest="$(pick_random_host "")"
        sni="$dest"
        [[ -n "$dest" ]] || { err "伪装域名不能为空"; return 1; }
        uuid="$(gen_uuid)"
        sid="$(rand_hex 8)"
        fp="$(rand_fp)"
        spx="$(rand_path)"
        gen_reality_keys
        out_tag="${tag}-out"
        python3 - "$XRAY_CONF" "$tag" "$out_tag" "$port" "$uuid" "$dest" "$sni" "$REALITY_PRIV" "$sid" "$rhost" "$rport" "$ruser" "$rpass" <<'PY'
import json,sys
path,tag,out_tag=sys.argv[1],sys.argv[2],sys.argv[3]
listen_port=int(sys.argv[4]); uuid=sys.argv[5]; dest=sys.argv[6]; sni=sys.argv[7]
priv=sys.argv[8]; sid=sys.argv[9]; rhost=sys.argv[10]; rport=int(sys.argv[11])
ruser,rpass=sys.argv[12],sys.argv[13]
inbound={
  "tag": tag, "listen": "0.0.0.0", "port": listen_port, "protocol": "vless",
  "settings": {"clients": [{"id": uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"},
  "streamSettings": {
    "network": "tcp", "security": "reality",
    "realitySettings": {
      "show": False, "dest": dest+":443", "target": dest+":443", "xver": 0,
      "serverNames": [sni], "privateKey": priv, "shortIds": [sid]
    }
  },
  "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}
}
server={"address": rhost, "port": rport}
if ruser:
    server["users"]=[{"user": ruser, "pass": rpass}]
outbound={"tag": out_tag, "protocol": "socks", "settings": {"servers": [server]}}
rule={"type": "field", "inboundTag": [tag], "outboundTag": out_tag}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
conf["outbounds"]=[o for o in conf.get("outbounds",[]) if o.get("tag")!=out_tag]
conf["outbounds"].append(outbound)
rt=conf.setdefault("routing", {})
rules=[r for r in (rt.get("rules") or []) if tag not in (r.get("inboundTag") or [])]
rules.insert(0, rule)
rt["rules"]=rules
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        xray_test_restart || die "Xray 启动失败"
        open_firewall "$port" tcp
        save_meta "$tag" <<EOF
{
  "tag": "$tag",
  "kind": "socks-vless",
  "protocol": "中转（SOCKS5→VLESS Reality）",
  "name": "$name",
  "server": "$server",
  "port": "$port",
  "uuid": "$uuid",
  "sni": "$sni",
  "dest": "${dest}:443",
  "pbk": "$REALITY_PUB",
  "sid": "$sid",
  "fp": "$fp",
  "spx": "$spx",
  "priv": "$REALITY_PRIV",
  "out_tag": "$out_tag",
  "dest_addr": "$rhost",
  "dest_port": "$rport"
}
EOF
        ok "已添加中转。SOCKS5 已转为 VLESS + Reality，落地 ${rhost}:${rport}"
    else
        python3 - "$XRAY_CONF" "$tag" "$port" "$rhost" "$rport" <<'PY'
import json,sys
path,tag=sys.argv[1],sys.argv[2]
listen_port=int(sys.argv[3]); rhost=sys.argv[4]; rport=int(sys.argv[5])
inbound={
  "tag": tag, "listen": "0.0.0.0", "port": listen_port,
  "protocol": "dokodemo-door",
  "settings": {
    "address": rhost, "port": rport, "network": "tcp,udp",
    "rewriteAddress": rhost, "rewritePort": rport,
    "allowedNetwork": "tcp,udp", "followRedirect": False
  },
  "sniffing": {"enabled": False}
}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        if ! xray_test_restart; then
            python3 - "$XRAY_CONF" "$tag" "$port" "$rhost" "$rport" <<'PY'
import json,sys
path,tag=sys.argv[1],sys.argv[2]
listen_port=int(sys.argv[3]); rhost=sys.argv[4]; rport=int(sys.argv[5])
inbound={
  "tag": tag, "listen": "0.0.0.0", "port": listen_port,
  "protocol": "dokodemo-door",
  "settings": {"address": rhost, "port": rport, "network": "tcp,udp", "followRedirect": False},
  "sniffing": {"enabled": False}
}
conf=json.load(open(path,encoding="utf-8"))
conf["inbounds"]=[i for i in conf.get("inbounds",[]) if i.get("tag")!=tag]
conf["inbounds"].append(inbound)
json.dump(conf, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
            xray_test_restart || die "Xray 启动失败"
        fi
        open_firewall "$port" tcp
        open_firewall "$port" udp
        local client_share clash_item
        client_share="$(np_share rewrite "$link" "$server" "$port" "$name")"
        clash_item="$(np_share clash "$link" "$name" "$server" "$port")"
        python3 - "$META_DIR/$tag.json" "$tag" "$name" "$server" "$port" "$rhost" "$rport" "$client_share" "$clash_item" "$scheme" <<'PY'
import json,sys
path=sys.argv[1]
meta={
  "tag": sys.argv[2],
  "kind": "dokodemo",
  "protocol": "中转（任意门）",
  "name": sys.argv[3],
  "server": sys.argv[4],
  "port": sys.argv[5],
  "dest_addr": sys.argv[6],
  "dest_port": sys.argv[7],
  "client_share": sys.argv[8],
  "clash_item": sys.argv[9],
  "origin_scheme": sys.argv[10]
}
json.dump(meta, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY
        ok "已添加中转。任意门转发到 ${rhost}:${rport}，请放行 TCP/UDP ${port}"
    fi
    print_node "$tag"
}

# ---------------- 查看 / 卸载 ----------------
menu_view() {
    local tags t c i
    mapfile -t tags < <(list_installed_tags)
    if [[ ${#tags[@]} -eq 0 ]]; then
        warn "还没有安装任何协议"; return
    fi
    echo
    echo -e "${BOLD}已安装节点${NC}"
    i=1
    for t in "${tags[@]}"; do
        echo "  $i) $(load_meta "$META_DIR/$t.json" protocol)  $(load_meta "$META_DIR/$t.json" server):$(load_meta "$META_DIR/$t.json" port)"
        i=$((i+1))
    done
    echo "  0) 全部打印"
    read -rp "请选择: " c
    if [[ "$c" == "0" ]]; then
        for t in "${tags[@]}"; do print_node "$t"; done
        write_combined_clash
        return
    fi
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#tags[@]} )); then
        print_node "${tags[$((c-1))]}"
    fi
}

write_combined_clash() {
    local tags
    mapfile -t tags < <(list_installed_tags)
    [[ ${#tags[@]} -gt 0 ]] || return
    write_clash_yaml "$CLASH_DIR/all.yaml" "${tags[@]}"
    print_clash_import_all
}

uninstall_tag() {
    local tag="$1"
    local f="$META_DIR/$tag.json" port kind out_tag left
    [[ -f "$f" ]] || { warn "未安装 $tag"; return; }
    port="$(load_meta "$f" port)"
    kind="$(load_meta "$f" kind)"
    if [[ "$tag" == relay-* ]]; then
        out_tag="$(load_meta "$f" out_tag)"
        left="$(xray_remove_relay "$tag" "$out_tag")"
        close_firewall "$port" tcp
        [[ "$kind" == "dokodemo" ]] && close_firewall "$port" udp
        if [[ "${left:-0}" == "0" ]]; then
            systemctl stop xray >/dev/null 2>&1 || true
            info "Xray inbound 已清空，已停止 Xray"
        else
            xray_test_restart || warn "Xray 重启异常，请检查 $XRAY_CONF"
        fi
        rm -f "$f" "$CLASH_DIR/$tag.yaml"
        ok "已卸载 $tag"
        return
    fi
    case "$tag" in
        hysteria2|hysteria2-*)
            hy2_stop_tagged "$tag"
            close_firewall "$port" udp
            ;;
        ss2022|ss2022-*|socks5|socks5-*)
            left="$(xray_remove_inbound "$tag")"
            close_firewall "$port" tcp
            close_firewall "$port" udp
            if [[ "${left:-0}" == "0" ]]; then
                systemctl stop xray >/dev/null 2>&1 || true
                info "Xray inbound 已清空，已停止 Xray"
            else
                xray_test_restart || warn "Xray 重启异常，请检查 $XRAY_CONF"
            fi
            ;;
        *)
            left="$(xray_remove_inbound "$tag")"
            close_firewall "$port" tcp
            if [[ "${left:-0}" == "0" ]]; then
                systemctl stop xray >/dev/null 2>&1 || true
                info "Xray inbound 已清空，已停止 Xray"
            else
                xray_test_restart || warn "Xray 重启异常，请检查 $XRAY_CONF"
            fi
            ;;
    esac
    rm -f "$f" "$CLASH_DIR/$tag.yaml"
    ok "已卸载 $tag"
}

menu_uninstall() {
    local tags t c i
    mapfile -t tags < <(list_installed_tags)
    if [[ ${#tags[@]} -eq 0 ]]; then
        warn "没有可卸载的协议"; return
    fi
    echo
    echo -e "${BOLD}卸载${NC}"
    i=1
    for t in "${tags[@]}"; do
        echo "  $i) $(load_meta "$META_DIR/$t.json" protocol)  $(load_meta "$META_DIR/$t.json" server):$(load_meta "$META_DIR/$t.json" port)"
        i=$((i+1))
    done
    echo "  a) 卸载全部协议（保留 Xray/Hy2 程序）"
    echo "  0) 返回"
    read -rp "请选择: " c
    [[ "$c" == "0" || -z "$c" ]] && return
    if [[ "$c" == "a" || "$c" == "A" ]]; then
        for t in "${tags[@]}"; do uninstall_tag "$t"; done
        return
    fi
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#tags[@]} )); then
        uninstall_tag "${tags[$((c-1))]}"
    fi
}

banner() {
    clear 2>/dev/null || true
    local os_name ipstr
    os_name="${OS_PRETTY:-${OS_ID:-unknown} ${OS_VER}}"
    collect_public_ips
    ipstr="$(printf '%s、' "${PUBLIC_IPS[@]}")"
    ipstr="${ipstr%、}"
    echo "检测到信息"
    echo "当前操作系统：${os_name}"
    echo "当前服务器IP：${ipstr}"
    echo "--------------------------------------------------"
    echo "安装（可共存，一次装一种）"
    echo "  1) VLESS + TCP + Reality + Vision     直连（最推荐）"
    echo "  2) VLESS + XHTTP + Reality            直连（新传输）"
    echo "  3) Hysteria2                          UDP 加速"
    echo "  4) Shadowsocks 2022                   轻量"
    echo "  5) SOCKS5 明文 + 账号密码             指纹浏览器"
    echo "  6) VMess + TCP + Reality              直连（AEAD）"
    echo
    echo "中转"
    echo "  7) 添加中转（粘贴节点链接）"
    echo
    echo "管理"
    echo "  8) 查看配置 / 重新输出链接、二维码、Clash"
    echo "  9) 卸载"
    echo "  0) 退出"
    echo
}

main_menu() {
    local c
    while true; do
        banner
        read -rp "请输入选项: " c
        case "$c" in
            1) install_vless_reality; pause ;;
            2) install_vless_xhttp; pause ;;
            3) install_hysteria2; pause ;;
            4) install_ss2022; pause ;;
            5) install_socks5; pause ;;
            6) install_vmess_reality; pause ;;
            7) install_relay; pause ;;
            8) menu_view; pause ;;
            9) menu_uninstall; pause ;;
            0) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

main() {
    need_root
    need_tty
    detect_os
    mkdir -p "$NODE_HOME" "$META_DIR" "$CLASH_DIR"
    persist_self
    main_menu
}

main "$@"
