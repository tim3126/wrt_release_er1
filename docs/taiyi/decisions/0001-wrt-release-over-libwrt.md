# ADR-0001：保留 wrt_release 编排层

- 状态：Accepted
- 日期：2026-09-10
- 范围：JDCloud RE-CS-07（taiyi）生产固件

## 背景

LiBwrt/LibWrt 提供 IPQ60xx、NSS、DTS、镜像和基础软件包。taiyi 固件还需要单设备选择、无 Wi-Fi 策略、代理与 Docker 组合、自定义 feeds、兼容修正和发布验证。

直接在 LibWrt 工作树中维护这些内容，会把上游源码、产品配置和构建产物混在一起。每次升级都难以区分上游变化与本地修改，也容易绕过现有 profile 和产物门禁。

## 决策

- `wrt_release` 继续作为 taiyi 产品构建和发布编排层。
- LibWrt `25.12-nss` 作为固定 commit 的上游输入。
- 生产构建在 E 盘 WSL2 VHDX 内的 ext4 工作区执行。
- `main-nss` 不作为生产基线。
- “最新”表示经过审计、构建和实机验收的最新稳定提交。
- 实验性 CPUIdle/DTS 改动与上游基线迁移分开。

## 后果

收益：

- 设备与软件包策略可版本化。
- 上游更新可审计、可回滚。
- 构建与产物有明确门禁。
- 实验改动不会污染生产基线。

成本：

- 每次上游迁移都要审计命令式 source fixes。
- 需要逐步固定 feeds、custom packages 和构建镜像。
- `wrt_release` 本身需要测试和维护。

## 被否决方案

### 直接使用 LibWrt 工作树生产构建

不采用。它减少了一层入口，但会失去 taiyi 产品配置、custom feeds、source fixes 和验收门禁，实际维护风险更高。

### 使用 main-nss

不采用。它是滚动 SNAPSHOT，Qualcommax/IPQ60xx 当前仍使用 Linux 6.12.94，且 feeds 漂移更大；没有足够的 RE-CS-07 实机收益支撑迁移。
