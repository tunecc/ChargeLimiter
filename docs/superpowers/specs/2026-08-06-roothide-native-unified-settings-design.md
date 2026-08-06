# 原生 Roothide 打包 + 统一共享配置 - 设计文档

**日期**: 2026-08-06  
**状态**: 已批准，待写实现计划  
**关联**: 取代/收敛 `2026-08-04-roothide-app-settings-persistence-design.md` 中「App 独立 suite 为权威源」的方向；保留其 postinst 权限修复与写失败 UI 反馈中仍然有效的部分。

## 1. 背景与问题

在 1.14.0 发布回归中观察到三类问题，且与当前工程形态直接相关：

1. **roothide：卸载旧版后装新版，设置页反复提示「保存失败」，但设置似乎已生效**  
   - 1.14 引入 `CLAppSettingsStore`（suite `com.chargelimiter.mod.appdata`），写路径以 `NSUserDefaults synchronize` + 读回校验为成功条件。  
   - 在 roothide 上该返回值/持久化语义不可靠时，会出现「内存或实际已生效，校验判失败 → 误报保存失败」。

2. **rootless：安装 1.14 后 UI 仍显示 1.13.9，配置相关也异常**  
   - `project.pbxproj` 的 `MARKETING_VERSION = 1.14.0`，`Package*/DEBIAN/control` 构建时写入 1.14.0。  
   - 但 `ChargeLimiter/Info.plist` 中 `CFBundleShortVersionString` **硬编码为 `1.13.9`**，App target 使用该 Info.plist，设置页用 bundle 短版本显示 → 用户看到 1.13.9。

3. **roothide 包非原生**  
   - `scripts/build_packages.sh` 默认把 rootless 暂存树 **转换** 成 roothide deb（RootHidePatcher 风格：布局搬家、`install_name_tool`、maintainer script sed）。  
   - 仓库明确承认「尚无原生 roothide Xcode 打包入口」。转换链路 fragile（路径 sed、权限、脚本 `/rootfs` 改写），与官方发布方式不一致。

### 1.1 权威外部依据（已检索）

