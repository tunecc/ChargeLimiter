# Comet Design Handoff

- Change: fix-lockscreen-limit-inflow
- Phase: design
- Mode: compact
- Context hash: 96fca46dcdee1e04c71d7246799c4a95fa71760e22ca80e05df26ef6d281b45f

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## docs/openspec/changes/fix-lockscreen-limit-inflow/proposal.md

- Source: docs/openspec/changes/fix-lockscreen-limit-inflow/proposal.md
- Lines: 1-25
- SHA256: 44649ab1761ff9e272b7eb72992ea846fc37149df0f2bc3399a1868cd74b2ab7

```md
# Proposal: fix-lockscreen-limit-inflow

## Why

用户真机反馈（iOS 17）：锁屏后限流控制失效，电流恢复到未限流水平；换回原版（ChargeLimiter-main v1.7.x 系）锁屏时限流保持正常。上一轮修复（v1.15.2 commit f03befb，读回校验 + 60s 自愈定时器）针对"锁屏期 cltm 清 pref 无人重写"的假设，真机验证完全无效——说明假设方向错了，真实根因是当前版在锁屏期自己把限流取消。

## What Changes

- 修复 `desiredThermalSimulationModeForCurrentState` 的充电会话判定在锁屏态使用不可靠信号的问题：
  - `adaptorConnected` 不再经 `isAdaptorConnect` 读系统派生的 `ExternalChargeCapable`（限流态下 cltm 周期性重算会读到 false），改用稳定的 `AdapterDetails`（存在且 `Description != "batt"`）判定；
  - `chargeAllowed` 的电流判定在限流档为 moderate/heavy 时联动 30mA 阈值（限流本身压制电流到 120mA 以下，固定 120mA 阈值会误判"不在充电"），对齐 `scheduleChargeEnableVerification` 已有先例；
  - 限流档已写入且未出现明确退出信号（拔线 / 停充命令 / 关限流 / 等级切换）时 desired 不瞬时降档，防读数空洞期自取消。
- desired 从限流档降为默认档时记录 policy event（`thermal_desired_downgrade`），真机可定位是哪个信号导致降档。

不改变：限流的写入路径（`setThermalSimulationMode` / cltm pref）、停充控制面（iOS 17 override 路径）、UI 配置项与语义。原版锁屏正常的机制（写一次长期留存）不受影响，本修复只是让新架构的"desired 计算"在锁屏态收敛到与原版等价的稳态。

## Capabilities

- **Modified Capabilities**: 无 spec 级行为变更——限流在锁屏期"应保持生效"本来就是 `adv_limit_inflow` 的预期行为（CHANGELOG v1.15.2 已承诺"锁屏后限流失效"修复），本 change 是该承诺的 bug 修复落地，不新增需求场景。`.openspec.yaml` 设置 `skip_specs: true`。

## Impact

- 代码：`ChargeLimiter/daemon.mm`（`desiredThermalSimulationModeForCurrentState`、`syncThermalSimulationModeForCurrentState`、电流阈值常量、policy event 记录）；预计 1 个文件。
- 测试：`scripts/tests/test_thermal_session_gate.py` 断言需同步更新（现断言 `desiredThermalSimulationModeForCurrentState` 必须含 `isAdaptorConnect`，本修复恰恰要移除该依赖）；新增锁屏态 desired 判定的源码扫描测试。
- 风险：低。改动集中在 desired 计算分支，写路径不变；最坏情况退化为修复前行为（锁屏限流失效），不会影响停充/恢复充电链路。

```

## docs/openspec/changes/fix-lockscreen-limit-inflow/design.md

- Source: docs/openspec/changes/fix-lockscreen-limit-inflow/design.md
- Lines: 1-60
- SHA256: 22230fa5ece2656a66cba3261da41068ea91056047671092031c7a8595be1d01

