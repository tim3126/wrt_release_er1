# 刷写与恢复门禁

## 风险声明

任何 eMMC 固件刷写都不能保证零变砖风险。目标是通过镜像身份、设备状态、备份、断电保护和已验证恢复路径，将风险降到可接受水平。

当前 taiyi 已更换 eMMC。旧 eMMC 的 `mmcblk0p18` I/O 故障不再直接代表当前介质状态，但刷写前仍必须重新采集当前 eMMC 的健康证据，不能沿用旧结论。

## 禁止刷写条件

出现任一项即停止：

- 镜像不是 `jdcloud,re-cs-07` 的 sysupgrade 镜像。
- LibWrt、`wrt_release`、feeds 或镜像 SHA-256 无法追溯。
- `sysupgrade -T` 校验失败。
- 当前 eMMC、loop ext4 overlay 或块设备日志出现 I/O error。
- 既有回滚固件或 U-Boot 归档无法读取、无法核对哈希，或恢复方法没有经过验证。
- U-Boot/串口/救砖路径没有经过验证。
- 设备供电不稳定或升级期间可能断电。
- 新 eMMC sysupgrade 路径尚未在备用介质/设备验证。
- 当前路由器是唯一网络入口且没有旁路恢复方案。

## 刷写前证据

已有的回滚固件和 U-Boot 归档不需要每次重复制作，但刷写前必须确认其存储位置可访问、文件可读取、哈希与记录一致，并且对应 RE-CS-07 当前恢复方法。无法完成复核时停止刷写。

每次升级仍需离线保存或记录：

1. `sysupgrade -b` 配置备份，并在另一台机器解包验证。
2. 当前 `ubus call system board`、内核、软件包、mount、block info。
3. 当前 GPT/分区布局、启动分区状态和 U-Boot 环境摘要，用于确认恢复目标；已有完整备份时不重复制作。
4. 当前 LAN/WAN MAC 与分区身份信息。
5. 串口接线参数、U-Boot 中断方法和现有恢复资料的位置。
6. 新镜像的 manifest、buildinfo、profiles 和 SHA-256。

配置备份可能含 PPPoE、代理、VPN、SSH 和密码材料，按敏感数据保存，不提交到 Git。

## 镜像预检

在路由器上只做验证、不写入：

```sh
sha256sum /tmp/<taiyi-sysupgrade.bin>
sysupgrade -T /tmp/<taiyi-sysupgrade.bin>
```

必须将计算结果与发布归档比对。不要使用 `-F` 强制绕过 board/image 检查。

factory 镜像与 sysupgrade 镜像用途不同。运行中的 OpenWrt 只使用通过验证的 sysupgrade 镜像；不要因文件名相近混用 factory 镜像。RE-CS-07 factory 是 `kernel + 6 MiB padding + rootfs + metadata`，不是整盘 GPT 镜像；未验证对应 U-Boot 安装/恢复命令前，禁止把它写入整盘或任意猜测的分区。

## 首次升级策略

1. 先在可恢复的 RE-CS-07 或备用 eMMC 验证 6.12.103。
2. 第一次基线迁移优先验证干净升级，再验证配置保留升级。
3. 确认新通用 `emmc_do_upgrade`、`emmc_copy_config`、rootfs 和 loop ext4 overlay 行为。
4. 升级期间使用稳定电源，不操作电源和网线。
5. 串口保持可用，并记录完整启动日志。
6. 未完成首启验收前，不将设备恢复为唯一主路由。

## 回滚触发条件

出现以下情况立即回滚：

- U-Boot 无法加载 kernel 或 rootfs。
- overlay 未创建、只读、offset 错误或 ext4 报错。
- PPPoE、NSS 或交换端口不能恢复。
- Docker/nftables 导致管理地址不可达。
- 重启后配置丢失。
- 持续内核崩溃、watchdog reset 或异常温升。

回滚使用上一个已知可用且哈希已验证的固件。若 sysupgrade 不可用，按已验证的串口/U-Boot 恢复手册操作；未确认分区目标时不得尝试手写 `dd`。

## 变砖风险控制的核心

- 正确设备和正确镜像类型。
- 不使用 `sysupgrade -F`。
- 刷写前验证 eMMC 与镜像。
- 稳定供电。
- 已验证的 bootloader 恢复路径。
- 确认既有回滚固件、U-Boot/恢复资料可读且哈希匹配，并保存本次配置备份。
- 先实验设备，后主路由。
