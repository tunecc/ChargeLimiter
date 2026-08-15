# CHANGELOG

本文件是 ChargeLimiter 的唯一发布公告来源。

写法参考了 Keep a Changelog 和一些成熟项目常见的结构：每个版本先说明主线，再按少量分类列出用户真正会感知到的变化，尽量详细，但不写成长文。

## v1.15.2 - 2026-08-15

本版主线：**修复 issue#1 反馈的三项充电控制回归**。对照原项目定位回归点：iOS 17 停充后恢复充电路径缺少写后验证，硬件 `ChargingOverride` 位图粘滞 inhibit 导致偶发「已连接电源 · 未充电」；限流（高温模拟）的激活判定依赖初始恒为 YES 且拔线不重置的充电命令标志，未插电时也向 cltm 持续写模拟模式，长期漂移后限流失效、限制电流不对；UI 切换限流等级连发两条配置，daemon 逐条立即同步存在竞态，等级切换不实时。

### 修复

- iOS 17 停充后插线偶发不充电：恢复充电增加 8 秒写后验证（电流 + ChargingOverride 位图），未生效自动重写一次，仍无效回退 legacy 写路径并记录诊断事件。
- 限流在未插电时持续生效、长时间后失效：限流会话判定增加适配器连接前置条件，拔线时重置充电命令标志；未插电时恢复为默认模式（off）。
- 限流等级切换不实时：限流相关四项配置改为 200ms 去抖合并同步，双配置连发最终只写一次最终等级，消除中间态残留。

## v1.15.1 - 2026-08-13

本版主线：**修复限流回归 + 代码仓库大扫除**。v1.15.0 重构限流切换逻辑时引入了 `isAdaptorConnect` 检查，导致 iOS 17.0 下部分充电器限流不生效（用户反馈「最新版停充有效、限流不生效，换回 1.7 正常」）；同时对全仓做了多轮死代码清理与重复代码提纯，净删约 1100 行。

### Fixed

- **修复限流 (`adv_limit_inflow`) 在 iOS 17.0 下不生效**：v1.15.0 commit `0de0350` 重构限流切换逻辑时，在 `desiredThermalSimulationModeForCurrentState` 中新增了 `isAdaptorConnect` 检查，该函数依赖 `ExternalChargeCapable` 判断电源连接。iOS 17.0 下某些充电器 `ExternalChargeCapable` 为 false 但实际在充电，导致限流模式被意外重置为 `off`。现去掉 `isAdaptorConnect` 检查，充电状态改用 `g_chargeCommandEnabled + IsCharging + 实际电流 > 120mA` 三重校验，比纯布尔值信号更可靠。

### Changed

- **删除死代码与遗留 roothide 转换路径**：移除 CLTheme 主题系统、`performAction` 空壳、`CL_MODE_EDGE` 模式、`Makefile`/`MakefileRootless`（已仅走 xcodebuild）、build_packages.sh 的 legacy roothide 转换路径等，净删约 1068 行，4 个契约测试同步更新。
- **移除休眠的 adaptive hold 层**：`adv_hold_behavior` 的 adaptive 模式及相关采样状态机从未上线，`currentHoldRuntimeBehavior` 固定返回 `balanced`，`g_holdDischargeStreak` 等变量已死，净删约 250 行。
- **移除 UI 循环档位归一化**：`CLSettingsViewController` 中停充预设值被重复归一化（identity 映射），去掉冗余逻辑。
- **合并路径格式化器**：`CLSettingsViewController` 中多个 `.json` 路径格式化函数合为一个。
- **共享契约测试助手**：19 个测试文件提取通用 `_helpers.py`，减少重复。

### Notes

- 本版无新增功能，主要修复限流回归 + 清理仓库。v1.15.0 的 relaxin 适配、日志级别等功能不受影响。
- 净减约 1100 行代码，编译产物大小略微减小。

## v1.15.0 - 2026-08-11

本版两个主线：① **正式适配 relaxin 越狱（原生 roothide）**——此前部分 relaxin 设备「装好即 daemon 离线」（启动 126）、设置保存后重启丢失；本版修复 daemon 启动链路、配置持久化与 jbroot 路径兜底，并加固安装/卸载生命周期，relaxin 用户安装后即可开箱即用。② **可配置日志级别与设置入口重组**——新增「日志级别」（标准 / 仅错误），只过滤 `aldente.log` 文件输出，保留系统日志与完整诊断报告；「调试与观测」从充电高级设置移入软件设置，拆成「策略诊断 / 日志级别」两个入口。

### Added

