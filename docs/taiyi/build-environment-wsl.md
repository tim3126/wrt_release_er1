# WSL2 编译环境

## 2026-09-10 审计结果

| 项目 | 结果 | 判断 |
| --- | --- | --- |
| 发行版 | Ubuntu 24.04.4 LTS / WSL2 | 合适 |
| Linux | `6.18.33.2-microsoft-standard-WSL2` | 合适 |
| CPU | 32 逻辑处理器 | 充足 |
| WSL 内存 | 15 GiB | 足够，但必须限制并行度 |
| Swap | 4 GiB | 可用，不应依赖 swap 承担正常编译峰值 |
| ext4 根盘 | 1007 GiB，约 576 GiB 可用 | 充足 |
| Windows E 盘 | 约 316 GiB 可用 | 归档空间充足 |
| Docker | 29.7.2，daemon 可连接，overlayfs | 可用 |
| 原生编译依赖 | GCC、G++、make、flex、bison、unzip 等缺失 | 尚未就绪 |

结论：硬件、WSL2 和 ext4 存储条件良好。完成一次受控依赖安装并限制并行度后，适合作为 taiyi 的长期编译环境。

## 推荐模式

日常生产构建优先使用 WSL2 ext4 中的原生 Ubuntu 工作区。原因：

- 路径和权限模型与 OpenWrt 预期一致。
- 少一层 Docker volume、用户映射和镜像更新逻辑。
- 工作区仍物理存放在 E 盘的 WSL VHDX 内。
- 更容易保留和检查完整构建日志、dl 缓存和产物。

Docker 保留为 CI 对照环境，不作为唯一生产构建路径。当前容器基础镜像已固定 digest，并记录实际构建后的本地 image ID；但容器构建仍执行 `apt-get update`，Ubuntu 软件包仓库状态未固定为快照。在发布可长期拉取的不可变工具链镜像前，它仍不等同于完全可复现环境。`container_resume` 只能复用已准备的本地 image ID，若 image ID 与准备状态不同必须失败。

## 一次性准备

安装软件属于环境变更，需要在 WSL 交互终端中由操作者输入 sudo 密码。仓库提供了可审计、幂等的 [setup-taiyi-wsl.sh](../../scripts/setup-taiyi-wsl.sh)，只使用 Ubuntu 已配置的 APT 仓库，不执行远程 `curl | bash`，也不执行系统 `full-upgrade`：

```bash
cd /home/ubuntu/workspaces/taiyi-wrt-release
./scripts/setup-taiyi-wsl.sh
```

脚本会验证 Ubuntu 24.04、ext4 工作区和关键编译命令。安装后仍必须运行 LibWrt 自身的 prerequisite 检查；不能仅凭 apt 成功判断环境可用。若 Ubuntu 包名与上游要求不兼容，应显式适配，不能安装来源不明的替代包。

## 并行度

当前迁移分支的 `build.sh` 已支持经过正整数校验的并行度变量。首次构建建议：

```text
DOWNLOAD_JOBS=16
BUILD_JOBS=8
```

未显式设置时，脚本会按 CPU 数自动计算，并分别封顶为下载 16、编译 8。GitHub Actions 固定使用下载 8、编译 4。验收一次完整构建的峰值内存后再调整；失败诊断可显式使用 `BUILD_JOBS=1`，脚本不再在并行构建失败后自动重跑。

## 工作区规则

1. 在 `/home/ubuntu/workspaces/taiyi-wrt-release` 中 clone/checkout。
2. 不从 `/mnt/e` 直接编译。
3. 构建前记录 `git status`，不覆盖未提交修改。
4. 新基线第一次构建使用全新 source/build/staging 目录。
5. `dl` 缓存若复用，必须让构建系统重新校验哈希。
6. 最终只复制发布归档到 Windows E 盘。
7. 不在构建日志中记录令牌、代理凭据或完整环境变量。

## 缓存与增量恢复矩阵

