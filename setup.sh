#!/bin/sh
# OpenWrt 升级后一键配置脚本（apk 版本，要求 OpenWrt 24.10+）
# 功能：清华源 / OpenClash / Nikki / Argon 主题 / acme / luci-app-ddns
# 所有应用均自动下载 .apk 包并通过 apk 安装（依赖自动解析）

TMP_DIR="/tmp/openwrt-after-upgrade"
LOG_FILE="$TMP_DIR/run.log"
GITHUB_PROXY="${GITHUB_PROXY:-}"
FORCE="${FORCE:-0}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS_SERVERS="${DNS:-}"

# 值守式升级的还原层：快照在升级前写入，随 /etc 备份跨固件保留
CONF_DIR="/etc/autosetup"
PKG_SNAPSHOT="$CONF_DIR/pkgs.snapshot"
THIRD_LIST="$CONF_DIR/thirdparty.list"
REPOS_SNAPSHOT="$CONF_DIR/repos.snapshot"
APK_CACHE="$CONF_DIR/apk-cache"
SOURCES_FILE="$CONF_DIR/sources.list"
OWUT_INIT="/etc/owut.d/asu-defaults.sh"
PKG_DB="/lib/apk/db/installed"

NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/feed.sh"

DO_NETCHECK=0
DO_MIRROR=0
DO_OPENCLASH=0
DO_NIKKI=0
DO_ARGON=0
DO_CERT=0
DO_SNAPSHOT=0
DO_RESTORE=0
DO_UPGRADE=0
FAILED_STEPS=""

mkdir -p "$TMP_DIR"
: > "$LOG_FILE"

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    C_RED="$(tput setaf 1 2>/dev/null)"; C_GREEN="$(tput setaf 2 2>/dev/null)"
    C_YELLOW="$(tput setaf 3 2>/dev/null)"; C_BLUE="$(tput setaf 4 2>/dev/null)"
    C_RESET="$(tput sgr0 2>/dev/null)"
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLUE" "$(date '+%H:%M:%S')" "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
info() { printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
err()  { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { err "$*"; exit 1; }

record_fail() {
    case " $FAILED_STEPS " in *" $1 "*) ;; *) FAILED_STEPS="$FAILED_STEPS $1" ;; esac
}

section() {
    printf '\n%s========== %s ==========%s\n' "$C_BLUE" "$1" "$C_RESET" | tee -a "$LOG_FILE"
}

usage() {
    cat <<EOF
用法: sh setup.sh [选项] [步骤...]
不指定步骤时执行全部步骤。要求系统使用 apk（OpenWrt 24.10+）。

步骤:
  netcheck    预检默认路由/IP 连通/DNS 解析（网关、DNS 异常时自动配置）
  mirror      替换 apk 源为清华源
  openclash   下载并安装 OpenClash apk
  nikki       添加 Nikki 源并安装
  argon       下载并安装 Argon 主题及配置工具 apk
  cert        安装 acme 和 luci-app-ddns
  snapshot    记录当前已装软件清单（upgrade 步骤开头会自动调用）
  restore     恢复升级前的软件与网络（首启由 autosetup 服务调用）
  upgrade     值守式升级：快照并备份第三方包 → owut 升级（升级后自动装回）

选项:
  -p, --proxy <URL>   指定单个 GitHub 加速前缀（默认已自动使用内置镜像）
      --direct        不走镜像，直连 GitHub
  -g, --gateway <IP>  默认网关地址（默认 192.168.1.1）
      --dns <IP>      DNS 服务器，可多次指定（默认：网关 + 公共 DNS）
  -h, --help          显示帮助

环境变量:
  FORCE=1             已安装也重新安装
  GITHUB_PROXY=<URL>  同 --proxy
  GATEWAY=<IP>        同 --gateway
  DNS="<IP> ..."      同 --dns，空格分隔多个
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--proxy)
            [ $# -ge 2 ] || die "$1 需要一个 URL 参数"
            GITHUB_PROXY="$2"; shift 2 ;;
        --proxy=*)
            GITHUB_PROXY="${1#*=}"; shift ;;
        --direct)
            DIRECT=1; shift ;;
        -g|--gateway)
            [ $# -ge 2 ] || die "$1 需要一个 IP 参数"
            GATEWAY="$2"; shift 2 ;;
        --gateway=*)
            GATEWAY="${1#*=}"; shift ;;
        --dns)
            [ $# -ge 2 ] || die "$1 需要一个 IP 参数"
            DNS_SERVERS="${DNS_SERVERS:+$DNS_SERVERS }$2"; shift 2 ;;
        --dns=*)
            DNS_SERVERS="${DNS_SERVERS:+$DNS_SERVERS }${1#*=}"; shift ;;
        netcheck)  DO_NETCHECK=1; shift ;;
        mirror)    DO_MIRROR=1; shift ;;
        openclash) DO_OPENCLASH=1; shift ;;
        nikki)     DO_NIKKI=1; shift ;;
        argon)     DO_ARGON=1; shift ;;
        cert)      DO_CERT=1; shift ;;
        snapshot)  DO_SNAPSHOT=1; shift ;;
        restore)   DO_RESTORE=1; shift ;;
        upgrade)   DO_UPGRADE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) warn "忽略未知参数: $1"; shift ;;
    esac
done

