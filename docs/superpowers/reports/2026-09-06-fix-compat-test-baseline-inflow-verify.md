# 验证报告：fix-compat-test-baseline-inflow

- 日期：2026-09-06
- 分支：feature/20260906/battery-compatibility-test-page（hotfix：current 隔离）
- 验证模式：full（5 任务 > 3）
- 产物语言：zh-CN

## Summary

| 维度 | 状态 |
|------|------|
| Completeness | tasks.md 4 完成 + 1 显式延期（真机复测，见 WARNING-1）；两条 MODIFIED 需求全部实现 |
| Correctness | 根因消除检查通过：旧绝对判定条件已移除、前置检查不再硬阻断 charging、基线相对判定与自愈逻辑就位（file:line 证据见下） |
| Coherence | 实现与 hotfix design.md 六点方案一致；delta spec 与 design 无矛盾 |

## 检查明细（7 项，full 路径）

1. **tasks.md 全部处置**：PASS（4 完成 + 真机复测显式延期记录 + OPEN 节）。
2. **符合 change design.md**：PASS——①恢复充电基线阶段（:365-380，enable=NO 后 setChargeStatus:YES + waitChargingBaseline 20s，失败 abort）；②基线快照（armTest:battery: 记录 bCharging/bExtConnected/bCurrent）；③基线相对判定（:654-659 禁流 `bExtConnected && !extConnected` 或 `bCurrent >= 0 && current < 0`，停充 `bCharging && !isCharging`）；④基线自愈（acquireBaselineThenArm 非充电先恢复 ≤10s 再复查）；⑤前置检查 charging 不阻断（allOK 仅 daemon/plugged/battery，:1232）、charging 行橙色提示；⑥说明区勿拔线 + 自动恢复提示（:1044-1045）。
3. **符合技术设计**：hotfix 预设无独立 superpowers Design Doc，change design.md 即设计事实源（已核对）。
4. **spec 场景**：delta spec 两条 MODIFIED 需求的 6 个场景中，代码级可验证场景全部有实现映射（见第 2 条证据）；充电基线无法恢复中止、真机实际翻转行为 = 真机复测开放项。
5. **proposal 目标**：两个用户报告问题的根因均已按修复目标消除（根因消除检查：旧条件 `!extCapable || !extConnected || !isCharging || current < 0` 已不存在，`ExternalChargeCapable` 仅存于注释）。
6. **delta spec 与 design 无矛盾**：PASS——判定信号、自愈窗口、提示文案一一对应。
7. **设计文档可定位**：PASS——change design.md 位于 change 目录，归档时随目录移动。

## 构建与打包证据（修复后最新运行）

- rootful xcodebuild → BUILD SUCCEEDED
- rootless xcodebuild → BUILD SUCCEEDED
- `./scripts/build_packages.sh` → [OK] Done，四类包产出（TrollStore/rootful/rootless/roothide）

## Issues

### CRITICAL

（无）

### WARNING

- **WARNING-1（已接受偏差）：真机复测未执行（延期开放项）**
  - 内容：用户自测清单——插电、电量中等：完整三项、已停充状态进入测试（应自动恢复充电基线后执行）、禁流生效判定（不拔线，应判"支持"）、取消恢复。
  - 原因：验证执行时用户暂不可用；本环境无真实充电状态机。
  - 影响范围：两个修复的代码路径已经两道静态验证（根因消除 grep + 编译），但真实设备上的端到端行为未经实测。
  - 处置：归档提交后提醒用户用最新 out/ 包复测；如仍异常按 hotfix 流程再开修复 change。

### SUGGESTION

- S1：`waitChargingBaseline` 与回稳轮询结构相似，后续可抽公共辅助（纯重构建议，未做）。

## Final Assessment

**无 CRITICAL 问题。1 个已接受 WARNING（真机复测延期）。验证通过，可进入归档前最终确认。**
