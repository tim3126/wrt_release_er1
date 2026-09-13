# 构建与发布流程

## 发布标识

建议格式：

```text
taiyi-25.12.2-k6.12.103-r1
```

每个发布必须绑定：

- `wrt_release` 完整 commit。
- LibWrt 分支、tag 和完整 commit。
- 内核版本。
- 所有 feed revisions。
- `wrt_core/source-locks.env` 及其 SHA-256；它固定不属于 `feeds.buildinfo` 的关键 custom source。
- 容器镜像 digest（若使用容器）。
- `config.buildinfo`、`feeds.buildinfo`、`version.buildinfo`。
- manifest、profiles.json 和 SHA-256。

## 阶段 1：发现与审计

1. 用 `git ls-remote` 获取远程 heads/tags，不直接更新生产分支。
2. 在本地只读比较当前固定提交与候选提交。
3. 重点审计 RE-CS-07 DTS、IPQ60xx image、eMMC upgrade、NSS、PPPoE、netfilter、F2FS 和 rpcd。
4. 明确记录无关的 Wi-Fi、其他 SoC 和其他架构变化。
5. 确认候选提交来自 `25.12-nss` 稳定线。

## 阶段 2：迁移分支

1. 从已发布的 `wrt_release` commit 创建独立迁移分支。
2. 更新 canonical LibWrt URL、固定 commit 和预期内核。
3. 审计 `update.sh` 中每个 source fix：保留、适配、删除或对 ER1 跳过。
4. 固定本次发布使用的 feeds 与关键 custom package revision。
5. 不加入 CPUIdle 或其他实验补丁。

## 阶段 3：配置门禁

先执行不产生固件的检查：

```bash
./build.sh jdcloud_er1_libwrt config_preview
./build.sh jdcloud_er1_libwrt debug
```

必须确认：

- 只选择 `jdcloud_re-cs-07`。
- 内核版本与预期一致。
- 无 Wi-Fi 驱动、固件和 hostapd/wpad。
- NSS、PPPoE、Docker、Nikki 和规定应用存在。
- 禁止应用没有重新出现。
- source fix 没有 fuzz、错误上下文或静默跳过。
- Taiyi 最终配置启用 `CONFIG_USE_APK=y`、`CONFIG_PACKAGE_apk-openssl=y`、签名包与 TLS 证书校验。
- Taiyi 最终配置不包含 `CONFIG_PACKAGE_opkg=y` 或 `CONFIG_PACKAGE_luci-lib-ipkg=y`。
- LuCI Package Manager 与 ImmortalWrt/OpenWrt APK keyring 已选入。
- FRPC 三包仍在镜像中但分类为 firmware-only；默认 config、init guard 与 LuCI enable flag 必须作为同一 source contract 通过零 fuzz和语义验收。
- `jool`/`openvswitch` 的未选 `kmod-nf-conntrack6` 警告和 `trojan-plus` 的未选 `boost-system` 警告只可在 profile 明确未选择这些包时记录放行；任一包进入 `.config` 或 solver closure 都必须失败。

## 阶段 4：干净构建

1. 使用 WSL ext4 中的全新工作区。
2. 运行上游 prerequisite 检查。
3. 下载阶段和编译阶段使用受控并行度。
4. 保存完整日志；长时间无输出不能自行判断成功。
5. 编译失败先保留首个错误和工作区，不盲目清理重跑。

推荐初始并行度：

```text
DOWNLOAD_JOBS=16
BUILD_JOBS=8
```

迁移分支已实现这两个变量并校验其必须为正整数；GitHub Actions 使用更保守的 `8` / `4`。

`container_resume` 不重建或更新容器，只复用已存在的本地 image ID。准备阶段写入的 build-state 同时绑定 release input SHA-256、source-lock SHA-256、LibWrt commit、最终 `.config` SHA-256、应用 source fixes 后的 prepared-tree SHA-256、fragments、container base 和 image ID；任一项变化时 resume 必须失败并重新执行正常 prepare/build。