- **新增「日志级别」设置**（软件设置 → 日志级别）：标准（默认）/ 仅错误两档，只过滤 `aldente.log` 文件输出，`NSLog2`/`os_log` 系统日志与完整诊断报告不受影响。
- **「策略诊断 / 日志级别」入口移入软件设置**：「调试与观测」卡片从充电高级设置移除，改为软件设置下的「策略诊断」「日志级别」两个入口。

### Fixed

- **修复首页「停充预设 / 设为当前」改语言后消失**：改语言重建界面后按钮未在新行上重建，现重建时先清空旧按钮引用。
- **修复 relaxin roothide 下 daemon 装好即离线（启动 126）**：launchd system 域在 rootfs 命名空间看不到 `/Applications` 逻辑路径，bootstrap 返回成功但 daemon 永不 exec；现 postinst 用 `jbroot` 命令把 plist `Program`/`ProgramArguments` 换成 `.jbroot-XXX` 真实路径并清理 system / user / foreground 域残留，App spawn 不再带 root persona（daemon 自身 setuid +s 提权）。
- **修复 roothide 下 `jbroot()` 路径解析失败时日志静默空转**：不再静默早退，退用自身可执行路径推导 `.jbroot-XXX` fallback，`aldente.log` 与离线诊断在异常环境下也能正常落盘。
- **修复 roothide 配置保存后丢失**：恢复配置路径初始化，并新增配置持久化链路诊断上报，relaxin 下设置不再静默丢失。
- **修复 `config_reload` 失败在「仅错误」模式下被静默丢弃**：失败改以 error 级别落盘，成功保持 info。
- **加固 Relaxin 安装与生命周期**：安装时严格解析并校验 daemon 真实路径，plist 或 launchctl 失败即中止；daemon 启动后自愈 LaunchDaemon 持久化路径；URL Scheme 避开 root persona；卸载时在 daemon 清理失败后安全删除已验证的 jbroot 数据目录。

### Notes

- **本版正式适配 relaxin（原生 roothide）**：relaxin 设备安装后 daemon 即可正常启动、设置修改重启不丢失；建议回归 安装 → 重启 → 卸载。
- 「仅错误」模式下 `aldente.log` 只写 error 级；系统日志与诊断报告不受影响。

## v1.14.2 - 2026-08-09

本版两个主线：① 修复 daemon 在运行约半小时后崩溃（EXC_BAD_ACCESS / Segmentation fault），根因是全局 sqlite 句柄被多个线程无锁共用：http 并发队列读统计 + battery 事件写 + `reload_conf`/`app_docs` 切换关重开同一连接互相踩踏，一个线程释放连接后，另一线程在 SQL 解析/执行时读到被字符串覆写的悬垂指针，现所有 sqlite 访问统一走同一把可重入锁，HTTP 请求处理改为串行队列，并新增可复现崩溃的最小回归测试与 CI 门禁防止回潮；② 修复「永久停用系统优化充电」后无法恢复（见下方 Fixed），补齐重新打开系统的路径与 daemon 启动自愈。

### Fixed

- **修复 daemon 崩溃（EXC_BAD_ACCESS / SIGSEGV）**：真机反馈 daemon 运行约 27 分钟后，统计读取路径 `get_statistics -> getDBData` 在 sqlite3 内部 Segfault（故障地址指向 ASCII 字符串被当地址）。已将全部 sqlite 访问（open/prepare/step/finalize/exec/close）套上同一把可重入互斥锁，并让 HTTP 请求处理串行执行，`get_statistics` 与 `reload_conf` 关重开不再并发交叠。
- **降低并发稳定性风险**：battery 事件写入与 HTTP 读取、以及 reload 关开连接，从源头不再同时碰同一个 sqlite 连接。
- **修复「永久停用系统优化充电」后无法恢复**：开启「永久停用系统优化充电」会把系统的「优化电池充电」开关（`disableSmartCharging:`）写为关闭，但旧版 daemon 里没有任何路径会再把它打开，导致清配置、卸载都不一定能复原（清除/重置配置把本地 `disable_smart_charge` 清成 `NO` 后，卸载的复位逻辑会直接跳过）。现补齐三条重新打开系统的路径 + daemon 启动自愈：① 清配置/重置时把 `disable_smart_charge` 一并还原为 `NO`；② 关闭「永久停用」开关（`set_conf`）时立即 `setSmartChargeEnable(YES)`；③ 清除配置（`reset_conf`）后若系统仍关闭则显式恢复；④ daemon 启动时若配置已放行但系统优化充电仍处于关闭态则自动恢复——让已受影响的设备装新版后无需任何手动操作即可复原。

### Added

