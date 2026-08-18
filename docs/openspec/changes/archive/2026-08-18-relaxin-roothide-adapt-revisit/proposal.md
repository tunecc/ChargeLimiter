# Proposal: 基于 Relaxin 开源源码复核 ChargeLimiter 的 Relaxin roothide 适配

## Why

ChargeLimiter 在 v1.15.0「正式适配 relaxin 越狱（原生 roothide）」时，Relaxin 越狱尚未开源，所有适配都是摸着石头过河：根据真机故障现象反推根因，逐个补丁修复（daemon 离线 126、设置保存丢失、jbroot 路径兜底等）。这种黑盒适配导致修复点零散、对 Relaxin 行为的认知可能有偏差，部分「乱七八糟的问题」未必被根因修复。

现在 Relaxin 已开源（`/Users/tune/Downloads/Relaxin`），可以从源码层面精确确认此前摸黑适配的每一处假设是否仍然成立，并发现与现有逻辑真正不一致、需要重新适配的点，把所有功能在 Relaxin 上做到完美复现。

## What Changes

- **复核 v1.15.0 摸黑适配点**：逐条对照 Relaxin 源码，确认下列既有适配逻辑是否正确、是否仍必要、是否可简化：
  - postinst 用 `jbroot` 命令把 LaunchDaemon plist 的 `Program`/`ProgramArguments` 解析为 `.jbroot-<brand>` 真实路径（`Package_roothide/DEBIAN/postinst`）
  - daemon spawn 在 roothide 下避开 root persona，靠 setuid 位 + `platformize_me()` 提权（`utils.mm` `restartDaemonForApp_C` / `clRepairDaemonForApp_C`）
  - `getJBType()` 的 roothide 判定（`utils.mm:2685`：`resolveRoothidePreferencesDirByAPI()` / `.jbroot-` 前缀 / `/var/jb` realpath）
  - libroot/libroothide 动态加载解析 jbroot 路径（`utils.mm` `getLibrootJbrootpathFunction` / `resolveRoothidePathByAPI`）
  - URL Scheme 避开 root persona
  - prerm 卸载时 jbroot 数据目录的安全删除与域清理
- **重新适配与 Relaxin 源码不一致或未覆盖的点**：基于源码确认的 Relaxin 行为，修正或补齐与现有逻辑不一致之处。重点候选（待 design 阶段源码核对后定稿）：
  - Relaxin 是否提供 tweak 注入与 `/usr/lib/TweakInject` 约定（ChargeLimiter 当前不用 tweak，但需确认无冲突）
  - `markAppsAsDebugged` / `CS_DEBUGGED` 对 App 进程的影响与 ChargeLimiter 现有 entitlement/spawn 策略的相互作用
  - Relaxin 的 `rootfs()` / `jbroot()` / `JBROOT_PATH` 语义与 ChargeLimiter 既有路径解析的边界
  - `.jbroot-<brand>` brand 校验算法（XOR checksum）是否与 ChargeLimiter 的 `/.jbroot-` 前缀启发式判定一致
  - Relaxin bootstrap 的 `/var/jb` symlink 拓扑与 ChargeLimiter 对 `/var/jb` 的依赖
- **正向适配验证**：所有现有功能（充电控制、加速充电 LPM、设置持久化、daemon 通信、通知/URL Scheme 等）在 Relaxin 上逐项验收，确保完美复现。

## Capabilities

### New Capabilities
<!-- 本次不新增 capability；适配是对既有 daemon-charge-control 在 Relaxin 平台上的正确性复核，行为契约不变 -->
（无）

### Modified Capabilities
- `daemon-charge-control`: 本次不改 daemon 充电控制的 spec 级行为契约；若复核中发现 Relaxin 平台特有的行为偏差需要 spec 级调整，再在此处补充。**若复核结论为「行为契约不变，仅实现/打包/脚本侧修正」**，则在 `.openspec.yaml` 设 `skip_specs: true` 并改为纯实现型 change。

## Impact

- **构建/打包**：`scripts/build_packages.sh`（roothide 构建链路）、`ChargeLimiter/Package_roothide/DEBIAN/{postinst,prerm,control}`、`scripts/roothide.entitlements`
- **运行时**：`ChargeLimiter/utils.mm`（`getJBType` / `resolveRoothidePathByAPI` / `resolveRoothidePreferencesDirByAPI` / `getLibrootJbrootpathFunction` / spawn persona 逻辑）、`ChargeLimiter/daemon.mm`（daemon 启动链路自愈、LaunchDaemon plist 路径修复）
- **依赖**：libroot / libroothide 动态加载；Relaxin 提供的 `jbroot` 命令、systemhook、launchdhook、RunningBoard `_allowedLockedFilePaths` hook
- **平台范围**：仅 Relaxin roothide；rootful / rootless / TrollStore 保持原行为
- **参考源码（只读）**：`/Users/tune/Downloads/Relaxin`（不纳入本项目，仅作为适配事实源）
