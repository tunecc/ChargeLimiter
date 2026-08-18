# 源码复核报告：Relaxin roothide 适配

- **change**：`relaxin-roothide-adapt-revisit`
- **phase**：verify（落盘归档）
- **设备基线**：iPhone 15 Pro Max（iPhone16,2）/ iOS 17.1
- **参考源码（只读）**：`/Users/tune/Downloads/Relaxin`
- **关联文档**：
  - Design Doc：`docs/superpowers/specs/2026-08-18-relaxin-roothide-adapt-revisit-design.md`（§2 126 根因 + §3 D1-D7 复核清单与判定标准）
  - OpenSpec design.md：`docs/openspec/changes/relaxin-roothide-adapt-revisit/design.md`（D1-D7 高层决策 + Relaxin 源码侧事实 12 条）
  - 验收报告：`docs/superpowers/reports/2026-08-18-relaxin-roothide-acceptance.md`

> 本报告是 D1-D7 每条复核清单的可追溯归档判定。源码层面 PASS 结论在真机上重新确认（开源快照 ≠ 装机版本），真机实测见验收报告。

## 复核结论摘要

v1.15.0 摸黑适配在 Relaxin 源码层面**基本正确**，D1-D7 全部 PASS，无"明显做错需要推倒重来"的点。唯一触发的小偏差（roothide 包架构 arm64→arm64e）已在 build 阶段 Task 2 就地修正（commit ed813fc），未触及 spec（`skip_specs: true` 不冲突）。126 根因查清（§2）。

## D1-D7 逐条复核判定

### D1: postinst plist Program 路径解析 — PASS

**复核清单**：
- [x] `Package_roothide/DEBIAN/postinst:46` 用 `command -v jbroot` 校验命令可用，`:47` `jbroot "$DAEMON_BIN"` 解析真实路径
- [x] `:51` case 校验解析结果匹配 `*/.jbroot-*/Applications/ChargeLimiter.app/ChargeLimiterDaemon`，不匹配则 `fail_install`
- [x] `:56-59` `plutil -replace Program` 与 `ProgramArguments.0` 均写入真实路径
- [x] Relaxin `RLXBootstrapFinalizer.m` 命名空间设计：system 域 launchd 在 rootfs 命名空间看不到 jbroot 逻辑路径，需 `jbroot` 命令解析成 `/rootfs/.jbroot-XXX/...` 真实路径

**真机实测**（验收场景 3.3）：`launchctl print` 显示 `program = .jbroot-492D3FB4D434B4BB/.../ChargeLimiterDaemon`，daemon running（pid=1537, execs=1）。

**修正触发**：不触发。

### D2: roothide 下 spawn 避开 root persona — PASS

**复核清单**：
- [x] `utils.mm:2764` `restartDaemonForApp_C`：`jbType != JBTYPE_TROLLSTORE && jbType != JBTYPE_ROOTHIDE` 才加 `SPAWN_FLAG_ROOT`（roothide 下不加）
- [x] `utils.mm:2351` `platformize_me()` 在 daemon main 调用（`daemon.mm:4294`），`setuid(0)` 提权
- [x] postinst `chmod +s` 设置 daemon 二进制 setuid 位（真机实测 `-rwsr-sr-x root wheel`）
- [x] Relaxin `jbdomain_systemwide.c` S_ISUID checkin 分支按文件 uid 设置进程 euid/svuid，绕开 persona fix 链

**126 根因**（design §2）：App（mobile）用 `SPAWN_FLAG_ROOT` spawn daemon 命中 Relaxin `systemhook/src/common.c:209-296` iOS 17 persona fix 链；persona fix 失败时子进程被 SIGKILL，但 `SPAWN_FLAG_NOWAIT` 下父进程 spawn rc 仍为 0，daemon 永不在线。v1.15.0 改为非 root spawn + setuid + platformize_me，绕开整条 persona fix 链，正确。

**真机实测**（验收场景 3.3）：无 spawn rc=126。

**修正触发**：不触发。根因已查清，既有路径绕开 persona fix 链。

### D3: getJBType() roothide 判定 — PASS

**复核清单**：
- [x] `utils.mm:2699` 第一优先级 `resolveRoothidePreferencesDirByAPI()` 成功 → `JBTYPE_ROOTHIDE`
- [x] App 路径分支 `utils.mm:2721`：`path_4 hasPrefix:@".jbroot-"` → ROOTHIDE
- [x] Daemon 路径分支 `utils.mm:2729`：`realpath("/var/jb")`（:939）含 `/.jbroot-` → ROOTHIDE
- [x] 与 Relaxin jbroot 物理布局一致（primary `/var/containers/Bundle/Application/.jbroot-<brand>`、`/var/jb` symlink）

**真机实测**（验收场景 3.3/3.4）：App 策略诊断显示越狱类型=roothide（jb_type=2）。

**修正触发**：不触发。启发式判定足够，不引入 brand checksum 校验（App 进程拿不到 brand）。

### D4: libroot/libroothide 动态加载 — PASS（装机期验证项确认）

