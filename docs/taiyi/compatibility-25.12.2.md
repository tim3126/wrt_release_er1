# 25.12.2 锁定候选固件兼容性报告

日期：2026-09-11

## 结论

`25.12.2 / Linux 6.12.103` sysupgrade 镜像已在当前 RE-CS-07 上完成实际升级并稳定启动。升级后设备身份、FIT/rootfs 内容、GPT 分区标签、root/overlay、网络和关键服务均完成只读核验；当前 p10 kernel 与 p11 root member 的 SHA-256 与最终镜像逐字节一致。结论为**升级成功**。这不等于 factory 恢复路径已验证；其他设备刷写前仍须逐台核对并准备恢复条件。

factory 镜像不是整盘 GPT 镜像。它是 `kernel + 6 MiB padding + squashfs + metadata` 的设备安装/恢复封装；未验证对应 U-Boot 恢复命令和分割逻辑前，不得写入整盘或任意分区。

## 候选产物

| 项目 | 结果 |
| --- | --- |
| Board | `jdcloud,re-cs-07` |
| Target | `qualcommax/ipq60xx` |
| LibWrt | `25.12.2 r38135-0c4cd0f9920a` |
| Kernel | `6.12.103` |
| Factory size | `161029826` bytes |
| Factory SHA-256 | `6d3e490c96f96924cdbfb338b6bb8d1bb70b6aedb863b2d5a7fe75a009af942a` |
| Sysupgrade size | `160369447` bytes |
| Sysupgrade SHA-256 | `fb44818678135de67c8f02021357a70972d0ec090edcaa8eb76dd2e196171cc7` |
| LibWrt source | `0fd5daca26aed9cab74b4141690deb5d997383f1` |
| Source-lock SHA-256 | `b6f2d0fb8221cb845419add0a66f3be7c6ec7b1032dc2afac4057a2fad592cd1` |
| Prepared-source SHA-256 | `50caee89bf24e835853a18344bd2d40e904ef93cfbfa26c09fa9ed1cd1a2b44d` |
| Build container image ID | `sha256:671e57ed9daef17d6a23cd0315d04ed287e3307baf3004f031578069021da98b` |
| Exact Linux bundle SHA-256 | `b9f5ea8025b8608ee03853cdf3a7faaca797f3343b9a4dc43c1e1bc788d878ba` |
| Current-system `sysupgrade -T` | 通过；新 hash/size 已在设备端精确复核，测试后 `/tmp` 镜像已删除 |

sysupgrade tar 只包含：

- `CONTROL`：`BOARD=jdcloud_re-cs-07`
- `kernel`：`5566980` bytes
- `root`：`154796032` bytes

## 当前设备证据

| 项目 | 当前值 |
| --- | --- |
| Board | `jdcloud,re-cs-07` |
| LibWrt | `25.12.1 r37978-cd0a06bfd3fd` |
| Kernel | `6.12.94` |
| U-Boot | `2016.01-g42b9707`，构建日期 `2026-08-15` |
| HLOS | `/dev/mmcblk0p10`，标签 `0:HLOS`，12 MiB |
| rootfs | `/dev/mmcblk0p11`，标签 `rootfs`，2 GiB |
| Root | squashfs；overlay 为 loop ext4 |
| eMMC | `DG4008`，`PRE_EOL=0x01`，life A/B=`0x02/0x04` |

当前启动日志未发现 eMMC、ext4 overlay 或 I/O error。寿命字段没有显示临近预警，但它们不能代替升级期间的稳定供电和恢复准备。

## 写盘路径

从当前 25.12.1 发起第一次升级时，sysupgrade 在 ramfs 中使用当前系统携带的旧 `mmc_do_upgrade`：

1. `find_mmc_part '0:HLOS'` 精确解析为 p10。
2. `find_mmc_part rootfs` 精确解析为 p11。
3. kernel 写 p10，root 写 p11。
4. root 成员后的 ext4 overlay offset 由 64 KiB 对齐后的 root 成员尺寸确定。
5. 不改 GPT、p1-p9、APPSBLENV、APPSBL、boot0 或 boot1，也不更新 U-Boot。

