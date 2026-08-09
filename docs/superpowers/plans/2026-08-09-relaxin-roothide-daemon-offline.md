# relaxin roothide Daemon 离线自愈（方案 A+B）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「daemon 离线」报告能自动定位失败环节，并提供用户可触发的「一键修复」自愈链路（方案 A 诊断硬化 + B 可观测化）。不改动 daemon 侧逻辑与 `CLAPIClient` 自动重启路径。

**Architecture:** 在 App 侧 `utils.mm` 新增两个 C 桥函数——只读探针 `clDaemonLaunchProbe_C()`（进诊断报告）与有副作用自愈 `clRepairDaemonForApp_C()`（按钮触发，kill→spawn→launchctl 尽力而为）——由 `CLDiagnosticCollector` 以 dlsym 接入离线诊断段并修复 jb 类型双源判读，UI 在既有「调试与观测」卡加一行修复按钮（后台队列执行、关联对象防重入）。Python 源码扫描测试落到既有 `scripts/tests/` unittest 体系。

**Tech Stack:** Objective-C / Objective-C++（ARC）、Foundation、UIKit、Python unittest（源码扫描）、launchctl / posix_spawn。

## Global Constraints

- 用户端文案 key 沿用仓库惯例（中文原文即 key，形如 `"修复 daemon 启动" = "修复 daemon 启动";`），且 zh-Hans 与 en 两份 `.strings` 同步。
- `CLDiagnosticCollector.m/.h` 保持纯 Foundation，不得 `#import <UIKit/UIKit.h>`。
- daemon 在线（`httpReachable==YES`）时 markdown 不得渲染 `# daemon 启动链路` 段。
- 自愈仅由用户显式点击触发；不得接入 `CLAPIClient` 初始化自动路径。
- 本环境无法跑 `xcodebuild`。测试只做源码断言；编译验证由用户在可跑 xcodebuild 环境对 rootful / rootless / roothide 三 scheme 执行（命令见 AGENTS.md）。
- 给出行号仅为锚点；插入导致行号漂移时按语义就近落点。
- Commit 遵循 AGENTS.md：`feat(...)` / `test(...)` 风格，单文件聚焦。

---

### Task 1: utils.mm 导出 `getLogPath_C` 与链路辅助函数

**Files:**
- Modify: `ChargeLimiter/utils.mm`（`getLogPath_C` 放 `getRuntimeDataRootPath_C` 之后；辅助函数放 `restartDaemonForApp_C` 之后）
- Test: Create `scripts/tests/test_daemon_link_bridge.py`

**Interfaces:**
- Produces（后续任务依赖）：
  - `extern "C" NSString* getLogPath_C(void);`
  - 静态 `NSString* CLDaemonPathForApp(void);`
  - 静态 `NSString* CLDaemonJbRootPath(void);`
  - 静态 `NSString* CLReadDaemonLogTail(NSInteger maxLines);`

- [ ] **Step 1: 写 failing 测试**

```python
# scripts/tests/test_daemon_link_bridge.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
U = REPO / "ChargeLimiter" / "utils.mm"


class DaemonLinkBridgeTests(unittest.TestCase):
    def setUp(self):
        self.u = U.read_text(encoding="utf-8") if U.exists() else ""

    def test_log_path_export(self):
        self.assertIn("getLogPath_C", self.u)

    def test_daemon_path_helper(self):
        self.assertIn("CLDaemonPathForApp", self.u)

    def test_jbroot_helper(self):
        self.assertIn("CLDaemonJbRootPath", self.u)

    def test_log_tail_helper(self):
        self.assertIn("CLReadDaemonLogTail", self.u)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认红**

Run: `python3 scripts/tests/test_daemon_link_bridge.py`
Expected: 4 FAIL（符号均不存在）

- [ ] **Step 3: 实现**

在 `getRuntimeDataRootPath_C`（≈1063）后追加：

```objc
extern "C" NSString* getLogPath_C(void) {
    return getLogPath();
}
```

在 `restartDaemonForApp_C` 函数结尾（≈2594）后追加：

```objc
// === daemon 链路修复工具（App 侧）===
// 定位逻辑与 restartDaemonForApp_C 相同：App 自身 bundle 目录下的 ChargeLimiterDaemon
static NSString* CLDaemonPathForApp(void) {
    NSString* bundlePath = [getSelfExePath() stringByDeletingLastPathComponent];
    if (bundlePath.length == 0) {
        return @"";
    }
    return [bundlePath stringByAppendingPathComponent:@"ChargeLimiterDaemon"];
}

