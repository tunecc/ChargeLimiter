# 策略诊断页增强:一键复制完整诊断 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在策略诊断页新增「环境与连通性」卡片与「一键复制完整诊断」主入口,让用户能复制含环境/连通性/读电量链路/策略信号的完整 Markdown 诊断文本给开发者。

**Architecture:** 三单元拆分——U1 `CLDiagnosticCollector`(App 侧纯采集+Markdown 格式化)、U2 daemon `get_diag` 只读端点(读电量 service/key/IOKit 错误)、U3 策略诊断页 UI 接入。U1 是唯一跨进程聚合点,UI 不直接调 daemon HTTP。

**Tech Stack:** Objective-C / UIKit / IOKit / `CLAPIClient` / `CLL()` 本地化 / Python unittest 源码扫描

**Spec:** `docs/superpowers/specs/2026-08-04-diagnostics-panel-design.md`

## Global Constraints

- daemon `get_diag` / `getIOPMPSServDiagnostics()` **纯只读无副作用**:禁止 `IORegistryEntrySetCFProperties`、`exit`、`kill`、改 `g_use_smart`、写文件、重启 daemon
- 复制文本不含:电池序列号、设备 UDID、完整 jbroot 路径(只截到 `.jbroot-XXX` 前缀)、用户配置类字段
- 单字段失败降级为 `(无法获取)`,不抛异常、不短路整段
- daemon 离线时环境段仍完整,连通性/读电量链路标离线,复制文本开头用 `⚠️ daemon 离线`
- 本环境无 xcodebuild:我写源码+Python 扫描测试;pbxproj 改动交用户(精确脚本/说明)
- 所有新 UI 文案走 `CLL()` + `zh-Hans.lproj`/`en.lproj`
- 测试约定:`scripts/tests/test_*.py` 源码扫描(unittest)

---

### Task 1: U2 daemon `getIOPMPSServDiagnostics()` + `get_diag` 端点

**Files:**
- Modify: `ChargeLimiter/daemon.mm` (在 `getBatInfo` 附近加 helper;在 `handleReq` 加 `get_diag` 分支)
- Test: `scripts/tests/test_get_diag_api.py`

**Interfaces:**
- Consumes: `getIOPMPSServ()`, `g_use_smart`, `g_serv_boot`, `getJBType()`, `getSysVer()`, `getDevMdoel()`, `getAppVer()`
- Produces:
  - `static NSDictionary* getIOPMPSServDiagnostics(void)` — 只读诊断字典
  - `handleReq` 分支 `api == @"get_diag"` → `@{ @"status": @0, @"data": <diag dict> }`
  - data 字段约定(U1 依赖这些 key):
    ```
    service_name: NSString  ("AppleSmartBattery" | "IOPMPowerSource" | "(未匹配)")
    published_keys: NSArray<NSString*>
    key_present: NSDictionary  { CurrentCapacity/Amperage/Voltage/IsCharging/Temperature → BOOL }
    iokit_return: NSNumber (kern_return_t, props==nil 时用 -2)
    use_smart: NSNumber BOOL
    serv_boot: NSNumber
    sysver / devmodel / ver: NSString
    jbtype: NSString  ("roothide"|"rootless"|"rootful"|"trollstore"|"unknown")
    libjailbreak_loaded: NSNumber BOOL  (dlopen("/usr/lib/libjailbreak.dylib") 成败,立即后立即 dlclose)
    ```

- [ ] **Step 1: 写失败测试(源码扫描契约)**

创建 `scripts/tests/test_get_diag_api.py`:

```python
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DAEMON = REPO / "ChargeLimiter" / "daemon.mm"


class GetDiagApiContractTests(unittest.TestCase):
    def setUp(self):
        self.src = DAEMON.read_text(encoding="utf-8")

    def test_helper_exists(self):
        self.assertRegex(
            self.src,
            r"static\s+NSDictionary\s*\*\s*getIOPMPSServDiagnostics\s*\(\s*void\s*\)",
        )

    def test_handle_req_get_diag_branch(self):
        self.assertIn('@"get_diag"', self.src)
        # 分支必须返回 status + data
        idx = self.src.find('@"get_diag"')
        body = self.src[idx : idx + 800]
        self.assertIn('"status"', body)
        self.assertIn('"data"', body)

    def test_helper_is_readonly_no_set_properties(self):
        start = self.src.find("getIOPMPSServDiagnostics")
        self.assertGreater(start, -1)
        # 取函数体到下一个 static/函数边界
        body = self.src[start : start + 2500]
        self.assertNotIn("IORegistryEntrySetCFProperties", body)
        self.assertNotIn("exit(", body)
        self.assertNotIn("kill(", body)
        # 允许读 getIOPMPSServ / IORegistryEntryCreateCFProperties
        self.assertIn("IORegistryEntryCreateCFProperties", body)

    def test_helper_reports_required_keys(self):
        start = self.src.find("getIOPMPSServDiagnostics")
        body = self.src[start : start + 2500]
        for key in [
            "service_name",
            "published_keys",
            "key_present",
            "iokit_return",
            "use_smart",
            "serv_boot",
            "libjailbreak_loaded",
            "jbtype",
        ]:
            self.assertIn(f'@"{key}"', body, f"missing data key {key}")

    def test_key_present_checks_five_critical(self):
        start = self.src.find("getIOPMPSServDiagnostics")
        body = self.src[start : start + 2500]
        for k in ["CurrentCapacity", "Amperage", "Voltage", "IsCharging", "Temperature"]:
            self.assertIn(f'@"{k}"', body)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m unittest scripts.tests.test_get_diag_api -v
```

Expected: FAIL — `getIOPMPSServDiagnostics` / `@"get_diag"` 不存在

- [ ] **Step 3: 实现 `getIOPMPSServDiagnostics` + `get_diag` 分支**

在 `daemon.mm` 的 `getBatInfo` 之后(约 1284 行后)插入:

```objc
// 只读诊断:命中 service + 发布 key + 5 个关键 key 存在性 + 库加载。
// 硬约束:绝不 SetCFProperties / exit / kill / 写文件 / 改 g_use_smart。
static NSString* CLJBTypeString(void) {
    switch (getJBType()) {
        case JBTYPE_ROOTHIDE:   return @"roothide";
        case JBTYPE_ROOTLESS:   return @"rootless";
        case JBTYPE_ROOT:       return @"rootful";
        case JBTYPE_TROLLSTORE: return @"trollstore";
        default:                return @"unknown";
    }
}

static BOOL CLProbeLibJailbreakLoaded(void) {
    void* h = dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (h) {
        // 已加载则 NOLOAD 成功;再尝试一次常规 dlopen 验证可打开
        dlclose(h);
        return YES;
    }
    h = dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY);
    if (h) {
        dlclose(h);
        return YES;
    }
    return NO;
}

static NSDictionary* getIOPMPSServDiagnostics(void) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    out[@"serv_boot"] = @(g_serv_boot);
    out[@"use_smart"] = @(g_use_smart);
    out[@"sysver"] = getSysVer() ?: @"";
    out[@"devmodel"] = getDevMdoel() ?: @"";
    out[@"ver"] = getAppVer() ?: @"";
    out[@"jbtype"] = CLJBTypeString();
    out[@"libjailbreak_loaded"] = @(CLProbeLibJailbreakLoaded());

    io_service_t serv = getIOPMPSServ();
    NSString* serviceName = @"(未匹配)";
    if (serv != IO_OBJECT_NULL) {
        serviceName = g_use_smart ? @"AppleSmartBattery" : @"IOPMPowerSource";
    }
    out[@"service_name"] = serviceName;

    NSArray* publishedKeys = @[];
    NSMutableDictionary* keyPresent = [@{
        @"CurrentCapacity": @NO,
        @"Amperage": @NO,
        @"Voltage": @NO,
        @"IsCharging": @NO,
        @"Temperature": @NO,
    } mutableCopy];
    NSInteger iokitReturn = 0;

    if (serv == IO_OBJECT_NULL) {
        iokitReturn = -1;
    } else {
        CFMutableDictionaryRef props = nil;
        kern_return_t kr = IORegistryEntryCreateCFProperties(serv, &props, kCFAllocatorDefault, 0);
        iokitReturn = (NSInteger)kr;
        if (props == nil) {
            if (iokitReturn == 0) iokitReturn = -2;
        } else {
            NSDictionary* info = (__bridge_transfer NSDictionary*)props;
            publishedKeys = [[info allKeys] sortedArrayUsingSelector:@selector(compare:)];
            for (NSString* k in keyPresent.allKeys) {
                keyPresent[k] = @(info[k] != nil);
            }
        }
    }
    out[@"published_keys"] = publishedKeys;
    out[@"key_present"] = keyPresent;
    out[@"iokit_return"] = @(iokitReturn);
    return out;
}
```

在 `handleReq` 的 `get_bat_info` 分支之后加:

```objc
} else if ([api isEqualToString:@"get_diag"]) {
    NSDictionary* data = getIOPMPSServDiagnostics();
    return @{
        @"status": @0,
        @"data": data ?: @{},
    };
```

- [ ] **Step 4: 跑测试确认通过**

```bash
python3 -m unittest scripts.tests.test_get_diag_api -v
```

Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/daemon.mm scripts/tests/test_get_diag_api.py
git commit -m "feat(daemon): 新增 get_diag 只读诊断端点"
```

---

### Task 2: U1 `CLDiagnosticCollector` 模型 + Markdown 格式化(纯函数)

**Files:**
- Create: `ChargeLimiter/UIKit/CLDiagnosticCollector.h`
- Create: `ChargeLimiter/UIKit/CLDiagnosticCollector.m`
- Test: `scripts/tests/test_diagnostic_collector_markdown.py`

**Interfaces:**
- Consumes: 无(本 task 只建模型与 `markdownText`,不调网络)
- Produces:
  ```objc
  @interface CLDiagEnvironment : NSObject
  @property (nonatomic, copy) NSString *deviceModel;
  @property (nonatomic, copy) NSString *systemVersion;
  @property (nonatomic, copy) NSString *appVersion;
  @property (nonatomic, copy) NSString *packageScheme;   // roothide|rootless|rootful
  @property (nonatomic, copy) NSString *jbType;          // roothide|...
  @property (nonatomic, copy) NSString *exePath;         // 截断后的可执行路径
  @property (nonatomic, copy) NSString *dataRootPath;    // 截断后的数据根
  @property (nonatomic, assign) NSTimeInterval systemBootTime;
  @end

  @interface CLDiagConnectivity : NSObject
  @property (nonatomic, assign) BOOL daemonAlive;
  @property (nonatomic, assign) BOOL httpReachable;
  @property (nonatomic, copy) NSString *daemonUptimeText; // "3h 12m" / "N/A"
  @property (nonatomic, copy) NSString *lastApiError;     // "0" / "timeout" / ...
  @end

  @interface CLDiagBatteryProbe : NSObject
  @property (nonatomic, copy) NSString *serviceName;
  @property (nonatomic, copy) NSArray<NSString *> *publishedKeys;
  @property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *keyPresent; // 5 critical
  @property (nonatomic, assign) NSInteger iokitReturn;
  @property (nonatomic, assign) BOOL useSmart;
  @property (nonatomic, assign) BOOL libjailbreakLoaded;
  @property (nonatomic, copy, nullable) NSString *libroothideStatus; // "OK"/"N/A"/"❌"
  @end

  @interface CLDiagnosticReport : NSObject
  @property (nonatomic, strong) CLDiagEnvironment *environment;
  @property (nonatomic, strong) CLDiagConnectivity *connectivity;
  @property (nonatomic, strong) CLDiagBatteryProbe *batteryProbe;
  @property (nonatomic, copy, nullable) NSString *policySummaryText; // 复用现有摘要
  @property (nonatomic, copy, nullable) NSString *probeSummaryText;
  - (NSString *)markdownText;
  @end

  // 包架构字符串(编译宏)
  FOUNDATION_EXPORT NSString *CLPackageSchemeString(void);
  // 路径脱敏:只保留到 .jbroot-XXX 前缀,其余截断
  FOUNDATION_EXPORT NSString *CLSanitizePathForDiag(NSString *path);
  ```

- [ ] **Step 1: 写失败测试(源码扫描 markdown 契约 + 脱敏 + 宏)**

```python
# scripts/tests/test_diagnostic_collector_markdown.py
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
H = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.h"
M = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.m"


class DiagnosticCollectorContractTests(unittest.TestCase):
    def setUp(self):
        self.h = H.read_text(encoding="utf-8") if H.exists() else ""
        self.m = M.read_text(encoding="utf-8") if M.exists() else ""

    def test_files_exist(self):
        self.assertTrue(H.exists(), "CLDiagnosticCollector.h missing")
        self.assertTrue(M.exists(), "CLDiagnosticCollector.m missing")

    def test_report_has_markdown_text(self):
        self.assertIn("- (NSString *)markdownText", self.h)

    def test_markdown_emits_four_sections(self):
        # markdownText 实现必须产出四个段标题
        self.assertIn("# 环境", self.m)
        self.assertIn("# 连通性", self.m)
        self.assertIn("# 读电量链路", self.m)
        self.assertIn("# 策略信号", self.m)

    def test_offline_banner(self):
        self.assertIn("⚠️ daemon 离线", self.m)

    def test_sanitize_path_helper(self):
        self.assertIn("CLSanitizePathForDiag", self.h)
        self.assertIn("CLSanitizePathForDiag", self.m)
        # 必须处理 .jbroot- 截断
        self.assertIn(".jbroot-", self.m)

    def test_package_scheme_helper(self):
        self.assertIn("CLPackageSchemeString", self.h)
        self.assertIn("CL_PACKAGE_ROOTHIDE", self.m)
        self.assertIn("CL_PACKAGE_ROOTLESS", self.m)

    def test_five_critical_keys_in_markdown(self):
        for k in ["CurrentCapacity", "Amperage", "Voltage", "IsCharging", "Temperature"]:
            self.assertIn(k, self.m)

    def test_no_uikit_import(self):
        # 纯函数层不碰 UIKit
        self.assertNotIn("#import <UIKit/UIKit.h>", self.m)
        self.assertNotIn("#import <UIKit/UIKit.h>", self.h)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m unittest scripts.tests.test_diagnostic_collector_markdown -v