if [ "$DO_NETCHECK$DO_MIRROR$DO_OPENCLASH$DO_NIKKI$DO_ARGON$DO_CERT$DO_SNAPSHOT$DO_RESTORE$DO_UPGRADE" = "000000000" ]; then
    DO_NETCHECK=1; DO_MIRROR=1; DO_OPENCLASH=1; DO_NIKKI=1; DO_ARGON=1; DO_CERT=1
fi

[ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行本脚本"
[ -x /usr/bin/apk ] || die "本脚本仅支持使用 apk 的系统（OpenWrt 24.10+），未找到 apk"

. /etc/openwrt_release 2>/dev/null
DISTRIB_ID="${DISTRIB_ID:-OpenWrt}"
DISTRIB_RELEASE="${DISTRIB_RELEASE:-unknown}"
DISTRIB_ARCH="${DISTRIB_ARCH:-unknown}"
[ -x /sbin/fw4 ] && FW4=1 || FW4=0

case "$DISTRIB_ID" in
    *[Ii]mmortal*) FLAVOR="immortal" ;;
    *)             FLAVOR="openwrt" ;;
esac

GITHUB_PROXY="${GITHUB_PROXY%/}/"
[ "$GITHUB_PROXY" = "/" ] && GITHUB_PROXY=""

# 仅判断“本地是否已安装”，绝不读取软件源索引。
# 注意：`apk info <pkg>` 会在所有已启用源里搜索，包仅仅“源里可查”时也会返回成功，
# 因此必须用 -e（--installed）只查已安装数据库；再以 installed 数据库文件兜底。
is_installed() {
    if apk info -e "$1" >/dev/null 2>&1; then
        return 0
    fi
    for db in /lib/apk/db/installed /usr/lib/apk/db/installed; do
        if [ -r "$db" ] && grep -q "^P:$1\$" "$db" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

APK_UPDATED=0

apk_update() {
    [ "$APK_UPDATED" = 1 ] && return 0
    apk_update_force
}

apk_update_force() {
    apk update && APK_UPDATED=1
}

# 下载工具：优先 curl，否则 wget；wget 兼容 BusyBox（不支持 --tries）
HAVE_CURL=0
if command -v curl >/dev/null 2>&1; then HAVE_CURL=1; fi
HAVE_WGET=0
if command -v wget >/dev/null 2>&1; then HAVE_WGET=1; fi

# GNU wget 要求 HSTS 存储为普通文件且不可全局写，否则每次下载都打印 ERROR（不影响结果）
prepare_wget_hsts() {
    hsts="${HOME:-/root}/.wget-hsts"
    if [ ! -f "$hsts" ] || [ -L "$hsts" ]; then
        rm -f "$hsts"
        : > "$hsts"
    fi
    chmod 600 "$hsts" 2>/dev/null
}
prepare_wget_hsts

dl() {
    url="$1"; out="$2"
    if [ "$HAVE_CURL" = 1 ]; then
        curl -fL --connect-timeout 15 --retry 3 --retry-all-errors -o "$out" "$url"
    elif [ "$HAVE_WGET" = 1 ]; then
        wget -q -T 15 -O "$out" "$url"
    else
        err "需要 curl 或 wget"
        return 1
    fi
}

# 仅取 HTTP 响应头中的重定向 Location（BusyBox wget 无此能力，故只用 curl；无 curl 时由 API 路径兜底）
http_location() {
    [ "$HAVE_CURL" = 1 ] || return 1
    curl -fsSI --connect-timeout 15 "$1" 2>/dev/null | grep -i '^location:' | tail -n1
}

# GitHub 加速前缀：默认使用内置镜像依次回退；--direct 才在末尾尝试直连
GH_MIRRORS="https://gh-proxy.com https://ghfast.top https://ghproxy.net"
GH_PREFIX=""
DIRECT=0

gh_prefixes() {
    if [ -n "$GITHUB_PROXY" ]; then
        printf '%s\n' "$GITHUB_PROXY"
        return 0
    fi
    for m in $GH_MIRRORS; do printf '%s/\n' "$m"; done
    [ "$DIRECT" = 1 ] && printf '\n'
}

is_gh_url() {
    case "$1" in
        https://github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 按镜像依次尝试下载 GitHub 资源；成功即记住可用前缀，非 GitHub 链接直接下载
dl_gh() {
    url="$1"; out="$2"
    if ! is_gh_url "$url"; then
        dl "$url" "$out"
        return $?
    fi
    for p in $(gh_prefixes); do
        if dl "${p}${url}" "$out" && [ -s "$out" ]; then
            GH_PREFIX="$p"
            return 0
        fi
    done
    return 1
}

# 从 GitHub API JSON 中提取 latest 发布的 tag_name 与全部资产浏览器下载地址
# 不依赖 grep -P / jq：用 grep -oE 配合锚点逐项提取
github_release_json() {
    repo="$1"; out="$2"
    api="https://api.github.com/repos/$repo/releases/latest"
    for p in $(gh_prefixes); do
        if dl "${p}${api}" "$out" && [ -s "$out" ] && grep -q '"tag_name"' "$out" 2>/dev/null; then
            GH_PREFIX="$p"
            return 0
        fi
    done
    return 1
}

get_latest_tag() {
    repo="$1"
    json="$TMP_DIR/$(echo "$repo" | tr '/' '_').json"
    if github_release_json "$repo" "$json"; then
        grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "$json" | head -n1 \
            | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/'
        return 0
    fi
    loc=$(http_location "https://github.com/$repo/releases/latest") || return 1
    printf '%s' "$loc" | sed 's#.*/tag/##' | tr -d '\r\n'
}

get_assets() {
    repo="$1"
    json="$TMP_DIR/$(echo "$repo" | tr '/' '_').json"
    if github_release_json "$repo" "$json"; then
        grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' "$json" \
            | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/' | sort -u
        return 0
    fi
    tag=$(get_latest_tag "$repo") || return 1
    page="$TMP_DIR/$(echo "$repo" | tr '/' '_').html"
    dl_gh "https://github.com/$repo/releases/expanded_assets/$tag" "$page" || return 1
    grep -oE "/$repo/releases/download/[^\"<> ]+" "$page" \
        | sed "s#^#https://github.com#" | sort -u
}

pick_apk() {
    assets="$1"; name="$2"
    printf '%s\n' "$assets" | grep -E '/[^/]+\.apk$' | while read -r u; do
        b="${u##*/}"
        case "$b" in
            "${name}-"*) printf '%s\n' "$u"; return 0 ;;
        esac
    done | head -n 1
}

install_apk_url() {
    url="$1"; name="${2:-}"
    out="$TMP_DIR/${url##*/}"
    log "下载 apk: $url"
    dl_gh "$url" "$out" || return 1
    log "安装（自动解析依赖）: ${url##*/}"
    apk add --allow-untrusted "$out" || return 1
    if [ -n "$name" ] && ! is_installed "$name"; then
        err "安装校验失败：${url##*/} 安装后本地未检测到 $name"
        return 1
    fi
    info "安装成功: ${url##*/}"
}

github_install() {
    repo="$1"; name="$2"
    if is_installed "$name" && [ "$FORCE" != "1" ]; then
        info "$name 已安装，跳过（FORCE=1 可强制重装）"
        return 0
    fi
    assets=$(get_assets "$repo") || { err "无法获取 $repo 的发布信息（可尝试 -p  指定镜像）"; return 1; }
    url=$(pick_apk "$assets" "$name")
    [ -n "$url" ] || { err "$repo 未找到 $name 的 apk 包"; return 1; }
    install_apk_url "$url" "$name" || return 1
    # 登记来源：这类包不在任何 feed 里，升级后只能按此记录重装
    register_source "$repo" "$name"
}

if [ "$FLAVOR" = "immortal" ]; then
    MIRROR_BASE="https://mirrors.tuna.tsinghua.edu.cn/immortalwrt"
else
    MIRROR_BASE="https://mirrors.tuna.tsinghua.edu.cn/openwrt"
fi

rewrite_url() {
    u="$1"
    if [ "$FLAVOR" = "immortal" ]; then
        printf '%s' "$u" | sed \
            -e 's#//downloads\.immortalwrt\.org#//mirrors.tuna.tsinghua.edu.cn/immortalwrt#g' \
            -e 's#//archive\.immortalwrt\.org#//mirrors.tuna.tsinghua.edu.cn/immortalwrt#g' \
            -e 's#//mirrors\.immortalwrt\.org#//mirrors.tuna.tsinghua.edu.cn/immortalwrt#g'
    else
        printf '%s' "$u" | sed \
            -e 's#//downloads\.openwrt\.org#//mirrors.tuna.tsinghua.edu.cn/openwrt#g' \
            -e 's#//archive\.openwrt\.org#//mirrors.tuna.tsinghua.edu.cn/openwrt#g'
    fi
}

# 逐行规范化源文件：去除空白/CRLF/反引号/引号，避免畸形 URL 导致 apk 拉取失败
backup_file() {
    f="$1"
    orig="$TMP_DIR/$(basename "$f").orig"
    [ -f "$orig" ] || cp -a "$f" "$orig"
    cp -a "$f" "$TMP_DIR/$(basename "$f").$(date '+%Y%m%d-%H%M%S').bak"
}

sanitize_repo_file() {
    f="$1"
    [ -f "$f" ] || return 0
    backup_file "$f"
    tmp="$f.tmp.$$"
    : > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$(printf '\r')}"
        trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$trimmed" in
            ''|\#*)
                printf '%s\n' "$line"
                continue
                ;;
        esac
        # \140=` \042=" \047=' ，均为 URL 非法字符，直接剔除
        cleaned=$(printf '%s' "$trimmed" | tr -d '\140\042\047 \r')
        cleaned=$(rewrite_url "$cleaned")
        case "$cleaned" in
            http://*|https://*) printf '%s\n' "$cleaned" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
    log "已处理 $f"
}