## 增量编译与失败恢复

增量编译用于同一个 clean candidate workspace 内的失败恢复，不能把旧 workspace 改名后冒充新 commit 的 clean build。

1. 先完成符合 [提交规范](../commit-conventions.md) 的最终 commit message，再创建 WSL ext4 snapshot。构建期间发生 amend、rebase 或重新提交时，即使 tree hash 相同，旧构建的 provenance 也只属于旧 commit；停止旧 worker/container，从新 commit 创建新 snapshot。
2. 新候选依次执行 `config_preview`、`container_debug` 和 `container_resume`。`container_debug` 生成 prepared source 与 build-state；`container_resume` 只能在所有 identity 字段精确匹配时使用。
3. 可跨 clean workspace 复用的默认缓存只有 `dl`。导入前验证来源候选 `SHA256SUMS`、LibWrt commit、source-lock、config 和 container base；源/目标 `dl` 只允许目录与普通文件。使用 `rsync --ignore-existing` 后仍由 `make download` 校验实际使用文件的上游 hash。
4. `.ccache` 只有在 builder image ID、编译器/工具链、target、config 和 source identity 均已证明兼容时才可复用；任一身份变化就明确记录 `ccache_reused=no`。不得迁移旧 `build_dir`、`staging_dir`、`bin`、`firmware` 或 prepared source 到新候选。
5. 并行 `make -j8` 失败时保留首个失败包、完整日志和 workspace，不先 clean。单包 target 必须由实际 `package/feeds` 链接与 Make target 确认，不能按 feed 目录猜测。需要串行诊断时使用 `BUILD_JOBS=1` 与 `V=s`；优先通过正常外层入口 resume，若直接进入容器，必须从 build-state 注入全部 release 与 container identity，否则门禁应拒绝。
6. 串行 resume 成功只有在后续 `package/install`、`target/install`、`package/index`、image/rootfs gate、profiles 和 SHA-256 全部通过时才算完成；provenance 必须记录实际最终并行度。不能把“失败包后来单独成功”替代完整 image build。
7. 长构建使用 `setsid`/`nohup` 独立 worker，并配置 Pi 可见 monitor，状态与日志保存在 ext4。停止作废任务时既要终止 monitor/worker，也要检查 Docker daemon 中是否有脱离 client 的残留构建容器，只停止已确认属于该 workspace 的容器。
8. Linux 输出的 `SHA256SUMS` 与 `sha256sums` 在 NTFS 大小写不敏感目录会冲突。导出时分别保留原内容为不冲突名称，在目标目录外生成新的导出 manifest，再移入目标并重验。
9. 自动关机只能排在 clean build、完整静态验收、候选导出与目标端 hash 复核之后。编译或验收失败时不得关机，以便保留现场；强制关机必须由操作者单独授权。

运行设备上的临时 hotfix 与长期固件修复必须分开记录。DDNS-Go init 的实例名热修复可以先恢复 LuCI 状态显示，但要进入长期基线，仍需由包含 source-fix 的新 commit 走完上述 clean build；旧 hotfix 可能被未来 package upgrade 覆盖。

## GitHub 云编译与发布

- `Build WRT` 是候选构建入口，可手动选择 `jdcloud_er1_libwrt`，生成可下载 artifact，但不创建 Release。
- `Release Taiyi Firmware` 是 taiyi 专用生产入口，只允许手动触发，固定使用默认 fragments，并通过 `taiyi-production` environment 执行发布 job。
- 构建 job 只有 `contents: read` 权限；发布 job 不执行上游构建代码，只下载已经通过门禁的 artifact，并拥有最小 `contents: write` 权限。
- ER1 门禁要求恰好一个 `factory.bin` 和一个 `sysupgrade.bin`、不允许其他 `.bin`，并校验 SHA-256 和内嵌的 `jdcloud,re-cs-07` metadata。
- Release 白名单只包含这两种镜像、manifest、profiles、三份 buildinfo、provenance 和 SHA-256。
- workflow 使用固定 commit 的官方 Actions，不执行远程 `curl | sudo bash` 环境脚本。

