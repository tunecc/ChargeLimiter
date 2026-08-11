# Configurable File Log Level Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared `normal`/`error` file-log level setting in Advanced Settings that filters only `aldente.log` while preserving system logs and the full diagnostic report.

**Architecture:** A tiny C policy header owns the stable value normalization and severity decision so it can be compiled and tested without iOS runtime dependencies. `utils.mm` keeps an atomic per-process mode cache, refreshes it whenever `CLSettingsStore` writes or reloads the shared plist, and makes `NSFileErrorLog`/`NSFileInfoLog` pass through one severity-aware writer. The daemon and App continue using the existing shared configuration IPC and rollback path; the UI reads the shared key, defaults missing/unknown values to `normal`, and reuses the existing picker action sheet.

**Tech Stack:** Objective-C/Objective-C++, UIKit, Foundation plist storage, existing `CLAPIClient` HTTP IPC, C11 test harness compiled with Xcode clang, Python `unittest` discovery.

## Global Constraints

- Do not add a separate “详细诊断日志” switch.
- The only persisted key is `log_level`; values are exactly `normal` and `error`.
- The setting filters `aldente.log` only; `NSLog2`/`os_log` and the full diagnostic report remain unchanged.
- Unknown or missing values normalize to `normal`.
- Preserve existing config rollback/`Save Failed` semantics and do not log configuration keys or values.
- Preserve rootful, rootless, roothide, and TrollStore path behavior and the 256 KiB log rotation limit.
- Update English and Simplified Chinese localization entries together.
- Do not touch unrelated dirty files in the main checkout or add build artifacts, `out/`, or signed packages.

---

### Task 1: Add A Compilable Log Policy Contract

**Files:**
- Create: `ChargeLimiter/CLFileLogPolicy.h`
- Create: `tests/test_file_log_policy.c`
- Create: `tests/test_file_log_policy.py`

**Interfaces:**
- Produces `CLFileLogModeFromCString(const char *)` returning `CLFileLogModeErrorOnly` only for the literal `"error"`, otherwise `CLFileLogModeNormal`.
- Produces `CLFileLogShouldWrite(CLFileLogMode, CLFileLogSeverity)` returning true for errors at either mode and for informational entries only in normal mode.

- [ ] **Step 1: Write the failing executable test.**

  Create `tests/test_file_log_policy.c` with hand-derived assertions for `NULL`, `""`, `"normal"`, `"error"`, and an unknown value, plus both severities at both modes. Include `../ChargeLimiter/CLFileLogPolicy.h` so the test names the production API rather than duplicating its logic.

- [ ] **Step 2: Add the Python discovery wrapper and run it to verify RED.**

  `tests/test_file_log_policy.py` must compile the C file with `xcrun clang -std=c11 -I ChargeLimiter` into a temporary directory and run the executable. Run:

  ```bash
  python3 -m unittest tests.test_file_log_policy -v
  ```

  Expected: FAIL during compilation because `ChargeLimiter/CLFileLogPolicy.h` and its declarations do not yet exist.

- [ ] **Step 3: Implement the minimal pure C policy header.**

  Define the two enums and `static inline` functions with no Foundation dependency. Use `strcmp` only for the stable `error` value and make the default branch normal.

- [ ] **Step 4: Run the focused test to verify GREEN.**

  ```bash
  python3 -m unittest tests.test_file_log_policy -v
  ```

  Expected: PASS with the compiled executable returning zero.

- [ ] **Step 5: Commit the tested policy contract.**

  ```bash
  git add ChargeLimiter/CLFileLogPolicy.h tests/test_file_log_policy.c tests/test_file_log_policy.py
  git commit -m "test(logging): define file log level policy"
  ```

### Task 2: Add Severity-Aware File Logging And Process Cache

**Files:**
- Modify: `ChargeLimiter/utils.h:43-52`
- Modify: `ChargeLimiter/utils.mm:1-30, 2870-2925, 3728-4015`

**Interfaces:**
- Adds public `void NSFileInfoLog(NSString *fmt, ...);`; `NSFileErrorLog` remains source-compatible.
- Keeps `NSFileLogWithArguments` private and changes it to accept a `CLFileLogSeverity`.
- Adds private cache helpers that accept an `id` or preferences dictionary and never call `CLSettingsStore` while path initialization is running.

- [ ] **Step 1: Re-run the policy test as the RED gate for the writer change.**

  The policy executable from Task 1 is the real boundary used by the writer. Run it before editing `utils.mm` to confirm the severity decision is green and that the next implementation work is limited to wiring this decision into file output:

  ```bash
  python3 -m unittest tests.test_file_log_policy -v
  ```

