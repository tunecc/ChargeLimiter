# roothide App 设置持久化 - 设计文档

**日期**: 2026-08-04
**状态**: 已实现，待家家机回归测试

## 问题描述

在 roothide 越狱环境（iPhone16,2 / iOS 17.1）中，App 语言偏好（"跟随系统 / English / 简体中文"）每次杀掉 App 后台并重启 App 后都会重置为"跟随系统"。其它 App 专属设置（深色模式 `AppAppearance`、滑动震动 `SliderHapticStyle`、停充预设 `StopChargePresetValue`）也存在同类风险。

### 先前结论核对

先前分析判断 c18c306 "fix(settings): preserve app language after restart" 只完成了一半修复，根因是**共享目录权限边界**。本次核对确认该分析成立：

- daemon 以 root 运行，在 `jbroot()/var/mobile/ChargeLimiter` 下创建 `com.chargelimiter.mod.plist`，文件属主为 `root:wheel`。
- mobile App 无法以 `NSDataWritingAtomic`（原子替换）方式写入该 plist，导致 App 侧的写入要么静默失败、要么写到裸 rootfs 路径而无法被 daemon 读取。
- 重启后 App 回读不到自己写入的值，于是 fallback 为默认（"跟随系统"）。

## 修复方案

分三步推进，彼此正交：

### 第 1 步：postinst 修复共享数据目录权限

`ChargeLimiter/Package/DEBIAN/postinst`（rootful）与 `ChargeLimiter/Package_rootless/DEBIAN/postinst`（rootless / roothide 转换源）新增 `repair_shared_data_permissions()`，在 `launchctl bootstrap` daemon **之前**把共享数据目录校正为 mobile 可读写：

- 目录 `/var/mobile/ChargeLimiter`：`mobile:mobile 0750`
- 配置 `com.chargelimiter.mod.plist`：`mobile:mobile 0640`

> 故意为 rootless postinst 用变量 `DATA_DIR_LOGICAL="/var/mobile/ChargeLimiter"` 间接传递路径，避开 roothide 打包转换 `rewrite_roothide_maintainer_script` 里 sed 把 `/var/mobile/...` 改写成 `/rootfs/var/...` 的字面规则。运行时再经 `jbroot` 解析为真实物理路径（`resolve_cl_data_root`）。逐字测试 `test_roothide_conversion_preserves_jbroot_logical_data_path` 验证转换后仍保留 `DATA_DIR_LOGICAL`、不出现 `/rootfs/var/mobile/ChargeLimiter`。

### 第 2 步：写失败 UI 反馈

App 侧所有"App 专属设置"写入路径统一在失败时发送 `CLConfigWriteFailedNotification`（在 utils.mm 定义/广播，`extern NSString* const CLConfigWriteFailedNotification`），由 `AppDelegate` 监听并弹出失败提示去重：

- `CLSettingsViewController.m` 的 `CLSetLocalIntegerForKey` 在 `setIntegerForKey:value:error:` 失败时 post 该通知。
- `languageTapped` 检查 `CLSetAppLanguage(language, &error)` 返回值，失败时同样 post；成功才 `syncDaemonLanguageWithAppLanguage:`。
- `ui.mm` `AppDelegate` 在启动时 `addObserver:handleConfigWriteFailure:`，并用 `@synchronized` 守 `_configWriteAlertIsShowing` 做去重，避免短时间内多次失败弹窗轰炸。

### 第 3 步：App 独立 settings store

新增 `ChargeLimiter/UIKit/CLAppSettingsStore.{h,m}` 与 `ChargeLimiter/CLLocalization.m`，把四个 App 专属 key 物理隔离到独立 NSUserDefaults suite `com.chargelimiter.mod.appdata`：

| Key | 取值 | 校验 |
|---|---|---|
| `AppLanguage` | 0=system / 1=en / 2=zh-Hans | `[0,2]` |
| `AppAppearance` | 0=system / 1=light / 2=dark | `[0,2]` |
| `SliderHapticStyle` | 0-3 | `[0,3]` |
| `StopChargePresetValue` | 0 或 15-100 | 0 或 `[15,100]` |

要点：

