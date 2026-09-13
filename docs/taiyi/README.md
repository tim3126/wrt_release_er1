# Taiyi Firmware Documentation

本目录是 JDCloud RE-CS-07（taiyi）二开固件的版本化文档入口。文档与构建脚本、设备配置和发布提交一起维护。

## 目标

- 以最少的长期维护成本构建可追溯的 taiyi 固件。
- 使用已审计的最新稳定上游，而不是在构建时追逐浮动 HEAD。
- 将构建成功、镜像正确和实机可用分成独立门禁。
- 将刷写风险控制在有备份、有恢复路径、可停止的流程内。

## 架构结论

```text
wrt_release（产品构建与发布编排）
    -> 固定提交的 LiBwrt/LibWrt 25.12-nss（上游源码）
    -> jdcloud_er1_libwrt 配置与 fragments
    -> 干净 WSL2 ext4 工作区构建
    -> 静态产物验收
    -> 备用机或恢复路径已验证的 RE-CS-07 实机验收
    -> 发布并保留回滚固件
```

生产基线使用 `25.12-nss`。`main-nss` 是滚动 SNAPSHOT，不作为 taiyi 的日常生产基线。

## 文档索引

- [提交规范](../commit-conventions.md)
- [架构与维护边界](architecture.md)
- [WSL2 编译环境](build-environment-wsl.md)
- [构建与发布流程](build-release.md)
- [受控插件通道](plugin-channel.md)
- [软件包来源审计](package-source-audit.md)
- [刷写与恢复门禁](flash-recovery.md)
- [25.12.2 候选兼容性报告](compatibility-25.12.2.md)
- [验收矩阵](validation.md)
- [ADR-0001：保留 wrt_release 编排层](decisions/0001-wrt-release-over-libwrt.md)

## 当前基线

| 项目 | 已部署/已独立确认基线 | R8 状态 |
| --- | --- | --- |
| `wrt_release` | R6 commit `058958548314380ca82810e244cde866a0943387` | 功能代码 commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23`；clean candidate 已归档 |
| LibWrt 分支 | `25.12-nss` | `25.12-nss` |
| LibWrt 提交 | `0fd5daca26aed9cab74b4141690deb5d997383f1` | 保持固定 |
| 内核 | Linux 6.12.103 | Linux 6.12.103 |
| 包管理器 | APK；五个 NJU 架构 feeds，kernel/NSS/kmod 随固件 | APK 受控插件组；public target/kmod feeds 继续禁止 |
| 候选/设备状态 | R6 controlled reboot 与 T+1h 已通过，较长 soak 未完成 | R8 rootfs/image/index/APK/NTFS 验收通过；操作者确认修复有效，独立 DBX 复核因新 SSH host key 待重新授权 |
| 设备 | `jdcloud,re-cs-07` | `jdcloud,re-cs-07` |

R8 候选的 provenance 仍绑定功能代码 commit `3a9603d`；之后的纯文档提交不得用于重标候选。创建 tag、推送或实机反馈也不改变既有镜像身份。

## 强制原则

1. 不直接从浮动分支 HEAD 生成生产固件。
2. 不在同一次基线迁移中加入 CPUIdle、频率或其他实验性 DTS 改动。
3. 不把编译通过视为可刷写。
4. 未通过镜像校验、备份校验和恢复演练时，不在主路由器刷写。
5. 不承诺刷写零风险；通过正确镜像、断电保护和可验证恢复路径降低风险。
6. 每次发布保留源码、feeds、配置、manifest、buildinfo、哈希和回滚固件。
7. APK 不允许全量升级；受控插件通道只允许经过 solver 验证的审核包组更新，kernel/NSS/kmod 随固件。

## 文档职责

- 本目录记录可执行、可评审、与代码版本绑定的工程流程。
- Obsidian 的 `20-基础设施/taiyi-openwrt.md` 记录实机故障、部署结果和运维证据。
- 两处结论冲突时，以实机证据为事实依据，并通过代码评审同步更新本目录。
