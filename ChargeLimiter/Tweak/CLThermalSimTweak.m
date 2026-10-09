// CLThermalSim —— ChargeLimiter 温控模拟执行端（thermal-sim-mikasa-rewrite：
// 完全模仿 Mikasa-san:Powercuff 机制）。仅注入 thermalmonitord（见 CLThermalSim.plist）。
// 档位经内核 notify state 传输——真机实证 thermalmonitord 内 CFPreferences 读不到
// root 进程的偏好写入（偏好镜像通路全链无效），内核态是唯一生效通路（Powercuff
// 全系同款）。零运行时偏好读取；唯一例外：进程启动时单次 best-effort 读会话键
// 做跨重启重挂（重启后内核态归零）。
//
// 双通道（写方 = daemon/CLI root 进程；会话启用期间本 tweak 亦写档位通道）：
//   com.chargelimiter.thermalapply   档位通道，state = 0=off/1=nominal/2=light/3=moderate/4=heavy
//   com.chargelimiter.thermalsession 会话通道，state = enabled(bit0) | 充电时档位(bit8-15) | 平时档位(bit16-23)
// 完整控制模式（会话未启用）档位通道归 daemon 独写，本 tweak 不干预。
//
// 分时段会话（limit-only-idle-thermal-level）：插电且系统正在充电 → 充电时档位；
// 未插电或插线未充电 → 平时档位。两侧皆可为零（=该时段不施加热模拟）。
// 旧安装只写 bits8-15，bits16-23 为 0 天然解读为"平时档位关闭"，升级不错档。
//
// 仅限流会话（limit-only daemon-free，spec B2）：由电池属性 interest、IOPS 电源源通知
// 与会话通道通知驱动（IOKit 插电/充电判定，不碰偏好）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>

// IOKit 电源源通知（HIPCharge 同款原语，iOS SDK 无公开头——IOKit.tbd 已导出符号）。
// 电源状态任何变化（插/拔/适配器细节）都会触发回调，是"App 不在场"插拔边沿的主修复。
extern CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(void (*callback)(void *context),
                                                              void *context);

static NSString * const CLTSApplyNotification = @"com.chargelimiter.thermalapply";
static NSString * const CLTSSessionNotification = @"com.chargelimiter.thermalsession";

static int CLTSApplyToken = -1;
static int CLTSSessionToken = -1;

// Mikasa 同款：强引用捕获，无 dealloc hook。
static id CLTSCurrentProduct = nil;

#pragma mark - 档位编码（Powercuff 编码）

static NSString *CLTSStringForThermalMode(uint64_t mode) {
    switch (mode) {
        case 1: return @"nominal";
        case 2: return @"light";
        case 3: return @"moderate";
        case 4: return @"heavy";
        default: return @"off";
    }
}

static uint64_t CLTSModeValueForString(NSString *mode) {
    if ([mode isEqualToString:@"nominal"]) return 1;
    if ([mode isEqualToString:@"light"]) return 2;
    if ([mode isEqualToString:@"moderate"]) return 3;
    if ([mode isEqualToString:@"heavy"]) return 4;
    return 0;
}

#pragma mark - 档位应用（Mikasa ApplyThermals 同款）

static void CLTSApplyThermals(void) {
    if (CLTSCurrentProduct == nil) return;
    if (![CLTSCurrentProduct respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) return;
    uint64_t mode = 0;
    notify_get_state(CLTSApplyToken, &mode);
    NSString *modeString = CLTSStringForThermalMode(mode);
    NSLog(@"[CLThermalSim] apply mode=%@", modeString); // 生命周期日志：注入/应用的直接证据
    // off 也下发：清除已生效档位（还原语义）。
    ((void (*)(id, SEL, NSString *))objc_msgSend)(CLTSCurrentProduct,
                                                  @selector(putDeviceInThermalSimulationMode:),
                                                  modeString);
}

#pragma mark - 会话边沿（内核态 + IOKit，零偏好）

// 插电判定（Bug B2 2026-10-05 真机修正）：ExternalChargeCapable 与 ExternalConnected
// 任一为真即插电——首插瞬间 capable 可能尚未发布，严格"capable 优先、缺失才看
// connected"会误判未插电并清掉限流；误判"插电"（保留限流）是更安全的错误方向。
static BOOL CLTSPowerConnected(void) {
    io_service_t serv = IOServiceGetMatchingService(0, // kIOMasterPortDefault：iOS SDK 标记不可用，值即 0
                                                    IOServiceMatching("AppleSmartBattery"));
    if (serv == IO_OBJECT_NULL) return NO;
    BOOL connected = NO;
    CFTypeRef capable = IORegistryEntryCreateCFProperty(serv, CFSTR("ExternalChargeCapable"), kCFAllocatorDefault, 0);
    CFTypeRef connectedRef = IORegistryEntryCreateCFProperty(serv, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
    if (capable != NULL && CFGetTypeID(capable) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)capable)) {
        connected = YES;
    }
    if (connectedRef != NULL && CFGetTypeID(connectedRef) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)connectedRef)) {
        connected = YES;
    }
    if (capable) CFRelease(capable);
    if (connectedRef) CFRelease(connectedRef);
    IOObjectRelease(serv);
    return connected;
}