| 来源 | 要点 |
|---|---|
| [roothide/Developer](https://github.com/roothide/Developer) | `THEOS_PACKAGE_SCHEME=roothide`；`#include <roothide.h>` + `jbroot()`；必备 entitlements；Xcode 可用 [libroothide devkit](https://github.com/roothide/libroothide/releases) |
| [roothide.md](https://github.com/roothide/Developer/blob/main/roothide.md) | 包布局同 rootful（无固定 `/var/jb`）；链接 `@loader_path/.jbroot/`；bootstrap 默认根为 jbroot，系统根在 `/rootfs` |
| [entitlements.md](https://github.com/roothide/Developer/blob/main/entitlements.md) | 越狱数据放 jbroot 的 `/var/`；Mach-O 不可放在 jbroot `/var/` 或 `/tmp/` |
| [interface.md](https://github.com/roothide/Developer/blob/main/interface.md) | `jbroot` / `rootfs` / `jbrand` API 语义 |
| [The Apple Wiki · Roothide](https://theapplewiki.com/wiki/Roothide) | deb `Architecture: iphoneos-arm64e`（与 CPU arm64e 无关）；dpkg 装入随机 jbroot |

检索工具：`mcp__moor__grok_search_rs__web_search` / `web_fetch`（2026-08-06）。

## 2. 目标与非目标

### 2.1 目标

1. **统一配置存储**：App 专属四键与 daemon 配置回到**同一共享 plist**；废除 appdata suite 作为权威源。  
2. **写盘语义诚实**：「保存失败」仅在共享 plist **真正写盘失败** 时出现；消除 suite/`synchronize` 假阳性。  
3. **权限可自愈**：postinst + 进程启动双闸，保证 mobile App 与 root daemon 都能写共享文件且写后权限不锁死 App。  
4. **版本单源**：UI / control / 产物文件名均来自 `MARKETING_VERSION`。  
5. **原生 roothide 发布线**：Xcode scheme + `Package_roothide` + `build_packages.sh` / GitHub Actions **默认原生构建**，不再依赖 rootless→roothide 转换主路径。  
6. **文档对齐**：构建说明与 roothide 维护者文档反映上述事实，并链到官方 Developer 文档。

### 2.2 非目标

- 不改充电控制算法 / iOS 17 探针逻辑。  
- 不把整仓发布主线迁到纯 Theos `make package`（仍以 Xcode + 打包脚本为主）。  
- 不新增长连接程 IPC；App 继续直接写共享文件 + 现有 HTTP。  
- 不把 TrollStore 数据根强行改成越狱共享路径。  
- 不在本设计中引入跨进程文件锁（除非回归证明必要）。

## 3. 已确认决策

| # | 决策 |
|---|---|
| D1 | 配置模型选 **B**：撤掉独立 suite 权威源，四键回到共享 plist。 |
| D2 | 写模型选 **A**：App 与 daemon **都可直接写** 同一共享 plist；靠权限修复保证可写。 |
| D3 | 打包选 **A**：Xcode + `build_packages.sh` 增加**原生** roothide 入口（非 Theos 主线、非继续默认转换）。 |
| D4 | 数据根选 **A**：逻辑路径 `/var/mobile/ChargeLimiter/`，配置 `…/com.chargelimiter.mod.plist`；roothide 运行时 `jbroot(...)`。 |
| D5 | 迁移选 **A**：启动时从 appdata suite / standardUserDefaults / 旧路径迁入共享 plist，成功后清理双源。 |
| D6 | 总方案选 **方案 1**：统一共享存储 + 原生 roothide 发布线一次收口（非「只修表象」）。 |

## 4. 架构

### 4.1 存储权威源（唯一）

| 项 | 值 |
|---|---|
| 逻辑数据根 | `/var/mobile/ChargeLimiter/` |
| 配置文件 | `/var/mobile/ChargeLimiter/com.chargelimiter.mod.plist` |
| roothide | `jbroot("/var/mobile/ChargeLimiter/…")` |
| rootless | 现有 libroot / 安装前缀解析，逻辑路径不变 |
| rootful | 直接使用上述逻辑路径 |
| TrollStore | 继续 app 容器模型（与越狱共享根分离） |

### 4.2 键归属

同一 plist 内：

| Key | 谁写 | 谁读 |
|---|---|---|
| 充电/策略等 daemon 配置 | App UI + daemon | 双方 |
| `AppLanguage` / `AppAppearance` / `SliderHapticStyle` / `StopChargePresetValue` | **App 经共享 store 直写** | App；daemon **不**用这四键做业务逻辑 |
| `lang`（`en` / `zh-Hans` / `system`） | App 经现有 HTTP `setConfigWithKey:@"lang"`（或写共享后 daemon reload） | daemon 文案 |

- 四键主路径：`setlocalKV` / `CLSettingsStore` → 原子写共享 plist。  
- `CLAppSettingsStore`：降为 **migrate-only**（或迁移完成后删除主路径调用）；不再作为读写权威。  
- 禁止第二套权威文件长期并存。

### 4.3 组件关系

```
UI (设置 / 语言 / 外观 / 震动 / 停充预设)
    → setlocalKV / CLSettingsStore.apply
    → 原子写 共享 plist
         ↑ reload / 读盘
daemon

启动:
  1. ensure/repair 数据根权限 (best-effort)
  2. load 共享 plist
  3. migrate(appdata + standardUserDefaults + 旧路径) → 共享 → 清双源
  4. CLApplyLanguageFromSettings()  // 只读共享
  5. 可选 HTTP 同步 lang
```

## 5. 写盘、权限与「保存失败」

### 5.1 保存成功的唯一定义

共享 plist 写入成功当且仅当：

1. 解析写路径（越狱：`getConfigWritePathWithLibroot()`，逻辑落在 `/var/mobile/ChargeLimiter/…`）；  
2. 父目录存在且 mobile 可写（或已自愈）；  
3. 合并 preferences + 本次变更；  
4. **原子写盘**（`NSDataWritingAtomic` 或 temp + replace）；  
5. **从磁盘读回**与预期一致。

失败：回滚内存到写前快照 → 发送 `CLConfigWriteFailedNotification`。

### 5.2 废止的假阳性

| 旧 | 新 |
|---|---|
| `NSUserDefaults synchronize == NO` ⇒ 失败 | 不再用 suite/`synchronize` 判定 App 专属设置成败 |
| 仅内存成功也当成功 | 必须以读回磁盘为准；UI 可乐观更新，失败回滚 UI |
| 写失败静默 | 保留弹窗，仅真写盘失败 |

### 5.3 权限目标态

| 对象 | owner | mode |
|---|---|---|
| 数据目录 | `mobile:mobile` | `0750` |
| 配置 plist | `mobile:mobile` | `0640` |

daemon（root）写盘后必须 **re-apply** 上述权限，避免文件变成 `root:wheel` 再次锁死 App。

### 5.4 自愈双闸

1. **postinst**（rootful / rootless / **Package_roothide** 同源逻辑）  
   - 在 `launchctl bootstrap` daemon **之前** `repair_shared_data_permissions`。  
   - 逻辑路径用变量 `DATA_DIR_LOGICAL="/var/mobile/ChargeLimiter"`，运行时经 `jbroot` 解析。  
   - 原生 roothide 脚本按 jbroot 语义编写；**不要**再套用 rootless 转换 sed 把 `/var/mobile` 改成 `/rootfs/var/mobile`。需要碰系统根时显式 `/rootfs/...`。

2. **进程启动**  
   - daemon：确保目录/文件存在 + 权限目标态。  
   - App：探测不可写时 best-effort 修复；无能力则记日志，**首次真实写失败**再弹窗（避免冷启动惊吓）。

### 5.5 弹窗策略

**触发**：原子写失败；读回不一致；无法创建数据目录且无法自愈。

**不触发**：迁移跳过/空跑；仅 `lang` HTTP 同步失败（只打日志；本版不为此复用「设置未能保存」主文案）；任何 `synchronize` 返回值。

**去重**：保留 AppDelegate `_configWriteAlertIsShowing`。

**卸载旧版再装**：无残留则创建+授权；有 root 残留则 postinst/daemon 修好；迁移失败不弹保存失败。

### 5.6 迁移顺序

```
1. repair / ensure data root (best-effort)
2. CLSettingsStore load 共享 plist
3. migrateIfNeeded:
     appdata suite → standardUserDefaults → 历史读路径
     仅当共享缺键时填入 → 一次 apply 原子写
     成功则清 appdata 标记与冗余键
4. CLApplyLanguageFromSettings()
5. 如需 HTTP 同步 lang
```

## 6. 版本号单源

### 6.1 根因

- `MARKETING_VERSION`（pbxproj）= 1.14.0  
- `ChargeLimiter/Info.plist` → `CFBundleShortVersionString` = **硬编码 1.13.9**  
- App 显示读 bundle → 用户见 1.13.9；dpkg Version 却是 1.14.0  

### 6.2 规则

**唯一人工版本源：`MARKETING_VERSION`。**

| 产物 | 来源 |
|---|---|
| `CFBundleShortVersionString` | `Info.plist` 使用 `$(MARKETING_VERSION)` |
| `DEBIAN/control` Version | `build_packages.sh` 从 pbxproj 解析并写入 |
| 输出文件名 | 同上 `VERSION` |
| GHA / tag | 与 `MARKETING_VERSION` 一致；包内 Info 与 control 同版本校验 |

构建时用 xcodebuild 产物覆盖 stage 内 `.app`，仓库模板里陈旧 Info.plist 不作为运行时版本源；实现时可清理以免误导。

实现阶段扫描硬编码旧版本字符串（例如 API 客户端中的 `ver` 字段）：若应跟随 App 版本则改为读 bundle。

## 7. 原生 Roothide 打包

### 7.1 工程

- 新增 scheme/target：`ChargeLimiter roothide`（及对称 Daemon target，与 rootless 成对）。  
- Build Settings 要点：  
  - `THEOS_PACKAGE_SCHEME=roothide`  
  - 宏与 rootless 对称（如 `THEOS_PACKAGE_SCHEME_ROOTHIDE`）  
  - Header/Library：libroothide 或 roothide/theos（路径写入维护文档；CI 预装）  
  - **编译期**产出符合 roothide 的 load/rpath（`@loader_path/.jbroot/...`），主路径不再事后改 rootless 二进制  
  - Entitlements：现有 jb entitlements **合并** roothide 基础项（`platform-application`、`com.apple.private.security.no-sandbox`、`storage.AppBundles`、`storage.AppDataContainers` 等，与 `scripts/roothide.entitlements` / 官方一致）

### 7.2 包模板 `ChargeLimiter/Package_roothide/`

- 布局同 rootful：`Applications/`、`Library/LaunchDaemons/`、`DEBIAN/`（**无** `/var/jb` 前缀）。  
- `control`：`Architecture: iphoneos-arm64e`。  
- maintainer scripts：jbroot 语义路径；`DATA_DIR_LOGICAL`；`repair_shared_data_permissions`；需要 rootfs 时显式 `/rootfs`。  
- LaunchDaemon：可执行路径为 jbroot 布局绝对路径（与 rootful 同形）。

### 7.3 `scripts/build_packages.sh`

默认：

1. build rootful  
2. build rootless  
3. **build roothide（新 scheme，独立 derivedData）**  
4. 分别 stage → tipa + 三 deb  

- **默认关闭** rootless→roothide 转换主路径。  
- 可选保留 `--legacy-roothide-convert` 作紧急回滚，**默认不启用**（与当前「默认转换」相反）。  
- 校验至少包括：  
  - roothide deb 无 `var/jb` 安装前缀布局  
  - Architecture = `iphoneos-arm64e`  
  - 主二进制 roothide 链接预期  
  - App `CFBundleShortVersionString` == `VERSION`  
  - postinst 含权限修复 / `DATA_DIR_LOGICAL`

### 7.4 GitHub Actions

- 继续一次四产物；roothide 改为原生构建产物。  
- CI 需 xcodebuild、ldid、dpkg-deb、roothide 头文件/库（文档写安装；可 cache）。  
- 保留 `out/…_roothide_arm64e.deb` 存在性检查，并加 control arch + 布局断言。

### 7.5 发布矩阵

| 产物 | 构建入口 | 包布局 | Architecture |
|---|---|---|---|
| TrollStore `.tipa` | rootless app + TS entitlements | Payload | — |
| rootful `.deb` | ChargeLimiter | `/Applications`… | `iphoneos-arm` |
| rootless `.deb` | ChargeLimiter rootless | `/var/jb/...` | `iphoneos-arm64` |
| roothide `.deb` | **ChargeLimiter roothide** | rootful 形 | `iphoneos-arm64e` |

## 8. 文档

| 文档 | 动作 |
|---|---|
| `构建安装包.md` | 删除「roothide 由 rootless 转换」为默认的叙述；写原生 scheme、依赖、命令、legacy 开关 |
| `README.md` 构建/安装段 | 同步四产物与 roothide 要求 |
| **新建** `docs/roothide-packaging.md` | 维护者手册：官方外链、本仓 scheme、entitlements、数据路径、`jbroot`、postinst、与 rootless 差异、本地/CI 验收 |
| 本 spec | 已写入 `docs/superpowers/specs/2026-08-06-roothide-native-unified-settings-design.md` |

文档必须写明：数据权威路径、App/daemon 双写 + 权限双闸、版本只改 `MARKETING_VERSION`、原生 roothide ≠ 转换包。

## 9. 测试与验收

### 9.1 自动化

- 改写 `scripts/tests`：四键权威为共享 store；postinst 权限；**roothide 包为原生布局**（非 conversion 残留）。  
- 删除或改写「appdata suite 为持久化主路径」的契约断言。  
- 构建脚本自检：version 一致、arch、路径前缀、entitlements。

### 9.2 真机

| 环境 | 检查 |
|---|---|
| rootless | 设置页版本 = MARKETING_VERSION；改配置可保存；重启保持 |
| roothide | 卸载旧版再装；改语言/外观/震动/预设 **不**误报失败；杀进程保持；daemon `lang` 仍可用；共享目录权限为 mobile 可写 |
| rootful / TrollStore | 无回归：版本显示、设置保存 |

### 9.3 成功标准（汇总）

- 设置页版本与 control / 文件名一致。  
- 改 App 专属设置：无假阳性「保存失败」；杀进程仍在。  
- 共享配置在 rootless / roothide 可写。  
- `out/` roothide deb 为原生构建；日志/文档不再把 conversion 当默认正式线。  
- 维护者文档可按步骤复现构建与路径约定。

## 10. 建议实现顺序

1. **版本单源**（小，立刻修 rootless 显示 1.13.9）  
2. **存储统一 + 迁移 + 写盘/弹窗 + 权限自愈**  
3. **Package_roothide + scheme + build_packages + GHA**  
4. **文档与测试改写**  
5. **真机回归**  

1 与 2 可部分并行；3 依赖本机/CI 的 roothide 工具链。

## 11. 风险与回滚

| 风险 | 缓解 |
|---|---|
| postinst 未跑或权限漏修 → App 直写失败 | daemon 启动 re-chown；写失败弹窗文案保留；安装文档强调完整安装 |
| 原生 roothide 链接/entitlements 不齐 | 对照官方 entitlements + 真机装包；legacy convert 仅紧急 |
| 迁移漏键 | 读路径候选覆盖 appdata / standard / 历史路径；缺键用默认，不误报 |
| CI 缺 libroothide | 文档 + workflow 预装/缓存；失败快失败 |

回滚：git 回退；若已发转换包用户，原生包应可覆盖安装（同 Package id `com.chargelimiter.mod`）；数据根保持 `/var/mobile/ChargeLimiter/` 以兼容 1.13.9/1.14 已落盘数据。

## 12. 与 2026-08-04 设计的关系

| 2026-08-04 | 本设计 |
|---|---|
| 第 1 步 postinst 修共享目录权限 | **保留并扩展**到原生 `Package_roothide` |
| 第 2 步写失败 UI | **保留触发器**，收紧为仅共享写盘真失败 |
| 第 3 步 CLAppSettingsStore 为权威 | **撤销权威地位**；仅作迁移源后废弃主路径 |
| roothide 由 rootless 转换 | **改为原生 scheme/模板/CI** |

---

**批准记录**：brainstorming 会话中用户确认方案 1 及第 1–3 段设计（2026-08-06）。
