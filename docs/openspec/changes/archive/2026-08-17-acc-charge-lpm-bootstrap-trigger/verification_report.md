# 验证报告：重越狱/重启用户空间后未开 APP 时加速充电 LPM 不生效

## 验证范围

本次修复改动集中在 `ChargeLimiter/daemon.mm`：

- 新增辅助函数 `applyBootstrapAccChargeIfNeeded(NSDictionary* info, NSString* policyState)`：仅在「`acc_charge` 开启 + 适配器已连接 + 充电稳态（`is_charging || current_looks_charging || policyState == charging`）+ `g_accChargeAppliedThisSession == NO`」时调用 `performAcccharge(YES)` 一次。
- `serve()` 末尾 `refreshBatteryStateAndApplyPolicy()` 之后调用一次（bootstrap 兜底）。
- `onBatteryEvent` 内 `applyChargePolicy` 之后调用一次（IORegistry 延迟就绪兜底）。

新增静态回归测试 `scripts/tests/test_acccharge_lpm_bootstrap_trigger.py`（3 用例）。CHANGELOG 与 delta spec（`daemon-charge-control`）已补。

验证受限于：项目无单元测试体系，修复路径依赖真机 IOKit / 私有框架（`_PMLowPowerMode`、`RadiosPreferences`、`BluetoothManager` 等），且 daemon codesign 阶段在主机（非越狱 macOS）跑 `ldid` 会失败（pre-existing on main，与本次改动无关，见既有归档 `2026-08-17-acc-charge-lpm-plugfix/verification_report.md`）。因此采用**静态路径分析 + 编译验证 + 静态回归测试**作为可执行的验证手段，真机行为留待用户验收。

## 执行的检查

### 1. tasks.md 全部任务已完成

`tasks.md` 5 项任务全部勾选 `[x]`（1-5 项均完成）。

### 2. 改动文件与 tasks.md 描述一致

```text
ChargeLimiter/daemon.mm                            | +57 行（applyBootstrapAccChargeIfNeeded 实现 + serve()/onBatteryEvent 两处调用 + 前置声明）
docs/openspec/changes/acc-charge-lpm-bootstrap-trigger/.comet.yaml   | +30 行（Comet 状态）
docs/openspec/changes/acc-charge-lpm-bootstrap-trigger/design.md     | +38 行
docs/openspec/changes/acc-charge-lpm-bootstrap-trigger/proposal.md   | +39 行
docs/openspec/changes/acc-charge-lpm-bootstrap-trigger/tasks.md      | +7 行
scripts/tests/test_acccharge_lpm_bootstrap_trigger.py                | +89 行
```

提交后工作区脏改动：`CHANGELOG.md`（补 Unreleased 修复条目）、`tasks.md`（勾选 5）、delta spec `specs/daemon-charge-control/spec.md`（新增，被 `.gitignore` 排除与既有归档一致）、`.comet.yaml`（状态推进）。所有改动均对应 tasks.md 第 5 项，归因属当前 change。

### 3. 编译通过

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme ChargeLimiterDaemon \
  -configuration Debug -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64 clean build
```

- arm64：`CompileC ... daemon.o`（`daemon.mm`）通过，`Ld .../ChargeLimiterDaemon.app/ChargeLimiterDaemon normal` 通过；既有 ldid codesign Run Script 阶段在非越狱主机失败（`ldid.cpp(1300): _assert(): errno=2`），与本次改动无关（既有归档同样记录）。
- arm64e：同样 `CompileC ... daemon.o` + `Ld` 通过，无新增 error / warning。
- daemon.mm 编译期 warning 仅 IOKit 头文档 warning（`-Wdocumentation`）与既存 `utils.mm` 既有 warning，本次新增代码零警告。

### 4. 相关测试通过

```bash
python3 -m unittest scripts.tests.test_acccharge_lpm_bootstrap_trigger -v
# 3 用例全部 PASS

python3 -m unittest discover -s scripts/tests
# Ran 175 tests in 0.941s — OK
```

新测试覆盖：
- `test_serve_has_bootstrap_acccharge_trigger`：serve() 调用 `applyBootstrapAccChargeIfNeeded`，辅助函数内含 `performAcccharge(YES)`、前置 `is_adaptor_connected` + `g_accChargeAppliedThisSession` + `acc_charge`。
- `test_onBatteryEvent_has_acccharge_trigger`：`onBatteryEvent` 调用 `applyBootstrapAccChargeIfNeeded`。
- `test_steady_reassert_still_gated_by_session_flag`：稳态重申段（`} while(false);` 到 `if (is_adaptor_new_disconnected)` 之间）仍以 `g_accChargeAppliedThisSession` 为前置、不调用 `performAcccharge(YES)`（去注释后断言）、仍按需 `setLPMEnable(YES)`。

回归保护：既有 `test_acccharge_lpm_boot_recovery`（2 用例，覆盖 `performAcccharge(YES)` 幂等守卫与稳态重申段语义）、`test_thermal_self_heal` / `test_charge_enable_verify` / `test_thermal_sync_debounce` / `test_temp_pause_hysteresis` 等相关 daemon 回归测试全部通过。

### 5. 无明显安全问题

- 无硬编码密钥、无新增 unsafe 操作。
- `applyBootstrapAccChargeIfNeeded` 前置 `acc_charge` / `is_adaptor_connected` / 充电稳态 / `g_accChargeAppliedThisSession == NO` 四重守卫，未插电稳态不进入，避免「开 app 秒进 LPM」回归。
- 调用 `performAcccharge(YES)` 命中幂等守卫（`cache_status != nil` 直接 return）无副作用，不会覆盖亮度缓存或重复写系统开关。
- 无新增定时器 / dispatch_source / 长驻轮询，后台资源开销零增量（用户关心的「会不会增加后台资源开销」答：**不增加**，仅在 daemon 启动一次与每个电池事件各加一次 O(1) 守卫判断，命中后无副作用）。

### 6. 代码审查策略

`review_mode: off`（hotfix 默认）。跳过自动 code review，已在本报告内手动复核正确性、安全、边界条件（见上文）。跳过原因：项目 hotfix 默认配置；改动范围小（1 个源文件 + 1 个测试文件），且已通过静态回归测试断言关键不变量。

## 根因消除检查

- 旧的「userspace 重启后已插电稳态无路径首次应用加速项」空窗已消除：`serve()` 末尾 bootstrap 兜底 + `onBatteryEvent` 首事件兜底两条路径覆盖「daemon 启动时已充电稳态」与「IORegistry 延迟发布导致首事件才反映充电稳态」两种情形。
- `g_accChargeAppliedThisSession` 在两种兜底路径下都会被 `performAcccharge(YES)` 内部置 YES，稳态重申段随即承接恢复语义。
- 未重新引入「开 app 秒进 LPM」：稳态重申段语义不变（仍以 `g_accChargeAppliedThisSession == YES` 为前置只做恢复，不调用 `performAcccharge(YES)`）；兜底路径前置 `is_adaptor_connected`，未插电稳态不进入；`apply_now` 路径不调用 `applyBootstrapAccChargeIfNeeded`（仅 serve 与 onBatteryEvent 调用）。

## 待真机验收

- 重越狱 / 重启用户空间后已插电、未打开 APP：daemon 启动后 LPM（及开启的其它加速项）自动应用。
- 拔线后 LPM 正常还原；再次插电进入充电态重新首次应用。
- 未插电时打开 APP 不再秒进 LPM（v1.15.2 修复不回归）。
- 长会话后台资源开销无明显增加（无新增定时器）。
