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
KEYS_DIR="$CONF_DIR/keys"
WORLD_SNAPSHOT="$CONF_DIR/world.snapshot"
RELEASE_MARK="$CONF_DIR/release.snapshot"
GH_CACHE="$CONF_DIR/github-cache"
SOURCES_FILE="$CONF_DIR/sources.list"
RESTORE_FLAG="$CONF_DIR/restore.flag"
# 连续还原失败计数：达到上限后删除标记，避免每次开机/网络变化无限重跑
ATTEMPTS_FILE="$CONF_DIR/restore.attempts"
MAX_RESTORE_TRIES="${MAX_RESTORE_TRIES:-5}"
# init-script 与服务工作副本都放在 /etc/autosetup 下：只有这个目录被登记进
# /etc/sysupgrade.conf，升级后仍然存在
OWUT_INIT="$CONF_DIR/asu-defaults.sh"
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
UNKNOWN_PKGS=""

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
  ALLOW_LOSS=1        upgrade 时即使有包升级后无法装回也继续（默认拦截）
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
# 1 = 最近一次 apk update 只部分成功（有源不可用，其余源索引已更新）
APK_PARTIAL=0

apk_update() {
    [ "$APK_UPDATED" = 1 ] && return 0
    apk_update_force
}

# apk update 只要有一个源取不到（如第三方源下架了旧版本目录）就返回非零，
# 但其余源的索引其实已经更新好了。这种“部分成功”不应让整个步骤失败：
# 返回 0 并置 APK_PARTIAL=1，需要严格判断的调用方（如 restore）自行检查
apk_update_force() {
    APK_PARTIAL=0
    out=$(apk update 2>&1)
    rc=$?
    printf '%s\n' "$out" | tee -a "$LOG_FILE"
    if [ "$rc" -eq 0 ]; then
        APK_UPDATED=1
        return 0
    fi
    avail=$(printf '%s\n' "$out" | sed -n 's/.* \([0-9][0-9]*\) distinct packages available.*/\1/p' | tail -n 1)
    if [ -n "$avail" ] && [ "$avail" -gt 0 ]; then
        APK_PARTIAL=1
        APK_UPDATED=1
        bad=$(printf '%s\n' "$out" | sed -n \
            -e 's/^WARNING: updating and opening \(.*\): [^:]*$/\1/p' \
            -e 's/^WARNING: updating \(.*\): [^:]*$/\1/p' | sort -u | tr '\n' ' ')
        warn "部分软件源不可用，其余源索引已更新，继续执行。不可用的源: ${bad:-见上方 WARNING}"
        return 0
    fi
    return 1
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
DIRECT="${DIRECT:-0}"

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

# 从同一个仓库安装一个或多个包，所有 apk 放进同一个 apk add 事务。
# 同仓库的包之间可能转移文件归属（如 Argon 3.x 把配置工具的文件并进了主题包），
# 分开安装会因“trying to overwrite ... owned by”失败，同一事务内 apk 能正确处理
github_install() {
    repo="$1"; shift
    todo=""
    for name in "$@"; do
        if is_installed "$name" && [ "$FORCE" != "1" ]; then
            info "$name 已安装，跳过（FORCE=1 可强制重装）"
            continue
        fi
        todo="$todo $name"
    done
    [ -n "$todo" ] || return 0

    assets=$(get_assets "$repo") || { err "无法获取 $repo 的发布信息（可尝试 -p  指定镜像）"; return 1; }
    files=""
    for name in $todo; do
        url=$(pick_apk "$assets" "$name")
        [ -n "$url" ] || { err "$repo 未找到 $name 的 apk 包"; return 1; }
        out="$TMP_DIR/${url##*/}"
        log "下载 apk: $url"
        dl_gh "$url" "$out" || { err "下载失败: $url"; return 1; }
        files="$files $out"
    done

    log "安装（自动解析依赖）:$todo"
    # shellcheck disable=SC2086
    apk add --allow-untrusted $files || { err "apk 安装失败:$todo"; return 1; }

    gi_rc=0
    set -- $files
    for name in $todo; do
        out="$1"; shift
        if ! is_installed "$name"; then
            err "安装校验失败：${out##*/} 安装后本地未检测到 $name"
            gi_rc=1
            continue
        fi
        info "安装成功: ${out##*/}"
        # 另存一份到保留目录：GitHub 类包不在任何 feed，离线时只能靠这份副本。
        # 按包名分目录且每次替换整个目录，保证每个包只留一个版本（多版本并存会导致降级）
        rm -rf "$GH_CACHE/$name"
        mkdir -p "$GH_CACHE/$name" 2>/dev/null \
            && cp -f "$out" "$GH_CACHE/$name/" 2>/dev/null
        # 登记来源：这类包不在任何 feed 里，升级后只能按此记录重装
        register_source "$repo" "$name"
    done
    return $gi_rc
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
    # 配置工具的 apk 与主题同仓库发布（独立配置仓库仅提供 ipk）；两者必须同一事务安装
    github_install "jerrykuku/luci-theme-argon" "luci-theme-argon" "luci-app-argon-config" \
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
# 除已知域名外，再按路径特征识别任意镜像站（ustc/aliyun/sjtu 等）的官方源：
# 其路径形如 https://<镜像>/openwrt/releases/...，第三方 feed 极少使用这种路径
DISTRO_REPO_RE="${DISTRO_REPO_RE:-downloads\.openwrt\.org|downloads\.immortalwrt\.org|mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.immortalwrt\.org|/(openwrt|immortalwrt)/(releases|snapshots)/}"

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
    official_repo_file "$TMP_DIR/official.repos" || {
        printf '未找到任何官方源行（检查 /etc/apk/repositories）\n' > "$TMP_DIR/official.err"
        return 1
    }
    # 先用官方源单独刷一次索引，避免用残缺的缓存索引做比对
    apk --repositories-file "$TMP_DIR/official.repos" update >/dev/null 2>&1
    if ! apk --repositories-file "$TMP_DIR/official.repos" list -a \
            > "$TMP_DIR/official.pkgs" 2> "$TMP_DIR/official.err"; then
        return 1
    fi
    n_official=$(wc -l < "$TMP_DIR/official.pkgs" 2>/dev/null | tr -d ' ')
    if [ -z "$n_official" ] || [ "$n_official" -lt 200 ]; then
        printf '官方源索引不可信（仅 %s 条），可能部分 feed 未取到\n' "${n_official:-0}" \
            > "$TMP_DIR/official.err"
        return 1
    fi
    # 注意：本函数的 stdout 会被 $(...) 捕获，诊断信息必须走 stderr
    printf '[信息] 官方源可用包 %s 个（用于比对）\n' "$n_official" >&2
    list_installed | sort -u > "$TMP_DIR/installed.txt"
    awk '
        NR == FNR { want[$0] = 1; next }
        {
            for (n in want)
                if (index($0, n "-") == 1) {
                    # 必须是 "name-<数字>"，否则 foo 会被 foo-extra 误判为官方包
                    if (substr($0, length(n) + 2) ~ /^[0-9]/) found[n] = 1
                } else if ($0 == n) found[n] = 1
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

# sysupgrade 只保留白名单里的路径，自定义目录必须显式登记，否则固件一升就没了
ensure_keep_entry() {
    conf=/etc/sysupgrade.conf
    mkdir -p "$CONF_DIR" 2>/dev/null
    added=""
    # 服务的开机自启链接同样不在白名单：只保留 init.d 文件而没有 rc.d 链接，
    # owut 不支持 -I 时服务开机不会启动，还原就静默失效
    if [ -f /etc/init.d/autosetup ] && ! /etc/init.d/autosetup enabled 2>/dev/null; then
        /etc/init.d/autosetup enable 2>/dev/null
    fi
    rc_link=$(ls /etc/rc.d/S*autosetup 2>/dev/null | head -n 1)
    for p in "$CONF_DIR" /etc/init.d/autosetup $rc_link; do
        grep -qs "^$p/*\$" "$conf" 2>/dev/null && continue
        printf '%s\n' "$p" >> "$conf" 2>/dev/null && added="$added $p"
    done
    [ -n "$added" ] && info "已加入 $conf 保留清单:$added"
    return 0
}

# 第三方源的签名公钥也在 /etc/apk/keys，同样不在 sysupgrade 白名单里，一并备份
snapshot_apk_keys() {
    mkdir -p "$KEYS_DIR" 2>/dev/null || return 0
    cp -f /etc/apk/keys/*.pem "$KEYS_DIR"/ 2>/dev/null
    n=$(ls "$KEYS_DIR" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && info "已备份 $n 个 apk 签名公钥 -> $KEYS_DIR"
}

restore_apk_keys() {
    [ -d "$KEYS_DIR" ] || return 0
    mkdir -p /etc/apk/keys 2>/dev/null
    for k in "$KEYS_DIR"/*; do
        [ -f "$k" ] || continue
        b=${k##*/}
        [ -f "/etc/apk/keys/$b" ] && continue
        cp -f "$k" "/etc/apk/keys/$b" && info "已恢复签名公钥: $b"
    done
}

# 记录第三方源行（官方源之外的全部），升级后原样加回——不依赖任何具体 feed 脚本
snapshot_extra_repos() {
    : > "$REPOS_SNAPSHOT" 2>/dev/null || return 1
    for f in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
        [ -f "$f" ] || continue
        grep -Ev '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
            | grep -Ev "$DISTRO_REPO_RE" >> "$REPOS_SNAPSHOT"
    done
    # 不用 sort -o：OpenWrt 的 BusyBox 未启用 FEATURE_SORT_BIG，会接受 -o 但直接忽略，
    # 结果仍输出到终端、文件也不去重（真机实测）。改用临时文件
    sort -u "$REPOS_SNAPSHOT" > "$REPOS_SNAPSHOT.tmp" 2>/dev/null \
        && mv -f "$REPOS_SNAPSHOT.tmp" "$REPOS_SNAPSHOT"
    rm -f "$REPOS_SNAPSHOT.tmp"
    [ -s "$REPOS_SNAPSHOT" ] || return 0
    info "已记录 $(wc -l < "$REPOS_SNAPSHOT" | tr -d ' ') 个第三方源 -> $REPOS_SNAPSHOT"
}

# 版本号 -> 分支号：24.10.2 -> 24.10，25.12.0-rc1 -> 25.12，SNAPSHOT 保持不变
release_branch() {
    case "$1" in
        *SNAPSHOT*|*snapshot*) printf 'SNAPSHOT'; return 0 ;;
    esac
    b=$(printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    printf '%s' "${b:-$1}"
}

# 读取升级前的发行版信息，判断版本/分支是否变化
# 结果写入全局变量 OLD_ID OLD_REL OLD_BRANCH NEW_BRANCH REL_CHANGED BRANCH_CHANGED
#   REL_CHANGED=1    完整版本号变了（含小版本，如 25.12.0 -> 25.12.1）
#   BRANCH_CHANGED=1 分支变了（如 24.10 -> 25.12），离线缓存不再可靠
detect_release_change() {
    OLD_ID=""; OLD_REL=""; OLD_BRANCH=""; REL_CHANGED=0; BRANCH_CHANGED=0
    NEW_BRANCH=$(release_branch "${DISTRIB_RELEASE:-}")
    [ -f "$RELEASE_MARK" ] || return 0
    read -r OLD_ID OLD_REL < "$RELEASE_MARK" 2>/dev/null
    OLD_BRANCH=$(release_branch "$OLD_REL")
    [ "$OLD_REL" != "$DISTRIB_RELEASE" ] && REL_CHANGED=1
    if [ "$OLD_ID" != "$DISTRIB_ID" ] || [ "$OLD_BRANCH" != "$NEW_BRANCH" ]; then
        BRANCH_CHANGED=1
        REL_CHANGED=1
    fi
}

# 把字符串转成可安全放进 sed 正则的形式（只需处理版本号里会出现的字符）
sed_escape() {
    printf '%s' "$1" | sed 's/[.[\*^$#]/\\&/g'
}

# 源行是否已存在于任一 apk 源文件
repo_line_present() {
    for f in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
        [ -f "$f" ] && grep -qsxF "$1" "$f" && return 0
    done
    return 1
}

# 在所有源文件中把整行 $1 替换为 $2；有替换返回 0
repo_line_replace() {
    hit=1
    for f in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
        [ -f "$f" ] && grep -qsxF "$1" "$f" || continue
        awk -v o="$1" -v n="$2" '$0 == o { $0 = n } { print }' "$f" > "$f.tmp.$$" \
            && cat "$f.tmp.$$" > "$f"
        rm -f "$f.tmp.$$"
        hit=0
    done
    return $hit
}

# 把快照里的第三方源加回当前配置
# 源行可能带 apk 仓库标签，如 "@daeuniverse https://..."，整行原样处理
restore_extra_repos() {
    [ -f "$REPOS_SNAPSHOT" ] || return 0
    target=/etc/apk/repositories
    need_nikki=0
    while read -r u; do
        [ -n "$u" ] || continue
        if [ "$BRANCH_CHANGED" = 1 ]; then
            # Nikki 的源地址由 feed.sh 按当前分支/架构生成，跨分支时重跑它最可靠
            case "$u" in
                *nikki*) need_nikki=1; continue ;;
            esac
        fi
        if [ "$REL_CHANGED" = 1 ]; then
            nv="$u"
            # 小版本升级也要换完整版本号：kmods 源路径带完整版本号
            # （如 .../25.12/kmods/25.12.0/...），不换就会装到与新内核不匹配的 kmod
            if [ -n "$OLD_REL" ] && [ -n "$DISTRIB_RELEASE" ]; then
                nv=$(printf '%s' "$nv" | sed "s#$(sed_escape "$OLD_REL")#$DISTRIB_RELEASE#g")
            fi
            # 跨分支时再换分支号（两侧要求非数字，避免误伤别的数字）
            if [ "$BRANCH_CHANGED" = 1 ] && [ -n "$OLD_BRANCH" ] && [ -n "$NEW_BRANCH" ] \
                    && [ "$OLD_BRANCH" != "SNAPSHOT" ]; then
                ob=$(sed_escape "$OLD_BRANCH")
                nv=$(printf '%s' "$nv" | sed \
                    -e "s#\([^0-9.]\)$ob\([^0-9.]\)#\1$NEW_BRANCH\2#g" \
                    -e "s#\([^0-9.]\)$ob\$#\1$NEW_BRANCH#")
            fi
            if [ "$nv" != "$u" ]; then
                info "源地址已按新版本改写: $u -> $nv"
                # 原文件若随 sysupgrade 保留下来（如 customfeeds.list），就地改写，避免新旧两行并存
                if repo_line_replace "$u" "$nv"; then
                    u="$nv"
                    continue
                fi
            elif [ "$BRANCH_CHANGED" = 1 ]; then
                warn "跨版本但源地址中未找到旧版本号，原样加回（可能仍指向旧分支）: $u"
            fi
            u="$nv"
        fi
        repo_line_present "$u" && continue
        printf '%s\n' "$u" >> "$target" && info "已恢复第三方源: $u"
    done < "$REPOS_SNAPSHOT"

    if [ "$need_nikki" = 1 ]; then
        info "跨版本升级：重新执行 Nikki feed.sh 生成新分支的源"
        ensure_nikki_feed || warn "Nikki 源重建失败，Nikki 相关包可能无法装回"
    fi
}

# 升级前把第三方包本身的 apk 文件缓存下来（版本锁定、离线可还原）
# 目录结构：apk-cache/<包名>/<文件>.apk，每个包只保留一个版本
cache_thirdparty_apks() {
    [ -s "$THIRD_LIST" ] || return 0
    staging="$APK_CACHE.new"
    rm -rf "$staging"
    mkdir -p "$staging" || return 1
    # 逐包 fetch：批量时只要有一个包不可用，整条命令就会失败、一个都下不到
    failed=""
    kept=""
    gh_only=""
    nocopy=""
    for p in $(cat "$THIRD_LIST"); do
        mkdir -p "$staging/$p"
        if apk fetch -o "$staging/$p" "$p" >/dev/null 2>"$TMP_DIR/fetch.err" \
                && ls "$staging/$p"/*.apk >/dev/null 2>&1; then
            continue
        fi
        # 失败原因写进日志，便于区分“源里没有”与“网络/签名问题”
        printf '[fetch %s] %s\n' "$p" "$(head -n 2 "$TMP_DIR/fetch.err" 2>/dev/null | tr '\n' ' ')" \
            >> "$LOG_FILE"
        rm -rf "$staging/$p"
        # 本次取不到：沿用上次该包的副本（只此一份，不会和新版本并存）
        if ls "$APK_CACHE/$p"/*.apk >/dev/null 2>&1; then
            cp -a "$APK_CACHE/$p" "$staging/$p" && kept="$kept $p"
        else
            # GitHub 类包本来就不在任何 feed 里，单独归类，避免误以为备份出了问题
            if grep -qs " $p\$" "$SOURCES_FILE"; then
                gh_only="$gh_only $p"
            else
                failed="$failed $p"
            fi
        fi
    done
    # 不在本次清单里的包（已卸载或已变成官方包）不再带入新缓存，升级后也就不会被装回
    rm -rf "$APK_CACHE"
    mv "$staging" "$APK_CACHE"
    got=$(ls "$APK_CACHE"/*/*.apk 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$kept" ] && warn "以下包本次下载失败，沿用上次的离线副本:$kept"
    [ -n "$failed" ] && log "以下包源里取不到（无法离线备份）:$failed"
    if [ -n "$gh_only" ]; then
        log "以下为 GitHub 类包，升级后按 sources.list 从 GitHub 重装:$gh_only"
        for p in $gh_only; do
            ls "$GH_CACHE/$p"/*.apk >/dev/null 2>&1 && continue
            nocopy="$nocopy $p"
        done
        [ -n "$nocopy" ] && info "其中尚无离线副本（GitHub 不可达时无法装回）:$nocopy；需要副本可执行 FORCE=1 sh $0 openclash argon 重装一次"
    fi
    info "已离线备份 $got 个第三方包 -> $APK_CACHE"

    # 既下载不到、也没登记来源的包，升级后无法自动装回：如实列出
    # （结果存入全局 UNKNOWN_PKGS，upgrade 据此拦截，避免升级后静默丢包）
    unknown=""
    for p in $(cat "$THIRD_LIST"); do
        ls "$APK_CACHE/$p"/*.apk >/dev/null 2>&1 && continue
        ls "$GH_CACHE/$p"/*.apk >/dev/null 2>&1 && continue
        grep -qs " $p\$" "$SOURCES_FILE" && continue
        unknown="$unknown $p"
    done
    UNKNOWN_PKGS="$unknown"
    if [ -n "$unknown" ]; then
        warn "以下第三方包来源未知，升级后无法自动装回:$unknown"
        info "常见原因：所属第三方源已被移除（apk fetch 失败原因见 $LOG_FILE 中的 [fetch ...] 行）"
        info "处理方式：重新添加该包的软件源；GitHub 包登记 echo 'owner/repo 包名' >> $SOURCES_FILE；不再需要的包直接 apk del"
    fi
}

# GitHub 包副本：清掉旧版平铺文件，以及已卸载包的副本
prune_github_cache() {
    [ -d "$GH_CACHE" ] || return 0
    rm -f "$GH_CACHE"/*.apk 2>/dev/null
    for d in "$GH_CACHE"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        is_installed "$n" || { rm -rf "$GH_CACHE/$n"; info "已删除已卸载包的离线副本: $n"; }
    done
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
    ensure_keep_entry
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
        why=$(head -n 2 "$TMP_DIR/official.err" 2>/dev/null | tr '\n' ' ')
        if [ -s "$THIRD_LIST" ]; then
            # 已有上次的成功结果，绝不能清空——否则 owut 会因第三方包缺货而拒绝升级
            warn "官方源索引不可用（${why:-未知原因}），沿用上次识别的 $(wc -l < "$THIRD_LIST" | tr -d ' ') 个第三方包"
            cache_thirdparty_apks
        else
            err "官方源索引不可用（${why:-未知原因}），且没有历史清单，无法判断哪些包需要剔除"
            info "先执行 sh $0 mirror 刷新索引，或检查网络后重试"
            record_fail "snapshot"
            snapshot_extra_repos
            return 1
        fi
    fi
    snapshot_extra_repos
    snapshot_apk_keys
    prune_github_cache

    # world = 显式安装的顶层包。还原只补这些，依赖交给 apk 解析，
    # 否则会把旧依赖（可能已改名/被替代）也写进 world，越滚越脏。
    # 保留仓库标签（name@tag）：带标签源里的包只有按 name@tag 才能装上；只去掉版本约束
    if [ -r /etc/apk/world ]; then
        grep -Ev '^[[:space:]]*(#|$)' /etc/apk/world 2>/dev/null \
            | sed 's/[<>=~][^@]*//' | sort -u > "$WORLD_SNAPSHOT"
        info "已记录 $(wc -l < "$WORLD_SNAPSHOT" | tr -d ' ') 个顶层包 -> $WORLD_SNAPSHOT"
    else
        : > "$WORLD_SNAPSHOT"
        warn "未找到 /etc/apk/world，将按完整已装清单还原（可能把依赖写成顶层包）"
    fi
    printf '%s %s\n' "${DISTRIB_ID:-unknown}" "${DISTRIB_RELEASE:-unknown}" > "$RELEASE_MARK"

    ensure_restore_files
}

# 按 sources.list 重装无法从 feed 取得的包（GitHub Release 等）
# 同一仓库的包合并成一次安装（见 github_install 的说明）
restore_sources() {
    [ -f "$SOURCES_FILE" ] || return 0
    rs_rc=0
    rs_repos=$(awk '$1 !~ /^#/ && NF >= 2 { print $1 }' "$SOURCES_FILE" | awk '!seen[$0]++')
    for rs_repo in $rs_repos; do
        rs_names=""
        for rs_name in $(awk -v r="$rs_repo" '$1 == r && NF >= 2 { print $2 }' "$SOURCES_FILE"); do
            is_installed "$rs_name" && [ "$FORCE" != "1" ] && continue
            rs_names="$rs_names $rs_name"
        done
        [ -n "$rs_names" ] || continue
        # shellcheck disable=SC2086
        github_install "$rs_repo" $rs_names || rs_rc=1
    done
    return $rs_rc
}

# 优先用升级前的 apk 缓存离线还原（版本与升级前一致）
# 只装升级前清单里的第三方包：用户卸载过的包即使还有副本也不会被装回
restore_offline_cache() {
    [ -s "$THIRD_LIST" ] || return 0
    files=""
    for p in $(cat "$THIRD_LIST"); do
        is_installed "$p" && continue
        for d in "$APK_CACHE/$p" "$GH_CACHE/$p"; do
            set -- "$d"/*.apk
            [ -f "$1" ] || continue
            files="$files $*"
            break
        done
    done
    [ -n "$files" ] || return 0
    set -- $files
    log "从离线缓存安装 $# 个 apk（版本与升级前一致）"
    if apk add --allow-untrusted "$@" >/dev/null 2>"$TMP_DIR/apk.err"; then
        return 0
    fi
    for f in "$@"; do
        apk add --allow-untrusted "$f" >/dev/null 2>"$TMP_DIR/apk.err" \
            || warn "离线安装失败 ${f##*/}: $(head -n 2 "$TMP_DIR/apk.err" 2>/dev/null | tr '\n' ' ')"
    done
    return 0
}