新 root 的 squashfs 有效字节为 `154737563`，其后有 `58469` 字节 padding，成员总长正好按 64 KiB 对齐。该布局与旧 helper 的 overlay offset 计算相符。

新固件首启后的后续升级会使用新 `emmc_do_upgrade`/`emmc_copy_config` 路径；其 HLOS/rootfs 标签仍指向 p10/p11。

## FIT 与 factory 布局

新 FIT 为 AArch64，load/entry 均为 `0x41000000`，默认配置为 `config@cp03-c4`，包含 `jdcloud_re-cs-07` DTB。当前 p10 的只读字符串同样显示 RE-CS-07、`config@cp03-c4` 和 Linux 6.12.94。

factory 前 `5566980` 字节与 sysupgrade kernel 完全一致。factory 从 6 MiB offset 开始的 squashfs 有效内容与 sysupgrade root 完全一致；有效内容后是 `807` 字节 metadata。这解释了两种镜像尾部差异，不能据此互换使用。

## 配置迁移风险

刷写前已生成当前系统的标准配置与关键分区恢复包，并在另一台机器解包验证内部校验。恢复包本身已验证完整，但 raw GPT/分区写回流程仍未演练。

Docker/dockerd 已从 `27.3.1` 升级到 `29.6.1`，daemon、overlayfs storage driver 和 cgroupfs 正常；当前报告 0 个 containers。PPPoE、NSS、LAN/WAN、代理规则和 overlay 已通过首轮实机核验，Docker 业务数据和容器 DNS 仍需按实际使用情况核对。

## 实机升级后核验

当前设备已运行 `LibWrt 25.12.2 r38135-0c4cd0f9920a / Linux 6.12.103`，board 为 `jdcloud,re-cs-07`，target 为 `qualcommax/ipq60xx`。核验时已连续运行约 4 小时；p10/p11 标签与尺寸未变，root 为只读 squashfs，overlay 为可写 loop-ext4。

最终 sysupgrade 内 kernel member SHA-256 为 `09bdef803d417e4be3932220e2c4be9bafc7009c46768b062fc907e9a205ad26`，root member SHA-256 为 `5f2fb6405fae8e7a988abe237b339bed78ee43025b8673bc1e89ca9bd0b066e2`。当前设备 p10 前 `5566980` bytes 与 p11 前 `154796032` bytes 分别得到相同 hash；active `/dev/loop0` offset 也为 `154796032`，证明运行内容与最终 strict 镜像一致。

LAN、PPPoE WAN、默认路由、DNS 和公网探测正常；Nikki/Mihomo 与 dockerd 29.6.1 正常运行，NSS modules 已加载。启动与系统日志未发现 kernel panic、Oops、I/O、eMMC、squashfs、ext4、OOM 或 segfault。`wan6` down 和 frpc crash loop 是升级前已存在的问题。Lucky、EasyTier、sing-box 的 UCI 开关均为 disabled，因此未运行符合配置。

AdGuardHome 当前只有 LuCI 管理包和 `/etc/init.d/AdGuardHome`，没有下载后的二进制/配置目录；Docker daemon 正常但当前报告 0 个 containers。若升级前预期使用这两项，需单独核对业务数据和启用流程。CPUIdle 仍为 `none`，核验时温区约 70–74 C，符合迁移前结论：6.12.103 baseline 未解决独立 CPUIdle/温度问题。

刷机后 Dropbear host key 已更新；重新授权 DBX 时观察到 ED25519 指纹 `SHA256:M5LLzEc8IHK2KwNpn/FGDwlQbgykW21CGizo6aaniDI`。

## 2026-09-13 后续只读运行复核

后续重启后的 DBX 复核仍为 `r38135-0c4cd0f9920a`。系统约 2 小时 uptime 时无 OOM、崩溃、eMMC I/O 或 F2FS 错误，DDNS-Go named procd instance 正常。Docker 是操作者主动停止/排除项，但本次重启后 dockerd 因 `S99dockerd` 再次运行且没有 containers；这说明单次 stop 不持久，不代表 Docker 本身故障。IPv6 已由操作者明确禁用，odhcpd 的 no-public-prefix/RA lifetime 0 与当前策略一致。