生产 release 不接受 GitHub native runner 的 `BuildContainerImageId: native`。`Release Taiyi Firmware` 只会调用带 `use_audited_builder=true` 的构建路径，并要求 GitHub repository variables 提供：

- `TAIYI_BUILDER_IMAGE`：受控 Registry 的完整 immutable OCI reference，必须以 `@sha256:<64-hex>` 结尾。
- `TAIYI_BUILDER_MANIFEST_DIGEST`：与 image reference 后缀完全相同的 OCI manifest digest。
- `TAIYI_BUILDER_CONFIG_IMAGE_ID`：拉取后由 Docker inspect 得到、已审计的 local config image ID。

生产构建会实际 `docker pull` 该 immutable reference、inspect config image ID，并在该 image 内执行 `build.sh`。release job 随后将三个字段与 `BUILD_PROVENANCE.txt` 精确比对。任一变量缺失、digest 不匹配、pull/inspect 失败或 provenance 不一致时必须失败；不得用环境变量伪造 image ID，也不得为了发布临时降低这些门禁。Registry 只读认证、image 审计/签名、`taiyi-production` reviewer 和分支保护属于 GitHub/Registry 配置，必须在首次 production dry run 前另行完成和验证。

factory 镜像用于文档规定的安装或恢复路径；运行中的 OpenWrt 升级只能使用 sysupgrade 镜像。

## 阶段 5：静态验收

比较旧、新版本：

- diffconfig 和完整 `.config`。
- manifest 的包增删与版本变化。
- feed revisions。
- 内核模块和 DTB。
- kernel/rootfs/sysupgrade 文件尺寸。
- sysupgrade tar 内容、metadata 和支持设备列表。
- eMMC `platform.sh`/`emmc.sh` 路径。
- `profiles.json` 中必须只有预期的 ER1 profile。
- SHA-256 必须在归档后再次验证。
- Linux 产物同时包含 `SHA256SUMS` 和上游 `sha256sums`；复制到 NTFS 时会发生大小写文件名冲突。必须使用保留原名的 tar 归档，或将小写文件改名并同步更新总校验表后复验。
- `profiles.json` 必须是合法 JSON，且 `.profiles` 恰好只含 `jdcloud_re-cs-07`，其 `supported_devices` 必须精确为 `jdcloud,re-cs-07`。
- 提取后的 rootfs 必须包含 `/usr/bin/apk`、`/lib/apk/db`、`/etc/apk/keys`、`distfeeds.list` 和 `customfeeds.list`，且不得包含活动 opkg 包管理器。
- rootfs 必须包含可执行且受语义门禁保护的 `/etc/uci-defaults/995_configure_taiyi_apk_repositories`。镜像内初始 `distfeeds.list` 可以是上游默认值，但必须在隔离目录实际执行 995；执行后的 `distfeeds.list` 只能包含已批准的五个 NJU `aarch64_cortex-a53` 架构仓库，不得包含公共 `targets/qualcommax/ipq60xx` 或 `kmods` URL。不能把首次启动前的文件误当成运行态生效仓库。
- 必须用镜像内实际 keyring 对五个 NJU `packages.adb` 做签名验收；HTTPS 可用不能替代包签名验证。
- 在离线或可丢弃测试环境执行 `apk update`、查询和 `--simulate add`；不得在生产路由器首次验证，也不得执行 `apk upgrade`。

静态验收失败时不得把镜像交给刷写阶段。

## 2026-09-13 R8 Dockerman/FRPC 本地候选

commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23` 已从 WSL ext4 clean snapshot `/home/ubuntu/workspaces/taiyi-r8-3a9603d` 完成 `container_resume`。LibWrt source commit 为 `0fd5daca26aed9cab74b4141690deb5d997383f1`，kernel 为 `6.12.103`，builder config image ID 为 `sha256:7f905f359da67ea6e7d3b8b8a217cb72757fc7e6360a9bbdf6a95b6b938a4631`。构建使用 `DOWNLOAD_JOBS=16`、`BUILD_JOBS=8`，从 `32239a5` 工作区只导入 42,351 个普通 `dl` 文件并由构建系统重新校验；builder image ID 不同，因此 `.ccache`、`build_dir`、`staging_dir`、`bin` 和旧 firmware 均未复用。

内置门禁通过 package/target install、package index、image metadata、rootfs、manifest、profiles 与 SHA-256。独立验收从最终 sysupgrade 解出 3,138 个 inode，并以本次 immutable builder image、`--user 0:0`、`--cap-add MKNOD`、`--network none` 复核 `/dev/console` 为 `5:1`/`0600`。隔离执行 995 后得到严格五条 NJU user-space feed，没有 public targets/kmods，disabled add-on feed 未改变 customfeeds。最终 rootfs 中 FRPC default-disabled/firmware-only、Dockerman provider rendering、DDNS-Go named instance 与 PBR TLS fail-closed contract 均通过；rootfs build public key 与 provenance 一致，6 个本地 `packages.adb` 签名及 250 个 APK 完整性全部通过。

NTFS-safe 候选位于 `E:\OTHERCODE\openwrt\artifacts\taiyi\taiyi-r8-3a9603d-dockerman-frpc-local-candidate-20260913T065900Z`。目录含 12 个普通文件；Windows 端重新解析 11 条 `SHA256SUMS` 并重算全部成员后通过。OpenWrt 小写 `sha256sums` 以 `OPENWRT_IMAGE_SHA256SUMS` 保存，WSL source aggregate 以 `WSL_SOURCE_SHA256SUMS` 保存：

- factory SHA-256: `c8696eab22e23db680c53237f371914ed8bd842653a5aa6bda0934554f212f25`
- sysupgrade SHA-256: `22984cd4e479f78b4c2d77061cc7c9b2dc9eb77d2367bc5a349131fb09c3b875`

独立验收中曾出现 stale builder-ID expectation、非 root device extraction、pre-first-boot feed-state assumption、minified LuCI semantic matching 与 apk-tools option/trust 语义五类 harness 失败；这些均在新 evidence 目录保留后纠正，未修改、重打包或重编译 firmware bits。最终通过证据为 `/home/ubuntu/workspaces/taiyi-r8-3a9603d-control/validation-final-7/VALIDATION.txt`。

该目录是本地候选，不是生产发布。候选导出时未执行 push、tag、release、feed publication、刷机、GPT 修改、设备配置写入或 Windows shutdown。操作者随后确认修复有效，但本会话通过 DBX 发起的只读复核因设备返回 `Unknown server key` 被安全阻断；未自动信任新 host key，也未取得新的 firmware identity、FRPC/ubus 与 Dockerman UI/solver 证据。因此该反馈记录为操作者验收，不替代重新授权后的独立实机证据；push/tag/release/feed publication 仍未执行，生产提升仍需完成身份确认、FRPC disabled/enabled、Dockerman UI/solver、OAF、网络/NSS、恢复与 soak 门禁。

## 阶段 6：实机与发布

实机步骤见 [刷写与恢复门禁](flash-recovery.md)，完整功能检查见 [验收矩阵](validation.md)。全部通过后才能：

1. 创建 release/tag。
2. 将产物和证据复制到不可变发布目录。
3. 保留上一个已知可用固件作为回滚版本。
4. 更新本目录的当前基线。
5. 将部署结果同步到 taiyi Obsidian 运维笔记。
