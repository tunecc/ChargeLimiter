// CLThermalSim —— ChargeLimiter 温控模拟执行端（design: thermal-sim-companion-tweak D1–D4）。
// 仅注入 thermalmonitord（见 CLThermalSim.plist）：把 daemon 写入 com.apple.cltm 的
// 温控/PPM 模拟档位推进到 CommonProduct 的系统模拟 API，并在通知与进程重启时重放。
// 全部 hook 点做能力探测：类/selector 缺失时静默跳过，退回偏好通路现状。
//
// 仅限流会话（limit-only daemon-free，spec B2）：daemon 不驻留的形态下，会话键
// clLimitSessionEnabled/clLimitMode 由一次性 CLI 写入；本 tweak 据此维护插电时限流档、
// 拔线回 off 的会话语义（幂等收敛），并经电池属性 interest 通知与既有 hook 点复查。
// 会话关闭时不碰 thermal 镜像键——写方归 CLI/常驻 daemon。PPM 模拟不属于会话。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOKit/IOKitLib.h>

static NSString * const CLTSPrefsSuite = @"com.apple.cltm";
static NSString * const CLTSKeyThermalMode = @"thermalSimulationMode";
static NSString * const CLTSKeyPPMMode = @"ppmSimulationMode";
static NSString * const CLTSKeyLocked = @"thermalSimulationLocked";
static NSString * const CLTSApplyNotification = @"com.chargelimiter.thermalapply";
static NSString * const CLTSKeySessionEnabled = @"clLimitSessionEnabled";
static NSString * const CLTSKeyLimitMode = @"clLimitMode";

// 当前可操作的 CommonProduct 实例；随 initProduct: 更新（weak，不延长生命周期）。
static __weak id CLTSCurrentProduct = nil;

#pragma mark - 配置读取

static NSString *CLTSReadMode(NSString *key) {
    CFTypeRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)CLTSPrefsSuite);
    NSString *mode = nil;
    if (val) {
        if (CFGetTypeID(val) == CFStringGetTypeID()) {
            mode = [(__bridge NSString *)val copy];
        }
        CFRelease(val);
    }
    if (![mode isEqualToString:@"nominal"] && ![mode isEqualToString:@"light"] &&
        ![mode isEqualToString:@"moderate"] && ![mode isEqualToString:@"heavy"]) {
        return @"off"; // 缺省/无效值按 off，不沿用旧档位
    }
    return mode;
}

static BOOL CLTSIsLocked(void) {
    CFTypeRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)CLTSKeyLocked, (__bridge CFStringRef)CLTSPrefsSuite);
    BOOL locked = NO;
    if (val) {
        if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
            locked = CFBooleanGetValue((CFBooleanRef)val);
        } else if (CFGetTypeID(val) == CFNumberGetTypeID()) {
            locked = [(__bridge NSNumber *)val boolValue];
        }
        CFRelease(val);
    }
    return locked;
}

// 锁定开启且档位非 off 时屏蔽系统覆盖；off 档永不屏蔽。
static BOOL CLTSShouldSuppressOverride(void) {
    if (!CLTSIsLocked()) return NO;
    return ![CLTSReadMode(CLTSKeyThermalMode) isEqualToString:@"off"];
}

#pragma mark - 仅限流会话（spec B2）

static void CLTSApplyOnProduct(id product); // 前置声明：会话收敛时即时下发

static BOOL CLTSReadSessionEnabled(void) {
    CFTypeRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)CLTSKeySessionEnabled, (__bridge CFStringRef)CLTSPrefsSuite);
    BOOL enabled = NO;
    if (val) {
        if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)val);
        } else if (CFGetTypeID(val) == CFNumberGetTypeID()) {
            enabled = [(__bridge NSNumber *)val boolValue];
        }
        CFRelease(val);
    }
    return enabled;
}

static NSString *CLTSReadSessionLimitMode(void) {
    CFTypeRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)CLTSKeyLimitMode, (__bridge CFStringRef)CLTSPrefsSuite);
    NSString *mode = nil;
    if (val) {
        if (CFGetTypeID(val) == CFStringGetTypeID()) {
            mode = [(__bridge NSString *)val copy];
        }
        CFRelease(val);
    }
    if (![mode isEqualToString:@"nominal"] && ![mode isEqualToString:@"light"] &&
        ![mode isEqualToString:@"moderate"] && ![mode isEqualToString:@"heavy"]) {
        return @"off"; // 缺省/无效档不产生限流（安全侧）
    }
    return mode;
}

// 插电判定（与 daemon isAdaptorConnect 常规分支一致）：ExternalChargeCapable 优先，
// 缺失回退 ExternalConnected。仅限流模式无禁流覆盖写，派生键抖动前提不存在。
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

