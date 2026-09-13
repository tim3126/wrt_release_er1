# 架构与维护边界

## 组件职责

### LiBwrt/LibWrt

上游源码提供：

- Qualcommax/IPQ60xx 内核、DTS、镜像布局和升级脚本。
- QCA NSS 驱动、ECM 和相关内核补丁。
- ImmortalWrt 基础系统、LuCI 与发布 feeds。

上游必须以分支加完整 commit 固定。生产使用 `25.12-nss`，不直接跟随 `main-nss`。

### wrt_release

产品编排层提供：

- `jdcloud_er1_libwrt` 单设备配置。
- NSS、Docker、代理与 ER1 overrides fragments。
- custom feeds 和必要的源码兼容修正。
- WSL/容器构建入口。
- profile、manifest、profiles.json 与 SHA-256 验证。

生产定制应进入 `wrt_release`，不要长期直接修改克隆出来的 LibWrt 构建树。

## 工作区布局

WSL2 的 ext4 虚拟磁盘物理存放在 `E:\WSL2\distros\Ubuntu-24.04\ext4.vhdx`。推荐布局：

```text
/home/ubuntu/workspaces/taiyi-wrt-release/    # wrt_release 工作副本
/home/ubuntu/workspaces/taiyi-wrt-release/libwrt-er1-25.12-nss/
/home/ubuntu/workspaces/taiyi-wrt-release/firmware/
/home/ubuntu/releases/taiyi/<release-id>/     # 不可变发布归档
```

不要在 `/mnt/e/OTHERCODE/...` 内执行完整 OpenWrt 编译。该路径是 Windows 盘的 9p/DrvFS 挂载，元数据操作、大小写语义和大量小文件性能不适合 OpenWrt 构建。只将最终发布归档复制回 Windows 文件系统。

## 最新版本策略

“最新固件”定义为：

1. 发现新的 `25.12-nss` stable tag 或候选 commit。
2. 记录旧、新提交和上游变更。
3. 审计与 taiyi 相关的内核、DTS、NSS、eMMC、PPPoE、netfilter 和 F2FS 变化。
4. 在独立迁移分支更新固定 commit。
5. 完成干净构建、静态差异和实机回归。
6. 验收后发布为新的 taiyi 版本。

分支 HEAD 只能用于发现更新，不能作为生产构建输入。

## 变更分层

每次发布只允许一个主要变量组：

- 上游稳定基线升级；或
- 包与功能策略变更；或
- 实验性内核/DTS 变更。

CPUIdle DTS 实验必须位于独立分支和独立固件标识中，不能混入 6.12.103 基线迁移。这样温度、功耗和稳定性差异才可归因。

## 可复现性状态

当前已固定：

- LibWrt、上游 packages/LuCI/routing/telephony/video feeds。
- `nss_packages`、`sqm_scripts_nss` 与两个 Bandix feeds。
- Nikki、eMMC Health、HomeProxy、Go、AdGuardHome、Lucky、Diskman、Dockerman、tcping 等 retained custom sources。
- Ubuntu 24.04 容器基础镜像 digest；每次构建另记录最终本地 container image ID。

当前剩余缺口：

- 容器内 `apt-get update` 仍使用当时的 Ubuntu 仓库状态；最终 image ID 可识别环境，但不能替代可长期拉取的不可变工具链镜像。
- R8 已从 clean 功能代码 commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23` 构建并绑定 provenance。之后的纯文档提交不改变既有候选身份，也不能把既有镜像重标为新 HEAD；正式 Registry 发布仍需使用已审计、digest-pinned 的 builder 并重新执行对应门禁。

每次发布必须保存 source-lock hash、container base/image identity、`feeds.buildinfo`、`config.buildinfo`、`version.buildinfo` 和 manifest，不能只记录 LibWrt commit。
