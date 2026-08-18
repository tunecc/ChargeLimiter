# Comet Design Handoff

- Change: relaxin-roothide-adapt-revisit
- Phase: design
- Mode: compact
- Context hash: ff3ddea32eb8ef43fb2675160242dff6602fabd34851bd59ca41a38a52b94414

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## docs/openspec/changes/relaxin-roothide-adapt-revisit/proposal.md

- Source: docs/openspec/changes/relaxin-roothide-adapt-revisit/proposal.md
- Lines: 1-41
- SHA256: 7c5412bbbf2d1c8b31a9e495f7254b41e8819593a9aaa299b019dc2dec31e02f

```md
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

```

## docs/openspec/changes/relaxin-roothide-adapt-revisit/design.md

- Source: docs/openspec/changes/relaxin-roothide-adapt-revisit/design.md
- Lines: 1-108
- SHA256: 5a3558f2bc7ee1f6283ebb6052fba62fc16eb0461b01f0e70876265173075943

[TRUNCATED]

```md
# Design: 基于 Relaxin 开源源码复核 ChargeLimiter 的 Relaxin roothide 适配

> 参考 `proposal.md` 了解动机。本文只写"如何复核与如何修正"，不重复 why/what。

## Context

ChargeLimiter v1.15.0 在 Relaxin 未开源时做了摸黑适配，核心修复记录在 `docs/superpowers/plans/2026-08-11-relaxin-roothide-daemon-plist-path-fix.md` 与 `CHANGELOG.md` v1.15.0。现在 Relaxin 源码在 `/Users/tune/Downloads/Relaxin`（只读参考，不纳入项目），可以逐条对照确认既有适配是否仍然正确。

当前 ChargeLimiter 的 Relaxin 相关实现分布在：

- `ChargeLimiter/Package_roothide/DEBIAN/{postinst,prerm,control}` — 安装/卸载脚本
- `ChargeLimiter/utils.mm` — `getJBType()`、`resolveRoothidePathByAPI`、`resolveRoothidePreferencesDirByAPI`、`getLibrootJbrootpathFunction`、`restartDaemonForApp_C`、`clRepairDaemonForApp_C`、`spawn()`
- `ChargeLimiter/daemon.mm` — daemon 启动自愈、LaunchDaemon plist 路径修复
- `scripts/build_packages.sh` — roothide 构建链路（native scheme + `Package_roothide` 模板）
- `scripts/roothide.entitlements` — roothide merge entitlements
- `ChargeLimiter/Package_roothide`（构建时拷入 staging）+ `Package/Library/LaunchDaemons/com.chargelimiter.mod.plist`（rootful/roothide 共用 plist 模板）

Relaxin 源码侧关键事实（已核对）：

1. **Relaxin = roothide 架构**，iOS 16.5.1–17.3.1（`README.md`、`Interface/Home/HomeView+TerminalContent+Layout.swift:145`）。
2. **jbroot 命名**：`.jbroot-<brand>`，brand 是 64-bit 值，低字节是高 7 字节的 XOR checksum（`RLXBootstrapRootScanner.m:106-128`）。ChargeLimiter 用 `/.jbroot-` 前缀启发式判定 roothide，不校验 brand checksum —— 一致且足够。
3. **jbroot 物理位置**：primary `/var/containers/Bundle/Application/.jbroot-<brand>`，secondary `/var/mobile/Containers/Shared/AppGroup/.jbroot-<brand>`（`RLXBootstrapRootScanner.m:18-19,138-146`）。secondary 下的 `.jbroot` 符号链接指向 primary root（`RLXBootstrapPreparer.m:466`）。
4. **`/var/jb` 符号链接**：Relaxin 在卸载/重置时删除 `/var/jb`（`RLXBootstrapPreparer.m:665-667`），但开源快照里**没有**显式创建 `/var/jb` 的代码 —— `/var/jb` 的发布在 bootstrap tarball 内（`bootstrap_1900`，由 roothide procursus 提供），Relaxin 只负责维护/删除它。所以 ChargeLimiter 依赖 `/var/jb` 作为 rootless 判定标志、以及 `libroot.dylib` 的候选加载路径 `/var/jb/usr/lib/libroot.dylib`（`utils.mm:358`）在 Relaxin 上仍然成立。
5. **hook 框架**：ElleKit（`Vendor/ElleKit/`、`CydiaSubstrate.framework`，`.this_is_ellekit_not_substrate` 标记文件）。Relaxin 自身的 roothidehooks（pathhook/runningboardd/cfprefsd）用 `substrate.h` + `MSHookFunction`，由 ElleKit 提供。ChargeLimiter 不注入任何进程、不用 hook，与 Relaxin 的 hook 框架无直接冲突。
6. **tweak 注入开关**：`/basebin/.safe_mode` 存在 = 关闭 tweak 注入（`RLXPostJailbreakController.m:127,133-153`）。这是用户级开关，与 ChargeLimiter 无关。
7. **App 进程的 sandbox 放行**：`generate_sandbox_extensions`（`libjailbreak/src/roothider/common.m:393`）为每个进程对 primary jbroot 发 read+exec、对 secondary jbroot 发 read 或 read-write（`writable` 由是否 platform process 决定）。RunningBoard 的 `-[RBProcess _allowedLockedFilePaths]` hook（`roothidehooks/runningboardd.m`）把两个 jbroot 路径加入允许锁定文件列表。
8. **App 进程的 CS_DEBUGGED**：`jbdomain_systemwide.c:389` —— `jbsetting(markAppsAsDebugged)` 为 true 时，App 进程被设为 fullyDebugged（`cs_allow_invalid`）。这是用户在 Relaxin 设置里开关的，ChargeLimiter 不能假设它一定开或一定关。
9. **setuid 提权**：`jbdomain_systemwide.c` 进程 checkin 时，若二进制有 S_ISUID 位，会按文件 uid 设置进程 euid/svuid（`status = proc_read_ucred_identity ... desiredIdentity.euid = sb.st_uid`）。这是 Relaxin 替 ChargeLimiterDaemon 的 `chmod +s` + `platformize_me()` 提权路径提供的内核侧保障。
10. **persona-mgmt**：`systemwide_persona_fix`（`jbdomain_systemwide.c:1000+`）校验调用方持有 `com.apple.private.persona-mgmt` entitlement，且只对**直接子进程**生效（`systemwide_validate_direct_child`）。ChargeLimiter 的 `ChargeLimiter.app.jb.entitlements` 含 `com.apple.private.persona-mgmt: true`，所以 App 用 `SPAWN_FLAG_ROOT` spawn daemon 时能走 persona fix —— 但 v1.15.0 已发现 Relaxin 下 root persona spawn 导致 exec 126，故 roothide 下已避开。**这条复核结论：既有修复正确，保留。**
11. **cfprefsd 重定向**：`cfprefsd.m` 把非 apple 系统域的 preferences plist 路径用 `jbroot()` 重定向到 jbroot 命名空间。ChargeLimiter 的 `resolveRoothidePreferencesDirByAPI` 走 libroot/libroothide 的 `jbroot()` 解析 `/var/mobile/Library/Preferences` —— 与 cfprefsd 重定向目标一致，互补不冲突。
12. **pathhook**：`pathhook.m` 把 `__CFCopyHomeDirURLForUser` 返回的 home 目录在 rootfs 命名空间下重定向到 jbroot。这影响 `NSHomeDirectory()` 等 API 的返回值。ChargeLimiter 如果在 App 进程内用 `NSHomeDirectory()` 拿 mobile home，会自动拿到 jbroot 内的 mobile 路径 —— 需确认 ChargeLimiter 没有绕过这个 hook 自己拼 `/var/mobile`。

## Goals / Non-Goals

**Goals**

- 逐条复核 v1.15.0 摸黑适配点，在 Relaxin 源码层面确认"对/错/可简化/需补"。
- 发现并修正与 Relaxin 源码真正不一致或未覆盖的逻辑。
- 所有既有功能在 Relaxin 上逐项验收通过（安装→重启→卸载、充电控制、加速充电 LPM、设置持久化、daemon 通信、URL Scheme、通知）。

**Non-Goals**

- 不改 daemon 充电控制的 spec 级行为契约（`daemon-charge-control` spec 不变）。若复核中发现需要 spec 级调整，回到 open 阶段补 delta spec。
- 不适配 Relaxin 之外的新越狱；rootful/rootless/TrollStore 保持原行为。
- 不引入 tweak 注入、不挂 hook、不依赖 Relaxin 私有 API（只用 roothide 公共约定：jbroot 命令、libroot/libroothide 动态加载、setuid + platformize）。
- 不把 Relaxin 源码纳入本项目。

## Decisions

### D1: 既有"postinst 用 jbroot 命令解析 plist Program 路径"——保留，源码确认正确

Relaxin 的 `RLXBootstrapFinalizer.m:465` `fixBootstrapSymlink` 会把指向 `.jbroot-<brand>` 的绝对 symlink 改写成相对 `.jbroot/...` 形式，且 `prep_bootstrap.sh` + `updatelinks.sh` 在 jbroot 命名空间内运行。system 域 launchd 在 rootfs 命名空间看不到 jbroot 逻辑路径 —— 这个 v1.15.0 的根因判断与 Relaxin 源码的命名空间设计一致。**保留既有 postinst 逻辑**。

- 备选：改用 `launchctl` 的 `Program` 直接写 `.jbroot-<brand>` 真实路径（不靠 jbroot 命令）。否决：brand 是随机的，postinst 时无法静态知道，必须用 `jbroot` 命令解析。

### D2: 既有"roothide 下 daemon spawn 避开 root persona"——保留，源码确认正确

`jbdomain_systemwide.c` 的 `systemwide_persona_fix` 只校验直接子进程 + persona-mgmt entitlement；但 Relaxin 下 root persona spawn 的 exec 126 是 v1.15.0 真机实测的现象，源码层面 `systemwide_persona_fix` 本身不直接导致 126，更可能是 Relaxin 的 spawn 路径对 persona 99 的处理与 Dopamine 原版有差异。无论根因如何，**既有"roothide 下非 root spawn + setuid 位 + platformize_me() 提权"路径有 Relaxin 源码侧的 setuid checkin 保障（jbdomain_systemwide.c 的 S_ISUID 分支）**，保留。

### D3: `getJBType()` roothide 判定——复核通过，可保留启发式

`getJBType()`（`utils.mm:2685`）的判定顺序：`resolveRoothidePreferencesDirByAPI()` 成功 → ROOTHIDE；否则按可执行路径前缀。Relaxin 下 App 可执行路径在 `/var/containers/Bundle/Application/.jbroot-<brand>/Applications/ChargeLimiter.app/ChargeLimiter`，命中 `path_4 hasPrefix:@".jbroot-"` → ROOTHIDE。daemon 在 LaunchDaemons 路径下走 `realpath("/var/jb")` 判定。**与 Relaxin 源码的 jbroot 物理布局一致，保留。** 不引入 brand checksum 校验（启发式已足够，且 App 进程拿不到 brand）。

### D4: libroot/libroothide 动态加载——复核通过，路径候选需确认

`getLibrootJbrootpathFunction`（`utils.mm:337`）候选加载路径含 `/var/jb/usr/lib/libroot.dylib`（`utils.mm:358`）。Relaxin 的 `RLXBootstrapFinalizer.m:409` 确认 bootstrap tarball 内有 `var/jb/usr/lib/libroot.dylib`，且 finalizer 会 `refreshLibroot`。**保留既有候选列表**。`resolveRoothidePathByAPI` 的 `jbroot` 符号查找路径 `/var/jb/usr/lib/libroothide.dylib`（`utils.mm:944`）同理保留。

- 待真机/构建侧验证：libroot.dylib 在 Relaxin 上是否真的被发布到 `/var/jb/usr/lib/`（开源快照没给 tarball 内容，只有 finalizer 引用）。这是**构建期/装机期验证项**，不是代码改动的阻塞点。

### D5: Relaxin 下 cfprefsd 重定向与 ChargeLimiter 设置持久化的相互作用——需在 design 内记录为验收点

ChargeLimiter v1.15.0 修过"roothide 配置保存后丢失"。Relaxin 的 cfprefsd hook 会把 `com.chargelimiter.mod.plist` 这类非 apple 域 plist 路径重定向到 jbroot。ChargeLimiter 自己也用 `resolveRoothidePreferencesDirByAPI` 解析。**两者目标一致，但需确认 ChargeLimiter 写 prefs 时用的是重定向后的路径，且 daemon（root）与 App（mobile）写的是同一个 jbroot 内的文件**。这是 v1.15.0 修复的核心，复核验收时重点跑"改设置→重启→设置还在"。

### D6: Relaxin 的 pathhook 对 NSHomeDirectory 的影响——已排查，无硬拼

`pathhook.m` 重写 `__CFCopyHomeDirURLForUser`，让 `NSHomeDirectory()` 在 rootfs 命名空间下返回 jbroot 内的 mobile home。ChargeLimiter 在 `utils.mm` 中所有 `/var/mobile/...` 都是**逻辑路径**，走 `resolveRoothidePathByAPI` / `resolveRoothideDataRootByAPI` / `getSharedDataRootPathWithLibroot` 解析成 jbroot 真实路径（`utils.mm:487-494`、`988`），不绕过 hook 硬拼 rootfs 路径。`NSHomeDirectory()` 调用（`utils.mm:398,402,472,741,777`）会自动拿到 pathhook 重定向后的 jbroot 内 mobile home。**无硬拼 `/var/mobile` 绕过 hook 的代码路径，D6 排查通过，无需改动。**

### D7: `markAppsAsDebugged` 与 ChargeLimiter entitlement 的关系——记录为"不依赖"

ChargeLimiter 的 jb entitlements 已含 `platform-application`、`com.apple.private.security.no-sandbox`（roothide merge）、`com.apple.private.persona-mgmt` 等。Relaxin 的 `markAppsAsDebugged` 是给"没有这些 entitlement 的普通 App"放行 invalid pages 用的；ChargeLimiter 作为带完整 entitlement 的 platform app，不依赖 `markAppsAsDebugged` 开或关。**不为此做任何适配**，但在验收时记录"开关 markAppsAsDebugged 都能正常工作"。

```