# ---- 网络分层预检：默认路由 -> IP 连通 -> DNS 解析 ----
TEST_IP="223.5.5.5"
TEST_HOST="www.baidu.com"
PUBLIC_DNS="223.5.5.5 119.29.29.29"

has_default_route() {
    ip route show default 2>/dev/null | grep -q .
}

ip_reachable() {
    ping -c1 -W2 "$TEST_IP" >/dev/null 2>&1
}

resolve_ok() {
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$TEST_HOST" >/dev/null 2>&1
    else
        ping -c1 -W2 "$TEST_HOST" >/dev/null 2>&1
    fi
}

# 仅写入 DNS 配置（UCI），不重载接口；由 preflight 统一 reload 一次
configure_dns() {
    list="${DNS_SERVERS:-$GATEWAY $PUBLIC_DNS}"
    iface=$(detect_uplink)
    info "自动配置 DNS（接口 $iface）：$list"
    uci -q delete "network.$iface.dns" 2>/dev/null
    for d in $list; do
        uci add_list "network.$iface.dns=$d" 2>/dev/null
    done
    uci commit network 2>/dev/null
}

# 取与目标地址直连的物理设备名（br-lan / eth1 / pppoe-wan ...）
route_dev_for() {
    ip route get "$1" 2>/dev/null \
        | sed -n 's/.* dev \([A-Za-z0-9_.-][A-Za-z0-9_.-]*\).*/\1/p' | head -n1
}

