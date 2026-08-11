# Relaxin roothide Config Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore configuration persistence on Relaxin roothide and add a copyable diagnostic chain proving that the App wrote the same plist the daemon loaded.

**Architecture:** Refactor `ensureAppPathsWithLibroot()` into resolution, fallback, and one unconditional finalization path. Keep the shared-plist architecture, validate every successful write by parsing it back, expose metadata-only diagnostics from `utils.mm`, and have the daemon and existing diagnostic collector report both process views without exposing configuration values.

**Tech Stack:** Objective-C++, Objective-C, Foundation property lists, POSIX `stat`/`access`, existing localhost daemon API, Python `unittest` source-contract regression tests, Xcode iOS schemes, existing package build script.

## Global Constraints

- Preserve rootful, rootless, roothide, and TrollStore storage strategies.
- Do not replace the shared plist with a new IPC configuration protocol.
- Do not migrate, delete, or reset user configuration.
- Do not recursively change shared-directory permissions.
- Do not log configuration keys or values; diagnostics contain paths and file metadata only.
- Keep the current `CLSettingsStore.apply` rollback behavior on write failure.
- Preserve and deliberately integrate the existing uncommitted `utils.mm` non-atomic fallback and `daemon.mm` path log; do not overwrite them.
- Never stage or commit `ex/`, `out/`, `build_rootful/`, `build_rootless/`, `build_roothide/`, or signed artifacts.
- Before each commit, inspect `git diff --cached --name-only` and verify it contains only the files listed by that task.

---

## File Structure

- Create: `tests/test_roothide_config_persistence_contract.py`
  - Guards the control-flow regression, write verification, diagnostic API contract, and report redaction contract.
- Modify: `ChargeLimiter/utils.mm`
  - Owns path resolution/finalization, config write/readback validation, file metadata, and process-local last-write diagnostics.
- Modify: `ChargeLimiter/utils.h`
  - Exposes `getConfigPersistenceDiagnostics_C()` to the App diagnostic collector and daemon.
- Modify: `ChargeLimiter/daemon.mm`
  - Adds daemon-side config metadata to `get_diag` and records `reload_conf` disk-read results.
- Modify: `ChargeLimiter/UIKit/CLDiagnosticCollector.h`
  - Adds the typed configuration-persistence diagnostic model.
- Modify: `ChargeLimiter/UIKit/CLDiagnosticCollector.m`
  - Collects both process views, compares canonical paths, sanitizes output, and renders the Markdown report section.

No project-file change is required because `utils.mm`, `daemon.mm`, and `CLDiagnosticCollector.m` are already included in all relevant targets.

### Task 1: Restore Path Finalization and Validate Config Writes

**Files:**
- Create: `tests/test_roothide_config_persistence_contract.py`
- Modify: `ChargeLimiter/utils.mm:20-53, 994-1061, 1333-1406`
- Modify: `ChargeLimiter/utils.h:107-136`

**Interfaces:**
- Consumes: `resolveAppDocumentsPath()`, `getSharedDataRootPathWithLibroot()`, `getConfigRootPathWithLibroot()`, `resolveJbRootFromSelfExe()`, `getConfPath()`.
- Produces: `extern "C" NSDictionary* getConfigPersistenceDiagnostics_C(void)` with metadata-only keys documented below.
- Produces: path initialization source values `libroot`, `libroothide`, `sandbox`, and `exe-fallback`.
- Produces: write stages `never`, `invalid_path`, `mkdir_failed`, `atomic_verified`, `direct_verified`, `verify_failed`, and `write_failed`.

- [ ] **Step 1: Write the failing source-contract tests**

Create `tests/test_roothide_config_persistence_contract.py`:

```python
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
COLLECTOR_H = ROOT / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.h"
COLLECTOR_M = ROOT / "ChargeLimiter" / "UIKit" / "CLDiagnosticCollector.m"


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated function: {signature}")


class ConfigPersistenceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()
        cls.daemon_mm = DAEMON_MM.read_text()
        cls.collector_h = COLLECTOR_H.read_text()
        cls.collector_m = COLLECTOR_M.read_text()

    def test_path_finalization_runs_after_resolution_branch(self):
        body = function_body(self.utils_mm, "static void ensureAppPathsWithLibroot()")
        failure_branch = body.index("if (!appDoc || !sharedDataRoot || !configRoot)")
        finalization = body.index("// Finalize primary and fallback paths through one exit")
        assignment = body.index("g_confPath =", finalization)
        self.assertLess(failure_branch, finalization)
        self.assertLess(finalization, assignment)

    def test_direct_write_is_verified_before_success(self):
        signature = "static BOOL writeConfigDataToDiskWithLibroot(NSData* plistData, NSString** pathOut, NSError** errorOut) {"
        body = function_body(self.utils_mm, signature)
        self.assertIn("verifyWrittenConfigData", body)
        direct = body.index("NSDataWritingFileProtectionNone")
        verified = body.index("verifyWrittenConfigData", direct)
        direct_success = body.index("return YES", verified)
        self.assertLess(direct, verified)
        self.assertLess(verified, direct_success)

    def test_config_diagnostics_wrapper_is_declared(self):
        declaration = 'extern "C" NSDictionary* getConfigPersistenceDiagnostics_C(void);'
        self.assertIn(declaration, self.utils_h)
        self.assertIn("getConfigPersistenceDiagnostics_C(void)", self.utils_mm)

    def test_diagnostics_do_not_export_config_values(self):
        forbidden = ["config_values", "preferences_dump", "plist_contents"]
        combined = self.utils_mm + self.daemon_mm + self.collector_m
        for token in forbidden:
            self.assertNotIn(token, combined)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test and confirm the regression is reproduced**

Run:

```bash
python3 -m unittest tests/test_roothide_config_persistence_contract.py -v
```

Expected: FAIL in `test_path_finalization_runs_after_resolution_branch` because the marker is absent and current path assignment remains inside the failure branch. The diagnostics wrapper and write-verification tests also fail.

- [ ] **Step 3: Add process-local diagnostic state and metadata helpers**

In `ChargeLimiter/utils.mm`, add globals beside the existing path globals:

```objective-c
static NSString* g_pathResolutionSource = @"uninitialized";
static NSDictionary* g_lastConfigWriteDiagnostics = nil;
```

Add the following focused helpers before `writeConfigDataToDiskWithLibroot`:

```objective-c
static NSDictionary* configPathMetadata(NSString* path) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    out[@"config_path"] = path ?: @"";
    NSString* parent = path.length > 0 ? path.stringByDeletingLastPathComponent : @"";
    out[@"config_parent_path"] = parent;
    out[@"config_parent_writable"] = @(parent.length > 0 && access(parent.fileSystemRepresentation, W_OK) == 0);

    struct stat st = {};
    if (path.length > 0 && stat(path.fileSystemRepresentation, &st) == 0) {
        out[@"config_exists"] = @YES;
        out[@"config_size"] = @(st.st_size);
        out[@"config_mtime"] = @(st.st_mtime);
        out[@"config_mode"] = @(st.st_mode & 07777);
        out[@"config_owner_uid"] = @(st.st_uid);
        out[@"config_group_gid"] = @(st.st_gid);
    } else {
        out[@"config_exists"] = @NO;
        out[@"config_size"] = @0;
        out[@"config_mtime"] = @0;
        out[@"config_mode"] = @(-1);
        out[@"config_owner_uid"] = @(-1);
        out[@"config_group_gid"] = @(-1);
    }
    return out;
}

static void recordConfigWriteDiagnostics(NSString* stage, NSError* error, int savedErrno, BOOL verified) {
    @synchronized(NSFileManager.defaultManager) {
        g_lastConfigWriteDiagnostics = @{
            @"last_write_stage": stage ?: @"unknown",
            @"last_write_error_domain": error.domain ?: @"",
            @"last_write_error_code": @(error ? error.code : 0),
            @"last_write_errno": @(savedErrno),
            @"last_write_verified": @(verified),
        };
    }
}