# 输出清单 $1 中尚未安装的条目（按包名比对，条目可带 @tag，原样输出供 apk add 使用）
missing_entries() {
    awk 'NR == FNR { have[$0] = 1; next }
         { n = $0; sub(/@.*/, "", n); if (n != "" && !(n in have)) print $0 }' "$2" "$1"
}

# 包是否还存在于当前已启用的任一软件源索引中
pkg_available() {
    apk list -a "$1" 2>/dev/null | awk -v n="$1" '
        index($0, n "-") == 1 && substr($0, length(n) + 2) ~ /^[0-9]/ { f = 1 }
        END { exit !f }'
}

# 记录一次还原失败；连续失败达到上限就删除标记，停止开机自动重试
restore_attempt_failed() {
    n=$(cat "$ATTEMPTS_FILE" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((n + 1))
    printf '%s\n' "$n" > "$ATTEMPTS_FILE" 2>/dev/null
    if [ "$n" -ge "$MAX_RESTORE_TRIES" ]; then
        if [ -f "$RESTORE_FLAG" ]; then
            rm -f "$RESTORE_FLAG"
            err "还原已连续失败 $n 次，停止自动重试；排查后手动执行: sh $0 restore"
        fi
    else
        warn "还原失败（第 $n/$MAX_RESTORE_TRIES 次），保留标记，下次开机自动重试"
    fi
}

step_restore() {
    section "恢复升级前的软件与网络"
    if ! ensure_network; then
        err "网络未就绪，无法恢复；恢复网络后重跑: sh $0 restore"
        restore_attempt_failed
        record_fail "restore"
        return 1
    fi

    # 跨分支（如 24.10 -> 25.12）时离线缓存与旧源都不可靠；小版本升级不算
    detect_release_change
    if [ "$BRANCH_CHANGED" = 1 ]; then
        warn "系统分支已变化（$OLD_ID $OLD_REL -> $DISTRIB_ID $DISTRIB_RELEASE）"
    fi

    # 1) 补回公钥 → 加回源 → 刷索引
    restore_apk_keys
    restore_extra_repos
    idx_ok=1
    apk_update_force || { idx_ok=0; warn "软件索引刷新失败，仍继续尝试恢复"; }
    # 部分源不可用时，“源里查不到”可能只是那个源没取到，不能据此判定包已永久消失
    [ "$APK_PARTIAL" = 1 ] && idx_ok=0

    # 2) 离线缓存（仅在同一分支内使用，避免装入旧 ABI 的二进制）
    if [ "$BRANCH_CHANGED" = 1 ]; then
        warn "跨分支升级，跳过离线缓存，改用在线安装"
    else
        restore_offline_cache
    fi

    # 3) 不在任何 feed 里的包（GitHub Release）先装：
    #    否则它们会在下面的差集里被判为“装不上”，导致永远失败
    restore_sources || warn "部分 GitHub 类包未能重装"

    # 4) 按顶层包差集在线补齐（无 world 清单时退回完整已装清单）
    want="$PKG_SNAPSHOT"
    [ -s "$WORLD_SNAPSHOT" ] && want="$WORLD_SNAPSHOT"
    if [ ! -f "$want" ]; then
        err "未找到清单（$want），无法判断要装回哪些包"
        info "检查 /etc/sysupgrade.conf 是否包含 /etc/autosetup，或重跑 restore-install.sh"
        restore_attempt_failed
        record_fail "restore"
        return 1
    fi

    restored=0
    list_installed | sort -u > "$TMP_DIR/cur.txt"
    missing=$(missing_entries "$want" "$TMP_DIR/cur.txt")
    if [ -n "$missing" ]; then
        log "仍有 $(printf '%s\n' "$missing" | wc -l | tr -d ' ') 个包缺失，在线补齐"
        if apk add $missing >/dev/null 2>"$TMP_DIR/apk.err"; then
            restored=$(printf '%s\n' "$missing" | wc -l | tr -d ' ')
        else
            for p in $missing; do
                if apk add "$p" >/dev/null 2>"$TMP_DIR/apk.err"; then
                    restored=$((restored + 1))
                else
                    warn "安装失败 $p: $(head -n 2 "$TMP_DIR/apk.err" 2>/dev/null | tr '\n' ' ')"
                fi
            done
        fi
    fi

    # 5) 最终以“实际装上了没有”判定成败，而不是中间步骤的报错。
    #    官方包在新版本里已被改名/移除（索引正常却查不到）属于永久性缺失，重试也没用，
    #    只告警不计失败；第三方包、GitHub 包或索引刷新失败时一律算失败，留给下次重试
    list_installed | sort -u > "$TMP_DIR/cur.txt"
    still=$(missing_entries "$want" "$TMP_DIR/cur.txt")
    hard=""
    gone=""
    for p in $still; do
        n="${p%%@*}"
        if [ "$idx_ok" = 1 ] \
                && ! grep -qsxF "$n" "$THIRD_LIST" \
                && ! grep -qs " $n\$" "$SOURCES_FILE" \
                && ! pkg_available "$n"; then
            gone="$gone $p"
        else
            hard="$hard $p"
        fi
    done
    [ -n "$gone" ] && warn "以下官方包在新版本源中已不存在，跳过（不再重试）:$gone"
    if [ -n "$hard" ]; then
        warn "以下包仍未恢复:$hard"
        restore_attempt_failed
        record_fail "restore"
        return 1
    fi
    rm -f "$ATTEMPTS_FILE"
    info "恢复完成：本次补装 $restored 个包"
}

# 服务与 init-script 都不在 sysupgrade 白名单里，升级后会消失；
# 每次升级前按需重建，避免“标记没生成 → 开机不还原”这种静默失效
ensure_restore_files() {
    mkdir -p "$CONF_DIR" 2>/dev/null

    # 生成物：每次按当前逻辑重写，避免与安装器里的副本漂移
    if printf '%s\n' '#!/bin/sh
# 由 owut --init-script 带入镜像，首启执行；不要在此放置任何凭据
# （内容会上传构建服务器，并可从构建哈希公开下载）
mkdir -p /etc/autosetup
touch /etc/autosetup/restore.flag
rm -f /etc/autosetup/restore.attempts
# 服务文件本身不在 sysupgrade 白名单，从 /etc/autosetup 的副本重建
if [ -f /etc/autosetup/init.d-autosetup ]; then
    mkdir -p /etc/init.d
    cp -f /etc/autosetup/init.d-autosetup /etc/init.d/autosetup
    chmod 755 /etc/init.d/autosetup
    /etc/init.d/autosetup enable 2>/dev/null
    # uci-defaults 在 rcS 之前运行，这里直接启动，不依赖服务启动顺序
    /etc/init.d/autosetup start 2>/dev/null
fi
ln -sf /etc/autosetup/setup.sh /usr/bin/autosetup 2>/dev/null
exit 0' > "$OWUT_INIT" 2>/dev/null; then
        chmod 755 "$OWUT_INIT"
    else
        warn "写入 $OWUT_INIT 失败"
    fi

    if [ ! -f /etc/init.d/autosetup ]; then
        if [ -f "$CONF_DIR/init.d-autosetup" ]; then
            mkdir -p /etc/init.d 2>/dev/null
            if cp -f "$CONF_DIR/init.d-autosetup" /etc/init.d/autosetup 2>/dev/null; then
                chmod 755 /etc/init.d/autosetup
                /etc/init.d/autosetup enable 2>/dev/null
                info "已从副本重建 /etc/init.d/autosetup"
            else
                warn "重建 /etc/init.d/autosetup 失败"
            fi
        else
            warn "缺少服务文件 /etc/init.d/autosetup，升级后无法自动还原"
        fi
    fi

    # 短命令别名，同样不在白名单
    ln -sf "$CONF_DIR/setup.sh" /usr/bin/autosetup 2>/dev/null

    # 旧安装可能仍指向 /etc/owut.d，规范到保留目录
    if command -v uci >/dev/null 2>&1 && uci -q get attendedsysupgrade.owut >/dev/null 2>&1; then
        cur=$(uci -q get attendedsysupgrade.owut.init_script 2>/dev/null)
        if [ "$cur" != "$OWUT_INIT" ]; then
            uci set attendedsysupgrade.owut.init_script="$OWUT_INIT" 2>/dev/null \
                && uci commit attendedsysupgrade 2>/dev/null \
                && info "已把 owut init_script 规范为 $OWUT_INIT"
        fi
    fi

    # 服务文件可能刚被重建并 enable，再登记一次保留清单（含 rc.d 自启链接）
    ensure_keep_entry
}

# ---- 配置备份体积守卫 ----
# x86 等平台：sysupgrade 刷完镜像后，由 platform_copy_config 把配置备份
# cp 到引导分区（默认仅 16MB，内核已占去大半）。空间不够时 cp 失败，
# 但脚本不检查返回值——升级照常完成，首启找不到备份，全部配置静默丢失。
# 因此刷机前先生成一次真实备份，和引导分区剩余空间比较。
MOVED_CACHE_DIR=""

# 返回 0=放得下 1=放不下 2=无法判断；结果放入 BACKUP_KB / BOOT_AVAIL_KB
check_backup_fits() {
    BACKUP_KB=""; BOOT_AVAIL_KB=""
    bk="$TMP_DIR/backup-test.tgz"
    rm -f "$bk"
    sysupgrade -b "$bk" >/dev/null 2>&1 || { rm -f "$bk"; return 2; }
    BACKUP_KB=$(( ($(wc -c < "$bk") + 1023) / 1024 ))
    # 体积最大的几个文件，便于定位
    tar -tzvf "$bk" 2>/dev/null | awk '{ print $3, $NF }' | sort -rn | head -n 5 \
        > "$TMP_DIR/backup-top.txt"
    rm -f "$bk"
    # 只有单独挂载引导分区的平台（x86 等）有此限制
    grep -qs ' /boot ' /proc/mounts || return 0
    BOOT_AVAIL_KB=$(df -k /boot 2>/dev/null | awk 'NR == 2 { print $4 }')
    [ -n "$BOOT_AVAIL_KB" ] || return 2
    # 留 2MB 余量：新内核可能比旧内核大
    [ "$BACKUP_KB" -lt $((BOOT_AVAIL_KB - 2048)) ] && return 0
    return 1
}

restore_moved_caches() {
    [ -n "$MOVED_CACHE_DIR" ] && [ -d "$MOVED_CACHE_DIR" ] || return 0
    for d in "$MOVED_CACHE_DIR"/*; do
        [ -e "$d" ] && mv "$d" "$CONF_DIR/" 2>/dev/null
    done
    rm -rf "$MOVED_CACHE_DIR"
    MOVED_CACHE_DIR=""
}

guard_backup_size() {
    check_backup_fits
    fit=$?
    if [ "$fit" = 2 ]; then
        if [ -z "$BACKUP_KB" ]; then
            err "无法生成测试备份（sysupgrade -b 失败），为防止配置丢失已中止升级"
            return 1
        fi
        warn "无法读取引导分区剩余空间，跳过体积检查（备份 ${BACKUP_KB}KB）"
        return 0
    fi
    if [ "$fit" = 0 ]; then
        info "配置备份 ${BACKUP_KB}KB${BOOT_AVAIL_KB:+，引导分区剩余 ${BOOT_AVAIL_KB}KB}，空间足够"
        return 0
    fi

    warn "配置备份 ${BACKUP_KB}KB，引导分区仅剩 ${BOOT_AVAIL_KB}KB：直接升级会丢失全部配置"
    # 先牺牲离线缓存：升级后改为在线还原，配置比版本锁定重要得多
    if [ -d "$APK_CACHE" ] || [ -d "$GH_CACHE" ]; then
        MOVED_CACHE_DIR="$TMP_DIR/moved-cache"
        rm -rf "$MOVED_CACHE_DIR"; mkdir -p "$MOVED_CACHE_DIR"
        [ -d "$APK_CACHE" ] && mv "$APK_CACHE" "$MOVED_CACHE_DIR/"
        [ -d "$GH_CACHE" ] && mv "$GH_CACHE" "$MOVED_CACHE_DIR/"
        warn "已将离线缓存移出备份（本次升级后改为在线还原），重新检查"
        check_backup_fits
        fit=$?
        if [ "$fit" = 0 ]; then
            info "移出离线缓存后备份 ${BACKUP_KB}KB，空间足够"
            return 0
        fi
    fi
    restore_moved_caches
    err "配置备份 ${BACKUP_KB}KB 仍超过引导分区剩余空间 ${BOOT_AVAIL_KB}KB，已中止升级"
    info "备份中最大的文件（KB 前为字节数）:"
    cat "$TMP_DIR/backup-top.txt" 2>/dev/null | tee -a "$LOG_FILE"
    info "请把大文件移出 /etc 或从 /etc/sysupgrade.conf 删除对应条目后重试"
    return 1
}

step_upgrade() {
    section "值守式升级（自动剔除并备份第三方包）"
    command -v owut >/dev/null 2>&1 \
        || { err "未找到 owut（OpenWrt 25.12 起预装，旧版执行: apk add owut）"; record_fail "upgrade"; return 1; }
    ensure_network || { err "网络未就绪，终止升级"; record_fail "upgrade"; return 1; }

    # 重启后 apk 索引缓存在 /tmp 里已清空，先刷新；
    # 失败不中止——识别逻辑会沿用上次的清单，owut 会用明确报错兜底
    info "刷新软件索引"
    apk_update_force || warn "索引刷新失败（识别可能沿用上次结果）"

    step_snapshot || { err "快照失败，已中止升级"; record_fail "upgrade"; return 1; }
    ensure_restore_files

    # 有包既无离线副本、也无来源：升级后必然丢失，默认拦截
    if [ -n "$UNKNOWN_PKGS" ] && [ "${ALLOW_LOSS:-0}" != "1" ]; then
        err "以下第三方包升级后无法装回，已中止升级:$UNKNOWN_PKGS"
        info "补齐来源或卸载这些包后重试；确认可以丢弃时执行: ALLOW_LOSS=1 sh $0 upgrade"
        record_fail "upgrade"
        return 1
    fi

    # 配置备份必须能放进目标位置，否则 sysupgrade 会静默丢弃全部配置（见 check_backup_fits）
    guard_backup_size || { record_fail "upgrade"; return 1; }

    # 兜底：标记放在保留目录里，即使 owut 不支持 -I 也能在升级后触发还原
    # （服务文件与 rc.d 自启链接已登记进 sysupgrade.conf）。
    # 新一轮升级，失败计数清零；owut 失败（未刷机）时删除标记，避免日常运行中被误触发
    rm -f "$ATTEMPTS_FILE"
    : > "$RESTORE_FLAG" 2>/dev/null && info "已预置还原标记 restore.flag"

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
    # 新版 owut 默认（append）会把 /etc/apk/repositories.d/ 下除 distfeeds.list 外的源
    # 一并提交给 ASU；官方服务器的 repository_allow_list 为空，直接报
    # "Repository not allowed" 拒绝构建。第三方包已剔除、升级后由还原层装回，
    # 因此关闭这一行为，只用官方源构建
    case "$owut_help" in
        *--repositories-mode*) set -- "$@" --repositories-mode disable ;;
    esac

    log "执行: owut $*"
    owut "$@" || {
        rm -f "$RESTORE_FLAG"
        restore_moved_caches
        err "owut 升级失败（未刷机，已撤销还原标记）"
        record_fail "upgrade"
        return 1
    }
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
