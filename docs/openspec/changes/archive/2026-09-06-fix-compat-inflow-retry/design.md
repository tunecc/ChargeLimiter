# 设计：修复禁流测试信号漏检与系统对抗误判

## Context

根因见 proposal.md。关键事实：①daemon 自身禁流实现带重试（`isDisableInflowRetryEligible` / `armDisableInflowRetryIfNeeded`），因为单次禁流写会被 iOS 恢复；②用户设备上禁流生效表现为 IsCharging 翻转，电流不转负、ExternalConnected 不翻转；③README 成功判据是"120 秒内状态有变化"，失败判据是"禁流后有较大持续电流（≥5mA）"。

## 修复方案（单一方案）

1. **禁流信号集**（基线锚定前提下）：`changed = (bCharging && !isCharging) || (bExtConnected && !extConnected) || (bCurrent >= 0 && current < 0)`。基线自愈保证基线时刻正在充电，故 IsCharging 翻转是真实生效信号；满电自行停充的污染已被"基线恢复充电"步骤排除（基线时刻电流 >0 且刚恢复，120 秒窗口内自行停止仍可能，但 README 语义本身以此为准）。
2. **系统对抗重试**：确认窗口内检测到充电被恢复（`isCharging && current ≥ 5mA`）时，若重试次数 <3 → 重新下发 `set_inflow_status(false)`（带 in-flight 计数与防重入）、重置确认窗口继续监测；重试耗尽 → 判"无法支持（禁流无法维持）"。
3. **结果统计口径**：引擎在确认窗口内另记 `confirmMaxA/confirmMinA`；verdict 事件优先携带确认窗口统计（有状态变化时），无状态变化（120s 超时）时携带全程统计。结果卡文案改为"判定窗口电流最大/最低"。
4. **说明文案**：新增"前置检查显示的是点击开始时的状态"提示。

## Risks / Trade-offs

- [满电时基线恢复后系统自行停充仍可能让禁流误判"支持"] → 基线时刻电流 >0 且充电刚恢复，与 README 手动测试的方法学限制一致；说明区已提示电量较低时重试。
- [重试期间事件流噪音] → 重试通过 PhaseChanged 事件提示用户"正在重新下发"，结果卡仍为单一结论。