static BOOL verifyWrittenConfigData(NSString* path, NSError** errorOut) {
    NSData* data = [NSData dataWithContentsOfFile:path options:0 error:errorOut];
    if (data.length == 0) {
        return NO;
    }
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:&format
                                                           error:errorOut];
    if ([plist isKindOfClass:[NSDictionary class]]) {
        return YES;
    }
    if (errorOut && *errorOut == nil) {
        *errorOut = [NSError errorWithDomain:@"ChargeLimiter"
                                        code:-3
                                    userInfo:@{NSLocalizedDescriptionKey: @"Written config is not a dictionary plist"}];
    }
    return NO;
}
```

Do not add duplicate POSIX includes: `utils.h` already imports `common.h`, which supplies `<sys/stat.h>` and `<unistd.h>`.

- [ ] **Step 4: Restore the single finalization path**

Restructure `ensureAppPathsWithLibroot()` so only fallback selection is inside the failure branch and the existing directory creation/global assignment block follows it:

```objective-c
BOOL usedFallback = NO;
if (!appDoc || !sharedDataRoot || !configRoot) {
    NSLog2(@"[CL] CRITICAL: Path resolution failed. appDoc=%@ sharedDataRoot=%@ configRoot=%@",
           appDoc, sharedDataRoot, configRoot);
    if (getJBType() == JBTYPE_ROOTHIDE) {
        NSString* exeJbRoot = resolveJbRootFromSelfExe();
        NSString* exeSharedRoot = exeJbRoot.length > 0
            ? [exeJbRoot stringByAppendingPathComponent:@"var/mobile/ChargeLimiter"]
            : nil;
        if (exeSharedRoot.length == 0) {
            NSLog2(@"[CL] roothide exe-jbroot fallback failed: exeJbRoot=%@", exeJbRoot ?: @"(nil)");
            return;
        }
        appDoc = exeSharedRoot;
        sharedDataRoot = exeSharedRoot;
        configRoot = exeSharedRoot;
        usedFallback = YES;
    } else {
        NSString* fallback = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        appDoc = appDoc ?: fallback;
        sharedDataRoot = sharedDataRoot ?: fallback;
        configRoot = configRoot ?: fallback;
        usedFallback = YES;
    }
}

// Finalize primary and fallback paths through one exit
if (appDoc.length == 0 || sharedDataRoot.length == 0 || configRoot.length == 0) {
    NSLog2(@"[CL] CRITICAL: Refusing incomplete paths after fallback");
    return;
}

NSFileManager* fm = [NSFileManager defaultManager];
for (NSString* dir in @[appDoc, sharedDataRoot, configRoot]) {
    NSError* mkdirError = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
        NSLog2(@"[CL] CRITICAL: Path directory create failed path=%@ error=%@", dir, mkdirError);
        return;
    }
}

g_appDocumentsPath = appDoc;
g_runtimeDataRootPath = sharedDataRoot;
g_logPath = [sharedDataRoot stringByAppendingPathComponent:@LOG_FILENAME];
g_confPath = [configRoot stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME];
g_dbPath = [sharedDataRoot stringByAppendingPathComponent:@DB_FILENAME];
if (usedFallback) {
    g_pathResolutionSource = @"exe-fallback";
} else if (getJBType() == JBTYPE_ROOTHIDE) {
    g_pathResolutionSource = @"libroothide";
} else if (getJBType() == JBTYPE_TROLLSTORE) {
    g_pathResolutionSource = @"sandbox";
} else {
    g_pathResolutionSource = @"libroot";
}
NSFileErrorLog(@"path_init source=%@ pid=%d uid=%d euid=%d gid=%d egid=%d conf=%@ log=%@ db=%@",
               g_pathResolutionSource, getpid(), getuid(), geteuid(), getgid(), getegid(),
               g_confPath, g_logPath, g_dbPath);
cleanupLegacyContainerCacheFilesIfNeeded();
```

Also reset `g_pathResolutionSource` to `@"uninitialized"` in `setAppDocumentsPathOverride()` where the other path globals are reset.

- [ ] **Step 5: Validate atomic and direct writes before returning success**

In `writeConfigDataToDiskWithLibroot`, record each early failure. After either write succeeds, call `verifyWrittenConfigData`; only set `pathOut` and return `YES` after verification:

```objective-c
NSError* verifyError = nil;
if ([plistData writeToFile:confPath options:NSDataWritingAtomic error:&writeError]) {
    if (verifyWrittenConfigData(confPath, &verifyError)) {
        recordConfigWriteDiagnostics(@"atomic_verified", nil, 0, YES);
        if (pathOut) *pathOut = confPath;
        return YES;
    }
    recordConfigWriteDiagnostics(@"verify_failed", verifyError, errno, NO);
    if (errorOut) *errorOut = verifyError;
    return NO;
}

int atomicErrno = errno;
NSError* directError = nil;
if ([plistData writeToFile:confPath options:NSDataWritingFileProtectionNone error:&directError]) {
    verifyError = nil;
    if (verifyWrittenConfigData(confPath, &verifyError)) {
        recordConfigWriteDiagnostics(@"direct_verified", writeError, atomicErrno, YES);
        if (pathOut) *pathOut = confPath;
        return YES;
    }
    recordConfigWriteDiagnostics(@"verify_failed", verifyError, errno, NO);
    if (errorOut) *errorOut = verifyError;
    return NO;
}