```

Expected: FAIL — 文件不存在

- [ ] **Step 3: 实现 header + 模型 + markdownText + 辅助函数**

`ChargeLimiter/UIKit/CLDiagnosticCollector.h`:

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLDiagEnvironment : NSObject
@property (nonatomic, copy) NSString *deviceModel;
@property (nonatomic, copy) NSString *systemVersion;
@property (nonatomic, copy) NSString *appVersion;
@property (nonatomic, copy) NSString *packageScheme;
@property (nonatomic, copy) NSString *jbType;
@property (nonatomic, copy) NSString *exePath;
@property (nonatomic, copy) NSString *dataRootPath;
@property (nonatomic, assign) NSTimeInterval systemBootTime;
@end

@interface CLDiagConnectivity : NSObject
@property (nonatomic, assign) BOOL daemonAlive;
@property (nonatomic, assign) BOOL httpReachable;
@property (nonatomic, copy) NSString *daemonUptimeText;
@property (nonatomic, copy) NSString *lastApiError;
@end

@interface CLDiagBatteryProbe : NSObject
@property (nonatomic, copy) NSString *serviceName;
@property (nonatomic, copy) NSArray<NSString *> *publishedKeys;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *keyPresent;
@property (nonatomic, assign) NSInteger iokitReturn;
@property (nonatomic, assign) BOOL useSmart;
@property (nonatomic, assign) BOOL libjailbreakLoaded;
@property (nonatomic, copy, nullable) NSString *libroothideStatus;
@end

@interface CLDiagnosticReport : NSObject
@property (nonatomic, strong) CLDiagEnvironment *environment;
@property (nonatomic, strong) CLDiagConnectivity *connectivity;
@property (nonatomic, strong) CLDiagBatteryProbe *batteryProbe;
@property (nonatomic, copy, nullable) NSString *policySummaryText;
@property (nonatomic, copy, nullable) NSString *probeSummaryText;
- (NSString *)markdownText;
@end

@interface CLDiagnosticCollector : NSObject
/// 异步采集完整诊断。completion 保证在主线程回调。
+ (void)collectWithPolicySummary:(nullable NSString *)policySummary
                   probeSummary:(nullable NSString *)probeSummary
                     completion:(void (^)(CLDiagnosticReport *report))completion;
@end

FOUNDATION_EXPORT NSString *CLPackageSchemeString(void);
FOUNDATION_EXPORT NSString *CLSanitizePathForDiag(NSString * _Nullable path);
FOUNDATION_EXPORT NSString *CLJBTypeLabelFromCode(int code);

NS_ASSUME_NONNULL_END
```

`ChargeLimiter/UIKit/CLDiagnosticCollector.m`(核心片段,完整实现按此骨架展开):

