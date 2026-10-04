// CLThermalSim —— ChargeLimiter 温控模拟执行端（thermal-sim-mikasa-rewrite：
// 完全模仿 Mikasa-san:Powercuff 机制）。仅注入 thermalmonitord（见 CLThermalSim.plist）。
// 档位经内核 notify state 传输——真机实证 thermalmonitord 内 CFPreferences 读不到
// root 进程的偏好写入（偏好镜像通路全链无效），内核态是唯一生效通路（Powercuff
// 全系同款）。零运行时偏好读取；唯一例外：进程启动时单次 best-effort 读会话键
// 做跨重启重挂（重启后内核态归零）。
//
// 双通道（写方 = daemon/CLI root 进程；会话启用期间本 tweak 亦写档位通道）：
//   com.chargelimiter.thermalapply   档位通道，state = 0=off/1=nominal/2=light/3=moderate/4=heavy
//   com.chargelimiter.thermalsession 会话通道，state = enabled(bit0) | 档位值(bit8-15)
// 完整控制模式（会话未启用）档位通道归 daemon 独写，本 tweak 不干预。
//
// 仅限流会话（limit-only daemon-free，spec B2）：插电 → 限流档、拔线/档位 off → off，
// 由电池属性 interest 与会话通道通知驱动（IOKit 插电判定，不碰偏好）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>

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
    // off 也下发：清除已生效档位（还原语义）。
    ((void (*)(id, SEL, NSString *))objc_msgSend)(CLTSCurrentProduct,
                                                  @selector(putDeviceInThermalSimulationMode:),
                                                  CLTSStringForThermalMode(mode));
}

#pragma mark - 会话边沿（内核态 + IOKit，零偏好）

// 插电判定（与 daemon isAdaptorConnect 常规分支一致）：ExternalChargeCapable 优先，
// 缺失回退 ExternalConnected。
static BOOL CLTSPowerConnected(void) {
    io_service_t serv = IOServiceGetMatchingService(0, // kIOMasterPortDefault：iOS SDK 标记不可用，值即 0
                                                    IOServiceMatching("AppleSmartBattery"));
    if (serv == IO_OBJECT_NULL) return NO;
    BOOL connected = NO;
    CFTypeRef val = IORegistryEntryCreateCFProperty(serv, CFSTR("ExternalChargeCapable"), kCFAllocatorDefault, 0);
    if (val == NULL) {
        val = IORegistryEntryCreateCFProperty(serv, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
    }
    if (val != NULL) {
        if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
            connected = CFBooleanGetValue((CFBooleanRef)val);
        }
        CFRelease(val);
    }
    IOObjectRelease(serv);
    return connected;
}

// 会话通道解码：enabled(bit0) + 档位值(bit8-15)。
static BOOL CLTSSessionConfig(uint64_t *limitMode) {
    uint64_t state = 0;
    notify_get_state(CLTSSessionToken, &state);
    *limitMode = (state >> 8) & 0xFF;
    return (state & 1ULL) != 0;
}

// 会话重算：插电且档位非 0 → 档位；否则 off（正确性底线：不允许限流档未插电残留）。
// 会话未启用直接返回——完整控制模式档位通道归 daemon 独写。
static void CLTSSessionEvaluate(void) {
    uint64_t limit = 0;
    if (!CLTSSessionConfig(&limit)) return;
    uint64_t target = (CLTSPowerConnected() && limit != 0) ? limit : 0;
    notify_set_state(CLTSApplyToken, target);
    CLTSApplyThermals();
}

// 电池属性变化（插拔边沿）回调：会话重算。消息类型不区分——任何属性变化都重算。
static void CLTSBatteryInterestCallback(void *refcon, io_service_t service, natural_t messageType, void *messageArgument) {
    CLTSSessionEvaluate();
}

#pragma mark - 跨重启重挂（单次 best-effort 偏好读取）

// 重启后内核态归零。从持久化会话键尽力恢复会话通道并重算（本进程首次偏好访问，
// 与运行期缓存不可见问题不同路径）；读不到/未启用则维持 off。此后运行期零偏好读取。
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
    NSString *mode = nil;
    CFTypeRef modeRef = CFPreferencesCopyAppValue(CFSTR("clLimitMode"), CFSTR("com.apple.cltm"));
    if (modeRef != NULL) {
        if (CFGetTypeID(modeRef) == CFStringGetTypeID()) {
            mode = [(__bridge NSString *)modeRef copy];
        }
        CFRelease(modeRef);
    }
    uint64_t value = CLTSModeValueForString(mode);
    notify_set_state(CLTSSessionToken, 1ULL | (value << 8));
    CLTSSessionEvaluate();
}

#pragma mark - Hook 替换实现（仅 initProduct:，Mikasa 同款）

static IMP CLTSOrigInitProduct = NULL;

static id CLTSInitProductOverride(id self, SEL _cmd, id data) {
    id result = CLTSOrigInitProduct ? ((id (*)(id, SEL, id))CLTSOrigInitProduct)(self, _cmd, data) : nil;
    if (result == nil) return nil; // 原实现失败：不捕获不应用
    if ([result respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
        CLTSCurrentProduct = result; // 强引用捕获（Mikasa 同款）
    }
    CLTSApplyThermals(); // thermalmonitord 重启重放：内核态即真相
    return result;
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
        if (productClass != nil) { // 类缺失（系统变更）：静默退回
            CLTSHookSelector(productClass, @selector(initProduct:), (IMP)CLTSInitProductOverride, &CLTSOrigInitProduct);
        }
        // 双通道（Mikasa 同款 notify_register_dispatch，主队列）：
        // 档位通知 → 即时下发；会话通知 → 会话边沿重算。
        notify_register_dispatch([CLTSApplyNotification UTF8String], &CLTSApplyToken,
                                 dispatch_get_main_queue(), ^(int token) {
            CLTSApplyThermals();
        });
        notify_register_dispatch([CLTSSessionNotification UTF8String], &CLTSSessionToken,
                                 dispatch_get_main_queue(), ^(int token) {
            CLTSSessionEvaluate();
        });
        // 跨重启重挂：会话偏好仍启用则恢复会话通道并重算（产品实例就绪前只落内核态，
        // 由 initProduct 重放补一次下发）。
        CLTSRestoreSessionFromPrefs();
        // 电池属性 interest（插拔边沿）：注册失败静默降级——会话通道通知兜底。
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
    }
}