- **sqlite 并发竞态回归测试**：`tests/sqlite_race_repro.c` 用纯 C 镜像 daemon 的 sqlite 访问与线程模型，无锁变体在 ASan / TSan / 裸跑均能复现同类 Segfault，加锁变体在 sanitizer 下干净；`tests/run_repro.sh` 一键构建运行。
- **CI 回归门禁**：新增 `sqlite-race-repro` workflow，在 daemon / HTTP 服务器 / 测试相关文件变更时自动校验「加锁修复在 sanitizer 下保持干净」，防止竞态回潮。
- **relaxin roothide daemon 离线自愈与可观测化**：针对部分 relaxin 越狱 roothide 设备上「装好即 daemon 离线」的问题，新增「修复 daemon 启动」入口（后台 kill 残留 → 重新拉起 daemon → 尽力而为的 launchctl 复位 → 回读日志），一键将 daemon 拉回在线；完整诊断报告新增「daemon 启动链路（离线诊断）」段与越狱类型双源判读，离线即可定位失败环节（spawn rc / 端口 / launchctl / 日志尾）。

### Notes

- 本版无用户侧功能/配置变化；重点回归方向是在装有新构建后打开统计页拉取 `get_statistics`，同时触发一次 `reload_conf`（旧版迁移提示）或 App 更新后首次请求，观察 30 分钟以上确认无崩溃。

## v1.14.1 - 2026-08-07

本版主线是 **策略诊断可复制给开发者** 与 **原生 roothide 构建链路**：在「充电高级 → 策略诊断」提供一键完整诊断（环境 / 连通性 / 读电量 IOKit 链路 / 策略信号），并默认用原生 roothide scheme 出包；同时补强诊断字段，避免 roothide 误报与路径空白。

### Added

- **一键复制完整诊断**（充电高级 → 策略诊断）：复制 Markdown 分段报告，含环境、daemon 连通性、读电量 service/关键 key、策略信号；daemon 离线时仍可复制并带 `⚠️ daemon 离线` 横幅，便于区分「daemon 没起来」与「IOKit 读不到电量」。
- **环境与连通性卡片**：诊断页实时展示包架构、越狱类型、daemon 在线/HTTP、命中 service、`CurrentCapacity` 是否齐全等，进页自动拉取。
- **daemon 只读 `get_diag` API**：上报命中 service、发布 key 清单、五关键 key 存在性、IOKit 返回值、`use_smart`、越狱类型、路径与即时电量/电流等，无写盘/不停充副作用。
- **原生 roothide 打包路径**：默认 `ChargeLimiter roothide` scheme + `Package_roothide` 出 `iphoneos-arm64e` deb（可用 `--legacy-roothide-convert` / `--skip-roothide` 切换）。

### Fixed

- **修复构建链接失败 `Undefined symbols: CLDiagnosticCollector`**：将诊断采集源码接入三个 App target（rootful/rootless/roothide），Daemon 不链接；并为 roothide/rootless App 增加 `CL_PACKAGE_ROOTHIDE` / `CL_PACKAGE_ROOTLESS` 宏。
- **修复完整诊断中可执行路径/数据根路径常为「无法获取」**：App 在 `dlsym` 失败时用 dyld/`NSBundle`/Documents 兜底；daemon `get_diag` 回传 `exe_path` / `data_root` 作为权威补充。
- **修复 roothide 下 `libjailbreak.dylib ❌dlopen失败` 误导**：真实 `/usr/lib` 无该库时改为「N/A（roothide 预期）」，避免当成越狱损坏。
- **修复诊断页导出入口易混淆**：复制探针/策略/事件时间线按钮改名并加说明；移除与诊断无关的「复制长测校准模板」入口。

### Changed

- 完整诊断读电量段增加 **当前电量/电流** 一行；复制文本末尾增加 **使用说明**（查电量直接复制；查停充请先插电并运行探针后再复制）。
- 策略诊断页 tip 文案同步说明查电量 vs 查停充流程。
- roothide 正式发布线改为原生构建；本地 libroot 由脚本/CI 填充，不再依赖误提交的本地 stub。

### Notes

- **若完整诊断显示 daemon 离线 / Could not connect to the server**：属于 LaunchDaemon 或进程未监听 `127.0.0.1:1230`，不是 iOS 17 读电量 key 未适配。请在 jbroot shell 检查 `launchctl` 与前台运行 `ChargeLimiterDaemon`（详见排障说明）。
- 回归建议：roothide 安装后打开策略诊断 → 一键复制，确认路径非空、库状态文案合理；daemon 在线机确认 service/key/电量行有数；`./scripts/build_packages.sh` 能产出 tipa + 三份 deb。
- 适用于 rootful / rootless / roothide / TrollStore；roothide 用户请安装 `ChargeLimiter_*_roothide_arm64e.deb`。

