# Outcome

查清“自动限流在锁屏一段时间后失效”的真实层级，并以代码层证据确认最终交付状态（`b8c0764` 整体退回原版命令驱动语义）；锁屏真机有效性结论按 2026-09-09 收尾决定不再采集，本 change 以收尾归档结束。

# Scope

- 对比原版与新版 thermal 限流写入、daemon 生命周期与安装迁移链路，区分 `adv_limit_inflow` 自动限流与 `adv_thermal_mode_lock` 锁定默认热态（调查已完成，事实沉淀于 Constraints）。
- 根因修复以 `b8c0764`（删除 desired 读数闭环、恢复原版命令边沿写入）为最终交付，本 change 不再包含新的实现。
- 收尾归档：以代码层可验证的验收项确认最终状态；真机证据项与未实现项按 2026-09-09 决定移出验收。

# Non-goals

- 不把 `com.apple.cltm` 偏好仍存在等同于充电电流已受限。
- 不在没有真机证据时继续叠加基于电池读数的 desired/self-heal 闭环；该方向已经过三轮补丁并真机失败。
- 不使用未验证的 PMIC/IOKit 私有写入键直接指定固定充电电流。
- 不承诺所有 iOS/电池/充电器组合都支持锁屏 thermal 限流；原版文档明确将其列为系统限制，支持范围必须由配对测试界定。
- 不实现 legacy `chaoge.ChargeLimiter` launchd job 清理；该独立安装迁移缺陷留待后续 change 处理（2026-09-09 决定）。
- 不采集锁屏真机配对证据；锁屏 thermal 限流有效性按上游文档化系统限制对待，有效性边界不再由本 change 界定。
- 不为 daemon 补充 cltm pref 读回诊断能力；“pref 被清除”与“有效 state 回落”的现场区分缺口作为已知限制遗留。

# Acceptance examples

- A1：交付物 `b8c0764` 在 main HEAD 在位；读数驱动闭环符号（desired/sync 闭环、60s 自愈定时器、200ms 去抖、读回校验、粘滞兜底）全仓源码零残留，既有测试 `scripts/tests/test_limit_inflow_command_driven.py` 通过。
- A2：thermal 模式写入唯一入口为 `setThermalSimulationMode`（NSUserDefaults suite=com.apple.cltm），仅由充电命令边沿（setBatteryStatus 停充→默认档/开充→限流档）与配置变更边沿（set_conf / set_limit_inflow）触发；电池事件流不参与（onBatteryEventEnd 为空），无任何定时器可达 thermal 写入。
- A3：关闭限流（`adv_limit_inflow` off 且无 `adv_thermal_mode_lock`）后，集中决策函数返回默认 thermal 档（`adv_def_thermal_mode`，默认关闭）。
- A4：停充、恢复充电既有控制路径无回归：仓库既有相关单测全部通过。

# Constraints and invariants

- 当前 `main` 已包含 `b8c0764`，包内 daemon 与 2026-08-19 18:57 的构建产物哈希一致；本 change 不再假设用户安装的是回退前旧包。
- 当前与原版的 `setThermalSimulationMode` 都只通过 `NSUserDefaults(suite=com.apple.cltm)` 写 `thermalSimulationMode`；原版没有锁屏保活机制。
- 原版 README/help 明确写明“高温模拟无法在锁屏状态下生效”；单个用户成功只能作为待复现实验现象，不能作为规格依据。
- 上一轮 `f03befb`、`6a33876`、`8cb6e3c` 的读回、自愈、判据和粘滞补丁均未通过真机验收，`b8c0764` 仅恢复原版命令边沿写入语义。
- 当前 Mac 未识别到可用 iOS 设备，涉及锁屏电流的验收必须由用户连接设备或安装候选包后提供同机证据。
- Battman 调查（2026-08-23，本地源码核对）：同类软件 Battman 的停充/禁流不走 thermal 模拟，而是经 `AppleSMC` user client 直写 `CH0C`（停充保 AC）/`CH0I`（禁流），写前读 `CH0R` bit1（no VBUS）与 `CHCE`（有无适配器）做守卫，写后用 `CHNC`（NotChargingReason）位图判定实际原因；其 thermal 控制走 `notify_set_state`+`SCPreferences(OSThermalStatus.plist)`，不写 `com.apple.cltm`。Battman 未实现“限流到具体 mA”，限流语义同为开关式。
- 本项目 iOS17 停充/禁流已走 IOKit setProperties override 面（`IsCharging+PCI` / `FieldDiagsInflowInhibit+OBCInflowInhibit`），与 Battman 的 SMC 直写在效果上同域（注释已标注 CH0J/CH0I 对应关系）；尚未具备 NotChargingReason 位图解码与写后原因验证，entitlements 缺 `com.apple.private.applesmc.user-access`。
- 上游原版 README 承认：部分电池 thermal 模拟无效（以实测为准）、部分电池电流读数有误（以实际电量变化为准）——“第三方电池 thermal 限流不可靠、电流读数不可信”是上游已文档化的系统限制。

# Decisions

- change 使用当前 `main` 工作区，不创建额外分支或 worktree。
- 包文件名不是源码版本证据；已通过解包哈希和二进制字符串确认 18:57 生成的 rootful/rootless/roothide 包包含 `b8c0764` 后代码。
- 将原版/新版 package ID 与 launchd label 不同视为独立安装迁移缺陷：原版是 `chaoge.ChargeLimiter`，新版是 `com.chargelimiter.mod`，现有 postinst 未清理旧 job。
- 不接受上一轮“编译 + 源码扫描 pass”作为锁屏修复完成依据。
- 2026-09-09 收尾决定：用户确认本 change 按现状直接归档；`b8c0764`（删除 desired 读数闭环、恢复原版命令边沿写入）为最终交付状态，依赖锁屏真机配对证据的验收项不再在本 change 内执行。
- 2026-09-09 收尾决定（第二轮）：独立 Verifier 首轮验收判 A2/A5 failed（legacy 清理交付物缺失；拔线残留为 `b8c0764` 提交信息明示接受的原版行为）、A1/A3/A4 blocked（无真机证据）。用户确认按“修订验收后归档”收尾：legacy job 清理另立 change，真机证据不再采集，拔线残留记为已接受的原版行为，验收改为纯代码可验项（A1-A4）。拔线后 `thermalSimulationMode` 残留限流档至下一次充电命令边沿属原版行为，不再作为验收项。

# Open questions

以下问题原为 `[blocking]`，已随 2026-09-09 用户决定“按现状直接归档”关闭，不再作为实现决策点：

- Q1（已关闭）：不再选择新的实现路径。实质处理已落地：`b8c0764` 删除 desired 读数闭环、恢复原版命令边沿写入；锁屏 thermal 限制按上游已文档化的系统限制收尾。
- Q2（已关闭）：本 change 不再继续“原版锁屏有效”的路径差异调查。
- Q3（已关闭）：本 change 不再收集复现设备/环境信息；锁屏真机配对结论不在本 change 内产出。
- Q4（已关闭）：0mA 场景不属于本 change 的锁屏失效范围（thermal 限流本就不是 0mA 语义）；如后续实现 0mA/旁路供电，走停充 override 面另立 change。

# Verification expectations

- 代码层：验收 A1-A4 由独立只读 Verifier 基于源码、既有单测与 Runtime 检查逐项判定；构建层与真机层不再作为本 change 的验收门槛（2026-09-09 收尾决定）。
- 收尾层：检查 `git diff --check`、`git status`，验收结论全部通过后进入 Archive。
