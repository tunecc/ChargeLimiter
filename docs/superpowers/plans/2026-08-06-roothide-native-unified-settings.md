# 原生 Roothide + 统一共享配置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 App 专属设置收回共享 plist、消除「保存失败」假阳性、版本号单源，并把 roothide 发布线从 rootless 转换改为原生 Xcode/打包入口。

**Architecture:** 唯一配置权威是 `/var/mobile/ChargeLimiter/com.chargelimiter.mod.plist`（roothide 经 `jbroot`）。App/daemon 都经 `CLSettingsStore` 原子写盘；写成功后 daemon 侧 re-chown 为 `mobile:mobile`。`CLAppSettingsStore` 降为启动迁移源后退出主路径。打包新增 `ChargeLimiter roothide` scheme + `Package_roothide`，`build_packages.sh`/GHA 默认原生构建。

**Tech Stack:** Objective-C++/ObjC（Xcode）、shell 打包脚本、Python unittest（源码契约）、dpkg-deb/ldid、libroothide / THEOS_PACKAGE_SCHEME=roothide。

**Spec:** `docs/superpowers/specs/2026-08-06-roothide-native-unified-settings-design.md`

## Global Constraints

- 逻辑数据根固定为 `/var/mobile/ChargeLimiter/`；配置文件 `com.chargelimiter.mod.plist`。
- App 专属四键：`AppLanguage` / `AppAppearance` / `SliderHapticStyle` / `StopChargePresetValue` 权威源 = 共享 plist，**不是** `com.chargelimiter.mod.appdata`。
- 「保存失败」只在共享 plist 原子写失败或读回不一致时触发；迁移失败与 `NSUserDefaults synchronize` **不**触发。
- 版本唯一人工源：`MARKETING_VERSION`（`ChargeLimiter.xcodeproj/project.pbxproj`）。
- roothide deb：`Architecture: iphoneos-arm64e`，包布局 rootful 形（无 `/var/jb` 前缀），默认 **不**走 rootless 转换。
- 本环境可能无完整 xcodebuild/真机；能跑的验收优先 `python3 -m unittest discover -s scripts/tests`；编译/装包步骤在有工具链的机器执行并记录结果。
- `/docs` 在 `.gitignore` 中：提交 docs 下文件需 `git add -f`。
- 不改充电控制 / iOS17 探针；不迁纯 Theos 主发布线。

## File map（将创建 / 修改）

| 文件 | 职责 |
|---|---|
| `ChargeLimiter/Info.plist` | `CFBundleShortVersionString` → `$(MARKETING_VERSION)` |
| `ChargeLimiter/UIKit/CLAPIClient.m` | 去掉硬编码旧 `ver`，改读 bundle 版本 |
| `ChargeLimiter/utils.mm` / `utils.h` | `apply` 返回 BOOL；写后权限修复；共享迁移入口；可选废弃 suite 主路径 |
| `ChargeLimiter/CLLocalization.m` | 语言读写改走 `getlocalKV`/`setlocalKV` |
| `ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m` | `CLLocalInteger*` 改走共享 KV |
| `ChargeLimiter/ui.mm` | 启动迁移改调共享迁移；外观读共享 |
| `ChargeLimiter/UIKit/CLAppSettingsStore.{h,m}` | 降为 migrate-only 或删除主 API 调用点（保留文件仅当迁移需要读旧 suite） |
| `ChargeLimiter/Package_roothide/**` | 原生 roothide 包模板 |
| `ChargeLimiter.xcodeproj/**` + `*.xcscheme` | roothide App/Daemon targets + scheme |
| `scripts/build_packages.sh` | 原生 roothide 构建主路径；legacy convert 默认关 |
| `.github/workflows/release.yml` | roothide 工具链 + 内容校验 |
| `构建安装包.md` / `README.md` / `docs/roothide-packaging.md` | 文档 |
| `scripts/tests/test_*.py` | 契约测试改写/新增 |

---

### Task 1: 版本号单源

**Files:**
- Modify: `ChargeLimiter/Info.plist`
- Modify: `ChargeLimiter/UIKit/CLAPIClient.m`（约 290 行硬编码 `@"ver": @"1.13.6"`）
- Create: `scripts/tests/test_version_single_source.py`
- Test: 同上

**Interfaces:**
- Consumes: pbxproj `MARKETING_VERSION`
- Produces: App bundle `CFBundleShortVersionString` 与 MARKETING_VERSION 一致；API 客户端 `ver` 运行时来自 bundle

- [ ] **Step 1: 写失败契约测试**

创建 `scripts/tests/test_version_single_source.py`：

