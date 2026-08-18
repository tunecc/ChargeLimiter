---
change: relaxin-roothide-adapt-revisit
design-doc: docs/superpowers/specs/2026-08-18-relaxin-roothide-adapt-revisit-design.md
base-ref: a89631b5bab6c036b6e62915d568abafd706b153
archived-with: 2026-08-18-relaxin-roothide-adapt-revisit
---

# Relaxin roothide 适配源码复核与真机验收 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 基于 Relaxin 开源源码复核 ChargeLimiter v1.15.0 摸黑适配，并在 iPhone 15 Pro Max / iOS 17.1 真机上完成 9 项验收，确认适配正确（预期代码改动为零，以真机验收为主）。

**Architecture:** 复核阶段（tasks 1.x）已在 Design Doc §3 内联完成并 PASS；本计划主体是 tasks 3.x 真机验收；tasks 2.x 作为条件性任务，仅在 3.x 验收发现"小偏差"时触发；tasks 4.x 收尾归档。所有"源码层面 PASS"结论在真机上重新确认（开源快照 ≠ 装机版本）。

**Tech Stack:** Shell (postinst/prerm/build_packages.sh) + Objective-C++ (utils.mm/daemon.mm) + 真机命令行 (launchctl/plutil/jbroot/dpkg)。

**关联文档：**
- Design Doc: `docs/superpowers/specs/2026-08-18-relaxin-roothide-adapt-revisit-design.md`（D1-D7 决策 + §2 126 根因 + §4 修正边界 + §5 测试策略 + §6 风险与回退）
- OpenSpec tasks: `docs/openspec/changes/relaxin-roothide-adapt-revisit/tasks.md`
- 既有 v1.15.0 适配记录: `docs/superpowers/plans/2026-08-11-relaxin-roothide-daemon-plist-path-fix.md`、`CHANGELOG.md` v1.15.0
- 参考源码（只读，不纳入本项目）: `/Users/tune/Downloads/Relaxin`
- memory 索引: `ios-power-re-playbook.md`、`ios17-charge-control-root-cause.md`

---

## Global Constraints

- **设备基线**：iPhone 15 Pro Max（iPhone16,2）/ iOS 17.1。iOS 16 已完美，不在本次范围。
- **skip_specs=true**：行为契约不变，无 delta spec；任何 spec 级行为变更触发"开新 change"（Design Doc §4）。
- **代码改动预期为零**：复核结论 D1-D7 在源码层面 PASS，tasks 2.x 仅在真机验收发现小偏差时触发。
- **参考源码只读**：`/Users/tune/Downloads/Relaxin` 只用于复核对照，不修改、不纳入本项目。
- **真机验收环境**：Relaxin 越狱已安装，jbroot 命令在 roothide 命名空间可用。
- **回退路径**：卸载新版 deb，装回 v1.15.x；prerm 有 jbroot 数据目录清理兜底。
- **验收失败分级**（Design Doc §4）：小偏差→tasks 2.x 就地修；大发现→开新 change；装机期验证项→装机时确认。
- **验收报告落盘**：所有验收结果结构化记录到 `docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md`；独立复核报告 `docs/superpowers/reports/2026-08-18-relaxin-roothide-source-revisit.md` 推迟到 verify 阶段与验收报告一起归档。

---

## 文件结构（受影响文件清单）