## v1.14.0 - 2026-08-06

本版主要解决了 roothide（iOS 17）环境下充电控制失效与 App 语言/设置重启后丢失两大问题：新增 iOS 17 停充写法探针并落地了专用的 override 充电控制平面，同时把 App 专属设置抽离到独立 store 彻底修复重启丢失。

### Fixed

- **修复 roothide 下 App 语言每次杀后台重启后重置为"跟随系统"**：根因是 daemon 以 root 创建的共享配置 plist 属主为 root:wheel，mobile App 无法以原子替换方式写入。现在 postinst 在 bootstrap daemon 前把共享数据目录修复为 `mobile:mobile 0750`、plist `0640`；并把四个 App 专属设置抽离到独立的 NSUserDefaults suite，与 daemon 共享文件物理隔离。
- **修复 iOS 17 有效停充后主界面仍显示"正在充电"**：iOS 17 上 sticky `IsCharging=true` 不会随停充清除，导致 UI 误判充电态。现在显示层以电流 + daemon 充电命令/保持/抑制/策略状态为准，停充时正确显示"已连接电源 · 停止充电"，保持时显示"插电保持中"。
- **修复 iOS 17 停充写法极性错误**：override 写服务写入 `IsCharging` + `PCI` 的反极性而非 `ChargingOverride` bit，并同步 `g_chargeCommandEnabled`，避免命令态与实际不一致。
- 修复探针超时与属性转换、深探针覆盖 `prop_only` 路径延迟生效的问题。

### Added

- **iOS 17 停充控制探针**（设置 → 诊断）：一键尝试多种停充写法并自动恢复，产出可复制的探针结果与诊断摘要，帮助在不支持的机型上找到真正生效的写法。深探针对每条 path 观察 2 秒以捕捉 `prop_only` 路径的延迟电流停止。
- **iOS 17 override 充电控制平面**：新增 `AppleSmartBatteryManager` 服务的 charge/inflow override 写路径，`setChargeStatus` / `setInflowStatus` 在 iOS 17 路由到独立写服务，读服务与之分离。
- **App 独立 settings store**：`CLAppSettingsStore`（suite `com.chargelimiter.mod.appdata`）承载 `AppLanguage` / `AppAppearance` / `SliderHapticStyle` / `StopChargePresetValue`，首启从共享 plist / standardUserDefaults 迁移，事务写并读回校验。
- **写失败 UI 反馈**：App 专属设置写盘失败时弹出"保存失败"提示并去重，不再静默吞掉。
- 本地化新增 iOS 17 override 探针路径相关标签。

### Changed

- App 专属设置改走 `CLAppSettingsStore`，daemon 侧语言 (`lang` key) 仍独立经 HTTP API 同步，两侧互不踩踏。
- 本地化逻辑从 utils.mm 抽离到独立的 `CLLocalization.m`。
- postinst 用变量 `DATA_DIR_LOGICAL` 间接传递共享目录逻辑路径，规避 roothide 打包转换把 `/var/mobile/...` 改写为 `/rootfs/var/...` 的 sed 规则。
- 构建脚本修复宿主 umask 077 致 `DEBIAN` 目录以 0700 落盘被 dpkg-deb 拒绝的问题。

### Notes

- 适用于 rootful / rootless / roothide / TrollStore 四种环境，roothide 包由 rootless 暂存树转换生成。
- roothide 用户建议优先回归：杀后台重启后语言/深色模式/震动/停充预设是否保持；切换语言后 daemon 文案是否同步；诊断里运行停充探针是否正常。

## v1.13.9 - 2026-06-23

这一版修复了 v1.13.8 引入的配置持久化问题，彻底解决杀后台重开后设置丢失的问题。

### Fixed

- **修复配置持久化失败问题**：v1.13.8 将配置文件移到 app 数据容器后，在 roothide 环境下因路径解析错误导致配置文件被写入到只读的 Bundle 目录，无法保存。现在统一将所有越狱环境的配置、数据库、日志放在 daemon 可访问的共享目录 `/var/mobile/ChargeLimiter/`，彻底解决写入权限问题。
- 修复配置迁移逻辑：从 NSUserDefaults 迁移配置后立即写盘，确保数据持久化。
- 修复杀后台重开后停充预设、滑动震动等设置丢失的问题。

### Added

- **自动清理空目录**：迁移或删除旧版数据后，自动清理遗留的空 ChargeLimiter 目录，保持系统整洁。

### Changed

