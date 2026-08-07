# 将 CLDiagnosticCollector 接入 Xcode 工程（pbxproj）

> **本机约束：** 当前任务环境不直接改 `ChargeLimiter.xcodeproj`。
> 请在能跑 `xcodebuild` 的机器上，按本文把源文件与包架构宏接到 **App** target。

## 背景

- Tasks 2–3 已新增：
  - `ChargeLimiter/UIKit/CLDiagnosticCollector.h`
  - `ChargeLimiter/UIKit/CLDiagnosticCollector.m`
- 这两个文件 **尚未** 加入任何 Xcode target 的 Compile Sources。
- `CLPackageSchemeString()` 依赖编译期宏区分包架构：
  - `CL_PACKAGE_ROOTHIDE`
  - `CL_PACKAGE_ROOTLESS`
  - 二者都不定义 → rootful

## 目标模式（对照 `CLLocalization.m`）

与 `CLLocalization.m` 相同的 **App-only target 拆分**：

| Target | 是否加入 Compile Sources |
|--------|--------------------------|
| `ChargeLimiter`（rootful App） | **是** |
| `ChargeLimiter_rootless`（若工程里存在） | **是** |
| `ChargeLimiter_roothide` | **是** |
| `ChargeLimiterDaemon` | **否** |
| `ChargeLimiterDaemon_rootless` | **否** |
| `ChargeLimiterDaemon_roothide` | **否** |

提醒：

1. **不要**把 `CLDiagnosticCollector.m` 加入任何 **Daemon** target  
   （Daemon 侧不需要 UI 诊断采集器；对照 `CLLocalization.m` 也只在三个 App Sources phase 里）。
2. Header 通常放进工程 group 即可；真正需要编译的是 `.m`。
3. 每个 App target 需要 **各自** 一条 `CLDiagnosticCollector.m in Sources` 的 `PBXBuildFile`（与 `CLLocalization.m` 三份 `in Sources` 同模式），不要只加进一个 target 就结束。

## 步骤 1：把源文件加入 3 个 App target

在 Xcode 中（或等价编辑 pbxproj）：

1. 把 `CLDiagnosticCollector.h` / `CLDiagnosticCollector.m` 加入工程（建议 group：`ChargeLimiter/UIKit`，与现有 UIKit 源并列）。
2. Target Membership / Compile Sources 勾选：
   - `ChargeLimiter`
   - `ChargeLimiter_rootless`（若存在）
   - `ChargeLimiter_roothide`
3. 确认 **未勾选** 任何 Daemon：
   - `ChargeLimiterDaemon`
   - `ChargeLimiterDaemon_rootless`
   - `ChargeLimiterDaemon_roothide`

手工 pbxproj 检查清单：

- `PBXFileReference`：`CLDiagnosticCollector.h`、`CLDiagnosticCollector.m`
- `PBXBuildFile`：每个 **App** target 一条 `CLDiagnosticCollector.m in Sources`
- 对应 App 的 `PBXSourcesBuildPhase.files` 包含上述 build file
- **Daemon** 的 Sources phase **不得** 出现 `CLDiagnosticCollector`

## 步骤 2：Preprocessor Definitions（包架构宏）

`CLDiagnosticCollector.m` 中：

```objc
#if defined(CL_PACKAGE_ROOTHIDE) && CL_PACKAGE_ROOTHIDE
    return @"roothide";
#elif defined(CL_PACKAGE_ROOTLESS) && CL_PACKAGE_ROOTLESS
    return @"rootless";
#else
    return @"rootful";
#endif
```

因此必须在 **App** target 的 Debug/Release 都设好：

| App target | 宏 | 说明 |
|------------|----|------|
| `ChargeLimiter_roothide` | `CL_PACKAGE_ROOTHIDE=1` | 诊断报告 `packageScheme=roothide` |
| `ChargeLimiter_rootless` | `CL_PACKAGE_ROOTLESS=2` | 诊断报告 `packageScheme=rootless` |
| `ChargeLimiter`（rootful） | **不定义** 上述二者 | 走 `#else` → `rootful` |

推荐写在 target 级 `GCC_PREPROCESSOR_DEFINITIONS`（保留 `$(inherited)`）：

```text
# ChargeLimiter_roothide (Debug + Release)
GCC_PREPROCESSOR_DEFINITIONS = (
  "$(inherited)",
  "CL_PACKAGE_ROOTHIDE=1",
);

# ChargeLimiter_rootless (Debug + Release)
GCC_PREPROCESSOR_DEFINITIONS = (
  "$(inherited)",
  "CL_PACKAGE_ROOTLESS=2",
);

# ChargeLimiter (rootful): 不要加 CL_PACKAGE_ROOTHIDE / CL_PACKAGE_ROOTLESS
```

也可用 `OTHER_CFLAGS` 追加 `-DCL_PACKAGE_ROOTHIDE=1` / `-DCL_PACKAGE_ROOTLESS=2`，效果等价；**不要**覆盖已有 Theos 相关 flags（例如 roothide 上的 `-DTHEOS_PACKAGE_SCHEME_ROOTHIDE=1`）。

注意：

- 宏只加在 **App** target；Daemon 不编译 collector，无需这些宏。
- rootful **不要**误加 `CL_PACKAGE_*`，否则诊断页会显示错误包架构。

## 步骤 3：编译验收（用户环境）

在仓库根目录执行：

```bash
# 编译 roothide app(用户环境)
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter roothide" \
  -destination "generic/platform=iOS" -configuration Release \
  -derivedDataPath build_roothide CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

可选（确认其它包架构也能链上 collector）：

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" \
  -destination "generic/platform=iOS" -configuration Release \
  -derivedDataPath build_rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64

xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter rootless" \
  -destination "generic/platform=iOS" -configuration Release \
  -derivedDataPath build_rootless CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

通过标准：

- `xcodebuild` 成功（无 `CLDiagnosticCollector` 未找到 / undefined symbol）
- 装到 iOS 17.0 设备 → **充电高级 → 策略诊断 → 一键复制完整诊断** → 把文本发回
- 报告中 `packageScheme` 与当前安装包一致（roothide / rootless / rootful）

## 快速自检（接入后）

```bash
# 应命中 App Sources，不应命中 Daemon Sources
rg -n "CLDiagnosticCollector" ChargeLimiter.xcodeproj/project.pbxproj

# 宏
rg -n "CL_PACKAGE_ROOTHIDE|CL_PACKAGE_ROOTLESS" ChargeLimiter.xcodeproj/project.pbxproj
```

期望：

- 至少 3 条 App 侧 `CLDiagnosticCollector.m in Sources`（若无 rootless target 则为 2）
- Daemon 的 Sources 列表无 collector
- roothide App 配置含 `CL_PACKAGE_ROOTHIDE`
- rootless App 配置含 `CL_PACKAGE_ROOTLESS`
- rootful App 配置 **不含** 上述宏

## 不要做的事

- 不要把 collector 加进任何 **Daemon** target
- 不要只改 scheme 不改 Compile Sources
- 不要在本任务机器上“顺便”手改 pbxproj 后无法用 `xcodebuild` 验证就提交
- 不要删除现有 `THEOS_PACKAGE_*` / MonkeyDev 相关 flags
