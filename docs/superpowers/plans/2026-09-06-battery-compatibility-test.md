---
archived-with: 2026-09-06-battery-compatibility-test-page
status: final
---
# 电池兼容性测试页面 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 ChargeLimiter 主页面"更多功能"区历史统计下方新增"电池兼容性测试"页面，一键自动执行停充/智能停充/禁流三项兼容性测试并给出判定与总体结论。

**Architecture:** UI 进程内测试引擎（`CLBatteryCompatibilityEngine`，与控制器同文件实现）通过现有 daemon HTTP API 驱动测试，独立 1 秒轮询 `get_bat_info` 原始响应采样判定；配置快照持久化 NSUserDefaults，完成/取消/离开三路径自动恢复。零 daemon 改动。

**Tech Stack:** Objective-C（UIKit），Xcode 工程 6 target（3 UI app + 3 daemon），本地化 en/zh-Hans strings。

## Global Constraints

- 仓库规范（AGENTS.md）：4 空格缩进；新类 `CL` 前缀；控制器放 `ChargeLimiter/UIKit/Controllers/`；用户可见文案必须同时更新 en.lproj 与 zh-Hans.lproj；不提交 out/、build_rootful/、build_rootless/。
- 判定参数（Design Doc 定稿）：采样间隔 1s；监测上限 120s；确认窗口 10s（混合延长至 30s 按均值）；电流阈值 5mA；回稳上限 15s；前置电量 10%–95%。
- 配置键（不得改动）：`enable`、`adv_predictive_inhibit_charge`；快照 NSUserDefaults key：`cl_compat_test_snapshot`。
- 测试与探针互斥：daemon 在 `g_chargeControlProbeRunning` 时对控制写假成功（返回 0），UI 必须按钮互禁。
- 有效电流取值：优先 `InstantAmperage`，缺失回退 `Amperage`（与 daemon `getEffectiveBatteryCurrent` 一致）。
- 验证命令：
  - rootful：`xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64`
  - rootless：`xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter rootless" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_rootless CODE_SIGNING_ALLOWED=NO ARCHS=arm64`
  - 打包：`./scripts/build_packages.sh`
- 提交风格：`feat(compat): ...` / `chore(build): ...`；每个计划任务一个提交。

## 已核实技术事实（执行者必读）

| # | 事实 | 影响 |
|---|------|------|
| F1 | daemon `g_enable=NO` 时策略循环完全短路，不会自动干预充电 | 测试前置=关全局开关 |
| F2 | `set_config enable=false` 会触发 daemon `resetBatteryStatus()`（自动恢复充电） | 关开关后设备处于"正在充电"，是测试起点 |
| F3 | `set_charge_status`/`set_inflow_status` API 无 enabled 门禁 | 全局开关关闭时仍可调 |
| F4 | 停充写法由 `adv_predictive_inhibit_charge` 决定：YES→PredictiveChargingInhibit；NO→传统 IsCharging | 停充测试临时关它、智能停充测试临时开它 |
| F5 | 探针运行期间控制写假成功 | 测试与探针按钮互禁 |
| F6 | `get_bat_info` 原始字段：`IsCharging`、`InstantAmperage`、`Amperage`、`ExternalChargeCapable`、`ExternalConnected`、`CurrentCapacity`、`BatteryInstalled` | 引擎直读 `response[@"data"]` |
| F7 | 探针结果：`data.summary`（any_effective/best_path/dominant_failure/power_note）+ `data.results[]`（service/path/verdict/...）；解析范例 `chargeControlProbeExportTextFromPayload`（CLAdvancedSettingsViewController.m:1598） | 探针摘要展示照此解析 |
| F8 | `CLBatteryManager.saveConfigKey:value:completion:` 封装 set_config；`daemonAlive` 只读属性 | 配置读写走它 |
| F9 | iOS17+ 禁流态 External* 派生值会抖动 | 禁流判定以电流特征 + IsCharging 为主 |
| F10 | `CLGlassCard`（CLSettingsViewController.m:76）与 `CLAdvSettingsCard`（CLAdvancedSettingsViewController.m:80）均定义在 .m 内部，**不可跨文件复用** | 新页面自带 `CLCompatCard` 轻量卡片类 |
| F11 | Xcode 工程：新 UI 源文件需 1 条 PBXFileReference + 1 条 PBXBuildFile×3 target + Controllers group child + 3 个 UI target 的 Sources phase 条目；daemon target 不加 | 任务 1.1 的 pbxproj 编辑 |
| F12 | 项目允许多类同文件（CLHistoryViewController 在 CLSettingsViewController.m 内） | 引擎与控制器同文件 |