// 从自身 exe 截取 .jbroot-XXX 前缀（launchctl plist 候选路径推导用）
static NSString* CLDaemonJbRootPath(void) {
    NSString* exe = getSelfExePath();
    NSArray* parts = [exe componentsSeparatedByString:@"/"];
    NSMutableArray* kept = [NSMutableArray array];
    for (NSString* p in parts) {
        [kept addObject:p];
        if ([p hasPrefix:@".jbroot-"]) {
            break;
        }
    }
    NSString* root = [kept componentsJoinedByString:@"/"];
    return (root.length > 1) ? root : @"";
}

// aldente.log 尾部（daemon 离线时的“尸检报告”）
static NSString* CLReadDaemonLogTail(NSInteger maxLines) {
    if (maxLines <= 0) {
        maxLines = 1;
    }
    NSString* logPath = getLogPath();
    if (logPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        return @"";
    }
    NSString* content = [NSString stringWithContentsOfFile:logPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (content.length == 0) {
        return @"";
    }
    NSArray<NSString*>* lines = [content componentsSeparatedByString:@"\n"];
    NSInteger count = (NSInteger)lines.count;
    NSInteger keep = MIN(count, maxLines);
    NSArray<NSString*>* tail = [lines subarrayWithRange:NSMakeRange((NSUInteger)(count - keep),
                                                                   (NSUInteger)keep)];
    return [tail componentsJoinedByString:@"\n"];
}
```

- [ ] **Step 4: 运行确认绿**

Run: `python3 scripts/tests/test_daemon_link_bridge.py`
Expected: 4 PASS

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/utils.mm scripts/tests/test_daemon_link_bridge.py
git commit -m "feat(utils): 导出 getLogPath_C 与 daemon 链路路径/日志辅助"
```

---

## Task 2: 只读探针 `clDaemonLaunchProbe_C`

**Files:**
- Modify: `ChargeLimiter/utils.mm`（Task 1 辅助函数之后）
- Test: Modify `scripts/tests/test_daemon_link_bridge.py`

**Interfaces:**
- Consumes: `CLDaemonPathForApp` / `CLReadDaemonLogTail` / `localPortOpen(GSERV_PORT)`（utils.mm:2449）
- Produces: `extern "C" NSDictionary* clDaemonLaunchProbe_C(void);` 返回：`daemon_path`(NSString)、`daemon_exists`(BOOL)、`initial_port_open`(BOOL)、`log_tail`(NSString)
- 只读约束：探针函数体内不得含 kill/spawn/launchctl/bootout/bootstrap。

- [ ] **Step 1: 追加 failing 测试**

```python
    def test_probe_is_read_only(self):
        idx = self.u.find("clDaemonLaunchProbe_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for kw in ("killall", "launchctl", "bootout", "bootstrap", "posix_spawn"):
            self.assertNotIn(kw, body, f"探针只读，不应含 {kw}")

    def test_probe_returns_keys(self):
        idx = self.u.find("clDaemonLaunchProbe_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for key in ("daemon_path", "daemon_exists", "initial_port_open", "log_tail"):
            self.assertIn(f'@"{key}"', body, f"probe 缺 key {key}")
```

- [ ] **Step 2: 运行确认红**

Run: `python3 scripts/tests/test_daemon_link_bridge.py`
Expected: 新增 2 项 FAIL，既有 4 项 PASS

- [ ] **Step 3: 实现**

```objc
// 只读探针：不做任何副作用，供诊断报告离线段使用
extern "C" NSDictionary* clDaemonLaunchProbe_C(void) {
    NSString* daemonPath = CLDaemonPathForApp();
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    out[@"daemon_path"] = daemonPath ?: @"";
    out[@"daemon_exists"] = @([[NSFileManager defaultManager] fileExistsAtPath:daemonPath]);
    out[@"initial_port_open"] = @(localPortOpen(GSERV_PORT));
    out[@"log_tail"] = CLReadDaemonLogTail(20);
    return out;
}
```

- [ ] **Step 4: 运行确认绿**

Run: `python3 scripts/tests/test_daemon_link_bridge.py`
Expected: 6 PASS

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/utils.mm scripts/tests/test_daemon_link_bridge.py
git commit -m "feat(utils): 新增只读 clDaemonLaunchProbe_C（离线诊断探针）"
```

---

## Task 3: 自愈 `clRepairDaemonForApp_C`

**Files:**
- Modify: `ChargeLimiter/utils.mm`（`clDaemonLaunchProbe_C` 之后）
- Test: Modify `scripts/tests/test_daemon_link_bridge.py`

**Interfaces:**
- Consumes: `CLDaemonPathForApp` / `CLDaemonJbRootPath` / `CLReadDaemonLogTail`、`spawn(...)`（≈2230）、`getSelfExePath` / `getJBType` / `getAppDocumentsPath` / `localPortOpen(GSERV_PORT)`、`JBTYPE_TROLLSTORE`（utils.h:48）
- Produces: `extern "C" NSDictionary* clRepairDaemonForApp_C(void);` 返回 Task 2 全部 key +：`kill_rc`、`root_spawn_rc`、`nonroot_spawn_rc`(-999=未尝试)、`port_after_spawn`(BOOL)、`launchctl_attempted`(BOOL)、`launchctl_rc`、`launchctl_out`、`final_port_open`(BOOL)、`repair_result`(`already_up|path_missing|recovered|still_down`)

- [ ] **Step 1: 追加失败测试**

```python
    def test_repair_export_and_steps(self):
        self.assertIn("clRepairDaemonForApp_C", self.u)
        idx = self.u.find("clRepairDaemonForApp_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for kw in ("killall", "launchctl", "bootstrap", "--app-docs"):
            self.assertIn(kw, body, f"repair 应含 {kw}")

    def test_repair_returns_keys(self):
        idx = self.u.find("clRepairDaemonForApp_C")
        end = self.u.find('extern "C"', idx + 1)
        body = self.u[idx:end] if idx >= 0 and end > idx else ""
        for key in ("repair_result", "root_spawn_rc", "nonroot_spawn_rc",
                    "port_after_spawn", "final_port_open", "log_tail"):
            self.assertIn(f'@"{key}"', body, f"repair 缺 key {key}")
```

- [ ] **Step 2: 运行确认红**

Run: `python3 scripts/tests/test_daemon_link_bridge.py`
Expected: 新增 2 项 FAIL

- [ ] **Step 3: 实现**

```objc
// 自愈 + 报告：用户显式触发。kill 残留 → spawn(root→非root) → 等端口 → launchctl 尽力而为。
// nonroot_spawn_rc：根/便携回退失败时的 rc；仅在 root 失败且非 TrollStore 环境时尝试，否则 -999。
extern "C" NSDictionary* clRepairDaemonForApp_C(void) {
    NSString* daemonPath = CLDaemonPathForApp();
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    out[@"daemon_path"] = daemonPath ?: @"";
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:daemonPath];
    out[@"daemon_exists"] = @(exists);

    BOOL alreadyOpen = localPortOpen(GSERV_PORT);
    out[@"initial_port_open"] = @(alreadyOpen);
    if (alreadyOpen) {
        out[@"repair_result"] = @"already_up";
        out[@"final_port_open"] = @YES;
        out[@"log_tail"] = CLReadDaemonLogTail(20);
        return out;
    }
    if (!exists) {
        out[@"repair_result"] = @"path_missing";
        out[@"final_port_open"] = @NO;
        out[@"log_tail"] = CLReadDaemonLogTail(20);
        return out;
    }

    int jbType = getJBType();
    int rootFlags = (jbType != JBTYPE_TROLLSTORE) ? SPAWN_FLAG_ROOT : 0;

    // 1) 杀残留 daemon（best-effort；EPERM/ENOENT 属预期，rc 记录）
    out[@"kill_rc"] = @(spawn(@[@"/usr/bin/killall", @"-9", @"ChargeLimiterDaemon"],
                              nil, nil, nil, SPAWN_FLAG_NOWAIT | rootFlags, nil));

    // 2) spawn daemon：root 优先，EPERM 时 nonroot（口径与 restartDaemonForApp_C 一致）
    NSMutableArray* argv = [NSMutableArray arrayWithObject:daemonPath];
    NSString* appDocs = getAppDocumentsPath();
    if (appDocs.length > 0) {
        [argv addObject:@"--app-docs"];
        [argv addObject:appDocs];
    }
    int rootRc = spawn(argv, nil, nil, nil, SPAWN_FLAG_NOWAIT | rootFlags, nil);
    out[@"root_spawn_rc"] = @(rootRc);
    int nonrootRc = -999;
    if (rootRc != 0 && rootFlags) {
        nonrootRc = spawn(argv, nil, nil, nil, SPAWN_FLAG_NOWAIT, nil);
    }
    out[@"nonroot_spawn_rc"] = @(nonrootRc);

    // 3) 轮询 1230 至多 ~5s（300ms × 17）
    BOOL afterSpawn = NO;
    for (int i = 0; i < 17; i++) {
        if (localPortOpen(GSERV_PORT)) {
            afterSpawn = YES;
            break;
        }
        usleep(300 * 1000);
    }
    out[@"port_after_spawn"] = @(afterSpawn);

    // 4) launchctl 尽力而为（relaxin App sandbox 下常 EPERM；只留证，不重试）
    NSInteger lrc = -1;
    NSString* lout = @"";
    BOOL attempted = NO;
    if (!afterSpawn) {
        NSMutableArray* candidates = [NSMutableArray arrayWithObject:
            @"/Library/LaunchDaemons/com.chargelimiter.mod.plist"];
        NSString* jbRoot = CLDaemonJbRootPath();
        if (jbRoot.length > 0) {
            [candidates addObject:
                [jbRoot stringByAppendingPathComponent:@"Library/LaunchDaemons/com.chargelimiter.mod.plist"]];
        }
        for (NSString* plist in candidates) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:plist]) {
                continue;
            }
            NSString* bootOut = nil;
            NSString* bootErr = nil;
            spawn(@[@"/bin/launchctl", @"bootout", @"system/com.chargelimiter.mod"],
                  &bootOut, &bootErr, nil, rootFlags, nil);
            NSString* splash = bootErr ?: (bootOut ?: @"");
            NSString* bOut = nil;
            NSString* bErr = nil;
            lrc = spawn(@[@"/bin/launchctl", @"bootstrap", @"system", plist],
                        &bOut, &bErr, nil, rootFlags, nil);
            attempted = YES;
            lout = bErr.length ? bErr : (bOut.length ? bOut : splash);
            for (int i = 0; i < 10; i++) {
                if (localPortOpen(GSERV_PORT)) {
                    break;
                }
                usleep(300 * 1000);
            }
            break;
        }
    }
    out[@"launchctl_attempted"] = @(attempted);
    out[@"launchctl_rc"] = @((int)lrc);
    out[@"launchctl_out"] = lout ?: @"";

    BOOL finalOpen = localPortOpen(GSERV_PORT);
    out[@"final_port_open"] = @(finalOpen);
    out[@"repair_result"] = finalOpen ? @"recovered" : @"still_down";
    out[@"log_tail"] = CLReadDaemonLogTail(20);
    return out;
}
```

> 实现提示：`spawn` 非 NOWAIT 会 `waitpid` 直到子进程退出；`/bin/launchctl` 属短命命令，「尽力而为」可接受。若 `spawn @[ @"/bin/launchctl", ...]` 在越狱环境返回 ENOENT/EPERM，属预期并原样记入 `launchctl_rc`。

- [ ] **Step 4: 运行确认绿**

Run: `python3 scripts/tests/test_daemon_link_bridge.py`
Expected: 8 PASS

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/utils.mm scripts/tests/test_daemon_link_bridge.py
git commit -m "feat(utils): 新增 clRepairDaemonForApp_C 自愈链路（kill→spawn→launchctl）"
```

