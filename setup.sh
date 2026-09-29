#!/bin/sh
# OpenWrt 升级后一键配置脚本（apk 版本，要求 OpenWrt 24.10+）
# 功能：清华源 / OpenClash / Nikki / Argon 主题 / acme / luci-app-ddns
# 所有应用均自动下载 .apk 包并通过 apk 安装（依赖自动解析）

TMP_DIR="/tmp/openwrt-after-upgrade"
LOG_FILE="$TMP_DIR/run.log"
GITHUB_PROXY="${GITHUB_PROXY:-}"
FORCE="${FORCE:-0}"

NIKKI_FEED="https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/feed.sh"

DO_NETCHECK=0
DO_MIRROR=0
DO_OPENCLASH=0
DO_NIKKI=0
DO_ARGON=0
DO_CERT=0
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
  netcheck    预检默认路由/IP 连通/DNS 解析（DNS 异常时自动配置）
  mirror      替换 apk 源为清华源
  openclash   下载并安装 OpenClash apk
  nikki       添加 Nikki 源并安装
  argon       下载并安装 Argon 主题及配置工具 apk
  cert        安装 acme 和 luci-app-ddns

选项:
  -p, --proxy <URL>   指定单个 GitHub 加速前缀（默认已自动使用内置镜像）
      --direct        不走镜像，直连 GitHub
  -h, --help          显示帮助

环境变量:
  FORCE=1             已安装也重新安装
  GITHUB_PROXY=<URL>  同 --proxy
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
        netcheck)  DO_NETCHECK=1; shift ;;
        mirror)    DO_MIRROR=1; shift ;;
        openclash) DO_OPENCLASH=1; shift ;;
        nikki)     DO_NIKKI=1; shift ;;
        argon)     DO_ARGON=1; shift ;;
        cert)      DO_CERT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) warn "忽略未知参数: $1"; shift ;;
    esac
done

if [ "$DO_NETCHECK$DO_MIRROR$DO_OPENCLASH$DO_NIKKI$DO_ARGON$DO_CERT" = "000000" ]; then
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
    install_apk_url "$url" "$name"
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
FALLBACK_DNS="223.5.5.5 119.29.29.29"

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

configure_dns() {
    info "自动配置 DNS：$FALLBACK_DNS"
    uci -q delete network.wan.dns 2>/dev/null
    for d in $FALLBACK_DNS; do
        uci add_list network.wan.dns="$d" 2>/dev/null
    done
    uci commit network 2>/dev/null
    ifdown wan 2>/dev/null; ifup wan 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
}

# 预检并尽力修复；返回 0 表示已可正常解析上网
preflight_network() {
    if ! has_default_route; then
        err "未检测到默认路由，WAN 可能未连接/未拨号"
        info "请检查 WAN 口网线、DHCP/PPPoE 配置后重跑: sh $0 netcheck"
        return 1
    fi
    info "默认路由正常"

    if ! ip_reachable; then
        err "无法 ping 通 $TEST_IP，WAN 链路未真正连通（与 DNS 无关）"
        info "请确认 WAN 已获取地址或完成拨号后重跑: sh $0 netcheck"
        return 1
    fi
    info "IP 连通正常（$TEST_IP 可达）"

    if resolve_ok; then
        info "DNS 解析正常（$TEST_HOST）"
        return 0
    fi

    warn "DNS 解析失败"
    configure_dns

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
    err "可手动排查: nslookup $TEST_HOST $TEST_IP，或检查上游是否拦截 53 端口"
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
    if [ "$FW4" -ne 1 ]; then
        err "Nikki 仅支持 firewall4 系统，跳过"
        record_fail "nikki"
        return 1
    fi
    case "$DISTRIB_RELEASE" in
        *24.10*|*25.12*|SNAPSHOT) ;;
        *)
            err "Nikki 要求 OpenWrt >= 24.10（当前: $DISTRIB_RELEASE），跳过"
            record_fail "nikki"
            return 1
            ;;
    esac

    info "添加 Nikki 官方软件源"
    feed="$TMP_DIR/nikki-feed.sh"
    dl_gh "$NIKKI_FEED" "$feed" || { err "feed.sh 下载失败"; record_fail "nikki"; return 1; }
    sh "$feed" || { err "Nikki 软件源添加失败"; record_fail "nikki"; return 1; }

    info "刷新软件索引（含 Nikki 新源）"
    apk_update_force || { record_fail "nikki"; return 1; }

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

section "执行结果汇总"
if [ -z "$FAILED_STEPS" ]; then
    info "全部步骤执行成功"
else
    err "以下步骤存在失败:$FAILED_STEPS"
    warn "可根据日志 $LOG_FILE 排查后单独重跑，例如: sh setup.sh openclash"
fi

info "如 LuCI 菜单未刷新，可执行: /etc/init.d/uhttpd restart"
exit $([ -z "$FAILED_STEPS" ] && echo 0 || echo 1)
