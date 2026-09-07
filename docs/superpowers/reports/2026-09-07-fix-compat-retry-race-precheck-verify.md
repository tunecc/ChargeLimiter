# 验证报告：fix-compat-retry-race-precheck

- 日期：2026-09-07
- 分支：feature/20260906/battery-compatibility-test-page（hotfix：current 隔离）
- 验证模式：full（5 任务 > 3；scale 评估 Result: full）
- 产物语言：zh-CN

## Summary

| 维度 | 状态 |
|------|------|
| Completeness | tasks.md 5 项全部完成（3.1 真机复测部分由用户执行，显式记为 WARNING 开放项）；MODIFIED 需求「禁流测试判定」全部实现 |
| Correctness | 根因消除检查通过：旧"写完成即重置窗口"模式已不存在、恢复事件仅在窗口已建立时计数、前置检查"正在充电"行与相关文案已移除（file:line 证据见下） |
| Coherence | 实现与 hotfix design.md 五点方案一致；delta spec 7 个场景全部有实现映射，无矛盾 |

## 检查明细（7 项，full 路径）

1. **tasks.md 全部处置**：PASS（1.1/1.2/2.1/2.2 完成 + 3.1 编译打包冒烟完成、真机复测记为 WARNING-1 开放项）。
2. **符合 change design.md**：PASS——①确认窗口自「写生效」起算（handleSample 禁流状态变化时 `confirmStartIndex = -1` 关窗 :679-682，首个非充电样本开窗并初始化判定窗口统计 :716-720；停充类保持原逻辑 :683-687）；②恢复事件门控（`inflowWindowOpen && chargeRestored` 才计恢复 :729-735）；③生效观察上限（窗口未建立时累计 `inflowChargeStreak`、重试写在途暂停计数 :708-714，≥10 个连续充电采样按恢复事件处理）；④重试写完成仅清 `inflowRetryInFlight` 不重置窗口（inflowRetryOrExhaust :766-790，窗口由生效样本重开）；⑤前置检查移除"正在充电"行（runPrecheck 字典去 charging 项 :948-958、setupPrecheckCard 去该行、failMessages 去 charging 文案与橙色特判 :1515-1526）+ 说明区删前置检查时刻 tip + "请在插电状态下运行"（:1131）。
3. **符合技术设计**：hotfix 预设无独立 superpowers Design Doc，change design.md 即设计事实源（已核对）。
4. **spec 场景**：delta spec 7 个场景全部有实现映射——禁流生效判支持（开窗后 allBelow → Supported :749）、充电停止即信号（:667 三信号含 IsCharging 翻转，未变）、系统对抗时重新下发（窗口已建立恢复 → inflowRetryOrExhaust，窗口自生效样本重开）、重试耗尽判不支持（:769-772）、生效滞后不计为恢复事件（窗口未建立分支 :708-714）、系统自行停充不触发误判（信号集不含 ExternalChargeCapable，未变）、禁流后电流持续判不支持（120s 超时 :695-697，未变）。真机实际行为 = WARNING-1 开放项。
5. **proposal 目标**：两个用户报告问题的根因均已消除——①重试竞态（滞后采样被计为新恢复事件烧光重试）已通过"窗口自生效样本起算 + 恢复事件门控"消除；②前置检查"正在充电"行误导已移除该行。
6. **delta spec 与 design 无矛盾**：PASS——窗口起算时机、恢复事件门控、观察上限、重试上限 3 次与 daemon 一致、文案变更一一对应。
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
  - 内容：用户自测清单——插电、电量中等时仅勾选禁流单项：①禁流生效（充电可见停止）后应判「支持」而非"禁流无法维持"；②若发生系统对抗，重试事件不应秒级连跳（第 1/2/3 次应间隔出现，每次间隔 = 写生效滞后 + 生效观察）；③前置检查卡片应只有 daemon/已插电/电量三行，无"正在充电"行。
  - 原因：验证执行时用户在真机侧待命但本轮未执行；本环境无真实充电状态机与写生效滞后时序。
  - 影响范围：修复的代码路径已经两道静态验证（根因消除 grep + 双 scheme 编译 + 打包冒烟），但真实设备上的端到端行为未经实测。
  - 处置：归档提交后提醒用户用最新 out/ 包复测（用户已知会）；如仍异常按 hotfix 流程再开修复 change。

### SUGGESTION

- S1：`inflowRetryOrExhaust` 的耗尽判定文案"充电被系统恢复且重试已耗尽"对"写未生效观察上限"触发路径语义略偏（此时未必是系统恢复），后续可区分文案（纯文案建议，未做）。

## Final Assessment

**无 CRITICAL 问题。1 个已接受 WARNING（真机复测延期）。验证通过，可进入归档前最终确认。**