---

## Task 4: 诊断采集层（离线链路段 + jb 双源）

**Files:**
- Modify: `ChargeLimiter/UIKit/CLDiagnosticCollector.h`
- Modify: `ChargeLimiter/UIKit/CLDiagnosticCollector.m`
- Test: Modify `scripts/tests/test_diagnostic_collector_markdown.py`

**Interfaces:**
- Consumes: `clDaemonLaunchProbe_C`（dlsym；语义同 Task 2 返回键）
- Produces：
  - 新模型 `CLDiagDaemonLink`：`daemonPath` / `daemonExists` / `initialPortOpen` / `rootSpawnRc` / `nonrootSpawnRc` / `portAfterSpawn` / `launchctlAttempted` / `launchctlRc` / `launchctlOut` / `finalPortOpen` / `repairResult` / `logTail`
  - `CLDiagnosticReport.daemonLink`
  - `CLDiagEnvironment.jbRawCode`(int) + `jbProbeDetail`(NSString)
  - `FOUNDATION_EXPORT NSString *CLDiagErrnoLabel(NSInteger rc);`（Task 复用）
  - offline 时 markdown 渲染 `# daemon 启动链路` 段；jb 行带 raw code + 符号探测

- [ ] **Step 1: 追加失败测试**

在 `scripts/tests/test_diagnostic_collector_markdown.py` 追加：

