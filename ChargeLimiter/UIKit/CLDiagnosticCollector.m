//
//  CLDiagnosticCollector.m
//  ChargeLimiter
//
//  诊断模型 + markdownText + 路径/架构辅助函数 + 网络采集。
//

#import "CLDiagnosticCollector.h"
#import "CLAPIClient.h"
#import "CLBatteryManager.h"
#import <dlfcn.h>

// 不引入 common.h/utils.h（会拉 UIKit）；仅 dlsym 解析 unmangled _C 符号。
static int CLDiagCallGetJBType(void) {
    typedef int (*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "getJBType_C");
    });
    return fn ? fn() : -1;
}

static NSString *CLDiagCallGetSelfExePath(void) {
    typedef NSString *(*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "getSelfExePath_C");
    });
    return fn ? fn() : nil;
}

static NSString *CLDiagCallGetRuntimeDataRootPath(void) {
    typedef NSString *(*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "getRuntimeDataRootPath_C");
    });
    return fn ? fn() : nil;
}

static NSTimeInterval CLDiagCallGetSysBoottime(void) {
    typedef int (*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "get_sys_boottime_C");
    });
    return fn ? (NSTimeInterval)fn() : 0;
}

NSString *CLPackageSchemeString(void) {
#if defined(CL_PACKAGE_ROOTHIDE) && CL_PACKAGE_ROOTHIDE
    return @"roothide";
#elif defined(CL_PACKAGE_ROOTLESS) && CL_PACKAGE_ROOTLESS
    return @"rootless";
#else
    return @"rootful";
#endif
}

NSString *CLSanitizePathForDiag(NSString *path) {
    if (path.length == 0) {
        return @"(无法获取)";
    }

    // 截到 .jbroot-XXX 这一段为止，后面路径省略
    NSRange r = [path rangeOfString:@".jbroot-"];
    if (r.location != NSNotFound) {
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        NSMutableArray *kept = [NSMutableArray array];
        for (NSString *p in parts) {
            [kept addObject:p];
            if ([p hasPrefix:@".jbroot-"]) {
                break;
            }
        }
        return [[kept componentsJoinedByString:@"/"] stringByAppendingString:@"/…"];
    }

    // 非 jbroot 路径：保留最后 3 段
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count > 4) {
        NSArray *tail = [parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)];
        return [@"…/" stringByAppendingString:[tail componentsJoinedByString:@"/"]];
    }
    return path;
}

NSString *CLJBTypeLabelFromCode(int code) {
    switch (code) {
        case 2:  return @"roothide";     // JBTYPE_ROOTHIDE
        case 0:  return @"rootless";     // JBTYPE_ROOTLESS
        case 1:  return @"rootful";      // JBTYPE_ROOT
        case 8:  return @"trollstore";   // JBTYPE_TROLLSTORE
        default: return @"unknown";
    }
}

@implementation CLDiagEnvironment
@end

@implementation CLDiagConnectivity
@end

@implementation CLDiagBatteryProbe
@end

@implementation CLDiagnosticReport