- `+ (instancetype)shared` 单例。
- `-integerForKey:defaultValue:` 读，非法值回退 `defaultValue`。
- `-setIntegerForKey:value:error:` 事务写入：写后读回校验，不一致则回滚并返回 NSError。
- `-migrateIfNeeded:` 首次启动迁移，priority：appdata suite > 共享 plist（经 `dlsym(jbroot)` 与 `dlsym(getConfigReadPathsWithLibroot)` 解析）> standardUserDefaults > 0。迁移成功后写 `CLAppSettingsMigrationVersion` 标记避免重跑。
- `CLLocalization.m` 提供 `CLLocalizedString`/`CLGetAppLanguage`/`CLSetAppLanguage(…,&err)`/`CLApplyLanguageFromSettings`/`CLSetLocalizationBundle`，从 utils.mm 抽离本地化逻辑。
- `ui.mm` `didFinishLaunchingWithOptions` 在启动时调 `migrateIfNeeded:` 并 `CLApplyLanguageFromSettings()`；`AppAppearance` 读取改为 `[[CLAppSettingsStore shared] integerForKey:@"AppAppearance" defaultValue:0]`。
- daemon 侧仍以独立 `lang`（字符串 `en`/`zh-Hans`/`system`）为准，经 HTTP API `setConfigWithKey:` 同步，与 App 物理隔离互不踩踏。

### 工程集成

`ChargeLimiter.xcodeproj/project.pbxproj` 新增 `CLLocalization.h/.m`（顶层组）与 `CLAppSettingsStore.h/.m`（UIKit 组）的 `PBXFileReference` / `PBXGroup` / `PBXBuildFile`（rootful 与 rootless 两个 App target 的 Sources phase 各一份编译条目）。CLAppSettingsStore.m 使用 `extern "C"` 与 `dlsym`，文件类型登记为 `sourcecode.cpp.objcpp` 并补 `#import <dlfcn.h>`。

`scripts/build_packages.sh` 修一处 dpkg-deb 阻塞：宿主 umask 077 会让模板 `DEBIAN/` 目录以 0700 落盘，`cp -a` 原样保留后被 dpkg-deb 拒绝（`control directory has bad permissions 700`）。在 rootful/rootless 与 roothide 转换两处各加 `chmod 755 "$DEBIAN"`。

### 自测与契约测试

- utils.mm 内 `extern "C" BOOL CLRunAppSettingsStoreSelfTest(NSString**)`：用临时 NSUserDefaults suite 验证写读回、回滚。
- `scripts/tests/` 下 7 个新增 unittest：
  - `test_shared_data_permissions_postinst.py` —— postinst 权限修复 + roothide 转换保真。
  - `test_config_write_failure_feedback.py` —— 写失败 UI 反馈契约。
  - `test_app_settings_store_interface.py` / `test_app_settings_store_migration.py` —— store 接口与迁移。
  - `test_localization_extracted.py` —— 本地化函数从 utils.mm 抽出。
  - `test_startup_migration.py` —— 启动期 migrate / apply language。
  - `test_key_readpoint_rewiring.py` —— App 专属 key 读写改走 CLAppSettingsStore / `CLSetAppLanguage` 检查返回值。
- `CLTestApp.m` 在测试入口里依次跑 `CLRunLocalizationPersistenceSelfTest` 与 `CLRunAppSettingsStoreSelfTest`。

## 验收

- `python3 -m unittest discover -s scripts/tests`：51/51 通过。
- `./scripts/build_packages.sh`：rootful / rootless / roothide / TrollStore 四个产物全部构建成功并通过 `Verify package contents`。
- deb 内 postinst 校正：`repair_shared_data_permissions` 命中，roothide 包内 postinst 保留 `DATA_DIR_LOGICAL`、未被改写为 `/rootfs/var/mobile/ChargeLimiter`。
- App 二进制 `strings` 命中 `CLAppSettingsStore` / `migrateIfNeeded:` / `com.chargelimiter.mod.appdata`。

## 待真机回归

待用户在 iPhone16,2 / iOS 17.1 roothide 上装 `ChargeLimiter_1.13.9_roothide_arm64e.deb`，验证：杀 App 重启后语言保持；切换语言后 daemon `lang` 同步；深色模式/滑动震动/停充预设重启不丢；写失败时是否弹提示。