- **重新调整数据路径策略**：
  - **越狱环境**（rootless / rootful / roothide）：配置文件、数据库、日志统一存放在 `/var/mobile/ChargeLimiter/`（jbroot 解析后的共享目录），确保 app 和 daemon 都能访问。
  - **TrollStore**：继续使用 app 数据容器 `<容器>/ChargeLimiter/`，不受越狱路径影响。
- 自动从旧路径迁移数据（`/var/mobile/Library/ChargeLimiter/`、`/var/mobile/Library/Application Support/ChargeLimiter/`、`/var/ChargeLimiter/` 等），保证升级平滑。

### Notes

- 相比 v1.13.8 的 app 数据容器方案，本版回归到共享目录方案，原因是 roothide 的 libroot 路径解析会将某些路径错误解析到只读的 Bundle 目录，而 daemon 需要访问配置文件，必须放在共享位置。
- 旧版本的配置文件会自动迁移，不会丢失数据。
- 迁移后的空目录会自动清理，无需手动删除。

## v1.13.8 - 2026-06-19

这一版把配置文件改存到 app 数据容器，并集成 libroot 重构越狱路径解析，根治清后台重开 / 重新越狱后配置丢失的问题。

### Changed

- 配置文件改存到 app 数据容器（`/var/mobile/Containers/Data/Application/<UUID>/ChargeLimiter/`），不再放在 jbroot 的 Preferences 目录。app 数据容器是 iOS 系统路径，不依赖 jbroot，roothide 重新越狱（jbroot 路径变化）或 libroot 偶发漂移时配置都不会丢失。roothide / rootless / TrollStore 统一此存储位置。
- 数据库与日志仍保留在 jbroot（`jbroot:/var/ChargeLimiter`），因为写入频繁，jbroot 下权限统一更稳妥。
- 路径解析改用 libroot 标准 API（`libroot_dyn_jbrootpath`，运行时动态加载），替代手动拼接 jbroot 路径。
- 工程与 Makefile 链接 `-lroot`，补充库搜索路径。
- roothide 安装包维护脚本去重 `jbroot` 调用。
- 精简路径解析代码：移除配置路径冻结机制、jbroot 配置别名清理、data-root 配置清理等不再需要的逻辑（配置已不在 jbroot）。

### Fixed

- 修复清掉软件后台再打开时配置文件被删除或清空的问题。根因是配置路径解析偶发漂移，叠加自动迁移/清理逻辑把当前配置误判为旧配置删除，以及 daemon 重载读不到配置后用空副本覆盖盘。现在配置改存 app 数据容器（稳定不漂移），自动迁移与清理不再删除配置（只记日志），`reloadFromDisk` 读不到时保留内存副本不再清空，从 `NSUserDefaults` 迁移后不再删除旧值（保留备份），配置读取失败时不再写盘。
- 修复因路径解析偶发漂移导致偶尔读不到配置、软件设置变回默认值的问题（配置改存 app 数据容器后路径不再漂移）。

### Notes

- 旧版本存放在 jbroot Preferences 的配置，首次启动会自动迁移到 app 数据容器。
- 语言、滑动震动、深色模式、停充预设等设置迁移后保留 `NSUserDefaults` 备份，不再因写盘失败永久丢失。
- 数据库（历史统计）与日志仍在 jbroot，重新越狱后可能需要重新积累；如需也迁到 app 数据容器，后续版本再处理。

## v1.13.7 - 2026-06-12

这一版重点修复 roothide 环境下软件设置在重启后被重置的问题。

### Fixed

- 修复 roothide 重启用户空间或重新越狱后，“软件设置”里的语言、滑动震动、停充预设、深色模式被重置的问题。这些选项原先写入 `NSUserDefaults`，在 roothide 下无法随 jbroot 持久化，现已统一改用与配置文件相同的持久化存储。
- 修复深色模式只在手动切换时生效、重启后不会自动应用的问题：现在启动时会读取已保存的外观设置并应用，不再出现“设置显示深色、实际跟随系统”的情况。

### Changed

- 旧版本写入 `NSUserDefaults` 的上述设置，会在首次启动时一次性迁移到新的持久化存储，升级后无需重新设置。

### Notes

- 刷新频率、历史统计开关、充电高级页的全部选项一直走配置文件持久化，本就不受此问题影响。

## v1.13.6 - 2026-06-06

这一版继续收口 roothide 的配置保存路径，解决配置写到错误位置导致丢失的问题。

### Fixed

- 修复 roothide 下配置可能被写入裸 `/var/mobile/Library/Preferences` 而无法持久化的问题：现在统一通过 jbroot 解析出真实的偏好目录再读写，重启或重新越狱后配置不再丢失。
- 修复 roothide 安装包的脚本路径转换规则，避免维护脚本残留错误路径影响安装与卸载。

### Changed

