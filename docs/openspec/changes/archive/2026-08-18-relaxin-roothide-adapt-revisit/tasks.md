# Tasks: Relaxin roothide 适配源码复核

> 详见 `proposal.md`（为什么）与 `design.md`（复核结论 D1–D7）。复核结论：v1.15.0 摸黑适配在 Relaxin 源码层面基本正确，D6 已排查通过无硬拼，行为契约不变（`skip_specs: true`）。本 tasks 以"源码复核收尾 + 真机验收"为主，预期代码改动极小或为零。

## 1. 源码复核收尾（只读，产出复核报告）

- [x] 1.1 复核 `Package_roothide/DEBIAN/postinst`：确认 `jbroot` 命令解析 daemon 真实路径 + plutil 替换 `Program`/`ProgramArguments` + system/foreground 域清理 + `repair_shared_data_permissions` 与 Relaxin `RLXBootstrapFinalizer.m` 命名空间设计一致（D1）
- [x] 1.2 复核 `Package_roothide/DEBIAN/prerm`：确认 `resolve_roothide_data_dir` brand 校验 + daemon `cleanup_data_container` 兜底 + 域清理与 Relaxin 卸载拓扑一致
- [x] 1.3 复核 `utils.mm` `getJBType()`（2685）：确认 roothide 判定（`resolveRoothidePreferencesDirByAPI` + `.jbroot-` 前缀 + `/var/jb` realpath）与 Relaxin jbroot 物理布局一致（D3）
- [x] 1.4 复核 `utils.mm` `getLibrootJbrootpathFunction`（337）+ `resolveRoothidePathByAPI`（907）：确认 libroot/libroothide 候选加载路径与 Relaxin `RLXBootstrapFinalizer.m:409` 一致（D4）
- [x] 1.5 复核 `utils.mm` `restartDaemonForApp_C`（2745）+ `clRepairDaemonForApp_C`：确认 roothide 下避开 root persona + setuid 位 + `platformize_me()` 提权路径，与 Relaxin `jbdomain_systemwide.c` S_ISUID checkin 一致（D2）
- [x] 1.6 复核 `utils.mm` 所有 `/var/mobile/...` 均走 jbroot API 解析、`NSHomeDirectory()` 走 pathhook，无硬拼 rootfs 路径（D6 已预排查，本任务做最终确认）
- [x] 1.7 复核 `daemon.mm` daemon 启动自愈 + `CLRepairRoothideLaunchDaemonPlist`（4297）与 postinst plist 修复语义一致
- [x] 1.8 复核 `scripts/build_packages.sh` roothide 构建链路（native scheme + `Package_roothide` + `sign_roothide_app` + `set_roothide_control_arch`）与 `scripts/roothide.entitlements` 完整性
- [x] 1.9 排查 Open Question：Relaxin 下 root persona spawn exec 126 的精确源码根因（`systemwide_persona_fix` 直接子进程校验 vs spawn_hook persona 处理），记录到复核报告，不阻塞 — **已解，见 design §2**

## 2. 必要修正（仅在复核发现问题时执行，可能为零改动）

- [x] 2.1 若 1.x 复核发现与 Relaxin 源码不一致或可简化点，按 design.md D1–D7 对应决策修正 — **执行：roothide 包架构 arm64 → arm64e（commit ed813fc），属小偏差，未触及 spec**
- [x] 2.2 若 2.1 触及 spec 级行为变更，回到 open 阶段补 delta spec（与 `skip_specs: true` 决策冲突时以用户确认为准） — **N/A：2.1 为打包正确性修正，无 spec 级行为变更**

## 3. 构建与真机验收（Relaxin roothide）

- [x] 3.1 在隔离 worktree/分支构建 roothide 包：`scripts/build_packages.sh <VERSION>`，确认 `out/ChargeLimiter_<VERSION>_roothide_arm64e.deb` 产出且 ldid/entitlement/arch 检查通过
- [x] 3.2 真机 Relaxin 安装：`dpkg -i` 或 Sileo 安装 roothide deb，确认 postinst 无 `fail_install`、daemon plist `Program` 被替换为 `.jbroot-<brand>` 真实路径
- [x] 3.3 验收 daemon 启动：`launchctl print system/com.chargelimiter.mod` 显示 running；App 内"策略诊断"显示 daemon 在线、越狱类型=roothide
- [x] 3.4 验收充电控制：插电→停充（IsCharging=NO + PredictiveChargingInhibit=YES）→恢复，电流阈值判定生效（沿用 [[ios-power-re-playbook]] 探针方法论）
- [x] 3.5 验收加速充电 LPM：开启 acc_charge_lpm → 插电进入充电态即开 LPM；拔线还原；重越狱/userspace reboot 后未开 APP 时 LPM 仍生效（v1.15.2 bootstrap 兜底）
- [x] 3.6 验收设置持久化（D5 重点）：改设置→重启 userspace→设置仍在；确认 App（mobile）与 daemon（root）写同一 jbroot 内 `com.chargelimiter.mod.plist`
- [x] 3.7 验收 daemon 通信：App 内"修复 daemon 启动"一键自愈可用；URL Scheme 触发不受 root persona 影响
- [x] 3.8 验收卸载：`dpkg -r` → prerm 清理 jbroot 数据目录 + 域 bootout，无残留
- [x] 3.9 验收 `markAppsAsDebugged` 开关：Relaxin 设置里开/关 markAppsAsDebugged，ChargeLimiter 均正常工作（D7，记录不依赖）

## 4. 收尾

- [x] 4.1 更新 `CHANGELOG.md`：记录本次源码复核结论与（若有）修正
- [x] 4.2 更新 memory `relaxin-adapt-change`：复核完成状态、真机验收结果
- [x] 4.3 进入 verify 阶段