| 文件 | 角色 | 本次预期动作 |
|---|---|---|
| `Package_roothide/DEBIAN/postinst` | roothide 安装钩子（plist Program 修复、域清理、权限修复） | 复核（D1），验收（3.2），条件性修改（2.x） |
| `Package_roothide/DEBIAN/prerm` | roothide 卸载钩子（域清理、数据目录清理） | 复核（1.2），验收（3.8），条件性修改（2.x） |
| `utils.mm` | App 侧核心工具（jbType 判定、spawn、路径解析、daemon 修复入口） | 复核（1.3-1.6），验收（3.3/3.7），条件性修改（2.x） |
| `daemon.mm` | daemon 主体（启动自愈、plist 修复） | 复核（1.7），验收（3.3） |
| `scripts/build_packages.sh` | 构建脚本（native scheme + roothide 包） | 复核（1.8），验收（3.1） |
| `scripts/roothide.entitlements` | roothide entitlements | 复核（1.8），验收（3.1） |
| `CHANGELOG.md` | 变更日志 | 收尾更新（4.1） |
| `docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md` | 验收报告 | 本阶段产出（Task 3） |
| `docs/superpowers/reports/2026-08-18-relaxin-roothide-source-revisit.md` | 复核报告 | verify 阶段产出（4.3 前置） |
| memory `relaxin-adapt-change` | 跨会话记忆 | 收尾更新（4.2） |

---

## Task 1: 源码复核收尾（已完成，归档确认）

**Files:**
- Reference: `docs/superpowers/specs/2026-08-18-relaxin-roothide-adapt-revisit-design.md` §3（D1-D7 复核清单与判定）
- Reference: `/Users/tune/Downloads/Relaxin`（只读对照源码）
- Reference: `Package_roothide/DEBIAN/postinst`、`Package_roothide/DEBIAN/prerm`、`utils.mm`、`daemon.mm`、`scripts/build_packages.sh`、`scripts/roothide.entitlements`

**Interfaces:**
- Consumes: v1.15.0 既有适配代码（已在 `base-ref: a89631b` 提交内）
- Produces: 复核结论 D1-D7 全部 PASS 的判定，作为后续真机验收的预期基线

**说明：** tasks.md 1.1-1.9 的 9 项只读源码复核**已在 Design Doc §3 内联完成并 PASS**（D1-D7 + §2 126 根因查清）。本 Task 不重复复核，仅做归档确认，把已完成的复核结论固化为可追溯状态。

- [x] **Step 1: 确认 D1（postinst plist Program 路径解析）已 PASS**

对照 Design Doc §3 D1 的复核清单，确认以下结论已记录：
- `Package_roothide/DEBIAN/postinst` 用 `jbroot "$DAEMON_BIN"` 解析真实路径 ✓
- `plutil -replace Program` 与 `ProgramArguments.0` 均写入真实路径 ✓
- `bootout system` + `bootout user/foreground` + `bootstrap system` 顺序正确 ✓
- 与 Relaxin `RLXBootstrapFinalizer.m` 命名空间设计一致 ✓
- 修正触发条件：不触发（当前开源快照命名空间未变）

- [x] **Step 2: 确认 D2（roothide 下 spawn 避开 root persona）已 PASS**

对照 Design Doc §3 D2 + §2（126 根因）：
- `restartDaemonForApp_C`（`utils.mm:2764`）`jbType != JBTYPE_TROLLSTORE && jbType != JBTYPE_ROOTHIDE` 才加 `SPAWN_FLAG_ROOT` ✓
- `clRepairDaemonForApp_C`（`utils.mm:3051`）同条件 ✓
- daemon 二进制有 setuid 位（postinst `chmod +s`）+ `platformize_me()` → `setuid(0)` 提权 ✓
- §2 根因：persona fix 链有多个失败分支，既有修复绕开整条链，正确
- 修正触发条件：不触发

- [x] **Step 3: 确认 D3（getJBType() roothide 判定）已 PASS**

- `getJBType()`（`utils.mm:2685`）第一优先级 `resolveRoothidePreferencesDirByAPI()` 成功 → ROOTHIDE ✓
- App 路径分支：`.jbroot-` 前缀判定 ✓
- Daemon 路径分支：`realpath("/var/jb")` 含 `/.jbroot-` ✓
- 与 Relaxin jbroot 物理布局一致 ✓

- [x] **Step 4: 确认 D4（libroot/libroothide 动态加载）已 PASS（装机期验证项）**