recordConfigWriteDiagnostics(@"write_failed", directError ?: writeError, errno, NO);
```

Use `invalid_path` before returning code `-2`, and `mkdir_failed` when parent creation fails. Set `pathOut` to `nil` on every failure path.

- [ ] **Step 6: Export metadata-only App/daemon diagnostics**

Add to `ChargeLimiter/utils.h`:

```objective-c
extern "C" NSDictionary* getConfigPersistenceDiagnostics_C(void);
```

Add to `ChargeLimiter/utils.mm`:

```objective-c
extern "C" NSDictionary* getConfigPersistenceDiagnostics_C(void) {
    NSMutableDictionary* out = [configPathMetadata(getConfPath()) mutableCopy];
    out[@"path_resolution_source"] = g_pathResolutionSource ?: @"uninitialized";
    @synchronized(NSFileManager.defaultManager) {
        [out addEntriesFromDictionary:g_lastConfigWriteDiagnostics ?: @{
            @"last_write_stage": @"never",
            @"last_write_error_domain": @"",
            @"last_write_error_code": @0,
            @"last_write_errno": @0,
            @"last_write_verified": @NO,
        }];
    }
    return out;
}
```

- [ ] **Step 7: Run the focused regression test**

Run:

```bash
python3 -m unittest tests/test_roothide_config_persistence_contract.py -v
```

Expected: all four tests PASS.

- [ ] **Step 8: Review and commit the storage-core task**

Run:

```bash
git diff --check -- ChargeLimiter/utils.mm ChargeLimiter/utils.h tests/test_roothide_config_persistence_contract.py
git diff -- ChargeLimiter/utils.mm ChargeLimiter/utils.h tests/test_roothide_config_persistence_contract.py
git add -- ChargeLimiter/utils.mm ChargeLimiter/utils.h tests/test_roothide_config_persistence_contract.py
git diff --cached --name-only
git commit -m "fix(roothide): restore config path initialization"
```

Expected staged names: exactly the three files listed above. The reviewed `utils.mm` diff intentionally includes the pre-existing direct-write fallback after adding readback validation.

### Task 2: Report App and Daemon Config Persistence Views

**Files:**
- Modify: `tests/test_roothide_config_persistence_contract.py`
- Modify: `ChargeLimiter/daemon.mm:1353-1429, 3785-3807, 4339-4356`
- Modify: `ChargeLimiter/UIKit/CLDiagnosticCollector.h:47-82`
- Modify: `ChargeLimiter/UIKit/CLDiagnosticCollector.m:20-107, 250-415, 419-594`

**Interfaces:**
- Consumes: `getConfigPersistenceDiagnostics_C()` from Task 1.
- Produces: daemon `get_diag.data.config_persistence` dictionary.
- Produces: daemon `reload_conf.data.config_reload` dictionary with `reload_ok`, `loaded_key_count`, and `config_path`.
- Produces: daemon `get_diag.data.config_reload` containing the most recent reload result or state `never`.
- Produces: `CLDiagConfigPersistence` and `CLDiagnosticReport.configPersistence`.

- [ ] **Step 1: Extend the failing contracts for daemon and report wiring**

Add these tests to `ConfigPersistenceContractTests`:

```python
    def test_daemon_exposes_config_persistence_and_reload_result(self):
        self.assertIn('out[@"config_persistence"]', self.daemon_mm)
        self.assertIn('out[@"config_reload"]', self.daemon_mm)
        reload_body = function_body(self.daemon_mm, "NSDictionary* handleReq(NSDictionary* nsreq) {")
        self.assertIn('@"config_reload"', reload_body)
        self.assertIn('@"loaded_key_count"', reload_body)
        self.assertIn('@"reload_ok"', reload_body)

    def test_report_has_config_persistence_section(self):
        self.assertIn("@interface CLDiagConfigPersistence", self.collector_h)
        self.assertIn("configPersistence", self.collector_h)
        self.assertIn('@"# 配置持久化链路"', self.collector_m)
        self.assertIn("CLConfigIdentityForDiag", self.collector_m)