```python
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
INFO = REPO / "ChargeLimiter" / "Info.plist"
PBX = REPO / "ChargeLimiter.xcodeproj" / "project.pbxproj"
API = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"


class VersionSingleSourceTests(unittest.TestCase):
    def test_info_plist_uses_marketing_version_var(self):
        text = INFO.read_text(encoding="utf-8")
        self.assertIn("<key>CFBundleShortVersionString</key>", text)
        # 必须是 Xcode 变量，不能再写死 1.x.y
        self.assertRegex(
            text,
            r"<key>CFBundleShortVersionString</key>\s*<string>\$\(MARKETING_VERSION\)</string>",
        )
        self.assertNotRegex(
            text,
            r"<key>CFBundleShortVersionString</key>\s*<string>\d+\.\d+",
        )

    def test_pbxproj_has_marketing_version(self):
        text = PBX.read_text(encoding="utf-8")
        self.assertRegex(text, r"MARKETING_VERSION = \d+\.\d+")

    def test_apiclient_does_not_hardcode_old_ver(self):
        text = API.read_text(encoding="utf-8")
        self.assertNotRegex(text, r'@"ver"\s*:\s*@"1\.\d+')
        self.assertTrue(
            "CFBundleShortVersionString" in text or "MARKETING_VERSION" in text or "shortVersion" in text.lower()
            or re.search(r'objectForInfoDictionaryKey:@\"CFBundleShortVersionString\"', text),
            "CLAPIClient should read version from bundle (or equivalent), not hardcode",
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m unittest scripts.tests.test_version_single_source -v
```

Expected: `test_info_plist_uses_marketing_version_var` FAIL；`test_apiclient_does_not_hardcode_old_ver` FAIL。

- [ ] **Step 3: 改 Info.plist**

把：

```xml
<key>CFBundleShortVersionString</key>
<string>1.13.9</string>
```

改为：

```xml
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
```

- [ ] **Step 4: 改 CLAPIClient 硬编码 ver**

在 `CLAPIClient.m` 构造请求字典处，将 `@"ver": @"1.13.6"` 改为运行时读取，例如：

```objc
NSString *appVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
// ...
@"ver": appVer,
```

（若该字典在类方法/静态上下文，用同样的 `mainBundle` 读取；不要再写死版本号。`sysver` 若也是演示硬编码，本任务可只改 `ver`，除非同一字面量块明显是假数据且影响协议——保持最小改动。）

- [ ] **Step 5: 跑测试确认通过**

```bash
python3 -m unittest scripts.tests.test_version_single_source -v
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add ChargeLimiter/Info.plist ChargeLimiter/UIKit/CLAPIClient.m scripts/tests/test_version_single_source.py
git commit -m "fix(version): CFBundleShortVersionString 跟随 MARKETING_VERSION"
```

---

### Task 2: 共享 store 写成功返回值 + 写后权限修复

**Files:**
- Modify: `ChargeLimiter/utils.mm`（`CLSettingsStore` 的 `-apply`、`writeMergedConfigDictionaryToDisk` 成功路径、`setlocalKV`）
- Modify: `ChargeLimiter/utils.h`（若导出 `setlocalKV` 返回类型变化，同步声明；可新增 `BOOL setlocalKVReturningError(...)` 以免大面积改调用点）
- Create: `scripts/tests/test_shared_store_apply_contract.py`
- Test: 同上

**Interfaces:**
- Consumes: 现有 `writeMergedConfigDictionaryToDisk`、`getConfigWritePathWithLibroot`、`CLConfigWriteFailedNotification`
- Produces:
  - `- (BOOL)apply`（失败仍 post `CLConfigWriteFailedNotification`，返回 NO）
  - `BOOL setlocalKVWithError(NSString *key, id val, NSError **error)` 或让 `setlocalKV` 在失败时依赖通知且新增可查询 API
  - 写盘成功后 `repairSharedConfigFileOwnership(NSString *path)`：若 `geteuid()==0`，则 `chown(mobile)` + `chmod 0640`，目录 `0750`

**推荐最小 API（避免改遍所有 setlocalKV 调用点）：**

```objc
// utils.h
BOOL setlocalKVChecked(NSString *key, id val); // YES=写盘成功
// setlocalKV 保持 void，内部仍 apply；Checked 版本返回 apply 结果
```

- [ ] **Step 1: 写契约测试**

