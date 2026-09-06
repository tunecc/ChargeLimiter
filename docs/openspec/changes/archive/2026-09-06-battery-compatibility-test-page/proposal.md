# 提案：电池兼容性测试页面

## Why

CL 依赖对 iOS 电池控制面的写入来实现停充与禁流，但少数电池/小板（温度异常、健康度过低或未激活）会"失控"，CL 无法控制。目前用户只能按 README 中的手动步骤（关全局开关、用 curl 调 HTTP 接口、盯 120 秒电流变化）逐项测试，门槛高、易漏判。需要一个放在 App 内的一键自动化测试页面，让普通用户在正式使用 CL 前就能确认自己的设备是否被支持。

## What Changes

- 主页面"更多功能"区在"历史统计"入口下方新增"电池兼容性测试"入口卡片，推入新页面 `CLBatteryCompatibilityTestViewController`。
- 新页面提供一键自动化测试编排（UI 进程内实现，复用现有 daemon HTTP API）：
  - **停充测试**：自动临时关闭 CL 全局开关，调 `set_charge_status flag=false`，监测 120 秒内充电状态是否变化；若停充后仍有持续电池电流（≥5mA）则判定无法支持停充。
  - **智能停充测试**：自动开启"充电高级-智能停充"，其余同停充测试。
  - **禁流测试**：自动临时关闭 CL 全局开关，调 `set_inflow_status flag=false`，监测 120 秒内状态是否变化；若禁流后仍有较大持续电流（≥5mA）则判定无法支持。
  - 单项测试可早停：充电状态快速变化（测试已生效）时提前出结论，不必等满 120 秒。
- 测试期间实时展示进度：当前测试项、已用时/预计剩余、实时电池电流、充电状态变化。
- 测试结束展示结果：每项测试的判定结论、监测期最大/最低电流、状态变化耗时，并给出总体判定（既不支持停充也不支持禁流 → 设备不被 CL 支持）。
- 配置自动保存/恢复：测试开始前保存全局开关、智能停充等可能干扰测试的 CL 配置，按需临时切换，测试结束/取消/中途退出时自动恢复原状。
- 前置检查：未插电、daemon 不在线、电量 100% 等无法有效测试的状态下阻止开始并提示。
- 页面内提供"运行停充控制探针"按钮，复用现有 `charge_control_probe` API 展示控制面写法结论。
- 支持测试中途取消；英语/简体中文双语文案同步更新。

## Capabilities

### New Capabilities

- `battery-compatibility-test`: App 内一键自动化电池兼容性测试能力——前置检查、三项测试编排（停充/智能停充/禁流）、配置自动保存与恢复、实时进度与结果判定展示、停充控制探针快捷入口。

### Modified Capabilities

（无——不修改 daemon 充电控制的任何需求行为，仅新增 UI 侧测试能力。）

## Impact

- **新增**：`ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.{h,m}`（测试页面与编排逻辑）；Xcode 工程引用。
- **修改**：`ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m`（新增入口卡片与跳转方法）；`ChargeLimiter/en.lproj/Localizable.strings`、`ChargeLimiter/zh-Hans.lproj/Localizable.strings`（新增文案）；`ChargeLimiter.xcodeproj`（新文件加入 target）。
- **复用（不修改）**：`CLAPIClient`（`setChargeStatus`、`setInflowStatus`、`getBatteryInfo`、`runChargeControlProbe`）、`CLBatteryManager`（电池数据轮询与配置存取）、daemon 全部现有 HTTP API。
- **风险**：测试会短暂真实停充/禁流（最多 120 秒/项），期间设备可能开始放电；通过前置检查、全程可取消、结束自动恢复配置来控制风险。
