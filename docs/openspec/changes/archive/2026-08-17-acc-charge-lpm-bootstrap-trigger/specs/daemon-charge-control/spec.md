# 加速充电（LPM 等）—— bootstrap 与首电池事件兜底首次应用

## ADDED Requirements

### Requirement: 加速充电项首次应用与稳态重申职责分离

- 首次应用与稳态重申职责分离（v1.15.2 引入）保持不变：
  - **首次应用**只由进入充电态的命令翻转分支触发（`capacity_low` / `plug_mode_start` / `temperature_recovered` / `critical_low_battery` / `full_charge_window` / `hold_recharge` 等），由 `performAcccharge(YES)` 把 `cache_status` 从 nil 变非 nil、并置 `g_accChargeAppliedThisSession = YES`。
  - **稳态重申**只做「恢复」：`applyChargePolicy` 在 `is_adaptor_connected && nextPolicyState == charging && !is_adaptor_new_disconnected && g_accChargeAppliedThisSession` 时，按需重拉被外部清除的加速项（LPM/airmode/wifi/blue/bright），不调用 `performAcccharge(YES)`、不覆盖亮度缓存。
  - 拔线 / 停充触发 `performAcccharge(NO)` 还原加速项并置 `g_accChargeAppliedThisSession = NO`。

#### Scenario: 命令翻转分支首次应用加速项

- WHEN 适配器从拔到插（`is_adaptor_new_connected`）或电量跨 `charge_below` 阈值等进入充电态的命令翻转分支触发
- THEN 命令翻转分支调用 `performAcccharge(YES)` 首次应用加速项，`g_accChargeAppliedThisSession` 置 YES
- AND 稳态重申段以 `g_accChargeAppliedThisSession == YES` 为前置按需恢复被外部清除的加速项，不调用 `performAcccharge(YES)`

#### Scenario: 拔线还原加速项

- WHEN 适配器拔出（`is_adaptor_new_disconnected`）触发
- THEN `performAcccharge(NO)` 还原加速项（LPM/airmode/wifi/blue/bright 复位）并置 `g_accChargeAppliedThisSession = NO`

### Requirement: bootstrap 与首电池事件兜底首次应用

- `applyBootstrapAccChargeIfNeeded(info, policyState)`：仅在 `acc_charge` 开启、`is_adaptor_connected`、充电稳态（`is_charging || current_looks_charging || policyState == charging`）、且 `g_accChargeAppliedThisSession == NO` 时调用 `performAcccharge(YES)` 一次，命中 `performAcccharge` 内幂等守卫（`cache_status != nil` 直接 return）无副作用。
- daemon `serve()` 末尾 `refreshBatteryStateAndApplyPolicy()` 之后调用一次，覆盖 userspace 重启 / 重越狱后已插电稳态、`is_adaptor_new_connected` 边沿退化为 NO 的空窗。
- `onBatteryEvent` 内 `applyChargePolicy` 之后调用一次，覆盖 IORegistry 延迟发布 `ExternalChargeCapable` / `AdapterDetails`、bootstrap 时 `bat_info` 尚未反映充电稳态、首个真正的电池事件到来时才补齐的场景。
- 不引入长驻轮询、不新增定时器；不改变稳态重申段语义，避免重新引入「开 app 秒进 LPM」回归。

#### Scenario: 重越狱后已插电未打开 APP 时首次应用加速项

- WHEN 重越狱或重启用户空间后 daemon 启动，此时已插电且处于充电稳态，且用户未打开 APP
- THEN daemon `serve()` 末尾 `applyBootstrapAccChargeIfNeeded` 在 `is_adaptor_connected && charging_steady && g_accChargeAppliedThisSession == NO` 成立时调用 `performAcccharge(YES)`，开启 LPM 等加速项并置 `g_accChargeAppliedThisSession = YES`
- AND 后续稳态重申段以 `g_accChargeAppliedThisSession == YES` 为前置按需恢复被外部清除的加速项

#### Scenario: IORegistry 延迟发布时首电池事件补齐首次应用

- WHEN daemon `serve()` 时 IORegistry 尚未发布 `ExternalChargeCapable` / `AdapterDetails`，bootstrap 兜底读取的 `bat_info` 未反映充电稳态
- THEN 首个真正的 IOKit 电池事件到达 `onBatteryEvent` 时，若已进入充电稳态且 `g_accChargeAppliedThisSession == NO`，`applyBootstrapAccChargeIfNeeded` 补一次 `performAcccharge(YES)`

#### Scenario: 未插电时打开 APP 不误开 LPM

- WHEN 未插电稳态下打开 APP 触发 `apply_now` / `refreshAll`
- THEN `apply_now` 路径不调用 `applyBootstrapAccChargeIfNeeded`（仅 serve 与 onBatteryEvent 调用）
- AND 稳态重申段 `g_accChargeAppliedThisSession == NO` 跳过
- AND 不开启 LPM（即不回归「开 app 秒进 LPM」）

