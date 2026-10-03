// CLThermalSim —— ChargeLimiter 温控模拟执行端（design: thermal-sim-companion-tweak D1–D4）。
// 仅注入 thermalmonitord（见 CLThermalSim.plist）：把 daemon 写入 com.apple.cltm 的
// 温控/PPM 模拟档位推进到 CommonProduct 的系统模拟 API，并在通知与进程重启时重放。
// 全部 hook 点做能力探测：类/selector 缺失时静默跳过，退回偏好通路现状。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const CLTSPrefsSuite = @"com.apple.cltm";
static NSString * const CLTSKeyThermalMode = @"thermalSimulationMode";
static NSString * const CLTSKeyPPMMode = @"ppmSimulationMode";
static NSString * const CLTSKeyLocked = @"thermalSimulationLocked";
static NSString * const CLTSApplyNotification = @"com.chargelimiter.thermalapply";

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
    CLTSApplyOnProduct(self);
    return result;
}

static void CLTSTryTakeActionOverride(id self, SEL _cmd) {
    if (CLTSShouldSuppressOverride()) return; // 每次调用实时判定（D4）
    if (CLTSOrigTryTakeAction) ((void (*)(id, SEL))CLTSOrigTryTakeAction)(self, _cmd);
}

static void CLTSSimulateLightOverride(id self, SEL _cmd) {
    if (CLTSShouldSuppressOverride()) return;
    if (CLTSOrigSimulateLight) ((void (*)(id, SEL))CLTSOrigSimulateLight)(self, _cmd);
}

static void CLTSUpdateTelemetryOverride(id self, SEL _cmd) {
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
    CLTSApplyOnProduct(CLTSCurrentProduct);
}

__attribute__((constructor)) static void CLTSInit(void) {
    @autoreleasepool {
        CLTSHookCommonProduct(objc_getClass("CommonProduct"));
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        CLTSApplyNotificationCallback,
                                        (__bridge CFStringRef)CLTSApplyNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    }
}
