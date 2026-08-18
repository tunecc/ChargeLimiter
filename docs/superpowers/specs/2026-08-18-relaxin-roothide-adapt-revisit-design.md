---
comet_change: relaxin-roothide-adapt-revisit
role: technical-design
canonical_spec: openspec
archived-with: 2026-08-18-relaxin-roothide-adapt-revisit
status: final
---

# Design Doc: Relaxin roothide 适配源码复核与验收

> 详见 OpenSpec `proposal.md`（为什么）与 `design.md`（高层复核报告 D1-D7）。本文是对高层报告的**深度技术细化**：126 根因、复核清单与判定标准、修正边界、测试策略。复核清单内联于本文 §3（每条决策给出复核清单 + 判定标准 + 修正触发条件）；独立复核报告（`docs/superpowers/reports/2026-08-18-relaxin-roothide-source-revisit.md`）按 Comet 阶段分工推迟到 verify 阶段与验收报告一起落盘，作为复核结论的可追溯归档。

## 1. Context

- **change**：`relaxin-roothide-adapt-revisit`（skip_specs=true，行为契约不变）
- **设备基线**：iPhone 15 Pro Max（iPhone16,2）/ iOS 17.1。iOS 16 已完美，不在本次范围。
- **参考源码（只读）**：`/Users/tune/Downloads/Relaxin`，不纳入本项目。
- **既有 v1.15.0 适配记录**：`docs/superpowers/plans/2026-08-11-relaxin-roothide-daemon-plist-path-fix.md`、`CHANGELOG.md` v1.15.0。
- **复核结论**（来自 open 阶段 design.md D1-D7）：v1.15.0 摸黑适配在 Relaxin 源码层面基本正确，预期代码改动极小或为零，以真机验收为主。

## 2. root persona spawn exec 126 根因（源码层面查清）

open 阶段 design.md 的 Open Question 之一已查清，结论如下。这一节消除"spawn 返回成功但 daemon 永不在线"的现象层解释。

### 调用链

ChargeLimiter App（mobile，非 root）用 `SPAWN_FLAG_ROOT` spawn daemon → `utils.mm:2453-2456` 设 `posix_spawnattr_set_persona_np(99, OVERRIDE)` + `persona_uid=0` + `persona_gid=0` → `posix_spawnp`（`utils.mm:2497`）→ 命中 Relaxin systemhook 的 `posix_spawn_hook_shared` → `spawn_exec_hook_common`（`/Users/tune/Downloads/Relaxin/Vendor/Dopamine/BaseBin/systemhook/src/common.c:100`）。

### 根因

Relaxin `common.c:209-296` 的 iOS 17 persona 处理：

1. **iOS 17 Apple 阉割了 non-root → root 的 persona 覆写**（`common.c:209` 注释）。App 是 mobile，想 spawn 成 root，系统层不再允许直接覆写。
2. systemhook 检测到 `pspi_id==99 && POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE && (uid==0 || gid==0)`，走 persona fix 路径：
   - 把 persona 的 uid/gid **改回 501（mobile）**（`common.c:261-262`），避免 `posix_spawn` 直接失败。
   - 加 `POSIX_SPAWN_START_SUSPENDED`（`common.c:265`），让子进程以 mobile 身份**暂停启动**。
   - `posix_spawn` 返回成功，父进程拿到 childPid。
3. 然后 systemhook 调用 `jbclient_persona_fix(childPid, 0, 0, resume=true)`（`common.c:369`），由 launchdhook 的 `systemwide_persona_fix`（`/Users/tune/Downloads/Relaxin/Vendor/Dopamine/BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c:998`）在内核把子进程 ucred 改成 root，再 `kill(childPid, SIGCONT)` 恢复（`jbdomain_systemwide.c:1103-1114`）。
4. **失败点**：`systemwide_persona_fix` 有多个失败分支：
   - `com.apple.private.persona-mgmt` entitlement 校验不过 → EACCES（`jbdomain_systemwide.c:1004-1014`）
   - `systemwide_validate_direct_child` 校验不过（调用方不是子进程的直接父）→ 失败（`jbdomain_systemwide.c:1034`）
   - 内核 ucred 修改失败 → 失败
   - 失败后子进程被 `SIGKILL`（`jbdomain_systemwide.c:1126`），父进程 `waitpid` 回收。