```

- [ ] **Step 2: Run the test and confirm the new diagnostic contract fails**

Run:

```bash
python3 -m unittest tests/test_roothide_config_persistence_contract.py -v
```

Expected: the two newly added tests FAIL because the daemon response and report model are not wired yet.

- [ ] **Step 3: Add daemon config metadata and reload result**

Add process-local reload state beside the existing daemon globals:

```objective-c
static NSDictionary* g_lastConfigReloadDiagnostics = nil;
```

In `getIOPMPSServDiagnostics()`, add:

```objective-c
NSDictionary* configPersistence = getConfigPersistenceDiagnostics_C();
out[@"config_persistence"] = configPersistence ?: @{};
out[@"loaded_key_count"] = @(getAllKV().count);
out[@"config_reload"] = g_lastConfigReloadDiagnostics ?: @{
    @"state": @"never",
    @"reload_ok": @NO,
    @"loaded_key_count": @0,
    @"config_path": @"",
};
```

In the `reload_conf` branch, read the plist directly before reloading so success is evidence-based rather than inferred from the old in-memory store:

```objective-c
NSString* reloadPath = getConfPath();
NSDictionary* diskConfig = reloadPath.length > 0
    ? [NSDictionary dictionaryWithContentsOfFile:reloadPath]
    : nil;
BOOL reloadOK = [diskConfig isKindOfClass:[NSDictionary class]];
NSUInteger loadedKeyCount = reloadOK ? diskConfig.count : 0;

reloadLocalKVFromDisk();
uninitDB();
initDB(nil);
initConf(NO);
recoverSmartChargeCoordinationOnBootstrap();
refreshFullChargeScheduleTimer(0);
evaluateFullChargeSchedule(YES);

NSDictionary* reloadResult = @{
    @"state": @"reload_conf",
    @"reload_ok": @(reloadOK),
    @"loaded_key_count": @(loadedKeyCount),
    @"config_path": reloadPath ?: @"",
};
g_lastConfigReloadDiagnostics = reloadResult;
NSFileErrorLog(@"config_reload ok=%d key_count=%lu path=%@",
               reloadOK, (unsigned long)loadedKeyCount, reloadPath ?: @"(nil)");
return @{
    @"status": reloadOK ? @0 : @1,
    @"data": @{ @"config_reload": reloadResult },
};
```

Retain the existing uncommitted `daemon_paths` startup log unchanged; its `exe`, `log`, `conf`, `db`, and `dataRoot` fields already match this plan.

- [ ] **Step 4: Add the typed diagnostic model**

Add to `CLDiagnosticCollector.h`:

```objective-c
@interface CLDiagConfigPersistence : NSObject
@property (nonatomic, copy) NSString *appPath;
@property (nonatomic, copy) NSString *daemonPath;
@property (nonatomic, assign) BOOL sameCanonicalPath;
@property (nonatomic, assign) BOOL appExists;
@property (nonatomic, assign) BOOL daemonExists;
@property (nonatomic, assign) BOOL appParentWritable;
@property (nonatomic, assign) BOOL daemonParentWritable;
@property (nonatomic, assign) NSInteger appMode;
@property (nonatomic, assign) NSInteger daemonMode;
@property (nonatomic, assign) NSInteger appOwnerUID;
@property (nonatomic, assign) NSInteger appGroupGID;
@property (nonatomic, assign) NSInteger daemonOwnerUID;
@property (nonatomic, assign) NSInteger daemonGroupGID;
@property (nonatomic, assign) long long appSize;
@property (nonatomic, assign) long long daemonSize;
@property (nonatomic, assign) NSTimeInterval appModificationTime;
@property (nonatomic, assign) NSTimeInterval daemonModificationTime;
@property (nonatomic, copy) NSString *pathResolutionSource;
@property (nonatomic, copy) NSString *lastWriteStage;
@property (nonatomic, copy) NSString *lastWriteErrorDomain;
@property (nonatomic, assign) NSInteger lastWriteErrorCode;
@property (nonatomic, assign) NSInteger lastWriteErrno;
@property (nonatomic, assign) BOOL lastWriteVerified;
@property (nonatomic, assign) NSInteger daemonLoadedKeyCount;
@property (nonatomic, copy) NSString *daemonReloadState;
@property (nonatomic, assign) BOOL daemonLastReloadOK;
@end
```

Add to `CLDiagnosticReport`:

```objective-c
@property (nonatomic, strong) CLDiagConfigPersistence *configPersistence;
```

Add `@implementation CLDiagConfigPersistence @end` beside the other model implementations.

- [ ] **Step 5: Collect and compare both process views**

At the top of `CLDiagnosticCollector.m`, declare the direct wrapper:

```objective-c
extern NSDictionary *getConfigPersistenceDiagnostics_C(void);
```

Add a canonical identity helper that removes only the random jbroot prefix for comparison:

```objective-c
static NSString *CLConfigIdentityForDiag(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return @"";
    NSString *normalized = path.stringByStandardizingPath;
    NSRange marker = [normalized rangeOfString:@"/.jbroot-"];
    if (marker.location != NSNotFound) {
        NSUInteger tokenStart = marker.location + 1;
        NSRange slash = [normalized rangeOfString:@"/"
                                          options:0
                                            range:NSMakeRange(tokenStart, normalized.length - tokenStart)];
        if (slash.location != NSNotFound) {
            normalized = [@"$JBROOT" stringByAppendingString:[normalized substringFromIndex:slash.location]];
        }
    }
    if ([normalized hasPrefix:@"/private/var/"]) {
        normalized = [normalized substringFromIndex:[@"/private" length]];
    }
    return normalized;
}
```

Before sending `get_diag`, collect the App view:

```objective-c
NSDictionary *appConfig = getConfigPersistenceDiagnostics_C() ?: @{};
CLDiagConfigPersistence *config = [CLDiagConfigPersistence new];
NSString *rawAppPath = appConfig[@"config_path"] ?: @"";
config.appPath = CLSanitizePathForDiag(rawAppPath);
config.appExists = [appConfig[@"config_exists"] boolValue];
config.appParentWritable = [appConfig[@"config_parent_writable"] boolValue];
config.appMode = [appConfig[@"config_mode"] integerValue];
config.appOwnerUID = [appConfig[@"config_owner_uid"] integerValue];
config.appGroupGID = [appConfig[@"config_group_gid"] integerValue];
config.appSize = [appConfig[@"config_size"] longLongValue];
config.appModificationTime = [appConfig[@"config_mtime"] doubleValue];
config.pathResolutionSource = appConfig[@"path_resolution_source"] ?: @"uninitialized";
config.lastWriteStage = appConfig[@"last_write_stage"] ?: @"never";
config.lastWriteErrorDomain = appConfig[@"last_write_error_domain"] ?: @"";
config.lastWriteErrorCode = [appConfig[@"last_write_error_code"] integerValue];
config.lastWriteErrno = [appConfig[@"last_write_errno"] integerValue];
config.lastWriteVerified = [appConfig[@"last_write_verified"] boolValue];
report.configPersistence = config;
```

When `get_diag` returns, consume `data[@"config_persistence"]` and compare raw identities before sanitizing:

```objective-c
NSDictionary *daemonConfig = [data[@"config_persistence"] isKindOfClass:[NSDictionary class]]
    ? data[@"config_persistence"] : @{};