# 上联逻辑接口名（lan/wan/...），全局只解析一次
# 路由/接口配置的 interface 字段必须是 UCI 逻辑接口名，不能假定叫 wan，
# 也不能直接填物理设备名（否则 netifd 报 "Interface xxx not found"）
UPLINK_IFACE=""
detect_uplink() {
    [ -n "$UPLINK_IFACE" ] && { printf '%s' "$UPLINK_IFACE"; return 0; }

    dev=$(route_dev_for "$GATEWAY")
    name=""

    if command -v uci >/dev/null 2>&1; then
        sections=$(uci show network 2>/dev/null \
            | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p')
        # 优先按物理设备精确匹配
        for s in $sections; do
            d=$(uci -q get "network.$s.device" 2>/dev/null)
            [ -z "$d" ] && d=$(uci -q get "network.$s.ifname" 2>/dev/null)
            case " $d " in
                *" $dev "*) name="$s"; break ;;
            esac
        done
        # PPPoE 路由设备为 pppoe-<iface>，与 UCI 的 device 不一致：按 ppp 协议匹配
        if [ -z "$name" ] && printf '%s' "$dev" | grep -q '^ppp'; then
            for s in $sections; do
                proto=$(uci -q get "network.$s.proto" 2>/dev/null)
                case "$proto" in ppp*) name="$s"; break ;; esac
            done
        fi
    fi

    # 仍未命中：取第一个非 loopback 逻辑接口。
    # 不能回退成物理设备名——它不是合法的 network section 名，写入会被静默丢弃
    if [ -z "$name" ]; then
        for s in $sections; do
            [ "$s" = "loopback" ] && continue
            d=$(uci -q get "network.$s.device" 2>/dev/null)
            [ "$d" = "lo" ] && continue
            name="$s"; break
        done
    fi

    [ -z "$name" ] && name="lan"
    UPLINK_IFACE="$name"
    printf '%s' "$name"
}

# 配置默认网关：按接口协议选择持久化方式，并立即下发内核路由
configure_gateway() {
    info "配置默认网关：$GATEWAY"

    if ip -4 addr show 2>/dev/null | grep -qw "$GATEWAY"; then
        err "$GATEWAY 是本机接口地址，不能作为默认网关"
        return 1
    fi

    if ! ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then
        err "网关 $GATEWAY 不可达：本机没有任何接口接入该网段"
        info "请先确认上联接口已接入上级网络（网线/DHCP/拨号），或用 --gateway 指定正确网关"
        return 1
    fi

    ifname=$(detect_uplink)
    proto=$(uci -q get "network.$ifname.proto" 2>/dev/null)

    # 上一版遗留的静态路由 section，先清理，避免两种方式并存
    uci -q delete network.auto_defaultroute

    case "$proto" in
        static|"")
            # 静态地址接口：gateway 是接口原生选项，ifup 后 netifd 自动重建默认路由，
            # 比独立 route section 可靠（route section 在接口重载瞬间可能漏装）
            uci set "network.$ifname.gateway=$GATEWAY"
            info "网关写入接口配置 network.$ifname.gateway（静态地址，netifd 原生管理）"
            ;;
        *)
            # DHCP/PPPoE 等接口忽略 gateway 选项，用静态默认路由 section
            uci set network.auto_defaultroute=route
            uci set network.auto_defaultroute.interface="$ifname"
            uci set network.auto_defaultroute.target='0.0.0.0'
            uci set network.auto_defaultroute.netmask='0.0.0.0'
            uci set network.auto_defaultroute.gateway="$GATEWAY"
            info "网关以静态路由 section 写入（$proto 接口，interface=$ifname）"
            ;;
    esac
    uci commit network

    # 立即生效，不必等接口重载
    ip route replace default via "$GATEWAY" || {
        err "写入默认路由失败: default via $GATEWAY"
        return 1
    }
}

# 重载上联接口（网关/DNS 共用一次），等待网关重新可达并兜底补回内核默认路由
reload_uplink() {
    iface=$(detect_uplink)
    info "重载上联接口 $iface 使配置生效"
    ifup "$iface" 2>/dev/null

    i=1
    while [ "$i" -le 15 ]; do
        ping -c1 -W1 "$GATEWAY" >/dev/null 2>&1 && break
        sleep 1
        i=$((i + 1))
    done

    # netifd 重载会清空旧内核路由；原生 gateway 应由其重建，route section 可能滞后，统一兜底
    has_default_route || ip route replace default via "$GATEWAY" 2>/dev/null
}