```python
    def test_daemon_link_offline_section(self):
        self.assertIn("# daemon 启动链路", self.m)
        self.assertIn("CLDiagErrnoLabel", self.h)
        self.assertIn("CLDiagErrnoLabel", self.m)

    def test_daemon_link_model(self):
        self.assertIn("CLDiagDaemonLink", self.h)
        self.assertIn("daemonLink", self.h)

    def test_jb_dual_source(self):
        self.assertIn("jbRawCode", self.h)
        self.assertIn("jbProbeDetail", self.h)
```

- [ ] **Step 2: 运行确认红**

Run: `python3 scripts/tests/test_diagnostic_collector_markdown.py`
Expected: 新增 3 项 FAIL（既有项 PASS）

- [ ] **Step 3: 实现**

`CLDiagnosticCollector.h`：在 `CLDiagBatteryProbe` 之后加：

```objc
@interface CLDiagDaemonLink : NSObject
@property (nonatomic, copy) NSString *daemonPath;
@property (nonatomic, assign) BOOL daemonExists;
@property (nonatomic, assign) BOOL initialPortOpen;
@property (nonatomic, assign) NSInteger rootSpawnRc;
@property (nonatomic, assign) NSInteger nonrootSpawnRc;
@property (nonatomic, assign) BOOL portAfterSpawn;
@property (nonatomic, assign) BOOL launchctlAttempted;
@property (nonatomic, assign) NSInteger launchctlRc;
@property (nonatomic, copy) NSString *launchctlOut;
@property (nonatomic, assign) BOOL finalPortOpen;
@property (nonatomic, copy) NSString *repairResult;
@property (nonatomic, copy) NSString *logTail;
@end
```