```python
# scripts/tests/test_shared_store_apply_contract.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
UTILS = REPO / "ChargeLimiter" / "utils.mm"
UTILS_H = REPO / "ChargeLimiter" / "utils.h"


class SharedStoreApplyContractTests(unittest.TestCase):
    def test_apply_returns_bool(self):
        s = UTILS.read_text(encoding="utf-8")
        self.assertRegex(s, r"- \(BOOL\)apply\b")

    def test_setlocalkv_checked_declared(self):
        h = UTILS_H.read_text(encoding="utf-8")
        self.assertIn("setlocalKVChecked", h)

    def test_write_success_repairs_ownership_hooks(self):
        s = UTILS.read_text(encoding="utf-8")
        # 写成功路径必须尝试把配置文件交回 mobile
        self.assertTrue(
            "repairSharedConfigFileOwnership" in s
            or ("chown" in s and "mobile" in s and "0640" in s),
            "successful shared config write must repair mobile ownership",
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m unittest scripts.tests.test_shared_store_apply_contract -v
```

Expected: FAIL（当前 `- (void)apply`）

- [ ] **Step 3: 实现**

在 `utils.mm`：

1. 把 `CLSettingsStore` 的 `- (void)apply` 改为 `- (BOOL)apply`：失败路径 `return NO`；成功路径在清 dirty 前/后调用权限修复后 `return YES`。
2. 新增：

```objc
static void repairSharedConfigFileOwnership(NSString *confPath) {
    if (confPath.length == 0 || geteuid() != 0) {
        return;
    }
    NSString *dir = [confPath stringByDeletingLastPathComponent];
    // chown mobile:mobile dir 0750; file 0640
    // 用 chown/chmod C API 或 NSFileManager；忽略单点失败只打日志
}
```

在 `writeMergedConfigDictionaryToDisk` 返回 YES 之后 **或** `apply` 成功分支调用（推荐 `apply` 成功分支 + daemon 其它直写成功点，至少覆盖 `apply`）。

3. `utils.h` 声明 `BOOL setlocalKVChecked(NSString *key, id val);`  
   实现：`setValue` + `return [store apply];`

4. 所有内部编译错误：其它调用 `[store apply]` 的地方按需忽略返回值或处理。

- [ ] **Step 4: 跑测试确认通过**

```bash
python3 -m unittest scripts.tests.test_shared_store_apply_contract -v
```

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/utils.mm ChargeLimiter/utils.h scripts/tests/test_shared_store_apply_contract.py
git commit -m "fix(settings): 共享 store apply 返回值与 root 写后交还 mobile 权限"
```

---

### Task 3: App 四键与语言改回共享 plist

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m`（`CLLocalIntegerForKey` / `CLSetLocalIntegerForKey`，约 4308+）
- Modify: `ChargeLimiter/CLLocalization.m`（`CLGetAppLanguage` / `CLSetAppLanguage`）
- Modify: `ChargeLimiter/ui.mm`（`AppAppearance` 读取）
- Modify: `scripts/tests/test_key_readpoint_rewiring.py`
- Modify: `scripts/tests/test_localization_extracted.py`（若断言 suite）
- Test: 上述测试

**Interfaces:**
- Consumes: `getlocalKV` / `setlocalKVChecked` / `CLConfigWriteFailedNotification`
- Produces: 四键与语言只经共享 store；写失败仍靠 `apply` 发通知（`CLSetLocalIntegerForKey` 可不再自己 post，或仅在 `setlocalKVChecked==NO` 时依赖已有通知避免重复——`apply` 已 post，**不要双重弹窗**）

- [ ] **Step 1: 改写失败测试（先改测试为新契约）**

`test_key_readpoint_rewiring.py` 改为：

```python
class KeyReadPointRewiringTests(unittest.TestCase):
    def test_clsettings_uses_shared_kv(self):
        s = SVC_M.read_text(encoding="utf-8")
        self.assertIn("getlocalKV", s)
        self.assertTrue("setlocalKVChecked" in s or "setlocalKV(" in s)
        self.assertNotIn("[[CLAppSettingsStore shared] integerForKey", s)
        self.assertNotIn("[[CLAppSettingsStore shared] setIntegerForKey", s)

    def test_languagetapped_checks_return_value(self):
        s = SVC_M.read_text(encoding="utf-8")
        self.assertIn("if (!CLSetAppLanguage", s)  # 或 if (CLSetAppLanguage ... 取反；与实现一致
        # 更稳：断言 CLSetAppLanguage 调用与错误处理同时存在
        self.assertIn("CLSetAppLanguage", s)
        self.assertIn("CLConfigWriteFailedNotification", s)

    def test_appearance_uses_shared_kv(self):
        s = UI_MM.read_text(encoding="utf-8")
        self.assertNotIn("[[CLAppSettingsStore shared] integerForKey:@\"AppAppearance\"", s)
        self.assertTrue("AppAppearance" in s and ("getlocalKV" in s or "readIntForKey" in s or "getInt" in s))
```