---

### Task 1: 页面骨架 + Xcode 工程（tasks.md 1.1）

**Files:**
- Create: `ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.h`
- Create: `ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`
- Modify: `ChargeLimiter.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `CLBatteryCompatibilityTestViewController`（push 即用，`[[CLBatteryCompatibilityTestViewController alloc] init]`）；内部 `CLCompatCard`（卡片构建，本文件私有）；文件内同时声明引擎类前置占位（Task 3 实现）。

- [x] **Step 1: 创建 .h**

```objc
//
//  CLBatteryCompatibilityTestViewController.h
//  ChargeLimiter
//
//  电池兼容性测试页面 - 一键自动化停充/智能停充/禁流兼容性测试
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLBatteryCompatibilityTestViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
```

- [x] **Step 2: 创建 .m（骨架：枚举/常量/事件模型/卡片类/控制器 UI 构建占位）**

.m 文件顶部按序包含（本任务先落骨架，引擎留空壳，Task 3 填充）：

```objc
#import "CLBatteryCompatibilityTestViewController.h"
#import "CLAPIClient.h"
#import "CLBatteryManager.h"
#import "CLLocalization.h"
#import "CLSymbolImageSupport.h"
```

枚举与常量（全局约束参数逐字照抄）：

```objc
typedef NS_ENUM(NSInteger, CLCompatTestKind) {
    CLCompatTestKindStopCharge = 0,
    CLCompatTestKindSmartStopCharge = 1,
    CLCompatTestKindInflow = 2,
};

typedef NS_ENUM(NSInteger, CLCompatTestVerdict) {
    CLCompatTestVerdictPending = 0,   // 未测/待测
    CLCompatTestVerdictSupported,     // 支持
    CLCompatTestVerdictUnsupported,   // 无法支持
    CLCompatTestVerdictError,         // 写入失败/采集中断等
};

typedef NS_ENUM(NSInteger, CLCompatEventKind) {
    CLCompatEventKindPhaseChanged = 0, // 当前阶段文本变化
    CLCompatEventKindSample,           // 一次采样
    CLCompatEventKindStateChange,      // 状态变化事件
    CLCompatEventKindVerdict,          // 单项结论
    CLCompatEventKindFinished,         // 全部完成
    CLCompatEventKindAborted,          // 中止
};

