---
name: relaxin-roothide-daemon-offline
description: relaxin 越狱 roothide 下 daemon 离线：离线诊断链 + 一键自愈（方案 A+B）
metadata:
  type: design
  originSessionId: current
  modified: 2026-08-09T00:00:00.000Z
---

# relaxin roothide daemon 离线：离线诊断链 + 一键自愈设计

## 1. 背景

部分用户反馈：在最新 relaxin 越狱的 roothide 包上，**安装后首次打开 App 即「daemon 离线」**（HTTP 连不上、不显示电量），同一版本在另一些设备上正常。

已确认的复现时机：**装好打开就离线**（非跨重启后才失效）→ 问题集中在「安装后 daemon 没有被正确拉起」这一段，不是运行中崩溃。

现有诊断报告（`CLDiagnosticCollector` + `CLAdvancedSettingsViewController`）只能回答「不通」，无法区分故障断在哪一环，且「越狱类型」显示 `unknown`（该字段现不可用，但恰是最关键的分组变量）。

**注**：relaxin 为知识截止（2026-01）之后的越狱，Web 检索无可索引资料。本设计所有结论基于本项目代码 + roothide 通用机制，具体判读以真机样本回填为准。

## 2. 目标

- 让「daemon 离线」报告能自动定位失败环节（launchd 未拉起 / App spawn 失败 / daemon 起来即崩 / 端口被占）。
- 提供用户可触发的「一键修复」：在不改变既有自动拉 daemon 行为的前提下，完成一次尽力而为的自愈并分步留证。
- 修复「越狱类型 unknown」的判读盲区（双源 + 原始 code）。
- 不改动 `CLAPIClient` 的自动重启路径，避免双击 spawn。

## 3. 判定树（报告必须能区分的分支）

```
daemon 离线
├─ daemon 二进制在 App 实测路径不存在        → path_missing（包没装上 daemon，深水区）
├─ 存在，但 App spawn 失败
│   ├─ root 版 rc ≠ 0 → 记录 errno(EPERM/EACCES...) → 重试非 root
│   └─ 非 root rc ≠ 0 → spawn 链路坏（relaxin App sandbox 限制）
├─ spawn 成功但端口未开
│   ├─ aldente.log 尾部含 "serve failed, exit" → bind 失败
│   ├─ 含 "already served, exit" → 端口被其它进程/残留占
│   ├─ 含 sqlite/crash 栈 → daemon 启动即崩
│   └─ 日志为空/被截断 → 进程根本没进 serve（dyld/entitlement 层失败）
└─ spawn 未开 + launchctl bootstrap 也失败 → launchd 命名空间/权限问题（记 rc+out 留证）
```

## 4. 架构概览

```
CLAdvancedSettingsViewController（已有诊断页）
  ├── [已有] 一键复制完整诊断 ──► CLDiagnosticCollector.collect...
  ├── [新增] 一键修复 daemon  ──► clRepairDaemonForApp_C()  → 刷回报告
  └── [已有] applyDiagReportToLabels → 新增离线诊断段字段
                                    ▲
CLDiagnosticCollector（纯 Foundation）
  ├── 新增模型 CLDiagDaemonLink（离线时才渲染）
  ├── 环境字段新增 jb 判定双源
  └── dlsym 新增: clDaemonLaunchProbe_C / clRepairDaemonForApp_C / getLogPath_C

utils.mm（App 侧 _C 桥）
  ├── [新] clDaemonLaunchProbe_C()  只读探针（诊断用，无副作用）
  ├── [新] clRepairDaemonForApp_C() 自愈+报告（kill→spawn→launchctl→日志）
  └── [新] getLogPath_C() 导出
```

## 5. 组件设计

### C1: `clDaemonLaunchProbe_C(void) -> NSDictionary *`（utils.mm，只读）

不产生任何副作用，供「一键复制完整诊断」的离线段使用。返回：

| key | 类型 | 说明 |
|---|---|---|
| `daemon_path` | NSString | App 实测 daemon 路径（未打码；报告层再 sanitize） |
| `daemon_exists` | BOOL | 路径是否存在 |
| `initial_port_open` | BOOL | `localPortOpen_C(1230)` |
| `log_tail` | NSString | `aldente.log` 尾部最多 20 行（路径 sanitize；不存在返回空串） |