// 会话收敛（幂等）：目标 = 插电且档位非 off → 限流档；否则 off。镜像键与锁定镜像
// 未变化时不重写（读回比对），变化时写偏好并即时下发。会话关闭时直接返回——
// thermal 镜像写方归 CLI / 常驻 daemon，tweak 不得越权。
static void CLTSSessionEvaluate(void) {
    if (!CLTSReadSessionEnabled()) return;
    NSString *limit = CLTSReadSessionLimitMode();
    NSString *target = (!CLTSPowerConnected() || [limit isEqualToString:@"off"]) ? @"off" : limit;
    BOOL locked = ![target isEqualToString:@"off"];
    if ([CLTSReadMode(CLTSKeyThermalMode) isEqualToString:target] && CLTSIsLocked() == locked) {
        return;
    }
    CFPreferencesSetValue((__bridge CFStringRef)CLTSKeyThermalMode,
                          (__bridge CFTypeRef)target,
                          (__bridge CFStringRef)CLTSPrefsSuite,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue((__bridge CFStringRef)CLTSKeyLocked,
                          (__bridge CFTypeRef)@(locked),
                          (__bridge CFStringRef)CLTSPrefsSuite,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)CLTSPrefsSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CLTSApplyOnProduct(CLTSCurrentProduct);
}

// 电池属性变化（插拔边沿）回调：会话重算。消息类型不区分——任何属性变化都重收敛，
// 幂等早退保证代价可忽略。
static void CLTSBatteryInterestCallback(void *refcon, io_service_t service, natural_t messageType, void *messageArgument) {
    CLTSSessionEvaluate();
}

#pragma mark - 档位应用

static void CLTSApplyOnProduct(id product) {
    if (product == nil) return;
    @try {
        // thermal：off 也主动下发以清除已生效档位（还原语义）。
        if ([product respondsToSelector:@selector(putDeviceInThermalSimulationMode:)]) {
            NSString *thermal = CLTSReadMode(CLTSKeyThermalMode);
            ((void (*)(id, SEL, NSString *))objc_msgSend)(product, @selector(putDeviceInThermalSimulationMode:), thermal);
        }
        // PPM：off 不调用低温模拟 API（spec 行为）。
        NSString *ppm = CLTSReadMode(CLTSKeyPPMMode);
        if (![ppm isEqualToString:@"off"] &&
            [product respondsToSelector:@selector(putDeviceInLowTempSimulationMode:)]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(product, @selector(putDeviceInLowTempSimulationMode:), ppm);
        }
    } @catch (NSException *exc) {
        NSLog(@"[CLThermalSim] apply exception: %@", exc);
    }
}

#pragma mark - Hook 替换实现

static IMP CLTSOrigInitProduct = NULL;
static IMP CLTSOrigTryTakeAction = NULL;
static IMP CLTSOrigSimulateLight = NULL;
static IMP CLTSOrigTelemetry = NULL;

static id CLTSInitProductOverride(id self, SEL _cmd, id data) {
    id result = CLTSOrigInitProduct ? ((id (*)(id, SEL, id))CLTSOrigInitProduct)(self, _cmd, data) : nil;
    if (result == nil) return nil; // 原实现失败：不捕获不应用
    CLTSCurrentProduct = self;
    // thermalmonitord 重启重放（spec B2 触发之一）：先按会话重算镜像（自愈对齐
    // 当前插电状态），再应用既有镜像语义。
    CLTSSessionEvaluate();
    CLTSApplyOnProduct(self);
    return result;
}

static void CLTSTryTakeActionOverride(id self, SEL _cmd) {
    CLTSSessionEvaluate(); // 机会性复查（spec B2）：策略评估频率即复查频率，幂等早退
    if (CLTSShouldSuppressOverride()) return; // 每次调用实时判定（D4）
    if (CLTSOrigTryTakeAction) ((void (*)(id, SEL))CLTSOrigTryTakeAction)(self, _cmd);
}

static void CLTSSimulateLightOverride(id self, SEL _cmd) {
    if (CLTSShouldSuppressOverride()) return;
    if (CLTSOrigSimulateLight) ((void (*)(id, SEL))CLTSOrigSimulateLight)(self, _cmd);
}

static void CLTSUpdateTelemetryOverride(id self, SEL _cmd) {
    CLTSSessionEvaluate(); // 机会性复查：电源域遥测更新常伴随供电状态变化
    if (CLTSShouldSuppressOverride()) return;
    if (CLTSOrigTelemetry) ((void (*)(id, SEL))CLTSOrigTelemetry)(self, _cmd);
}

static void CLTSHookSelector(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m == nil) return; // selector 缺失：跳过，不产生副作用
    IMP prev = method_setImplementation(m, newImp);
    if (prev && *origOut == NULL) *origOut = prev;
}

static void CLTSHookCommonProduct(Class cls) {
    if (cls == nil) return; // 类缺失（系统变更）：静默退回
    CLTSHookSelector(cls, @selector(initProduct:), (IMP)CLTSInitProductOverride, &CLTSOrigInitProduct);
    CLTSHookSelector(cls, @selector(tryTakeAction), (IMP)CLTSTryTakeActionOverride, &CLTSOrigTryTakeAction);
    CLTSHookSelector(cls, @selector(simulateLightThermalPressure), (IMP)CLTSSimulateLightOverride, &CLTSOrigSimulateLight);
    CLTSHookSelector(cls, @selector(updatePowerzoneTelemetry), (IMP)CLTSUpdateTelemetryOverride, &CLTSOrigTelemetry);
}

#pragma mark - 通知与入口

static void CLTSApplyNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CLTSSessionEvaluate(); // 配置可能刚变：先重算会话镜像，再按镜像下发
    CLTSApplyOnProduct(CLTSCurrentProduct);
}

static IONotificationPortRef CLTSNotifyPort = NULL;
static io_object_t CLTSBatteryNotifier = IO_OBJECT_NULL;

__attribute__((constructor)) static void CLTSInit(void) {
    @autoreleasepool {
        CLTSHookCommonProduct(objc_getClass("CommonProduct"));
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        CLTSApplyNotificationCallback,
                                        (__bridge CFStringRef)CLTSApplyNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        // 仅限流会话主触发（spec B2）：AppleSmartBattery 属性变化（插拔边沿）驱动
        // 会话重算。注册失败静默降级——既有 hook 点机会性复查兜底。
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
