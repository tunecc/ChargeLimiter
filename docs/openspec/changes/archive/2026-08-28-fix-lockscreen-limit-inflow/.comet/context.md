# Comet Design Handoff

- Change: fix-lockscreen-limit-inflow
- Phase: design
- Mode: compact
- Context hash: 74c98ebc8153fb4f784de57c59b6a3bb62ea67f7e31177de4cee5bcbeddeb499

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## docs/openspec/changes/fix-lockscreen-limit-inflow/proposal.md

- Source: docs/openspec/changes/fix-lockscreen-limit-inflow/proposal.md
- Lines: 1-33
- SHA256: 83a5034d1b93662f55ff09a17d132f923d77d89c369d21838184428225f4bd7d

```md
# Proposal: fix-lockscreen-limit-inflow

## Why

用户真机反馈（iOS 17）：锁屏后限流控制失效，电流恢复到未限流水平；换回原版（v1.7 系）锁屏时限流保持正常。

根因不是"锁屏期 cltm 清 pref 无人重写"（上一轮 f03befb 的假设，真机验证无效），而是当前版自己在锁屏期把限流取消了。`d8ad775`（v1.12.4 → v1.12.5 之间）引入 `desiredThermalSimulationModeForCurrentState` → `syncThermalSimulationModeForCurrentState` 反馈闭环，让 thermal mode 随电池/适配器实时读数推导。锁屏后这些读数抖动（`ExternalChargeCapable` 塌为 false、电流低于阈值），desired 算出 off，sync 主动把限流 pref 改写为 off。后续三版补丁（f03befb / 6a33876 / 8cb6e3c）都在闭环内打转，方向反了。

`b8c0764` 已正确删除整个 desired/sync 闭环、60s 自愈、200ms 去抖、读回校验和粘滞兜底，退回原版命令驱动语义。但删除闭环后留下两个缺口：

1. 配置切换不原子：UI 通过两次独立 `set_conf` 分别写 `adv_limit_inflow` 和 `adv_limit_inflow_mode`，两次请求之间 thermal mode 可能处于不一致状态。
2. 默认等级修改可能覆盖当前限流档：`set_conf` 的 `adv_def_thermal_mode` 分支无条件 `setThermalSimulationMode(val)`，即使当前正在限流充电也会把限流改写为默认档。

## What Changes

- 新增 daemon 内部 API `set_limit_inflow_config`，一次请求同时提交 `enabled` 和 `mode`，串行 handler 内原子完成两键写入和一次 thermal mode 更新。
- 集中决策函数只在命令边沿和配置变更时调用，输入只有 `g_chargeCommandEnabled` 和四个配置键，不读电池/适配器/电流/锁屏信号。
- `set_conf` 的 `adv_def_thermal_mode` 分支改为经同一决策函数决定是否写入，不再无条件覆盖限流档。
- `CLAPIClient` 增加 `setLimitInflowEnabled:mode:completion:`，只发一次请求；成功或 daemon 不可达时通过批量 C bridge 一次更新两个本地镜像键。
- `CLSettingsStore` 增加批量写入口：在同一 `@synchronized` 区域内设多个键，一次 `apply`，失败时 `reloadFromDisk` 回滚保证两键不落盘一半。
- UI 的 `limitInflowModeTapped` 改为调用单一原子方法，替代两次 `setConfigWithKey`。

不改变：配置键名称、用户可见选项和语义、停充控制面、`set_conf` 对其他配置的兼容性。

## Capabilities

无 spec 级行为变更。限流在锁屏期保持生效是 `adv_limit_inflow` 的预期行为，本 change 是 bug 修复落地。`.openspec.yaml` 设置 `skip_specs: true`。

## Impact

- 代码：`ChargeLimiter/daemon.mm`（新增 `set_limit_inflow_config` handler、集中决策函数、`adv_def_thermal_mode` 分支修正）；`ChargeLimiter/utils.mm`（`CLSettingsStore` 批量写入口）；`ChargeLimiter/UIKit/CLAPIClient.m`（`setLimitInflowEnabled:mode:completion:` + 批量本地镜像）；`ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m`（UI 调用改为原子方法）。预计 4 个文件。
- 测试：新增源码契约测试覆盖原子 API、批量写、命令驱动决策和 UI 调用路径；保留 `test_thermal_mode_live_refresh`。
- 风险：低。`b8c0764` 已删除闭环，本 change 只补配置切换原子性和决策集中化，不改写路径语义。

```

