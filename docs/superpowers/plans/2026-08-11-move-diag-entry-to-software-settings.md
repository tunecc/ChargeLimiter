# Move 调试与观测 Entry to Software Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the `策略诊断` entry and `日志级别` picker from the Advanced Settings page into the Software Settings page, without touching the diagnostics page implementation.

**Architecture:** Copy the four related code segments (`kLogLevelPickerTag`, `logLevelText`, `logLevelTapped:`, `policyDiagnosticsTapped`) into `CLSoftwareSettingsViewController` with prefixed names, add the two rows to its `settingsCard`, remove the whole `调试与观测` card and the four now-dead segments from `CLAdvancedSettingsViewController`, and rely on the existing `configDidUpdate` notification to refresh the `日志级别` row value.

**Tech Stack:** Objective-C/Objective-C++, UIKit, existing `CLAPIClient` IPC, existing `getlocalKV_C`/`setlocalKV_C` shared-plist wrappers, Xcode iOS schemes, Python unittest.

## Global Constraints

- Do not move or refactor `CLPolicyDiagnosticsViewController` implementation; it stays in `CLAdvancedSettingsViewController.m`.
- Do not change `log_level` config key semantics, IPC, daemon refresh chain, rollback, or `Save Failed` behavior.
- Do not alter any Advanced Settings charging-policy cards other than the `调试与观测` card.
- Lower-priority: exact string keys `策略诊断`/`查看`/`日志级别`/`标准`/`仅错误`/`取消` already exist in en/zh-Hans Localizable.strings — no new localization entries.
- The two new Software Settings rows use `addNavigationRowWithIcon:` (a `CLGlassCard` method), placed between `停充预设` and `应用数据目录`.
- Never stage or commit `build_*/`, `out/`, `ex/`, or signed artifacts. Inspect `git diff --cached --name-only` before each commit — only the files listed by that task.

---

### Task 1: Add 策略诊断 and 日志级别 Rows to Software Settings

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m:4453-4790` (CLSoftwareSettingsViewController)

**Interfaces:**
- Consumes: `getlocalKV_C(NSString*)` (declared at `CLSettingsViewController.m:24`), `CLL(@"key")`, `[[CLAPIClient shared] setConfigWithKey:value:completion:]`.
- Produces: `-softwareLogLevelText` (NSString), `-softwareLogLevelTapped:(UITapGestureRecognizer*)`, `-softwarePolicyDiagnosticsTapped`, `static const NSInteger kLogLevelPickerTag = 316`, and two settings rows titled `策略诊断` / `日志级别`.
- Consumes from Task 2 (kept, not removed yet): `CLPolicyDiagnosticsViewController` class (defined at `CLAdvancedSettingsViewController.m:568`).

- [ ] **Step 1: Add the tag constant and method declarations to `CLSoftwareSettingsViewController`**

In `ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m`, inside the `@interface CLSoftwareSettingsViewController ()` block (after the existing `- (void)configDidUpdate;` declaration around line 4467), add:

```objc
static const NSInteger kLogLevelPickerTag = 316;
- (NSString *)softwareLogLevelText;
- (void)softwareLogLevelTapped:(UITapGestureRecognizer *)tap;
- (void)softwarePolicyDiagnosticsTapped;
```

> Note: `static const` in a class extension must appear before its first use in the `@implementation`. If the compiler complains about the constant's scope, move it to file scope above `@interface` (the file already does this elsewhere — `CLAdvancedSettingsViewController.m:564` declares `kLogLevelPickerTag` at file scope). Prefer file scope: add `static const NSInteger kLogLevelPickerTag = 316;` right above the `@interface CLSoftwareSettingsViewController` line at `CLSettingsViewController.m:4453`.

- [ ] **Step 2: Add the two rows to `setupSettingsCard`**

In `setupSettingsCard`, between the `停充预设` row (ends around line 4556) and the `应用数据目录` row (line 4562), insert:

```objc
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"waveform.path.ecg" title:CLL(@"策略诊断") value:CLL(@"查看") color:[UIColor systemTealColor] target:self action:@selector(softwarePolicyDiagnosticsTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"doc.text" title:CLL(@"日志级别") value:self.softwareLogLevelText color:[UIColor systemPurpleColor] target:self action:@selector(softwareLogLevelTapped:)];
```

The existing `停充预设` row ends with `[self.settingsCard addSeparator];` already; insert the block right after that separator and before the `应用数据目录` `addNavigationRowWithIcon:` call. Keep the existing separator that precedes `应用数据目录`.

- [ ] **Step 3: Implement the three methods**

Add these methods to the `@implementation CLSoftwareSettingsViewController` (place near the other picker/navigation handlers; any position in the implementation works):

```objc
- (NSString *)softwareLogLevelText {
    NSString *level = getlocalKV_C(@"log_level");
    if ([level isEqualToString:@"error"]) {
        return CLL(@"仅错误");
    }
    return CLL(@"标准");
}

