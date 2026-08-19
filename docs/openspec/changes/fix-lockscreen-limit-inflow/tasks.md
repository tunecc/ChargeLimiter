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