```objc
#import "CLDiagnosticCollector.h"
#import "CLAPIClient.h"
#import "../common.h"   // getJBType / getSelfExePath / getRuntimeDataRootPath / get_sys_boottime
                        // 注意:common.h 在非 mock 真机可用;若模拟器 CL_USE_MOCK_DATA
                        // 则用弱符号回退字符串 "N/A"

// 若 common.h 拉不进(模拟器),用声明兜底:
extern int getJBType(void) __attribute__((weak_import));
extern NSString* getSelfExePath(void) __attribute__((weak_import));
extern NSString* getRuntimeDataRootPath(void) __attribute__((weak_import));
extern int get_sys_boottime(void) __attribute__((weak_import));

NSString *CLPackageSchemeString(void) {
#if defined(CL_PACKAGE_ROOTHIDE) && CL_PACKAGE_ROOTHIDE
    return @"roothide";
#elif defined(CL_PACKAGE_ROOTLESS) && CL_PACKAGE_ROOTLESS
    return @"rootless";
#else
    return @"rootful";
#endif
}

NSString *CLSanitizePathForDiag(NSString *path) {
    if (path.length == 0) return @"(无法获取)";
    // 截到 .jbroot-XXX 这一段为止,后面路径省略
    NSRange r = [path rangeOfString:@".jbroot-"];
    if (r.location != NSNotFound) {
        NSUInteger end = r.location + r.length;
        while (end < path.length && path.characterAtIndex? /* 用 substring */) {
            // 实现:找到 .jbroot- 后下一个 '/' 前的全部
        }
        // 简化实现:
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        NSMutableArray *kept = [NSMutableArray array];
        for (NSString *p in parts) {
            [kept addObject:p];
            if ([p hasPrefix:@".jbroot-"]) break;
        }
        return [[kept componentsJoinedByString:@"/"] stringByAppendingString:@"/…"];
    }
    // 非 jbroot 路径:保留最后 3 段
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count > 4) {
        NSArray *tail = [parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)];
        return [@"…/" stringByAppendingString:[tail componentsJoinedByString:@"/"]];
    }
    return path;
}

NSString *CLJBTypeLabelFromCode(int code) {
    switch (code) {
        case 2:  return @"roothide";     // JBTYPE_ROOTHIDE
        case 0:  return @"rootless";
        case 1:  return @"rootful";
        case 8:  return @"trollstore";
        default: return @"unknown";
    }
}

// … CLDiagEnvironment / Connectivity / BatteryProbe @implementation 空壳 …

@implementation CLDiagnosticReport
- (NSString *)markdownText {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    CLDiagConnectivity *c = self.connectivity;
    if (c && !c.daemonAlive) {
        [lines addObject:@"⚠️ daemon 离线"];
        [lines addObject:@""];
    }
    // # 环境
    [lines addObject:@"# 环境"];
    CLDiagEnvironment *e = self.environment;
    [lines addObject:[NSString stringWithFormat:@"设备型号:        %@", e.deviceModel.length ? e.deviceModel : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"iOS 版本:        %@", e.systemVersion.length ? e.systemVersion : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"App 版本:        %@", e.appVersion.length ? e.appVersion : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"包架构:          %@", e.packageScheme.length ? e.packageScheme : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"越狱类型:        %@", e.jbType.length ? e.jbType : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"可执行路径:      %@", e.exePath.length ? e.exePath : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"数据根路径:      %@", e.dataRootPath.length ? e.dataRootPath : @"(无法获取)"]];
    if (e.systemBootTime > 0) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:e.systemBootTime];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        [lines addObject:[NSString stringWithFormat:@"系统启动:        %@", [fmt stringFromDate:d]]];
    } else {
        [lines addObject:@"系统启动:        (无法获取)"];
    }
    [lines addObject:@""];

    // # 连通性
    [lines addObject:@"# 连通性"];
    [lines addObject:[NSString stringWithFormat:@"daemon 在线:     %@", c.daemonAlive ? @"YES" : @"NO"]];
    [lines addObject:[NSString stringWithFormat:@"HTTP 可达:       %@", c.httpReachable ? @"YES" : @"NO"]];
    [lines addObject:[NSString stringWithFormat:@"daemon 启动时长: %@", c.daemonUptimeText.length ? c.daemonUptimeText : @"N/A"]];
    [lines addObject:[NSString stringWithFormat:@"最近 API 错误码: %@", c.lastApiError.length ? c.lastApiError : @"(无法获取)"]];
    [lines addObject:@""];

    // # 读电量链路
    [lines addObject:@"# 读电量链路"];
    CLDiagBatteryProbe *b = self.batteryProbe;
    if (!c.httpReachable) {
        [lines addObject:@"daemon 离线,无法探测"];
    } else {
        [lines addObject:[NSString stringWithFormat:@"命中 service:    %@", b.serviceName.length ? b.serviceName : @"(无法获取)"]];
        NSString *keys = b.publishedKeys.count ? [b.publishedKeys componentsJoinedByString:@","] : @"(无)";
        [lines addObject:[NSString stringWithFormat:@"发布 key 清单:   %@", keys]];
        [lines addObject:@"关键 key 是否齐全:"];
        for (NSString *k in @[@"CurrentCapacity", @"Amperage", @"Voltage", @"IsCharging", @"Temperature"]) {
            BOOL present = [b.keyPresent[k] boolValue];
            [lines addObject:[NSString stringWithFormat:@"  %@: %@", k, present ? @"YES" : @"❌缺失"]];
        }
        [lines addObject:[NSString stringWithFormat:@"IOKit 返回值:     %ld", (long)b.iokitReturn]];
        [lines addObject:[NSString stringWithFormat:@"use_smart:        %d", b.useSmart ? 1 : 0]];
        [lines addObject:@"越狱库加载:"];
        [lines addObject:[NSString stringWithFormat:@"  libjailbreak.dylib:  %@", b.libjailbreakLoaded ? @"OK" : @"❌dlopen失败"]];
        [lines addObject:[NSString stringWithFormat:@"  libroothide.dylib:   %@", b.libroothideStatus.length ? b.libroothideStatus : @"N/A"]];
    }
    [lines addObject:@""];

    // # 策略信号
    [lines addObject:@"# 策略信号"];
    if (self.policySummaryText.length > 0) {
        [lines addObject:self.policySummaryText];
    } else {
        [lines addObject:@"(无法获取)"];
    }

    if (self.probeSummaryText.length > 0) {
        [lines addObject:@""];
        [lines addObject:@"## 停充控制探针结论"];
        [lines addObject:self.probeSummaryText];
    }
    return [lines componentsJoinedByString:@"\n"];
}
@end

// collectWithPolicySummary: 本 task 只留空壳声明,Task 3 实现网络采集
@implementation CLDiagnosticCollector
+ (void)collectWithPolicySummary:(NSString *)policySummary
                   probeSummary:(NSString *)probeSummary
                     completion:(void (^)(CLDiagnosticReport *))completion {
    // Task 3 实现
    if (completion) {
        CLDiagnosticReport *empty = [CLDiagnosticReport new];
        empty.environment = [CLDiagEnvironment new];
        empty.connectivity = [CLDiagConnectivity new];
        empty.batteryProbe = [CLDiagBatteryProbe new];
        empty.policySummaryText = policySummary;
        empty.probeSummaryText = probeSummary;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(empty); });
    }
}
@end
```

> 实现时把 `CLSanitizePathForDiag` 的伪代码换成完整可编译版本(上面骨架里用 `hasPrefix:@".jbroot-"` 的简化实现即可,删掉 `characterAtIndex?` 注释块)。

- [ ] **Step 4: 跑测试确认通过**

```bash
python3 -m unittest scripts.tests.test_diagnostic_collector_markdown -v
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/UIKit/CLDiagnosticCollector.h ChargeLimiter/UIKit/CLDiagnosticCollector.m scripts/tests/test_diagnostic_collector_markdown.py
git commit -m "feat(diag): CLDiagnosticCollector 模型与 markdownText"
```

---

### Task 3: U1 网络采集 `collectWithPolicySummary:` + CLAPIClient `getDiag`

**Files:**
- Modify: `ChargeLimiter/UIKit/CLAPIClient.h` — 加 `getDiagWithCompletion:`
- Modify: `ChargeLimiter/UIKit/CLAPIClient.m` — 实现,`allowDaemonRestart:NO`
- Modify: `ChargeLimiter/UIKit/CLDiagnosticCollector.m` — 实现 `collectWithPolicySummary:`
- Test: `scripts/tests/test_diagnostic_collector_collect.py`

**Interfaces:**
- Consumes: Task 1 的 `get_diag` 端点;Task 2 的模型
- Produces:
  ```objc
  // CLAPIClient.h
  - (void)getDiagWithCompletion:(CLAPICallback)completion;
  // 内部: sendRequestInternal allowRetry:NO allowDaemonRestart:NO
  //       专用 session timeout 8s/15s(诊断不该死等)

  // CLDiagnosticCollector
  + (void)collectWithPolicySummary:(NSString *)policySummary
                     probeSummary:(NSString *)probeSummary
                       completion:(void (^)(CLDiagnosticReport *report))completion;
  // 行为:
  //  1. 本地填 environment(包架构宏 / getJBType / getSelfExePath 脱敏 / getRuntimeDataRootPath 脱敏 / get_sys_boottime)
  //  2. 调 getDiagWithCompletion:
  //     - 成功 status==0 → httpReachable=YES,daemonAlive=YES,填 batteryProbe + serv_boot 算 uptime
  //     - 失败/超时 → httpReachable=NO,daemonAlive=NO,lastApiError=error.localizedDescription 或 "timeout"
  //  3. 主线程 callback
  ```

- [ ] **Step 1: 写失败测试**