> jb 双源判定不在 C1，见 C3（`CLDiagnosticCollector` 侧，需复用 dlsym 的命中与否记录）。

### C2: `clRepairDaemonForApp_C(void) -> NSDictionary *`（utils.mm，有副作用）

供「一键修复」按钮调用，仅当用户显式触发。逐步执行并记录：

1. 复用 C1 的 `daemon_path`/`daemon_exists`/`initial_port_open`。
2. 若端口已开 → 返回 `already_up`（不做任何动作）。
3. Kill 残留：`spawn @[ @"/usr/bin/killall", @"-9", @"ChargeLimiterDaemon" ]`（root persona，best-effort）→ `kill_rc`。
4. spawn daemon（带 `--app-docs`，沿用 `restartDaemonForApp_C` 的 root→非 root 回退逻辑），记录 `root_spawn_rc` 与 `nonroot_spawn_rc` 原值。
5. 每 300ms 轮询 `localhost:1230` 至多 5s → `port_after_spawn`。
6. 仍未开 → 尽力而为 launchctl 复位：
   - `launchctl bootout system/com.chargelimiter.mod`
   - `launchctl bootstrap system <plistPath>`，`plistPath` 依次尝试 `/Library/LaunchDaemons/com.chargelimiter.mod.plist` 与 `从 App 自身 jbroot 推导的路径`（`getSelfExePath` 前缀 + `/Library/LaunchDaemons/...`）
   - 记录 `launchctl_attempted` / `launchctl_rc` / `launchctl_out`（首个输出行）
7. 轮询至多 3s → `port_after_launchctl`。
8. 汇总 `final_port_open` 与 C1 的 `log_tail`。

**副作用边界**：只在用户点按钮时执行；不动 `CLAPIClient` init 的自动 spawn；daemon 在线时直接短路。

### C3: `CLDiagnosticCollector`（模型 + markdown + 双源）

- 新增模型 `CLDiagDaemonLink`（`CLDiagnosticCollector.h`）：
  `daemonPath`（sanitize 后）、`daemonExists`、`initialPortOpen`、`rootSpawnRc`、`nonrootSpawnRc`、`portAfterSpawn`、`launchctlRc`、`launchctlOut`、`finalPortOpen`、`logTail`。
- `CLDiagnosticReport` 增 `daemonLink` 属性；`markdownText` **仅在 `daemonAlive == NO`** 时插入 `# daemon 启动链路（离线诊断）` 段，内容见附录 A。
- errno 解释表（App 侧翻译）：`0=成功 / 1=EPERM 权限 / 2=ENOENT 路径不存在 / 13=EACCES 权限拒绝`，其余显示原值。
- **jb 双源修复**：`CLDiagEnvironment` 新增 `jbRawCode`（int）+ `jbProbeDetail`（NSString）。`CLDiagCallGetJBType` 记录 dlsym 是否命中；命中则记录原始 code + `getJBType()` 内部走到的分支依据（libroot/jbroot 符号是否可解析、路径形态）。报告 `越狱类型` 行显示 `label (raw=N, symbol=?)`。

### C4: UI 接入（`CLAdvancedSettingsViewController.m`）

- 调试与观测卡片新增行「修复 daemon 启动」（icon `arrow.clockwise.circle`），点击 → 后台队列跑 C2 → 主线程刷新诊断标签 + 弹结果摘要（成功 / 失败于哪一步 / errno 解释）。
- 失败时摘要给出可操作建议文案（例如「spawn 被拒（EPERM）→ 建议先重装包或越狱修复工具」）。
- 运行中禁点（disable），完成后恢复。
- 不新增页面，复用现有卡片容器。

### C5: Localizable

新增约 10 个键（zh-Hans + en）：「修复 daemon 启动」「修复中…」「修复完成：daemon 已在线」「修复失败：<步骤> <errno 解释>」等。

## 6. 错误处理与降级

- 每一环失败只记录、不抛异常；报告照样产出。
- `launchctl` 步骤明确按“尽力而为”：在 App sandbox 下大概率 `EPERM`/`ENOENT`，属预期，报告返回 `launchctl unavailable: rc=...`，不做多余重试。
- `log_tail` 读取失败（无权限/路径不可解析）返回空串并标注 `(不可读)`。
- 后台队列执行 C2，主线程只收结果；耗时上限约 8s，超时返回超时标记。

