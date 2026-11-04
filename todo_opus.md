# 还原逻辑审查待办（todo_opus）

审查范围：`setup.sh`、`restore/install.sh`、`README.md`、`plan.md`。
结论来自静态阅读代码，未在真机上运行验证。

## 总体结论

整体思路正确：升级前快照 → 剔除第三方包构建 → 首启装回。

- 同大版本小版本升级、且 owut 支持 `-I` 时，第三方包大多能装回；但受第 1、2 项影响，restore 几乎总会报失败并在每次开机重跑。
- 第 3、5 项会造成静默失效。
- 跨大版本升级还需额外考虑第 7 项。

建议优先修复：1、2、3、4、5（改动都不大）。

---

## 一、会直接导致还原失败或误报失败

### [x] 1. GitHub 类包必然先被记为失败，restore 永远返回 1
- 位置：`setup.sh` 第 986–1022 行（`step_restore`）
- 现状：restore 顺序为"离线缓存 → 快照差集在线补齐 → `sources.list` 从 GitHub 重装"。
  - OpenClash、Argon 不在任何源里，`apk fetch` 取不到，离线缓存中没有它们。
  - 第 3 步比对时它们算缺失，`apk add luci-app-openclash` 失败，被写入 `bad_pkgs`。
  - 第 4 步从 GitHub 装成功，但 `bad_pkgs` 不会被清掉。
- 后果：每次 restore 都返回 1，`restore.flag` 永不删除，每次开机都重跑，日志一直报失败。
- 修复：把 `restore_sources` 移到第 3 步之前；或在全部步骤结束后重新计算一次缺失清单，再判定成功与否。

### [x] 2. 差集基于完整已装库，而不是 `/etc/apk/world`
- 位置：`setup.sh` 第 989–1013 行
- 现状：`pkgs.snapshot` 取自 `/lib/apk/db/installed`，包含全部依赖库、内核模块和基础包。跨版本升级时这些包常会改名、合并、换实现（如 `libustream-*`、`wpad-*` 这类二选一的包）。
- 后果：
  - 旧名在新源中不存在或与新固件冲突，进入 `bad_pkgs`，同样导致 restore 永远失败。
  - `apk add` 会把这些依赖写进 world，变成"手动安装"。依赖被锁死，下次升级 owut 也会把它们当作顶层包上报。
- 修复：快照时额外保存一份 `/etc/apk/world`，restore 只按 world 的差集补装，依赖交给 apk 自行解析。

### [x] 3. 首启标记完全依赖 owut 的 `-I` 生效
- 位置：`setup.sh` `step_upgrade` 中 `--init-script` 判断处（约第 1100 行）
- 现状：`restore.flag` 只在 uci-defaults 中创建。owut 不支持 `--init-script` 时只打印 warn，然后继续升级。
- 后果：升级后既没有标记也没有服务，什么都不还原，属于静默失效。
- 修复（任选其一，最好两者都做）：
  - 在调用 owut 之前直接 `touch /etc/autosetup/restore.flag`（该目录本就跨升级保留）。
  - 把 `/etc/init.d/autosetup` 和 `/etc/rc.d/S95autosetup` 也登记进 `/etc/sysupgrade.conf`，服务直接保留下来，不再依赖 uci-defaults 重建。

### [x] 4. install.sh 在 `set -e` 下遇到 `uci -q delete` 会中止
- 位置：`restore/install.sh` 第 14 行（`set -e`）、第 141 行、第 148 行、第 150 行
- 现状：首次安装时 `attendedsysupgrade.owut.pre_install`、`.remove` 本不存在，`uci delete` 返回 1，脚本在 `set -e` 下直接退出。
- 后果：`uci commit` 和最后的 `snapshot` 都不会执行，安装器在中途悄悄结束。24.10 上未装 owut 时没有 `attendedsysupgrade` 配置，第 141 行的 `uci set` 也会在这里中止。
- 修复：给这几条命令加上 `|| true`；必要时先检查 owut 是否已安装。

### [x] 5. 升级前没有刷新索引
- 位置：`setup.sh` 第 1089 行（`step_upgrade` 调用 `step_snapshot`）
- 现状：没有先执行 `apk update`。路由器重启后 `/tmp` 中的索引缓存被清空，`thirdparty_packages` 得到"官方源索引为空"。
- 后果：
  - 如果有旧的 `thirdparty.list` 就沿用旧清单，之后新装的第三方包没被剔除，owut 构建失败。
  - `apk fetch` 同样没有索引可用，离线缓存为空。
- 修复：在 `step_snapshot` 之前调用 `apk_update_force`，失败则中止升级。

---

## 二、会削弱还原能力

