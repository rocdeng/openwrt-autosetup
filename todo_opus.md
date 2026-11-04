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