（实现时按最终调用形式微调断言字符串，但 **禁止** 再断言 `CLAppSettingsStore` 为读写主路径。）

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m unittest scripts.tests.test_key_readpoint_rewiring -v
```

- [ ] **Step 3: 实现读写改线**

`CLSettingsViewController.m`：

```objc
static NSInteger CLLocalIntegerForKey(NSString *key, NSInteger defaultValue) {
    id val = getlocalKV(key);
    if ([val isKindOfClass:[NSNumber class]]) {
        return [val integerValue];
    }
    return defaultValue;
}

static void CLSetLocalIntegerForKey(NSString *key, NSInteger value) {
    // apply 失败时已 post CLConfigWriteFailedNotification — 此处不要再 post 一次
    (void)setlocalKVChecked(key, @(value));
}
```

`CLLocalization.m`：

```objc
CLAppLanguage CLGetAppLanguage(void) {
    id val = getlocalKV(@"AppLanguage");
    NSInteger n = [val isKindOfClass:[NSNumber class]] ? [val integerValue] : 0;
    // switch 同前
}

BOOL CLSetAppLanguage(CLAppLanguage language, NSError **error) {
    // 校验 range 同前
    if (!setlocalKVChecked(@"AppLanguage", @((NSInteger)language))) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLAppSettings" code:-2
                                    userInfo:@{NSLocalizedDescriptionKey: @"Shared config write failed"}];
        }
        return NO;
    }
    CLApplyLanguageFromSettings();
    [[NSNotificationCenter defaultCenter] postNotificationName:CLAppLanguageDidChangeNotification object:nil];
    return YES;
}
```

去掉对 `CLAppSettingsStore.h` 的依赖（若不再需要）。

`ui.mm` 中 `AppAppearance`：

```objc
id appearanceVal = getlocalKV(@"AppAppearance");
NSInteger appearance = [appearanceVal isKindOfClass:[NSNumber class]] ? [appearanceVal integerValue] : 0;
```

`CLSetAppleLanguages` 仍可用 `getAppUserDefaults()` 写 `AppleLanguages`（这是系统语言覆盖，不是四键权威源）；**不要**再把四键写入 suite。

- [ ] **Step 4: 跑相关测试**

```bash
python3 -m unittest scripts.tests.test_key_readpoint_rewiring scripts.tests.test_config_write_failure_feedback scripts.tests.test_localization_extracted -v
```

按失败信息修正 `test_config_write_failure_feedback.py` / `test_localization_extracted.py` 中仍要求 suite 主路径的断言（改为共享 KV / 通知仍由 `apply` 发出）。

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m ChargeLimiter/CLLocalization.m ChargeLimiter/ui.mm scripts/tests/test_key_readpoint_rewiring.py scripts/tests/test_config_write_failure_feedback.py scripts/tests/test_localization_extracted.py
git commit -m "fix(settings): App 四键与语言改回共享 plist"
```

---

### Task 4: 启动迁移 — appdata suite → 共享 plist

**Files:**
- Modify: `ChargeLimiter/utils.mm`（新增 `BOOL CLMigrateAppSettingsToSharedStoreIfNeeded(void)` 或扩展现有迁移）
- Modify: `ChargeLimiter/utils.h`（声明）
- Modify: `ChargeLimiter/ui.mm`（启动调用新迁移，不再 `[[CLAppSettingsStore shared] migrateIfNeeded:]` 作为权威）
- Modify: `ChargeLimiter/UIKit/CLAppSettingsStore.m`（可选：只保留「读旧 suite 供迁移」的辅助，或由 utils 直接 `initWithSuiteName:` 读）
- Modify: `scripts/tests/test_startup_migration.py`
- Modify: `scripts/tests/test_app_settings_store_migration.py`（改为断言「迁入共享」契约，或标记迁移源可读）
- Test: 上述

**Interfaces:**
- Consumes: `getlocalKV` / `setlocalKVChecked` / suite `com.chargelimiter.mod.appdata` / `standardUserDefaults` / 可选旧共享已有键
- Produces: `BOOL CLMigrateAppSettingsToSharedStoreIfNeeded(void)`  
  - 对四键：若共享已有合法值则跳过该键；否则从 appdata → standard → 默认 0  
  - 全部处理后若有写入则一次或逐键 `setlocalKVChecked`  
  - 成功后写共享标记键如 `CLAppSettingsMigratedToShared=1`，并 `removeObject` 旧 suite 四键（best-effort）  
  - **返回值语义**：迁移逻辑跑完返回 YES；无数据可迁也 YES；仅当「需要写入共享却写失败」返回 NO（**ui 只打日志，不弹保存失败**）

- [ ] **Step 1: 改写启动迁移测试**

