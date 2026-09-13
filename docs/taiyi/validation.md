# 验收矩阵

每项记录命令、预期、实际结果、日志路径和执行时间。`通过` 必须有证据，不能只写主观结论。

## 2026-09-13 运行策略与 DBX 只读复核

当前操作者策略：Docker 由操作者主动停止并从本轮业务回归中排除；IPv6 明确禁用，因此没有 LAN public prefix 和 RA lifetime 0 不作为缺陷。FRPC 插件必须保留，但未配置时默认停用，未来配置后可显式启用。

复核设备运行 `LibWrt 25.12.2 r38135-0c4cd0f9920a`，并非待构建的 `3a9603d`。约 2 小时 uptime 时负载、可用内存和 overlay 正常；未发现 OOM、segfault、soft lockup、watchdog reset、eMMC I/O error、F2FS corruption 或 NSS failure。DDNS-Go 保持 `instances.ddns-go.running=true`，没有 `instance1`。

| 观察 | 结论与后续 |
| --- | --- |
| FRPC 启动 6 次后进入 crash loop | 默认配置为 `127.0.0.1:7000`、init 无 enable guard 且 respawn=1。长期 source fix 为 commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23`；尚未刷入，必须通过新 rootfs 和实机未配置/启用/再禁用回归。 |
| dockerd boot enabled、daemon running、0 containers | 与先前手动 stop 不同，说明单次 stop 不跨重启；用户未要求永久 disable，因此不修改固件，只按 operator-stopped/excluded 记录，不声明 Docker runtime 已验收。 |
| odhcpd 持续报告无 LAN public prefix | 与 IPv6 明确禁用一致，不阻断；若以后启用 IPv6，重新检查 WAN6 PD 与 LAN RA。 |
| Nikki 启动期 3 次 rpcd timeout | 当前 status 立即返回且 ubus running，列为观察项；候选重启后若持续出现或影响 LuCI 再升级为故障。 |
| Dropbear 3 条 PTY error | `/dev/pts` 与 `ptmx` 当前正常，之后无复发；观察，不作为 blocker。 |
| `cron.err` 29 条 | 其中 22 条为正常 command event，未匹配到 command failure；这是 facility/severity 表现，不按 29 次任务失败统计。 |
| GPT primary/alternate metadata mismatch | 7.28 GiB eMMC 的分区与 loop-F2FS 当前可用、无块错误，但生产签署前需单独评估。未经完整 raw GPT 备份、恢复演练和授权不得运行 `parted` 或写分区表。 |
| USB PHY dummy regulator、overlay null UUID、NSS DDR `kern.alert` | 当前均为启动信息/已有平台告警，未伴随 USB、overlay 或 NSS 功能失败；继续在每个候选启动日志中对比。 |
| Docker containerd v2/IPsec/swap-limit/git warnings | 普通 daemon 启动不受阻；仅在恢复 Docker 业务时按实际需要处理，不为消除日志而加入 kernel/package。 |

## 2026-09-13 `3a9603d` 静态候选验收

本地候选目录为 `E:\OTHERCODE\openwrt\artifacts\taiyi\taiyi-r8-3a9603d-dockerman-frpc-local-candidate-20260913T065900Z`，绑定 commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23`、LibWrt `0fd5daca26aed9cab74b4141690deb5d997383f1` 与 builder image ID `sha256:7f905f359da67ea6e7d3b8b8a217cb72757fc7e6360a9bbdf6a95b6b938a4631`。本次只复用 42,351 个经构建系统重验的 `dl` 普通文件，未复用 `.ccache` 或任何旧 build/staging/bin/firmware tree。

| 检查 | 结果 |
| --- | --- |
| 内置 build/rootfs/image/manifest/profile/hash gate | 通过 |
| 最终 sysupgrade rootfs 解包 | 通过；3,138 inodes，`/dev/console` 为 character device `5:1`、mode `0600` |
| 995 first-boot repository 隔离模拟 | 通过；严格五条 NJU user-space feed，无 public targets/kmods，disabled add-on feed 未改变 customfeeds |
| FRPC | 三包存在且 firmware-only；config 默认 `enabled=0`，init bool schema/guard 和 LuCI enable flag 均进入最终 rootfs |
| Dockerman dependency rendering | strict comparator、compatible/installed provider preference、ambiguity 与 selected-provider recursion 均进入压缩后的最终 LuCI JS |
| DDNS-Go/PBR | named procd instance 与 TLS fail-closed helper 通过 |
| APK trust/integrity | rootfs build public key 与 provenance 一致；6/6 本地 index 签名通过，250/250 APK 完整性通过 |
| NTFS export | 12 个普通文件；Windows 端 11 条 aggregate manifest 及全部成员哈希通过 |