5. **与 ChargeLimiter 的相互作用**：ChargeLimiter 的 `spawn()` 用 `SPAWN_FLAG_NOWAIT`（`utils.mm:2509,2760`），立即返回 0，**不等 `jbclient_persona_fix` 完成**。若 persona fix 失败，子进程被 SIGKILL，父进程看到的 spawn rc 仍是 0，但 daemon 永不在线 —— 这就是"spawn 成功但 daemon 离线/126"的真因。

### 为什么 v1.15.0 的修复有效

v1.15.0 改为 roothide 下非 root spawn（`utils.mm:2764`：`jbType != JBTYPE_ROOTHIDE` 才加 `SPAWN_FLAG_ROOT`），靠 daemon 二进制的 setuid 位（postinst `chmod +s`）+ `platformize_me()` → `setuid(0)` 提权。这条路径**绕开整条 persona fix 链**：
- spawn 不带 persona 99，systemhook 的 persona fix 分支不触发。
- daemon 进程 checkin 时，Relaxin `jbdomain_systemwide.c` 的 S_ISUID 分支（`stat` 检测 setuid 位）按文件 uid 设置进程 euid/svuid，内核侧直接提权，无需 persona fix。

**结论**：既有修复正确，保留。本节作为"知其所以然"记录，不改变 D2 决策。

## 3. 深度设计决策（D1-D7 细化）

每条决策给出：**复核清单**（具体核对什么）、**判定标准**（通过/不通过）、**修正触发条件**（什么情况下要改）。完整复核清单见复核报告。

### D1: postinst plist Program 路径解析 — 保留

- **复核清单**：
  - `Package_roothide/DEBIAN/postinst` 用 `jbroot "$DAEMON_BIN"` 解析真实路径
  - 校验解析结果匹配 `*/.jbroot-*/Applications/ChargeLimiter.app/ChargeLimiterDaemon`（postinst 已有 case 校验）
  - `plutil -replace Program` 与 `ProgramArguments.0` 均写入真实路径
  - `launchctl bootout system` + `bootout user/foreground` + `bootstrap system` 顺序
- **判定标准**：postinst 在 Relaxin 真机执行后，`plutil -extract Program raw` 返回 `.jbroot-<brand>` 真实路径，`launchctl print system/com.chargelimiter.mod` 显示 running。
- **修正触发**：若 Relaxin 未来版本改变 system 域 launchd 命名空间（看不到 jbroot 路径），需重新评估。当前开源快照 `RLXBootstrapFinalizer.m` 命名空间设计未变，不触发。

### D2: roothide 下 spawn 避开 root persona — 保留（126 根因见 §2）

- **复核清单**：
  - `restartDaemonForApp_C`（`utils.mm:2764`）`jbType != JBTYPE_TROLLSTORE && jbType != JBTYPE_ROOTHIDE` 才加 `SPAWN_FLAG_ROOT`
  - `clRepairDaemonForApp_C`（`utils.mm:3051`）同条件
  - daemon 二进制有 setuid 位（postinst `chmod +s "$APP_DIR/ChargeLimiterDaemon"`）
  - `platformize_me()`（`utils.mm:2351`）在 daemon main 调用，`setuid(0)` 提权
- **判定标准**：App spawn daemon 后 daemon 在线（端口可达、日志正常），无 126。
- **修正触发**：不触发。根因已查清（§2），既有路径绕开 persona fix 链，正确。

### D3: getJBType() roothide 判定 — 保留

- **复核清单**：
  - `getJBType()`（`utils.mm:2685`）第一优先级 `resolveRoothidePreferencesDirByAPI()` 成功 → ROOTHIDE
  - App 路径分支：`path_4 hasPrefix:@".jbroot-"` → ROOTHIDE（`utils.mm:2720`）
  - Daemon 路径分支：`realpath("/var/jb")` 含 `/.jbroot-` → ROOTHIDE（`utils.mm:2726-2729`）