- (void)softwareLogLevelTapped:(UITapGestureRecognizer *)tap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"日志级别") message:nil preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    UIAlertAction *normalAction = [UIAlertAction actionWithTitle:CLL(@"标准") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[CLAPIClient shared] setConfigWithKey:@"log_level" value:@"normal" completion:^(NSDictionary * _Nullable res, NSError * _Nullable err) {
            [weakSelf updateCardValue:weakSelf.settingsCard title:CLL(@"日志级别") value:weakSelf.softwareLogLevelText];
        }];
    }];
    [alert addAction:normalAction];

    UIAlertAction *errorAction = [UIAlertAction actionWithTitle:CLL(@"仅错误") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[CLAPIClient shared] setConfigWithKey:@"log_level" value:@"error" completion:^(NSDictionary * _Nullable res, NSError * _Nullable err) {
            [weakSelf updateCardValue:weakSelf.settingsCard title:CLL(@"日志级别") value:weakSelf.softwareLogLevelText];
        }];
    }];
    [alert addAction:errorAction];

    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)softwarePolicyDiagnosticsTapped {
    Class cls = NSClassFromString(@"CLPolicyDiagnosticsViewController");
    UIViewController *vc = [[cls alloc] init];
    if (vc) {
        [self.navigationController pushViewController:vc animated:YES];
    }
}
```

> Confirmed: this page has NO `reloadContentRows`. The correct fresher is `updateCardValue:` (`CLSettingsViewController.m:4590`), which locates the value label by `[title hash]` — and `addNavigationRowWithIcon:` (`CLSettingsViewController.m:1027`) sets `valueLabel.tag = [title hash]`, so the two are compatible.

- [ ] **Step 4: Refresh the 日志级别 row on config update**

In the existing `- (void)configDidUpdate` method (`CLSettingsViewController.m:5177`), after the `updateCardValue:` call for `停充预设` (line 5190), add:

```objc
    [self updateCardValue:self.settingsCard title:CLL(@"日志级别") value:self.softwareLogLevelText];
```

- [ ] **Step 5: Build the rootful App scheme to verify**

Run:

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_move_diag_rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64 2>&1 | tail -6
```

Expected: `** BUILD SUCCEEDED **`. Fix any compile errors (method naming, missing `reloadContentRows`, tag constant placement) until the build passes.

- [ ] **Step 6: Run the Python test suite to verify no regression**

Run:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: all tests pass (7 tests: 1 policy + 6 persistence contract).

- [ ] **Step 7: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m
git diff --cached --name-only
git commit -m "feat(ui): add 策略诊断 and 日志级别 entries to software settings"
```

Expected staged names: exactly `ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m`.

### Task 2: Remove 调试与观测 Card and Dead Segments from Advanced Settings

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m`

**Interfaces:**
- Consumes: none from Task 1 (this task removes duplicate code; both files coexist until this commit).
- Produces: Advanced Settings page without the `调试与观测` card; `CLPolicyDiagnosticsViewController` class untouched and still present.

- [ ] **Step 1: Delete the 调试与观测 card block**

In `ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m`, locate the `diagnosticsCard` construction in `setupContent` (currently lines ~1981-1988):

```objc
    CLAdvSettingsCard *diagnosticsCard = [[CLAdvSettingsCard alloc] init];
    [diagnosticsCard addSectionHeader:CLL(@"调试与观测")];
    [diagnosticsCard addPickerRowWithIcon:@"waveform.path.ecg" title:CLL(@"策略诊断") value:CLL(@"查看") color:[UIColor systemTealColor] tag:314 target:self action:@selector(policyDiagnosticsTapped)];
    [diagnosticsCard addSeparator];
    [diagnosticsCard addPickerRowWithIcon:@"doc.text" title:CLL(@"日志级别") value:self.logLevelText color:[UIColor systemTealColor] tag:kLogLevelPickerTag target:self action:@selector(logLevelTapped:)];
    [self addTipRowToCard:diagnosticsCard text:CLL(@"集中查看策略切换原因、hold 运行时参数和 Smart Charge 接管状态。")];
    [self.mainStack addArrangedSubview:diagnosticsCard];
```