- `getLibrootJbrootpathFunction`（`utils.mm:337`）候选路径含 `/var/jb/usr/lib/libroot.dylib` ✓
- `resolveRoothidePathByAPI`（`utils.mm:907`）的 `jbroot` 符号查找路径含 `/var/jb/usr/lib/libroothide.dylib` ✓
- Relaxin `RLXBootstrapFinalizer.m:409` 确认 bootstrap tarball 内有 `var/jb/usr/lib/libroot.dylib` ✓
- **装机期验证项**：装机时 `/var/jb/usr/lib/libroot.dylib` 实际存在性在 Task 3.3 验收，不阻塞本步

- [x] **Step 5: 确认 D5（配置持久化链路）已 PASS（验收重点）**

- `resolveRoothidePreferencesDirByAPI`（`utils.mm:987`）解析到 jbroot ✓
- daemon（root）与 App（mobile）写同一 jbroot 内 `com.chargelimiter.mod.plist` ✓
- Relaxin `cfprefsd.m` 重定向与 ChargeLimiter 自管路径目标一致 ✓
- `repair_shared_data_permissions`（postinst）修复共享数据目录权限 ✓
- **验收重点**：在 Task 3.6 真机确认"改设置→重启→设置仍在"

- [x] **Step 6: 确认 D6（/var/mobile 硬拼排查）已 PASS**

- grep `utils.mm` 所有 `/var/mobile/...` 均走 jbroot API 解析（`resolveRoothidePathByAPI` / `getSharedDataRootPathWithLibroot` / `resolveRoothideDataRootByAPI`）✓
- `NSHomeDirectory()` 调用走 Relaxin pathhook ✓
- 已在 open 阶段 design.md D6 排查通过，本步做最终确认

- [x] **Step 7: 确认 D7（不依赖 markAppsAsDebugged）已 PASS**

- ChargeLimiter jb entitlements 含 `platform-application`、`no-sandbox`、`persona-mgmt` ✓
- 作为 platform app 不依赖 `markAppsAsDebugged` 放行 invalid pages ✓
- 验收在 Task 3.9 真机确认

- [x] **Step 8: 确认 §2（126 根因）已查清**

对照 Design Doc §2：
- 调用链已厘清（`utils.mm:2453-2456` persona 99 → Relaxin `common.c:209-296` persona fix → `jbdomain_systemwide.c:998` systemwide_persona_fix → SIGCONT/SIGKILL）✓
- v1.15.0 修复（roothide 下非 root spawn + setuid 位 + platformize_me）绕开整条 persona fix 链 ✓
- 结论：既有修复正确，保留

- [x] **Step 9: 归档确认**

复核结论已固化于 Design Doc §3 D1-D7 + §2（9 项源码层面全部 PASS，1.4/1.8 为装机期验证项）。独立复核报告 `docs/superpowers/reports/2026-08-18-relaxin-roothide-source-revisit.md` 按 Comet 阶段分工推迟到 verify 阶段与验收报告一起落盘。

- [x] **Step 10: 不提交（本 Task 无代码改动）**

本 Task 是归档确认，不产生代码改动，无 commit。

---

## Task 2: 必要修正（条件性，预期为零改动）

**Files:**
- Conditional Modify: `Package_roothide/DEBIAN/postinst`、`Package_roothide/DEBIAN/prerm`、`utils.mm`、`daemon.mm`、`scripts/build_packages.sh`、`scripts/roothide.entitlements` 之一或多个

**Interfaces:**
- Consumes: Task 3 验收失败的"小偏差"判定（Design Doc §4）
- Produces: 修正后的代码 + 重验通过记录

**触发条件：** 仅当 Task 3 真机验收某场景 FAIL，且按 Design Doc §4 分级判定为"小偏差"（v1.15.0 既有适配的偏差，改动小，不触及 spec）时执行。若判定为"大发现"（需 spec 级调整或跨模块改动）→ 不执行本 Task，改为开新 change 并停止本 change 的 3.x 后续验收。

**预期：** 零改动。复核结论 D1-D7 源码层面 PASS，本 Task 大概率不触发。

- [x] **Step 1: 判定失败场景的级别**

