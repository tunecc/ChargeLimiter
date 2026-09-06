# Brainstorm Summary

- Change: battery-compatibility-test-page
- Date: 2026-09-06

## 确认的技术方案

用户已确认（2026-09-06）：

1. **架构方案 A**：UI 侧测试引擎（`CLBatteryCompatibilityEngine`，与 `CLBatteryCompatibilityTestViewController` 同文件实现，遵循项目多类同文件惯例）+ `get_bat_info` 原始响应 1 秒直读轮询；零 daemon 改动。引擎通过 block 回调推送进度事件，控制器只做渲染。
2. **分路径测试**：停充测试临时关闭 `adv_predictive_inhibit_charge`（测传统 IsCharging 写法）；智能停充测试临时开启它（测 PredictiveChargingInhibit 写法）；禁流测试临时关闭全局开关后 `set_inflow_status(false)`。
3. **编排状态机**：前置检查 → 快照 → 停充 → 回稳 → 智能停充 → 回稳 → 禁流 → 恢复快照 → 结果；任一环节可取消并恢复。
4. **判定规则**：状态变化（120s 上限）→ 确认窗口 10s（10 样本全 <5mA 支持 / 全 ≥5mA 不支持 / 混合延长 30s 按均值）→ 结论；每项记录最大/最低电流、状态变化耗时。
5. **回稳**：每项结束恢复充电/禁流并等基线（IsCharging==YES 且电流>0，最长 15s）；恢复异常在结果页标警告。
6. **前置检查**：daemon 在线、已插电、正在充电、电量 10%–95%。
7. **安全防护**：每项开始前复核全局开关仍关闭；测试与探针互斥（按钮互禁 + probe_busy 提示）；快照持久化 NSUserDefaults（`enable`、`adv_predictive_inhibit_charge`），完成/取消/离开三路径恢复，强杀后残留快照下次进入提示恢复。
8. **页面结构**：说明 → 前置状态 → 测试项选择（默认全选可单项）→ 开始/取消 → 进度（实时电流）→ 结果×3 → 总体判定（双不支持=设备不被 CL 支持）→ 探针卡片。
9. **Spec Patch**：delta spec 补充停充测试路径语义与"停充生效但电流持续 ≥5mA"边界场景。

## 关键取舍与风险

- 编排放 UI 侧（daemon 是常驻进程，出错威胁主功能；现有 API 已够用）——已定。
- 测试期间真实停充/禁流最多 6 分钟：120s 上限 + 早停 + 可取消 + 自动恢复控制风险。
- 测试与探针互斥：探针运行期间控制写假成功（daemon `g_chargeControlProbeRunning` 时 return 0）。
- `set_config enable=false` 副作用：daemon 自动 resetBatteryStatus（恢复充电）——与测试起点（正在充电）一致，无冲突。
- iOS17+ 禁流态 External* 派生值息屏抖动：禁流判定以 IsCharging + 电流特征为主，External* 为辅。
- daemon predictive 写失败自动 fallback legacy：智能停充测试结论以观测为准（状态变化即支持）。

## 测试策略

rootful + rootless 双 scheme xcodebuild 编译；`./scripts/build_packages.sh` 打包冒烟；真机手动冒烟（完整流程/取消恢复/单项重测/探针/双语/强杀后快照恢复），判定与 README 手动流程对照。

## Spec Patch

回写 `specs/battery-compatibility-test/spec.md`：
1. "停充测试判定"需求补充：停充测试 SHALL 临时关闭智能停充配置以覆盖传统停充写法。
2. "智能停充测试判定"需求补充：SHALL 临时开启智能停充配置以覆盖 PredictiveChargingInhibit 写法。
3. 新增边界场景：停充生效但确认窗口电流持续 ≥5mA → 判定无法支持停充。