`CLDiagEnvironment` 在 `jbType` 后追加：

```objc
@property (nonatomic, assign) int jbRawCode;              // getJBType 原始 code；-1=未取到
@property (nonatomic, copy) NSString *jbProbeDetail;       // symbol/jbroot/libroot 探测串
```

`CLDiagnosticReport` 追加：

```objc
@property (nonatomic, strong) CLDiagDaemonLink *daemonLink; // 离线时才填充
```

文件底部 `FOUNDATION_EXPORT` 区追加：

```objc
FOUNDATION_EXPORT NSString *CLDiagErrnoLabel(NSInteger rc);
```

`CLDiagnosticCollector.m`：
- 加 dlsym 包装（近 `CLDiagCallGetJBType`）：

```objc
static NSDictionary *CLDiagCallDaemonLaunchProbe(void) {
    typedef NSDictionary *(*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "clDaemonLaunchProbe_C");
    });
    return fn ? fn() : nil;
}
```

- `CLDiagCallGetJBType` 改为带 found 输出：

```objc
static int CLDiagGetJBTypeCode(BOOL *outFound) {
    typedef int (*fn_t)(void);
    static BOOL resolved = NO;
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "getJBType_C");
        resolved = (fn != NULL);
    });
    if (outFound) {
        *outFound = resolved;
    }
    return fn ? fn() : -1;
}

static NSString *CLDiagJbProbeDetail(BOOL symbolFound) {
    BOOL jbrootSym = (dlsym(RTLD_DEFAULT, "jbroot") != NULL);
    BOOL librootSym = (dlsym(RTLD_DEFAULT, "libroot_dyn_jbrootpath") != NULL);
    return [NSString stringWithFormat:@"symbol=%@ jbroot=%@ libroot=%@",
            symbolFound ? @"YES" : @"NO",
            jbrootSym ? @"YES" : @"NO",
            librootSym ? @"YES" : @"NO"];
}
```

- errno 解释（放文件前部）:

```objc
NSString *CLDiagErrnoLabel(NSInteger rc) {
    if (rc == 0)      return @"0";
    if (rc == 1)      return @"1(EPERM 权限)";
    if (rc == 2)      return @"2(ENOENT 无此文件)";
    if (rc == 13)     return @"13(EACCES 权限拒绝)";
    return [NSString stringWithFormat:@"%ld", (long)rc];
}
```

- `collectWithPolicySummary:probeSummary:completion:` 中，把：

```objc
    int jb = CLDiagCallGetJBType();
    env.jbType = CLJBTypeLabelFromCode(jb);
```