// 充电判定（limit-only-idle-thermal-level）：IsCharging 为真即正在充电。
// 属性缺失或类型不符时按"正在充电"处理——与插电判定同向的容错：误判"充电"会保留
// 限流（更安全的错误方向），误判"未充电"会让插电时的限流静默失效。
// 对应「完整控制」的"充电命令开启"：那一侧是 ChargeLimiter 自己的停充命令，仅限流模式下
// daemon 不驻留、ChargeLimiter 无法停充，现实条件就是系统是否正在充电。
static BOOL CLTSIsCharging(void) {
    io_service_t serv = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"));
    if (serv == IO_OBJECT_NULL) return YES;
    BOOL charging = YES;
    CFTypeRef ref = IORegistryEntryCreateCFProperty(serv, CFSTR("IsCharging"), kCFAllocatorDefault, 0);
    if (ref != NULL) {
        if (CFGetTypeID(ref) == CFBooleanGetTypeID()) {
            charging = CFBooleanGetValue((CFBooleanRef)ref);
        }
        CFRelease(ref);
    }
    IOObjectRelease(serv);
    return charging;
}

// 会话通道解码：enabled(bit0) + 充电时档位(bit8-15) + 平时档位(bit16-23)。
// bits16-23 为 0 = 平时档位关闭；旧安装（只带单档位）读到这里也是 0，解读一致。
static BOOL CLTSSessionConfig(uint64_t *chargeMode, uint64_t *idleMode) {
    uint64_t state = 0;
    notify_get_state(CLTSSessionToken, &state);
    *chargeMode = (state >> 8) & 0xFF;
    *idleMode = (state >> 16) & 0xFF;
    return (state & 1ULL) != 0;
}

// 会话重算：插电且系统正在充电 → 充电时档位；否则 → 平时档位。两侧皆可为零。
// 会话未启用直接返回——完整控制模式档位通道归 daemon 独写。
static void CLTSUpdateReassertTimer(void); // 前置声明（定义在会话重算之后）

static void CLTSSessionEvaluate(void) {
    uint64_t charge = 0;
    uint64_t idle = 0;
    // 门控刷新先于早退（Verifier risks 修复）：会话禁用时也要停表——否则
    // enabled→disabled 切换后 30s 定时器永不停止（tick 空转早退，无行为影响但不卫生）
    CLTSUpdateReassertTimer();
    if (!CLTSSessionConfig(&charge, &idle)) return;
    BOOL plugged = CLTSPowerConnected();
    // 插电未充电（系统优化充电 / 80% 限制暂停）归"平时"一侧，与「完整控制」同口径
    BOOL charging = plugged && CLTSIsCharging();
    uint64_t target = charging ? charge : idle;
    NSLog(@"[CLThermalSim] session evaluate enabled=1 charge=%llu idle=%llu plugged=%d charging=%d target=%llu",
          (unsigned long long)charge, (unsigned long long)idle, plugged, charging,
          (unsigned long long)target); // 边沿取证（Bug A/B2 排障）
    notify_set_state(CLTSApplyToken, target);
    CLTSApplyThermals();
}

// === 会话 watchdog（thermal-limit-edge-reliability；Verifier 失败轮修订）===
// 会话启用期间 30s 周期性完整会话重评估：重读插电态（IOKit）→ 应用/清除档位 → 刷新
// 门控。修复盲重放缺陷：旧版 handler 只重放档位通道、不复查门控——拔电/注销后若边沿
// （IOPS/interest）失灵，旧档位被每 30s 钉死。现为 watchdog 语义：无论边沿死活，
// 会话启用期间世界必然在 ≤30s 内收敛（用户认可的 30s 检查一次模型）。
// 注销（respring）只重启 SpringBoard，thermalmonitord 与本定时器都存活——拔电残留
// 由 tick 重评估清除。单次成本=IOKit 插电读+内核态读+一次重放，30s 节奏可忽略。
static dispatch_source_t CLTSReassertTimer = NULL;