# 预检并尽力修复；返回 0 表示已可正常解析上网
preflight_network() {
    if ! has_default_route || ! ip_reachable; then
        warn "默认路由缺失或外网 IP 不可达，尝试自动配置默认网关"
        if ! configure_gateway; then
            info "请检查上联接口的网线、上级设备地址、DHCP/PPPoE 配置后重跑: sh $0 netcheck"
            return 1
        fi
    fi

    if ! has_default_route; then
        err "配置后仍无默认路由"
        return 1
    fi
    info "默认路由正常"

    if ! ip_reachable; then
        err "默认网关已配置但仍无法 ping 通 $TEST_IP，网关上游可能无法访问外网"
        info "请检查网关设备本身的联网，或指定其他网关: sh $0 netcheck --gateway <IP>"
        return 1
    fi
    info "IP 连通正常（$TEST_IP 可达）"

    if resolve_ok; then
        info "DNS 解析正常（$TEST_HOST）"
        return 0
    fi

    warn "DNS 解析失败"
    configure_dns
    reload_uplink
    /etc/init.d/dnsmasq restart 2>/dev/null

    if ! has_default_route; then
        err "接口重载后默认路由丢失且未能恢复"
        return 1
    fi

    i=1
    while [ "$i" -le 6 ]; do
        if resolve_ok; then
            info "配置 DNS 后解析恢复正常"
            return 0
        fi
        warn "等待 DNS 生效，5 秒后重试 ($i/6)"
        sleep 5
        i=$((i + 1))
    done

    err "配置 DNS 后仍无法解析域名"
    info "当前 /etc/resolv.conf:"; cat /etc/resolv.conf 2>/dev/null | tee -a "$LOG_FILE"
    info "上游 DNS 记录:"; cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null | tee -a "$LOG_FILE"
    err "可手动排查: nslookup $TEST_HOST $GATEWAY，或检查上游是否拦截 53 端口"
    return 1
}

NETWORK_OK=0

# 整个脚本运行期间只预检一次；后续步骤直接复用结果
ensure_network() {
    [ "$NETWORK_OK" = 1 ] && return 0
    preflight_network || return 1
    NETWORK_OK=1
}

step_netcheck() {
    section "网络与 DNS 预检"
    if ensure_network; then
        info "网络正常，可以继续安装"
        return 0
    fi
    record_fail "netcheck"
    return 1
}

# Nikki 系统要求校验；返回 0 表示可安装
nikki_requirements_ok() {
    if [ "$FW4" -ne 1 ]; then
        warn "Nikki 仅支持 firewall4 系统，不添加其源"
        return 1
    fi
    case "$DISTRIB_RELEASE" in
        *24.10*|*25.12*|SNAPSHOT) return 0 ;;
        *)
            warn "Nikki 要求 OpenWrt >= 24.10（当前: $DISTRIB_RELEASE），不添加其源"
            return 1
            ;;
    esac
}

NIKKI_FEED_OK=0
# 添加 Nikki 官方软件源（幂等，不刷新索引）；mirror 和 nikki 步骤共用
ensure_nikki_feed() {
    [ "$NIKKI_FEED_OK" -eq 1 ] && return 0
    nikki_requirements_ok || return 1

    info "添加 Nikki 官方软件源"
    feed="$TMP_DIR/nikki-feed.sh"
    dl_gh "$NIKKI_FEED" "$feed" || { err "feed.sh 下载失败"; return 1; }
    sh "$feed" || { err "Nikki 软件源添加失败"; return 1; }
    NIKKI_FEED_OK=1
}

step_mirror() {
    section "步骤 1/5 替换软件源为清华源"

    if ! ensure_network; then
        err "网络未就绪，暂不修改源文件；恢复网络后重跑: sh $0 mirror"
        record_fail "mirror"
        return 1
    fi

    if [ "$FLAVOR" = "immortal" ]; then
        info "检测到 ImmortalWrt"
    else
        info "检测到 OpenWrt 官方版"
    fi

    targets="/etc/apk/repositories"
    [ -d /etc/apk/repositories.d ] && targets="$targets $(ls /etc/apk/repositories.d/*.list 2>/dev/null)"
    for f in $targets; do
        sanitize_repo_file "$f"
    done

    # 清华源改完后立刻接入 Nikki 源，随后只更新一次索引即可覆盖两者
    if ensure_nikki_feed; then
        info "Nikki 源已就绪，将随清华源一起更新索引"
    else
        warn "Nikki 源本次未添加，nikki 步骤会单独重试"
    fi

    info "更新软件索引"
    apk_update || { err "软件索引更新失败，可先手动执行 wget -O- $MIRROR_BASE/ 排查"; record_fail "mirror"; return 1; }
    info "软件源替换完成"
}

ensure_dnsmasq_full() {
    if is_installed dnsmasq-full; then
        info "已安装 dnsmasq-full"
        return 0
    fi
    log "替换 dnsmasq 为 dnsmasq-full（OpenClash 依赖）"
    /etc/init.d/dnsmasq stop 2>/dev/null
    if ! apk add dnsmasq-full; then
        warn "直接安装失败，先移除 dnsmasq 再安装"
        apk del dnsmasq || return 1
        apk add dnsmasq-full || return 1
    fi
    /etc/init.d/dnsmasq enable 2>/dev/null
    /etc/init.d/dnsmasq start 2>/dev/null
    info "dnsmasq-full 就绪"
}