## docs/openspec/changes/fix-lockscreen-limit-inflow/design.md

- Source: docs/openspec/changes/fix-lockscreen-limit-inflow/design.md
- Lines: 1-69
- SHA256: f3ba62e928d19018525fa0c67e704fa6aa02d728bcebfaede334c76397f700a5

```md
# Design: fix-lockscreen-limit-inflow

## 结论

采用"原版命令驱动语义 + 原子配置切换"的方案。运行时 thermal mode 只由 ChargeLimiter 自己最近一次充电命令和配置决定，不读取锁屏、适配器、电流、`IsCharging`、`ExternalChargeCapable` 或 `AdapterDetails`。

## 根因与历史边界

v1.7 到 v1.12.4 的实现只在 `setBatteryStatus(YES/NO)` 命令边沿写入 thermal mode：继续充电使用 `adv_limit_inflow_mode`，停充使用 `adv_def_thermal_mode`。电池事件不会持续重写 thermal pref，因此锁屏天然不会改变限流状态。

`d8ad775` 在 v1.12.4 与 v1.12.5 之间引入 `desiredThermalSimulationModeForCurrentState`，随后 v1.14.x、v1.15.x 逐步加入适配器、电流、读回、自愈、粘滞和去抖。这个闭环把不稳定的系统读数变成了主动降档信号，最终造成锁屏限流自取消。`b8c0764` 删除闭环并恢复命令驱动方向是正确的，但同时留下了配置切换不立即收敛、以及默认等级修改可能覆盖当前限流档的问题。

## 运行时模型

新增一个集中决策函数（名称按实现阶段确定），其输入只有：

- `g_chargeCommandEnabled`：daemon 最近一次成功发出的充电命令；
- `adv_limit_inflow`：是否启用充电时限流；
- `adv_limit_inflow_mode`：限流等级；
- `adv_def_thermal_mode`：非限流时的默认等级；
- `adv_thermal_mode_lock`：锁定默认等级。

决策规则：

1. `adv_thermal_mode_lock == YES` 时，目标是默认等级。
2. `g_chargeCommandEnabled == YES` 且 `adv_limit_inflow == YES` 且未锁定时，目标是限流等级。
3. 其他情况目标是默认等级。

该函数只在明确的命令或配置变更路径调用：`setBatteryStatus` 成功后、原子限流配置成功后、以及默认等级或锁定等级的兼容 `set_conf` 路径。`onBatteryEventEnd` 不再写 thermal mode——当前 onBatteryEventEnd 中对 `adv_thermal_mode_lock` 的 `setThermalSimulationMode` 调用移至 `set_conf` 的 `adv_thermal_mode_lock` 分支，由决策函数统一处理。

## 原子限流配置接口

新增 daemon 内部 API `set_limit_inflow_config`，请求体包含 `enabled` 与 `mode`。允许的 mode 为 `off`、`nominal`、`light`、`moderate`、`heavy`。`enabled == false` 时仍保存用户选择的 mode；UI 的"关闭"选项发送 `enabled=false, mode=off`。

daemon 在现有串行 HTTP handler 内完成：校验 payload；通过共享设置 store 的批量写入口一次提交 `adv_limit_inflow` 与 `adv_limit_inflow_mode`；写盘失败时恢复原快照并返回失败；成功后按当前命令和完整配置只调用一次 `setThermalSimulationMode`。

旧 `set_conf` 保留供其他配置和旧客户端兼容。旧客户端分别更新两个限流键时仍可工作，但新 UI 不再依赖它处理限流等级。

## 客户端与本地镜像

`CLAPIClient` 增加 `setLimitInflowEnabled:mode:completion:`，真实设备只发送一次上述 API。成功响应或 daemon 不可达时，客户端通过 shared store 的批量 C bridge 一次更新两个本地镜像键；daemon 明确拒绝时不写本地镜像。模拟器 mock 同步更新两个键并返回成功。

共享 store 扩展批量设置能力：在同一个同步区域内把两项变更放入内存快照，再执行一次现有原子 plist 写入；失败时沿用现有 `reloadFromDisk` 回滚逻辑，保证两键不会只落盘一半。该能力是通用内部 helper，但本 change 只用于限流两键。

## 错误处理与并发

- 请求缺字段、mode 非法或类型不符合时返回结构化错误，不静默降级。
- 写盘失败沿用现有配置写失败诊断/通知机制，并返回失败状态；thermal pref 保持旧值。
- HTTP handler 已是串行队列；批量请求不需要 timer、generation、dispatch debounce 或额外锁。
- thermal 写入不读回、不自愈，不把写入结果重新推导成下一次 desired。

## 测试策略

源码契约测试覆盖：daemon 命令驱动决策不读取电池/适配器/锁屏信号；`onBatteryEventEnd` 不调 `setThermalSimulationMode`；不存在 desired/sync/self-heal/sticky 闭环；批量 API 校验五种 mode、同时写两个键且成功只应用一次；UI 只调用单一批量客户端方法；shared store 失败整组回滚。

行为矩阵：

| 充电命令 | 限流开关 | 锁定 | 目标档位 |
|---|---:|---:|---|
| YES | YES | NO | 限流等级 |
| YES | NO | NO | 默认等级 |
| NO | YES | NO | 默认等级 |
| 任意 | 任意 | YES | 默认等级 |

验证包括模拟器 mock、全量 Python 契约测试、rootful/rootless/roothide 三 scheme 编译，以及真机插电切换、停充切换和锁屏保持验收。

## 非目标

不识别或保存锁屏状态；不根据适配器、电流、`IsCharging`、`ExternalChargeCapable`、`AdapterDetails` 或系统 thermal state 维持限流；不恢复 60 秒自愈、读回校验、粘滞窗口、降档事件或 200ms 去抖；不改变停充/禁流控制面、配置键名称和用户可见选项。

```