static const NSTimeInterval CLCompatSampleInterval  = 1.0;
static const NSTimeInterval CLCompatMonitorLimit    = 120.0;
static const NSTimeInterval CLCompatConfirmWindow   = 10.0;
static const NSTimeInterval CLCompatConfirmWindowMax = 30.0;
static const NSInteger      CLCompatCurrentThresholdmA = 5;
static const NSTimeInterval CLCompatSettleLimit     = 15.0;
static NSString * const CLCompatSnapshotKey = @"cl_compat_test_snapshot";
```

事件模型：

```objc
@interface CLCompatTestEvent : NSObject
@property (nonatomic, assign) CLCompatEventKind kind;
@property (nonatomic, assign) CLCompatTestKind testKind;
@property (nonatomic, copy, nullable) NSString *message;       // 阶段/原因文本
@property (nonatomic, assign) NSInteger currentmA;             // 样本电流
@property (nonatomic, assign) NSTimeInterval elapsed;          // 该项已用秒
@property (nonatomic, assign) NSTimeInterval progress;         // 0~1
@property (nonatomic, assign) CLCompatTestVerdict verdict;
@property (nonatomic, assign) NSInteger maxCurrentmA;
@property (nonatomic, assign) NSInteger minCurrentmA;
@end
@implementation CLCompatTestEvent
@end
```

私有卡片类（对照 F10，模式仿 CLAdvSettingsCard）：

```objc
@interface CLCompatCard : UIView
@property (nonatomic, strong) UIStackView *contentStack;
- (UILabel *)addSectionHeader:(NSString *)title;
- (UIView *)addSwitchRowWithTitle:(NSString *)title isOn:(BOOL)isOn onChange:(void(^)(BOOL))onChange;
- (UIButton *)addActionButtonWithTitle:(NSString *)title color:(UIColor *)color handler:(void(^)(void))handler;
- (UILabel *)addValueRowWithTitle:(NSString *)title value:(NSString *)value;
- (UILabel *)addMultilineValueRowWithTitle:(NSString *)title value:(NSString *)value;
- (void)addSeparator;
- (void)addTipRow:(NSString *)text;
@end
```

实现要点：`contentStack` 垂直布局；卡片背景 `secondarySystemGroupedBackgroundColor`、圆角 12、内边距 16；行高 ≥40；`addMultilineValueRow` 的 value label `numberOfLines=0`。样式细节对照 CLSettingsViewController.m 内 CLGlassCard 实现抄写即可（图标可选，不强制）。

控制器骨架：`viewDidLoad` 建 `UIScrollView` + 垂直 `UIStackView`（`self.mainStack`），依次加入：说明卡片（tip 文案见 Task 8 文案表）、前置状态卡片（4 个 value row，引用存 `self.precheckRows` 字典，key 为 `daemon/plugged/charging/battery`）、选择卡片（3 个 switch 行，存 `self.testSwitches`）、开始按钮、进度卡片（`self.progressCard`：当前项 label、UIProgressView、已用时 label、实时电流 label、事件 label）、三个结果卡片（存 `self.resultCards[testKind]`，每张含结论 value row + 电流 value row + 耗时 value row，初始"未测试"）、总体判定卡片（`self.overallLabel`）、探针卡片（按钮 + 结果 multiline row）。运行态禁止交互的方法 `- (void)updateControlsForRunning:(BOOL)running`：开始/取消互斥、3 个 switch 与探针按钮 `enabled` 反向。

- [x] **Step 3: pbxproj 注册新文件（F11）**

1. `PBXFileReference` 区（锚点：`A720B95F2F2F0995008B9C91 /* CLAdvancedSettingsViewController.m */ = {isa = PBXFileReference;` 行之后）加：

```
		BB7C0A010000000000000001 /* CLBatteryCompatibilityTestViewController.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = CLBatteryCompatibilityTestViewController.m; sourceTree = "<group>"; };
		BB7C0A010000000000000002 /* CLBatteryCompatibilityTestViewController.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = CLBatteryCompatibilityTestViewController.h; sourceTree = "<group>"; };
```

2. `PBXBuildFile` 区加 3 条（.m only，.h 不编译）：

```
		BB7C0A010000000000000003 /* CLBatteryCompatibilityTestViewController.m in Sources */ = {isa = PBXBuildFile; fileRef = BB7C0A010000000000000001 /* CLBatteryCompatibilityTestViewController.m */; };
		BB7C0A010000000000000004 /* CLBatteryCompatibilityTestViewController.m in Sources */ = {isa = PBXBuildFile; fileRef = BB7C0A010000000000000001 /* CLBatteryCompatibilityTestViewController.m */; };
		BB7C0A010000000000000005 /* CLBatteryCompatibilityTestViewController.m in Sources */ = {isa = PBXBuildFile; fileRef = BB7C0A010000000000000001 /* CLBatteryCompatibilityTestViewController.m */; };
```

3. Controllers group children（锚点：`A720B95F2F2F0995008B9C91 /* CLAdvancedSettingsViewController.m */,` 的 group children 行）加两条 fileRef（.h/.m）。
4. 3 个 UI app target 的 Sources phase（锚点：`A720B9842F2F0995008B9C91 /* CLAdvancedSettingsViewController.m in Sources */,`、`A720B9A52F2F0995008B9C91 ...`、`5469A50775CC4D6F83F5C016 ...` 三行各对应一个 UI target 的 Sources phase）各加一条对应 BuildFile。**不得**加进 3 个 daemon target。
   - 注意：若 ID 与现有冲突，用未占用的 24 位十六进制替换（保持 BB7C0A01 前缀顺延）。

- [x] **Step 4: 编译验证**

Run: `xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [x] **Step 5: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.{h,m} ChargeLimiter.xcodeproj/project.pbxproj
git commit -m "feat(compat): 电池兼容性测试页面骨架与工程注册"
```

---

### Task 2: 主页入口卡片（tasks.md 1.2）

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m`（入口在 setupHistoryEntryCard 之后、setupMoreCard 之前；对照 5489-5493 行与 6076-6151 行模式）

**Interfaces:**
- Consumes: Task 1 的 `CLBatteryCompatibilityTestViewController`（文件顶部无需 import，用 `NSClassFromString` 与 advancedTapped 同款防御模式，见下）。

- [x] **Step 1: 在主页面 build 布局中插入入口调用**

锚点（约 5489-5493 行）：

```objc
    // 历史统计入口
    [self setupHistoryEntryCard];
    
    // 电池兼容性测试入口（历史统计下方）
    [self setupCompatTestEntryCard];
    
    // 充电高级入口
    [self setupMoreCard];
```

- [x] **Step 2: 实现 setupCompatTestEntryCard 与跳转**

在 `setupHistoryEntryCard` 方法（约 6076 行）之后新增，整体复制 `setupHistoryEntryCard` 的布局结构，仅改：图标 `stethoscope`、iconWrap 背景色 `systemIndigoColor`、标题 `CLL(@"电池兼容性测试")`、副标题 `CLL(@"一键检测停充 / 智能停充 / 禁流支持")`、target action `@selector(compatTestTapped)`、card 属性名 `self.compatTestEntryCard`（对应声明处加 `@property (nonatomic, strong) CLGlassCard *compatTestEntryCard;`，与 historyEntryCard 同区）。

跳转方法（与 advancedTapped 同款）：

```objc
- (void)compatTestTapped {
    Class vcClass = NSClassFromString(@"CLBatteryCompatibilityTestViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}
```

- [x] **Step 3: 编译验证**

Run: 同 Global Constraints rootful 命令
Expected: `** BUILD SUCCEEDED **`

- [x] **Step 4: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m
git commit -m "feat(compat): 主页更多功能区新增电池兼容性测试入口"
```

---

### Task 3: 引擎——前置检查（tasks.md 2.1）

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`（新增引擎类实现）

**Interfaces:**
- Produces（后续任务依赖，签名逐字）:

```objc
@interface CLBatteryCompatibilityEngine : NSObject
@property (nonatomic, copy) void (^onEvent)(CLCompatTestEvent *event);
// selection: 三项布尔（keyed by CLCompatTestKind 下标）
- (void)startWithSelection:(NSArray<NSNumber *> *)selection;
- (void)cancel;
+ (void)runPrecheckWithCompletion:(void(^)(NSDictionary<NSString *, NSNumber *> *results))completion;
// results keys: @"daemon" @"plugged" @"charging" @"battery"，值为 @(YES/@(NO)
+ (void)restoreSnapshot:(BOOL)alsoRestoreCharging completion:(nullable void(^)(BOOL ok))completion;
+ (BOOL)hasPendingSnapshot;
@end
```

- [x] **Step 1: 实现前置检查**

```objc
+ (void)runPrecheckWithCompletion:(void(^)(NSDictionary<NSString *, NSNumber *> *results))completion {
    NSMutableDictionary *r = @{@"daemon": @NO, @"plugged": @NO, @"charging": @NO, @"battery": @NO}.mutableCopy;
    [[CLAPIClient shared] getBatteryInfoWithCompletion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || ![resp[@"status"] intValue] == NO) { /* status!=0 视为 daemon 不在线 */ }
            NSDictionary *data = [resp isKindOfClass:[NSDictionary class]] ? resp[@"data"] : nil;
            BOOL daemonOK = (data != nil);
            BOOL plugged = [data[@"ExternalConnected"] boolValue];
            BOOL charging = [data[@"IsCharging"] boolValue];
            NSInteger cap = [data[@"CurrentCapacity"] integerValue];
            BOOL batteryOK = (cap >= 10 && cap <= 95);
            r[@"daemon"] = @(daemonOK);
            r[@"plugged"] = @(plugged);
            r[@"charging"] = @(charging);
            r[@"battery"] = @(batteryOK);
            if (completion) completion(r);
        });
    }];
}
```

注意：status 判定写法为 `if (error == nil && [resp[@"status"] integerValue] == 0) daemonOK = (data != nil);`，不要写成上面的占位比较。

- [x] **Step 2: 控制器接入前置检查**

点击开始时：先 `runPrecheckWithCompletion`；任一为 NO → 在前置卡片对应行标红显示提示文案（`CLL(@"未插电，请插电后重试")` / `CLL(@"daemon 未运行")` / `CLL(@"当前未在充电，无法测试")` / `CLL(@"电量需在 10%–95% 之间")`），不启动测试。全部 YES → 进入 Task 4 流程（快照）。

- [x] **Step 3: 编译验证**

Run: 同 rootful 命令；Expected: `** BUILD SUCCEEDED **`

- [x] **Step 4: Commit**

```bash
git add ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m
git commit -m "feat(compat): 测试前置检查（daemon/插电/充电中/电量范围）"
```

---

### Task 4: 引擎——配置快照与恢复（tasks.md 2.2）

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`

**Interfaces:**
- Consumes: Task 3 的 engine 类；`CLBatteryManager.saveConfigKey:value:completion:`（F8）。
- Produces: `+writeSnapshotWithCompletion:` / `+applySnapshotWithCompletion:` / `+clearSnapshot`（内部方法，Task 5/7 调用）；`+hasPendingSnapshot`（Task 6 页面进入检测用）。

- [x] **Step 1: 快照写入与恢复**

```objc
+ (void)writeSnapshotWithCompletion:(void(^)(BOOL ok))completion {
    // 先经 getConfig 读原值（不能读 CLBatteryManager 缓存，可能过期）
    [[CLAPIClient shared] getConfigWithKey:nil completion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        NSDictionary *data = (resp[@"data"] ?: @{}) ;
        BOOL enable = [data[@"enable"] boolValue];
        BOOL predictive = data[@"adv_predictive_inhibit_charge"] == nil ? YES : [data[@"adv_predictive_inhibit_charge"] boolValue];
        NSDictionary *snap = @{@"enable": @(enable), @"adv_predictive_inhibit_charge": @(predictive)};
        [NSUserDefaults.standardUserDefaults setObject:snap forKey:CLCompatSnapshotKey];
        if (completion) completion(YES);
    }];
}