step_openclash() {
    section "步骤 2/5 安装 OpenClash"
    ensure_network || { err "网络未就绪，终止本步骤"; record_fail "openclash"; return 1; }
    apk_update || { record_fail "openclash"; return 1; }
    ensure_dnsmasq_full || { err "dnsmasq-full 替换失败"; record_fail "openclash"; return 1; }
    github_install "vernesong/OpenClash" "luci-app-openclash" \
        || { record_fail "openclash"; return 1; }
    warn "首次使用请在 OpenClash 页面「版本更新」中下载 mihomo 内核后再启动"
}

step_nikki() {
    section "步骤 3/5 安装 Nikki"
    ensure_network || { err "网络未就绪，终止本步骤"; record_fail "nikki"; return 1; }

    if ! ensure_nikki_feed; then
        err "Nikki 不满足安装条件或官方源添加失败"
        record_fail "nikki"
        return 1
    fi

    # 全量流程中 mirror 已带着 Nikki 源更新过索引；单独跑 nikki 时这里才真正更新
    apk_update || { err "软件索引更新失败"; record_fail "nikki"; return 1; }

    info "安装 Nikki（自动解析依赖）"
    if is_installed luci-app-nikki && [ "$FORCE" != "1" ]; then
        info "luci-app-nikki 已安装，跳过"
    else
        apk add nikki luci-app-nikki luci-i18n-nikki-zh-cn \
            || { err "Nikki 安装失败"; record_fail "nikki"; return 1; }
    fi

    if is_installed luci-app-nikki; then
        info "Nikki 安装完成"
    else
        err "Nikki 校验失败：apk add 返回成功但本地未检测到 luci-app-nikki"
        record_fail "nikki"
        return 1
    fi
}

step_argon() {
    section "步骤 4/5 安装 Argon 主题及配置工具"
    ensure_network || { err "网络未就绪，终止本步骤"; record_fail "argon"; return 1; }
    apk_update || { record_fail "argon"; return 1; }
    github_install "jerrykuku/luci-theme-argon" "luci-theme-argon" \
        || record_fail "argon"
    # 配置工具的 apk 与主题同仓库发布（独立配置仓库仅提供 ipk）
    github_install "jerrykuku/luci-theme-argon" "luci-app-argon-config" \
        || record_fail "argon"

    if is_installed luci-theme-argon; then
        uci set luci.main.mediaurlbase='/luci-static/argon' 2>/dev/null \
            && uci commit luci 2>/dev/null \
            && info "已将 Argon 设为默认主题"
    fi

    case "$FAILED_STEPS" in *argon*) return 1 ;; esac
    info "Argon 安装完成"
}

step_cert() {
    section "步骤 5/5 安装 acme 与 DDNS"
    ensure_network || { err "网络未就绪，终止本步骤"; record_fail "cert"; return 1; }
    apk_update || { record_fail "cert"; return 1; }

    info "安装 acme 证书客户端（自动解析依赖）"
    apk add acme luci-app-acme luci-i18n-acme-zh-cn \
        || record_fail "cert"

    info "安装 DDNS 动态域名（自动解析依赖）"
    apk add ddns-scripts luci-app-ddns luci-i18n-ddns-zh-cn \
        || record_fail "cert"

    case "$FAILED_STEPS" in *cert*) return 1 ;; esac
    info "acme / DDNS 安装完成"
}

# ---- 值守式升级还原层 ----
# 第三方包 = 已安装、但不在发行版官方软件源里的包（第三方 feed 或从 GitHub 安装）。
# 全程不写死包名：识别、备份、剔除、还原都按实际清单计算。
DISTRO_REPO_RE="${DISTRO_REPO_RE:-downloads\.openwrt\.org|downloads\.immortalwrt\.org|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.immortalwrt\.org}"

# 已装包名：优先读 apk 数据库（不受输出格式变化影响），回退 apk info
list_installed() {
    if [ -r "$PKG_DB" ]; then
        sed -n 's/^P:\(.*\)$/\1/p' "$PKG_DB"
        return 0
    fi
    apk info 2>/dev/null
}

# 只保留发行版官方源，生成临时 repositories 文件（第三方 feed 被排除）
official_repo_file() {
    out="$1"
    : > "$out"
    for f in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
        [ -f "$f" ] || continue
        grep -Ev '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
            | grep -E "$DISTRO_REPO_RE" >> "$out"
    done
    [ -s "$out" ]
}

# 输出第三方包名：已装包减去「官方源里存在的包」
thirdparty_packages() {
    official_repo_file "$TMP_DIR/official.repos" || return 1
    apk --repositories-file "$TMP_DIR/official.repos" list -a > "$TMP_DIR/official.pkgs" 2>/dev/null || return 1
    [ -s "$TMP_DIR/official.pkgs" ] || return 1
    list_installed | sort -u > "$TMP_DIR/installed.txt"
    awk '
        NR == FNR { want[$0] = 1; next }
        {
            for (n in want)
                if (index($0, n "-") == 1 || $0 == n) found[n] = 1
        }
        END { for (n in want) if (!(n in found)) print n }
    ' "$TMP_DIR/installed.txt" "$TMP_DIR/official.pkgs" | sort
}

# 记录包的来源（仅用于无法从任何 feed 取回的包）
register_source() {
    repo="$1"; name="$2"
    mkdir -p "$CONF_DIR" 2>/dev/null
    grep -qs "^$repo $name\$" "$SOURCES_FILE" && return 0
    printf '%s %s\n' "$repo" "$name" >> "$SOURCES_FILE"
}