```python
# scripts/tests/test_diagnostic_collector_collect.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
API_H = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.h"
API_M = REPO / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"
COL_M = REPO / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.m"


class CollectContractTests(unittest.TestCase):
    def setUp(self):
        self.api_h = API_H.read_text(encoding="utf-8")
        self.api_m = API_M.read_text(encoding="utf-8")
        self.col_m = COL_M.read_text(encoding="utf-8")

    def test_get_diag_declared(self):
        self.assertIn("getDiagWithCompletion", self.api_h)

    def test_get_diag_uses_no_daemon_restart(self):
        idx = self.api_m.find("getDiagWithCompletion")
        self.assertGreater(idx, -1)
        body = self.api_m[idx : idx + 1200]
        self.assertIn('@"get_diag"', body)
        self.assertIn("allowDaemonRestart:NO", body)
        self.assertIn("allowRetry:NO", body)

    def test_collect_calls_get_diag(self):
        self.assertIn("getDiagWithCompletion", self.col_m)

    def test_collect_fills_environment_locally(self):
        # 本地环境不依赖 daemon
        self.assertIn("CLPackageSchemeString", self.col_m)
        self.assertIn("CLSanitizePathForDiag", self.col_m)
        self.assertIn("CLJBTypeLabelFromCode", self.col_m)

    def test_collect_marks_offline_on_error(self):
        # 失败路径必须把 httpReachable / daemonAlive 置 NO
        self.assertTrue(
            "httpReachable = NO" in self.col_m or "httpReachable=NO" in self.col_m
            or ".httpReachable = NO" in self.col_m
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m unittest scripts.tests.test_diagnostic_collector_collect -v
```

Expected: FAIL — `getDiagWithCompletion` 未声明

- [ ] **Step 3: 实现 CLAPIClient 便捷方法**

`CLAPIClient.h` 在 `checkDaemonAliveWithCompletion:` 前加:

```objc
// 便捷方法 - 拉取只读诊断(环境/读电量链路);失败不重启 daemon
- (void)getDiagWithCompletion:(CLAPICallback)completion;
```

`CLAPIClient.m` 实现:

```objc
- (void)getDiagWithCompletion:(CLAPICallback)completion {
    NSDictionary *params = @{ @"api": @"get_diag" };
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 8.0;
    cfg.timeoutIntervalForResource = 15.0;
    NSURLSession *diagSession = [NSURLSession sessionWithConfiguration:cfg];
    [self sendRequestInternal:params
                   allowRetry:NO
            allowDaemonRestart:NO
                      session:diagSession
                   completion:completion];
}
```

- [ ] **Step 4: 实现 `collectWithPolicySummary:`**

替换 Task 2 的空壳:

```objc
+ (void)collectWithPolicySummary:(NSString *)policySummary
                   probeSummary:(NSString *)probeSummary
                     completion:(void (^)(CLDiagnosticReport *))completion {
    CLDiagnosticReport *report = [CLDiagnosticReport new];
    report.policySummaryText = policySummary;
    report.probeSummaryText = probeSummary;

    // 1) 本地环境
    CLDiagEnvironment *env = [CLDiagEnvironment new];
    env.packageScheme = CLPackageSchemeString();
    int jb = (getJBType != NULL) ? getJBType() : -1;
    env.jbType = CLJBTypeLabelFromCode(jb);
    NSString *exe = (getSelfExePath != NULL) ? getSelfExePath() : nil;
    env.exePath = CLSanitizePathForDiag(exe);
    NSString *dataRoot = (getRuntimeDataRootPath != NULL) ? getRuntimeDataRootPath() : nil;
    env.dataRootPath = CLSanitizePathForDiag(dataRoot);
    env.systemBootTime = (get_sys_boottime != NULL) ? (NSTimeInterval)get_sys_boottime() : 0;
    // deviceModel / systemVersion / appVersion 由 get_diag 回填;本地先占位
    env.deviceModel = @"";
    env.systemVersion = @"";
    env.appVersion = @"";
    report.environment = env;

    CLDiagConnectivity *conn = [CLDiagConnectivity new];
    conn.daemonAlive = NO;
    conn.httpReachable = NO;
    conn.daemonUptimeText = @"N/A";
    conn.lastApiError = @"(未请求)";
    report.connectivity = conn;

    CLDiagBatteryProbe *probe = [CLDiagBatteryProbe new];
    probe.serviceName = @"";
    probe.publishedKeys = @[];
    probe.keyPresent = @{};
    probe.libroothideStatus = ([env.packageScheme isEqualToString:@"roothide"] ? @"N/A" : @"N/A");
    report.batteryProbe = probe;

    // 2) 拉 get_diag
    [[CLAPIClient shared] getDiagWithCompletion:^(NSDictionary *response, NSError *error) {
        if (error || response == nil || [response[@"status"] intValue] != 0) {
            conn.httpReachable = NO;
            conn.daemonAlive = NO;
            if (error) {
                conn.lastApiError = error.localizedDescription ?: @"error";
            } else if (response[@"msg"]) {
                conn.lastApiError = [NSString stringWithFormat:@"%@", response[@"msg"]];
            } else {
                conn.lastApiError = @"status!=0";
            }
        } else {
            conn.httpReachable = YES;
            conn.daemonAlive = YES;
            conn.lastApiError = @"0";
            NSDictionary *data = response[@"data"];
            if ([data isKindOfClass:[NSDictionary class]]) {
                env.deviceModel = [NSString stringWithFormat:@"%@", data[@"devmodel"] ?: @""];
                env.systemVersion = [NSString stringWithFormat:@"%@", data[@"sysver"] ?: @""];
                env.appVersion = [NSString stringWithFormat:@"%@", data[@"ver"] ?: @""];
                // 若 daemon 回报 jbtype,优先用(与本地交叉验证)
                if ([data[@"jbtype"] isKindOfClass:[NSString class]] && [data[@"jbtype"] length] > 0) {
                    // 保留本地,同时可在 markdown 里看一致性;此处不覆盖本地
                }
                NSNumber *servBoot = data[@"serv_boot"];
                if ([servBoot respondsToSelector:@selector(doubleValue)] && servBoot.doubleValue > 0) {
                    NSTimeInterval up = [[NSDate date] timeIntervalSince1970] - servBoot.doubleValue;
                    if (up < 0) up = 0;
                    NSInteger h = (NSInteger)(up / 3600);
                    NSInteger m = (NSInteger)((up - h * 3600) / 60);
                    conn.daemonUptimeText = [NSString stringWithFormat:@"%ldh %ldm", (long)h, (long)m];
                }
                probe.serviceName = [NSString stringWithFormat:@"%@", data[@"service_name"] ?: @"(无法获取)"];
                NSArray *keys = data[@"published_keys"];
                probe.publishedKeys = [keys isKindOfClass:[NSArray class]] ? keys : @[];
                NSDictionary *kp = data[@"key_present"];
                probe.keyPresent = [kp isKindOfClass:[NSDictionary class]] ? kp : @{};
                probe.iokitReturn = [data[@"iokit_return"] integerValue];
                probe.useSmart = [data[@"use_smart"] boolValue];
                probe.libjailbreakLoaded = [data[@"libjailbreak_loaded"] boolValue];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
        }
    }];
}
```

