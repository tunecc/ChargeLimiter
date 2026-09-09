---
generated_from_state_version: 14
---

# 验证

## 当前结果

- 结果: **已归档**
- 验证情况: **已完成检查，验证结果已确认**
- 目标周期: 2
- 迭代: 1
- 验证器尝试次数: 1
- 完成时间: 2026-09-09T06:22:51.048Z
- 摘要: main HEAD 99635a0 在代码层完整满足修订后验收 A1-A4：b8c0764 在位且读数驱动闭环符号源码零残留，thermal 写入收敛为 setThermalSimulationMode 唯一入口并仅由充电命令边沿与配置变更边沿驱动（onBatteryEventEnd 为空、无定时器直达写入），关闭限流时决策函数返回默认档，充电控制相关既有单测全部通过。遗留项均为 brief 明确移出验收的 Non-goals 或元数据级红项，不阻塞归档。

## 验收

| 编号 | 结果 | 来源 | 验收项 | 原因 |
| --- | --- | --- | --- | --- |
| A1 | passed | brief.md | A1：交付物 `b8c0764` 在 main HEAD 在位；读数驱动闭环符号（desired/sync 闭环、60s 自愈定时器、200ms 去抖、读回校验、粘滞兜底）全仓源码零残留，既有测试 `scripts/tests/test_limit_inflow_command_driven.py` 通过。 | git merge-base --is-ancestor b8c0764 main 退出码 0，b8c0764 确为 main HEAD 99635a0 祖先；b8c0764 删除 daemon.mm 闭环约 220 行、utils.mm 9 行并删除 test_thermal_lockscreen_hold.py / test_thermal_session_gate.py（两文件已不存在）。对 desiredThermalSimulationModeForCurrentState\|syncThermalSimulationModeForCurrentState\|getThermalSimulationModePref\|refreshThermalSelfHealTimer\|g_thermalSelfHealTimer\|g_thermalLimitActive\|kThermalLimitStickyWindowSeconds\|thermal_session_sticky_hold\|thermal_write_unconfirmed\|thermal_desired_downgrade\|debounce 在 *.mm/*.h/*.m/*.c/*.cpp/*.py/*.swift 全仓扫描零命中（仅 CHANGELOG.md:38 历史记载，非源码）；daemon.mm 已无任何 dispatch_source_create。scripts/tests/test_limit_inflow_command_driven.py 本机重跑 7 tests OK，与 Runtime 检查一致。 |
| A2 | passed | brief.md | A2：thermal 模式写入唯一入口为 `setThermalSimulationMode`（NSUserDefaults suite=com.apple.cltm），仅由充电命令边沿（setBatteryStatus 停充→默认档/开充→限流档）与配置变更边沿（set_conf / set_limit_inflow）触发；电池事件流不参与（onBatteryEventEnd 为空），无任何定时器可达 thermal 写入。 | thermal 写入唯一入口 setThermalSimulationMode（utils.mm:3539-3545，NSUserDefaults suiteName=com.apple.cltm 写 thermalSimulationMode），全仓仅两个调用点：daemon.mm:1835（applyThermalModeForCurrentState）与 daemon.mm:1878（restoreThermalSimulationForReset 写 off，仅限卸载/退出复位链，非限流控制）。applyThermalModeForCurrentState 触发点全部为边沿：setBatteryStatus（daemon.mm:1843，停充→g_chargeCommandEnabled=NO→默认档/开充→YES→限流档，见决策函数 1821-1832）、set_conf（daemon.mm:3578-3586，键 adv_def_thermal_mode/adv_limit_inflow/adv_limit_inflow_mode/adv_thermal_mode_lock）、set_limit_inflow_config（daemon.mm:3617）。onBatteryEventEnd 为空（daemon.mm:2607-2610，仅注释，调用点 3284/3313）。决策函数只读 4 个配置键+g_chargeCommandEnabled，不读系统实时信号。全 daemon 仅 3 个 NSTimer（752 holdMonitor、774 disableInflowRetry、862 trollStoreBundleCheck）：前两者只能经 refreshBatteryStateAndApplyPolicy→applyChargePolicy 的充电命令边沿间接连带 thermal 写入，无定时器直接发起 thermal 写；无 60s 自愈定时器残留。 |
| A3 | passed | brief.md | A3：关闭限流（`adv_limit_inflow` off 且无 `adv_thermal_mode_lock`）后，集中决策函数返回默认 thermal 档（`adv_def_thermal_mode`，默认关闭）。 | targetThermalModeForCurrentState（daemon.mm:1821-1832）：lock=NO 跳过锁定分支；limitInflow=NO 跳过限流分支，返回 defaultMode=getLocalString(@"adv_def_thermal_mode", @"off")；initConf 默认值 adv_def_thermal_mode: off（daemon.mm:3348）。即 adv_limit_inflow off 且无 adv_thermal_mode_lock 时集中决策函数返回默认档（默认关闭），不依赖任何电池读数。 |
| A4 | passed | brief.md | A4：停充、恢复充电既有控制路径无回归：仓库既有相关单测全部通过。 | 停充/恢复充电相关既有单测全部通过：本机运行 16 个相关模块（test_limit_inflow_command_driven/atomic_config/store_batch/ui_atomic、test_ios17_charge_override_paths、test_ios17_inflow_flicker_guard、test_ios17_ui_hold_status_display、test_temp_pause_hysteresis、test_charge_enable_verify、test_charge_control_probe_logic、test_key_readpoint_rewiring、test_smart_charge_reset_logic、test_smart_charge_restore_after_disable、test_acccharge_lpm_boot_recovery、test_thermal_mode_live_refresh、test_config_write_failure_feedback）共 72 tests OK；test_limit_inflow_command_driven 单独以 Runtime 同命令重跑亦通过（7 tests OK）。全仓 205 项中唯一失败为 test_version_single_source.test_release_version_is_consistent（版本号元数据期望 1.15.2 vs 实际 1.15.3），与停充/恢复充电控制路径无关，不落入 A4 的相关单测范围。 |

## 检查

| 检查 | 命令 | 工作目录 | 状态 | 退出码 | 耗时 |
| --- | --- | --- | --- | ---: | ---: |
| git-ancestor-b8c0764 | merge-base --is-ancestor b8c0764 main | . | passed | 0 | 20 ms |
| git-worktree-clean | status --porcelain | . | passed | 0 | 17 ms |
| test-limit-inflow-command-driven | -m unittest scripts.tests.test_limit_inflow_command_driven -v | . | passed | 0 | 73 ms |

## 阻塞项

_无。_

## 风险与跳过的工作

- 锁屏真机 thermal 限流有效性未验证——brief 已按 2026-09-09 决定移入 Non-goals，按上游文档化系统限制对待。
- legacy chaoge.ChargeLimiter launchd job 清理未实现（postinst 未清理旧 job），已决定另立 change。
- 拔线后 thermalSimulationMode 残留限流档至下一次充电命令边沿——已记录为 b8c0764 明示接受的原版行为。
- 无 cltm pref 读回诊断能力，'pref 被清除'与'有效 state 回落'现场不可区分，作为已知限制遗留。
- test_version_single_source.test_release_version_is_consistent 在 main HEAD 为红：79f2658 将版本 bump 至 1.15.3 但未同步测试期望 1.15.2；与充电控制无关且不属 A4 范围，建议后续小改修正。
- TrollStore bundle 检查定时器（daemon.mm:862）在 bundle 丢失路径经 resetBatteryStatusWithContext(YES,@"bundle_missing")→restoreThermalSimulationForReset 写 off（daemon.mm:847/1877-1879），属退出前复位恢复语义（写默认 off，非限流写入），对命令驱动语义无影响。

## 之前的迭代

| 目标周期 | 迭代 | 尝试 | 结果 | 未解决项 | 摘要 | 完成时间 |
| ---: | ---: | ---: | --- | --- | --- | --- |
| 1 | 1 | 1 | fail | A1, A2, A3, A4, A5 | 交付物 b8c0764 本身在 main HEAD 完整在位：desired 读数闭环/自愈/去抖/读回/粘滞零残留，thermal 写入收敛为命令与配置边沿唯一入口，代码层根因修复成立。但逐项验收中 A2（legacy launchd 清理交付物缺失）与 A5（拔线后限流档残留，不恢复默认 thermal 模式）为代码层可判定的不满足，判 failed；A1/A3/A4 因锁屏真机配对证据未采集（2026-09-09 收尾决定放弃）判 blocked。按收尾决定不改变未满足项判定，整体 verdict 为 fail。 | 2026-09-09T05:12:43.649Z |
| 1 | 2 | 0 | recovery | — | Native confirmed acceptance criteria changed | 2026-09-09T06:00:23.624Z |
| 2 | 1 | 1 | pass | — | main HEAD 99635a0 在代码层完整满足修订后验收 A1-A4：b8c0764 在位且读数驱动闭环符号源码零残留，thermal 写入收敛为 setThermalSimulationMode 唯一入口并仅由充电命令边沿与配置变更边沿驱动（onBatteryEventEnd 为空、无定时器直达写入），关闭限流时决策函数返回默认档，充电控制相关既有单测全部通过。遗留项均为 brief 明确移出验收的 Non-goals 或元数据级红项，不阻塞归档。 | 2026-09-09T06:22:51.048Z |



## 结论

main HEAD 99635a0 在代码层完整满足修订后验收 A1-A4：b8c0764 在位且读数驱动闭环符号源码零残留，thermal 写入收敛为 setThermalSimulationMode 唯一入口并仅由充电命令边沿与配置变更边沿驱动（onBatteryEventEnd 为空、无定时器直达写入），关闭限流时决策函数返回默认档，充电控制相关既有单测全部通过。遗留项均为 brief 明确移出验收的 Non-goals 或元数据级红项，不阻塞归档。
