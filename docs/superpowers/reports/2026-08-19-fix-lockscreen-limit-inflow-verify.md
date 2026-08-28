# 验证报告：fix-lockscreen-limit-inflow（轻量验证）

日期：2026-08-19 · verify_mode: light（覆盖说明见下）· review_mode: off

## 规模评估说明

`comet state scale` 自动判定 full（任务数 10 > 3），手动覆盖为 **light**：任务数超阈值源于 tasks.md 把测试、实现、验证拆为 10 个细项（含 2 项测试任务）；实际改动 **3 个文件、194+/6-，单一模块（daemon.mm）+ 2 个测试文件**，无 delta spec、无跨模块协调，符合轻量阈值（≤8 文件、≤1 capability）。提交区间复核：`git diff --stat 8230105...HEAD` 确认 3 文件。

## 6 项检查结果

| # | 检查项 | 结果 | 证据 |
|---|---|---|---|
| 1 | tasks.md 全部 `[x]` | PASS | 10/10 已勾选，0 未完成（3.4 真机验收清单已写入 acceptance.md，执行归用户） |
| 2 | 改动文件与 tasks 一致 | PASS | daemon.mm + test_thermal_lockscreen_hold.py（新增）+ test_thermal_session_gate.py（断言更新），与 tasks 1.1/1.2/2.x 完全对应 |
| 3 | 编译通过 | PASS | xcodebuild rootful / rootless / roothide 三 scheme fresh run 全部 BUILD SUCCEEDED（2026-08-19） |
| 4 | 相关测试通过 | PASS | 全仓 33/33 python 测试 OK（fresh run），含新增 test_thermal_lockscreen_hold 6 项 |
| 5 | 无明显安全问题 | PASS | 新增代码安全扫描 0 命中（无密钥/strcpy/sprintf/system/popen）；新增代码仅 NSDictionary 判定与 policy event 记录 |
| 6 | 代码审查策略 | SKIP（配置） | review_mode: off，按配置跳过自动 code review。已在 build 阶段完成自审（发现并修复初版粘滞兜底两处 Critical：退出信号逻辑反、UPS 漏判，commit 8cb6e3c） |

## RED→GREEN 证据

- test_thermal_lockscreen_hold.py 初次运行：FAILED (failures=5)，失败原因均为本 bug 对应缺失实现
- 实现后：OK（6/6）
- test_thermal_session_gate.py 更新断言后初次运行：FAILED (failures=1)（旧代码仍含 isAdaptorConnect）→ 实现后 OK

## 验证范围外（用户真机验收，acceptance.md A1-A5）

锁屏 ≥30min 限流保持、无持续 thermal_desired_downgrade、拔插恢复、未插电不残留（672ab65 回归防护）、关闭限流恢复电流。归档前建议完成。

## 结论

轻量验证 6 项全部 PASS（第 6 项按配置 SKIP），无 CRITICAL / IMPORTANT 问题。

---

## 第二轮验证（改道退回原版语义后，2026-08-19）

真机验收 A1-A5 失败 → verify-fail → build 改道：整体退回原版命令驱动语义（b8c0764）。

| 检查项 | 结果 | 证据 |
|---|---|---|
| tasks.md 4.x 改道任务全部完成 | PASS | 5/5（对照原版定位、删闭环、恢复原版写法、删过时测试、提交） |
| 改动与退回方案一致 | PASS | daemon.mm -220+17 / utils.mm -9 / utils.h -1；净删 desired/sync 闭环、自愈定时器、去抖、粘滞兜底、getThermalSimulationModePref；无残留引用（14 个符号全 clean） |
| 编译通过 | PASS | rootful/rootless/roothide 三 scheme BUILD SUCCEEDED（fresh run） |
| 测试通过 | PASS | 全仓 168/168 OK（删 4 个断言对象已不存在的 thermal 测试文件；保留 mode_live_refresh） |
| 安全扫描 | PASS | 新增代码即原版已发布多年的写法，无新引入面 |
| code review | SKIP | review_mode: off（hotfix profile） |

**验证范围外（用户真机验收，沿用 A1-A5）**：锁屏 ≥30min 限流保持、拔插恢复、未插电不残留、关闭限流恢复电流。退回后语义与原版一致，原版多年无锁屏失效报告。

**结论**：第二轮轻量验证全部 PASS。

---

## 第三轮验证（真机验收通过后归档前，2026-08-28）

### 范围升级说明