> 注意:若 `common.h` 在 App target 引入有问题,改用 `CLBatteryManager.shared` 的 `deviceModel`/`systemVersion`/`appVersion`/`systemBootTime` 作环境回填兜底(get_diag 成功时用 daemon 值覆盖;失败时用 manager 缓存)。实现时优先 manager 兜底 + get_diag 覆盖,避免 weak_import 复杂度。

- [ ] **Step 5: 跑测试确认通过**

```bash
python3 -m unittest scripts.tests.test_diagnostic_collector_collect -v
python3 -m unittest scripts.tests.test_diagnostic_collector_markdown -v
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add ChargeLimiter/UIKit/CLAPIClient.h ChargeLimiter/UIKit/CLAPIClient.m ChargeLimiter/UIKit/CLDiagnosticCollector.m scripts/tests/test_diagnostic_collector_collect.py
git commit -m "feat(diag): collectWithPolicySummary 拉 get_diag 并填报告"
```

---

### Task 4: U3 策略诊断页 UI 接入

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m`
  - import `CLDiagnosticCollector.h`
  - `CLPolicyDiagnosticsViewController` 加 property `lastDiagReport`
  - `setupContent` 顶部加主按钮 + 环境与连通性卡片
  - 旧导出按钮改名+副标题;删「复制长测校准模板」
  - `viewWillAppear` / 主按钮 调 `CLDiagnosticCollector collect...`
- Modify: `ChargeLimiter/zh-Hans.lproj/Localizable.strings`
- Modify: `ChargeLimiter/en.lproj/Localizable.strings`
- Test: `scripts/tests/test_diagnostics_panel_ui.py`

**Interfaces:**
- Consumes: Task 2/3 的 `CLDiagnosticCollector` / `CLDiagnosticReport.markdownText`
- Produces: 用户可见 UI + 剪贴板 Markdown

- [ ] **Step 1: 写失败测试**

```python
# scripts/tests/test_diagnostics_panel_ui.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ADV = REPO / "ChargeLimiter" / "UIKit" / "Controllers" / "CLAdvancedSettingsViewController.m"
ZH = REPO / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings"
EN = REPO / "ChargeLimiter" / "en.lproj" / "Localizable.strings"


class DiagnosticsPanelUITests(unittest.TestCase):
    def setUp(self):
        self.src = ADV.read_text(encoding="utf-8")
        self.zh = ZH.read_text(encoding="utf-8")
        self.en = EN.read_text(encoding="utf-8")

    def test_imports_collector(self):
        self.assertIn("CLDiagnosticCollector.h", self.src)

    def test_one_tap_copy_button_exists(self):
        self.assertIn("一键复制完整诊断", self.src)
        self.assertIn("copyFullDiagnosticTapped", self.src)

    def test_environment_card_keys(self):
        for key in [
            "diag_device", "diag_ios", "diag_appver", "diag_scheme",
            "diag_jbtype", "diag_daemon", "diag_http", "diag_service",
            "diag_key_capacity", "diag_iokit",
        ]:
            self.assertIn(f'@"{key}"', self.src, f"missing valueLabels key {key}")

    def test_collect_called_on_appear_or_refresh(self):
        self.assertIn("collectWithPolicySummary", self.src)

    def test_calibration_template_removed(self):
        # setupContent 的导出卡不再添加「复制长测校准模板」
        # 允许 method 残留但 setupContent 区域不得 addPicker 该 title
        setup_start = self.src.find("- (void)setupContent")
        # 只检查 CLPolicyDiagnosticsViewController 的 setupContent(第一个)
        setup_end = self.src.find("- (void)addDiagnosticRowToCard", setup_start)
        body = self.src[setup_start:setup_end]
        self.assertNotIn("复制长测校准模板", body)

    def test_renamed_export_buttons(self):
        self.assertIn("复制探针→详细", self.src)
        self.assertIn("复制策略信号", self.src)

    def test_localization_keys(self):
        for key in [
            "一键复制完整诊断",
            "环境与连通性",
            "复制探针→详细",
            "复制策略信号",
            "完整诊断已复制到剪贴板。",
        ]:
            self.assertIn(f'"{key}"', self.zh, f"zh missing {key}")
            self.assertIn(f'"{key}"', self.en, f"en missing {key}")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

```bash
python3 -m unittest scripts.tests.test_diagnostics_panel_ui -v
```

Expected: FAIL

- [ ] **Step 3: 加本地化键**

`zh-Hans.lproj/Localizable.strings` 追加:

```
"一键复制完整诊断" = "一键复制完整诊断";
"环境与连通性" = "环境与连通性";
"命中 service" = "命中 service";
"发布 key 数" = "发布 key 数";
"CurrentCapacity 齐全" = "CurrentCapacity 齐全";
"IOKit 返回值" = "IOKit 返回值";
"包架构" = "包架构";
"越狱类型" = "越狱类型";
"daemon 启动时长" = "daemon 启动时长";
"HTTP 可达" = "HTTP 可达";
"复制探针→详细" = "复制探针→详细";
"复制策略信号" = "复制策略信号";
"导出事件时间线→原始" = "导出事件时间线→原始";
"完整诊断已复制到剪贴板。" = "完整诊断已复制到剪贴板。";
"点最上方按钮可把以上信息连同策略信号一键复制给开发者。" = "点最上方按钮可把以上信息连同策略信号一键复制给开发者。";
"仅含探针结论,不含环境" = "仅含探针结论,不含环境";
"仅含策略/保持/信号,不含环境" = "仅含策略/保持/信号,不含环境";
"仅含持久化事件,不含环境" = "仅含持久化事件,不含环境";
```

`en.lproj/Localizable.strings` 追加对应英文:

```
"一键复制完整诊断" = "Copy Full Diagnostics";
"环境与连通性" = "Environment & Connectivity";
"命中 service" = "Matched Service";
"发布 key 数" = "Published Key Count";
"CurrentCapacity 齐全" = "CurrentCapacity Present";
"IOKit 返回值" = "IOKit Return";
"包架构" = "Package Scheme";
"越狱类型" = "Jailbreak Type";
"daemon 启动时长" = "Daemon Uptime";
"HTTP 可达" = "HTTP Reachable";
"复制探针→详细" = "Copy Probe Detail";
"复制策略信号" = "Copy Policy Signals";
"导出事件时间线→原始" = "Export Event Timeline (Raw)";
"完整诊断已复制到剪贴板。" = "Full diagnostics copied to the clipboard.";
"点最上方按钮可把以上信息连同策略信号一键复制给开发者。" = "Tap the top button to copy everything above plus policy signals for the developer.";
"仅含探针结论,不含环境" = "Probe conclusion only; no environment";
"仅含策略/保持/信号,不含环境" = "Policy/hold/signals only; no environment";
"仅含持久化事件,不含环境" = "Persisted events only; no environment";
```