**复核清单**：
- [x] `utils.mm:357-359` `getLibrootJbrootpathFunction` 候选加载路径含 `/var/jb/usr/lib/libroot.dylib`
- [x] `utils.mm:943-945` `resolveRoothidePathByAPI` 的 `jbroot` 符号查找路径含 `/var/jb/usr/lib/libroothide.dylib`
- [x] Relaxin `RLXBootstrapFinalizer.m:409` 确认 bootstrap tarball 内有 `var/jb/usr/lib/libroot.dylib`，finalizer 会 `refreshLibroot`

**真机实测**（验收场景 3.3，装机期验证项）：`/var/jb/usr/lib/libroot.dylib`（174656B）+ `libroothide.dylib`（168640B）就位；aldente.log 无 `libroot_dyn_jbrootpath not available`。

**修正触发**：不触发。装机期验证项确认通过。

### D5: 配置持久化链路 — PASS（验收重点）

**复核清单**：
- [x] `utils.mm:987` `resolveRoothidePreferencesDirByAPI` 解析 `/var/mobile/Library/Preferences` 到 jbroot
- [x] daemon（root）与 App（mobile）写同一 jbroot 内 `com.chargelimiter.mod.plist`
- [x] Relaxin `cfprefsd.m` 把非 apple 域 plist 重定向到 jbroot，与 ChargeLimiter 自管路径目标一致
- [x] postinst `repair_shared_data_permissions` 修复共享数据目录权限

**真机实测**（验收场景 3.6，D5 验收重点）：改设置→重启 userspace→设置仍在；App 与 daemon 读写同一 jbroot 内 plist（规范化路径一致=YES，路径解析来源=libroothide，atomic_verified=YES）。

**修正触发**：不触发。v1.15.0 既有修复在 Relaxin 上正确工作。

### D6: /var/mobile 硬拼排查 — PASS

**复核清单**：
- [x] `utils.mm:28-29,88,252,280,293-294` 所有 `/var/mobile/...` 均为逻辑路径常量（`kRoothideDataRoot` 等）
- [x] 逻辑路径通过 `resolveRoothidePathByAPI`（:944-945 加载 libroothide）/ `resolveRoothideDataRootByAPI` / `getSharedDataRootPathWithLibroot` 解析成 jbroot 真实路径
- [x] `NSHomeDirectory()` 调用走 Relaxin pathhook（`pathhook.m` 重写 `__CFCopyHomeDirURLForUser`）
- [x] 无硬拼 rootfs 路径绕过 hook 的代码

**真机实测**：场景 3.6 设置持久化 PASS 间接确认路径解析正确（pathhook + libroot 解析链路有效）。

**修正触发**：不触发。

### D7: 不依赖 markAppsAsDebugged — PASS

**复核清单**：
- [x] `scripts/roothide.entitlements` 含 `platform-application`、`com.apple.private.security.no-sandbox`（:5,:7）
- [x] jb entitlements 含 `com.apple.private.persona-mgmt`（App spawn 路径用）
- [x] 作为 platform app 不依赖 `markAppsAsDebugged`/`CS_DEBUGGED` 放行 invalid pages

**真机实测**（验收场景 3.9）：Relaxin 设置开/关 `markAppsAsDebugged`，ChargeLimiter 均正常工作。

**修正触发**：不触发。

## Open Question 复查

- ~~root persona spawn exec 126 的精确源码根因~~ — **已解**（design §2）：`systemwide_persona_fix` 多失败分支（entitlement 校验 / 直接子进程校验 / 内核 ucred 修改）任一失败 → 子进程 SIGKILL；`SPAWN_FLAG_NOWAIT` 下父进程 spawn rc 仍为 0。既有"避开 root persona"修复绕开整条链。
- ~~装机时 `/var/jb/usr/lib/libroot.dylib` 与 `libroothide.dylib` 是否就位~~ — **装机期确认**（D4 真机实测）。

## 修正记录

| 项 | 级别 | 处理 | commit |
|---|---|---|---|
| roothide 包架构 arm64 → arm64e | 小偏差（打包正确性，未触及 spec） | Task 2 就地修 `scripts/build_packages.sh` ARCHS + arch check | ed813fc |

## 已知偏差（未修正，待 follow-up 评估）

- **daemon 运行域**：`launchctl print` 输出 `domain = user/501` + Warning，而非 postinst 期望的 system 域。功能正常（充电控制/LPM/通信/持久化全 PASS），记录待 follow-up 评估是否需在 postinst/daemon 侧补 system 域 bootstrap 兜底。**不阻塞本次归档**。

## 附加发现（开独立 follow-up change 修，与 Relaxin 无关）

- **iOS 17 禁流态 `ExternalConnected`/`ExternalChargeCapable` 抖动**：息屏充电触发热控/停充→禁流后，一亮屏可能误发"开始充电"通知（充电线没动过）。原版也有此隐患，iOS 17 新禁流 key（`FieldDiagsInflowInhibit`/`OBCInflowInhibit`）让它更容易触发。根因与修复方向见 memory `ios17-inflow-external-connected-flicker`，开独立 follow-up change 修。

## 最终判定

**全部 PASS**。D1-D7 源码复核全部通过，126 根因查清，唯一小偏差（arm64e）已修正，真机验收 9 项全 PASS（见验收报告）。`skip_specs: true` 决策不冲突（无 spec 级行为变更）。**Ready for archive**。
