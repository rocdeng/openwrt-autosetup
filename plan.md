# OpenWrt 升级后一键配置 — 需求与实现思路

> 操作步骤、检查清单与故障排查见 [README.md](README.md)；本文只讲设计与取舍。

## 一、需求背景

OpenWrt 每次升级/刷机后，软件源和用户自行安装的软件都会被重置，需要手工重复一套固定操作。本工程用一个 POSIX `sh` 脚本 `setup.sh` 把这些操作自动化，在升级后一键完成环境重建。

## 二、功能需求

脚本需依次完成以下五件事：

1. **替换软件源为清华源**：把默认的官方源替换为清华 TUNA 镜像，提升国内下载速度。
2. **安装 OpenClash**：从 GitHub Release 获取并安装 `luci-app-openclash`。
3. **安装 Nikki**：通过官方 `feed.sh` 接入 Nikki 软件源后安装（github nikki）。
4. **安装 Argon 主题及配置工具**：`luci-theme-argon` 与 `luci-app-argon-config`，并将 Argon 设为默认主题。
5. **安装 acme 客户端与 DDNS**：`acme` / `luci-app-acme` 与 `ddns-scripts` / `luci-app-ddns`（含中文语言包）。

## 三、目标环境与关键约束

| 项目 | 说明 |
|---|---|
| 系统 | OpenWrt 24.10 及以上（或同期 ImmortalWrt），使用 **apk** 包管理器 |
| 包格式 | 统一只处理 **`.apk`** 包，由 `apk add` 自动解析并安装依赖，不做 ipk 解包 |
| Shell | POSIX `sh`（busybox ash/dash 可运行），不使用 bash 特有语法 |
| 权限 | 必须 root 运行 |
| 网络 | 访问 GitHub 可能受限，需支持配置加速代理前缀 |
| 架构 | 不硬编码 CPU 架构，优先选架构无关的 `all` 包；GitHub 包多为单文件 `all` 包 |

环境前置校验：启动时检测 root 身份与 `/usr/bin/apk` 是否存在，缺失即报错退出；读取 `/etc/openwrt_release` 获取发行版、版本、架构；检测 `/sbin/fw4` 判断防火墙类型。

## 四、总体设计

- **单文件自包含**：仅一个 `setup.sh`，不依赖外部库，方便上传到路由器直接执行。
- **幂等可重跑**：已安装的软件默认跳过；`FORCE=1` 可强制重装；任一步失败只记录不中断，最后汇总，可单独重跑失败步骤。
- **步骤可组合**：不带参数执行全部；带步骤名（`mirror/openclash/nikki/argon/cert`）只执行指定项。
- **统一日志**：终端彩色输出 + 同时写入 `/tmp/openwrt-after-upgrade/run.log`。
- **临时目录**：所有下载与源文件备份集中在 `/tmp/openwrt-after-upgrade/`（重启即清，不污染存储）。

```
参数解析 → 环境校验 → 依次执行启用的步骤 → 结果汇总
                          │
                          ├─ mirror     改源 + 接入 Nikki feed + 单次 apk update
                          ├─ openclash  dnsmasq-full + GitHub apk
                          ├─ nikki      apk add（源与索引已在 mirror 就绪）
                          ├─ argon      GitHub apk ×2 + uci 设默认主题
                          └─ cert       apk add acme / ddns
```

## 五、分步实现思路

### 0. 网络与 DNS 预检（step_netcheck）

所有安装动作都依赖网络，因此把网络检查独立成步、并在每个联网步骤前复用。`preflight_network` 逐级判定，先修链路、再修解析：