- **判定标准**：App 与 daemon 在 Relaxin 上均判定为 ROOTHIDE（策略诊断报告显示越狱类型=roothide）。
- **修正触发**：不触发。判定逻辑与 Relaxin jbroot 物理布局（primary `/var/containers/Bundle/Application/.jbroot-<brand>`、`/var/jb` symlink）一致。

### D4: libroot/libroothide 动态加载 — 保留（装机期验证）

- **复核清单**：
  - `getLibrootJbrootpathFunction`（`utils.mm:337`）候选加载路径含 `/var/jb/usr/lib/libroot.dylib`（`utils.mm:358`）
  - `resolveRoothidePathByAPI`（`utils.mm:907`）的 `jbroot` 符号查找路径含 `/var/jb/usr/lib/libroothide.dylib`（`utils.mm:944`）
  - Relaxin `RLXBootstrapFinalizer.m:409` 确认 bootstrap tarball 内有 `var/jb/usr/lib/libroot.dylib`
- **判定标准**：daemon 启动后日志无 `libroot_dyn_jbrootpath not available`，路径解析成功。
- **修正触发**：若装机时 `/var/jb/usr/lib/libroot.dylib` 不存在，需补候选路径或改用 libroothide API。**这是装机期验证项，不是代码改动的硬阻塞**。

### D5: 配置持久化链路 — 验收重点

- **复核清单**：
  - `resolveRoothidePreferencesDirByAPI`（`utils.mm:987`）解析 `/var/mobile/Library/Preferences` 到 jbroot
  - daemon（root）与 App（mobile）写同一 jbroot 内 `com.chargelimiter.mod.plist`
  - Relaxin `cfprefsd.m` 把非 apple 域 plist 重定向到 jbroot，与 ChargeLimiter 自管路径目标一致
  - `repair_shared_data_permissions`（postinst）修复共享数据目录权限
- **判定标准**：改设置→重启 userspace→设置仍在；App 与 daemon 读写同一文件。
- **修正触发**：若验收发现设置丢失，属"v1.15.0 既有适配的偏差"且改动小 → 走 tasks 2.x 就地修。若发现 Relaxin cfprefsd 重定向与 ChargeLimiter 路径有结构性冲突 → 开新 change。

### D6: /var/mobile 硬拼排查 — 已通过

- **复核清单**：grep `utils.mm` 所有 `/var/mobile/...` 均为逻辑路径，走 `resolveRoothidePathByAPI` / `getSharedDataRootPathWithLibroot` / `resolveRoothideDataRootByAPI` 解析；`NSHomeDirectory()` 调用走 Relaxin pathhook。
- **判定标准**：无硬拼 rootfs 路径绕过 hook 的代码。
- **修正触发**：不触发。已排查通过（open 阶段 design.md D6）。

### D7: 不依赖 markAppsAsDebugged — 不适配

- **复核清单**：ChargeLimiter jb entitlements 含 `platform-application`、`no-sandbox`、`persona-mgmt` 等，作为 platform app 不依赖 `markAppsAsDebugged` 放行 invalid pages。
- **判定标准**：Relaxin 设置里开/关 `markAppsAsDebugged`，ChargeLimiter 均正常工作。
- **修正触发**：不触发。

## 4. 修正边界与分级（C 方案）

验收失败项按性质分级处理：

| 级别 | 定义 | 处理路径 | 示例 |
|---|---|---|---|
| **小偏差** | v1.15.0 既有适配的偏差，改动小（postinst/utils.mm 微调，不触及 spec） | 本次 change tasks 2.x 就地修，修完重验 | postinst 某个域清理遗漏、候选路径补一条 |
| **大发现** | 需要重新设计或 spec 级调整，或改动跨多模块 | 记录到复核/验收报告，开新 change | Relaxin 行为与假设结构性冲突、需要 spec 级行为变更 |
| **装机期验证项** | 源码层面无法确认，需真机装机才能验证 | 真机验收时确认，通过则归档，不通过则升级到小偏差或大发现 | libroot.dylib 路径就位 |

**边界判定原则**：若修正会触及 `daemon-charge-control` spec 级行为契约 → 大发现，开新 change（与 skip_specs=true 冲突时以用户确认为准）。否则按小偏差就地修。

