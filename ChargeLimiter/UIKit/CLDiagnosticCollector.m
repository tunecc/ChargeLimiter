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
#import <mach-o/dyld.h>

// 不引入 common.h/utils.h（会拉 UIKit）。
// 优先 dlsym unmangled _C 符号；失败则用本进程 dyld / bundle 路径兜底。

NSString *CLDiagErrnoLabel(NSInteger rc) {
    if (rc == -999)   return @"-999(未尝试)";
    if (rc == 0)      return @"0";
    if (rc == 1)      return @"1(EPERM 权限)";
    if (rc == 2)      return @"2(ENOENT 无此文件)";
    if (rc == 13)     return @"13(EACCES 权限拒绝)";
    return [NSString stringWithFormat:@"%ld", (long)rc];
}

static NSDictionary *CLDiagCallDaemonLaunchProbe(void) {
    typedef NSDictionary *(*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "clDaemonLaunchProbe_C");
    });
    return fn ? fn() : nil;
}

static int CLDiagGetJBTypeCode(BOOL *outFound) {
    typedef int (*fn_t)(void);
    static BOOL resolved = NO;
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "getJBType_C");
        resolved = (fn != NULL);
    });
    if (outFound) {
        *outFound = resolved;
    }
    return fn ? fn() : -1;
}

static NSString *CLDiagJbProbeDetail(BOOL symbolFound) {
    BOOL jbrootSym = (dlsym(RTLD_DEFAULT, "jbroot") != NULL);
    BOOL librootSym = (dlsym(RTLD_DEFAULT, "libroot_dyn_jbrootpath") != NULL);
    return [NSString stringWithFormat:@"symbol=%@ jbroot=%@ libroot=%@",
            symbolFound ? @"YES" : @"NO",
            jbrootSym ? @"YES" : @"NO",
            librootSym ? @"YES" : @"NO"];
}

static NSString *CLDiagLocalExecutablePath(void) {
    // 1) dyld 可执行路径（App 主 binary）
    char buf[PATH_MAX] = {0};
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0 && buf[0] != '\0') {
        return @(buf);
    }
    // 2) dladdr 本文件所在 image
    Dl_info di;
    if (dladdr((const void *)CLDiagLocalExecutablePath, &di) && di.dli_fname) {
        return @(di.dli_fname);
    }
    // 3) main bundle
    NSString *exec = [NSBundle mainBundle].executablePath;
    if (exec.length > 0) {
        return exec;
    }
    return [NSBundle mainBundle].bundlePath;
}

static NSString *CLDiagCallGetSelfExePath(void) {
    typedef NSString *(*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "getSelfExePath_C");
    });
    NSString *viaC = fn ? fn() : nil;
    if (viaC.length > 0) {
        return viaC;
    }
    return CLDiagLocalExecutablePath();
}

static NSString *CLDiagCallGetRuntimeDataRootPath(void) {
    typedef NSString *(*fn_t)(void);
    static fn_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (fn_t)dlsym(RTLD_DEFAULT, "getRuntimeDataRootPath_C");
    });
    NSString *viaC = fn ? fn() : nil;
    if (viaC.length > 0) {
        return viaC;
    }
    // 兜底：App 容器 Documents（TrollStore/沙盒）或可执行目录旁逻辑根
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count > 0 && [docs.firstObject length] > 0) {
        return docs.firstObject;
    }
    NSString *exe = CLDiagLocalExecutablePath();
    return exe.stringByDeletingLastPathComponent ?: nil;
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

/// roothide 上 /usr/lib/libjailbreak.dylib 常不在真实 rootfs → 失败是预期，不应标成故障。
static NSString *CLFormatLibjailbreakStatus(BOOL loaded, NSString *packageScheme, NSString *jbType) {
    if (loaded) {
        return @"OK";
    }
    BOOL roothideLike = [packageScheme isEqualToString:@"roothide"]
        || [jbType isEqualToString:@"roothide"];
    if (roothideLike) {
        return @"N/A(roothide 预期:真实 /usr/lib 无此库)";
    }
    return @"❌dlopen失败";
}