## docs/openspec/changes/fix-lockscreen-limit-inflow/tasks.md

- Source: docs/openspec/changes/fix-lockscreen-limit-inflow/tasks.md
- Lines: 1-50
- SHA256: 9f8d8cf3bd569797fe9cc0aa375ee54e12917a177d244d4c94a674f6b7d99211

```md
# Tasks: fix-lockscreen-limit-inflow

## 1. RED：先写失败测试

- [ ] 1.1 新增 `scripts/tests/test_limit_inflow_atomic_config.py`：断言 daemon 含 `set_limit_inflow_config` handler、请求体校验 `enabled` 与 `mode` 五种合法值（off/nominal/light/moderate/heavy）、批量写两键成功后只调一次 `setThermalSimulationMode`、失败时整组回滚不写 thermal。
- [ ] 1.2 新增 `scripts/tests/test_limit_inflow_command_driven.py`：断言集中决策函数只读 `g_chargeCommandEnabled` 和四个配置键（`adv_limit_inflow`/`adv_limit_inflow_mode`/`adv_def_thermal_mode`/`adv_thermal_mode_lock`），不读 `isAdaptorConnect`/`AdapterDetails`/`currentLooksCharging`/`IsCharging`/`ExternalChargeCapable`；`onBatteryEventEnd` 不调 `setThermalSimulationMode`。
- [ ] 1.3 新增 `scripts/tests/test_limit_inflow_ui_atomic.py`：断言 `limitInflowModeTapped` 只调一次 `setLimitInflowEnabled:mode:completion:`，不再调两次 `setConfigWithKey`。
- [ ] 1.4 新增 `scripts/tests/test_limit_inflow_store_batch.py`：断言 `CLSettingsStore` 含批量写入口（同一 `@synchronized` + 一次 `apply`），失败路径调 `reloadFromDisk`。
- [ ] 1.5 确认 `test_thermal_mode_live_refresh.py` 仍通过（不受影响）。

## 2. 实现 daemon 命令驱动 + 原子配置

- [ ] 2.1 新增集中决策函数（daemon.mm）：输入 `g_chargeCommandEnabled` + 四个配置键，返回目标 thermal mode；不读电池/适配器/电流/锁屏。规则：lock=YES → 默认档；charging+limit=YES → 限流档；其他 → 默认档。
- [ ] 2.2 `setBatteryStatus` 改为调用决策函数（替代当前内联逻辑）。
- [ ] 2.3 新增 `set_limit_inflow_config` HTTP handler：校验 payload（`enabled` bool + `mode` ∈ {off,nominal,light,moderate,heavy}）；通过 `CLSettingsStore` 批量写入口一次提交 `adv_limit_inflow` + `adv_limit_inflow_mode`；写盘失败返回失败不写 thermal；成功后调一次决策函数更新 thermal mode。
- [ ] 2.4 `set_conf` 的 `adv_def_thermal_mode` 分支：改为调决策函数决定是否写入 thermal mode，不再无条件 `setThermalSimulationMode(val)`。
- [ ] 2.5 `set_conf` 的 `adv_thermal_mode_lock` 分支：改为调决策函数更新 thermal mode（当前 onBatteryEventEnd 中的 lock 写入逻辑移至此处）。
- [ ] 2.6 `set_conf` 的 `adv_limit_inflow` 和 `adv_limit_inflow_mode` 分支保留兼容（旧客户端仍可工作），但写后也经决策函数更新 thermal。
- [ ] 2.7 `onBatteryEventEnd` 清空 thermal 写入逻辑（不再调 `setThermalSimulationMode`），仅保留日志或移除。
- [ ] 2.8 搜索确认无残留 desired/sync/sticky/self-heal/debounce 代码。

## 3. 实现 shared store 批量写

- [ ] 3.1 `CLSettingsStore` 新增 `setValuesForKeys:apply:` 批量写入口：在同一 `@synchronized` 区域内逐个 `setValue:forKey:`，再调一次 `apply`；失败时 `reloadFromDisk` 回滚（已有逻辑）。
- [ ] 3.2 新增 C bridge `setlocalKVBatch_C`（或等价），供客户端一次更新多个本地镜像键。

## 4. 实现 client + UI

- [ ] 4.1 `CLAPIClient` 新增 `setLimitInflowEnabled:mode:completion:`：真机发一次 `set_limit_inflow_config` 请求；成功或 daemon 不可达时调批量 C bridge 一次更新两个本地镜像键；daemon 拒绝时不写本地镜像。
- [ ] 4.2 mock 路径同步更新两个键并返回成功。
- [ ] 4.3 `CLAdvancedSettingsViewController.m` 的 `limitInflowModeTapped` 改为调 `setLimitInflowEnabled:mode:completion:`，删除两次 `setConfigWithKey` 调用。

## 5. 验证

- [ ] 5.1 运行全部限流相关源码扫描测试转绿。
- [ ] 5.2 全仓 Python 契约测试通过（含保留的 `test_thermal_mode_live_refresh`）。
- [ ] 5.3 三 scheme（rootful / rootless / roothide）编译通过。
- [ ] 5.4 真机验收清单（acceptance.md）已写入；真机验收执行与结果由用户后续反馈。

## 6. 真机验收

- [ ] 6.1 安装含本修复的 roothide 包（`./scripts/build_packages.sh`）
- [ ] 6.2 限流等级设为 moderate 或 heavy，插电充电中
- [ ] 6.3 锁屏 ≥30 分钟（最好跨一晚）
- [ ] 6.4 逐条核对 acceptance.md A1-A6
- [ ] 6.5 验收通过后归档

## 已完成（历史阶段，仅记录）

- [x] b8c0764 删除 desired/sync 闭环、60s 自愈、200ms 去抖、读回校验、粘滞兜底；退回原版命令驱动语义；168 项测试通过；三 scheme 编译通过。

```