### [x] 6. 离线缓存先删后下载
- 位置：`setup.sh` 第 879–880 行（`cache_thirdparty_apks`）
- 现状：先 `rm -f apk-cache/*.apk` 再 `apk fetch`；所有包放在一条命令里，且输出被丢弃。
- 后果：本次下载失败时，上次的有效缓存也被清掉，升级照常继续；其中一个包找不到就可能拖累其他包，用户只看到"已离线备份 0 个"。
- 修复：先下载到临时目录，成功后再替换；逐个包 fetch 并记录失败的包；离线备份数少于预期时中止升级，至少要明确提示。

### [x] 7. 跨大版本时第三方源被"原样回放"成旧版本
- 位置：`snapshot_extra_repos` / `restore_extra_repos` / `restore_offline_cache`
- 现状：`repos.snapshot` 保存的是完整 URL。Nikki 的 `feed.sh` 会把发行版分支和架构写进 URL；离线缓存也是"版本锁定"的旧构建。
- 后果：从 24.10 升到 25.12 后，回放的仍是 24.10 的源；可能在新固件上装上为旧库编译的二进制，看起来安装成功，运行时才出问题。
- 修复建议：
  - 检测到 `DISTRIB_RELEASE` 的大版本变化时，跳过离线缓存，并把源 URL 中的版本号替换为新版本。
  - 对已知的源（如 Nikki），重新执行其 `feed.sh`，比回放旧 URL 可靠。

### [x] 8. GitHub 包没有离线备份
- 位置：`install_apk_url`
- 现状：apk 已下载到 `/tmp`，却没有复制进 `apk-cache`。
- 后果：升级后如果 GitHub 镜像全部不可用，OpenClash 和 Argon 就装不回来。
- 修复：安装成功后把该文件另存一份。注意第 6 项：每次 snapshot 都会清空 `apk-cache`，这个副本需要放在单独的目录。

### [x] 9. 第三方包识别使用前缀匹配
- 位置：`setup.sh` 第 806 行（`thirdparty_packages` 中的 awk）
- 现状：`index($0, n "-") == 1` 表示只要官方索引里有以"包名-"开头的包，就判定该包为官方包。
- 后果：例如第三方的 `foo` 会因官方有 `foo-extra` 被误判为官方包，不会被剔除，owut 构建失败。此外这段是"已装包数 × 索引行数"的双重循环，BusyBox awk 下很慢。
- 修复：先从 `apk list` 输出中解析出纯包名（去掉 `-版本-rN` 及后续字段），再做精确的哈希匹配。

### [x] 10. `DISTRO_REPO_RE` 只认官方域名与清华源
- 位置：`setup.sh` `DISTRO_REPO_RE` 定义处
- 后果：如果用户改用中科大、阿里云等其他镜像，这些官方源行会被当成第三方源写进 `repos.snapshot`，升级后作为旧版本的官方源回放，风险比第 7 项更大。
- 修复：改为按路径特征识别（如 `/releases/`、`/snapshots/`），或允许用户配置该正则。

---

## 三、小问题

- [x] **`--direct` 不生效**：第 103 行在参数解析时设置 `DIRECT=1`，第 213 行又把它重置为 `DIRECT=0`。把第 213 行的初始化移到参数解析之前即可。
- [x] **OpenClash 内核可自动保留**：把 `/etc/openclash/core/` 加进 `/etc/sysupgrade.conf` 即可跨升级保留。README 中"唯一无法自动化"的手工项可以去掉。
- [ ] **等网超时后要到下次开机才重试**：`restore-boot.sh` 最多等待 10 分钟，超时后保留标记，要等下次开机（或网络配置变化触发 reload）才会再试。可考虑用 cron 定时重试。
- [x] **plan.md 有一处过时描述**：第九节仍写着 `/etc/owut.d/asu-defaults.sh`，实际位置已改为 `/etc/autosetup/asu-defaults.sh`。

---

## 四、第二轮复查（DeepSeek 修复后）发现并已修复的问题

- [x] **A. 开机自启链接没有保留**：只保留了 `/etc/init.d/autosetup`，没有保留 `/etc/rc.d/S95autosetup`。owut 不支持 `-I` 时服务开机不会启动。现在 `ensure_keep_entry` 会先确保服务已 enable，再把自启链接登记进 `/etc/sysupgrade.conf`。
- [x] **B. 离线缓存只增不减**：旧版本和新版本并存会按文件名顺序安装，可能导致降级；已卸载的包也会被装回。现在 `apk-cache/` 和 `github-cache/` 都按"包名/文件"分目录，每个包只保留一个版本；还原时只装 `thirdparty.list` 中的包；snapshot 时清理已卸载包的副本和旧版平铺文件。
- [x] **C. 跨版本判断用了完整版本号**：小版本升级也会跳过离线缓存，而 URL 里的分支号又替换不到。现在按分支号（`24.10`、`25.12`）判断；先替换完整版本号，再替换两侧为非数字的分支号，并对正则做转义；跨分支时 Nikki 源改为重跑 `feed.sh`。
- [x] **D. 永久装不上的包导致无限重跑**：新版本源里已不存在的官方包只告警、不算失败；第三方包、GitHub 包或索引刷新失败仍算失败；连续失败达到 `MAX_RESTORE_TRIES`（默认 5）次后删除标记。
- [x] **E. owut 失败时未撤销预置标记**：现在 owut 返回非零时会删除 `restore.flag`；每次新的升级会清零失败计数。
- [x] **F. world 中的 `@tag` 后缀没去掉**：已修复。