static void CLTSUpdateReassertTimer(void) {
    uint64_t charge = 0;
    uint64_t idle = 0;
    BOOL enabled = CLTSSessionConfig(&charge, &idle);
    BOOL shouldRun = enabled; // 会话启用即运行：未插电时 tick 评估→应用平时档位（幂等自愈）
    if (shouldRun && CLTSReassertTimer == NULL) {
        CLTSReassertTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                   dispatch_get_main_queue());
        if (CLTSReassertTimer != NULL) {
            dispatch_source_set_timer(CLTSReassertTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                                      30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(CLTSReassertTimer, ^{
                NSLog(@"[CLThermalSim] watchdog tick"); // A3/恢复取证：log show 可检索
                CLTSSessionEvaluate(); // 完整重评估：重读插电态→应用/清除→刷新门控（含本定时器起停）
            });
            dispatch_resume(CLTSReassertTimer);
        }
    } else if (!shouldRun && CLTSReassertTimer != NULL) {
        dispatch_source_cancel(CLTSReassertTimer);
        // cancel 后由 block 持有的引用释放；置 nil 允许下次重建
        CLTSReassertTimer = NULL;
    }
}

// 电池属性变化（插拔边沿）回调：会话重算。消息类型不区分——任何属性变化都重算。
static void CLTSBatteryInterestCallback(void *refcon, io_service_t service, natural_t messageType, void *messageArgument) {
    CLTSSessionEvaluate();
}

// IOPS 电源源变化回调（主边沿）：会话重算——插/拔/适配器细节变化均触发。
static void CLTSPowerSourceChanged(void *context) {
    CLTSSessionEvaluate();
}

#pragma mark - 跨重启重挂（单次 best-effort 偏好读取）

// 读一个 com.apple.cltm 字符串键；缺失或类型不符返回 nil（调用方按关闭处理）。
static NSString *CLTSCopyLimitOnlyMode(CFStringRef key) {
    CFTypeRef ref = CFPreferencesCopyAppValue(key, CFSTR("com.apple.cltm"));
    if (ref == NULL) return nil;
    NSString *value = nil;
    if (CFGetTypeID(ref) == CFStringGetTypeID()) {
        value = [(__bridge NSString *)ref copy];
    }
    CFRelease(ref);
    return value;
}

// 重启后内核态归零。从持久化会话键尽力恢复会话通道并重算（本进程首次偏好访问，
// 与运行期缓存不可见问题不同路径）；读不到/未启用则维持 off。此后运行期零偏好读取。
// 两个档位键分别缺键按关闭（limit-only-idle-thermal-level）：旧安装只有 clLimitMode，
// 恢复出来就是"充电时档位有值、平时档位关闭"，与升级前的实际效果一致。
static void CLTSRestoreSessionFromPrefs(void) {
    CFTypeRef enabledRef = CFPreferencesCopyAppValue(CFSTR("clLimitSessionEnabled"),
                                                     CFSTR("com.apple.cltm"));
    BOOL enabled = NO;
    if (enabledRef != NULL) {
        if (CFGetTypeID(enabledRef) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)enabledRef);
        } else if (CFGetTypeID(enabledRef) == CFNumberGetTypeID()) {
            enabled = [(__bridge NSNumber *)enabledRef boolValue];
        }
        CFRelease(enabledRef);
    }
    if (!enabled) return;
    uint64_t charge = CLTSModeValueForString(CLTSCopyLimitOnlyMode(CFSTR("clLimitMode")));
    uint64_t idle = CLTSModeValueForString(CLTSCopyLimitOnlyMode(CFSTR("clLimitIdleMode")));
    notify_set_state(CLTSSessionToken, 1ULL | (charge << 8) | (idle << 16));
    CLTSSessionEvaluate();
}

#pragma mark - Hook 替换实现（仅 initProduct:，Mikasa 同款）

static IMP CLTSOrigInitProduct = NULL;

static id CLTSInitProductOverride(id self, SEL _cmd, id data) {
    id result = CLTSOrigInitProduct ? ((id (*)(id, SEL, id))CLTSOrigInitProduct)(self, _cmd, data) : nil;
    if (result == nil) return nil; // 原实现失败：不捕获不应用
    if ([result respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
        CLTSCurrentProduct = result; // 强引用捕获（Mikasa 同款）
        NSLog(@"[CLThermalSim] product captured"); // 生命周期日志：hook 已生效的直接证据
    }
    CLTSApplyThermals(); // thermalmonitord 重启重放：内核态即真相
    return result;
}

// 产品对象释放（break98pl 同款卫生 hook）：thermalmonitord 会重建产品对象——
// 旧捕获若不清空，后续下发打到已释放对象上（僵尸下发：无效甚至有害）。
// initProduct: 重建路径会重新捕获并即时重放，此处只负责清旧。
static IMP CLTSOrigDealloc = NULL;

static void CLTSDeallocOverride(id self, SEL _cmd) {
    if (CLTSCurrentProduct == self) {
        CLTSCurrentProduct = nil; // 清捕获，防僵尸下发
        NSLog(@"[CLThermalSim] product released");
    }
    if (CLTSOrigDealloc) ((void (*)(id, SEL))CLTSOrigDealloc)(self, _cmd);
}

static void CLTSHookSelector(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m == nil) return; // selector 缺失：跳过，不产生副作用
    IMP prev = method_setImplementation(m, newImp);
    if (prev && *origOut == NULL) *origOut = prev;
}

