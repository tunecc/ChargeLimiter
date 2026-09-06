# 提案：修复禁流测试信号漏检与系统对抗误判

## Why

Hotfix `fix-compat-test-baseline-inflow` 后真机复测（用户实测）仍有两个问题：

1. **禁流测试仍误判"无法支持"**：上一轮把 `IsCharging` 从禁流信号中剔除后，用户设备上禁流生效时**电流并不转负、ExternalConnected 也不翻转**（用户确认充电线全程未动、已连接状态从未变化），唯一真实的生效信号（充电→停止充电）被忽略 → 120 秒无变化 → 误判。同时用户观察到"未充电→跳转成充电"：单次禁流写会被 iOS 恢复充电（**系统对抗**；daemon 自身禁流实现即带重试机制 `isDisableInflowRetryEligible` 正是为此），测试只写一次、被系统翻回即判不支持。
2. **结果展示误导**：停充测试判"支持"但结果卡显示最大电流 493mA——这是**状态变化前**的充电电流（全程最大/最低），而判定依据是状态变化后确认窗口的电流（<5mA，判定正确）。展示与判定口径不一致让用户无法理解结果。

前置检查"正在充电"行在第二次点开始时显示"未在充电"属如实反映上一轮测试后的状态（回稳失败的合法结果），非 bug，但需要文案说明避免误解。

**复现与自动化说明**：依赖真实设备充电状态机与系统对抗行为，本环境无法自动化复现；证据为用户真机实测描述 + 代码级根因定位（`handleSample` 禁流分支信号集，CLBatteryCompatibilityTestViewController.m）。

## What Changes

- 禁流生效信号恢复 `IsCharging` 翻转（基线已锚定充电中，翻转即真信号）：`changed = (bCharging && !isCharging) || (bExtConnected && !extConnected) || (bCurrent >= 0 && current < 0)`。
- **禁流对抗重试**：确认窗口内检测到充电被系统恢复（`IsCharging==YES && 电流 ≥5mA`）时重新下发 `set_inflow_status(false)`（最多 3 次），与 daemon 真实禁流行为一致；重试耗尽仍恢复充电才判"无法支持（禁流无法维持）"。
- 结果卡电流展示改为**判定口径**：有状态变化时展示确认窗口（状态变化后）的最大/最低电流（与 5mA 阈值比较的数据）；无状态变化（120s 超时）时展示监测期全程最大/最低电流。
- 说明区新增提示：前置检查显示的是点击开始时的状态，测试过程中充电状态会按测试需要自动切换。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `battery-compatibility-test`: 禁流测试判定（信号集恢复 IsCharging 翻转 + 系统对抗重试）；测试结果展示（电流改为判定窗口口径）。需 delta spec。

## Impact

- 修改：`ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`（禁流判定/重试/结果统计口径）、`en.lproj`、`zh-Hans.lproj`（新增文案）。
- 复用不改：daemon 全部 API。
