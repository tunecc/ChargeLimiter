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