替换为：

```objc
    BOOL jbFound = NO;
    int jb = CLDiagGetJBTypeCode(&jbFound);
    env.jbType = CLJBTypeLabelFromCode(jb);
    env.jbRawCode = jb;
    env.jbProbeDetail = CLDiagJbProbeDetail(jbFound);
```

- 离线分支（`error || response == nil || ...`）内、设置 `conn` 之后追加：

```objc
    NSDictionary *probeRaw = CLDiagCallDaemonLaunchProbe();
    CLDiagDaemonLink *link = [CLDiagDaemonLink new];
    link.daemonPath = CLSanitizePathForDiag(probeRaw[@"daemon_path"]);
    link.daemonExists = [probeRaw[@"daemon_exists"] boolValue];
    link.initialPortOpen = [probeRaw[@"initial_port_open"] boolValue];
    link.logTail = [probeRaw[@"log_tail"] isKindOfClass:[NSString class]] ? probeRaw[@"log_tail"] : @"";
    report.daemonLink = link;
```

- `markdownText` 中 `# 连通性` 段之后、`# 读电量链路` 之前插入：

```objc
    CLDiagDaemonLink *dk = self.daemonLink;
    if (!c.httpReachable && dk) {
        [lines addObject:@"# daemon 启动链路（离线诊断）"];
        [lines addObject:[NSString stringWithFormat:@"daemon 路径:     %@", dk.daemonPath.length ? dk.daemonPath : @"(无法获取)"]];
        [lines addObject:[NSString stringWithFormat:@"二进制存在:      %@", dk.daemonExists ? @"YES" : @"NO"]];
        if (dk.repairResult.length) {
            [lines addObject:[NSString stringWithFormat:@"修复结果:        %@", dk.repairResult]];
            [lines addObject:[NSString stringWithFormat:@"App spawn rc:    root=%@ 非root=%@",
                              CLDiagErrnoLabel(dk.rootSpawnRc), CLDiagErrnoLabel(dk.nonrootSpawnRc)]];
            [lines addObject:[NSString stringWithFormat:@"spawn 后端口:    %@", dk.portAfterSpawn ? @"YES" : @"NO"]];
            [lines addObject:[NSString stringWithFormat:@"launchctl:       %@ rc=%@ out=\"%@\"",
                              dk.launchctlAttempted ? @"已尝试" : @"未尝试",
                              CLDiagErrnoLabel(dk.launchctlRc),
                              dk.launchctlOut ?: @""]];
            [lines addObject:[NSString stringWithFormat:@"最终端口:        %@", dk.finalPortOpen ? @"YES" : @"NO"]];
        }
        [lines addObject:@"日志尾部(aldente.log):"];
        [lines addObjectsFromArray:[self daemonLogTailLines:dk.logTail]];
        [lines addObject:@""];
    }
```

补充私有方法（放 `markdownText` 附近）：

```objc
- (NSArray<NSString *> *)daemonLogTailLines:(NSString *)tail {
    if (tail.length == 0) {
        return @[@"  (空/无日志)"];
    }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [tail componentsSeparatedByString:@"\n"]) {
        if (line.length > 0) {
            [out addObject:[NSString stringWithFormat:@"  %@", line]];
        }
    }
    return out.count ? out : @[@"  (空)"];
}
```

- [ ] **Step 4: 运行确认绿**

Run: `python3 scripts/tests/test_diagnostic_collector_markdown.py`
Expected: 全部 PASS（既有 + 新增 3 项）

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/UIKit/CLDiagnosticCollector.h ChargeLimiter/UIKit/CLDiagnosticCollector.m scripts/tests/test_diagnostic_collector_markdown.py
git commit -m "feat(diag): 离线注入 daemon 链路段并修复 jb 类型双源"
```

---

## Task 5: UI 一键修复

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m`
- Test: Modify `scripts/tests/test_diagnostics_panel_ui.py`

**Interfaces:**
- Consumes: `clRepairDaemonForApp_C`（extern 声明）、`CLL(@"修复 daemon 启动")` 等（Task 提供中文键）、`CLDiagErrnoLabel`（Task 4）、`refreshEnvironmentDiagnostics`
- Produces: `repairDaemonTapped` 处理函数 + 防重入；`handleDaemonRepairResult:` 结果摘要

- [ ] **Step 1: 追加失败测试**

在 `scripts/tests/test_diagnostics_panel_ui.py` 追加：