# 记录第三方源行（官方源之外的全部），升级后原样加回——不依赖任何具体 feed 脚本
snapshot_extra_repos() {
    : > "$REPOS_SNAPSHOT" 2>/dev/null || return 1
    for f in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
        [ -f "$f" ] || continue
        grep -Ev '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
            | grep -Ev "$DISTRO_REPO_RE" >> "$REPOS_SNAPSHOT"
    done
    sort -u "$REPOS_SNAPSHOT" -o "$REPOS_SNAPSHOT" 2>/dev/null
    [ -s "$REPOS_SNAPSHOT" ] || return 0
    info "已记录 $(wc -l < "$REPOS_SNAPSHOT" | tr -d ' ') 个第三方源 -> $REPOS_SNAPSHOT"
}

# 把快照里的第三方源加回当前配置
restore_extra_repos() {
    [ -f "$REPOS_SNAPSHOT" ] || return 0
    target=/etc/apk/repositories
    while read -r u; do
        [ -n "$u" ] || continue
        grep -qsxF "$u" "$target" 2>/dev/null && continue
        printf '%s\n' "$u" >> "$target" && info "已恢复第三方源: $u"
    done < "$REPOS_SNAPSHOT"
}

# 升级前把第三方包本身的 apk 文件缓存下来（版本锁定、离线可还原）
cache_thirdparty_apks() {
    [ -s "$THIRD_LIST" ] || return 0
    mkdir -p "$APK_CACHE" || return 1
    rm -f "$APK_CACHE"/*.apk 2>/dev/null
    apk fetch -o "$APK_CACHE" $(cat "$THIRD_LIST") >/dev/null 2>&1
    got=$(ls "$APK_CACHE"/*.apk 2>/dev/null | wc -l | tr -d ' ')
    info "已离线备份 $got 个第三方包 -> $APK_CACHE"

    # 既下载不到、也没登记来源的包，升级后无法自动装回：如实列出
    unknown=""
    for p in $(cat "$THIRD_LIST"); do
        ls "$APK_CACHE/$p"-*.apk >/dev/null 2>&1 && continue
        grep -qs " $p\$" "$SOURCES_FILE" && continue
        unknown="$unknown $p"
    done
    if [ -n "$unknown" ]; then
        warn "以下第三方包来源未知，升级后无法自动装回:$unknown"
        info "登记方式（一次即可）: echo 'owner/repo 包名' >> $SOURCES_FILE"
    fi
}

step_snapshot() {
    section "记录软件清单与第三方包"
    names=$(list_installed | sort -u)
    if [ -z "$names" ]; then
        err "无法获取已装软件列表（$PKG_DB 不可读且 apk info 无输出）"
        record_fail "snapshot"
        return 1
    fi
    mkdir -p "$CONF_DIR" || { err "无法创建 $CONF_DIR"; record_fail "snapshot"; return 1; }
    if ! printf '%s\n' "$names" > "$PKG_SNAPSHOT"; then
        err "写入清单失败: $PKG_SNAPSHOT"
        record_fail "snapshot"
        return 1
    fi
    info "已记录 $(wc -l < "$PKG_SNAPSHOT" | tr -d ' ') 个已装包 -> $PKG_SNAPSHOT"

    if third=$(thirdparty_packages); then
        if [ -n "$third" ]; then
            printf '%s\n' "$third" > "$THIRD_LIST"
            info "识别出 $(wc -l < "$THIRD_LIST" | tr -d ' ') 个第三方包 -> $THIRD_LIST"
        else
            : > "$THIRD_LIST"
            info "未发现第三方包"
        fi
        cache_thirdparty_apks
    else
        warn "官方源索引不可用，无法识别第三方包；请先 sh $0 mirror 后重试"
        : > "$THIRD_LIST"
    fi
    snapshot_extra_repos
}

# 按 sources.list 重装无法从 feed 取得的包（GitHub Release 等）
restore_sources() {
    [ -f "$SOURCES_FILE" ] || return 0
    rc=0
    while read -r repo name rest; do
        case "$repo" in ''|'#'*) continue ;; esac
        [ -n "$name" ] || continue
        is_installed "$name" && [ "$FORCE" != "1" ] && continue
        github_install "$repo" "$name" || rc=1
    done < "$SOURCES_FILE"
    return $rc
}

# 优先用升级前的 apk 缓存离线还原（版本与升级前一致）
restore_offline_cache() {
    set -- "$APK_CACHE"/*.apk
    [ -f "$1" ] || return 0
    log "从离线缓存安装 $# 个 apk（版本与升级前一致）"
    if apk add --allow-untrusted "$@" >/dev/null 2>&1; then
        return 0
    fi
    for f in "$@"; do
        apk add --allow-untrusted "$f" >/dev/null 2>&1 || warn "离线安装失败: ${f##*/}"
    done
    return 0
}