+ (void)applySnapshotWithCompletion:(void(^)(BOOL ok))completion {
    NSDictionary *snap = [NSUserDefaults.standardUserDefaults dictionaryForKey:CLCompatSnapshotKey];
    if (snap.count == 0) { if (completion) completion(YES); return; }
    dispatch_group_t g = dispatch_group_create();
    __block BOOL ok = YES;
    dispatch_group_enter(g);
    [[CLBatteryManager shared] saveConfigKey:@"enable" value:snap[@"enable"] ?: @YES completion:^(BOOL s) { if (!s) ok = NO; dispatch_group_leave(g); }];
    dispatch_group_enter(g);
    [[CLBatteryManager shared] saveConfigKey:@"adv_predictive_inhibit_charge" value:snap[@"adv_predictive_inhibit_charge"] ?: @YES completion:^(BOOL s) { if (!s) ok = NO; dispatch_group_leave(g); }];
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        [NSUserDefaults.standardUserDefaults removeObjectForKey:CLCompatSnapshotKey];
        if (completion) completion(ok);
    });
}
+ (BOOL)hasPendingSnapshot { return [NSUserDefaults.standardUserDefaults dictionaryForKey:CLCompatSnapshotKey].count > 0; }
```

- [x] **Step 2: 残留快照检测（页面进入）**

控制器 `viewWillAppear`：`[CLBatteryCompatibilityEngine hasPendingSnapshot]` 为 YES → 弹 `UIAlertController`：标题 `CLL(@"检测到未完成的测试")`，消息 `CLL(@"上次测试未正常结束，是否恢复配置？")`，按钮"恢复"（调 `applySnapshotWithCompletion:`，完成后提示 `CLL(@"配置已恢复")`）与"丢弃"（直接 `removeObjectForKey:`）。

- [x] **Step 3: 三路径恢复接线**

- 完成：全部测试结束 → 恢复充电/禁流（Task 5）→ `applySnapshotWithCompletion:` → 发 `Finished` 事件。
- 取消：`cancel` → 中止当前轮询 → 恢复充电/禁流 → `applySnapshotWithCompletion:` → 发 `Aborted` 事件（message=`CLL(@"已取消并恢复配置")`）。
- 离开页面：`viewWillDisappear` 中若 `self.engineRunning` → 调 `cancel`（等价取消路径）。

- [x] **Step 4: 编译验证 + Commit**

Run: 同 rootful 命令；Expected: `** BUILD SUCCEEDED **`

```bash
git add ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m
git commit -m "feat(compat): 配置快照持久化与完成/取消/离开三路径恢复"
```

---

### Task 5: 引擎——状态机与三项测试判定（tasks.md 2.3）

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`

