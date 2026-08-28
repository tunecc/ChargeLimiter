# Brainstorm Summary: fix-lockscreen-limit-inflow

## 确认事实

1. 原版（v1.7 系）thermal mode 只在 `setBatteryStatus` 命令边沿写一次，从不读回。锁屏后限流天然保持。
2. `d8ad775` 引入 `desiredThermalSimulationModeForCurrentState` → `syncThermalSimulationModeForCurrentState` 反馈闭环，thermal mode 开始随电池/适配器实时读数推导。
3. 锁屏后 `ExternalChargeCapable` 抖动塌为 false、限流态电流低于 120mA 阈值，desired 算出 off，sync 主动把限流 pref 改写为 off。这是锁屏限流失效的真实根因。
4. 三版补丁（f03befb / 6a33876 / 8cb6e3c）都在闭环内打转，方向反了——自愈定时器跑同一个错误的 desired 计算。
5. `b8c0764` 正确删除整个闭环、60s 自愈、200ms 去抖、读回校验和粘滞兜底，退回原版命令驱动语义。168 项测试通过，三 scheme 编译通过。
6. 删除闭环后留下两个缺口：配置切换不原子（UI 两次 `set_conf`），默认等级修改可能覆盖当前限流档。

## 否定方案

### 短去抖（200ms timer）

用户在 UI 连续发送两个 `set_conf` 请求时（先 `adv_limit_inflow` 后 `adv_limit_inflow_mode`，或反过来），两次请求之间 daemon 可能已用半更新的配置调 `setThermalSimulationMode`，导致 thermal mode 短暂处于错误档。

短去抖方案：收到第一个 `set_conf` 后等 200ms，期间收到的后续 `set_conf` 合并，超时后统一处理。

历史教训：去抖在 `31b03f` 引入后有三次 bug 修复记录，且不是真正原子——timer 到期前 daemon 仍可能被其他路径打断。用户确认不采用。

### desired/sync 闭环修复

尝试在闭环内修信号判据（AdapterDetails 替代 ExternalChargeCapable、阈值联动、粘滞兜底）。三版补丁均无效，因为闭环本身就是问题——只要 thermal mode 随实时读数推导，锁屏期读数塌陷就会传导到 thermal mode。

## 确认方案：命令驱动 + 原子配置

### 核心思路

thermal mode 只由 ChargeLimiter 自己的命令和配置决定，不读任何系统实时信号。

### 关键设计

1. 集中决策函数：输入 `g_chargeCommandEnabled` + 四个配置键，输出目标 thermal mode。
2. 原子配置 API `set_limit_inflow_config`：一次请求同时提交 `enabled` + `mode`，串行 handler 内原子完成。
3. Shared store 批量写：同一 `@synchronized` + 一次 `apply` + 失败回滚。
4. 客户端 `setLimitInflowEnabled:mode:completion:`：一次请求 + 一次批量本地镜像更新。
5. UI 调用单一原子方法。

### 优势

- 比 b8c0764 退回版更好：配置切换原子，不会出现中间不一致状态。
- 比原版更好：默认等级修改不再无条件覆盖限流档；决策集中化便于维护。
- 不引入实时信号依赖，锁屏天然免疫。