1. **默认路由 / IP 连通**：`ip route show default` 缺失或 `ping 223.5.5.5` 不通时，调用 `configure_gateway` 自动修复：
   - 网关地址默认 `192.168.1.1`，可用 `--gateway`（或 `GATEWAY` 环境变量）覆盖；
   - 安全校验：拒绝把本机接口地址设为网关；先 ping 网关确认本机已接入该网段，不可达则放弃（避免写入无效路由）；
   - 逻辑接口名自动探测：`ip route get` 取物理设备（如 `br-lan`）→ 遍历 `uci show network` 按 device 反查逻辑接口（如 `lan`）；PPPoE（设备 `pppoe-*`）按 `proto ppp*` 匹配；都不命中则取第一个非 loopback 逻辑接口（**禁止回退物理设备名**，否则 UCI 写入被静默丢弃）；
   - 持久化方式按协议选择：`static` 接口直接写 `network.<iface>.gateway`（netifd 原生管理，重载后自动重建；旧版独立 `route` section 会在 ifup 瞬间漏装）；`dhcp`/`ppp*` 接口忽略 gateway 选项，用命名 section `auto_defaultroute`，配置前先清理旧 section；
   - 网关与 DNS 只触发**一次** `ifup <iface>`；重载后等待网关可达（最多 15 秒），并校验/兜底补回内核默认路由，避免重载清空路由后失联；
   - 配置后仍 ping 不通外网，判定为网关上游问题并提示更换网关；
2. **IP 连通**：`ping 223.5.5.5`，确认链路层已通；
3. **DNS 解析**：`nslookup www.baidu.com`（无 nslookup 时退化为 ping 域名）。

DNS 失败时 `configure_dns` 将 DNS 列表（默认网关 + 223.5.5.5、119.29.29.29，可用 `--dns` 多次指定或 `DNS` 环境变量覆盖）写入自动探测到的上联逻辑接口（`network.<iface>.dns`，实测设备为 `lan`）；DNS 与网关共用同一次 `ifup <iface>`，随后重启 dnsmasq 并最多重试 6 次等待生效；仍失败则打印 `/etc/resolv.conf` 与上游 DNS 记录辅助排查。

> 顺序约束：mirror 步骤改为**先预检通过、再改源文件**，避免在无网状态下先污染配置。

### 1. 替换清华源（step_mirror）

- 依据 `DISTRIB_ID` 区分官方 OpenWrt 与 ImmortalWrt，构造不同的 `sed` 替换规则：
  - 官方：`downloads.openwrt.org` / `archive.openwrt.org` → `mirrors.tuna.tsinghua.edu.cn/openwrt`
  - ImmortalWrt：对应域名 → `mirrors.tuna.tsinghua.edu.cn/immortalwrt`
- 处理 apk 的源文件：`/etc/apk/repositories` 以及 `/etc/apk/repositories.d/*.list`。
- 每个文件先备份到临时目录，再用 `sed -i` 原地替换。
- 改完清华源后，通过共享函数 `ensure_nikki_feed`（校验 fw4/版本 → 下载执行 feed.sh）接入 Nikki 源，然后只执行**一次** `apk update` 同时覆盖清华源与 Nikki 源（需求：避免全量流程中 mirror 和 nikki 各更新一次）。
- 若系统不满足 Nikki 条件或 feed 失败，mirror 不失败，只提示 nikki 步骤单独重试。

### 2. OpenClash（step_openclash）

- OpenClash 依赖 `dnsmasq-full`（默认装的是精简版 `dnsmasq`），先执行 `ensure_dnsmasq_full`：
  停 dnsmasq 服务 → 尝试直接安装；若因文件冲突失败，则先 `apk del dnsmasq` 再 `apk add dnsmasq-full` → 重新启用/启动服务。
- 通过通用的 GitHub 安装流程下载安装 `vernesong/OpenClash` 的 `luci-app-openclash` apk。
- 安装后提示：首次使用需在界面「版本更新」中下载 mihomo 内核。

### 3. Nikki（step_nikki）

- 源接入逻辑已前置到 mirror（`ensure_nikki_feed`），本步骤复用；单独运行 `sh setup.sh nikki` 时仍会通过同一函数自动补源。
- 前置门槛（不满足则记录失败）：
  - 必须是 firewall4/nftables 系统（存在 `/sbin/fw4`）；
  - 版本需 ≥ 24.10（白名单匹配 24.10 / 25.12 / SNAPSHOT）。
- 全量流程中索引已由 mirror 带着 Nikki 源更新；单独跑 nikki 时才 `apk update`。
- 然后执行 `apk add nikki luci-app-nikki luci-i18n-nikki-zh-cn`，依赖由 apk 自动解决。

### 4. Argon 主题与配置工具（step_argon）

- 两个组件都从 `jerrykuku/luci-theme-argon` 仓库的 Release 取 apk：
  - `luci-theme-argon`
  - `luci-app-argon-config`