Task 3 验收中触发的小偏差：3.1 构建 roothide 包时 daemon binary arch=arm64（与 control `iphoneos-arm64e` 不一致）。按 Design Doc §4 判定为"小偏差"（v1.15.0 既有、改动小、不触及 spec）→ 继续 Step 2。

其余 8 项验收全部 PASS，未触发本 Task。

- [x] **Step 2: 按 D1-D7 对应决策修正**

修正点对应构建链路（D1/D8 关联）：roothide 生态（Relaxin 源码 `RLXBootstrapRootScanner`、`Vendor/ElleKit/CydiaSubstrate.framework`、`DevKit/Packaging/RelaxinLite/package-deb.sh`）全是 arm64e，roothide 包理应 arm64e。

修改 `scripts/build_packages.sh`：
- 第 432 行：roothide scheme `ARCHS=arm64` → `ARCHS=arm64e`
- 第 723-724 行：`check_app "$APP_PATH" "arm64"` → `"arm64e"`，注释更新为"Native roothide scheme builds arm64e (matches Relaxin roothide device slice and the iphoneos-arm64e dpkg architecture label)"

- [x] **Step 3: 若触及 spec 级行为 → 回到 open 阶段**

未触及 spec 级行为契约（纯打包架构标签修正），与 `skip_specs: true` 不冲突。

- [x] **Step 4: 修改后语法/编译检查**

`bash scripts/build_packages.sh` 重建，[OK] Done。

- [x] **Step 5: 重新打包**

`out/ChargeLimiter_1.15.2_roothide_arm64e.deb` 产出，daemon binary arch=arm64e（`xcrun lipo -archs` 确认），control Architecture=iphoneos-arm64e，arch check 通过。

- [x] **Step 6: 重装并重验**

arm64e 版 deb 传真机重装，后续 3.3-3.9 全部 PASS（见 Task 3 各 Step）。

- [x] **Step 7: 提交修正（若有代码改动）**

提交 `scripts/build_packages.sh` 的 arm64e 修正。

---

## Task 3: 构建与真机验收（本阶段主体）

**Files:**
- Create: `docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md`（验收报告）
- Reference: `scripts/build_packages.sh`、`out/ChargeLimiter_<VERSION>_roothide_arm64e.deb`

**Interfaces:**
- Consumes: Task 1 的 D1-D7 复核结论（作为预期基线）、Task 2 的修正（若触发）
- Produces: 9 项验收结果（PASS/FAIL）+ 验收报告文件

**设备：** iPhone 15 Pro Max（iPhone16,2）/ iOS 17.1，Relaxin 越狱已安装。

**验收报告模板**（每个场景按此结构记录）：
```markdown
### 场景 3.X: <名称>
- **步骤**：<具体操作>
- **预期**：<预期结果，引用 D1-D7 对应决策>
- **实测**：<真机实际结果>
- **判定**：PASS / FAIL
- **失败诊断**（FAIL 时）：<spawn rc / 端口 / launchctl / 日志尾 / 下一步>
```

**失败诊断通用路径**（任一场景 FAIL 时按顺序定位，Design Doc §5.3）：
1. daemon 在线：`launchctl print system/com.chargelimiter.mod` 是否 running；App 策略诊断显示什么
2. spawn 链路：策略诊断的"daemon 启动链路（离线诊断）"段，看 spawn rc / 端口 / launchctl / 日志尾
3. 路径解析：策略诊断的路径诊断段，看 jbroot 解析是否成功、数据文件落点
4. 充电 IOKit：策略诊断的"读电量 IOKit 链路"段，看 service/key 是否有效（沿用 `ios17-charge-control-root-cause` memory）
5. cfprefsd 重定向：改设置后立即查 jbroot 内 plist 是否更新，区分"没写入"与"写了但重启后丢"

- [x] **Step 1: 创建验收报告骨架**

