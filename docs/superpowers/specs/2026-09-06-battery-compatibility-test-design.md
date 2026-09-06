---
comet_change: battery-compatibility-test-page
role: technical-design
canonical_spec: openspec
archived-with: 2026-09-06-battery-compatibility-test-page
status: final
---

# 技术设计：电池兼容性测试页面

上游事实源：`docs/openspec/changes/battery-compatibility-test-page/`（proposal.md / specs/battery-compatibility-test/spec.md / design.md / tasks.md）。本文档是 open 阶段 design.md 的深度技术细化，不重写需求。

## 1. 上下文与已核实事实

代码核实结论（实现的前提约束）：

| # | 事实 | 来源 |
|---|------|------|
| F1 | `g_enable=NO` 时 daemon 策略循环完全短路（`refreshBatteryStateAndApplyPolicy` / `onBatteryEvent` 直接 return），不会自动干预充电状态 | daemon.mm |
| F2 | `set_config enable=false` 触发 `resetBatteryStatus()`（恢复充电）并恢复系统优化充电 → 关全局开关后设备处于"daemon 不管 + 正在充电"，正是测试起点 | daemon.mm set_config handler |
| F3 | `set_charge_status` / `set_inflow_status` HTTP API 无 enabled 门禁，直接写 IOKit | daemon.mm API handler |
| F4 | 停充写法由 `adv_predictive_inhibit_charge`（默认 YES）决定：YES → PredictiveChargingInhibit 路径；NO → 传统 IsCharging 路径；predictive 写失败 daemon 自动 fallback legacy（`g_predictiveInhibitFallbackActive`） | daemon.mm setChargeStatus / shouldUsePredictiveInhibitChargePath |
| F5 | 探针运行期间（`g_chargeControlProbeRunning`）set_charge_status / set_inflow_status 返回 0（假成功）→ 测试与探针必须互斥 | daemon.mm setChargeStatus/setInflowStatus |
| F6 | `get_bat_info` 返回原始字段：`IsCharging`、`InstantAmperage`、`Amperage`、`ExternalChargeCapable`、`ExternalConnected` 等；有效电流优先 InstantAmperage（与 daemon `getEffectiveBatteryCurrent` 一致） | CLBatteryManager.m / daemon.mm |
| F7 | 探针结果结构：`data.summary`（any_effective/best_path/dominant_failure/power_note）+ `data.results[]`（service/path/verdict/write_ret/prop_changed/current_stopped）；`CLAdvancedSettingsViewController.chargeControlProbeExportTextFromPayload` 是现成解析范例 | CLAdvancedSettingsViewController.m |
| F8 | 配置键名：`enable`、`adv_predictive_inhibit_charge`；UI 写入走 `CLBatteryManager.saveConfigKey:value:completion:`（HTTP set_config） | CLBatteryManager.m |
| F9 | iOS17+ 禁流态 `ExternalConnected`/`ExternalChargeCapable` 为系统间接派生值，息屏周期刷新会抖动，不能作为唯一判据 | daemon.mm isAdaptorConnect 注释 |
| F10 | 项目允许多类同文件（`CLHistoryViewController` 定义在 CLSettingsViewController.m 内）；UI 卡片控件有 CLGlassCard / CLAdvSettingsCard 两种现成模式 | Controllers |

## 2. 架构

```
CLSettingsViewController（主页，更多功能区）
  历史统计入口 → [电池兼容性测试入口（新增）] → 充电高级入口
                      │ push
                      ▼
CLBatteryCompatibilityTestViewController（新文件 Controllers/CLBatteryCompatibilityTestViewController.{h,m}）
  ├─ CLBatteryCompatibilityEngine（同文件内部类）
  │    状态机 · 1s 轮询采样 · 判定 · 配置快照恢复 · 事件回调(block)
  └─ UI 渲染（进度/结果/探针），不直接触碰测试逻辑
        │ 复用（零 daemon 改动）
        ▼
CLAPIClient：setChargeStatus / setInflowStatus / getBatteryInfo / runChargeControlProbe / getConfig / setConfig
```

**职责边界**