```python
# test_startup_migration.py
class StartupMigrationTests(unittest.TestCase):
    def test_shared_migrate_called_at_launch(self):
        s = UI_MM.read_text(encoding="utf-8")
        self.assertIn("CLMigrateAppSettingsToSharedStoreIfNeeded", s)
        self.assertIn("CLApplyLanguageFromSettings", s)
        self.assertNotIn("[[CLAppSettingsStore shared] migrateIfNeeded", s)
```

- [ ] **Step 2: 跑测试确认失败** → 实现 `CLMigrateAppSettingsToSharedStoreIfNeeded` → 改 `ui.mm` didFinishLaunching

```objc
if (!CLMigrateAppSettingsToSharedStoreIfNeeded()) {
    NSLog2(@"[CL] shared settings migration had write failures");
}
CLApplyLanguageFromSettings();
```

- [ ] **Step 3: 更新/弱化 `test_app_settings_store_*`**

- `test_app_settings_store_interface.py`：若 `CLAppSettingsStore` 仍保留仅供迁移，可改为断言迁移函数存在于 `utils.mm`；若删除 store 文件，删除对应测试。  
- **推荐本任务**：utils 内直接读 suite，不再依赖 `CLAppSettingsStore migrateIfNeeded`；store 文件可暂时留着但无调用点，下一任务删除或掏空。

- [ ] **Step 4: 全量 scripts 测试**

```bash
python3 -m unittest discover -s scripts/tests -v
```

修到全绿（本任务范围内与迁移/读写相关的）。

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/utils.mm ChargeLimiter/utils.h ChargeLimiter/ui.mm scripts/tests/test_startup_migration.py scripts/tests/test_app_settings_store_migration.py scripts/tests/test_app_settings_store_interface.py
git commit -m "fix(settings): 启动时把 appdata suite 迁入共享 plist"
```

---

### Task 5: 移除 CLAppSettingsStore 主路径（清理）

**Files:**
- Delete or gut: `ChargeLimiter/UIKit/CLAppSettingsStore.m` / `.h`
- Modify: `ChargeLimiter.xcodeproj/project.pbxproj`（从 App targets Sources 移除编译条目）
- Modify: `ChargeLimiter/UIKit/CLTestApp.m`（去掉 `CLRunAppSettingsStoreSelfTest` 若存在）
- Modify: `ChargeLimiter/utils.mm`（删除 `CLRunAppSettingsStoreSelfTest`）
- Delete or rewrite: `scripts/tests/test_app_settings_store_interface.py`、`test_app_settings_store_migration.py`
- Test: `python3 -m unittest discover -s scripts/tests`

**Interfaces:**
- Produces: 工程内无 `CLAppSettingsStore` 符号引用（除 CHANGELOG 历史叙述）

- [ ] **Step 1: rg 确认无残留引用**

```bash
rg -n "CLAppSettingsStore" --glob '!CHANGELOG.md' --glob '!docs/**' --glob '!*.md'
```

Expected: 清理后仅无或仅测试否定断言。

- [ ] **Step 2: 从 pbxproj 移除 PBXBuildFile / FileReference / Sources 条目**（rootful + rootless App；若已加 roothide 则一并）

- [ ] **Step 3: 删除源文件与过时测试，或把测试改成 `test_clappsettingsstore_absent`**

```python
def test_store_files_removed(self):
    self.assertFalse((REPO / "ChargeLimiter/UIKit/CLAppSettingsStore.m").exists())
```

- [ ] **Step 4: unittest discover 全绿 → Commit**

```bash
git add -A ChargeLimiter scripts/tests ChargeLimiter.xcodeproj/project.pbxproj
git commit -m "refactor(settings): 移除 CLAppSettingsStore 独立权威源"
```

---

### Task 6: 原生 `Package_roothide` 模板

**Files:**
- Create: `ChargeLimiter/Package_roothide/DEBIAN/control`
- Create: `ChargeLimiter/Package_roothide/DEBIAN/postinst`（及 `prerm`/`postrm`，从 rootful 适配）
- Create: `ChargeLimiter/Package_roothide/Library/LaunchDaemons/com.chargelimiter.mod.plist`（与 rootful 同路径形）
- Create: `scripts/tests/test_package_roothide_template.py`
- Test: 同上

**Interfaces:**
- Produces: 可被 `build_packages.sh` stage 的 roothide 包树（Applications 在构建时填入）

- [ ] **Step 1: 写模板契约测试**

```python
ROOTHIDE_CTRL = REPO / "ChargeLimiter/Package_roothide/DEBIAN/control"
ROOTHIDE_POST = REPO / "ChargeLimiter/Package_roothide/DEBIAN/postinst"
ROOTHIDE_PLIST = REPO / "ChargeLimiter/Package_roothide/Library/LaunchDaemons/com.chargelimiter.mod.plist"