- [ ] **Step 2: Implement the atomic mode cache in `utils.mm`.**

  Include `CLFileLogPolicy.h`, initialize a process-local integer to `CLFileLogModeNormal`, and use Clang `__atomic_load_n`/`__atomic_store_n` helpers. Normalize an `NSString` only by comparing its UTF-8 string to the policy helper; invalid objects and missing keys become normal. Refresh the cache from `preferences[@"log_level"]` after `CLSettingsStore` initialization, after a successful `apply`, after rollback, and after `reloadFromDisk` reads a dictionary. Do not call `getlocalKV`, `getConfPath`, or `CLSettingsStore shared` from the cache helper.

- [ ] **Step 3: Gate only the file writer and add the info entry point.**

  Change `NSFileLogWithArguments` to receive `CLFileLogSeverity`, return before formatting/path resolution when `CLFileLogShouldWrite` rejects the entry, and preserve the existing fallback path and 256 KiB rotation behavior. Pass `CLFileLogSeverityError` from `NSFileErrorLog` and add `NSFileInfoLog` passing `CLFileLogSeverityInfo`.

- [ ] **Step 4: Run both policy and existing tests.**

  ```bash
  python3 -m unittest tests.test_file_log_policy tests.test_roothide_config_persistence_contract -v
  ```

  Expected: all tests pass and the existing persistence contracts remain green.

- [ ] **Step 5: Commit the logger core.**

  ```bash
  git add ChargeLimiter/utils.h ChargeLimiter/utils.mm tests/test_file_log_policy.py
  git commit -m "feat(logging): filter file logs by severity"
  ```

### Task 3: Wire Shared Configuration Defaults And Daemon Refresh

**Files:**
- Modify: `ChargeLimiter/daemon.mm:2762-2857, 3463-3540, 3633-3729, 3807-3835`
- Modify: `ChargeLimiter/UIKit/CLAPIClient.m:250-300`

**Interfaces:**
- `log_level` is treated as a daemon string key and is included in reset/default dictionaries with value `@"normal"`.
- Existing `set_conf` persists the key through `setLocalString`, which refreshes the daemon cache; existing `reload_conf` refreshes it through `reloadLocalKVFromDisk`.
- Mock config includes `@"log_level": @"normal"` so the UI has the same contract in mock builds.

- [ ] **Step 1: Re-run the policy default tests before configuration wiring.**

  The compiled policy test already covers missing and unknown values normalizing to `normal`; run it before editing daemon configuration so a later failure can only come from the key registration/default path:

  ```bash
  python3 -m unittest tests.test_file_log_policy -v
  ```

- [ ] **Step 2: Register and default the daemon key.**

  Add `@"log_level"` to `gConfStringKeys`; add `@"log_level": @"normal"` to `initConf` defaults and reset defaults. Leave all existing key type conversions unchanged.

- [ ] **Step 3: Add the mock default.**

  Add the same key/value to `CLAPIClient`’s mock configuration dictionary without changing mock request semantics.

- [ ] **Step 4: Verify configuration and persistence tests.**

  ```bash
  python3 -m unittest discover -s tests -p 'test_*.py' -v
  ```

  Expected: all tests pass; no test should expose configuration values in diagnostics.

- [ ] **Step 5: Commit shared configuration wiring.**

  ```bash
  git add ChargeLimiter/daemon.mm ChargeLimiter/UIKit/CLAPIClient.m tests
  git commit -m "feat(settings): persist log level in shared config"
  ```