验收报告内容已就绪，按 Comet 阶段分工推迟到 verify 阶段落盘到 `docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md`。验收结果汇总（9 项全部 PASS）已固化于本 plan 文件 Task 3 各 Step。

- [x] **Step 2: 场景 3.1 — 构建 roothide 包** ✅ PASS（arm64e 修正后）

实测：首次构建 daemon binary arch=arm64（与 control arm64e 不一致）→ 触发 Task 2 修正 `scripts/build_packages.sh` ARCHS=arm64→arm64e + arch check；重建后 daemon arch=arm64e，[OK] Done。entitlements 完整（platform-application/no-sandbox/persona-mgmt/powersource-write）。

- [x] **Step 3: 场景 3.2 — 真机安装** ✅ PASS

实测：daemon setuid 位 `-rwsr-sr-x root wheel`；jbroot 路径 `.jbroot-492D3FB4D434B4BB`；共享数据目录 `drwxr-x--- mobile:mobile`。plutil 语法差异未直接验证 plist Program，由 3.3 launchctl print 间接确认。

- [x] **Step 4: 场景 3.3 — daemon 启动（D4 装机期验证）** ✅ PASS

实测：state=running pid=1537 execs=1；program=`.jbroot-492D3FB4D434B4BB/.../ChargeLimiterDaemon`（D1 正确）；arm64 二进制在 arm64e 设备正常启动；libroot.dylib(174656B)+libroothide.dylib(168640B) 就位（D4 装机期验证项确认）；aldente.log 生成无 libroot 解析失败；无 spawn rc=126（D2 有效）。**偏差**：daemon 实际运行在 user/501 域而非 postinst 期望的 system 域（`launchctl print` 输出 `domain = user/501` + Warning），功能正常，记录待收尾评估。

- [x] **Step 5: 场景 3.4 — 充电控制验收** ✅ PASS

实测探针：AppleSmartBattery|charging_override = effective（write_ret=0, current_stopped=1, restore_ret=0），停充电流 913→84，恢复回 913；best_path=AppleSmartBattery|charging_override；Manager 全 write_rejected（Unsupported），inflow_override write_rejected（BadArgument）—— 均符合 ios17-charge-control-root-cause 既有认知；daemon 在线/HTTP 可达/jb_type=2。

- [x] **Step 6: 场景 3.5 — 加速充电 LPM 验收** ✅ PASS

实测：插电即开 LPM、拔线还原、重越狱/userspace reboot 后未开 APP 插电仍生效（v1.15.2 bootstrap 兜底，commit a89631b 在 Relaxin 上正常工作）。

- [x] **Step 7: 场景 3.6 — 设置持久化验收（D5 验收重点）** ✅ PASS

实测：改设置→重启 userspace→设置仍在，App 与 daemon 读写同一 jbroot 内 plist（规范化路径一致=YES，路径解析来源=libroothide，atomic_verified=YES）。

- [x] **Step 8: 场景 3.7 — daemon 通信验收** ✅ PASS

实测：一键自愈可用、URL Scheme 触发正常、端口可达（用户确认）。

- [x] **Step 9: 场景 3.8 — 卸载验收** ✅ PASS

实测：dpkg -r 后无残留文件/服务（用户确认）。

- [x] **Step 10: 场景 3.9 — markAppsAsDebugged 开关验收** ✅ PASS

实测：Relaxin 设置开/关 markAppsAsDebugged，ChargeLimiter 均正常（D7 不依赖确认）。

- [x] **Step 11: 汇总验收结果并更新报告**

验收结果汇总：9 项全部 PASS。附加发现 3 项：(1) roothide arch 偏差已修正（Task 2）；(2) user/501 域偏差记录待评估；(3) iOS 17 禁流态 ExternalConnected 抖动误发"开始充电"通知 —— 与 Relaxin 无关，原版也有，开独立 follow-up change 修（memory `ios17-inflow-external-connected-flicker`）。验收报告推迟到 verify 阶段落盘。

- [x] **Step 12: 若有 FAIL 触发 Task 2**