- **Engine**：唯一拥有测试状态机与采样循环。对外接口：
  - `- (BOOL)startWithSelectedTests:(CLCompatTestSelection)selection;`（前置检查不过则返回 NO 并给出原因回调）
  - `- (void)cancel;`
  - `- (void)restoreSnapshotIfNeeded;`（页面进入/离开时调用）
  - 回调：`onPhaseChanged` / `onSample(电流, IsCharging, 已用时)` / `onStateChange(耗时)` / `onTestVerdict(项, 结论, 最大/最低电流, 耗时)` / `onFinished(总体判定, 恢复警告?)` / `onAborted(原因)`
- **ViewController**：构建卡片 UI、按钮态切换、把 Engine 事件映射到 UI；探针按钮直接调 CLAPIClient 并渲染摘要（模式复用 F7）。
- **CLBatteryManager/CLAPIClient**：不修改；Engine 每次采样自己调 `getBatteryInfoWithCompletion` 解析原始响应，不依赖全局刷新。

## 3. 编排状态机

```
idle
 └─ start → preconditionCheck ── 不过 ──→ aborted(原因)
             │ 过：读配置快照（enable、adv_predictive_inhibit_charge）→ 持久化 NSUserDefaults
             ▼
           testStopCharge（停充）
             └─ 完成/早停 → restoreCharging + 基线回稳(≤15s)
                  ▼
           testSmartStopCharge（智能停充）→ 同上回稳
                  ▼
           testInflow（禁流）→ restoreCharging/Inflow + 回稳
                  ▼
           restoreSnapshot（写回快照配置 → 删除 NSUserDefaults 快照）
                  ▼
           finished(总体判定, 恢复警告?)
任何运行态 ─ cancel / 页面离开 / 全局开关被外部改回 ─→ abortRestore（恢复充电/禁流 + 恢复快照）→ cancelled
```

- **测试项结构**（`CLCompatTestCase`）：类型、路径配置要求（停充=关智能停充；智能停充=开；禁流=关全局开关）、发送的 API、判定参数。
- **单项被排除**（用户只选部分）时直接跳过；全部完成才进入 restoreSnapshot。
- **回稳失败**（15s 内 `IsCharging!=YES` 或电流≤0）：不中止流程，在最终结果里附"测试后充电恢复异常"警告文案；若发生在测试中途，下一项仍按计划执行（下一项本来就要重新控制）。

## 4. 单项测试判定规则（参数定稿）

采样：每 1s 一次 `get_bat_info`；有效电流 = `InstantAmperage`（缺失回退 `Amperage`）。

**停充 / 智能停充**

1. 前置基线：`IsCharging==YES`（否则该项标"无法测试"）。
2. 按路径切配置 → `set_charge_status(false)` → 监测计时开始（上限 120s）。
3. `IsCharging` 变 false 的时刻记为 t（状态变化耗时 = t）→ 进入**确认窗口 10s**（10 个样本）：
   - 10 个样本全部 `< 5mA` → **支持**（早停）。
   - 10 个样本全部 `≥ 5mA` → **无法支持**（停充后持续电流，早停）。
   - 混合 → 延长观察至 30s 总窗口，按 30 样本均值判定：`< 5mA` 支持，`≥ 5mA` 无法支持。
4. 120s 内 `IsCharging` 一直 true → **无法支持**（状态无变化）。

**禁流**

1. 基线同上（需在充电）。
2. `set_inflow_status(false)` → 监测（上限 120s）。
3. 状态变化判据（任一出现即记 t，依据 F9 以电流特征为主）：`ExternalChargeCapable==NO` / `ExternalConnected==NO` / `IsCharging==NO` / 电流转负（放电）。
4. t 后确认窗口判定与停充一致（电流 `< 5mA` 含放电负值视为"已断流"）。
5. 120s 无任何变化或确认窗口电流持续 `≥ 5mA` → **无法支持**。

**总体判定**

- 支持停充 或 支持智能停充（任一）→ 停充能力可用。
- 停充、智能停充、禁流全部无法支持 → **"既不支持停充也不支持禁流，设备不被 CL 支持"**。
- 仅智能停充可用时提示"建议在充电高级中开启智能停充使用"。