## 7. 安全边界

- 复制文本不含：电池序列号、UDID、完整 jbroot（沿用 `CLSanitizePathForDiag` 截到 `.jbroot-XXX`）。
- C1 纯只读；C2 唯一副作用 kill/spawn/launchctl，仅按钮触发，daemon 在线短路。
- 不把 `aldente.log` 全文进报告，仅尾部 20 行，且不因报告读取而写任何文件。

## 8. 测试

- 纯 C 侧：Python 源码扫描断言
  - `clRepairDaemonForApp_C` 存在且含 kill/spawn/launchctl 分支；
  - errno 解释表覆盖 0/1/2/13；
  - `log_tail` 截断逻辑（>20 行取尾部）；
  - C1 不含 `killall`/`launchctl`/`spawn` 副作用关键字（只读性）。
- markdown 快照：fixture 离线报告 → 断言 `# daemon 启动链路（离线诊断）` 段存在；在线报告 → 断言该段不出现。
- 本地化：新增键在 zh-Hans/en 两份 `.strings` 都有。
- 不做 XCTest；交付后由用户在可跑 `xcodebuild` 环境验证 rootful/rootless/roothide 三个 scheme 编译，再手动冒烟：装包→打开→离线→点修复→在线。

## 9. 本地化 key 清单（草案）

`diag_repair_daemon` / `diag_repairing` / `diag_repair_ok` / `diag_repair_failed` / `diag_repair_already_up` / `diag_repair_epcm` 等（最终以代码为准，两份 strings 同步）。

## 10. 落地分工

- **我写**：utils.mm 的 C1/C2/getLogPath_C、CLDiagnosticCollector.h/.m（C3）、CLAdvancedSettingsViewController.m（C4）、Localizable 键、Python 扫描测试 + markdown 快照测试。
- **用户**：可跑 xcodebuild 环境验证三 scheme 编译；必要时 pbxproj 若出现新文件归属则按既有方式拆分（预期无新增 target，全部落在既有 utils.mm / CLDiagnosticCollector 文件内）。

## 11. 设计决策记录

| 决策 | 选择 | 理由 |
|---|---|---|
| 自愈放 App 侧而非 postinst | App 侧可观测、可重试、可留证 | 用户无需重装/越狱工具即可自愈 |
| 探针与修复分离 | C1 只读 / C2 有副作用 | 复制诊断不应触发副作用 |
| launchctl 尽力而为 | 记录 rc+out，不重试 | 大概率 EPERM，先留证再决定后续方案 D |
| 诊断段仅离线渲染 | 保持在线报告精简 | 在线用户不被打扰 |
| 不动 CLAPIClient 自动路径 | 仅新增手动修复 | 避免行为变化与双击 spawn |

## 12. 明确不做（Out of scope）

- 不改 daemon 侧任何逻辑（B 的“加固”仅表现为 App 侧可观测 + 可操作提示）。
- 不做 plist `Program` 路径加固（方案 D）——等 C1/C2 真机样本决定。
- 不做“自动后台自愈”定时器——只在用户显式点击时执行。

## 附录 A：离线诊断段示例

```
# daemon 启动链路（离线诊断）
daemon 路径:     .jbroot-XXX/…/ChargeLimiter.app/ChargeLimiterDaemon
二进制存在:      YES
App spawn rc:    root=1(EPERM) 非root=13(EACCES)
spawn 后端口:    NO
launchctl:       unavailable rc=1 out="Operation not permitted"
最终端口:        NO
日志尾部(aldente.log):
  [CL] INFO: libroot_dyn_jbrootpath not available
  [CL] CRITICAL: Path resolution failed. appDoc=… sharedDataRoot=…
  ...
```

## 附录 B：判定树 → 建议文案

| 判定 | 报告给用户的建议 |
|---|---|
| `path_missing` | 安装包缺 daemon，建议重装该包 |
| spawn rc=EPERM/EACCES | 越狱未给 App 提权，建议用越狱工具修复/重启后重试 |
| log 含 `serve failed` | 端口被占或 bind 失败，点修复会先 kill 残留 |
| launchctl rc=EPERM | launchd 未拉起（relax 命名空间），样本回传决定方案 D |