```md
# Design: fix-lockscreen-limit-inflow

## 根因（对比原版 + 当前版链路推演）

### 原版为什么锁屏正常

原版 `setBatteryStatus`（ChargeLimiter-main `daemon.mm:258-271`）只在充电命令翻转时写一次 thermal pref（`flag=YES` 写 `adv_limit_inflow_mode`，`flag=NO` 写 `adv_def_thermal_mode`），此后**从不读回、从不重写**。锁屏后电池事件继续到达，但没有任何代码路径再触碰 thermal pref，cltm 应用后限流长期保持。原版对锁屏天然免疫，因为它不依赖任何实时信号维持限流。

### 当前版的失效链路（自反馈取消）

当前版（v1.15.x 架构）为每个电池事件维护 ensure 语义：`onBatteryEventEnd()` → `syncThermalSimulationModeForCurrentState` → `desiredThermalSimulationModeForCurrentState`（`daemon.mm:1820`）+ 60s 自愈定时器跑同一函数。desired 的会话判定依赖两个**锁屏态不可靠信号**：

1. **`isAdaptorConnect` → `ExternalChargeCapable`**（`daemon.mm:1265`）：iOS 17 下该值由系统间接派生。[[ios17-inflow-external-connected-flicker]] 已真机证实：写入 inhibit 类 override（限流的热态模拟同属此类）后，息屏期 cltm/电源管理周期性重算时该值抖动、读到 false。`672ab65` 引入此前置条件时是为了修"未插电持续写限流"，但没料到锁屏态派生值会塌。
2. **`currentLooksCharging` 固定 120mA 阈值**（`daemon.mm:2828`）：限流生效的定义就是电流被压制（moderate/heavy 下常低于 120mA）；`scheduleChargeEnableVerification` 已为此联动了 30mA 阈值（`daemon.mm:1679` 附近），此处未联动。停充态（`g_chargeCommandEnabled=NO`）下充电电流为 0，chargeAllowed 全靠电流信号——限流态读数恰好落空。

失效链：

```
限流生效（pref=moderate/heavy）
→ 锁屏后 cltm 周期性重算，ExternalChargeCapable 短暂/持续塌为 false
   （或停充+限流组合下电流 < 120mA 且 g_chargeCommandEnabled=NO）
→ chargeSessionActive=NO → desired=off
→ ensure-sync 读回 pref=moderate ≠ off → 主动改写为 off（限流被自己关掉）
→ 电流恢复 → 再触发限流写入 → 抖动循环；60s 自愈跑同一判定，把 off 写得更牢
```

### 上一轮修复（f03befb）为什么无效

f03befb 假设"锁屏期 cltm 清 pref → 无人重写 → 失效"，所以加读回校验 + 自愈重写 **desired**。真实方向相反：**desired 本身在锁屏态被算错成 off**，sync 是把错误 desired 写下去的执行者。自愈定时器信任同一个错误判定，方向反了——不但救不回，还每 60s 强化一次降档。

## 修复方案

全部改动集中在 `ChargeLimiter/daemon.mm` 的 desired 计算，写路径（`setThermalSimulationMode`）与策略层不动。

### 1. adaptorConnected 换稳定判据（主修复）

`desiredThermalSimulationModeForCurrentState` 内不再调 `isAdaptorConnect`（读派生值 `ExternalChargeCapable`），改为本地判定 `AdapterDetails`：存在且 `Description != "batt"` 即视为适配器在位。这与 `isAdaptorConnect` 禁流分支用同一物理量，[[ios17-inflow-flicker-fix]] 已真机验证其在派生值抖动期稳定。保留未插电时回退 defaultMode 的语义（防"未插电持续写限流"回归，即 672ab65 修的 bug）。

### 2. 限流态电流阈值联动

`chargeAllowed` 的 `currentLooksCharging` 判定在当前限流档为 moderate/heavy 时用 30mA 阈值（新常量 `kThermalLimitCurrentThresholdmA`），对齐 `scheduleChargeEnableVerification` 的既有联动。轻档（nominal/light）下电流压制通常仍 >120mA，维持原阈值。

### 3. 会话粘滞兜底

新增运行时标志 `g_thermalLimitActive`（上次成功写入限流档时置位）。desired 计算发现限流档本应激活但会话判定瞬时塌掉、且**没有**明确退出信号（拔线边沿 / `g_chargeCommandEnabled` 翻 NO / `adv_limit_inflow` 关闭 / 等级改轻档）时，维持限流档不降档，并记 `thermal_session_sticky_hold` 事件（限流频率，避免刷库）。退出信号到达或真实拔线时清除标志。这防的是读数空洞期（AdapterDetails 短暂缺失等）的自取消。

### 4. 降档事件

`syncThermalSimulationModeForCurrentState` 在 desired 从限流档（≠defaultMode 且非 off）降为默认档时记录 `thermal_desired_downgrade` policy event（带 desired/actual/adaptor 判定快照），真机上直接定位降档原因。sticky hold 命中时不写 pref、不降档。

## 备选方案（不采用）

- **回退原版"写一次不维护"**：最小改动，但丢掉 672ab65 修的"未插电持续写限流漂移"防护与等级切换实时性，等于把已修 bug 再打开。
- **去掉 ensure-sync 只靠自愈定时器**：自愈跑同一 desired 计算，单独改它无意义；且去抖 sync 还承担等级切换实时性（31b03f），不能删。

## 验证方式

- 源码扫描测试（python，scripts/tests/）：断言 desired 计算不再含 `isAdaptorConnect`、含 `AdapterDetails` 判定、moderate/heavy 阈值联动存在、sticky hold 分支存在；`test_thermal_session_gate.py` 的旧断言同步更新。
- 三 scheme 编译验证。
- 真机验收（用户执行）：开限流 moderate/heavy → 插电 → 锁屏 ≥30 分钟 → 电流保持限流水平、`get_diag`/policy event 无 `thermal_desired_downgrade` 持续刷屏。

```