```python
    def test_repair_daemon_button(self):
        self.assertIn("修复 daemon 启动", self.src)
        self.assertIn("repairDaemonTapped", self.src)
        self.assertIn("clRepairDaemonForApp_C", self.src)
```

- [ ] **Step 2: 运行确认红**

Run: `python3 scripts/tests/test_diagnostics_panel_ui.py`
Expected: 新增 1 项 FAIL

- [ ] **Step 3: 实现**

顶部（`#import` 区之后、class 外）声明：

```objc
extern NSDictionary *clRepairDaemonForApp_C(void);
```

`setupContent` 的 `diagnosticsCard` 内（`addTipRowToCard:diagnosticsCard ...` 前）插入：

```objc
[diagnosticsCard addPickerRowWithIcon:@"arrow.clockwise.circle"
                                title:CLL(@"修复 daemon 启动") value:CLL(@"修复")
                                color:[UIColor systemOrangeColor] tag:315
                               target:self action:@selector(repairDaemonTapped)];
```

关联对象防重入（文件已 `#import <objc/runtime.h>`）：

```objc
static char kCLDaemonRepairRunningKey;
static BOOL CLDaemonRepairRunning(id self) {
    return [objc_getAssociatedObject(self, &kCLDaemonRepairRunningKey) boolValue];
}
static void CLSetDaemonRepairRunning(id self, BOOL running) {
    objc_setAssociatedObject(self, &kCLDaemonRepairRunningKey, @(running), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
```

`copyFullDiagnosticTapped:` 之后追加：

```objc
- (void)repairDaemonTapped {
    if (CLDaemonRepairRunning(self)) {
        return;
    }
    CLSetDaemonRepairRunning(self, YES);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = clRepairDaemonForApp_C() ?: @{};
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }
            CLSetDaemonRepairRunning(self, NO);
            [self handleDaemonRepairResult:result];
        });
    });
}

- (void)handleDaemonRepairResult:(NSDictionary *)result {
    NSString *verdict = result[@"repair_result"] ?: @"";
    NSString *msg;
    if ([verdict isEqualToString:@"recovered"]) {
        msg = CLL(@"修复完成：daemon 已在线");
    } else if ([verdict isEqualToString:@"already_up"]) {
        msg = CLL(@"daemon 已在运行");
    } else if ([verdict isEqualToString:@"path_missing"]) {
        msg = CLL(@"未找到 daemon 二进制，请重装包");
    } else {
        NSInteger r = [result[@"root_spawn_rc"] integerValue];
        NSInteger nr = [result[@"nonroot_spawn_rc"] integerValue];
        if (nr < 0) { nr = 0; }
        msg = [NSString stringWithFormat:@"%@ root=%@ nonroot=%@",
               CLL(@"仍不在线（见下方诊断报告）"),
               CLDiagErrnoLabel(r), CLDiagErrnoLabel(nr)];
    }
    if (![result[@"log_tail"] length]) {
        msg = [msg stringByAppendingString:@"\n(日志为空：未进 serve 或不可读)"];
    }
    [self presentInfoAlertWithTitle:CLL(@"修复") message:msg];
    [self refreshEnvironmentDiagnostics];
}
```

- [ ] **Step 4: 运行确认绿**

Run: `python3 scripts/tests/test_diagnostics_panel_ui.py`
Expected: 新增 1 项 PASS（既有 PASS）

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m scripts/tests/test_diagnostics_panel_ui.py
git commit -m "feat(ui): 高级设置新增「修复 daemon 启动」入口"
```

---

## Task 6: 本地化（zh-Hans + en 同步）

**Files:**
- Modify: `ChargeLimiter/zh-Hans.lproj/Localizable.strings`
- Modify: `ChargeLimiter/en.lproj/Localizable.strings`
- Test: Modify `scripts/tests/test_diagnostics_panel_ui.py`

**Interfaces:**
- Consumes: Task 5 引用的 `CLL(@"...")` 中文键
- Produces: 两份一致的中文键→文案

- [ ] **Step 1: 追加失败测试**

```python
    def test_repair_localization_keys(self):
        for key in ("修复 daemon 启动", "修复", "修复完成：daemon 已在线",
                    "daemon 已在运行", "未找到 daemon 二进制，请重装包",
                    "仍不在线（见下方诊断报告）"):
            self.assertIn(f'"{key}"', self.zh, f"zh missing {key}")
            self.assertIn(f'"{key}"', self.en, f"en missing {key}")