class PackageRoothideTemplateTests(unittest.TestCase):
    def test_control_arch(self):
        c = ROOTHIDE_CTRL.read_text(encoding="utf-8")
        self.assertIn("Architecture: iphoneos-arm64e", c)
        self.assertIn("Package: com.chargelimiter.mod", c)

    def test_postinst_permissions_and_paths(self):
        s = ROOTHIDE_POST.read_text(encoding="utf-8")
        self.assertIn('APP_DIR="/Applications/ChargeLimiter.app"', s)
        self.assertIn('DAEMON_PLIST="/Library/LaunchDaemons/com.chargelimiter.mod.plist"', s)
        self.assertIn("repair_shared_data_permissions", s)
        self.assertIn("/var/mobile/ChargeLimiter", s)
        self.assertNotIn("/var/jb/", s)

    def test_launchdaemon_rootful_shape(self):
        raw = ROOTHIDE_PLIST.read_bytes()
        self.assertIn(b"/Applications/ChargeLimiter.app/ChargeLimiterDaemon", raw)
        self.assertNotIn(b"/var/jb/", raw)
```

- [ ] **Step 2: 跑测试 FAIL → 创建文件**

`control` 示例：

```
Package: com.chargelimiter.mod
Name: Modified ChargeLimiter
Version: 1.14.0
Description: 优化了一下界面
Section: Applications
Depends: firmware (>= 13.0)
Priority: optional
Architecture: iphoneos-arm64e
Author: tune
Maintainer: tune
```

`postinst`：以 `Package/DEBIAN/postinst` 为底（rootful 路径），加入与 rootless 相同的 `jbroot` 解析可选增强——**原生 roothide 安装时脚本已在 jbroot 命名空间**，官方语义下 `/Applications` 与 `/var/mobile/ChargeLimiter` 按 jbroot 路径书写即可；`repair_shared_data_permissions` 对 `DATA_DIR="/var/mobile/ChargeLimiter"` 做 chown/chmod。若需兼容「有时需 rootfs」，仅在 touch 系统路径时用 `/rootfs`，**不要**把 DATA_DIR 写成 `/rootfs/var/mobile/ChargeLimiter`。

LaunchDaemon plist：复制 rootful 版。

`prerm`/`postrm`：从 rootful 复制并去掉 `/var/jb`。

- [ ] **Step 3: 测试 PASS → Commit**

```bash
git add ChargeLimiter/Package_roothide scripts/tests/test_package_roothide_template.py
git commit -m "chore(packaging): 添加原生 Package_roothide 模板"
```

- [ ] **Step 4: 更新 `test_shared_data_permissions_postinst.py`**

- 新增对 `Package_roothide/DEBIAN/postinst` 的权限断言。  
- **转换测试** `test_roothide_conversion_preserves_jbroot_logical_data_path`：若 legacy convert 仍保留，可继续测 rootless postinst 转换；并注明不再是默认发布路径。若 convert 函数删除，删除该测试。

---

### Task 7: Xcode roothide targets + scheme

**Files:**
- Modify: `ChargeLimiter.xcodeproj/project.pbxproj`
- Create: `ChargeLimiter.xcodeproj/xcshareddata/xcschemes/ChargeLimiter roothide.xcscheme`（可复制 rootless scheme 改名与蓝图 ID）
- 可选: Daemon `ChargeLimiterDaemon_roothide` target（与 rootless 成对；若 App target 已嵌入 daemon 产物，按现有 rootless 模式复制）

**Interfaces:**
- Produces: `xcodebuild -scheme "ChargeLimiter roothide" ... THEOS_PACKAGE_SCHEME=roothide` 可配置的 target  
- Build settings 相对 rootless 的差异：
  - `THEOS_PACKAGE_SCHEME = roothide`
  - `OTHER_CFLAGS`：定义 `THEOS_PACKAGE_SCHEME_ROOTHIDE`（或 roothide/theos 要求的宏）；**不要** `THEOS_PACKAGE_INSTALL_PREFIX=/var/jb`
  - Library/Header 搜索路径指向 roothide 变体（`/opt/theos/vendor/lib/iphone/roothide` 或 devkit；若本机只有 rootless theos，文档写明需 roothide/theos 或 devkit）
  - `PRODUCT_NAME = ChargeLimiter`（与现网包内二进制名一致）
  - Entitlements：jb entitlements 文件；打包阶段再 merge `scripts/roothide.entitlements`（与现 convert 行为一致，原生构建也应 ldid merge）

- [ ] **Step 1: 以 rootless target 为模板复制**

操作指引（人工/脚本皆可）：

1. 复制 `ChargeLimiter_rootless` native target 与其 Debug/Release XCBuildConfiguration。  
2. 新 ID 必须唯一（Xcode 24 位 hex）。  
3. 改 `name` / `productReference` 为 `_roothide`。  
4. 替换 build settings 中所有 `rootless` → `roothide` 语义（路径、SCHEME、CFLAGS、MonkeyDevTheosPath 若适用）。  
5. 同样处理 `ChargeLimiterDaemon_rootless` → `_roothide`（若 App 依赖嵌入 daemon）。  
6. 复制 `ChargeLimiter rootless.xcscheme` → `ChargeLimiter roothide.xcscheme`，BlueprintIdentifier 指向新 target。  
7. `xcodebuild -list` 应显示新 scheme。

- [ ] **Step 2: 有工具链时编译冒烟**

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter roothide" \
  -destination "generic/platform=iOS" -configuration Release \
  -derivedDataPath build_roothide CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
  MonkeyDevInstallOnAnyBuild=NO MonkeyDevBuildPackageOnAnyBuild=NO
```