NSString *rawDaemonPath = daemonConfig[@"config_path"] ?: @"";
config.daemonPath = CLSanitizePathForDiag(rawDaemonPath);
config.daemonExists = [daemonConfig[@"config_exists"] boolValue];
config.daemonParentWritable = [daemonConfig[@"config_parent_writable"] boolValue];
config.daemonMode = [daemonConfig[@"config_mode"] integerValue];
config.daemonOwnerUID = [daemonConfig[@"config_owner_uid"] integerValue];
config.daemonGroupGID = [daemonConfig[@"config_group_gid"] integerValue];
config.daemonSize = [daemonConfig[@"config_size"] longLongValue];
config.daemonModificationTime = [daemonConfig[@"config_mtime"] doubleValue];
config.daemonLoadedKeyCount = [data[@"loaded_key_count"] integerValue];
NSDictionary *reload = [data[@"config_reload"] isKindOfClass:[NSDictionary class]]
    ? data[@"config_reload"] : @{};
config.daemonReloadState = reload[@"state"] ?: @"never";
config.daemonLastReloadOK = [reload[@"reload_ok"] boolValue];
NSString *appIdentity = CLConfigIdentityForDiag(rawAppPath);
NSString *daemonIdentity = CLConfigIdentityForDiag(rawDaemonPath);
config.sameCanonicalPath = appIdentity.length > 0 && [appIdentity isEqualToString:daemonIdentity];
```

When daemon is offline, retain the App-side fields and set `daemonPath` to `@"(daemon 离线)"`.

- [ ] **Step 6: Render the configuration-persistence report section**

Insert before `# 读电量链路` in `markdownText`:

```objective-c
[lines addObject:@"# 配置持久化链路"];
CLDiagConfigPersistence *p = self.configPersistence;
[lines addObject:[NSString stringWithFormat:@"App 配置路径:     %@", p.appPath.length ? p.appPath : @"(无法获取)"]];
[lines addObject:[NSString stringWithFormat:@"daemon 配置路径:  %@", p.daemonPath.length ? p.daemonPath : @"(无法获取)"]];
[lines addObject:[NSString stringWithFormat:@"规范化路径一致:   %@", p.sameCanonicalPath ? @"YES" : @"NO"]];
NSString *appMode = p.appMode >= 0 ? [NSString stringWithFormat:@"0%lo", (unsigned long)p.appMode] : @"unknown";
[lines addObject:[NSString stringWithFormat:@"App 文件状态:     exists=%@ parent_writable=%@ size=%lld mtime=%.0f mode=%@ uid=%ld gid=%ld",
                  p.appExists ? @"YES" : @"NO", p.appParentWritable ? @"YES" : @"NO",
                  p.appSize, p.appModificationTime, appMode,
                  (long)p.appOwnerUID, (long)p.appGroupGID]];
NSString *daemonMode = p.daemonMode >= 0 ? [NSString stringWithFormat:@"0%lo", (unsigned long)p.daemonMode] : @"unknown";
[lines addObject:[NSString stringWithFormat:@"daemon 文件状态:  exists=%@ parent_writable=%@ size=%lld mtime=%.0f mode=%@ uid=%ld gid=%ld",
                  p.daemonExists ? @"YES" : @"NO", p.daemonParentWritable ? @"YES" : @"NO",
                  p.daemonSize, p.daemonModificationTime, daemonMode,
                  (long)p.daemonOwnerUID, (long)p.daemonGroupGID]];
[lines addObject:[NSString stringWithFormat:@"路径解析来源:     %@", p.pathResolutionSource.length ? p.pathResolutionSource : @"unknown"]];
[lines addObject:[NSString stringWithFormat:@"最近写入:         stage=%@ verified=%@ error=%@/%ld errno=%ld",
                  p.lastWriteStage.length ? p.lastWriteStage : @"never",
                  p.lastWriteVerified ? @"YES" : @"NO",
                  p.lastWriteErrorDomain.length ? p.lastWriteErrorDomain : @"none",
                  (long)p.lastWriteErrorCode, (long)p.lastWriteErrno]];
[lines addObject:[NSString stringWithFormat:@"daemon 已加载键数: %ld", (long)p.daemonLoadedKeyCount]];
[lines addObject:[NSString stringWithFormat:@"最近 daemon 重载: state=%@ ok=%@",
                  p.daemonReloadState.length ? p.daemonReloadState : @"never",
                  p.daemonLastReloadOK ? @"YES" : @"NO"]];
[lines addObject:@""];
```

All paths pass through `CLSanitizePathForDiag`; do not render `appConfig` or `daemonConfig` using `%@`.

- [ ] **Step 7: Run the focused regression suite**

Run:

```bash
python3 -m unittest tests/test_roothide_config_persistence_contract.py -v
```

Expected: all six tests PASS.

- [ ] **Step 8: Review and commit the diagnostics task**

Run:

```bash
git diff --check -- ChargeLimiter/daemon.mm ChargeLimiter/UIKit/CLDiagnosticCollector.h ChargeLimiter/UIKit/CLDiagnosticCollector.m tests/test_roothide_config_persistence_contract.py
git diff -- ChargeLimiter/daemon.mm ChargeLimiter/UIKit/CLDiagnosticCollector.h ChargeLimiter/UIKit/CLDiagnosticCollector.m tests/test_roothide_config_persistence_contract.py
git add -- ChargeLimiter/daemon.mm ChargeLimiter/UIKit/CLDiagnosticCollector.h ChargeLimiter/UIKit/CLDiagnosticCollector.m tests/test_roothide_config_persistence_contract.py
git diff --cached --name-only
git commit -m "feat(diag): report config persistence chain"
```

Expected staged names: exactly the four files listed above. The reviewed `daemon.mm` diff intentionally includes the existing startup path diagnostic.

### Task 3: Compile and Package All Supported Variants

**Files:**
- Verify only: all files changed by Tasks 1 and 2
- Do not commit: `out/`, `build_rootful/`, `build_rootless/`, `build_roothide/`, `Payload/`

**Interfaces:**
- Consumes: all code and tests from Tasks 1 and 2.
- Produces: three successful scheme builds and an installable `ChargeLimiter_*_roothide_arm64e.deb`.

- [ ] **Step 1: Run regression tests and static checks**

Run:

```bash
python3 -m unittest tests/test_roothide_config_persistence_contract.py -v
git diff --check
```

Expected: six tests PASS and `git diff --check` prints no errors.