static NSString *CLFormatLibroothideStatus(NSString *packageScheme, NSString *daemonStatus) {
    if ([daemonStatus isKindOfClass:[NSString class]] && daemonStatus.length > 0
        && ![daemonStatus isEqualToString:@"N/A"]) {
        return daemonStatus;
    }
    if ([packageScheme isEqualToString:@"roothide"]) {
        // App 通过 @loader_path/.jbroot 解析；此处不做强依赖探测，避免误报
        return @"N/A(由 roothide 运行时解析,未强制探测)";
    }
    return @"N/A";
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

@implementation CLDiagDaemonLink
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
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone localTimeZone];
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

    // # daemon 启动链路（仅离线时渲染；在线时 daemon 本身可回答，无需诊断链路）
    CLDiagDaemonLink *dk = self.daemonLink;
    if (!c.httpReachable && dk) {
        [lines addObject:@"# daemon 启动链路（离线诊断）"];
        [lines addObject:[NSString stringWithFormat:@"daemon 路径:     %@", dk.daemonPath.length ? dk.daemonPath : @"(无法获取)"]];
        [lines addObject:[NSString stringWithFormat:@"二进制存在:      %@", dk.daemonExists ? @"YES" : @"NO"]];
        [lines addObject:@"日志尾部(aldente.log):"];
        [lines addObjectsFromArray:[self daemonLogTailLines:dk.logTail]];
        [lines addObject:@""];
    }

    // # 读电量链路
    [lines addObject:@"# 读电量链路"];
    CLDiagBatteryProbe *b = self.batteryProbe;
    if (!c.httpReachable) {
        [lines addObject:@"daemon 离线,无法探测 IOKit service"];
        if (b.hasLiveBatterySample) {
            [lines addObject:[NSString stringWithFormat:@"App 侧最近电量:  %ld%% · %ld mA (manager 缓存,可能过期)",
                              (long)b.currentCapacityPercent, (long)b.amperageMilliAmps]];
        }
    } else {
        [lines addObject:[NSString stringWithFormat:@"命中 service:    %@", b.serviceName.length ? b.serviceName : @"(无法获取)"]];
        if (b.hasLiveBatterySample) {
            [lines addObject:[NSString stringWithFormat:@"当前电量/电流:   %ld%% · %ld mA",
                              (long)b.currentCapacityPercent, (long)b.amperageMilliAmps]];
        } else {
            [lines addObject:@"当前电量/电流:   (无采样)"];
        }
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
        [lines addObject:[NSString stringWithFormat:@"  libjailbreak.dylib:  %@", b.libjailbreakStatus.length ? b.libjailbreakStatus : @"N/A"]];
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
    } else {
        [lines addObject:@""];
        [lines addObject:@"## 停充控制探针结论"];
        [lines addObject:@"(未运行) 查停充是否生效时：请先插电 → 点「运行停充控制探针」→ 再「一键复制完整诊断」或「复制探针→详细」。"];
    }

    // 使用说明（给用户/开发者）
    [lines addObject:@""];
    [lines addObject:@"# 使用说明"];
    [lines addObject:@"1. 查「不显示电量/daemon」：直接复制本报告即可（看连通性 + 读电量链路）。"];
    [lines addObject:@"2. 查「停充/保持不生效」：请先插电，再运行停充控制探针后重新复制。"];
    [lines addObject:@"3. roothide 下 libjailbreak 真实路径失败多为预期，不代表越狱损坏。"];

    return [lines componentsJoinedByString:@"\n"];
}