Expected: BUILD SUCCEEDED（若缺 libroothide，先按 Task 9 文档安装；本任务可先完成 pbx 结构，编译阻塞记在 PR 说明）。

- [ ] **Step 3: Commit**

```bash
git add ChargeLimiter.xcodeproj
git commit -m "chore(xcode): 添加 ChargeLimiter roothide scheme/target"
```

---

### Task 8: `build_packages.sh` 原生 roothide 主路径

**Files:**
- Modify: `scripts/build_packages.sh`
- Modify: `scripts/tests/test_shared_data_permissions_postinst.py`（及新增 `test_build_packages_roothide_native.py`）
- Test: 源码级断言 + 有环境时完整 `./scripts/build_packages.sh`

**Interfaces:**
- Produces:
  - 默认 `BUILD_NATIVE_ROOTHIDE=1`，构建 `ChargeLimiter roothide` → stage `Package_roothide` → `out/ChargeLimiter_${VERSION}_roothide_arm64e.deb`
  - `--legacy-roothide-convert` 才启用旧转换；**默认不转换**
  - usage 文案更新

- [ ] **Step 1: 写脚本契约测试**

```python
# scripts/tests/test_build_packages_roothide_native.py
class BuildPackagesRoothideNativeTests(unittest.TestCase):
    def test_default_not_legacy_convert(self):
        s = (REPO / "scripts/build_packages.sh").read_text(encoding="utf-8")
        self.assertIn("ChargeLimiter roothide", s)
        self.assertIn("Package_roothide", s)
        # 默认不应再警告「will be built by converting」为唯一路径
        self.assertIn("--legacy-roothide-convert", s)

    def test_stages_native_roothide_scheme(self):
        s = (REPO / "scripts/build_packages.sh").read_text(encoding="utf-8")
        self.assertRegex(s, r'-scheme\s+"ChargeLimiter roothide"|-scheme "ChargeLimiter roothide"')
```

- [ ] **Step 2: 实现脚本改动（要点）**

1. 增加 `BUILD_ROOTHIDE` derivedData、`PKG_ROOTHIDE_DIR=.../Package_roothide`、`STAGE_ROOTHIDE_DIR`。  
2. 在 rootless build 之后增加 roothide `xcodebuild`（除非 `--skip-roothide`）。  
3. stage：`cp Package_roothide` → 填入 roothide `.app` → `set_control_version` → **直接** `set_roothide_control_arch`（模板已是 arm64e 也可再保证）→ strip/sign，对可执行文件 `ldid -M -Sscripts/roothide.entitlements`。  
4. 默认 **不调用** `convert_rootless_stage_to_roothide`。  
5. `--legacy-roothide-convert`：保留旧函数作 fallback。  
6. 校验：deb 内无 `var/jb` 前缀的 Applications；`Architecture` 正确；可选 `plutil`/`otool` 抽查。  
7. 更新文件头 usage 注释。

- [ ] **Step 3: 单元测试 PASS；有环境则跑完整打包**

```bash
python3 -m unittest scripts.tests.test_build_packages_roothide_native -v
./scripts/build_packages.sh   # 有 xcode 时
```

- [ ] **Step 4: Commit**

```bash
git add scripts/build_packages.sh scripts/tests/test_build_packages_roothide_native.py scripts/tests/test_shared_data_permissions_postinst.py
git commit -m "chore(packaging): roothide 改为原生构建默认路径"
```

---