- [ ] **Step 2: Compile the rootful scheme**

Run:

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath /tmp/chargelimiter-config-rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64 MonkeyDevInstallOnAnyBuild=NO MonkeyDevBuildPackageOnAnyBuild=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Compile the rootless scheme**

Run:

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter rootless" -destination "generic/platform=iOS" -configuration Release -derivedDataPath /tmp/chargelimiter-config-rootless CODE_SIGNING_ALLOWED=NO THEOS_PACKAGE_SCHEME=rootless THEOS_PACKAGE_INSTALL_PREFIX=/var/jb ARCHS=arm64 MonkeyDevInstallOnAnyBuild=NO MonkeyDevBuildPackageOnAnyBuild=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Compile the native roothide scheme**

Run:

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter roothide" -destination "generic/platform=iOS" -configuration Release -derivedDataPath /tmp/chargelimiter-config-roothide CODE_SIGNING_ALLOWED=NO THEOS_PACKAGE_SCHEME=roothide THEOS_PACKAGE_INSTALL_PREFIX= ARCHS=arm64 MonkeyDevInstallOnAnyBuild=NO MonkeyDevBuildPackageOnAnyBuild=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Build release packages**

Before running, note that `./scripts/build_packages.sh` cleans known files under ignored build/output directories. Then run:

```bash
./scripts/build_packages.sh
```

Expected: successful completion and an `out/ChargeLimiter_*_roothide_arm64e.deb` artifact.

- [ ] **Step 6: Verify package contents and Git cleanliness**

Run:

```bash
dpkg-deb -c out/ChargeLimiter_*_roothide_arm64e.deb
git status --short --branch
git log -3 --oneline
```

Expected package listing includes `ChargeLimiter.app/ChargeLimiter`, `ChargeLimiter.app/ChargeLimiterDaemon`, and `Library/LaunchDaemons/com.chargelimiter.mod.plist`. Git status may still show the pre-existing untracked `ex/`, but must not show build artifacts or unexpected tracked changes.

### Task 4: Relaxin Device Validation and Feedback Loop

**Files:**
- Device install artifact: `out/ChargeLimiter_*_roothide_arm64e.deb`
- No repository file changes

**Interfaces:**
- Consumes: packaged roothide build from Task 3.
- Produces: user-observed persistence result and copied Markdown diagnostic report.

- [ ] **Step 1: Install the new roothide package**

Install the Task 3 artifact through the user's normal Relaxin package workflow. Reopen ChargeLimiter after installation.

Expected: daemon is online and battery data is visible.

- [ ] **Step 2: Validate an App-only setting**

Change App appearance, leave the settings screen, force-quit ChargeLimiter, and reopen it.

Expected:

- No `Save Failed` alert.
- The selected appearance remains after relaunch.

- [ ] **Step 3: Validate a daemon-owned setting**

Change the stop-charge threshold or another charging-policy setting, then use the existing apply action.

Expected:

- The UI retains the new value.
- The daemon remains reachable.
- The charging policy reflects the new value under the corresponding battery/power condition.

- [ ] **Step 4: Copy the complete diagnostic report**

Open Advanced Settings, run the existing complete diagnostic collection, and copy the Markdown report.

Expected `# 配置持久化链路` conditions:

```text
规范化路径一致:   YES
App 文件状态 contains: exists=YES parent_writable=YES
daemon 文件状态 contains: exists=YES
最近写入 contains: stage=atomic_verified verified=YES
daemon 已加载键数 is greater than 0
```

`direct_verified` is acceptable but indicates the atomic write failure should be retained in the report for follow-up.

- [ ] **Step 5: Classify any remaining failure without guessing**

Use the report to choose the next action:

- `App 配置路径=(无法获取)` or `stage=invalid_path`: path initialization is still failing; inspect `path_init` log source and executable-derived fallback.
- `parent_writable=NO` or error code `NSCocoaErrorDomain/513`: inspect the exact directory/file owner and package `postinst` permission repair.
- `stage=verify_failed`: preserve the file and inspect the reported write/read error; do not reset user settings.
- `规范化路径一致=NO`: compare App and daemon raw log paths after `.jbroot-*` redaction and fix only the resolver producing the divergent suffix.
- App persistence passes but daemon behavior does not: inspect `config_reload`, `loaded_key_count`, and policy diagnostics separately from storage.

Stop after three evidence-based fix attempts if the same failure remains, and report each attempted hypothesis plus the latest diagnostic output.