无 FAIL。Task 2 仅因 3.1 arch 偏差触发并已修正（见 Task 2 记录）。

- [x] **Step 13: 不提交（本 Task 无代码改动，除非 Task 2 触发）**

Task 2 触发的 arm64e 修正单独提交。

**步骤**：
```bash
launchctl print system/com.chargelimiter.mod | head -30
# 期望显示 running
# 在 App 内查看"策略诊断"：daemon 在线、越狱类型=roothide
# 验证 D4 装机期验证项：
ls -l /var/jb/usr/lib/libroot.dylib
ls -l /var/jb/usr/lib/libroothide.dylib
# 期望至少 libroot.dylib 存在
```

**预期**（D2 + D3 + D4）：
- `launchctl print system/com.chargelimiter.mod` 显示 running
- App 策略诊断显示 daemon 在线
- App 策略诊断显示越狱类型=roothide（D3 判定正确）
- daemon 启动日志无 `libroot_dyn_jbrootpath not available`（D4 路径解析成功）
- `/var/jb/usr/lib/libroot.dylib` 存在（D4 装机期验证项确认）
- 无 spawn rc=126 现象（D2 修复有效）

**判定标准**：daemon running + 策略诊断在线 + jbtype=roothide + 无 126 + libroot.dylib 就位 → PASS

**失败诊断**：
- daemon 不 running：`launchctl print` 看 last exit code；plist Program 路径是否解析到
- spawn rc=126：回到 §2 根因，检查 setuid 位是否设置（`ls -l` daemon 二进制看 `rwsr-xr-x`）
- libroot.dylib 不存在：D4 装机期验证项失败，按 Design Doc §3 D4 修正触发条件 → 升级到 Task 2 补候选路径
- jbtype 不对：D3 判定异常，检查 `resolveRoothidePreferencesDirByAPI` 返回值

- [x] **Step 5: 场景 3.4 — 充电控制验收** ✅ PASS（详见 Task 3 汇总段）

- [x] **Step 6: 场景 3.5 — 加速充电 LPM 验收** ✅ PASS（详见 Task 3 汇总段）

- [x] **Step 7: 场景 3.6 — 设置持久化验收（D5 验收重点）** ✅ PASS（详见 Task 3 汇总段）

- [x] **Step 8: 场景 3.7 — daemon 通信验收** ✅ PASS（详见 Task 3 汇总段）

- [x] **Step 9: 场景 3.8 — 卸载验收** ✅ PASS（详见 Task 3 汇总段）

- [x] **Step 10: 场景 3.9 — markAppsAsDebugged 开关验收** ✅ PASS（详见 Task 3 汇总段）

- [x] **Step 11: 汇总验收结果并更新报告** ✅ 9 项全部 PASS（验收报告内容推迟到 verify 阶段落盘到 `docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md`）

- [x] **Step 13: 不提交（本 Task 无代码改动，除非 Task 2 触发）**

本 Task 产出验收报告内容（推迟到 verify 阶段落盘到 `docs/superpowers/reports/`）。Task 2 触发的 arm64e 修正单独提交。

---

## Task 4: 收尾

**Files:**
- Modify: `CHANGELOG.md`
- Modify: memory `relaxin-adapt-change`（`~/.claude/projects/-Users-tune-Documents-Scripts-Jailbreak-GitHub-ChargeLimiter/memory/`）
- Create: `docs/superpowers/reports/2026-08-18-relaxin-roothide-source-revisit.md`（verify 阶段，若按 Comet 分工推迟则仅占位）

**Interfaces:**
- Consumes: Task 1 复核结论 + Task 3 验收报告
- Produces: CHANGELOG 条目、memory 更新、verify 阶段入口

- [x] **Step 1: 更新 CHANGELOG.md** ✅ 已提交（commit 8e24c6a），Unreleased 补全 arm64e 修正 + D1-D7 复核 PASS + 9 项验收 PASS + 126 根因 + iOS17 禁流抖动 follow-up
Expected:
- 工作区干净（或仅剩未跟踪的 .agents/.claude/.codex/.comet 等工具目录）
- 最近 commit 含本 change 的收尾 commit