### Task 4: Add The Advanced Settings Picker And Localizations

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m:1-20, 554-562, 1673-2067, 2098-2115`
- Modify: `ChargeLimiter/en.lproj/Localizable.strings:192-196`
- Modify: `ChargeLimiter/zh-Hans.lproj/Localizable.strings:192-196`

**Interfaces:**
- Adds an unused picker tag `316` and a `logLevelText` helper that reads `getlocalKV_C(@"log_level")` and maps only `error` to “仅错误”; all other values display “标准”.
- Adds `-logLevelTapped:` using the existing `UIAlertControllerStyleAlert` picker pattern, writing `@"error"` or `@"normal"` through `CLAPIClient setConfigWithKey:value:completion:` and reloading the row after completion.
- Declares the existing C wrappers `getlocalKV_C` and `setlocalKV_C` locally, matching `CLSettingsViewController`’s established UIKit-target pattern.

- [ ] **Step 1: Re-run the policy normalization test before the UIKit edit.**

  UIKit cannot be linked in the repository's host-side test harness. The display helper will use the same literal mapping as the already-tested policy function, so run the policy executable before editing the controller and use the affected-scheme build plus the device smoke test as the UI verification boundary:

  ```bash
  python3 -m unittest tests.test_file_log_policy -v
  ```

- [ ] **Step 2: Add localization entries.**

  Add the exact keys `"日志级别"`, `"标准"`, and `"仅错误"` to both string tables. English values must be `"Log Level"`, `"Normal"`, and `"Errors Only"`; Simplified Chinese values must remain the same Chinese text.

- [ ] **Step 3: Add the picker row and read/display helper.**

  Under the existing “调试与观测” section, keep the “策略诊断” row and add a separator plus a `doc.text` picker row titled `CLL(@"日志级别")`, value from `logLevelText`, tag `316`, and action `logLevelTapped:`. In `viewDidLoad`, if the key is missing or invalid, issue one existing `setConfigWithKey:@"log_level" value:@"normal"` call so legacy installs converge without a new switch.

- [ ] **Step 4: Implement the action sheet and asynchronous row refresh.**

  Present `UIAlertControllerStyleAlert` with actions in stable order: `标准` → `normal`, `仅错误` → `error`, then `取消`. On selection call the shared API and reload the content in its completion; do not log the key/value and do not alter rollback/error alert behavior.

- [ ] **Step 5: Build the App target and run tests.**

  ```bash
  xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_log_level_app CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  python3 -m unittest discover -s tests -p 'test_*.py' -v
  ```

  Expected: App compilation exits 0 and all tests pass.

- [ ] **Step 6: Commit UI and localization changes.**

  ```bash
  git add ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m ChargeLimiter/en.lproj/Localizable.strings ChargeLimiter/zh-Hans.lproj/Localizable.strings
  git commit -m "feat(ui): add file log level picker"
  ```

### Task 5: Classify Existing File Log Calls And Verify All Variants

**Files:**
- Modify: `ChargeLimiter/utils.mm:1062-1080`
- Modify: `ChargeLimiter/daemon.mm:4260-4435`
- Modify: `ChargeLimiter/daemon.mm:3807-3835`
- Test: `tests/test_file_log_policy.py`

**Interfaces:**
- `path_init`, detailed `daemon_entry`, `daemon_paths`, and `daemon_privilege` remain available through `NSLog2` but stop inflating `aldente.log`.
- Successful `listen_ready`, a concise `daemon_started` summary, and successful `config_reload` use `NSFileInfoLog`; bind/startup failures, exceptions, fallback writes, and unexpected exits remain `NSFileErrorLog`.
- No log line includes configuration keys/values or random `.jbroot-*` tokens.

- [ ] **Step 1: Re-run the policy executable before changing call sites.**

  ```bash
  python3 -m unittest tests.test_file_log_policy -v
  ```

  This confirms both severity branches are covered before call-site classification changes.

- [ ] **Step 2: Migrate informational calls and keep failures at error severity.**

  Replace only the successful informational calls listed above; keep exception and failure calls on `NSFileErrorLog`. Shorten successful listener output to a stable backend/port summary and add the post-listener `daemon_started` info line.

- [ ] **Step 3: Run the complete test and build matrix.**

  ```bash
  python3 -m unittest discover -s tests -p 'test_*.py' -v
  xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_log_level_rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter rootless" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_log_level_rootless CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter roothide" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_log_level_roothide CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  xcodebuild -project ChargeLimiter.xcodeproj -scheme ChargeLimiterDaemon -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_log_level_daemon CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  xcodebuild -project ChargeLimiter.xcodeproj -scheme ChargeLimiterDaemon_rootless -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_log_level_daemon_rootless CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  xcodebuild -project ChargeLimiter.xcodeproj -scheme ChargeLimiterDaemon_roothide -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_log_level_daemon_roothide CODE_SIGNING_ALLOWED=NO ARCHS=arm64
  ```

  Expected: all six affected schemes compile with `CODE_SIGNING_ALLOWED=NO`; build directories remain untracked and are removed after verification if needed.

- [ ] **Step 4: Commit call-site classification.**

  ```bash
  git add ChargeLimiter/utils.mm ChargeLimiter/daemon.mm tests/test_file_log_policy.c tests/test_file_log_policy.py
  git commit -m "refactor(logging): classify startup file logs"
  ```

### Task 6: Final Review And Manual Handoff

**Files:**
- Review: all files changed by Tasks 1-5

- [ ] **Step 1: Run `git diff --check` and inspect the complete diff.**

  Confirm no unrelated files, config values, `.jbroot-*` tokens, diagnostic-report changes, or separate detailed-log switch were introduced.

- [ ] **Step 2: Run the full verification commands again.**

  Re-run the complete Python test suite and all six schemes from Task 5 after the final diff is stable. Record exit code 0 for every command before claiming completion.

- [ ] **Step 3: Perform the device smoke test.**

  Install the roothide package, open Advanced Settings, verify the default display is “标准”, select “仅错误”, reproduce one daemon restart, confirm new `aldente.log` entries omit `daemon_paths`/privilege details but retain errors, switch back to “标准”, and confirm `listen_ready`/`daemon_started` appear. Copy the full diagnostic report and verify its config persistence and battery sections are unchanged.

- [ ] **Step 4: Commit only if all checks are green and report the commit IDs.**

  ```bash
  git status -sb
  git log -5 --oneline
  ```

  Leave generated build artifacts untracked/removed and report any device-only observations separately from build evidence.
