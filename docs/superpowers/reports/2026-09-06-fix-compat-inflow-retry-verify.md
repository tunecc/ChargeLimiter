# 验证报告：fix-compat-inflow-retry

- 日期：2026-09-06
- 分支：feature/20260906/battery-compatibility-test-page（hotfix：current 隔离）
- 验证模式：full（5 任务 > 3；scale 评估 Result: full）
- 产物语言：zh-CN

## Summary

| 维度 | 状态 |
|------|------|
| Completeness | tasks.md 5 项全部完成（3.1 真机复测部分由用户执行，显式记为 WARNING 开放项）；两条 MODIFIED 需求全部实现 |
| Correctness | 根因消除检查通过：旧禁流条件（无 IsCharging 翻转）已不存在、结果卡旧文案"最大电流/最低电流"已替换、说明区新增前置检查 tip（file:line 证据见下） |
| Coherence | 实现与 hotfix design.md 四点方案一致；delta spec 9 个场景全部有实现映射，无矛盾 |

## 检查明细（7 项，full 路径）

1. **tasks.md 全部处置**：PASS（1.1/1.2/2.1/2.2 完成 + 3.1 编译打包冒烟完成、真机复测记为 WARNING-1 开放项）。
2. **符合 change design.md**：PASS——①禁流信号集恢复三信号并列（:667-669 `bCharging && !isCharging`、`bExtConnected && !extConnected`、`bCurrent >= 0 && current < 0`，注释 :659-663 更新为基线锚定下 IsCharging 翻转即真实信号）；②系统对抗重试（:694-725 确认窗口内 `isCharging && current >= 5mA` 触发，`inflowRetryInFlight` 防重入 + beginWrite/endWrite 在途计数，重试 ≤ `CLCompatInflowMaxRetries=3`（:47），重置确认窗口 :716-718 与判定窗口统计同步重置；耗尽判 Unsupported "禁流无法维持：充电被系统恢复且重试已耗尽" :701-703；重试事件 PhaseChanged 提示 "禁流被系统恢复，正在重新下发禁流（第 %d 次）" :707）；停充类不加重试（重试分支仅 `currentKind == Inflow` 进入）；③结果统计口径（finishTestWithVerdict :763-765 `changeElapsed >= 0` 时携带 confirmMaxA/confirmMinA，否则全程 maxA/minA；判定窗口统计由状态变化样本初始化 :677-679，确认窗口每样本更新 :693）；④说明文案（:1097 新增前置检查 tip）。
3. **符合技术设计**：hotfix 预设无独立 superpowers Design Doc，change design.md 即设计事实源（已核对）。
4. **spec 场景**：delta spec 两条 MODIFIED 需求 9 个场景全部有实现映射——禁流生效判支持（allBelow → Supported :737）、充电停止即信号（:667）、系统对抗时重新下发（:694-725）、重试耗尽判不支持（:701-703）、系统自行停充不触发误判（信号集不含 ExternalChargeCapable，grep 全文件无引用）、禁流后电流持续判不支持（120s 超时 :686-688）、结果页展示分项与总体判定（结果卡 + 总体判定逻辑未破坏，行标题改判定窗口口径 :1181-1182）、支持结论的电流口径（:763-765）、双不支持总体判定（总体判定逻辑保持）。真机实际行为 = WARNING-1 开放项。
5. **proposal 目标**：三个用户报告问题的根因均已消除——①禁流误判（信号集缺 IsCharging 翻转 + 无系统对抗重试）已修复；②结果卡电流口径误导（全程统计 → 判定窗口统计）已修复；③前置检查"正在充电"行状态说明缺失已补 tip。
6. **delta spec 与 design 无矛盾**：PASS——判定信号、重试上限与耗尽语义、统计口径、文案一一对应。
7. **设计文档可定位**：PASS——change design.md 位于 change 目录，归档时随目录移动。

## 构建与打包证据（修复后最新运行）

- rootful xcodebuild → BUILD SUCCEEDED
- rootless xcodebuild → BUILD SUCCEEDED
- `./scripts/build_packages.sh` → [OK] Done，四类包产出（TrollStore/rootful/rootless/roothide，out/ChargeLimiter_1.15.3_*）
- plutil -lint 双语 Localizable.strings → OK

## Issues

### CRITICAL

（无）

### WARNING

- **WARNING-1（已接受偏差）：真机复测未执行（延期开放项）**
  - 内容：用户自测清单——插电、电量中等时完整跑三项，重点验证：①禁流测试在禁流生效（IsCharging 翻转、电流不转负）时应判"支持"而非 120s 超时误判；②充电被系统恢复时应看到"禁流被系统恢复，正在重新下发禁流（第 N 次）"事件并重试，最多 3 次后若仍被恢复应判"无法支持（禁流无法维持）"；③停充结果卡应显示判定窗口（状态变化后）电流而非全程值；④前置检查行说明 tip 可见。
  - 原因：验证执行时用户在真机侧待命但本轮未执行；本环境无真实充电状态机。
  - 影响范围：修复的代码路径已经两道静态验证（根因消除 grep + 双 scheme 编译 + 打包冒烟），但真实设备上的端到端行为未经实测。
  - 处置：归档提交后提醒用户用最新 out/ 包复测（用户已知会）；如仍异常按 hotfix 流程再开修复 change。

### SUGGESTION

- S1：重试写在途期间的采样既不进入窗口判定也不进入判定窗口统计，结构上可把"在途跳过"抽成独立早退条件（纯重构建议，未做）。

## Final Assessment

**无 CRITICAL 问题。1 个已接受 WARNING（真机复测延期）。验证通过，可进入归档前最终确认。**