#pragma mark - 入口

static IONotificationPortRef CLTSNotifyPort = NULL;
static io_object_t CLTSBatteryNotifier = IO_OBJECT_NULL;

__attribute__((constructor)) static void CLTSInit(void) {
    @autoreleasepool {
        Class productClass = objc_getClass("CommonProduct");
        NSLog(@"[CLThermalSim] ctor loaded productClass=%@", productClass != nil ? @"yes" : @"no");
        if (productClass != nil) { // 类缺失（系统变更）：静默退回
            CLTSHookSelector(productClass, @selector(initProduct:), (IMP)CLTSInitProductOverride, &CLTSOrigInitProduct);
            // 捕获卫生（break98pl）：产品对象释放时清捕获，防僵尸下发
            CLTSHookSelector(productClass, sel_registerName("dealloc"), (IMP)CLTSDeallocOverride, &CLTSOrigDealloc);
        }
        // 双通道（Mikasa 同款 notify_register_dispatch，主队列）：
        // 档位通知 → 即时下发；会话通知 → 会话边沿重算。
        uint32_t applyReg = notify_register_dispatch([CLTSApplyNotification UTF8String], &CLTSApplyToken,
                                 dispatch_get_main_queue(), ^(int token) {
            CLTSApplyThermals();
        });
        uint32_t sessionReg = notify_register_dispatch([CLTSSessionNotification UTF8String], &CLTSSessionToken,
                                 dispatch_get_main_queue(), ^(int token) {
            CLTSSessionEvaluate();
        });
        // Bug A 修复（2026-10-05 真机）：注销（respring）不清内核态——apply 通道残留的
        // 旧档位会被下方 initProduct 重放。无条件评估一次会话（读内核态会话配置 +
        // IOKit 插电判定）：未插电 → 清残留为 off；插电 → 按配置应用。不依赖偏好可读。
        CLTSSessionEvaluate();
        // 跨重启重挂：会话偏好仍启用则恢复会话通道并重算（产品实例就绪前只落内核态，
        // 由 initProduct 重放补一次下发）。重启后内核态归零，此处是偏好 best-effort 兜底。
        CLTSRestoreSessionFromPrefs();
        // 电池属性 interest（插拔边沿，次要）：注册失败静默降级——IOPS 通知兜底。
        CLTSNotifyPort = IONotificationPortCreate(0); // master port 0（iOS）
        if (CLTSNotifyPort != NULL) {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(CLTSNotifyPort),
                               kCFRunLoopDefaultMode);
            io_service_t battery = IOServiceGetMatchingService(0,
                                                               IOServiceMatching("AppleSmartBattery"));
            if (battery != IO_OBJECT_NULL) {
                IOServiceAddInterestNotification(CLTSNotifyPort,
                                                 battery,
                                                 "IOServiceInterestNotifications", // kIOInterestNotifications 宏值（iOS SDK 头缺失）
                                                 CLTSBatteryInterestCallback,
                                                 NULL,
                                                 &CLTSBatteryNotifier);
                IOObjectRelease(battery);
            }
        }
        // IOPS 电源源通知（主边沿，HIPCharge 同款原语）：插/拔/适配器细节变化 → 会话
        // 重算——App 不在场时的插拔可靠性由它承担（D3：进 tweak 而非独立守护进程）。
        CFRunLoopSourceRef CLTSPowerSourceRef = IOPSNotificationCreateRunLoopSource(CLTSPowerSourceChanged, NULL);
        if (CLTSPowerSourceRef != NULL) {
            CFRunLoopAddSource(CFRunLoopGetMain(), CLTSPowerSourceRef, kCFRunLoopDefaultMode);
        }
        // 生命周期日志（零行为改动）：注入/注册/重挂一次性快照，log show 按
        // thermalmonitord 进程检索（[CLThermalSim] 前缀）。
        uint64_t restoredCharge = 0;
        uint64_t restoredIdle = 0;
        BOOL restoredEnabled = CLTSSessionConfig(&restoredCharge, &restoredIdle);
        NSLog(@"[CLThermalSim] ctor done apply_reg=%u session_reg=%u interest=%@ iops=%@ restore_enabled=%d restore_charge=%llu restore_idle=%llu",
              applyReg, sessionReg,
              CLTSBatteryNotifier != IO_OBJECT_NULL ? @"ok" : @"failed",
              CLTSPowerSourceRef != NULL ? @"ok" : @"failed",
              restoredEnabled, (unsigned long long)restoredCharge, (unsigned long long)restoredIdle);
    }
}
