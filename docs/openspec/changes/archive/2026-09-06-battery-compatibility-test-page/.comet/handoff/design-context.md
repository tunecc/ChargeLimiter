# Comet Design Handoff

- Change: battery-compatibility-test-page
- Phase: design
- Mode: compact
- Context hash: b6cff0d9b4ba6d31904d6bd77dd12f7c7bddba9a6c3b35ba0bf9485086b588cc

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## docs/openspec/changes/battery-compatibility-test-page/proposal.md

- Source: docs/openspec/changes/battery-compatibility-test-page/proposal.md
- Lines: 1-37
- SHA256: 9b5d6987c0968c8d1dea228d7689d2d1d3260bd932f5ead53ce6713f80fbc4f2

```md
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

```

## docs/openspec/changes/battery-compatibility-test-page/design.md

- Source: docs/openspec/changes/battery-compatibility-test-page/design.md
- Lines: 1-56
- SHA256: 6ec783956d0d2f367dfa244a46953a50c864545ab4c73d5d3c7a59ab010672cb

```md
# 设计：电池兼容性测试页面

## Context

- App（UI 进程）与 daemon 通过 `127.0.0.1:1230` HTTP API 通信；`CLAPIClient` 已封装 `setChargeStatus`、`setInflowStatus`、`getBatteryInfo`、`runChargeControlProbe`，daemon 端实现均已就绪，本次不新增、不修改 daemon API。
- `CLBatteryManager` 提供电池实时数据（`amperage`、`instantAmperage`、`isCharging`、`externalConnected` 等）与配置项读写；全局刷新频率跟随用户设置。
- 主页面 `CLSettingsViewController` 的"更多功能"区现有入口为：历史统计 → 充电高级 → 软件设置；入口卡片模式统一（CLGlassCard + UIControl + 推入导航栈）。
- README 手动测试流程定义了判定规则：120 秒内状态变化则支持；之后持续电池电流 ≥5mA 则无法支持；停充与禁流均不支持则设备不被 CL 支持。
- 动机与范围见 proposal.md；行为需求见 specs/battery-compatibility-test/spec.md。

## Goals / Non-Goals

**Goals**

- UI 进程内实现测试编排状态机，零 daemon 改动即可跑通三项测试。
- 测试期间采样节奏与全局刷新频率解耦，保证判定数据稳定。
- 任何退出路径（完成/取消/返回）都恢复测试前配置。

**Non-Goals**

- 不修改 daemon 充电控制逻辑与写法（探针仍是诊断面，不参与判定）。
- 不做后台持续监控或定期自动复测；测试仅由用户手动触发。
- 不替代 README 手动流程文档（页面提示保持精简）。

## Decisions

1. **编排状态机放在 UI 进程（新控制器内），不新增 daemon API。**
   备选：daemon 新增 `battery_compat_test` API 由 daemon 编排。否决理由：daemon 是常驻进程，测试逻辑出错会威胁主功能；HTTP API 已满足全部控制与取数需求；UI 侧实现便于展示实时进度且失败可随时退出。

2. **测试期间由测试控制器独立定时轮询 `getBatteryInfoWithCompletion`（约 1 秒间隔），不依赖 `CLBatteryInfoDidUpdateNotification`。**
   备选：复用 CLBatteryManager 全局刷新通知。否决理由：全局刷新频率用户可调（可能数秒一跳），测试判定需要稳定采样节奏；独立轮询不影响用户设置。

3. **"持续 ≥5mA"判定采用滑动窗口**：状态变化后继续观察一小段确认窗口（候选 10 秒），窗口内电流持续 ≥5mA 才判不支持，避免瞬时抖动误判。具体窗口参数在 design 阶段 Design Doc 定稿。

4. **配置快照/恢复走现有配置保存通道**：测试开始前记录受影响配置快照（至少全局开关、智能停充；插电保持等可能干扰判定的策略项在 Design Doc 定稿），测试序列按项切换，`finally` 语义恢复——完成、取消、离开页面三条路径都执行恢复。

5. **早停规则**：出现状态变化后，若确认窗口内电流低于阈值 → 立即判"支持"并进入下一项；120 秒仍无状态变化 → 判"不支持"；状态变化但电流持续 ≥5mA → 判"不支持"。

6. **前置检查**：未插电、daemon 不在线、电量接近满（停充测试无从生效）时阻止开始并提示。具体阈值在 Design Doc 定稿。

7. **页面结构**：说明区（精简版兼容性说明）→ 测试项选择区 → 开始/取消按钮 → 进度区（当前项、已用时、实时电流）→ 结果区（分项结论 + 最大/最低电流 + 总体判定）→ 探针按钮区。入口卡片复用历史统计入口的视觉模式。

## Risks / Trade-offs

- [测试期间真实停充/禁流，设备最多 6 分钟不受 CL 控制] → 每项 120 秒上限 + 早停；全程可取消；恢复路径幂等。
- [用户测试中途强杀 App，配置恢复未执行] → 恢复操作在每次配置切换前就持久化快照；下次进入测试页可检测残留快照并提示恢复。
- [满电/极低电量状态下测试无意义或误判] → 前置检查排除。
- [禁流态下 `ExternalConnected` 等派生值抖动] → 判定不依赖单一属性，以电流特征 + 状态变化组合判定（Design Doc 细化）。

## Migration Plan

纯新增功能，无数据迁移；发布后即可用，回滚即移除入口与新文件。

## Open Questions

- 滑动确认窗口时长、恢复配置完整清单、满电判定阈值——在 design 阶段 Design Doc 定稿，不影响本设计方向。

```