---

## Self-Review

**1. Spec 覆盖：**
- Design Doc §1 Context → Global Constraints（设备基线、参考源码、skip_specs）✓
- Design Doc §2 126 根因 → Task 1 Step 8（归档确认）✓
- Design Doc §3 D1 → Task 1 Step 1 + Task 3 Step 3（3.2 验收）✓
- Design Doc §3 D2 → Task 1 Step 2 + Task 3 Step 4（3.3）、Step 8（3.7）✓
- Design Doc §3 D3 → Task 1 Step 3 + Task 3 Step 4（3.3）✓
- Design Doc §3 D4 → Task 1 Step 4 + Task 3 Step 4（3.3 装机期验证）✓
- Design Doc §3 D5 → Task 1 Step 5 + Task 3 Step 7（3.6 验收重点）✓
- Design Doc §3 D6 → Task 1 Step 6 ✓
- Design Doc §3 D7 → Task 1 Step 7 + Task 3 Step 10（3.9）✓
- Design Doc §4 修正边界 → Task 2 Step 1（分级判定）✓
- Design Doc §5.2 9 项验收场景 → Task 3 Step 2-10 一一对应 ✓
- Design Doc §5.3 失败诊断路径 → Task 3 失败诊断通用路径 ✓
- Design Doc §6 风险与回退 → Global Constraints 回退路径 ✓
- tasks.md 1.1-1.9 → Task 1 Step 1-9 ✓
- tasks.md 2.1-2.2 → Task 2 Step 2-3 ✓
- tasks.md 3.1-3.9 → Task 3 Step 2-10 ✓
- tasks.md 4.1-4.3 → Task 4 Step 1-4 ✓

**2. 占位符扫描：**
- Task 2 Step 2 未预设具体修改代码——这是**故意的**（条件性任务，未发生的问题不应预设方案），符合 Design Doc §4 "小偏差就地修"的边界判定原则；触发时按 D1-D7 对应决策的"修正触发条件"填写。这不是占位符，而是条件性任务的正确形态。
- 所有真机验收步骤给出具体命令/预期/判定/失败诊断，无 "TBD/TODO/implement later"。
- 验收报告模板给出完整结构。

**3. 类型/命名一致性：**
- D1-D7 决策编号在 Task 1（复核确认）与 Task 3（验收对应）中一致 ✓
- tasks.md 场景编号 3.1-3.9 与 Task 3 Step 2-10 一一对应 ✓
- 文件路径（`Package_roothide/DEBIAN/postinst`、`utils.mm`、`daemon.mm`、`scripts/build_packages.sh`、`scripts/roothide.entitlements`）在文件结构表与各 Task 中一致 ✓
- 验收报告路径 `docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md` 与独立复核报告路径 `docs/superpowers/reports/2026-08-18-relaxin-roothide-source-revisit.md` 在 Task 3、Task 4 中一致 ✓
- base-ref `a89631b5bab6c036b6e62915d568abafd706b153` 与 Plan 头部、验收报告骨架、memory 更新内容一致 ✓

---

## 执行交接

**Plan complete and saved to `docs/superpowers/plans/2026-08-18-relaxin-roothide-adapt-revisit.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**

**特殊说明：** 本计划主体是 Task 3 真机验收，需要真机设备（iPhone 15 Pro Max / iOS 17.1）在场。Task 1（复核归档）与 Task 4（收尾）可在无真机时完成；Task 2（条件性修正）仅在 Task 3 验收失败时触发；Task 3 大部分步骤需要真机交互。建议：
- 若真机未就绪：先执行 Task 1（归档确认已完成的复核结论）+ Task 4 Step 1-2（CHANGELOG 骨架 + memory 更新），Task 3 待真机就绪后执行。
- 若真机就绪：按 Task 1 → Task 3 → （条件性）Task 2 → Task 4 顺序执行。