## 五、仍未处理 / 已知限制

- [ ] 等网超时后要到下次开机才重试（见上文小问题）。
- [ ] 第三方包识别的 awk 仍是"已装包数 × 索引行数"的双重循环，正确性没问题，但 BusyBox 下偏慢。
- [ ] 离线缓存里的依赖包通过 `apk add <文件>` 安装后会被写进 world。
- [ ] 已经装好的 GitHub 包没有离线副本，要等下次通过脚本重装才会生成。
- [ ] 设备上更新 `setup.sh` 后，要先执行一次 `autosetup snapshot` 再升级，否则旧快照缺少 world/release 信息。
- [ ] 以上修复只做了语法检查和桩测试，仍需在真机上完整走一遍升级。

## 六、第三轮：真机 snapshot 输出暴露的问题（已修复）

真机环境：OpenWrt 25.12.0 / x86_64，识别出 10 个第三方包，离线备份 0 个，其中 7 个来源未知。

- [x] **BusyBox `sort` 参数顺序**：`sort -u FILE -o FILE` 在 BusyBox 下会把 `-o` 当成文件名，结果是源行被打印到终端，而且没有去重。已改为 `sort -u -o FILE FILE`。
- [x] **小版本升级时 kmods 源不改写**：daeuniverse 的 kmods 源路径里带完整版本号（`.../25.12/kmods/25.12.0/...`），25.12.0 升到 25.12.1 时也必须改写。现在只要完整版本号变化就替换版本号，分支号只在跨分支时替换。源文件如果随 sysupgrade 保留了下来，就在原文件里改写，避免新旧两行并存。
- [x] **仓库标签 `@tag` 被去掉**：带标签源里的包只有按 `name@tag` 才能装上。上一轮把 world 里的 `@tag` 去掉是错的，现在保留标签，只按包名做比对。
- [x] **来源未知的包不拦截升级**：之前只打印警告，升级照常继续，这些包会静默丢失。现在 `upgrade` 默认中止并列出包名，`ALLOW_LOSS=1` 才放行。
- [x] **`apk fetch` 失败原因被丢弃**：现在写进 `run.log` 的 `[fetch 包名]` 行。

## 七、设备侧待确认

- [ ] `nikki`、`luci-app-nikki`、`luci-i18n-nikki-zh-cn` 已经装着，但当前源里没有 Nikki 源（`repos.snapshot` 只有 daeuniverse 两行），所以既拿不到离线副本，也没法在线装回。需要重新执行 `autosetup nikki` 补回 Nikki 源。
- [ ] `chinadns-ng`、`dns2socks`、`shadowsocksr-libev-ssr-local`、`tcping` 的所属源不在当前配置里。要么补回对应的源，要么在不需要时卸载。

## 八、第四轮：`autosetup nikki` 真机输出

- [x] **Nikki 源已补回**：`feed.sh` 已写入源和 `nikki.pem`，nikki 的索引也取到了。
- [x] **只要有一个源不可用，`apk update` 就判为整体失败**：daeuniverse 的 kmods 源 `.../25.12/kmods/25.12.0/...` 返回 404（该站现在只有 `kmods/25.12.6/`），于是 `apk update` 返回非零，nikki 步骤被误判为失败。现在只要还有可用的包索引，就按"部分成功"处理：列出不可用的源后继续执行。restore 遇到部分成功时，不会把"源里查不到"判定为包已永久消失。
- [ ] 设备侧：daeuniverse 的源目前没有对应的已装包（`thirdparty.list` 里没有 dae 相关的包）。如果不用 dae，建议从 `customfeeds.list` 删掉这两行；如果要用，升级到 25.12.6 后 kmods 地址会被自动改写为 `kmods/25.12.6/`。

## 九、第五轮：Nikki 补源后的 snapshot

- [x] Nikki 的 3 个包已离线备份，签名公钥变为 3 个。
- [x] **源行仍被打印到终端**：上一轮的 `sort -u -o F F` 修复无效。OpenWrt 的 BusyBox 没有启用 `FEATURE_SORT_BIG`，它接受 `-o` 参数但会直接忽略，结果仍然输出到 stdout，文件也不去重。现在改为先写临时文件，再 `mv` 覆盖。
- [x] **GitHub 类包被列在"源里取不到"里**，看起来像备份出了问题。现在单独归为一类，并提示其中哪些还没有离线副本。
- [ ] 设备侧：`chinadns-ng`、`dns2socks`、`shadowsocksr-libev-ssr-local`、`tcping` 仍然来源未知，`upgrade` 会被拦截。