Delete this entire block (from `CLAdvSettingsCard *diagnosticsCard = ...` through `[self.mainStack addArrangedSubview:diagnosticsCard];`), keeping the preceding `满充计划` card and following reset-button code.

- [ ] **Step 2: Delete the dead tag constant**

Delete `static const NSInteger kLogLevelPickerTag = 316;` at `CLAdvancedSettingsViewController.m:564`.

- [ ] **Step 3: Delete the dead methods**

Delete these methods from `@implementation CLAdvancedSettingsViewController`:
- `- (NSString *)logLevelText` (currently `CLAdvancedSettingsViewController.m:2076-2084`)
- `- (void)logLevelTapped:(UITapGestureRecognizer *)tap` (currently `~2329-2347`)
- `- (void)policyDiagnosticsTapped` (currently `~2128-2132`)

Do NOT delete the `@interface CLPolicyDiagnosticsViewController` / `@implementation CLPolicyDiagnosticsViewController` block (currently starting at lines 568/582). It stays.

- [ ] **Step 4: Grep to confirm no dangling references**

Run:

```bash
grep -n "logLevelTapped\|logLevelText\|kLogLevelPickerTag\|policyDiagnosticsTapped" ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m
```

Expected: no matches (empty output). If any remain, remove those references.

- [ ] **Step 5: Build all three App schemes**

Run each and confirm `** BUILD SUCCEEDED **`:

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_move_diag_rootful2 CODE_SIGNING_ALLOWED=NO ARCHS=arm64
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter rootless" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_move_diag_rootless CODE_SIGNING_ALLOWED=NO ARCHS=arm64
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter roothide" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_move_diag_roothide CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

Expected: all three BUILD SUCCEEDED. (`MonkeyDevInstallOnAnyBuild=NO MonkeyDevBuildPackageOnAnyBuild=NO` may be passed to keep logs clean.)

- [ ] **Step 6: Run the Python test suite**

Run:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: all 7 tests pass.

- [ ] **Step 7: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m
git diff --cached --name-only
git commit -m "refactor(ui): remove 调试与观测 card from advanced settings"
```

Expected staged names: exactly `ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m`.

### Task 3: Final Review and Full Build Matrix

**Files:**
- Review: all files changed by Tasks 1-2
- Verify only: nothing to commit

**Interfaces:**
- Consumes: the final tree after Tasks 1-2.

- [ ] **Step 1: Run `git diff --check` and inspect the complete diff**

Confirm no whitespace errors and that the diff touches only the two settings controllers. Confirm no `log_level` config/logic changes leaked in.

- [ ] **Step 2: Grep the final UI structure**

Run and confirm the entry points live only in software settings and not advanced settings:

```bash
grep -n "策略诊断\|日志级别\|logLevelTapped\|softwareLogLevel" ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m
```

Expected: `策略诊断`/`日志级别`/`softwareLogLevel*` only in `CLSettingsViewController.m`; `CLPolicyDiagnosticsViewController` still defined in `CLAdvancedSettingsViewController.m`.

- [ ] **Step 3: Run the complete verification matrix**

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
git diff --check
for scheme in "ChargeLimiter" "ChargeLimiter rootless" "ChargeLimiter roothide"; do
  echo "=== $scheme ==="
  xcodebuild -project ChargeLimiter.xcodeproj -scheme "$scheme" -destination "generic/platform=iOS" -configuration Release -derivedDataPath "/tmp/build_move_diag_final_$RANDOM" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 2>&1 | tail -2 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
done
```

Expected: 7/7 tests pass, `git diff --check` clean, and all three schemes BUILD SUCCEEDED.

- [ ] **Step 4: Verify git cleanliness**

Run `git status --short --branch`. Confirm no build artifacts are staged/tracked (the `build_*` dirs used earlier are untracked; remove them with `rm -rf build_move_diag_*` if present). `ex/` remaining untracked is expected and fine.

- [ ] **Step 5: Report commit IDs**

Run `git log --oneline -4` and report the two commit IDs from Tasks 1-2 plus the current HEAD.