## docs/openspec/changes/battery-compatibility-test-page/tasks.md

- Source: docs/openspec/changes/battery-compatibility-test-page/tasks.md
- Lines: 1-28
- SHA256: 44fff82a5d662cf48875951344e45e786a2b03eaa11f8ceb7f56cee1016f4dd9

```md
# 任务清单：电池兼容性测试页面

## 1. 页面骨架与入口

- [ ] 1.1 新建 `CLBatteryCompatibilityTestViewController`（.h/.m），实现页面骨架：说明区、三项测试选择区、开始/取消按钮、进度区、结果区、探针按钮区，并加入 Xcode 工程各 target；验证：rootful 方案编译通过，页面可从入口推入显示
- [ ] 1.2 主页面"更多功能"区在历史统计入口下方新增"电池兼容性测试"入口卡片与跳转方法（复用现有入口卡片视觉模式）；验证：编译通过，真机/模拟器上入口位于历史统计下方且点击进入新页面

## 2. 测试编排核心

- [ ] 2.1 实现前置检查（插电、daemon 在线、电量范围）与提示；验证：未插电时点击开始被阻止并显示对应提示
- [ ] 2.2 实现配置快照/恢复器：测试前保存全局开关、智能停充等受影响配置，完成/取消/离开页面三路径恢复，残留快照下次进入检测提示；验证：任一退出路径后配置恢复为测试前值
- [ ] 2.3 实现测试状态机与三项测试逻辑（停充/智能停充/禁流）：独立 1 秒轮询采样、120 秒上限、滑动窗口 ≥5mA 持续电流判定、状态变化早停；验证：插电真机上停充测试能在状态变化后早停并给出正确结论
- [ ] 2.4 实现单项测试选择（默认三项全选）；验证：仅勾选停充测试时只执行该项

## 3. 进度与结果展示

- [ ] 3.1 实现实时进度区：当前测试项、已用时/预计剩余、实时电池电流、状态变化事件；验证：测试中页面每秒刷新电流与进度
- [ ] 3.2 实现结果区：分项结论、监测期最大/最低电流、总体判定（双不支持时提示设备不被 CL 支持）；验证：跑完三项后结果正确展示且与判定规则一致

## 4. 探针入口与本地化

- [ ] 4.1 实现"运行停充控制探针"按钮：复用 `runChargeControlProbe` API，运行中防重复触发，完成后展示结论摘要；验证：点击后运行并显示探针结论
- [ ] 4.2 补全 en.lproj / zh-Hans.lproj 双语文案；验证：切换语言后页面文案正确跟随

## 5. 验证

- [ ] 5.1 rootful + rootless 两方案 xcodebuild 编译通过；验证：`xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" ...` 与 rootless scheme 均成功
- [ ] 5.2 打包脚本冒烟 `./scripts/build_packages.sh`；真机安装后完整走一遍一键测试（含取消路径与配置恢复检查）

```

## docs/openspec/changes/battery-compatibility-test-page/specs/battery-compatibility-test/spec.md

- Source: docs/openspec/changes/battery-compatibility-test-page/specs/battery-compatibility-test/spec.md
- Lines: 1-155
- SHA256: 43ceed90dc5461fa2398b9eea1977edc293517305db260170b009e4acfa27a00

[TRUNCATED]

```md
## Purpose