FRPC 的 `S99frpc` 同样恢复并在默认 `127.0.0.1:7000` 配置下 crash 6 次。根因是上游 init 无显式 enabled guard 且 respawn=1。长期修复 commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23` 保留 FRPC 插件，新增默认关闭的 UCI/LuCI gate，并将 FRPC 三包改为 firmware-only，防止公共在线升级覆盖该契约。包含该修复的本地候选已在 `E:\OTHERCODE\openwrt\artifacts\taiyi\taiyi-r8-3a9603d-dockerman-frpc-local-candidate-20260913T065900Z` 完成 clean build、最终 rootfs、6 个 index 签名、250 个 APK 完整性和 Windows export hash 验收。操作者随后确认修复有效；独立 DBX 复核因设备 SSH host key 变化返回 `Unknown server key`，未自动更新信任，因此新的设备 firmware identity 与未配置/启用/再禁用证据仍待重新授权后补录。

内核继续报告 eMMC primary/alternate GPT 元数据不一致，但分区、squashfs 和 loop-F2FS 均正常且没有块错误。此项保留为恢复/存储专项，不得在运行设备上未经备份、恢复演练和授权执行分区表修复。

## 升级后 LuCI/helper 与软件源回归

升级后 LuCI 状态页的 CPU 使用率与温度一度显示 `?`。直接调用 `ubus call luci getCPUUsage` 和 `ubus call luci getTempInfo` 同样返回 `?`；thermal sysfs 可正常读取约 `71400`，证明传感器与内核接口正常。根因是 `/sbin/cpuusage` 和 `/sbin/tempinfo` 被以 CRLF 打包，shebang 实际为 `#!/bin/sh\r`，内核因此无法找到解释器。相同问题还影响 `/etc/init.d/smp_affinity`、两份 PBR helper 和未完成的 `/etc/uci-defaults/991_custom_settings`。

当前设备已先备份原文件到 `/root/taiyi-hotfix-20260911-luci-opkg`，再将运行所需 helper 转为 LF。修复后 CPU RPC 返回 CPU/HWE/ECM 数据，温度 RPC 返回 `CPU: 71.4°C`。`991_custom_settings` 若成功执行还会删除 `dropbear.main.DirectInterface`；为避免后续重启意外扩大 SSH 暴露，ER1 运行态已移除该 pending uci-default，构建编排也不再为 ER1 安装它。Dropbear 未重启，现有限定保持不变。

`opkg update` 的另一故障来自生成的 `distfeeds.conf`：它把 LibWrt `25.12.2` 直接映射为 ImmortalWrt release，并声明未发布的 custom/NSS feeds；这些 `Packages.gz` URL 均返回 404。`dl.openwrt.ai` 虽有 25.12/6.12.103 包索引，但没有 `Packages.sig`，不满足本机启用的 `option check_signature`，因此未采用，也未关闭签名校验。

当前设备的 `distfeeds.conf` 已改为无活动源的说明性配置，旧列表已清理；签名检查保持启用，`opkg update` 返回 0。其准确含义是“不再请求无效仓库”，不是“在线安装已经可用”。在发布兼容签名仓库前，新增软件包应通过固件重建完成。

构建编排已为无扩展名 shell patches 增加 LF 属性和 CR 字节回归检查，并为当前 opkg R1 安装一次性 distfeeds 防护脚本。该脚本只删除本固件生成的 ImmortalWrt 25.12.2 错误源及其对应缓存，写入采用失败即保留的原子路径；管理员后来配置的其他签名源及其缓存不会被覆盖。固定构建容器中的 `tests/taiyi-build-invariants.sh` 已通过。原 final 固件与 exact bundle 不作覆盖，它们仍精确对应当前 p10/p11 的已部署基线，但包含本节所述回归；未来候选必须重新构建并生成新的 provenance、大小与 SHA-256。

## APK 迁移方向（本地候选已构建，尚未部署）

