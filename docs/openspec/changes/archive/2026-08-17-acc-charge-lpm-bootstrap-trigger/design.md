# Design: 重越狱/重启用户空间后未开 APP 时加速充电低电量模式不生效

## 方案：bootstrap 兜底首次应用加速项（不依赖边沿、不依赖稳态重申）

### 1. 新增 bootstrap 加速项应用路径

在 `serve()` 末尾既有 `refreshBatteryStateAndApplyPolicy()` 调用之后（或之前紧邻），新增一次「bootstrap 兜底首次应用」：

- 仅当 `acc_charge` 已开启、且当前 `bat_info` 反映「适配器已连接 + 充电态」（`is_adaptor_connected` 且 `nextPolicyState == charging` / `is_charging || current_looks_charging`）、且 `g_accChargeAppliedThisSession == NO`（本次会话尚未首次应用）时，调用 `performAcccharge(YES)` 一次。
- 该路径与命令翻转分支共用 `performAcccharge(YES)` 入口，命中幂等守卫（`cache_status != nil` 直接 return）后无副作用；`g_accChargeAppliedThisSession` 由 `performAcccharge(YES)` 内部置 YES。
- 调用后稳态重申路径自然承接（`g_accChargeAppliedThisSession == YES` 后，稳态重申按需恢复被外部清除的项）。

### 2. 不重新引入「稳态重申首次应用」

`applyChargePolicy` 稳态重申段保持 `049b9bc` 的语义不变：
- 仍只做恢复，不调用 `performAcccharge(YES)`；
- 仍以 `g_accChargeAppliedThisSession == YES` 为前置条件，不借稳态路径首次应用。

这避免重新触发「未插电时 app/apply_now 触发策略 → 稳态重申误首次应用 → 秒进 LPM」回归。

### 3. 不引入长驻轮询

修复集中在 daemon bootstrap 路径一次性补齐，**不新增定时器、不新增 dispatch_source、不新增周期任务**。
- 已有的 `onBatteryEvent`（IOKit 电池事件回调）继续负责插拔 / 电量跨阈值等边沿触发的首次应用与恢复；
- 已有的稳态重申段（每个电池事件跑一次）继续负责恢复被外部清除的项；
- 仅在「daemon 启动后已处于充电稳态、但标志仍为 NO」这一空窗补一次 `performAcccharge(YES)`。

### 4. 边界与幂等

- daemon 启动时若 `bat_info` 还没就绪（`getBatInfo` 失败 / `ExternalChargeCapable` 未发布），bootstrap 兜底路径不应用；后续第一个 IOKit 电池事件到来时若已处于充电态、且 `is_adaptor_new_connected` 仍可能因 `oldInfo` 非空而退化为 NO，则首次应用仍可能漏。对此情形，bootstrap 兜底之外再补一个轻量兜底：在 `onBatteryEvent` 内，若充电稳态成立且 `g_accChargeAppliedThisSession == NO`，补一次 `performAcccharge(YES)`（命中幂等守卫无副作用）。这样无论 IORegistry 何时就绪，进入充电稳态的第一个电池事件即补齐首次应用。
- 拔线分支 `performAcccharge(NO)` 把 `g_accChargeAppliedThisSession` 置 NO、清空 `cache_status` —— 与既有语义一致；下一次插电或充电稳态事件会重新首次应用。
- 该路径只解决「首次应用」的 bootstrap 空窗，不改变拔线还原、稳态恢复、配置变更重置等既有行为。

### 5. 为什么不会重新引入「开 app 秒进 LPM」

「开 app 秒进 LPM」回归的根因是稳态重申路径在**未插电稳态**借幂等守卫首次应用。本方案的 bootstrap 兜底与 `onBatteryEvent` 兜底都前置 `is_adaptor_connected`（且 nextPolicyState/is_charging 等充电态判定），未插电稳态下不会进入。app/apply_now 触发的 `refreshBatteryStateAndApplyPolicy()`：
- 未插电时：`is_adaptor_connected == NO`，bootstrap 兜底条件不满足（且 bootstrap 路径只在 `serve()` 内跑一次，不在 `apply_now` 路径）；稳态重申段 `g_accChargeAppliedThisSession == NO` 跳过 —— LPM 不被拉起，与 `049b9bc` 后预期一致。
- 已插电时：app 触发的 `apply_now` 进入 `refreshBatteryStateAndApplyPolicy` → `applyChargePolicy`，正常走命令翻转或 bootstrap/事件兜底首次应用 —— 与既有预期一致。