**结果记录**：每项 `{结论, 状态变化耗时, 监测期最大电流, 监测期最低电流}`；电流含监测全程（含确认窗口）样本的极值。

## 5. 前置检查与安全防护

- **前置四项**（逐项显示在 UI）：daemon 在线（`daemonAlive`）、已插电（`ExternalConnected`）、正在充电（`IsCharging==YES`）、电量 10%–95%。
- **互斥**：测试运行中禁用探针按钮；探针请求中禁用开始按钮；daemon 返回 `probe_busy`（status -12）时提示"探针运行中"。
- **全局开关防篡改**：每项测试开始前 `getConfig("enable")` 复核仍为 NO；被外部改回 YES → 中止全部测试并恢复快照，提示"CL 已被重新启用，测试中止"。
- **快照**：`NSUserDefaults` key `cl_compat_test_snapshot` 存 `{enable, adv_predictive_inhibit_charge}` 原值；恢复成功后删除。页面 `viewWillAppear` 检测残留 → 弹窗"上次测试未正常结束，是否恢复配置？"（恢复 / 丢弃）。
- **页面离开**：`viewWillDisappear`（非 push 探针结果场景）时若测试运行中 → 等价 cancel 路径。

## 6. 页面结构（自上而下）

1. **说明卡片**：用途一句话 + 风险提示（测试会真实停充/禁流，每项最长 2 分钟）。
2. **前置状态卡片**：四项检查图标态实时刷新。
3. **测试项选择卡片**：三个 UISwitch 行（默认全开），测试运行中禁用。
4. **操作按钮**：开始测试 / 取消测试（运行中互斥切换）。
5. **进度卡片**：当前项名称、进度条（单项内按 120s 或实际剩余）、已用时/预计剩余、实时电流（大号数字）、最近状态变化事件行。
6. **结果区**：每项一张结果卡（结论徽章色：支持=绿 / 无法支持=红 / 未测=灰）+ 最大/最低电流 + 状态变化耗时。
7. **总体判定卡片**：醒目总结文案。
8. **探针卡片**：运行按钮 + 最近探针结论摘要（复用 F7 解析）；测试运行中禁用。

本地化：全部文案走 `CLL(@"中文 key")`，en/zh-Hans strings 同步新增。

## 7. 错误处理

| 场景 | 处理 |
|------|------|
| `set_charge_status`/`set_inflow_status` 返回非 0 | 该项标"控制面写入失败，无法测试"，继续下一项 |
| 采样请求连续失败 ≥5 次 | 该项中止标"数据采集中断"，继续后续项 |
| 恢复充电/禁流写失败 | 结果页附恢复异常警告；快照仍恢复 |
| daemon 中途离线 | 中止全部测试 → abortRestore → 提示 |
| 强杀 App | 残留快照下次进入恢复（见 §5） |

## 8. 测试策略

1. **编译**：rootful 与 rootless 两 scheme xcodebuild（AGENTS.md 命令）。
2. **打包**：`./scripts/build_packages.sh` 冒烟。
3. **真机冒烟**（插电、电量中间段）：
   - 完整一键流程 → 三项依次执行、结果与 README 手动流程对照一致。
   - 状态快速变化时早停生效（不等满 120s）。
   - 单项重测（只勾禁流）。
   - 取消按钮 / 返回离开 → 配置恢复（回主页核对开关与智能停充状态）。
   - 探针按钮 → 结论摘要显示；测试中按钮互禁。
   - 切英文 → 全文案正确。
   - 测试中强杀 App → 重进页面 → 残留快照恢复提示。
4. **无 XCTest 基础设施**：判定逻辑以真机对照 README 手动流程为验收基准。

## 9. 风险与缓解

- [测试期间设备最多 6 分钟不受 CL 控制] → 120s 上限 + 早停 + 取消 + 自动恢复。
- [探针与测试并发导致写假成功（F5）] → UI 互斥 + probe_busy 提示。
- [禁流判据受 iOS17+ 派生值抖动影响（F9）] → 判定以电流特征 + IsCharging 为主。
- [恢复充电异常导致设备持续放电] → 回稳检测 + 结果页显著警告。
- [强杀 App 配置未恢复] → 快照持久化 + 进入页面残留检测恢复。