- (NSString *)markdownText {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    CLDiagConnectivity *c = self.connectivity;
    if (c && !c.daemonAlive) {
        [lines addObject:@"⚠️ daemon 离线"];
        [lines addObject:@""];
    }

    // # 环境
    [lines addObject:@"# 环境"];
    CLDiagEnvironment *e = self.environment;
    [lines addObject:[NSString stringWithFormat:@"设备型号:        %@", e.deviceModel.length ? e.deviceModel : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"iOS 版本:        %@", e.systemVersion.length ? e.systemVersion : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"App 版本:        %@", e.appVersion.length ? e.appVersion : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"包架构:          %@", e.packageScheme.length ? e.packageScheme : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"越狱类型:        %@", e.jbType.length ? e.jbType : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"可执行路径:      %@", e.exePath.length ? e.exePath : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"数据根路径:      %@", e.dataRootPath.length ? e.dataRootPath : @"(无法获取)"]];
    if (e.systemBootTime > 0) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:e.systemBootTime];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        [lines addObject:[NSString stringWithFormat:@"系统启动:        %@", [fmt stringFromDate:d]]];
    } else {
        [lines addObject:@"系统启动:        (无法获取)"];
    }
    [lines addObject:@""];

    // # 连通性
    [lines addObject:@"# 连通性"];
    [lines addObject:[NSString stringWithFormat:@"daemon 在线:     %@", c.daemonAlive ? @"YES" : @"NO"]];
    [lines addObject:[NSString stringWithFormat:@"HTTP 可达:       %@", c.httpReachable ? @"YES" : @"NO"]];
    [lines addObject:[NSString stringWithFormat:@"daemon 启动时长: %@", c.daemonUptimeText.length ? c.daemonUptimeText : @"N/A"]];
    [lines addObject:[NSString stringWithFormat:@"最近 API 错误码: %@", c.lastApiError.length ? c.lastApiError : @"(无法获取)"]];
    [lines addObject:@""];

    // # 读电量链路
    [lines addObject:@"# 读电量链路"];
    CLDiagBatteryProbe *b = self.batteryProbe;
    if (!c.httpReachable) {
        [lines addObject:@"daemon 离线,无法探测"];
    } else {
        [lines addObject:[NSString stringWithFormat:@"命中 service:    %@", b.serviceName.length ? b.serviceName : @"(无法获取)"]];
        NSString *keys = b.publishedKeys.count ? [b.publishedKeys componentsJoinedByString:@","] : @"(无)";
        [lines addObject:[NSString stringWithFormat:@"发布 key 清单:   %@", keys]];
        [lines addObject:@"关键 key 是否齐全:"];
        for (NSString *k in @[@"CurrentCapacity", @"Amperage", @"Voltage", @"IsCharging", @"Temperature"]) {
            BOOL present = [b.keyPresent[k] boolValue];
            [lines addObject:[NSString stringWithFormat:@"  %@: %@", k, present ? @"YES" : @"❌缺失"]];
        }
        [lines addObject:[NSString stringWithFormat:@"IOKit 返回值:     %ld", (long)b.iokitReturn]];
        [lines addObject:[NSString stringWithFormat:@"use_smart:        %d", b.useSmart ? 1 : 0]];
        [lines addObject:@"越狱库加载:"];
        [lines addObject:[NSString stringWithFormat:@"  libjailbreak.dylib:  %@", b.libjailbreakLoaded ? @"OK" : @"❌dlopen失败"]];
        [lines addObject:[NSString stringWithFormat:@"  libroothide.dylib:   %@", b.libroothideStatus.length ? b.libroothideStatus : @"N/A"]];
    }
    [lines addObject:@""];

    // # 策略信号
    [lines addObject:@"# 策略信号"];
    if (self.policySummaryText.length > 0) {
        [lines addObject:self.policySummaryText];
    } else {
        [lines addObject:@"(无法获取)"];
    }

    if (self.probeSummaryText.length > 0) {
        [lines addObject:@""];
        [lines addObject:@"## 停充控制探针结论"];
        [lines addObject:self.probeSummaryText];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end

@implementation CLDiagnosticCollector

+ (void)collectWithPolicySummary:(NSString *)policySummary
                   probeSummary:(NSString *)probeSummary
                     completion:(void (^)(CLDiagnosticReport *))completion {
    CLDiagnosticReport *report = [CLDiagnosticReport new];
    report.policySummaryText = policySummary;
    report.probeSummaryText = probeSummary;

    // 1) 本地环境（不依赖 daemon）；device/sys/app 先用 manager 缓存兜底
    CLBatteryManager *mgr = [CLBatteryManager shared];
    CLDiagEnvironment *env = [CLDiagEnvironment new];
    env.packageScheme = CLPackageSchemeString();
    int jb = CLDiagCallGetJBType();
    env.jbType = CLJBTypeLabelFromCode(jb);
    env.exePath = CLSanitizePathForDiag(CLDiagCallGetSelfExePath());
    env.dataRootPath = CLSanitizePathForDiag(CLDiagCallGetRuntimeDataRootPath());
    NSTimeInterval boot = CLDiagCallGetSysBoottime();
    if (boot <= 0 && mgr.systemBootTime > 0) {
        boot = mgr.systemBootTime;
    }
    env.systemBootTime = boot;
    env.deviceModel = mgr.deviceModel.length ? mgr.deviceModel : @"";
    env.systemVersion = mgr.systemVersion.length ? mgr.systemVersion : @"";
    env.appVersion = mgr.appVersion.length ? mgr.appVersion : @"";
    report.environment = env;

    CLDiagConnectivity *conn = [CLDiagConnectivity new];
    conn.daemonAlive = NO;
    conn.httpReachable = NO;
    conn.daemonUptimeText = @"N/A";
    conn.lastApiError = @"(未请求)";
    report.connectivity = conn;

    CLDiagBatteryProbe *probe = [CLDiagBatteryProbe new];
    probe.serviceName = @"";
    probe.publishedKeys = @[];
    probe.keyPresent = @{};
    probe.libroothideStatus = @"N/A";
    report.batteryProbe = probe;

    // 2) 拉 get_diag（失败不重启 daemon；离线仍产出报告）
    [[CLAPIClient shared] getDiagWithCompletion:^(NSDictionary *response, NSError *error) {
        if (error || response == nil || [response[@"status"] intValue] != 0) {
            conn.httpReachable = NO;
            conn.daemonAlive = NO;
            if (error) {
                conn.lastApiError = error.localizedDescription ?: @"error";
            } else if (response[@"msg"]) {
                conn.lastApiError = [NSString stringWithFormat:@"%@", response[@"msg"]];
            } else {
                conn.lastApiError = @"status!=0";
            }
            // manager 兜底已在本地填好 device/sys/app/boot
        } else {
            conn.httpReachable = YES;
            conn.daemonAlive = YES;
            conn.lastApiError = @"0";
            NSDictionary *data = response[@"data"];
            if ([data isKindOfClass:[NSDictionary class]]) {
                NSString *dev = [NSString stringWithFormat:@"%@", data[@"devmodel"] ?: @""];
                NSString *sys = [NSString stringWithFormat:@"%@", data[@"sysver"] ?: @""];
                NSString *ver = [NSString stringWithFormat:@"%@", data[@"ver"] ?: @""];
                if (dev.length > 0) env.deviceModel = dev;
                if (sys.length > 0) env.systemVersion = sys;
                if (ver.length > 0) env.appVersion = ver;
                // 本地 unknown/空时用 daemon jbtype 回填；已知值保留本地
                if (env.jbType.length == 0 || [env.jbType isEqualToString:@"unknown"]) {
                    if ([data[@"jbtype"] isKindOfClass:[NSString class]] && [data[@"jbtype"] length] > 0) {
                        env.jbType = data[@"jbtype"];
                    }
                }
                NSNumber *servBoot = data[@"serv_boot"];
                if ([servBoot respondsToSelector:@selector(doubleValue)] && servBoot.doubleValue > 0) {
                    NSTimeInterval up = [[NSDate date] timeIntervalSince1970] - servBoot.doubleValue;
                    if (up < 0) up = 0;
                    NSInteger h = (NSInteger)(up / 3600);
                    NSInteger m = (NSInteger)((up - h * 3600) / 60);
                    conn.daemonUptimeText = [NSString stringWithFormat:@"%ldh %ldm", (long)h, (long)m];
                }
                probe.serviceName = [NSString stringWithFormat:@"%@", data[@"service_name"] ?: @"(无法获取)"];
                NSArray *keys = data[@"published_keys"];
                probe.publishedKeys = [keys isKindOfClass:[NSArray class]] ? keys : @[];
                NSDictionary *kp = data[@"key_present"];
                probe.keyPresent = [kp isKindOfClass:[NSDictionary class]] ? kp : @{};
                probe.iokitReturn = [data[@"iokit_return"] integerValue];
                probe.useSmart = [data[@"use_smart"] boolValue];
                probe.libjailbreakLoaded = [data[@"libjailbreak_loaded"] boolValue];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
        }
    }];
}

@end