factory SHA-256 为 `c8696eab22e23db680c53237f371914ed8bd842653a5aa6bda0934554f212f25`，sysupgrade SHA-256 为 `22984cd4e479f78b4c2d77061cc7c9b2dc9eb77d2367bc5a349131fb09c3b875`。最终独立证据保存在 `/home/ubuntu/workspaces/taiyi-r8-3a9603d-control/validation-final-7/VALIDATION.txt`；导出目录中的 `VALIDATION.txt` 为自包含摘要。

验收过程中五类失败均属于 harness 校准：误用早期 builder ID、非 root 无法创建设备节点、把 first-boot 前 feed 文件误作生效状态、用未压缩源码 marker 匹配最终 LuCI JS、混淆 signed index 与单 APK integrity 的 apk-tools 参数。每次失败都阻断导出并保留 evidence；最终通过前未修改 firmware bits。

该结果先将产物限定为本地候选。候选导出后，操作者反馈本轮修复有效；本会话尝试通过 DBX 只读确认实际 firmware、FRPC gate、Dockerman 最终 JS 与 DDNS-Go instance，但 SSH transport 因 `Unknown server key` 安全失败，未自动接受新 key。因此当前结论分为两层：操作者功能验收为通过，独立设备身份和逐项证据仍待 DBX 重新授权后补录。push/tag/release、feed publication 与 shutdown 均未执行；FRPC enabled/再 disabled、OAF ABI/服务/回滚、网络/NSS、恢复和 soak 仍是生产 blocker。

## 静态产物

| 检查 | 通过条件 |
| --- | --- |
| Source identity | LibWrt 与 `wrt_release` 完整 commit 匹配发布记录 |
| Target | 只有 `jdcloud_re-cs-07` |
| Kernel | 版本与门禁一致 |
| Packages | required/forbidden manifest 校验通过 |
| Wi-Fi | RE-CS-07 镜像不含 ath11k firmware、kmod-ath11k、hostapd/wpad |
| Image metadata | sysupgrade image 支持正确 board，无强制刷写需求 |
| Size | kernel/rootfs 未超过镜像和分区限制 |
| Hash | 发布目录内 SHA-256 重新校验通过 |

## 启动与存储

| 检查 | 通过条件 |
| --- | --- |
| Cold boot | U-Boot、kernel、rootfs 无错误，管理地址可达 |
| Warm reboot | 连续 3 次重启正常 |
| eMMC | 无 timeout、CRC、I/O error 或 reset |
| Overlay | 当前预期的 loop ext4 可读写、重启后持久，offset 与 squashfs/padding 布局一致 |
| Config retention | 保留配置升级后预期配置仍在 |
| Clean upgrade | 不保留配置升级后能形成干净 overlay |

## 网络与 NSS

| 检查 | 通过条件 |
| --- | --- |
| Ethernet | LAN/WAN 端口、速率、双工与计数正常 |
| PPPoE | 首拨、断线重拨、重启后恢复正常 |
| IPv4/IPv6 | 与当前运营商能力和产品策略一致 |
| NSS ECM | 实际建立加速连接，不只检查软件包存在 |
| Bridge/VLAN | 网络拓扑与防火墙 zone 正确 |
| nftables | 无规则加载错误、重复规则或 Docker 冲突 |

## 服务

| 检查 | 通过条件 |
| --- | --- |
| LuCI/ubus | 登录、状态和配置写入正常 |
| Nikki | 配置校验、透明代理、DNS 与重载正常 |
| HomeProxy/PBR | 不与 Nikki 形成规则或端口冲突 |
| Docker | daemon、bridge、容器 DNS 和外网访问正常 |
| Samba/CUPS | 启停、访问与重启恢复符合策略 |
| DDNS/Cloudflared/FRP | 只启用已配置服务，无崩溃循环；FRPC 默认 `enabled=0` 时不得创建 procd instance，配置完成并设为 `1` 后才运行 |
| DDNS-Go LuCI status | `/etc/init.d/ddns-go status`、PID、监听端口与本机 HTTP 均正常；ubus 必须为 `instances.ddns-go.running=true`，不能只相信页面文字 |
| Online plugin upgrade | solver 事务只含审核组，但升级后仍逐项验证 daemon、init/procd、LuCI、翻译和配置保留；solver 通过不能证明未声明的运行时接口兼容 |
| Dependency detail | 递归树只展开唯一兼容 provider；多 provider 标记为 solver choice 且不合并未选子依赖。页面 warning 必须与 `apk --simulate` 交叉验证，不能据此安装 legacy/kmod 包 |

