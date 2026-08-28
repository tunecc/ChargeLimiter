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