step_restore() {
    section "恢复升级前的软件与网络"
    if ! ensure_network; then
        err "网络未就绪，无法恢复；恢复网络后重跑: sh $0 restore"
        record_fail "restore"
        return 1
    fi

    # 1) 第三方源按升级前的快照加回（与具体 feed 无关），再刷新索引
    restore_extra_repos
    apk_update_force || warn "软件索引刷新失败，仍继续尝试恢复"

    # 2) 离线缓存优先（版本锁定）
    restore_offline_cache

    # 3) 与升级前清单比对，补齐其余缺失（来自 feed 的包）
    restored=0
    bad_pkgs=""
    if [ -f "$PKG_SNAPSHOT" ]; then
        list_installed | sort -u > "$TMP_DIR/cur.txt"
        missing=$(grep -vxF -f "$TMP_DIR/cur.txt" "$PKG_SNAPSHOT" 2>/dev/null)
        if [ -n "$missing" ]; then
            log "仍有 $(printf '%s\n' "$missing" | wc -l | tr -d ' ') 个包缺失，在线补齐"
            if apk add $missing >/dev/null 2>&1; then
                restored=$(printf '%s\n' "$missing" | wc -l | tr -d ' ')
            else
                for p in $missing; do
                    if apk add "$p" >/dev/null 2>&1; then
                        restored=$((restored + 1))
                    else
                        bad_pkgs="$bad_pkgs $p"
                    fi
                done
            fi
        fi
    else
        warn "未找到升级前清单 $PKG_SNAPSHOT，跳过包恢复"
    fi

    # 4) 无法从 feed 取得的包，按登记的来源重装
    restore_sources || bad_pkgs="$bad_pkgs <sources.list 中的包>"

    if [ -n "$bad_pkgs" ]; then
        warn "以下软件未能恢复，可能源里已不存在:$bad_pkgs"
        record_fail "restore"
        return 1
    fi
    info "恢复完成：在线补装 $restored 个包"
}

step_upgrade() {
    section "值守式升级（自动剔除并备份第三方包）"
    command -v owut >/dev/null 2>&1 \
        || { err "未找到 owut（OpenWrt 25.12 起预装，旧版执行: apk add owut）"; record_fail "upgrade"; return 1; }
    ensure_network || { err "网络未就绪，终止升级"; record_fail "upgrade"; return 1; }

    step_snapshot || { err "快照失败，已中止升级"; record_fail "upgrade"; return 1; }

    remove_list=""
    if [ -s "$THIRD_LIST" ]; then
        # 清单来自已装数据库，这些包此刻确实都装着，直接传包名。
        # 不用 /if-installed 后缀：旧版 owut 不识别，会报 "is not installed and cannot be removed"
        remove_list=$(tr '\n' ' ' < "$THIRD_LIST" | sed 's/[[:space:]]*$//')
        log "从构建清单剔除 $(wc -l < "$THIRD_LIST" | tr -d ' ') 个第三方包（升级后自动装回）"
    fi

    # 按当前 owut 实际支持的选项拼装，避免不同版本参数差异导致失败
    owut_help=$(owut -h 2>&1)

    set -- upgrade
    [ -n "$remove_list" ] && set -- "$@" -r "$remove_list"
    if [ -f "$OWUT_INIT" ]; then
        case "$owut_help" in
            *--init-script*)  set -- "$@" -I "$OWUT_INIT" ;;
            *) warn "当前 owut 不支持 --init-script，首启还原标记不会随镜像下发" ;;
        esac
    fi
    # 不使用 owut 的 --pre-install：它经 ubus call file exec 执行且有超时，
    # 我们的快照要跑 apk list/fetch，必然超时（实测 Request timed out）。
    # 快照已在本步骤开头完成，这里无需再挂钩子。
    # 默认 0 = 下载镜像时完全不输出，看起来像卡死；显示进度便于判断是在下载还是真的挂了
    case "$owut_help" in
        *--progress-size*) set -- "$@" --progress-size "${OWUT_PROGRESS_SIZE:-1000}" ;;
    esac

    log "执行: owut $*"
    owut "$@" || { err "owut 升级失败"; record_fail "upgrade"; return 1; }
}

if [ -n "$GITHUB_PROXY" ]; then
    GH_MODE="$GITHUB_PROXY"
elif [ "$DIRECT" = 1 ]; then
    GH_MODE="直连"
else
    GH_MODE="内置镜像自动回退"
fi

printf '%s' "$C_BLUE"
cat <<EOF

==============================================
  OpenWrt 升级后一键配置（apk）
  系统 : $DISTRIB_ID $DISTRIB_RELEASE ($DISTRIB_ARCH)
  防火墙: $([ "$FW4" -eq 1 ] && echo nftables/fw4 || echo iptables)
  GitHub 加速: $GH_MODE
  日志 : $LOG_FILE
==============================================
EOF
printf '%s' "$C_RESET"

[ "$DO_NETCHECK" -eq 1 ]  && step_netcheck
[ "$DO_MIRROR" -eq 1 ]    && step_mirror
[ "$DO_OPENCLASH" -eq 1 ] && step_openclash
[ "$DO_NIKKI" -eq 1 ]     && step_nikki
[ "$DO_ARGON" -eq 1 ]     && step_argon
[ "$DO_CERT" -eq 1 ]      && step_cert
[ "$DO_SNAPSHOT" -eq 1 ]  && step_snapshot
[ "$DO_RESTORE" -eq 1 ]   && step_restore
[ "$DO_UPGRADE" -eq 1 ]   && step_upgrade

section "执行结果汇总"
if [ -z "$FAILED_STEPS" ]; then
    info "全部步骤执行成功"
else
    err "以下步骤存在失败:$FAILED_STEPS"
    warn "可根据日志 $LOG_FILE 排查后单独重跑，例如: sh setup.sh openclash"
fi

info "如 LuCI 菜单未刷新，可执行: /etc/init.d/uhttpd restart"
exit $([ -z "$FAILED_STEPS" ] && echo 0 || echo 1)