- roothide 下会自动清理旧的裸 rootfs 配置副本，并在迁移成功后删除残留的旧配置文件，避免设置页误报“存在旧版残留”。
- 进入设置页前会先重新加载本地配置，让迁移和清理先完成，减少刚打开设置页时的误判。

## v1.13.5 - 2026-06-04

### Fixed

- 修复开启“永久停用系统优化充电”后，daemon 普通退出仍可能把系统优化充电恢复为开启的问题。
- 区分普通退出与卸载、重置等显式清理路径：普通退出会保留用户的永久停用配置，卸载或显式重置时才恢复系统优化充电。

## v1.13.4 - 2026-06-04

### Fixed

- 修复简易 HTTP 服务器在 POST 接口返回非 JSON 安全对象、非法数值或序列化异常时可能导致响应失败或服务线程异常的问题。
- POST handler 抛出 Objective-C 异常时会记录日志并返回 500 错误响应，避免异常继续向外传播。

### Changed

- HTTP JSON 响应增加统一兜底转换：递归处理字典、数组、集合、日期、URL、二进制数据和未知对象，并对 NaN / Infinity 等非法数值做安全降级。

## v1.13.3 - 2026-05-24

### Changed

- `aldente.log` 改为只记录异常、失败和 fallback 场景，不再写入 daemon 启动、插拔、正常充停、计划充电更新、悬浮窗显示/隐藏等普通状态。
- 旧版数据迁移不再迁移历史 `aldente.log`，只迁移配置和数据库；旧日志仅作为残留文件处理。
- 文件日志接口改为错误日志语义，并增加日志大小上限，避免异常重复时持续增长。

## v1.13.2 - 2026-05-19

### Changed

- 软件设置新增跳转“配置文件”，点击后会直接定位当前实际使用的配置文件。

### Fixed

- 修复roothide重启用户空间、重新越狱丢失配置

## v1.13.1 - 2026-05-16

### Changed

- 越狱、rootless、roothide 版本改为使用稳定的共享应用数据目录；TrollStore 版本继续使用应用沙盒目录。
- Sailing Mode默认改为关闭，补电阈值默认调整为 `5`。
- 配置文件命名统一为 `com.chargelimiter.mod.plist`，保留旧命名兼容迁移。

### Fixed

- 修复新版无法正确定位应用数据目录的问题，“应用数据目录”现在会优先打开当前实际使用的数据目录。
- 修复旧版数据迁移与残留检测逻辑，避免把当前正在使用的配置文件误判为旧版残留。

## v1.13.0 - 2026-05-16

### Changed

- 移除充电模式的边缘触发
- 重整插电保持相关 UI 与文案、运行逻辑
- 支持关闭历史统计

### Fixed

- 修复在 roothide 一类容器路径下，“应用数据目录”无法打开、以及“迁移旧版数据”时报 `Target documents path is unavailable.` 的问题

## v1.12.5 - 2026-05-14

这一版主要收口智能停充默认行为、卸载恢复链路和后续自动发版能力。

### Changed

- 智能停充默认改为开启，新安装后更接近推荐配置，减少首次使用时的额外设置成本。
- 调整“智能停充”相关文案，明确它的作用范围和失败回退行为。
- 限流控制切换逻辑做了整理，减少配置切换时的理解成本。

### Fixed

- 补齐退出和卸载前的充电状态恢复链路，降低卸载后残留旧充电状态的风险。
- 修复 iOS 15 图标兼容性问题。

### Maintenance

- 补齐 GitHub Actions 自动发布 Release 流程，后续版本可自动构建并上传 TrollStore、rootful、rootless、roothide 四类产物。

## v1.12.4 - 2026-05-05

这一版主要补了停充预设入口，同时把默认策略和卸载清理路径一起理顺。

### Added

- 新增停充预设功能，主页可以一键应用常用停充电量。
- 预设按钮支持点击直接应用、长按进入编辑。
- 软件设置页新增停充预设入口，便于集中管理。

### Changed

- 默认策略调整为开启插电保持，更贴近长期插电用户的常见需求。

### Fixed

- 卸载清理改为由 daemon 直接处理真实数据容器，去掉 `com.chargelimiter.mod.containerpath` 依赖，减少路径残留与错删风险。

### Maintenance

- 优化 roothide 包构建流程。

## v1.12.2 - 2026-04-24

这一版以稳定性修复为主，重点处理禁流和智能停充在部分设备上的边界行为。

### Fixed