### Task 9: GitHub Actions + 文档

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `构建安装包.md`
- Modify: `README.md`（构建/安装相关段落）
- Create: `docs/roothide-packaging.md`
- Test: 文档内命令与脚本 flags 一致（人工核对 + 可选测试断言文档含关键短语）

- [ ] **Step 1: release.yml**

在 “Prepare Theos headers” 之后或之中：

- 说明/安装 roothide 支持：优先 `roothide/theos` 或下载 [libroothide devkit](https://github.com/roothide/libroothide/releases) 到约定路径（与 pbx 搜索路径一致）。  
- “Verify expected release assets” 增加：

```bash
# 解包 roothide deb 抽查
TMP=$(mktemp -d)
dpkg-deb -R "out/ChargeLimiter_${TAG_VERSION}_roothide_arm64e.deb" "$TMP"
grep -q "Architecture: iphoneos-arm64e" "$TMP/DEBIAN/control"
test -d "$TMP/Applications/ChargeLimiter.app"
test ! -d "$TMP/var/jb"
# Info 版本
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$TMP/Applications/ChargeLimiter.app/Info.plist" | grep -qx "$TAG_VERSION"
```

（路径按 macOS runner 实际 `PlistBuddy` 位置调整。）

- [ ] **Step 2: 写 `docs/roothide-packaging.md`**

必须包含：

- 外链：Developer README / roothide.md / entitlements / Apple Wiki  
- 本仓 scheme 名、Package_roothide、数据路径、`jbroot`  
- 与 rootless 差异表  
- 本地构建：`./scripts/build_packages.sh`、`--skip-roothide`、`--legacy-roothide-convert`  
- CI 依赖  
- 真机验收清单（来自 spec §9.2）

- [ ] **Step 3: 更新 `构建安装包.md` / `README.md`**

删除「默认从 rootless 转换 roothide」为正式叙述；改为原生默认。

- [ ] **Step 4: Commit（docs 需 -f）**

```bash
git add .github/workflows/release.yml 构建安装包.md README.md
git add -f docs/roothide-packaging.md
git commit -m "docs: 原生 roothide 打包说明与 CI 校验"
```

---

### Task 10: 回归清单与收尾验证

**Files:** 无强制代码；可更新 `CHANGELOG.md` 草稿条目（若用户要求发版再改版本号）

- [ ] **Step 1: 全量契约测试**

```bash
python3 -m unittest discover -s scripts/tests -v
```

Expected: 全 PASS。

- [ ] **Step 2: 有工具链时完整产物**

```bash
./scripts/build_packages.sh
ls -l out/ChargeLimiter_*
```

抽查 roothide deb 布局与 Version。

- [ ] **Step 3: 真机清单（交给用户/有设备的执行者）**

| # | 环境 | 步骤 | 期望 |
|---|---|---|---|
| 1 | rootless | 安装新 deb，看设置页版本 | = MARKETING_VERSION |
| 2 | rootless | 改语言/外观/震动/预设，杀进程 | 保持；无误报失败 |
| 3 | roothide | 卸载旧版再装 | 不持续弹保存失败 |
| 4 | roothide | 改四键 + 重启 | 保持 |
| 5 | roothide | 看 daemon 通知语言 | `lang` 仍同步 |
| 6 | 任意 | 故意 chmod root 锁文件后改设置 | 可自愈或一次真实失败提示 |

- [ ] **Step 4: 最终 commit（若有 CHANGELOG/残余）**

```bash
git status
# 如有遗漏测试修复再提交
git commit -m "test: 收齐原生 roothide 与共享配置契约"
```

---

## Spec coverage（self-review）

| Spec 要求 | Task |
|---|---|
| 统一共享 plist / 废除 suite 权威 | 3, 4, 5 |
| 写盘语义 / 假阳性 | 2, 3 |
| 权限双闸（postinst + 写后/启动） | 2, 6；daemon 写后在 2 |
| 版本单源 | 1, 8 校验, 9 |
| 原生 roothide scheme/模板/脚本/GHA | 6, 7, 8, 9 |
| 迁移 appdata → 共享 | 4 |
| 文档 | 9 |
| 测试与真机验收 | 各 Task 测试 + 10 |
| 不改充电探针 | 未列入任务 |

## Placeholder scan

无 TBD/TODO 实现空步；编译依赖本机 theos/roothide 处已写明阻塞记录方式。

## 类型/符号一致性

- `setlocalKVChecked` / `- (BOOL)apply` / `CLMigrateAppSettingsToSharedStoreIfNeeded` / `repairSharedConfigFileOwnership` 在 Task 2–4 定义，后续任务只消费这些名字。  
- 包名 `com.chargelimiter.mod`、数据根、四键名与 spec 一致。
