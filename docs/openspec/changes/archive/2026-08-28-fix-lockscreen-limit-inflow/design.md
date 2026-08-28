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