- 修复高电量插电时禁流不生效的问题。部分设备在刚插电时会返回不完整的充电信息，导致已达到停充阈值时 daemon 可能误判为未插电或未进入禁流态；现在已补充延迟重评估和有限次重试。
- 优化智能停充（SmartBattery API）失败时的处理逻辑。若系统拒绝写入，或停充命令发出后一段时间仍未真正进入抑制态，会自动回退到传统 `IsCharging` 停充路径，减少“开了但没停住”的情况。

### Changed

- 智能停充默认关闭。新安装、重置配置或默认值补全过程中，不再默认启用 SmartBattery API 停充路径。
- 优化智能停充相关说明文案，明确这是“可回退”的停充路径，而不是绝对更高级的模式。

## v1.12.0 - 2026-04-17

这一版主要补了通知与 `100%` 停充控制模式切换。

### Added

- 新增通知功能。
- 增加“停止充电设为 `100%` 时由软件还是系统控制”的切换能力。

### Maintenance

- 优化安装包构建流程。

## v1.11.4 - 2026-04-05

这一版集中修正“插电保持”与 `100%` 上限模式的行为边界，让界面和实际生效逻辑一致。

### Fixed

- 修复插电保持在还没达到停止电量前就提前生效的问题。
- 现在只有设备先达到一次设定的停止电量后，保持带宽策略才会开始接管。

### Changed

- 当“停止充电”设置为 `100%` 时，hold 相关选项会直接置灰，不再出现“界面可用但实际不生效”的情况。
- 切换到 `100%` 系统控制模式时，新增更明确的提示文案。
- 当停止电量从 `100%` 调回 `100%` 以下时，之前的 hold 设置会自动恢复，无需重新设置。

### Notes

- `100%` 模式下电量控制会交还给系统，但温度控制仍然保留。

## v1.11.3 - 2026-03-29

这一版主要增强主界面停充阈值的快捷操作，并继续收紧停充相关互锁规则。

### Added

- 主界面“停止充电 (电量 ≥)”新增“设为当前”按钮，可一键把停充阈值设置为当前电量，并立即同步滑块、数值和顶部电池标记。

### Changed

- 优化停充相关互锁逻辑，减少禁流、插电保持、智能停充等组合同时开启时带来的无效或冲突状态。
- 在边缘触发模式下，快捷设置仍会保持“开始充电 < 停止充电”的约束，不会破坏原有阈值关系。

## v1.11.1 - 2026-03-23

这一版主要修正主界面供电状态的判断逻辑。

### Fixed

- 修复设备实际在用电池时，主状态仍可能误显示“已连接电源 · 停止充电”的问题。
- 主界面顶部状态、电池动画和适配器卡片改为统一按实际供电路径判断，减少显示互相打架。

### Changed

- 主界面“守护策略”文案调整为“供电状态”，减少策略状态与实时供电状态混淆。
- 调整关键阈值或高级开关后，会立即重新评估策略状态并刷新显示。

## v1.11.0 - 2026-03-23

这一版主要把更新检查和新的电池状态表达补齐到主界面。

### Added

- 新增检查更新功能，支持发现新版本后弹窗提示并跳转 GitHub Releases。

### Changed

- 重做右上角电池状态图标，充电、低电量、保持、高温暂停等状态更直观。

## v1.10.1 - 2026-03-21

这一版是插电保持和策略诊断能力的第一次完整落地。

### Added

- 新增插电保持、保持带宽与保持策略，支持更接近电脑插电驻留的保电量体验。
- 新增第一版智能自适应保持策略，可根据负载、供电环境和温度动态调整行为。
- 新增 Smart Charge 协调、策略诊断、最近策略切换与长时间事件时间线，排障和长测更直观。
- 新增满充计划，支持定期临时解除电量上限。

### Fixed

- 修复 `100%` 系统接管模式下的充电图标显示问题。

### Changed

- 优化高级设置页面布局。

## v1.9.6.3 - 2026-02-26

这一版把 `100%` 停充模式正式收口到“交由系统控制”这条语义上。

### Changed

- 停止充电电量设为 `100%` 时，电量控制交由系统接管，不再按电量阈值主动断充。
- 保留温度控制与安全兜底策略，`100%` 模式下仍可按温控逻辑介入。
- 新增“系统电量控制中，温度控制仍生效”浮层提示，仅在切换到 `100%` 时短暂显示并自动隐藏。

### Fixed

- 修复 `100%` 模式下图标不显示绿条的问题。

## v1.9.6.2 - 2026-02-16

### Fixed

- 修复越狱版的温度配置保存问题，并顺手优化了一部分相关逻辑。
- 修复温度显示问题。

## v1.9.6.1 - 2026-02-15

### Fixed

- 修复 TrollStore 版本配置保存问题，并统一颜色背景。

## v1.9.6 - 2026-02-10

### Fixed