- **重要实测结论**：配置工具的独立仓库 `luci-app-argon-config` 最新版只提供 ipk，而主题仓库 Release 中同时发布了配置工具的 apk，因此两者统一从主题仓库获取。
- 安装后通过 `uci set luci.main.mediaurlbase='/luci-static/argon'` 并 `uci commit luci` 将 Argon 设为默认主题。

### 5. acme 与 DDNS（step_cert）

均来自系统软件源（清华源），直接 apk 安装，依赖自动解析：

- acme：`acme luci-app-acme luci-i18n-acme-zh-cn`
- DDNS：`ddns-scripts luci-app-ddns luci-i18n-ddns-zh-cn`

### 6. 值守式升级还原层（step_snapshot / step_restore / step_upgrade）

**要解决的问题**：Attended Sysupgrade（`owut` / LuCI ASU）把设备已装包清单发给构建服务器，服务器只用**官方 feed** 解析（已核实 `sysupgrade.openwrt.org` 的 `overview.json` 中 `repository_allow_list` 为空）。因此第三方 feed 的包（Nikki）和 GitHub Release 安装的包（OpenClash/Argon）无法烘焙进镜像，升级后必然丢失。

**做法**：不写死任何包名，全部按实际清单计算。

1. **识别第三方包** `thirdparty_packages`：
   - 从 `/etc/apk/repositories`(+`repositories.d/*.list`) 中筛出官方源行（白名单正则 `DISTRO_REPO_RE`，默认匹配 `downloads.openwrt.org` / `mirrors.tuna.tsinghua.edu.cn` 等域名，以及任意镜像站上 `/openwrt|immortalwrt/releases|snapshots/` 路径；第三方 feed 行被排除）；
   - 以该文件作为 `apk --repositories-file` 覆盖，取官方可用包索引 `apk list -a`；
   - 用一次 `awk` 比对已装清单（`/lib/apk/db/installed` 的 `P:` 行）与官方索引，差集即第三方包，写入 `/etc/autosetup/thirdparty.list`。
2. **备份** `cache_thirdparty_apks`：对第三方包执行 `apk fetch -o /etc/autosetup/apk-cache`，把 **apk 文件本身**存下来（版本锁定、离线可还原）。下载不到且未登记来源的包会明确告警。
3. **来源登记** `/etc/autosetup/sources.list`（`owner/repo 包名`）：只用于 GitHub 这类任何 feed 都没有的包；`github_install` 安装成功后自动登记，因此以后新装的包无需人工维护。
4. **升级编排** `step_upgrade`：先快照/备份（含第三方源行 `repos.snapshot`），再由 `thirdparty.list` 动态生成 `owut upgrade -r <包名...>`（清单来自已装数据库，故用纯包名；旧版 owut 不认 `/if-installed` 后缀），并挂上 `-I`（随镜像下发的 uci-defaults）与 `--progress-size`（显示下载进度）。**不使用 owut 的 `-p/--pre-install`**：该钩子经 `ubus call file exec` 执行且有超时，快照要跑 `apk list`/`apk fetch`，实测直接 `Request timed out`；快照在 upgrade 步骤开头已完成，无需重复。
5. **首启还原** `step_restore`，由 procd 服务在开机后触发：
   - 先补回 `/etc/apk/keys` 里第三方源的**签名公钥**（同样不在 sysupgrade 白名单，丢了会报 `UNTRUSTED signature`），再按 `repos.snapshot` 把升级前的第三方源行加回 `/etc/apk/repositories`，然后刷新索引；跨分支（如 24.10 → 25.12）时把 URL 中的旧版本号/分支号改写为新的，Nikki 源则重跑其 `feed.sh` 生成；
   - 同一分支内优先用 `apk-cache/<包名>/`、`github-cache/<包名>/` 离线装回（版本与升级前一致，只装 `thirdparty.list` 中的包）；跨分支时跳过离线缓存，避免装入旧 ABI 的二进制；
   - 按 `sources.list` 重装 GitHub 类包；
   - 最后按 `world.snapshot`（顶层包）差集在线补齐，依赖交给 apk 解析；
   - 以"实际是否装上"判定成败：新版本中已不存在的官方包只告警；第三方包未装回则失败、保留标记重试，连续失败 `MAX_RESTORE_TRIES`（默认 5）次后删除标记，停止自动重试。