**Interfaces:**
- Consumes: Task 3/4 的方法；`CLAPIClient.setChargeStatus:completion:` / `setInflowStatus:completion:` / `getBatteryInfoWithCompletion:`。
- Produces: `- (void)startWithSelection:`（完整可跑）；采样结构 `CLCompatSample { NSInteger currentmA; BOOL isCharging; BOOL extCapable; BOOL extConnected; NSInteger capacity; }`。

- [x] **Step 1: 单项测试定义**

```objc
// 每项：kind、路径配置切换、发送的 API
// StopCharge:      先 saveConfigKey(@"adv_predictive_inhibit_charge", @NO) → setChargeStatus:NO
// SmartStopCharge: 先 saveConfigKey(@"adv_predictive_inhibit_charge", @YES) → setChargeStatus:NO
// Inflow:          （全局开关已在快照阶段关闭）→ setInflowStatus:NO
```

- [x] **Step 2: 主流程 startWithSelection:**

```
1) writeSnapshotWithCompletion
2) saveConfigKey(@"enable", @NO)   // 关全局开关（F1/F2：daemon 自动恢复充电，正是基线）
3) 依次对 selection 中为 YES 的项 runTestCase，每项之间 settleAndRestoreCharging
4) 全部结束 → restoreInflowIfAbnormal → applySnapshotWithCompletion → emit(Finished)
```