- 修复 iPad 上点击操作菜单闪退的问题。

### Changed

- 优化 iPad 界面布局，支持居中显示与分屏适配。

## v1.9.5 - 2026-02-07

### Added

- 增加迁移和删除旧版数据功能，迁移后会自动删除旧版数据。
- 配置文件目录输出到应用数据目录中，删除软件不会保留旧数据。

## v1.9.3 - 2026-02-04

### Added

- 顶部“ChargeLimiter”右侧新增刷新按钮，便于切换配置时快速刷新。

### Changed

- 刷新按钮会让守护进程立即读取当前电池状态和配置，并立刻执行充电策略（如停充、恢复、限流），同时更新界面显示。
- daemon 充电策略抽成统一函数，便于复用与维护。

### Notes

- 安装包大小有时约 `200KB`、有时约 `500KB`，主要取决于 `Assets.car` 大小变化。

## v1.9.2 - 2026-02-04

### Changed

- 优化 UI 和交互。

## v1.9.0 - 2026-02-04

这一版是从功能堆叠向可持续维护版本迈的一大步。

### Added

- 包名和标识更新为 `com.chargelimiter.mod`，避免与原作者冲突。
- 完整补齐本地化资源（Base / 英文 / 简体中文），修复语言切换逻辑。
- 充电与温控设置交互优化：滑块拖动震动反馈，支持震动强度分级。
- 配置文件保存位置优化，软件设置里可一键跳转对应文件夹（需安装 Filza）。

### Changed

- 设置页结构与样式优化，包括入口卡片统一风格、说明文字间距调整。
- 历史统计图表细节优化，包括 Tooltip、时间轴标签、自适应密度和选中点高亮。
- iOS 15 兼容图标回退处理，统一图标语义与颜色规范。

### Fixed

- 修复温度控制开关进入页面偶发灰色的问题。

## v1.8 - 2026-02-01

这一版是界面层面的完整重构。

### Changed

- 将原有 WebView 界面全部替换为原生 UIKit，整体风格更现代、更流畅。

### Removed

- 彻底移除悬浮窗相关功能和代码，以及一部分长期不用的旧功能。

## v1.7 - 2024-10-01

### Added

- 支持 SBC。

## v1.6.1 - 2024-06-30

### Added

- 增加 iOS 17 适配。
- 补齐和修正多语言本地化逻辑。

### Fixed

- 修复 CarPlay 导致悬浮窗无法自动隐藏的问题。
- 修复一个月后无法看到 5 分钟数据和小时数据的问题。

### Changed

- 悬浮窗自动隐藏逻辑兼容 CarPlay。

## v1.6 - 2024-04-29

### Fixed

- 修复温控相关 bug。
- 修复一批通用错误与异常场景。

## v1.5 - 2024-03-30

### Added

- 新增 `DisableInflow` 模式。
- 新增帮助说明。
- 新增按月统计。
- 新增快捷指令支持。
- 新增图表能力，方便其他开发者测试。

### Fixed

- 修复横屏 App 自适应问题。
- 修复越狱环境通知问题。
- 解决初始化显示模板问题。

### Maintenance

- 新增 `Makefile`。

## v1.4.1 - 2024-03-01

### Added

- 通知增加总开关。
- 支持 MagSafe。
- 支持 Safari。
- 增加一键拷贝数据，辅助开发者增强兼容性。
- 增加夜间模式。
- 增加适配系统版本说明与使用条款。

### Fixed

- 修复 iPad 横屏时拖动悬浮窗导致残缺的问题。
- 修复悬浮窗点击无效的问题。

### Changed

- 强化浮窗图标、请求超时、`update_freq` 与参数说明。
- 优化 Web UI 与 iPad 悬浮窗跟随设备朝向逻辑。

## v1.4 - 2024-02-14

### Added

- 新增通知能力。
- 增加作者信息。
- 图标改为圆角，并更新启动页与应用图标。

### Changed

- 项目更名为 `ChargeLimiter`。

### Fixed

- 修复无根越狱判断问题。

## v1.3 - 2024-02-12

### Added

- 增加无根越狱支持。

## v1.2 - 2024-02-12

### Added

- 为普通用户增加“插电即充”模式。
- 增加英文说明。

### Changed

- 将 timer 驱动改为 event driver。
- 移除不必要的 entitlements。
- 优化界面。

## v1.1 - 2024-02-05

### Notes

- `1.1` 与 `1.0.1` 指向同一提交，本次未单独引入新代码变化。

## v1.0.1 - 2024-02-05

### Added

- 增加真后台能力。
- 补充 iOS 16 arm64 兼容修正。

## v1.0 - 2024-02-03

### Added

- 首次提交。