让用户在正式使用 CL 前能通过 App 内的一键自动化测试，确认自己的电池/设备是否支持停充与禁流控制，替代 README 中需要 curl 与人工盯流的手动测试流程。

## ADDED Requirements

### Requirement: 电池兼容性测试入口

主页面"更多功能"区 SHALL 在"历史统计"入口下方提供"电池兼容性测试"入口卡片；用户点击后 SHALL 推入电池兼容性测试页面。

#### Scenario: 从主页面进入测试页面

- **WHEN** 用户在主页面点击"电池兼容性测试"入口
- **THEN** 应用推入电池兼容性测试页面，页面标题与入口文案一致

### Requirement: 测试前置检查

用户发起测试时，系统 SHALL 先校验测试前提：设备已插电（外接电源已连接）且 daemon 在线。任一前提不满足时 SHALL 阻止开始并给出对应提示；全部满足时 SHALL 允许开始测试。

#### Scenario: 未插电时阻止测试

- **WHEN** 设备未连接外接电源且用户点击开始测试
- **THEN** 测试不启动，页面提示需要插电后重试

#### Scenario: daemon 不在线时阻止测试

- **WHEN** daemon 不在线且用户点击开始测试
- **THEN** 测试不启动，页面提示 daemon 未运行

### Requirement: 一键完整测试编排

用户点击"开始测试"后，系统 SHALL 按顺序自动执行三项测试：停充测试、智能停充测试、禁流测试；每项测试时长上限为 120 秒，若该测试的判定条件已可得出结论，系统 SHALL 提前结束该项并进入下一项。全部选中的测试执行完毕后 SHALL 输出结果页。

#### Scenario: 完整顺序执行

- **WHEN** 用户点击开始测试且三项测试均未被排除
- **THEN** 系统依次执行停充测试、智能停充测试、禁流测试，页面对每项显示执行中状态，最终汇总三项结果

#### Scenario: 判定已明时早停

- **WHEN** 某项测试的充电状态在 120 秒内发生预期变化且电流监测已可给出结论
- **THEN** 该项测试提前结束并给出结论，无需等待满 120 秒

### Requirement: 单项测试选择

页面 SHALL 允许用户仅选择其中一项或多项测试运行，未选中的测试 SHALL 被跳过。

#### Scenario: 仅重测单项

- **WHEN** 用户仅勾选"停充测试"并点击开始
- **THEN** 系统只执行停充测试并输出该单项结果

### Requirement: 停充测试判定

停充测试 SHALL 按以下流程执行：临时关闭 CL 全局开关，并临时关闭智能停充配置以覆盖传统停充写法，调用停充接口（`set_charge_status`，flag=false），随后持续监测电池充电状态与电池电流，监测窗口上限 120 秒。判定规则：

- 若监测窗口内充电状态发生预期变化（由充电转为停止充电）且变化后的确认窗口内电池电流低于 5mA，SHALL 判定"支持停充"；
- 若停充后电池电流持续 ≥5mA（以确认窗口内的持续电流为准），SHALL 判定"无法支持停充"；
- 若 120 秒内充电状态无变化，SHALL 判定"无法支持停充"。

#### Scenario: 停充生效判定为支持

- **WHEN** 停充指令下发后充电状态在监测窗口内由充电转为停止，且确认窗口内电池电流低于 5mA
- **THEN** 该项测试得出"支持停充"结论，并记录状态变化耗时

#### Scenario: 停充生效但电流持续判定为不支持

- **WHEN** 停充指令下发后充电状态变为停止，但确认窗口内电池电流持续 ≥5mA
- **THEN** 该项测试得出"无法支持停充"结论，并记录监测期电流数据

#### Scenario: 停充后电流持续判定为不支持

- **WHEN** 停充指令下发后充电状态无变化，或停充后电池电流持续 ≥5mA
- **THEN** 该项测试得出"无法支持停充"结论，并记录监测期电流数据

### Requirement: 智能停充测试判定

智能停充测试 SHALL 临时开启"充电高级-智能停充"配置以覆盖智能停充写法，然后按与停充测试相同的流程与判定规则执行。

#### Scenario: 智能停充路径生效

```

Full source: docs/openspec/changes/battery-compatibility-test-page/specs/battery-compatibility-test/spec.md