- [ ] **Step 4: 改 `CLPolicyDiagnosticsViewController`**

1. 文件顶部 `#import "../CLDiagnosticCollector.h"`
2. 接口加:
   ```objc
   @property (nonatomic, strong, nullable) CLDiagnosticReport *lastDiagReport;
   ```
3. `setupContent` **开头**(在 runtimeCard 之前)插入:

```objc
// —— 主入口:一键复制完整诊断 ——
CLAdvSettingsCard *copyAllCard = [[CLAdvSettingsCard alloc] init];
[copyAllCard addPickerRowWithIcon:@"doc.on.doc.fill"
                            title:CLL(@"一键复制完整诊断")
                            value:CLL(@"复制")
                            color:[UIColor systemBlueColor]
                              tag:920
                           target:self
                           action:@selector(copyFullDiagnosticTapped:)];
[self addTipRowToCard:copyAllCard text:CLL(@"点最上方按钮可把以上信息连同策略信号一键复制给开发者。")];
[self.mainStack addArrangedSubview:copyAllCard];

// —— 环境与连通性 ——
CLAdvSettingsCard *envCard = [[CLAdvSettingsCard alloc] init];
[envCard addSectionHeader:CLL(@"环境与连通性")];
[self addDiagnosticRowToCard:envCard key:@"diag_device" icon:@"iphone" title:CLL(@"设备") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_ios" icon:@"gear" title:CLL(@"系统版本") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_appver" icon:@"app.badge" title:CLL(@"应用版本") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_scheme" icon:@"shippingbox" title:CLL(@"包架构") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_jbtype" icon:@"lock.shield" title:CLL(@"越狱类型") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_daemon" icon:@"server.rack" title:CLL(@"守护进程") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_http" icon:@"network" title:CLL(@"HTTP 可达") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_uptime" icon:@"clock" title:CLL(@"daemon 启动时长") color:[UIColor systemGrayColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_service" icon:@"cpu" title:CLL(@"命中 service") color:[UIColor systemTealColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_key_count" icon:@"list.number" title:CLL(@"发布 key 数") color:[UIColor systemTealColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_key_capacity" icon:@"battery.50" title:CLL(@"CurrentCapacity 齐全") color:[UIColor systemTealColor]];
[envCard addSeparator];
[self addDiagnosticRowToCard:envCard key:@"diag_iokit" icon:@"wrench" title:CLL(@"IOKit 返回值") color:[UIColor systemTealColor]];
[self addTipRowToCard:envCard text:CLL(@"点最上方按钮可把以上信息连同策略信号一键复制给开发者。")];
[self.mainStack addArrangedSubview:envCard];
```

4. 导出卡改名(在 setupContent 末尾 exportCard 处):

```objc
// 原: CLL(@"复制探针结果") → CLL(@"复制探针→详细")
// 原 tip 后追加副标题 tip: CLL(@"仅含探针结论,不含环境")
// 原: CLL(@"复制诊断摘要") → CLL(@"复制策略信号") + tip CLL(@"仅含策略/保持/信号,不含环境")
// 原: CLL(@"导出事件时间线") → CLL(@"导出事件时间线→原始") + tip CLL(@"仅含持久化事件,不含环境")
// 删除: copyCalibrationChecklistTapped 对应的 addPickerRow 整行(含 separator)
```

5. 新增方法:

```objc
- (void)refreshEnvironmentDiagnostics {
    NSString *policy = [self diagnosticSummaryTextForManager:[CLBatteryManager shared]];
    NSString *probe = self.lastProbeSummaryText;
    __weak typeof(self) weakSelf = self;
    [CLDiagnosticCollector collectWithPolicySummary:policy
                                      probeSummary:probe
                                        completion:^(CLDiagnosticReport *report) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.lastDiagReport = report;
        [self applyDiagReportToLabels:report];
    }];
}

- (void)applyDiagReportToLabels:(CLDiagnosticReport *)report {
    CLDiagEnvironment *e = report.environment;
    CLDiagConnectivity *c = report.connectivity;
    CLDiagBatteryProbe *b = report.batteryProbe;
    [self updateDiagnosticValue:(e.deviceModel.length ? e.deviceModel : @"--") forKey:@"diag_device"];
    [self updateDiagnosticValue:(e.systemVersion.length ? e.systemVersion : @"--") forKey:@"diag_ios"];
    [self updateDiagnosticValue:(e.appVersion.length ? e.appVersion : @"--") forKey:@"diag_appver"];
    [self updateDiagnosticValue:(e.packageScheme.length ? e.packageScheme : @"--") forKey:@"diag_scheme"];
    [self updateDiagnosticValue:(e.jbType.length ? e.jbType : @"--") forKey:@"diag_jbtype"];
    [self updateDiagnosticValue:(c.daemonAlive ? @"YES" : @"NO") forKey:@"diag_daemon"];
    [self updateDiagnosticValue:(c.httpReachable ? @"YES" : @"NO") forKey:@"diag_http"];
    [self updateDiagnosticValue:(c.daemonUptimeText.length ? c.daemonUptimeText : @"N/A") forKey:@"diag_uptime"];
    [self updateDiagnosticValue:(b.serviceName.length ? b.serviceName : @"--") forKey:@"diag_service"];
    [self updateDiagnosticValue:[NSString stringWithFormat:@"%lu", (unsigned long)b.publishedKeys.count] forKey:@"diag_key_count"];
    BOOL capOK = [b.keyPresent[@"CurrentCapacity"] boolValue];
    [self updateDiagnosticValue:(c.httpReachable ? (capOK ? @"YES" : @"❌缺失") : @"--") forKey:@"diag_key_capacity"];
    [self updateDiagnosticValue:(c.httpReachable ? [NSString stringWithFormat:@"%ld", (long)b.iokitReturn] : @"--") forKey:@"diag_iokit"];
}

- (void)copyFullDiagnosticTapped:(UITapGestureRecognizer *)tap {
    NSString *policy = [self diagnosticSummaryTextForManager:[CLBatteryManager shared]];
    NSString *probe = self.lastProbeSummaryText;
    __weak typeof(self) weakSelf = self;
    [CLDiagnosticCollector collectWithPolicySummary:policy
                                      probeSummary:probe
                                        completion:^(CLDiagnosticReport *report) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.lastDiagReport = report;
        [self applyDiagReportToLabels:report];
        NSString *text = [report markdownText] ?: @"";
        [UIPasteboard generalPasteboard].string = text;
        [self presentInfoAlertWithTitle:CLL(@"已复制") message:CLL(@"完整诊断已复制到剪贴板。")];
    }];
}
```