| 数据 | 新 clean candidate 是否可复用 | 必要条件 |
| --- | --- | --- |
| `dl` | 可以 | 来源候选 hash 已验证；LibWrt/source-lock/config/container base 已比对；只复制普通文件；`make download` 重新校验 |
| `.ccache` | 条件允许 | builder image ID、编译器/工具链、target、config 与源码身份全部一致；否则禁止 |
| 当前 workspace 的 `build_dir`/`staging_dir` | 仅同一 commit 失败恢复 | build-state 全字段一致，并使用 `container_resume`；commit amend/rebase 后立即作废 |
| 旧候选的 `build_dir`/`staging_dir`/`bin`/`firmware` | 禁止 | 不跨候选复制，不用历史产物伪造新 provenance |

同一个 clean workspace 的并行失败可以保留增量树后串行 resume。先记录失败包与日志，不自动 clean；使用实际 Make target，`BUILD_JOBS=1` 和 `V=s` 获取确定错误。直接绕过外层脚本进入容器时，必须从 `.wrt-release-build-state` 注入 `WRT_RELEASE_COMMIT`、tree/input hash、builder image ID/ref/manifest 等全部身份；缺少任何字段的 mismatch 是安全门禁结果，不是源码编译失败。

预计超过 60 秒的 build 使用脱离会话的 worker 与独立 monitor。worker 状态、PID 和日志放在 ext4 control 目录，monitor 定时确认 PID 与日志增长并在终态回传。终止已作废任务时，不能只停止 monitor：还要终止 worker，并用精确 builder/workspace 证据检查 Docker daemon 中是否留下孤立容器。

## 历史构建清理与 VHD 回收

先删除明确判定为旧候选的 Taiyi workspace，不使用未限定的通配删除。至少保留最新 clean candidate、对应 control/build-state、Windows 导出 artifact 和 Git commit；非 Taiyi workspace、Docker images、active containers 与 volumes 默认不在清理范围内。root container 创建的文件应由一次性 root container 从 `/home/ubuntu/workspaces` 的精确 bind mount 删除，避免宿主用户权限导致半清理。

清理顺序：

1. 记录 `df -h`、每个候选 `du -sh`、当前 builder container 和 Windows artifact/Git 回滚点。
2. 删除逐项列出的旧 workspace/control/evidence，并验收只剩预定 keep-set。
3. `docker builder prune --all --force` 只回收 unused build cache；除非另有授权，不使用 `docker system prune`，不删除 image、container 或 volume。
4. 以 root 执行 `fstrim -av`。此时 ext4 空闲已经可供 WSL 使用，但 Windows 上的动态 `ext4.vhdx` 物理长度通常不会立即下降。
5. 离线 compact 前记录全部 running container ID、名称、状态与 restart policy。只有它们可以接受短暂停机时才执行 `wsl --shutdown`；使用管理员 DiskPart 对已确认的 distro VHDX 做 readonly attach、`compact vdisk` 和 detach。
6. 重新启动 distro，比较 VHDX 大小、`df`、Docker cache、保留 workspace 和 compact 前后的 container ID；所有原运行容器必须恢复，健康检查仍在 starting 时不能直接宣告服务通过。

2026-09-13 的受控清理删除了 40 个旧 Taiyi 路径，只保留 `taiyi-r8-32239a5` 与其 control。ext4 已用从 665 GiB 降到 131 GiB，Docker build cache 从 326.8 GiB 降到 0；trim 后离线 compact 将观察到的 VHDX 从 683.17 GiB 降到 171.92 GiB，compact 前的 15 个 container ID 均恢复。该数值只作为本次证据，不是后续固定阈值。

随后为最终 commit `3a9603dd5b9aa32cc30383a22793a1fc50c17f23` 新建 `/home/ubuntu/workspaces/taiyi-r8-3a9603d` 与对应 control。它从保留的 `32239a5` 工作区只复制 42,351 个 `dl` 普通文件；source/config/base identity 相容，但 builder image ID 不同，因此明确未复用 `.ccache`。正式构建、独立 rootfs/APK 验收和 NTFS 导出完成后，`3a9603d` 是最新有用候选 workspace；`32239a5` 暂留作已验证下载缓存和前一候选回滚证据，后续清理仍需逐项确认且不得删除 Windows artifact。

## 容量规划

为单个干净 Qualcommax 构建预留至少 80 GiB；迁移期间同时保留旧、新两个工作区时预留至少 160 GiB。2026-09-13 清理后 ext4 可用约 825 GiB，满足该要求；后续以每次构建前的实际 `df` 为准。
