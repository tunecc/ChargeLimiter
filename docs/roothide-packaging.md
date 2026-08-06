# ChargeLimiter 原生 Roothide 打包说明

面向维护者：本仓 **roothide 正式发布线是原生 Xcode scheme + `Package_roothide`**，默认 **不再** 从 rootless 包树转换。

## 1. 官方外链

| 文档 | 用途 |
|---|---|
| [roothide/Developer](https://github.com/roothide/Developer) | 总览：`THEOS_PACKAGE_SCHEME=roothide`、`jbroot()`、Xcode devkit |
| [roothide.md](https://github.com/roothide/Developer/blob/main/roothide.md) | 与 rootless 差异：包布局同 rootful、无固定 `/var/jb`；`@loader_path/.jbroot/` |
| [entitlements.md](https://github.com/roothide/Developer/blob/main/entitlements.md) | 越狱数据放 jbroot `/var/`；Mach-O 不可放 jbroot `/var/` 或 `/tmp/` |
| [interface.md](https://github.com/roothide/Developer/blob/main/interface.md) | `jbroot` / `rootfs` / `jbrand` API |
| [libroothide releases（Xcode devkit）](https://github.com/roothide/libroothide/releases) | 非 Theos 主线时给 Xcode 用的 roothide SDK |
| [The Apple Wiki · Roothide](https://theapplewiki.com/wiki/Roothide) | deb `Architecture: iphoneos-arm64e`（dpkg 标签，不等于 CPU 必须 arm64e） |

安装 theos 推荐 fork：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
```

## 2. 本仓 roothide 方案一览

| 项 | 值 |
|---|---|
| Xcode scheme | `ChargeLimiter roothide` |
| App / Daemon targets | `ChargeLimiter_roothide` / `ChargeLimiterDaemon_roothide` |
| 包模板 | `ChargeLimiter/Package_roothide/` |
| 构建宏 | `THEOS_PACKAGE_SCHEME=roothide`，`THEOS_PACKAGE_SCHEME_ROOTHIDE=1` |
| 产物 | `out/ChargeLimiter_<VERSION>_roothide_arm64e.deb` |
| dpkg Architecture | `iphoneos-arm64e` |
| 包布局 | rootful 形：`Applications/`、`Library/LaunchDaemons/`、`DEBIAN/`（**无** `/var/jb`） |
| 额外 entitlements | 打包时合并 `scripts/roothide.entitlements` |
| 逻辑数据根 | `/var/mobile/ChargeLimiter/` |
| 共享配置 | `/var/mobile/ChargeLimiter/com.chargelimiter.mod.plist` |
| roothide 运行时路径 | `jbroot("/var/mobile/ChargeLimiter/…")`（代码侧）；maintainer 脚本已在 jbroot 命名空间，逻辑路径直接写 `/var/mobile/ChargeLimiter` |
| 权限目标 | 目录 `mobile:mobile` `0750`；plist `mobile:mobile` `0640` |

版本唯一人工源：`ChargeLimiter.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION`。  
`CFBundleShortVersionString`、`DEBIAN/control` Version、输出文件名均应与之对齐。

## 3. 与 rootless 差异

| | rootless | roothide（本仓原生） |
|---|---|---|
| scheme | `ChargeLimiter rootless` | `ChargeLimiter roothide` |
| 包模板 | `Package_rootless` | `Package_roothide` |
| 安装前缀 | `/var/jb/...` | 无固定前缀；dpkg 装入随机 jbroot |
| App 路径（包内） | `var/jb/Applications/ChargeLimiter.app` | `Applications/ChargeLimiter.app` |
| Architecture | `iphoneos-arm64` | `iphoneos-arm64e` |
| 链接 / rpath | libroot + rootless 前缀 | libroothide / roothide libroot；`@loader_path/.jbroot/` |
| 数据逻辑路径 | `/var/mobile/ChargeLimiter/`（经 libroot） | 同逻辑路径 + `jbroot(...)` |
| 系统根 | 通常直接访问 | 需要系统根时用 `/rootfs/...` |
| 默认构建 | `build_packages.sh` 始终构建 | **默认原生构建**；`--legacy-roothide-convert` 才从 rootless 转换 |

## 4. 本地构建

### 4.1 依赖

- Xcode + CLT、`xcodebuild`、`dpkg-deb`、`ldid`、`zip`、`plutil`
- Theos headers（工程仍用 `/opt/theos/vendor/include` 等）
- **roothide 链接库（原生默认路径必需）**
  - `LIBRARY_SEARCH_PATHS` → `/opt/theos/vendor/lib/iphone/roothide`（`-lroot`）
  - `HEADER_SEARCH_PATHS` → `/opt/theos/vendor/include/roothide`
  - 可选：`/opt/theos_roothide`（`MonkeyDevTheosPath`；默认不跑 MonkeyDev 打包 phase）

缺少 libroot 时，原生 scheme 会在链接阶段失败（`ld: library 'root' not found`）。

### 4.2 命令

仓库根目录：

```bash
# 默认：TrollStore + rootful + rootless + **原生** roothide
./scripts/build_packages.sh

# 指定版本（一般不需要；默认读 MARKETING_VERSION）
./scripts/build_packages.sh 1.14.0

# 跳过 roothide（只出 tipa / rootful / rootless）
./scripts/build_packages.sh --skip-roothide

# 紧急回滚：从 rootless 暂存树转换 roothide（非默认、非正式线）
./scripts/build_packages.sh --legacy-roothide-convert
```

环境变量（与 flags 等价，供 CI/调试）：

| 变量 | 默认 | 含义 |
|---|---|---|
| `CHARGELIMITER_BUILD_NATIVE_ROOTHIDE` | `1` | 原生 scheme 路径 |
| `CHARGELIMITER_BUILD_LEGACY_ROOTHIDE` | `0` | rootless→roothide 转换 |
| `CHARGELIMITER_BUILD_ROOTHIDE` | （未设=开） | `0` 时禁用全部 roothide 打包 |

单独编译 roothide app：

```bash
xcodebuild \
  -project ChargeLimiter.xcodeproj \
  -scheme "ChargeLimiter roothide" \
  -destination "generic/platform=iOS" \
  -configuration Release \
  -derivedDataPath build_roothide \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  THEOS_PACKAGE_SCHEME=roothide
```

### 4.3 原生流程（脚本内部）

1. `xcodebuild` scheme `ChargeLimiter roothide` → `build_roothide`
2. strip；`sign_roothide_app`（jb entitlements + 合并 `scripts/roothide.entitlements`）
3. 复制 `ChargeLimiter/Package_roothide` 到暂存树，填入 `Applications/ChargeLimiter.app`
4. 写入 `Version` 与 `Architecture: iphoneos-arm64e`
5. `dpkg-deb` → `out/ChargeLimiter_<VERSION>_roothide_arm64e.deb`
6. **不**调用 `convert_rootless_stage_to_roothide`（除非 `--legacy-roothide-convert`）

## 5. CI 依赖（GitHub Actions）

Workflow：`.github/workflows/release.yml`（`macos-15`）。

| 步骤 | 内容 |
|---|---|
| 打包工具 | `brew install dpkg ldid ripgrep` |
| Theos | clone `theos/theos` → `/opt/theos`，`/opt/include` 软链 |
| roothide 工具链 | best-effort：clone `roothide/theos` → `/opt/theos_roothide` 并拷贝 vendor；失败则试 [libroothide devkit](https://github.com/roothide/libroothide/releases) |
| 硬失败条件 | `/opt/theos/vendor/lib/iphone/roothide/libroot*` 仍不存在 → 明确报错退出（发布线需要原生链接） |
| 构建 | `./scripts/build_packages.sh`（默认含原生 roothide） |
| 产物抽查 | 解包 roothide deb：`Architecture: iphoneos-arm64e`、存在 `Applications/ChargeLimiter.app`、**无** `var/jb`、`CFBundleShortVersionString` == tag 版本、control `Version` 一致 |

本地若只要三件套、不装 roothide 库：

```bash
./scripts/build_packages.sh --skip-roothide
```

**不要**把 `--skip-roothide` 或 legacy convert 当作正式 release 默认。

## 6. 包模板与 postinst 要点

`ChargeLimiter/Package_roothide/`：

- `DEBIAN/control`：`Architecture: iphoneos-arm64e`，`Package: com.chargelimiter.mod`
- `DEBIAN/postinst`：在 `launchctl bootstrap` **之前** `repair_shared_data_permissions`
  - `DATA_DIR="/var/mobile/ChargeLimiter"`（jbroot 语义，**不要**写成 `/rootfs/var/mobile/...`）
  - `chown mobile:mobile` + `chmod 0750/0640`
- `Library/LaunchDaemons/com.chargelimiter.mod.plist`：Program 为 `/Applications/ChargeLimiter.app/ChargeLimiterDaemon`

## 7. 真机验收清单（spec §9.2）

| 环境 | 检查 |
|---|---|
| rootless | 设置页版本 = `MARKETING_VERSION`；改配置可保存；重启/杀进程保持 |
| roothide | **卸载旧版再装**；改语言 / 外观 / 震动 / 停充预设 **不**误报「保存失败」；杀进程保持；daemon `lang` 仍可用；共享目录对 mobile 可写 |
| rootful / TrollStore | 无回归：版本显示、设置保存 |

补充建议：

1. 安装后看 `out` 文件名、设置页、`dpkg` Status 三方版本一致。  
2. 故意把共享 plist 变成 `root:wheel` 后改一项设置：应自愈或仅一次**真实**写失败提示（不是 `synchronize` 假阳性）。  
3. roothide 包用 Sileo/dpkg 安装后，确认 App 在主屏幕、daemon 存活、策略诊断可读。

## 8. 常见问题

- **`ld: library 'root' not found`**  
  未安装 roothide libroot。按第 4.1 / 第 5 节补齐，或临时 `--skip-roothide` / `--legacy-roothide-convert`。

- **构建日志仍写 compatibility conversion**  
  只有显式 `--legacy-roothide-convert` 时才应出现。默认应打印 native scheme + `Package_roothide`。

- **deb 里出现 `/var/jb`**  
  不是原生 roothide 布局；检查是否误走了 legacy 路径或打错模板。

- **「保存失败」在 roothide 卸载重装后反复出现**  
  查共享 plist 权限与 postinst 是否执行；权威源是共享 plist，不是 `com.chargelimiter.mod.appdata` suite。

## 9. 相关文件

- `scripts/build_packages.sh`
- `scripts/roothide.entitlements`
- `ChargeLimiter/Package_roothide/`
- `ChargeLimiter.xcodeproj/xcshareddata/xcschemes/ChargeLimiter roothide.xcscheme`
- `.github/workflows/release.yml`
- [构建安装包.md](../构建安装包.md)
- 设计：`docs/superpowers/specs/2026-08-06-roothide-native-unified-settings-design.md`