**持久化前提（关键）**：OpenWrt 的 `sysupgrade` 只保留白名单路径（`/etc/config`、`/etc/sysupgrade.conf`、`/etc/apk/repositories` 等），**自定义目录默认不保留**。因此 `step_snapshot` 每次都会把 `/etc/autosetup`、`/etc/init.d/autosetup` 及其开机自启链接 `/etc/rc.d/S95autosetup` 写进 `/etc/sysupgrade.conf`；`upgrade` 在调用 owut 前预置 `restore.flag`（owut 失败则撤销），因此即使 owut 不支持 `-I`，升级后服务仍会自启并执行还原。

**钩子说明**：`--init-script` 的脚本会被放进镜像 `/etc/uci-defaults/99-asu-defaults`，内容会上传构建服务器且可从构建哈希公开下载，因此里面**不能有凭据**；它只负责置标记并重建服务，不含任何凭据。真正的重活由 `/etc/init.d/autosetup` 在开机后等外网可达时执行，失败保留标记、下次开机重试。

**已知边界**：
- 跨大版本若触发 `sysupgrade -n`（配置不兼容），静态 IP 会丢，还原层无法联网 → 需先手工恢复网络；
- 离线缓存只能在源里仍存在该版本时被 `apk fetch` 取到；取不到且未登记来源的包无法自动还原；
- 无法凭空推断历史 GitHub 包的仓库地址，需一次性登记。

## 六、通用机制（关键函数）

- **下载 `dl`**：优先 `curl`，否则 `wget`。启动时一次性探测 `HAVE_CURL`/`HAVE_WGET`；
  wget 分支只用 BusyBox wget 支持的参数（`-q -T N -O`），**不能用 `--tries`/`--timeout` 等长选项**（实机 BusyBox wget 会直接报 `unrecognized option`）。curl 用 `--retry-all-errors` 覆盖 TLS 偶发错误。
- **GitHub 镜像回退 `dl_gh` / `gh_prefixes`**（**默认即走镜像，不直连**）：
  - 默认：按 `gh-proxy.com → ghfast.top → ghproxy.net` 依次尝试，任一成功即缓存其前缀（`GH_PREFIX`）复用；
  - `-p/--proxy`：只使用指定前缀；
  - `--direct`：在镜像之后额外尝试一次直连（默认不含直连，避免在国内浪费 30 秒等待超时）。
  > 实测三镜像能力不同：`gh-proxy.com` 可代理 API（返回 JSON），`ghproxy.net` 可访问 expanded_assets 页面，文件下载多个均可用——故默认顺序把可代理 API 的 `gh-proxy.com` 放最前。
- **发布信息获取 `github_release_json` / `get_assets`**：优先请求 `api.github.com/repos/<repo>/releases/latest`（同样经镜像回退），
  用 `grep -oE` 从 JSON 中提取 `tag_name` 与 `browser_download_url`，**不依赖 curl、jq 或 grep -P**；
  API 全失败时才回退到「重定向取 tag + expanded_assets 页面」解析（该回退路径需要 curl）。
- **选取 apk `pick_apk`**：在资产中筛选 `.apk`，按文件名 basename 是否以 `包名-` 开头精确匹配。
  > 实测 apk 命名为 `包名-版本.apk`（连字符，如 `luci-app-openclash-0.47.156.apk`），
  > 而 ipk 为 `包名_版本_all.ipk`（下划线），两者必须区分。
- **安装状态判断 `is_installed`（只查本地，不看软件源）**：
  必须用 `apk info -e <pkg>`（`--installed`）只查已安装数据库；并以 `/lib/apk/db/installed`（含 `/usr/lib/...`）中 `P:<pkg>` 记录兜底。
  > 坑：`apk info <pkg>`（不带 `-e`）会在**所有已启用源索引**里搜索，包仅仅“源里可查”时也返回成功。
  > Nikki 的 `feed.sh` 刚加源并 `apk update` 后即触发此问题——脚本误判“已安装”而跳过 `apk add`，导致“显示安装完成、实际未安装”。
