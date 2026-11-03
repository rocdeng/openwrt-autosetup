#!/bin/sh
# 值守式升级还原层安装器（OpenWrt 24.10+，apk）
#
# 解决：Attended Sysupgrade(owut/LuCI) 只把官方 feed 里的包烘焙进镜像，
#       OpenClash / Argon（GitHub Release）与 Nikki（第三方 feed）会被丢弃。
#
# 做法：升级前快照已装清单 -> 升级 -> 首启自动把缺失的包装回来。
#
# 用法（设备上）：
#   wget -O restore-install.sh https://raw.githubusercontent.com/rocdeng/openwrt-autosetup/main/restore/install.sh
#   sh restore-install.sh
# 之后升级只需：owut upgrade

set -e

CONF="/etc/autosetup"
OWUT_D="/etc/owut.d"
RAW_URL="https://raw.githubusercontent.com/rocdeng/openwrt-autosetup/main/setup.sh"

info() { printf '[信息] %s\n' "$*"; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
command -v apk >/dev/null 2>&1 || die "本脚本要求 apk 包管理器（OpenWrt 24.10+）"

mkdir -p "$CONF" "$OWUT_D"

# ---- 1. setup.sh（真正干活的脚本，长期放在 /etc/autosetup）----
SETUP_SRC=""
for f in "$(dirname "$0")/../setup.sh" "$(dirname "$0")/setup.sh" ./setup.sh; do
    [ -f "$f" ] && SETUP_SRC="$f" && break
done
if [ -z "$SETUP_SRC" ]; then
    info "本地未找到 setup.sh，从仓库下载"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 -o "$CONF/setup.sh" "$RAW_URL"
    else
        wget -q -O "$CONF/setup.sh" "$RAW_URL"
    fi
    SETUP_SRC="$CONF/setup.sh"
fi
sh -n "$SETUP_SRC" || die "setup.sh 语法校验失败，已中止"
[ "$SETUP_SRC" = "$CONF/setup.sh" ] || cp "$SETUP_SRC" "$CONF/setup.sh"
chmod 755 "$CONF/setup.sh"
info "已安装 $CONF/setup.sh"

# ---- 2. 来源登记表：只记录「无法从任何 feed 取得」的包（GitHub Release 等）----
# 不要在这里硬编码要还原的包：还原清单由 setup.sh 每次升级前自动计算
if [ ! -f "$CONF/sources.list" ]; then
    cat > "$CONF/sources.list" <<'SRC'
# 每行：owner/repo 包名
# 只登记官方/第三方 feed 里都没有、只能从 GitHub Release 安装的包；
# 本脚本以后安装这类包会自动登记。示例：
# vernesong/OpenClash luci-app-openclash
SRC
    info "已生成 $CONF/sources.list（来源登记表）"
else
    info "保留已有 $CONF/sources.list"
fi

# 已装但未登记的第三方包，提示一次性登记（无法凭空推断其仓库地址）
for p in luci-app-openclash luci-theme-argon luci-app-argon-config; do
    apk info -e "$p" >/dev/null 2>&1 || continue
    grep -qs " $p\$" "$CONF/sources.list" && continue
    case "$p" in
        luci-app-openclash)          echo "vernesong/OpenClash $p" >> "$CONF/sources.list" ;;
        luci-theme-argon|luci-app-argon-config) echo "jerrykuku/luci-theme-argon $p" >> "$CONF/sources.list" ;;
    esac
done

# ---- 3. 升级前钩子：写快照 ----
cat > "$CONF/pre-install.sh" <<'PRE'
#!/bin/sh
# 由 owut --pre-install 调用：镜像校验通过、刷机前执行
exec /bin/sh /etc/autosetup/setup.sh snapshot
PRE
chmod 755 "$CONF/pre-install.sh"

# ---- 4. 首启还原脚本：等网络通再干活 ----
cat > "$CONF/restore-boot.sh" <<'BOOT'
#!/bin/sh
# 开机后执行一次：等外网可达（最长 10 分钟）再恢复，失败保留标记下次开机重试
FLAG=/etc/autosetup/restore.flag
PING_IP="223.5.5.5"
i=0
while [ "$i" -lt 120 ]; do
    if ping -c1 -W2 "$PING_IP" >/dev/null 2>&1; then
        break
    fi
    sleep 5
    i=$((i + 1))
done

if [ "$i" -ge 120 ]; then
    logger -t autosetup "等待外网超时，保留标记，下次开机重试"
    exit 0
fi

if /bin/sh /etc/autosetup/setup.sh restore; then
    rm -f "$FLAG"
    logger -t autosetup "升级后软件恢复完成"
    exit 0
fi

logger -t autosetup "恢复未完全成功，保留标记，下次开机重试"
exit 0
BOOT
chmod 755 "$CONF/restore-boot.sh"

# ---- 5. procd 服务：有标记才跑 ----
cat > /etc/init.d/autosetup <<'INITD'
#!/bin/sh /etc/rc.common
# 升级后有 restore.flag 时执行一次还原；无标记则什么都不做
START=95
STOP=10
USE_PROCD=1

start_service() {
    [ -f /etc/autosetup/restore.flag ] || return 0
    procd_open_instance
    procd_set_param command /bin/sh /etc/autosetup/restore-boot.sh
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "network"
}
INITD
chmod 755 /etc/init.d/autosetup
/etc/init.d/autosetup enable

# ---- 6. 随镜像下发的 uci-defaults：只负责置标记 ----
cat > "$OWUT_D/asu-defaults.sh" <<'DEFAULTS'
#!/bin/sh
# 由 owut --init-script 带入镜像，首启时执行；不要在此放置任何凭据
# （该文件内容会上传构建服务器，并可从构建哈希公开下载）
[ -x /etc/init.d/autosetup ] || exit 0
mkdir -p /etc/autosetup
touch /etc/autosetup/restore.flag
/etc/init.d/autosetup enable 2>/dev/null
exit 0
DEFAULTS
chmod 755 "$OWUT_D/asu-defaults.sh"

# ---- 7. 配置 owut：只挂两个钩子（剔除名单由 setup.sh 每次升级前自动生成）----
uci -q get attendedsysupgrade.owut >/dev/null 2>&1 || uci set attendedsysupgrade.owut=owut
uci set attendedsysupgrade.owut.init_script="$OWUT_D/asu-defaults.sh"
uci set attendedsysupgrade.owut.pre_install="$CONF/pre-install.sh"
uci -q delete attendedsysupgrade.owut.remove
uci commit attendedsysupgrade
info "已配置 owut：init_script / pre_install"

# ---- 8. 立刻快照一次，保证第一次升级就有清单与备份 ----
/bin/sh "$CONF/setup.sh" snapshot

info "安装完成。之后的升级命令: sh /etc/autosetup/setup.sh upgrade"
info "（它会自动快照、备份第三方包、剔除出构建清单，并在升级后自动装回）"
info "升级后首次开机会自动补回缺失的包；日志: logread -e autosetup"
