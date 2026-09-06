# 提案：修复电池兼容性测试基线污染与禁流误判

## Why

真机冒烟（用户实测）发现两个问题：

1. **已停充状态进入测试即出问题**：前置检查把"正在充电"（`IsCharging==YES`）作为硬阻断（CLBatteryCompatibilityTestViewController.m:1150-1152 allOK 要求 charging），设备在进入测试页前已处于停充状态（电量达到目标、CL 已停充、系统自行停充）时无法开始测试；即使绕过，`beginTest` 基线检查（:417-420）也会报"基线异常"。
2. **禁流测试误判"未生效"**：禁流状态变化判定使用绝对条件 `(!extCapable || !extConnected || !isCharging || current < 0)`（:572-573），不是基线相对。污染链：前两项停充测试结束后的回稳会调 `set_charge_status(true)` 恢复充电 → 若系统随即又自行停充（电量偏高）或充电尚未真正建立，禁流测试首个样本 `!isCharging` 即触发"状态变化"（与禁流无关）→ 确认窗口内电池电流仍在充电（≥5mA）→ 误判"无法支持"。真正能证明禁流生效的 `ExternalConnected` 翻转被早期误触发掩盖。用户实测观察到"明明已生效但判定未生效"。

**复现与自动化说明**：问题依赖真实设备充电状态机（插电、电量、系统停充行为），本环境无法自动化复现；失败证据为用户真机实测描述 + 上述代码级根因定位（可静态复核）。

## What Changes

- 测试开始时自动恢复充电基线：`enable=NO` 写入后新增"恢复充电"阶段（轮询等待 `IsCharging==YES && 电流>0`，上限 20 秒），失败则以"无法恢复充电（可能已接近满电）"中止并自动恢复配置。
- `beginTest` 基线检查自愈：基线非充电时先尝试恢复充电（上限 10 秒）再复查，仍非充电才报"基线异常"。
- 禁流判定改为**基线相对信号**：发送指令前记录基线（ExternalConnected、电流），状态变化 = 「电源已连接」由真转假（主信号，用户确认此为其设备上可靠的生效标志）或电流由非负转放电（辅信号）；`IsCharging`/`ExternalChargeCapable` 不再作为禁流独立判据（满电自行停充时它们天然为假，是本次误判根源）。
- 前置检查不再把"正在充电"作为硬阻断，改为提示"开始时将自动恢复充电"。
- 说明区新增提示：测试期间请勿拔掉充电线（禁流判定依赖"电源已连接"状态切换，拔线会误判）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `battery-compatibility-test`: 前置检查不再硬阻断"正在充电"（改为自动恢复充电基线）；禁流测试判定改为基线相对信号（ExternalConnected 翻转为主 + 电流转放电为辅）。需 delta spec。

## Impact

- 修改：`ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`（引擎判定与恢复流程、前置检查、说明文案）、`ChargeLimiter/en.lproj/Localizable.strings`、`ChargeLimiter/zh-Hans.lproj/Localizable.strings`（新增文案）。
- 复用不改：daemon 全部 API。