Full source: docs/openspec/changes/relaxin-roothide-adapt-revisit/design.md

## docs/openspec/changes/relaxin-roothide-adapt-revisit/tasks.md

- Source: docs/openspec/changes/relaxin-roothide-adapt-revisit/tasks.md
- Lines: 1-38
- SHA256: eb2c1c1a6b7f6c247008d44f2322bfd38b67fc3a7f1a38ceefac49f5b4735c27

```md
# Tasks: Relaxin roothide 适配源码复核

> 详见 `proposal.md`（为什么）与 `design.md`（复核结论 D1–D7）。复核结论：v1.15.0 摸黑适配在 Relaxin 源码层面基本正确，D6 已排查通过无硬拼，行为契约不变（`skip_specs: true`）。本 tasks 以"源码复核收尾 + 真机验收"为主，预期代码改动极小或为零。

## 1. 源码复核收尾（只读，产出复核报告）

- [ ] 1.1 复核 `Package_roothide/DEBIAN/postinst`：确认 `jbroot` 命令解析 daemon 真实路径 + plutil 替换 `Program`/`ProgramArguments` + system/foreground 域清理 + `repair_shared_data_permissions` 与 Relaxin `RLXBootstrapFinalizer.m` 命名空间设计一致（D1）
- [ ] 1.2 复核 `Package_roothide/DEBIAN/prerm`：确认 `resolve_roothide_data_dir` brand 校验 + daemon `cleanup_data_container` 兜底 + 域清理与 Relaxin 卸载拓扑一致
- [ ] 1.3 复核 `utils.mm` `getJBType()`（2685）：确认 roothide 判定（`resolveRoothidePreferencesDirByAPI` + `.jbroot-` 前缀 + `/var/jb` realpath）与 Relaxin jbroot 物理布局一致（D3）
- [ ] 1.4 复核 `utils.mm` `getLibrootJbrootpathFunction`（337）+ `resolveRoothidePathByAPI`（907）：确认 libroot/libroothide 候选加载路径与 Relaxin `RLXBootstrapFinalizer.m:409` 一致（D4）
- [ ] 1.5 复核 `utils.mm` `restartDaemonForApp_C`（2745）+ `clRepairDaemonForApp_C`：确认 roothide 下避开 root persona + setuid 位 + `platformize_me()` 提权路径，与 Relaxin `jbdomain_systemwide.c` S_ISUID checkin 一致（D2）
- [ ] 1.6 复核 `utils.mm` 所有 `/var/mobile/...` 均走 jbroot API 解析、`NSHomeDirectory()` 走 pathhook，无硬拼 rootfs 路径（D6 已预排查，本任务做最终确认）
- [ ] 1.7 复核 `daemon.mm` daemon 启动自愈 + `CLRepairRoothideLaunchDaemonPlist`（4297）与 postinst plist 修复语义一致
- [ ] 1.8 复核 `scripts/build_packages.sh` roothide 构建链路（native scheme + `Package_roothide` + `sign_roothide_app` + `set_roothide_control_arch`）与 `scripts/roothide.entitlements` 完整性
- [ ] 1.9 排查 Open Question：Relaxin 下 root persona spawn exec 126 的精确源码根因（`systemwide_persona_fix` 直接子进程校验 vs spawn_hook persona 处理），记录到复核报告，不阻塞

## 2. 必要修正（仅在复核发现问题时执行，可能为零改动）

- [ ] 2.1 若 1.x 复核发现与 Relaxin 源码不一致或可简化点，按 design.md D1–D7 对应决策修正
- [ ] 2.2 若 2.1 触及 spec 级行为变更，回到 open 阶段补 delta spec（与 `skip_specs: true` 决策冲突时以用户确认为准）

## 3. 构建与真机验收（Relaxin roothide）

- [ ] 3.1 在隔离 worktree/分支构建 roothide 包：`scripts/build_packages.sh <VERSION>`，确认 `out/ChargeLimiter_<VERSION>_roothide_arm64e.deb` 产出且 ldid/entitlement/arch 检查通过
- [ ] 3.2 真机 Relaxin 安装：`dpkg -i` 或 Sileo 安装 roothide deb，确认 postinst 无 `fail_install`、daemon plist `Program` 被替换为 `.jbroot-<brand>` 真实路径
- [ ] 3.3 验收 daemon 启动：`launchctl print system/com.chargelimiter.mod` 显示 running；App 内"策略诊断"显示 daemon 在线、越狱类型=roothide
- [ ] 3.4 验收充电控制：插电→停充（IsCharging=NO + PredictiveChargingInhibit=YES）→恢复，电流阈值判定生效（沿用 [[ios-power-re-playbook]] 探针方法论）
- [ ] 3.5 验收加速充电 LPM：开启 acc_charge_lpm → 插电进入充电态即开 LPM；拔线还原；重越狱/userspace reboot 后未开 APP 时 LPM 仍生效（v1.15.2 bootstrap 兜底）
- [ ] 3.6 验收设置持久化（D5 重点）：改设置→重启 userspace→设置仍在；确认 App（mobile）与 daemon（root）写同一 jbroot 内 `com.chargelimiter.mod.plist`
- [ ] 3.7 验收 daemon 通信：App 内"修复 daemon 启动"一键自愈可用；URL Scheme 触发不受 root persona 影响
- [ ] 3.8 验收卸载：`dpkg -r` → prerm 清理 jbroot 数据目录 + 域 bootout，无残留
- [ ] 3.9 验收 `markAppsAsDebugged` 开关：Relaxin 设置里开/关 markAppsAsDebugged，ChargeLimiter 均正常工作（D7，记录不依赖）

## 4. 收尾

- [ ] 4.1 更新 `CHANGELOG.md`：记录本次源码复核结论与（若有）修正
- [ ] 4.2 更新 memory `relaxin-adapt-change`：复核完成状态、真机验收结果
- [ ] 4.3 进入 verify 阶段

```
