# Proposal: 重越狱/重启用户空间后未开 APP 时加速充电低电量模式不生效

## Why

用户开启「加速充电 → 低电量模式」(acc_charge_lpm) 后，出现：

1. **重越狱 / 重启用户空间（userspace reboot）后，未打开 APP 时加速充电低电量模式不生效**。即使此时已插电、电池已处于充电态，LPM 不被开启，其它加速项（airmode / wifi / blue / bright）同理。
2. **只要打开一次 APP（哪怕立即杀掉后台），此后即使不打开 APP，加速充电 LPM 等也会持续生效**（包括充电态进入即开 LPM、拔线还原、稳态恢复被外部清除的项）。

其它功能本次未测试。该问题让用户每次重越狱 / 重启用户空间后必须手动打开一次 APP 才能让加速充电生效，与「daemon 由 launchd 常驻、用户无需干预」的预期不符。

## What Changes

在 daemon `serve()` bootstrap 路径与 `onBatteryEvent` 内各增加一个「充电稳态兜底首次应用加速项」的入口 `applyBootstrapAccChargeIfNeeded(info, policyState)`：

- 仅在 `acc_charge` 开启 + 适配器已连接 + 充电稳态（`is_charging || current_looks_charging || policyState == charging`）+ `g_accChargeAppliedThisSession == NO` 时调用 `performAcccharge(YES)` 一次。
- 命中 `performAcccharge` 内既有幂等守卫（`cache_status != nil` 直接 return）无副作用；`g_accChargeAppliedThisSession` 由 `performAcccharge(YES)` 内部置 YES，稳态重申段随即承接恢复语义。
- 不引入长驻轮询、不新增定时器；不改变稳态重申段语义（仍只做恢复、不调用 `performAcccharge(YES)`），避免重新引入 v1.15.2 修复的「开 app 秒进 LPM」回归。

## 根因分析

commit `049b9bc` 把加速项「首次应用」职责从稳态重申路径剥离后，首次应用的唯一入口收敛为「进入充电态的命令翻转分支」：
`capacity_low` / `plug_mode_start` / `temperature_recovered` / `critical_low_battery` / `full_charge_window` / `hold_recharge` 等 `performAcccharge(YES)` 调用点。

这些分支触发条件都依赖 `is_adaptor_new_connected`（拔→插的边沿）或 `capacity.intValue <= charge_below` 等电量阈值边沿。

daemon 启动时只有一次 bootstrap 主动补策略的机会（`serve()` 末尾的 `refreshBatteryStateAndApplyPolicy()`）。其行为取决于此时 `bat_info` 与 `old_bat_info` 的相对关系：

- **重越狱 / userspace reboot 后已插电**：`bat_info` 在 `serve()` 内首次 `getBatInfo(&bat_info)` 填充，此时 `old_bat_info = bat_info`（同一指针，或上一轮仍为 nil/旧值）。`applyChargePolicy(nil, bat_info)` 计算得到的 `is_adaptor_new_connected = !isAdaptorConnect(oldInfo) && isAdaptorConnect(info)`：
  - 当 `oldInfo == nil`（`safeOld = safeInfo`，见 `applyChargePolicy` 起始处 `safeOld = oldInfo ?: safeInfo`），`isAdaptorConnect(nil, ...)` 走 `ExternalChargeCapable` 路径返回 NO（无该 key），于是 `is_adaptor_new_connected = !NO && YES = YES` —— 看似能进入 `plug_mode_start` 分支。
  - 但 `plug_mode_start` 分支只在 `mode == CL_MODE_PLUG` 且 `is_adaptor_new_connected` 时触发，且依赖 `g_chargeCommandEnabled`、`is_charging`、`current_looks_charging`、`capacity` 等多个 IORegistry 字段在 daemon 启动这一瞬间已就绪。**IORegistry 在 userspace 重启后首次读到的快照常常 `IsCharging=true` 但 `ExternalChargeCapable` / `AdapterDetails` 尚未发布、或 `InstantAmperage=0`**，此时：
    - 若走 `critical_low_battery`（capacity <= 5）：要求 `(!g_chargeCommandEnabled || !is_charging || predictive_inhibit_active)` 才应用 `performAcccharge(YES)`；userspace 重启后 `g_chargeCommandEnabled=YES`、`is_charging=true`、`predictive_inhibit_active=NO`，条件不满足 → 不应用。
    - 若走 `plug_mode_start`：要求 `is_adaptor_new_connected` —— 当 `oldInfo` 与 `info` 都已被 daemon 在不同时机填充过、或外部电池事件已先于 bootstrap 路径触发过一次 `applyChargePolicy`，`oldInfo` 已是「已连接」态，`is_adaptor_new_connected` 退化为 NO → 不应用。
    - 其它充电态分支（`temperature_recovered` / `full_charge_window` / `hold_recharge` / `capacity_low`）依赖温度、满充计划窗口、hold 模式、`charge_below` 阈值等特定配置，不构成开机即插电的通用首次应用路径。

**关键缺陷**：`g_accChargeAppliedThisSession` 是进程内 BOOL，**重越狱 / userspace reboot 后 daemon 进程全新启动，标志复位为 NO**。而「首次应用」唯一入口是命令翻转分支 —— userspace 重启后已插电但无新边沿（无拔→插、无电量跨阈值）时，**没有任何路径会把 `g_accChargeAppliedThisSession` 置 YES**，加速项就不会被首次应用。稳态重申路径因 `g_accChargeAppliedThisSession == NO` 直接跳过，也不会恢复。

**打开 APP 后即持续生效**的原因：APP 启动时 `CLSettingsViewController` 等会通过 `[[CLBatteryManager shared] refreshAll]` / `applyNowWithCompletion` 触发 daemon 的 `apply_now` API，进而调用 `refreshBatteryStateAndApplyPolicy()`。由于此时 daemon 已运行一段时间，IORegistry 已稳定、`g_chargeCommandEnabled` 与 `is_charging` 等字段已就绪；同时 app 启动到 `apply_now` 之间往往已经发生过一次电池事件（`onBatteryEvent` 把 `old_bat_info` 推进为「未连接」或刷新），`is_adaptor_new_connected` 边沿重新成立，`plug_mode_start` 分支首次应用 `performAcccharge(YES)` 置 `g_accChargeAppliedThisSession = YES`。此后即便杀掉 APP，daemon 仍持有 `g_accChargeAppliedThisSession = YES`，稳态重申恢复路径对后续充电会话持续生效。

根因：**加速项「首次应用」缺少一个不依赖边沿、在 daemon 启动后已处于充电稳态时也能补首次应用的兜底路径**。当前 bootstrap 的一次 `refreshBatteryStateAndApplyPolicy()` 只能借边沿触发，userspace 重启后已插电稳态无新边沿即漏应用。

## 修复目标

- 重越狱 / userspace reboot 后已插电、daemon 启动时若已处于充电稳态，应能**首次应用**加速项（开启 LPM / airmode 等），无需用户打开 APP。
- 不能重新引入「稳态重申路径首次应用」导致的「开 app 秒进 LPM」回归：稳态重申仍只做恢复，不调用 `performAcccharge(YES)`。
- 不显著增加后台资源开销：修复应在 daemon bootstrap 路径内一次性补齐，不引入长驻轮询。
- 拔线 / 停充 / daemon 重启后行为不变。