## 在线升级专项回归

每个审核组首次在线升级至少记录升级前后包版本、solver 计划、实际 transaction、服务 PID/ubus/端口、LuCI 页面状态和配置文件 hash。不得输出配置内容或提供商凭据。

DDNS-Go 当前兼容契约是 service 名与 procd instance 均为 `ddns-go`。如果 LuCI 更新后页面显示未运行而进程/端口存在，读取 `ubus call service list '{"name":"ddns-go"}'`，区分 `instances.instance1` 与 `instances.ddns-go`。长期固件 source-fix 必须保证 init 只有一个 `procd_open_instance ddns-go`；无名、未知名、重复或混合实例布局都应在构建准备阶段失败。设备热修复后需验证：

- init status 为 running，PID 在重启后重新建立。
- `instances.ddns-go.running=true`。
- 配置的监听端口存在，本机 HTTP 可响应。
- `/etc/config/ddns-go` 和 DDNS-Go YAML 的哈希前后不变。
- 原 init 已 root-only 备份，可恢复后重启回滚。

热修复通过不等于长期交付完成；包含 source-fix 的最终 commit 仍需新 clean snapshot、完整 build、rootfs 检查和实机升级验收。后续 DDNS-Go package upgrade 可能覆盖设备侧 init，升级后必须重复上述检查。

FRPC 在 Taiyi 中保留为 firmware-only 插件。rootfs 必须同时包含 `frpc`、`luci-app-frpc` 和中文翻译，但默认 `/etc/config/frpc` 的 init section 为 `enabled=0`。未配置状态启动或重启后应验证：

- `/etc/init.d/frpc status` 不为 running，ubus 没有 running instance。
- 日志中没有新的 FRPC respawn 或 crash loop。
- LuCI 启动设置显示服务未启用，保存普通配置不能绕过 enabled gate。
- 设置真实 server、认证和至少一个有效 proxy 后，将 enabled 设为 `1`，服务应创建 procd instance 并连接；再设回 `0` 应停止且后续重启保持不运行。
- LuCI/APK 在线升级必须拒绝 FRPC 三包；FRPC 只能随保留该 init/LuCI 契约的审核固件更新。

Dockerman 依赖详情回归使用候选 `luci-app-dockerman 26.236.50544~cb5d434`。在安装版本 `0.5.26-r1` 上，预期 solver 计划只包含安装 `docker-compose`、安装 `ucode-mod-socket` 与升级 `luci-app-dockerman`。页面不得因未选中的 legacy provider 报 `kmod-ipt-fullconenat`、`kmod-nf-conntrack6`、`libip4tc2` 或 `libip6tc2` 缺失；这些包也不得进入计划。还需分别验证：

- 唯一兼容 installed provider 优先递归，available 同名或替代 provider 不贡献子错误、安装数和大小。
- installed provider 不满足版本而唯一 available provider 满足时，展示 upgrade/install 状态并递归 available metadata。
- versioned virtual provide 使用其声明版本；无版本 provide 不满足带版本约束。
- `<` 与 `>` 不接受相等版本，`<=` 与 `>=` 接受相等版本。
- 多个不同的兼容 provider 保持 solver choice，不按数组顺序选择；完全等价记录先去重。
- 直接缺失和没有兼容 provider 仍显示错误。
- frontend 展示通过后仍由 backend policy 在同一把锁内重新模拟、验证并执行，不能复用 UI 推断。

## 稳定性与性能

| 检查 | 通过条件 |
| --- | --- |
| Idle | 空闲 30 分钟无错误，记录所有 thermal zones |
| Forwarding | 持续转发测试无 crash、soft lockup 或明显丢包 |
| Soak | 至少 24 小时无 watchdog、OOM、I/O error |
| CPUFreq | `schedutil` 与频率驻留符合预期 |
| CPUIdle | 基线迁移只记录现状，不把缺失误判为回归 |
| Temperature | 与同环境旧基线比较，不以单次绝对温度归因 |

## 发布门禁

只有以下条件全部满足才能提升为生产版本：

- 静态产物全部通过。
- 刷写与恢复门禁全部通过。
- 关键网络、NSS、overlay 和 Docker 全部通过。
- 24 小时稳定性测试通过。
- 回滚固件和恢复资料已离线验证。
- 发布证据已归档且不含秘密。