- (NSArray<NSString *> *)daemonLogTailLines:(NSString *)tail {
    if (tail.length == 0) {
        return @[@"  (空/无日志)"];
    }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [tail componentsSeparatedByString:@"\n"]) {
        if (line.length > 0) {
            [out addObject:[NSString stringWithFormat:@"  %@", line]];
        }
    }
    return out.count ? out : @[@"  (空)"];
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
    BOOL jbFound = NO;
    int jb = CLDiagGetJBTypeCode(&jbFound);
    env.jbType = CLJBTypeLabelFromCode(jb);
    env.jbRawCode = jb;
    env.jbProbeDetail = CLDiagJbProbeDetail(jbFound);
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
    probe.libjailbreakStatus = @"N/A";
    probe.libroothideStatus = CLFormatLibroothideStatus(env.packageScheme, nil);
    // App 侧最近电量采样（主页/自动刷新写入 manager）
    if (mgr.updateTime > 0 || mgr.currentCapacity > 0 || mgr.amperage != 0 || mgr.instantAmperage != 0) {
        probe.hasLiveBatterySample = YES;
        probe.currentCapacityPercent = mgr.currentCapacity;
        // 优先瞬时电流，其次平均电流
        probe.amperageMilliAmps = (mgr.instantAmperage != 0) ? mgr.instantAmperage : mgr.amperage;
    } else {
        probe.hasLiveBatterySample = NO;
        probe.currentCapacityPercent = 0;
        probe.amperageMilliAmps = 0;
    }
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
            NSDictionary *probeRaw = CLDiagCallDaemonLaunchProbe();
            CLDiagDaemonLink *link = [CLDiagDaemonLink new];
            link.daemonPath = CLSanitizePathForDiag(probeRaw[@"daemon_path"]);
            link.daemonExists = [probeRaw[@"daemon_exists"] boolValue];
            link.initialPortOpen = [probeRaw[@"initial_port_open"] boolValue];
            link.logTail = [probeRaw[@"log_tail"] isKindOfClass:[NSString class]] ? probeRaw[@"log_tail"] : @"";
            report.daemonLink = link;
            // 离线时仍用本地 scheme 格式化 jailbreak 状态，避免误导
            probe.libjailbreakStatus = CLFormatLibjailbreakStatus(NO, env.packageScheme, env.jbType);
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

                // daemon 侧路径优先（同一机器上的真实 daemon 视角）
                if ([data[@"exe_path"] isKindOfClass:[NSString class]] && [data[@"exe_path"] length] > 0) {
                    // 保留 App 本地路径；另可在未来扩展。此处若 App 仍是占位则用 daemon。
                    if ([env.exePath isEqualToString:@"(无法获取)"] || env.exePath.length == 0) {
                        env.exePath = CLSanitizePathForDiag(data[@"exe_path"]);
                    }
                }
                if ([data[@"data_root"] isKindOfClass:[NSString class]] && [data[@"data_root"] length] > 0) {
                    if ([env.dataRootPath isEqualToString:@"(无法获取)"] || env.dataRootPath.length == 0) {
                        env.dataRootPath = CLSanitizePathForDiag(data[@"data_root"]);
                    }
                }

                // 本地 unknown/空时用 daemon jbtype 回填
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

                if ([data[@"libjailbreak_status"] isKindOfClass:[NSString class]] && [data[@"libjailbreak_status"] length] > 0) {
                    probe.libjailbreakStatus = data[@"libjailbreak_status"];
                } else {
                    BOOL jbLoaded = [data[@"libjailbreak_loaded"] boolValue];
                    probe.libjailbreakStatus = CLFormatLibjailbreakStatus(jbLoaded, env.packageScheme, env.jbType);
                }
                if ([data[@"libroothide_status"] isKindOfClass:[NSString class]]) {
                    probe.libroothideStatus = CLFormatLibroothideStatus(env.packageScheme, data[@"libroothide_status"]);
                } else {
                    probe.libroothideStatus = CLFormatLibroothideStatus(env.packageScheme, nil);
                }

                // daemon 若带回即时电量，覆盖 App 缓存
                if (data[@"current_capacity"] != nil || data[@"amperage"] != nil) {
                    probe.hasLiveBatterySample = YES;
                    if (data[@"current_capacity"] != nil) {
                        probe.currentCapacityPercent = [data[@"current_capacity"] integerValue];
                    }
                    if (data[@"amperage"] != nil) {
                        probe.amperageMilliAmps = [data[@"amperage"] integerValue];
                    } else if (data[@"instant_amperage"] != nil) {
                        probe.amperageMilliAmps = [data[@"instant_amperage"] integerValue];
                    }
                }
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
        }
    }];
}

@end