R8 本地候选已改用 LibWrt 25.12 的原生 APK 路径。变更只作用于 `jdcloud_er1_libwrt` profile：最终配置启用 `CONFIG_USE_APK`、`apk-openssl`、签名包、TLS 证书校验、ImmortalWrt/OpenWrt keyring 和支持 APK 的 LuCI Package Manager，并明确排除 opkg 与旧 `luci-lib-ipkg`。这不是在当前运行设备上原地安装另一个包管理器；只有经过授权刷入并通过实机门禁的 sysupgrade 才能完成设备迁移。

计划中的运行时 `distfeeds.list` 只启用 NJU 镜像的 `aarch64_cortex-a53` 架构级 `base`、`luci`、`packages`、`routing` 和 `telephony` 仓库。已验证这五个路径均发布 `packages.adb`。公共 `targets/qualcommax/ipq60xx` 与 `kmods` 仓库必须省略，因为它们不是由 Taiyi 固定的 LibWrt/NSS 构建产生，kernel ABI 与 NSS 组合不匹配；管理员维护的 `customfeeds.list` 保持不变。

R8 的 LuCI 受控插件通道不允许 `apk add`、删除或全量升级。它只接受同一审核包组中的显式升级请求，自动加入该组当前已安装成员，并在模拟计划完整解析且所有变更仍属于该组、未触及固件基线时执行。OAF 使用 `destan19/OpenAppFilter` 锁定源码；`appfilter`、`luci-app-oaf` 和翻译可作为用户态组在线更新，但 `kmod-oaf` 固定在固件中。HomeProxy、DDNS-Go、AdGuardHome、CUPS、Docker 与 eMMC Health 等已审核用户态组采用相同规则。当前 `customfeeds.list` 仍由管理员维护；在部署独立签名的 Taiyi add-on feed 并完成离线验收前，自定义插件不应被视为可在线更新。若 solver 带入 kernel、任意 `kmod-*`、NSS/ECM、libc/musl、base-files、procd、netifd、firewall4、APK/keyring、其他固件包、基线包或跨组依赖，必须拒绝整笔事务并通过下一版完整固件交付。禁止使用公共 target/kmod 包规避失败。

commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23` 的本地候选已经完成 clean build、最终 rootfs/image 检查、build public key 绑定、6 个本地 index 签名、250 个 APK 完整性和 Windows export hash 验收。这仍不代表当前设备已迁移或已批准生产升级。正式交付前还必须完成 NJU 运行态签名/离线 APK 求解、授权实机升级、备用/可恢复设备、FRPC 与 Dockerman 专项、网络/NSS、完整回滚和 soak 验证。

## 刷写前备份

已在 `E:\OTHERCODE\openwrt\taiyi-backup\20260911-152727` 保存当前运行系统的恢复包。tar 大小为 `180003840` bytes，SHA-256 为 `5c2764b01578464887be6526af4dd68017d9e24a89e7745e2e66a5d390735f89`；本地解包后的内部 `SHA256SUMS` 已全部通过。

恢复包包含标准 `sysupgrade -b` 配置、当前 GPT 主/备、p01-p10、eMMC boot0/boot1 及按活动 loop offset 截取的 `154075136`-byte p11 只读 squashfs 基线。它不包含正在写入的 loop-ext4 overlay 后半段。目录已关闭 NTFS ACL 继承；包内含配置凭据和 p09 ART 设备身份，不能公开分发。该备份提高恢复能力，但 raw 分区/GPT 写回流程尚未演练，不能据此取消串口/U-Boot 恢复前置条件。

## 剩余发布门禁

当前设备升级已成功，但以下项目仍未通过，不能据此宣称所有同型号设备均可无恢复准备地升级：

- 尚未复核历史回滚固件和 U-Boot 归档的全部恢复用途。
- 尚未验证串口中断和 U-Boot 恢复命令。
- 尚未在另一台设备/eMMC 做干净升级与保留配置升级。
- 尚未完成 24 小时稳定性测试及 AdGuardHome/Docker 业务数据核对。
- factory 的具体安装/恢复命令尚未验证。

禁止使用 `sysupgrade -F`，禁止将 factory 写入整个 eMMC，禁止在分区目标不明确时手工 `dd`。
