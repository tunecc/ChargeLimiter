---
comet_change: fix-lockscreen-limit-inflow
role: technical-design
canonical_spec: openspec
status: design
---

# 限流控制：命令驱动 + 原子配置切换

## 背景

v1.7 原版的限流控制简单可靠：`setBatteryStatus(YES/NO)` 在充电命令边沿写一次 thermal pref，此后从不读回、从不重写。锁屏后电池事件继续到达，但没有任何代码路径触碰 thermal pref，限流长期保持。

`d8ad775` 引入 `desiredThermalSimulationModeForCurrentState` → `syncThermalSimulationModeForCurrentState` 反馈闭环后，thermal mode 开始随电池/适配器实时读数推导。锁屏后 `ExternalChargeCapable` 抖动塌为 false、电流低于阈值，desired 算出 off，sync 主动把限流改写为 off。三版补丁（f03befb 读回校验 + 60s 自愈、6a33876 AdapterDetails + 阈值联动 + 粘滞兜底、8cb6e3c 粘滞修正）都在闭环内打转。

`b8c0764` 正确删除整个闭环，退回命令驱动。但留下两个缺口：配置切换不原子（UI 发两次 `set_conf`），以及默认等级修改可能覆盖当前限流档。

## 运行时模型

集中决策函数只在命令边沿和配置变更时调用：

1. `adv_thermal_mode_lock == YES` → 默认档
2. `g_chargeCommandEnabled == YES` 且 `adv_limit_inflow == YES` 且未锁定 → 限流档
3. 其他 → 默认档

输入只有 `g_chargeCommandEnabled` 和四个配置键。不读 `isAdaptorConnect`、`AdapterDetails`、`currentLooksCharging`、`IsCharging`、`ExternalChargeCapable`。

## 原子配置接口

新 daemon API `set_limit_inflow_config`：请求体含 `enabled`（bool）和 `mode`（off/nominal/light/moderate/heavy）。daemon 在串行 HTTP handler 内：

1. 校验 payload
2. 通过 `CLSettingsStore` 批量写入口一次提交 `adv_limit_inflow` + `adv_limit_inflow_mode`
3. 写盘失败 → 恢复快照、返回失败、不写 thermal
4. 成功 → 调一次决策函数更新 thermal mode

旧 `set_conf` 保留兼容。`adv_def_thermal_mode` 分支改为经决策函数决定是否写入。

## 客户端

`CLAPIClient.setLimitInflowEnabled:mode:completion:` 发一次请求。成功或 daemon 不可达时，通过批量 C bridge 一次更新两个本地镜像键。daemon 拒极时不写本地镜像。

## Shared store 批量写

`CLSettingsStore.setValuesForKeys:apply:` 在同一 `@synchronized` 区域内设多个键，再调一次 `apply`。失败时已有 `reloadFromDisk` 逻辑回滚，保证两键不落盘一半。

## 测试策略

源码契约测试覆盖：

- daemon 决策函数只读命令 + 四键，不读电池/适配器信号
- `onBatteryEventEnd` 不调 `setThermalSimulationMode`
- 不存在 desired/sync/sticky/self-heal/debounce 代码
- `set_limit_inflow_config` 校验五种 mode、批量写两键、成功只应用一次
- UI 只调单一批量客户端方法
- shared store 失败整组回滚

行为矩阵：

| 充电命令 | 限流开关 | 锁定 | 目标档位 |
|---|---:|---:|---|
| YES | YES | NO | 限流等级 |
| YES | NO | NO | 默认等级 |
| NO | YES | NO | 默认等级 |
| 任意 | 任意 | YES | 默认等级 |

验证：全量 Python 契约测试 + 三 scheme 编译 + 真机插电切换/停充切换/锁屏保持验收。

## 非目标

不识别或保存锁屏状态；不根据适配器/电流/系统 thermal state 维持限流；不恢复自愈/读回/粘滞/去抖；不改停充控制面、配置键名称和用户可见选项。