- **安装本地 apk `install_apk_url`**：经 `dl_gh` 下载到临时目录后 `apk add --allow-untrusted <file>`，依赖自动解析；传入包名后安装完立即用 `is_installed` 复检，未检出即判失败。
- **GitHub 安装编排 `github_install`**：已装且非 FORCE 则跳过；否则取资产 → 选 apk → 下载安装并复检。
- **Nikki 步骤 `step_nikki`**：`apk add`（或跳过）之后再次用 `is_installed luci-app-nikki` 显式校验，校验不到则 `record_fail` 并返回 1，不再无条件打印“安装完成”。
- **失败记录 `record_fail` / 汇总**：失败步骤名追加到 `FAILED_STEPS`，最终非空则退出码为 1，并提示可单独重跑。

## 七、使用方式

```sh
# 上传到路由器后
chmod +x setup.sh

sh setup.sh                       # 执行全部步骤（含最先执行的网络预检）
sh setup.sh netcheck              # 只做网络与 DNS 预检（网关、DNS 异常时自动配置）
sh setup.sh mirror openclash      # 只执行指定步骤
sh setup.sh netcheck --gateway 192.168.0.1   # 指定上级网关（默认 192.168.1.1）
sh setup.sh -p https://ghproxy.net/   # GitHub 受限时配置加速前缀

FORCE=1 sh setup.sh argon         # 已安装也强制重装
sh setup.sh -h                    # 查看帮助

# 值守式升级（先装一次还原层，之后用这条命令升级）
wget -O restore-install.sh https://raw.githubusercontent.com/rocdeng/openwrt-autosetup/main/restore/install.sh
sh restore-install.sh             # 安装还原层（一次性）
sh /etc/autosetup/setup.sh upgrade   # 快照 → 备份第三方包 → owut 升级 → 首启自动装回
```

## 八、验证情况

已在 Windows + Git Bash（sh/bash/dash）环境完成：

- `sh -n` / `bash -n` 语法检查通过；文件为纯 LF 换行。
- 真实联网验证三个 GitHub 软件均可解析到存在的 apk 下载地址（HTTP 302）：
  - `luci-app-openclash-0.47.156.apk`
  - `luci-theme-argon-2.4.7-r1.apk`
  - `luci-app-argon-config-2.4.7-r1.apk`
- 验证过程中修正了两处实现问题：apk 命名匹配规则（连字符 vs 下划线）、配置工具改从主题仓库取包。
- 用桩 `apk` 模拟 apk-tools 查询语义，对 `is_installed` 做 4 场景测试全部通过：
  仅源可查→判未安装、真正已安装→判已安装、`apk info -e` 不可用时 installed 数据库兜底命中、无任何记录→判未安装。
  修复后“Nikki 加源后被误判已安装而跳过”的问题不再发生，且安装后有显式复检。

仍需在真实 OpenWrt 设备上确认的部分：`apk add` 实际写入与依赖解析、`dnsmasq → dnsmasq-full` 替换、`uci` 主题设置、Nikki `feed.sh` 接入后的真实安装与复检结果。建议首次先执行 `sh setup.sh mirror nikki` 小步验证。

## 九、文件清单

```
openwrt-after-upgrade/
├── setup.sh            # 唯一的自包含自动化脚本（含 snapshot/restore/upgrade 子命令）
├── restore/
│   └── install.sh      # 值守式升级还原层安装器（自包含，含各钩子脚本）
└── plan.md             # 本说明文档
```

设备上安装还原层后的落点（均在 `/etc`，随 sysupgrade 备份跨固件保留）：

```
/etc/autosetup/setup.sh           # 脚本副本（开机服务调用它执行 restore）
/etc/autosetup/restore-boot.sh    # 首启还原包装（等外网可达）
/etc/autosetup/pkgs.snapshot      # 升级前已装包清单
/etc/autosetup/repos.snapshot     # 升级前的第三方源行
/etc/autosetup/keys/              # 第三方源的签名公钥备份
/etc/autosetup/thirdparty.list    # 自动识别出的第三方包
/etc/autosetup/apk-cache/         # 第三方包的 apk 离线备份
/etc/autosetup/sources.list       # 只能从 GitHub 获取的包的来源登记
/etc/init.d/autosetup             # procd 服务：有 restore.flag 才执行一次还原
/etc/autosetup/asu-defaults.sh   # 随镜像下发的 uci-defaults（置标记+重建服务，无凭据）
/etc/autosetup/init.d-autosetup   # procd 服务副本（/etc/init.d 不在保留清单）
```
