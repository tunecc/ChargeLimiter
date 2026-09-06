# 设计：修复电池兼容性测试基线污染与禁流误判

## Context

根因与复现说明见 proposal.md。核心事实：daemon 侧禁流稳态下 `ExternalConnected/ExternalChargeCapable` 均为假（daemon.mm isAdaptorConnect），但满电自行停充时 `IsCharging/ExternalChargeCapable` 也为假——所以禁流判据必须用"基线相对变化"而不是绝对状态；`ExternalConnected` 翻转（插电不动的前提下）是禁流特有的语义信号（用户实测确认）。

## 修复方案（单一方案）

1. **恢复充电基线阶段**（引擎 `startWithSelection:`）：`enable=NO` 写入后，发送 `set_charge_status(true)` 并轮询（1s 间隔，上限 20s）等待 `IsCharging==YES && current>0`；超时失败 → abort"无法恢复充电（可能已接近满电），请在电量较低时重试"。daemon 在 `enable=false` 时本就自动 `resetBatteryStatus()` 恢复充电（F2），此阶段通常立即通过，属兜底自愈。
2. **基线快照**（`beginTest:`）：发送指令前的基线采样中记录 `bCharging / bExtConnected / bCurrent`。
3. **基线相对判定**（`handleSample:`）：
   - 停充/智能停充：`changed = bCharging && !isCharging`（基线已确保充电中，等价现行为）。
   - 禁流：`changed = (bExtConnected && !extConnected) || (bCurrent >= 0 && current < 0)`。`IsCharging`/`ExternalChargeCapable` 不再作为独立判据。
4. **基线自愈**（`beginTest:`）：基线非充电 → 先尝试恢复充电（上限 10s）→ 复查；仍非充电 → Error"基线异常：无法恢复充电"。
5. **前置检查**：`charging` 不再计入 allOK 阻断；该行状态为否时显示"未在充电，开始时将自动恢复"（橙色提示）。
6. **说明区**：新增"测试期间请勿拔掉充电线"与"开始时自动恢复充电基线，电量接近满电可能导致无法开始"提示。

## Risks / Trade-offs

- [满电时系统自行停充仍可能让停充测试误判"支持"] → 与 README 手动流程同样的方法学限制；恢复充电基线失败会中止并提示电量较低时重试，说明区明示。
- [ExternalConnected 在 iOS17+ 有抖动] → 抖动是"假边沿"，稳态值可靠（daemon 自身以它判断禁流稳态）；确认窗口机制天然过滤单点抖动。
- [拔线场景] → 说明区提示勿拔线；拔线后 ExternalConnected 变假会被当作禁流生效——已知限制，文档化。
