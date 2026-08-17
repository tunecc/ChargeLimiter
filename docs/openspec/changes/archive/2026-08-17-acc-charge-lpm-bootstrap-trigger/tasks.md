# Tasks: 重越狱/重启用户空间后未开 APP 时加速充电低电量模式不生效

- [x] 1. daemon: 在 `serve()` 末尾 `refreshBatteryStateAndApplyPolicy()` 之后新增 bootstrap 兜底首次应用：当 `acc_charge` 开启、`is_adaptor_connected && (is_charging || current_looks_charging) && g_accChargeAppliedThisSession == NO` 时调用 `performAcccharge(YES)` 一次。
- [x] 2. daemon: 在 `onBatteryEvent` 内补一个充电稳态兜底：当 `is_adaptor_connected && (is_charging || current_looks_charging) && g_accChargeAppliedThisSession == NO` 时调用 `performAcccharge(YES)`；命中幂等守卫无副作用，覆盖 IORegistry 延迟就绪场景。
- [x] 3. 复现/回归测试：新增静态源码扫描测试 `test_acccharge_lpm_bootstrap_trigger.py`，断言（a）bootstrap 兜底路径存在且前置 `is_adaptor_connected` + 充电态 + `g_accChargeAppliedThisSession == NO`；（b）`onBatteryEvent` 兜底同样前置 `is_adaptor_connected`；（c）稳态重申段仍以 `g_accChargeAppliedThisSession == YES` 为前置条件、不调用 `performAcccharge(YES)`。
- [x] 4. 编译验证：`xcodebuild -scheme ChargeLimiterDaemon -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` 在 arm64 / arm64e 两 slice 通过，无新增 error / warning。
- [x] 5. CHANGELOG 与 spec delta：补本次修复条目；更新 `daemon-charge-control` spec「加速充电」一节，补充「bootstrap 与首电池事件兜底首次应用」。