6. `viewWillAppear` 末尾加 `[self refreshEnvironmentDiagnostics];`(在已有 `updateDiagnosticValues` 之后)

- [ ] **Step 5: 跑测试确认通过**

```bash
python3 -m unittest scripts.tests.test_diagnostics_panel_ui -v
python3 -m unittest scripts.tests.test_get_diag_api scripts.tests.test_diagnostic_collector_markdown scripts.tests.test_diagnostic_collector_collect -v
```

Expected: 全部 PASS

- [ ] **Step 6: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m \
        ChargeLimiter/zh-Hans.lproj/Localizable.strings \
        ChargeLimiter/en.lproj/Localizable.strings \
        scripts/tests/test_diagnostics_panel_ui.py
git commit -m "feat(ui): 策略诊断页一键复制完整诊断与环境卡片"
```

---

### Task 5: pbxproj 接入说明 + 包架构宏(交付脚本,不直接改)

**Files:**
- Create: `scripts/wire_diagnostic_collector_pbxproj.md`(说明文档,给用户在能跑 xcodebuild 的环境执行)
- Test: `scripts/tests/test_diag_pbxproj_instructions.py`(扫描说明文档完整性;可选扫描 pbxproj 是否已含若用户已接入)

**说明文档必须包含:**

1. 把 `CLDiagnosticCollector.h/.m` 加入 3 个 App target 的 Compile Sources:
   - `ChargeLimiter`
   - `ChargeLimiter_rootless`(若存在)
   - `ChargeLimiter_roothide`
   - **不要**加入任何 Daemon target
2. Preprocessor Definitions:
   - roothide App target:`CL_PACKAGE_ROOTHIDE=1`
   - rootless App target:`CL_PACKAGE_ROOTLESS=2`
   - rootful:不定义
3. 验收命令:
   ```bash
   # 编译 roothide app(用户环境)
   xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter roothide" \
     -destination "generic/platform=iOS" -configuration Release \
     -derivedDataPath build_roothide CODE_SIGNING_ALLOWED=NO ARCHS=arm64
   # 装到 17.0 设备 → 充电高级 → 策略诊断 → 一键复制完整诊断 → 把文本发回
   ```

- [ ] **Step 1: 写说明文档**

内容覆盖上述 3 点 + 与 `CLLocalization.m` 同样的 target 归属模式提醒。

- [ ] **Step 2: 写扫描测试(说明文档完整性)**

```python
# scripts/tests/test_diag_pbxproj_instructions.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DOC = REPO / "scripts" / "wire_diagnostic_collector_pbxproj.md"


class PbxprojInstructionsTests(unittest.TestCase):
    def test_doc_exists(self):
        self.assertTrue(DOC.exists())

    def test_doc_mentions_targets_and_macros(self):
        t = DOC.read_text(encoding="utf-8")
        self.assertIn("CLDiagnosticCollector", t)
        self.assertIn("CL_PACKAGE_ROOTHIDE", t)
        self.assertIn("CL_PACKAGE_ROOTLESS", t)
        self.assertIn("ChargeLimiter_roothide", t)
        self.assertIn("Daemon", t)  # 明确说不要加 daemon
        self.assertIn("xcodebuild", t)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: 跑测试**

```bash
python3 -m unittest scripts.tests.test_diag_pbxproj_instructions -v
```

- [ ] **Step 4: Commit**

```bash
git add scripts/wire_diagnostic_collector_pbxproj.md scripts/tests/test_diag_pbxproj_instructions.py
git commit -m "docs: CLDiagnosticCollector pbxproj 接入说明与宏"
```

---

### Task 6: 全量回归 + 收尾

- [ ] **Step 1: 跑全部相关测试**

```bash
python3 -m unittest \
  scripts.tests.test_get_diag_api \
  scripts.tests.test_diagnostic_collector_markdown \
  scripts.tests.test_diagnostic_collector_collect \
  scripts.tests.test_diagnostics_panel_ui \
  scripts.tests.test_diag_pbxproj_instructions \
  -v
```

Expected: 全部 PASS

- [ ] **Step 2: 跑既有相关回归(不停充/设置相关,防误伤)**

```bash
python3 -m unittest \
  scripts.tests.test_ios17_charge_override_paths \
  scripts.tests.test_charge_control_probe_logic \
  scripts.tests.test_ios17_ui_hold_status_display \
  -v
```

Expected: 全部 PASS(本改动不应影响)

- [ ] **Step 3: 对照 spec 清单勾选**

| Spec 项 | Task |
|---|---|
| get_diag 只读端点 | T1 |
| 5 关键 key 存在性 | T1 |
| CLDiagnosticCollector 模型+markdown | T2 |
| 离线 banner `⚠️ daemon 离线` | T2 |
| 路径脱敏 | T2 |
| 包架构宏 | T2 + T5 |
| collect 拉 get_diag,不重启 daemon | T3 |
| 顶部一键复制 | T4 |
| 环境与连通性卡片 | T4 |
| 进页自动拉 | T4 |
| 按钮改名+副标题 | T4 |
| 删复制长测校准模板 | T4 |
| 本地化 | T4 |
| pbxproj 说明 | T5 |

- [ ] **Step 4: 最终 commit(若有遗漏小修)**

```bash
git status
# 若干净则跳过;有小修则 commit
```

---

## Self-Review (plan vs spec)

| Spec 要求 | 覆盖 Task | 备注 |
|---|---|---|
| §2 U1 collector | T2+T3 | 模型与采集拆开,便于 TDD |
| §2 U2 get_diag | T1 | 含只读硬约束测试 |
| §2 U3 UI | T4 | |
| §3 四段 Markdown | T2 markdownText | |
| §3 5 关键 key | T1+T2 | |
| §4 离线降级 | T2 banner + T3 offline 标记 | |
| §5 安全(无序列号/脱敏) | T2 CLSanitizePathForDiag;T1 不回全字典 | |
| §8 测试 | 每 task 自带 Python 扫描 | |
| §9 本地化 | T4 | |
| §10 pbxproj 分工 | T5 说明文档,不动 pbxproj | |
| 混淆按钮处理 | T4 改名+删校准模板 | |
| 采集时机进页+复制 | T4 viewWillAppear + copyFull | |

**无占位符**:所有步骤含完整代码/命令。  
**类型一致**:`CLDiagnosticReport.markdownText` / `collectWithPolicySummary:probeSummary:completion:` / `getDiagWithCompletion:` 全 plan 统一。