- [x] **Step 3: runTestCase 单项状态机（核心，逐字实现）**

```objc
// 阶段: Waiting  = 监测状态变化(上限120s)
//       Confirm  = 状态变化后确认窗口(10s；混合延长至30s按均值)
- (void)runTestCase:(CLCompatTestKind)kind done:(void(^)(void))done {
    self.maxA = NSIntegerMin; self.minA = NSIntegerMax;
    self.samples = [NSMutableArray array];           // NSNumber 电流值
    self.elapsed = 0; self.changeElapsed = -1; self.confirmSamples = 0; self.extended = NO;
    // 基线检查：非充电态 → 该项 Error（文案 CLL(@"基线异常：当前未在充电")）
    // 1) 路径配置切换（见 Step 1 表）→ 2) 发送停充/禁流 API
    //    API 返回 status!=0 → emit Verdict(Error, CLL(@"控制面写入失败")) → done
    // 3) 每 1s（dispatch_source_t timer，主队列）采样：
    //    getBatteryInfoWithCompletion → data 解析 CLCompatSample（F6/F：电流优先 InstantAmperage 回退 Amperage）
    //    连续失败 ≥5 次 → Verdict(Error, CLL(@"数据采集中断")) → 清理 timer → done
    //    maxA/minA 更新；emit(Sample, current, elapsed, progress = elapsed/120)
    - Watching:
    //    kind==Inflow ? 状态变化 = (!extCapable || !extConnected || !isCharging || currentmA < 0)   // F9 以电流特征为主
    //                 : 状态变化 = !isCharging
    //    状态变化 → changeElapsed = elapsed; phase=Confirm
    //    elapsed ≥ 120 且无变化 → Verdict(Unsupported, CLL(@"120 秒内充电状态无变化")) → 清理 → done
    - Confirm:
    //    confirmSamples 计数达到 10 时：
    //      最近 10 样本全部 < 5mA → Verdict(Supported)   // 早停
    //      最近 10 样本全部 ≥ 5mA → Verdict(Unsupported, CLL(@"停充后电流持续 ≥5mA"))
    //      混合 → 若 !extended: extended=YES 继续至 30 样本按均值(<5mA 支持)
    //             已 extended: 按 30 样本均值判定
    //    Verdict 事件携带 maxCurrentmA/minCurrentmA/changeElapsed → 清理 timer → done
}
```

- [x] **Step 4: 回稳**

```objc
- (void)settleAndRestoreCharging:(void(^)(BOOL settled))done {
    // setChargeStatus:YES → 轮询等待 IsCharging==YES && currentmA>0，最长 15s
    // 超时未回稳 → self.restoreWarning = CLL(@"测试后充电恢复异常，请手动检查") （不中止流程）
}
// 禁流项结束后额外 setInflowStatus:YES 再走上述回稳
```

- [x] **Step 5: 每项开始前全局开关复核**

`startWithSelection` 内每项 runTestCase 前 `getConfigWithKey:@"enable"`：若为 YES → 取消剩余项，emit Aborted（`CLL(@"CL 已被重新启用，测试中止")`）→ applySnapshot。

- [x] **Step 6: 编译验证 + Commit**

Run: 同 rootful 命令；Expected: `** BUILD SUCCEEDED **`

```bash
git add ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m
git commit -m "feat(compat): 测试状态机与停充/智能停充/禁流判定引擎"
```

---