## docs/openspec/changes/fix-lockscreen-limit-inflow/tasks.md

- Source: docs/openspec/changes/fix-lockscreen-limit-inflow/tasks.md
- Lines: 1-28
- SHA256: 42edf4dc1e55f49cbe750a58397e2265d5d85f93db1402bff1f18b40cf85ad60

```md
# Tasks: fix-lockscreen-limit-inflow

## 1. RED：先写失败测试

- [x] 1.1 新增 `scripts/tests/test_thermal_lockscreen_hold.py`：断言 `desiredThermalSimulationModeForCurrentState` 不再调用 `isAdaptorConnect`、改用 `AdapterDetails` 判定、moderate/heavy 下 `chargeAllowed` 用 30mA 阈值、存在 sticky hold 分支（`g_thermalLimitActive`）。运行确认失败（当前代码无这些实现）。
- [x] 1.2 更新 `scripts/tests/test_thermal_session_gate.py`：`test_charge_session_requires_adaptor` 断言改为要求 `AdapterDetails` 判定而非 `isAdaptorConnect`。

## 2. 实现修复（daemon.mm）

- [x] 2.1 `desiredThermalSimulationModeForCurrentState`：`adaptorConnected` 改用 `AdapterDetails`（存在且 `Description != "batt"`）判定，移除 `isAdaptorConnect` 调用；未插电仍回退 defaultMode。
- [x] 2.2 限流档为 moderate/heavy 时 `chargeAllowed` 的电流判定用 `kThermalLimitCurrentThresholdmA`（30）阈值。
- [x] 2.3 新增 `g_thermalLimitActive` 粘滞兜底：会话判定瞬时塌掉但无明确退出信号（拔线 / `g_chargeCommandEnabled=NO` / `adv_limit_inflow` 关 / 等级改轻档）时维持限流档；退出信号清除标志；命中记 `thermal_session_sticky_hold` 事件。
- [x] 2.4 `syncThermalSimulationModeForCurrentState`：desired 从限流档降为默认档时记 `thermal_desired_downgrade` 事件（带判定快照）。

## 3. 验证

- [x] 3.1 运行全部 thermal 相关源码扫描测试（test_thermal_lockscreen_hold / test_thermal_session_gate / test_thermal_sync_debounce / test_thermal_mode_live_refresh / test_charge_enable_verify）转绿。
- [x] 3.2 三 scheme（rootful / rootless / roothide）编译通过。
- [x] 3.3 根因消除检查：确认 desired 计算不再依赖 `ExternalChargeCapable`；搜索验证无遗漏调用点。
- [x] 3.4 真机验收清单已写入 change 目录 acceptance.md（A1-A5）；真机验收执行与结果由用户后续反馈，验收通过是归档前置条件之一。

## 4. 真机验收失败后改道：整体退回原版命令驱动语义（2026-08-19）

- [x] 4.1 对照原版项目定位根因：原版 thermal 模式只在命令边沿写入，从不读电池读数推导期望模式；d8ad775 引入的 desired 闭环形成自反馈回路，锁屏期读数塌陷→desired=off→sync 自己取消限流；三版补丁（f03befb / 6a33876 / 8cb6e3c）均在回路内打转
- [x] 4.2 删除 desired/sync 闭环、60s 自愈定时器、200ms 去抖、读回校验、粘滞兜底、阈值联动、降档事件；utils 移除 getThermalSimulationModePref
- [x] 4.3 setBatteryStatus/onBatteryEventEnd/set_conf 恢复原版写法；保留 chargeEnableThresholdForCurrentThermalMode（另一 bug 修复）
- [x] 4.4 删除 test_thermal_self_heal / sync_debounce / session_gate / lockscreen_hold 四个过时断言文件；保留 mode_live_refresh
- [x] 4.5 全仓 168 项测试通过；三 scheme 编译通过；提交 b8c0764

```