```

- [ ] **Step 2: 运行确认红**

Run: `python3 scripts/tests/test_diagnostics_panel_ui.py`
Expected: 新增项 FAIL（6 键两边都缺）

- [ ] **Step 3: 实现**

`zh-Hans.lproj/Localizable.strings` 追加：

```
"修复 daemon 启动" = "修复 daemon 启动";
"修复" = "修复";
"修复完成：daemon 已在线" = "修复完成：daemon 已在线";
"daemon 已在运行" = "daemon 已在运行";
"未找到 daemon 二进制，请重装包" = "未找到 daemon 二进制，请重装包";
"仍不在线（见下方诊断报告）" = "仍不在线（见下方诊断报告）";
```

`en.lproj/Localizable.strings` 追加：

```
"修复 daemon 启动" = "Repair daemon launch";
"修复" = "Repair";
"修复完成：daemon 已在线" = "Repair done: daemon online";
"daemon 已在运行" = "Daemon already running";
"未找到 daemon 二进制，请重装包" = "Daemon binary not found, reinstall the package";
"仍不在线（见下方诊断报告）" = "Still offline (see diagnostic report below)";
```

> 若项目实际有两种 key 风格（部分中文键、部分英文键），以现有 `test_localization_extracted.py` 的断言方式为准，保持新键与相邻现有键风格一致。

- [ ] **Step 4: 运行确认绿**

Run: `python3 scripts/tests/test_diagnostics_panel_ui.py`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChargeLimiter/zh-Hans.lproj/Localizable.strings ChargeLimiter/en.lproj/Localizable.strings
git commit -m "feat(i18n): 修复 daemon 相关中英文文案"
```

---

## Task 7: 全量回归 + 用户侧编译验证

**Files:** 无（纯验证）

- [ ] **Step 1: 运行全部扫描测试**

```bash
python3 scripts/tests/test_daemon_link_bridge.py
python3 scripts/tests/test_diagnostic_collector_markdown.py
python3 scripts/tests/test_diagnostics_panel_ui.py
python3 -m unittest discover -s scripts/tests -p "test_*.py"
```
Expected: 全绿；若有新增 FAIL 是未实现任务，按任务序补齐。

- [ ] **Step 2: 用户侧编译验证（合并前必做）**

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64
# 同命令换 scheme：ChargeLimiter rootless、ChargeLimiter roothide（若存在）
```
Expected: BUILD SUCCEEDED × 3

- [ ] **Step 3: 冒烟（能上车则上车）**

装 roothide 包 → 打开 App → 若离线点「修复 daemon 启动」→ 观察结果摘要 → 复制完整诊断，核对 `# daemon 启动链路（离线诊断）` 段与 jb 双源行。失败设备样本回填 spec 判定树。

## Self-Review

**1. Spec 覆盖**
- C1 只读探针 → Task 2 ✅
- C2 自愈全链（always/kill/spawn/launchctl 备选路径、日志尾部、repair_result）→ Task 3 ✅
- C3 模型 + 离线链路段 + errno 表 + jb 双源 → Task 4 ✅
- C4 UI 按钮 + 防重入 + 结果摘要 → Task 5 ✅
- C5 本地化 → Task 6 ✅
- 测试与分工 / 编译验证 → Task 7 ✅

**2. Placeholder 检查**
- 无 TBD；每个代码步骤都含具体实现。全部函数名/键名在任务间互相可查。

**3. 类型/命名一致性**
- `clRepairDaemonForApp_C` / `clDaemonLaunchProbe_C` / `getLogPath_C`：App 侧 dlsym 与 extern 一致 ✅
- `CLDiagDaemonLink` 属性名（`daemonPath/daemonExists/initialPortOpen/rootSpawnRc/nonrootSpawnRc/portAfterSpawn/launchctlAttempted/launchctlRc/launchctlOut/finalPortOpen/repairResult/logTail`）在 header / markdown / controller 一致 ✅
- `CLDiagErrnoLabel` 在 collector 定义、header 导出、controller 复用一致 ✅
- 中文键（修复 daemon 启动 / 修复 / 修复完成：daemon 已在线 / daemon 已在运行 / 未找到 daemon 二进制，请重装包 / 仍不在线（见下方诊断报告））在 UI 与 zh/en strings 一致 ✅
- utils.mm 内辅助函数名（`CLDaemonPathForApp/CLDaemonJbRootPath/CLReadDaemonLogTail`）在 Task1-3 一致 ✅