## 十、第六轮：`FORCE=1 ... argon` 文件归属冲突

- [x] Argon 3.x 把配置工具的文件（`/etc/config/argon`、rpcd、菜单、ACL、`argon-config.js`）并进了主题包，`luci-app-argon-config` 3.x 只剩一个 848 字节的空壳。旧版本是先单独升级主题，这时文件仍归旧的 `luci-app-argon-config` 1.0 所有，于是报 `trying to overwrite ... owned by`。
- [x] 修复：`github_install` 支持同一仓库传入多个包，所有 apk 放进同一个 `apk add` 事务，由 apk 处理文件归属的转移。`step_argon` 和 `restore_sources`（按仓库分组）都改为一次性安装。离线还原本来就是同一个事务，不受影响。
- [ ] 设备侧：主题包处于"1 error"状态，需要用新脚本 `FORCE=1 sh /etc/autosetup/setup.sh argon` 重装一次，或者执行 `apk fix luci-theme-argon`。

## 十一、第七轮：`autosetup upgrade` 被 ASU 拒绝

- [x] 现象：`Status: Repository not allowed: https://nikkinikki.pages.dev/...`，构建返回 400。
- [x] 原因：新版 owut 的 `--repositories-mode` 默认是 `append`，会把 `/etc/apk/repositories.d/` 下除 `distfeeds.list` 外所有文件里的源（这里是 `customfeeds.list` 中的 Nikki 源）连同 `/etc/apk/keys` 一起提交给 ASU。官方服务器不允许任何外部源。
- [x] 修复：owut 支持该参数时，自动追加 `--repositories-mode disable`。第三方包本来就已经用 `-r` 剔除，升级后由还原层装回。
- [ ] 待观察：同次输出里的 `404 ... releases/25.12.6/targets/x86/64/kmods/6.12.71-.../index.json` 是 owut 用旧内核的 kmods 路径去查新版本，看起来不影响构建（随后正常打印了版本对比），修复后再确认一次。

## 十二、严重：升级后全部配置丢失（主机名变回 OpenWrt）

- [x] 排除：owut 调用 `sysupgrade <镜像>` 时不带 `-n`，默认保留配置；本脚本也从不传 `-n`。
- [x] 最可能的原因（待设备证据确认）：在 x86 上，sysupgrade 写完镜像后，`platform_copy_config` 会把配置备份 `cp` 到引导分区（默认只有 16MB，内核已经占去大半），而且**不检查 cp 的返回值**。备份放不下时，升级照常完成，首次启动找不到备份，全部配置被静默丢弃。`/etc/autosetup/apk-cache`（含 nikki/mihomo 二进制）、`github-cache` 以及 OpenClash 的大文件都会撑大备份。
- [x] 修复：`upgrade` 在调用 owut 前先 `sysupgrade -b` 生成一次真实备份，和 `/boot` 的剩余空间比较（留 2MB 余量）。放不下时，先把离线缓存移出备份再检查；仍然放不下就中止升级，并列出备份中最大的文件。owut 失败时会把缓存移回原处。
- [ ] 设备侧：确认引导分区大小与剩余空间、检查有没有残留的 `sysupgrade.tgz`，并恢复配置。

### 十二（续）：原因已确认

- [x] 真机实测：`sysupgrade -b` 生成的备份有 **37.7MB**，而引导分区 `/dev/sda1` 只剩 **9.8MB**。最大的文件来自 OpenClash 的 `/lib/upgrade/keep.d`，它保留了整个 `/etc/openclash/`：GeoIP.dat 18.5MB、clash_meta 13.2MB（`meta-backup` 里还有一份同样大小的）、GeoSite.dat 10.5MB、history 约 3MB。还原层的离线缓存只有约 1MB，不是主因。
- [x] 修复：备份放不下时，先把 `SHRINK_PATHS`（默认是 OpenClash 的 core、GeoIP、GeoSite、Country/ASN.mmdb、history）用 `mv` 暂存到 `/root/.autosetup-hold`。它和 `/etc` 在同一个 overlay 上，只是改名，不占内存，也不在任何保留清单里。暂存后重新检查；仍然放不下，再移出离线缓存；还是放不下就中止，并把所有文件移回。owut 失败或上次中途被打断时，也会自动移回。首启还原完成后，会提示需要重新下载的文件。
- [ ] 设备侧：这次恢复的 PVE 备份不含还原层，需要重新执行 `restore/install.sh`；升级前先拍一个 PVE 快照。