本 change 在 2026-08-19 从 hotfix 升级为 full workflow（preset-escalate），补全 Design Doc（`docs/superpowers/specs/2026-08-20-fix-lockscreen-limit-inflow-design.md`，命令驱动 + 原子配置方案）后重新进入 build。第二轮记录的"退回原版语义（b8c0764）"是本 change 内的中间回退，不是最终交付；最终交付为 `2132c4b`（原子限流配置——命令驱动 + set_limit_inflow_config + 批量写）及其后的状态提交 `0103ae3`，已合并 `main`。本轮验证覆盖该最终交付。

### 静态证据（本机 fresh，2026-08-28）

| # | 检查项 | 结果 | 证据 |
|---|---|---|---|
| 1 | tasks.md 全部 `[x]` | PASS | 28/28 已勾选，含 6.1-6.5 真机验收（acceptance.md A1-A6 已全部勾选） |
| 2 | 最终改动与 Design Doc 一致 | PASS | `targetThermalModeForCurrentState` 集中决策函数（daemon.mm:1821）只读 `g_chargeCommandEnabled` + `adv_thermal_mode_lock`/`adv_def_thermal_mode`/`adv_limit_inflow`/`adv_limit_inflow_mode` 四键，lock→默认档、charging+limit→限流档、其他→默认档；`set_limit_inflow_config` handler（daemon.mm:3593）校验 enabled+mode 后 `setlocalKVBatch_C` 批量写两键，成功才 `applyThermalModeForCurrentState`；`CLSettingsStore setValuesForKeys:apply:`（utils.mm:3993）同一 `@synchronized` 内写多键 + 一次 apply + 失败 `reloadFromDisk`；`onBatteryEventEnd`（daemon.mm:2607）函数体空，不再写 thermal |
| 3 | 命令驱动不变量 | PASS | `onBatteryEventEnd` 无 `setThermalSimulationMode` 调用（仅注释说明原版语义）；无 desired/sync/self-heal/debounce/sticky 残留（deb 二进制 strings 扫描 `desiredThermal\|syncThermal\|selfHeal\|stickyThermal` 0 命中） |
| 4 | 编译通过 | PASS | rootful / rootless / roothide 三 scheme fresh run（2026-08-28）全部 BUILD SUCCEEDED（0 errors，仅 2 个既有 Run Script build-phase warning，与本次改动无关） |
| 5 | 相关测试通过 | PASS | 全仓 188/188 OK（fresh run）；新增 `test_limit_inflow_atomic_config`(6) + `test_limit_inflow_command_driven`(7) + `test_limit_inflow_ui_atomic`(3) + `test_limit_inflow_store_batch`(5) = 21 项契约测试全过 |
| 6 | 安装包符号核对 | PASS | 解包 `out/ChargeLimiter_1.15.2_roothide_arm64e.deb`（2026-08-24 构建，晚于 `2132c4b` 2026-08-22 14:33），二进制含 `set_limit_inflow_config` / `setLimitInflowEnabled:mode:completion:` / `setValuesForKeys:apply:` / `atomic_verified` 等本 change 新增符号 |
| 7 | 安全扫描 | PASS | diff（8230105..HEAD）新增代码无 `system(`/`popen`/`strcpy`/`sprintf`/`strcpy` 等危险函数命中 |
| 8 | 代码审查策略 | SKIP（配置） | review_mode: standard，本 change 改动为命令驱动退回 + 原子配置，已在 build 阶段完成自审；最终 diff 为 6 源文件 +133/-135、4 测试文件 +230，无新增 capability/public API/schema 变更，符合 bug 修复范围 |

### 真机验收证据（用户，2026-08-28）

用户在 Relaxin 越狱 iPhone（iOS 17）真机完成 acceptance.md A1-A6 全部验收，结果全部通过：

- A1 锁屏 ≥30 分钟后电流保持限流水平，未恢复到未限流电流
- A2 亮屏后限流等级仍为用户设定的 moderate/heavy，未被自动改写
- A3 拔线后限流解除（pref 回 off），再插线限流正常恢复
- A4 未插电静置 10 分钟，pref 保持 off，无残留写限流
- A5 关闭限流开关后，充电电流恢复未限流水平
- A6 切换限流等级后电流即时变化到新等级，无需等待下次充电命令

与原版（v1.7 系）锁屏行为一致；原子配置切换无回归。

### 结论

静态 8 项全 PASS（第 8 项按配置 SKIP），真机 A1-A6 全 PASS。本 change 完成验收，可进入归档。