### Task 6: 单项选择 + 进度/结果 UI 接线（tasks.md 2.4 / 3.1 / 3.2）

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`

**Interfaces:**
- Consumes: Task 1 骨架的 `self.testSwitches` / `self.progressCard` / `self.resultCards` / `self.overallLabel`；Task 5 引擎完整事件流。

- [x] **Step 1: 单项选择**

开始按钮 handler 读 3 个 switch 的 state 组装 `selection = @[@(stopOn), @(smartOn), @(inflowOn)]`（下标=CLCompatTestKind）。三项全关 → 提示 `CLL(@"请至少选择一项测试")`。测试运行中 switch disabled（Task 1 的 updateControlsForRunning 已做）。

- [x] **Step 2: onEvent 事件 → UI 映射（主队列）**

| 事件 | UI 行为 |
|------|---------|
| PhaseChanged | 进度卡片"当前项"label = message；开始按钮→取消样式 |
| Sample | 实时电流 label = `format:@"%ld mA"`；progressView.progress = progress；已用时 label = `%.0fs / 约 %ds`（剩余 = max(0, 120-elapsed)） |
| StateChange | 事件 label = `CLL(@"检测到状态变化（%ds）")` |
| Verdict | 对应结果卡：结论 row = 支持绿 `systemGreenColor` / 无法支持红 `systemRedColor` / 异常橙 `systemOrangeColor`；电流 row = `max %ld mA · min %ld mA`；耗时 row = `CLL(@"状态变化耗时 %ds")`（changeElapsed<0 显示"—"）；重置进度条 |
| Finished | 进度卡片显示 `CLL(@"测试完成")`；updateControlsForRunning:NO；若 restoreWarning 非空在总体卡片下加橙色警告 row |
| Aborted | 进度卡片显示 aborted message；updateControlsForRunning:NO |

- [x] **Step 3: 总体判定**

Verdict 收齐后（Finished 事件里算）：`(stop==Supported || smart==Supported)` 且 `inflow==Supported` → `CLL(@"设备支持 CL 充电控制")`；仅智能停充支持 → `CLL(@"仅智能停充可用，建议开启充电高级-智能停充")`；停充与智能停充均不支持且禁流不支持 → 红色 `CLL(@"既不支持停充也不支持禁流，设备不被 CL 支持")`；其余组合给"部分能力可用，建议结合探针结果判断"。文案 key 全部进 Task 8 表。

- [x] **Step 4: 编译验证 + Commit**

Run: 同 rootful 命令；Expected: `** BUILD SUCCEEDED **`

```bash
git add ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m
git commit -m "feat(compat): 单项选择、实时进度与结果/总体判定展示"
```

---

### Task 7: 探针入口（tasks.md 4.1）

**Files:**
- Modify: `ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m`

**Interfaces:**
- Consumes: `CLAPIClient.runChargeControlProbeWithWaitMs:restore:paths:services:completion:`（waitMs=2000, restore=YES, paths/services 传 nil 用 daemon 默认）；F7 结果结构。

- [x] **Step 1: 探针按钮 handler**

复制 CLAdvancedSettingsViewController `runChargeControlProbeTapped` 模式：确认弹窗（消息 `CLL(@"将尝试多种停充写法并自动恢复，整轮可能需要 1–2 分钟。请插着充电器运行。")`）→ 运行中置 `self.probeRunning=YES`（按钮禁用；**同时**若测试运行中也禁用，见 Task 1 updateControlsForRunning）→ completion 中 status==-1x（probe_busy）→ 提示 `CLL(@"探针正在运行，请稍候")` → 成功后解析 `data.summary`：

```objc
// any_effective==YES → CLL(@"探针结论：控制面可生效（best_path: %@）"), summary[@"best_path"]
// 否则 → CLL(@"探针结论：未发现可生效写法（dominant_failure: %@）"), summary[@"dominant_failure"]
```

结果写入探针卡片 multiline row；附"复制详细"按钮（照 `chargeControlProbeExportTextFromPayload` 拼文本 → `UIPasteboard`）。

- [x] **Step 2: 编译验证 + Commit**

Run: 同 rootful 命令；Expected: `** BUILD SUCCEEDED **`

```bash
git add ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m
git commit -m "feat(compat): 页面内停充控制探针入口与结果摘要"
```

---

### Task 8: 双语文案（tasks.md 4.2）

**Files:**
- Modify: `ChargeLimiter/en.lproj/Localizable.strings`
- Modify: `ChargeLimiter/zh-Hans.lproj/Localizable.strings`

- [x] **Step 1: 两个 strings 文件末尾同步追加以下全部 key（zh-Hans 值=key 本身；en 值用右侧英文）**

```
"电池兼容性测试" = "Battery Compatibility Test";
"一键检测停充 / 智能停充 / 禁流支持" = "One-tap stop-charge / smart-stop / inflow test";
"测试会短暂停充或禁流（每项最长 2 分钟），结束后自动恢复配置。" = "Tests briefly stop charging or inflow (up to 2 min each); settings restore automatically.";
"前置检查" = "Preconditions";
"daemon 在线" = "daemon online";
"已插电" = "Plugged in";
"正在充电" = "Charging now";
"电量 10%–95%" = "Battery 10%–95%";
"未插电，请插电后重试" = "Not plugged in. Connect power and retry.";
"daemon 未运行" = "daemon is not running";
"当前未在充电，无法测试" = "Not charging now; cannot run the test.";
"电量需在 10%–95% 之间" = "Battery level must be 10%–95%.";
"停充测试" = "Stop-Charge Test";
"智能停充测试" = "Smart Stop Test";
"禁流测试" = "Inflow Test";
"开始测试" = "Start Test";
"取消测试" = "Cancel Test";
"请至少选择一项测试" = "Select at least one test.";
"当前测试" = "Current test";
"实时电流" = "Live current";
"已用时" = "Elapsed";
"检测到状态变化（%ds）" = "State changed (%ds)";
"支持" = "Supported";
"无法支持" = "Not supported";
"未测试" = "Not tested";
"异常" = "Error";
"最大电流" = "Max current";
"最低电流" = "Min current";
"状态变化耗时 %ds" = "State changed in %ds";
"120 秒内充电状态无变化" = "No charge-state change within 120s";
"停充后电流持续 ≥5mA" = "Current stays ≥5mA after stop";
"控制面写入失败" = "Control-plane write failed";
"数据采集中断" = "Sampling interrupted";
"基线异常：当前未在充电" = "Baseline error: not charging";
"测试完成" = "Tests finished";
"设备支持 CL 充电控制" = "This device supports CL charge control";
"仅智能停充可用，建议开启充电高级-智能停充" = "Only smart stop works; enable Smart Stop in Advanced";
"既不支持停充也不支持禁流，设备不被 CL 支持" = "Neither stop-charge nor inflow works; this device is NOT supported by CL";
"部分能力可用，建议结合探针结果判断" = "Partial capability; check the probe result";
"测试后充电恢复异常，请手动检查" = "Charging did not resume after test; check manually";
"已取消并恢复配置" = "Cancelled and settings restored";
"CL 已被重新启用，测试中止" = "CL was re-enabled; test aborted";
"检测到未完成的测试" = "Unfinished test detected";
"上次测试未正常结束，是否恢复配置？" = "Last test didn't finish. Restore settings?";
"恢复" = "Restore";
"丢弃" = "Discard";
"配置已恢复" = "Settings restored";
"运行停充控制探针" = "Run Charge Control Probe";
"将尝试多种停充写法并自动恢复，整轮可能需要 1–2 分钟。请插着充电器运行。" = "Tries multiple stop-charge writes and restores automatically; may take 1–2 min. Keep the charger plugged in.";
"探针正在运行，请稍候" = "Probe already running, please wait";
"探针结论：控制面可生效（best_path: %@）" = "Probe: control plane works (best_path: %@)";
"探针结论：未发现可生效写法（dominant_failure: %@）" = "Probe: no effective write found (dominant_failure: %@)";
"复制详细" = "Copy details";
```

- [x] **Step 2: 编译验证 + Commit**

Run: 同 rootful 命令；Expected: `** BUILD SUCCEEDED **`

```bash
git add ChargeLimiter/en.lproj/Localizable.strings ChargeLimiter/zh-Hans.lproj/Localizable.strings
git commit -m "feat(compat): 电池兼容性测试双语文案"
```

---

### Task 9: 双方案编译与打包验证（tasks.md 5.1 / 5.2）

**Files:** 无源码改动（纯验证；如编译报错则修复后重跑）。

- [x] **Step 1: rootful 编译**

Run: Global Constraints rootful 命令；Expected: `** BUILD SUCCEEDED **`

- [x] **Step 2: rootless 编译**

Run: Global Constraints rootless 命令；Expected: `** BUILD SUCCEEDED **`

- [x] **Step 3: 打包冒烟**

Run: `./scripts/build_packages.sh`
Expected: 四类包（TrollStore/rootful/rootless/roothide）产出成功，退出码 0。

- [x] **Step 4: 真机冒烟（手动，记录结果到 tasks.md 5.2 勾选项说明）**——已执行部分：无（用户暂不可用）。处置：显式记录为延期开放项移交验证/归档阶段，见 tasks.md"开放验证项"

清单：安装 → 主页入口位于历史统计下方 → 进入页面 → 完整一键测试（三项依次、结果与 README 手动判定一致、配置恢复）→ 早停生效 → 单项重测（只勾禁流）→ 取消/返回恢复 → 探针按钮 → 切英文 → 测试中强杀 App 后重进触发残留快照恢复提示。

- [x] **Step 5: Commit（如有修复）**

```bash
git add -A
git commit -m "chore(compat): 双方案编译与打包验证修复"
```

---

## Self-Review 结论

- Spec 覆盖：11 条 Requirement 全部映射到 Task 1–9（入口=T1/T2、前置=T3、编排=T5、单项=T6、判定=T5、快照=T4、进度=T6、结果/总体=T6、探针=T7、双语=T8、验证=T9）。
- 类型一致性：`CLCompatTestKind/Verdict/EventKind`、`CLCompatTestEvent`、engine 方法签名在 T1/T3/T4/T5/T6 间一致；快照 key、阈值常量全文一致。
- 无占位符；pbxproj 锚点与 ID 规则明确（F11）。