## 5. 测试策略

### 5.1 源码复核（无单测）

源码复核是"读 + 判定"产出，无可自动化测试的单元。产出为独立复核报告 `docs/superpowers/reports/2026-08-18-relaxin-roothide-source-revisit.md`，含 D1-D7 每条的复核清单与判定结果（PASS/FAIL/N/A）。

### 5.2 真机验收（9 项）

设备：iPhone 15 Pro Max / iOS 17.1。验收结果结构化记录到 `docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md`，模板：

```markdown
### 场景 X.Y: <名称>
- **步骤**：<具体操作>
- **预期**：<预期结果>
- **实测**：<真机实际结果>
- **判定**：PASS / FAIL
- **失败诊断**（FAIL 时）：<spawn rc / 端口 / launchctl / 日志尾 / 下一步>
```

验收场景（对应 tasks.md 3.x）：

| # | 场景 | 关键预期 |
|---|---|---|
| 3.1 | 构建 roothide 包 | `out/ChargeLimiter_<ver>_roothide_arm64e.deb` 产出，ldid/arch 检查通过 |
| 3.2 | 真机安装 | postinst 无 fail_install，plist Program 为 `.jbroot-<brand>` 真实路径 |
| 3.3 | daemon 启动 | `launchctl print` running，策略诊断显示 daemon 在线、jbtype=roothide |
| 3.4 | 充电控制 | 停充（IsCharging=NO + PredictiveChargingInhibit=YES）→ 恢复，电流阈值判定生效（沿用 [[ios-power-re-playbook]]） |
| 3.5 | 加速充电 LPM | 插电即开 LPM；拔线还原；重越狱/userspace reboot 后未开 APP 时 LPM 仍生效（v1.15.2 bootstrap 兜底） |
| 3.6 | 设置持久化 | 改设置→重启 userspace→设置仍在；App 与 daemon 写同一 jbroot 内 plist |
| 3.7 | daemon 通信 | "修复 daemon 启动"一键自愈可用；URL Scheme 触发不受 root persona 影响 |
| 3.8 | 卸载 | prerm 清理 jbroot 数据目录 + 域 bootout，无残留 |
| 3.9 | markAppsAsDebugged 开关 | Relaxin 设置开/关 markAppsAsDebugged，ChargeLimiter 均正常工作 |

### 5.3 失败诊断路径

任一场景 FAIL 时，按以下顺序定位：

1. **daemon 在线**：`launchctl print system/com.chargelimiter.mod` 是否 running；App 策略诊断显示什么。
2. **spawn 链路**：策略诊断的"daemon 启动链路（离线诊断）"段，看 spawn rc / 端口 / launchctl / 日志尾。
3. **路径解析**：策略诊断的路径诊断段，看 jbroot 解析是否成功、数据文件落点。
4. **充电 IOKit**：策略诊断的"读电量 IOKit 链路"段，看 service/key 是否有效（沿用 [[ios17-charge-control-root-cause]]）。
5. **cfprefsd 重定向**：改设置后立即查 jbroot 内 plist 是否更新，区分"没写入"与"写了但重启后丢"。

## 6. 风险与回退

- [开源快照 ≠ 装机版本] → 复核结论需真机回归验证。所有"源码层面 PASS"在真机上重新确认。
- [bootstrap tarball 内容不可见] → libroot.dylib/libroothide.dylib 实际发布路径装机期验证（D4）。
- [cfprefsd 重定向 + 自管 prefs 路径] → D5 验收重点，覆盖"改设置→重启→设置还在"。
- [persona fix 链有多个失败分支] → §2 已查清，既有修复绕开整条链；但若 Relaxin 未来改 spawn_hook 行为，需重新评估 D2。
- **回退**：卸载新版 deb，装回 v1.15.x。prerm 有 jbroot 数据目录清理兜底。

## 7. Open Questions

- ~~root persona spawn exec 126 的精确源码根因~~ — **已解（§2）**。
- 装机时 `/var/jb/usr/lib/libroot.dylib` 与 `libroothide.dylib` 是否就位 — 装机期验证（D4），不阻塞。
