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
#import <sys/utsname.h>
#import <string.h>

// 不引入 common.h/utils.h（会拉 UIKit）。
// 本项目 utils.mm 的 _C wrapper 直接 extern 调用（链接期绑定，不依赖导出表，
// 也不依赖 dlsym——stripped Mach-O executable 不导出本地符号，dlsym 会失败）。
// 仅 jbroot / libroot_dyn_jbrootpath 这类外部库符号仍走 dlsym 运行时查找。
extern NSDictionary *clDaemonLaunchProbe_C(void);
extern NSDictionary *getConfigPersistenceDiagnostics_C(void);
extern int getJBType_C(void);
extern NSString *getSelfExePath_C(void);
extern NSString *getRuntimeDataRootPath_C(void);
extern int get_sys_boottime_C(void);

NSString *CLDiagErrnoLabel(NSInteger rc) {
    if (rc == -999)   return @"-999(未尝试)";
    if (rc == 0)      return @"0";
    if (rc == 1)      return @"1(EPERM 权限)";
    if (rc == 2)      return @"2(ENOENT 无此文件)";
    if (rc == 12)     return @"12(ENOMEM 内存不足)";
    if (rc == 13)     return @"13(EACCES 权限拒绝)";
    if (rc == 22)     return @"22(EINVAL 参数无效)";
    if (rc == 23)     return @"23(ENFILE 系统文件表已满)";
    if (rc == 24)     return @"24(EMFILE 进程文件描述符已满)";
    if (rc == 47)     return @"47(EAFNOSUPPORT 地址族不支持)";
    if (rc == 48)     return @"48(EADDRINUSE 地址已占用)";
    if (rc == 49)     return @"49(EADDRNOTAVAIL 地址不可用)";
    if (rc == 55)     return @"55(ENOBUFS 缓冲区不足)";
    return [NSString stringWithFormat:@"%ld", (long)rc];
}

static NSDictionary *CLDiagCallDaemonLaunchProbe(void) {
    return clDaemonLaunchProbe_C();
}

static int CLDiagGetJBTypeCode(void) {
    return getJBType_C();
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
    NSString *viaC = getSelfExePath_C();
    if (viaC.length > 0) {
        return viaC;
    }
    return CLDiagLocalExecutablePath();
}

static NSString *CLDiagCallGetRuntimeDataRootPath(void) {
    NSString *viaC = getRuntimeDataRootPath_C();
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
    return (NSTimeInterval)get_sys_boottime_C();
}

static NSString *CLDiagLocalDeviceModel(void) {
    struct utsname name;
    memset(&name, 0, sizeof(name));
    if (uname(&name) == 0 && name.machine[0] != '\0') {
        return [NSString stringWithUTF8String:name.machine] ?: @"";
    }
    return @"";
}

static NSString *CLDiagLocalSystemVersion(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion <= 0) {
        return @"";
    }
    return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)version.majorVersion,
            (long)version.minorVersion, (long)version.patchVersion];
}

static NSString *CLDiagLocalAppVersion(void) {
    id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [value isKindOfClass:[NSString class]] ? value : @"";
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

static NSString *CLRedactJBRootTokensForDiag(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @"";
    }
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\.jbroot-[^/\\s]+"
                                                                           options:0
                                                                             error:&error];
    if (!regex || error) {
        return text;
    }
    return [regex stringByReplacingMatchesInString:text
                                           options:0
                                             range:NSMakeRange(0, text.length)
                                      withTemplate:@".jbroot-…"];
}

static NSString *CLConfigIdentityForDiag(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return @"";
    NSString *normalized = path.stringByStandardizingPath;
    NSRange marker = [normalized rangeOfString:@"/.jbroot-"];
    if (marker.location != NSNotFound) {
        NSUInteger tokenStart = marker.location + 1;
        NSRange slash = [normalized rangeOfString:@"/"
                                          options:0
                                            range:NSMakeRange(tokenStart, normalized.length - tokenStart)];
        if (slash.location != NSNotFound) {
            normalized = [@"$JBROOT" stringByAppendingString:[normalized substringFromIndex:slash.location]];
        }
    }
    if ([normalized hasPrefix:@"/private/var/"]) {
        normalized = [normalized substringFromIndex:[@"/private" length]];
    }
    return normalized;
}

static NSString *CLDiagValueBetween(NSString *text, NSString *startToken, NSString *endToken) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0
        || startToken.length == 0) {
        return @"";
    }
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *line in [lines reverseObjectEnumerator]) {
        NSRange start = [line rangeOfString:startToken];
        if (start.location == NSNotFound) {
            continue;
        }
        NSUInteger valueStart = NSMaxRange(start);
        NSUInteger valueEnd = line.length;
        if (endToken.length > 0) {
            NSRange end = [line rangeOfString:endToken options:0 range:NSMakeRange(valueStart, line.length - valueStart)];
            if (end.location != NSNotFound) {
                valueEnd = end.location;
            }
        }
        if (valueEnd <= valueStart) {
            return @"";
        }
        return [[line substringWithRange:NSMakeRange(valueStart, valueEnd - valueStart)]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return @"";
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

@implementation CLDiagConfigPersistence
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
        [lines addObject:[NSString stringWithFormat:@"daemon 进程:     %@", dk.daemonProcessPID > 0 ? [NSString stringWithFormat:@"PID %ld", (long)dk.daemonProcessPID] : @"未发现"]];
        NSString *mode = dk.daemonMode >= 0 ? [NSString stringWithFormat:@"0%lo", (unsigned long)dk.daemonMode] : @"unknown";
        [lines addObject:[NSString stringWithFormat:@"二进制权限:      executable=%@ mode=%@ uid=%ld gid=%ld",
                          dk.daemonExecutable ? @"YES" : @"NO", mode,
                          (long)dk.daemonOwnerUID, (long)dk.daemonGroupGID]];
        [lines addObject:[NSString stringWithFormat:@"初始端口(1230): %@", dk.initialPortOpen ? @"YES(已被监听)" : @"NO(无人监听)"]];
        NSDictionary *pp = dk.portProbe;
        [lines addObject:[NSString stringWithFormat:@"端口探测:        socket_errno=%@ connect=%@/%@ select=%@/%@ so_error=%@",
                          pp[@"socket_errno"] ?: @(-1), pp[@"connect_rc"] ?: @(-1),
                          pp[@"connect_errno"] ?: @(-1), pp[@"select_rc"] ?: @(-1),
                          pp[@"select_errno"] ?: @(-1), pp[@"so_error"] ?: @(-1)]];
        [lines addObject:[NSString stringWithFormat:@"日志文件路径:    %@", dk.logPath.length ? dk.logPath : @"(无法获取)"]];
        [lines addObject:[NSString stringWithFormat:@"日志文件存在:    %@", dk.logExists ? @"YES" : @"NO"]];
        NSString *logMode = dk.logMode >= 0 ? [NSString stringWithFormat:@"0%lo", (unsigned long)dk.logMode] : @"unknown";
        [lines addObject:[NSString stringWithFormat:@"日志元数据:      size=%lld mtime=%.0f mode=%@ uid=%ld gid=%ld writable=%@ parent_writable=%@ read_error=%@",
                          dk.logSize, dk.logModificationTime, logMode,
                          (long)dk.logOwnerUID, (long)dk.logGroupGID,
                          dk.logWritable ? @"YES" : @"NO", dk.logParentWritable ? @"YES" : @"NO",
                          dk.logReadError.length ? dk.logReadError : @"none"]];
        [lines addObject:[NSString stringWithFormat:@"启动阶段:        %@", dk.startupStage.length ? dk.startupStage : @"(日志未提供)"]];
        [lines addObject:[NSString stringWithFormat:@"启动 errno:       %@", dk.startupErrno >= 0 ? CLDiagErrnoLabel(dk.startupErrno) : @"(日志未提供)"]];
        [lines addObject:[NSString stringWithFormat:@"启动错误:         %@", dk.startupError.length ? dk.startupError : @"(日志未提供)"]];
        [lines addObject:@"日志尾部(aldente.log):"];
        [lines addObjectsFromArray:[self daemonLogTailLines:dk.logTail]];
        [lines addObject:@""];
    }

    // 最近一次「修复 daemon 启动」结果（若有）：spawn rc / launchctl rc / 端口变化
    if (self.repairSummaryText.length > 0) {
        [lines addObject:@"# 最近修复尝试"];
        [lines addObject:self.repairSummaryText];
        [lines addObject:@""];
    }

    // # 配置持久化链路
    [lines addObject:@"# 配置持久化链路"];
    CLDiagConfigPersistence *p = self.configPersistence;
    [lines addObject:[NSString stringWithFormat:@"App 配置路径:     %@", p.appPath.length ? p.appPath : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"daemon 配置路径:  %@", p.daemonPath.length ? p.daemonPath : @"(无法获取)"]];
    [lines addObject:[NSString stringWithFormat:@"规范化路径一致:   %@", p.sameCanonicalPath ? @"YES" : @"NO"]];
    NSString *appMode = p.appMode >= 0 ? [NSString stringWithFormat:@"0%lo", (unsigned long)p.appMode] : @"unknown";
    [lines addObject:[NSString stringWithFormat:@"App 文件状态:     exists=%@ parent_writable=%@ size=%lld mtime=%.0f mode=%@ uid=%ld gid=%ld",
                      p.appExists ? @"YES" : @"NO", p.appParentWritable ? @"YES" : @"NO",
                      p.appSize, p.appModificationTime, appMode,
                      (long)p.appOwnerUID, (long)p.appGroupGID]];
    NSString *daemonMode = p.daemonMode >= 0 ? [NSString stringWithFormat:@"0%lo", (unsigned long)p.daemonMode] : @"unknown";
    [lines addObject:[NSString stringWithFormat:@"daemon 文件状态:  exists=%@ parent_writable=%@ size=%lld mtime=%.0f mode=%@ uid=%ld gid=%ld",
                      p.daemonExists ? @"YES" : @"NO", p.daemonParentWritable ? @"YES" : @"NO",
                      p.daemonSize, p.daemonModificationTime, daemonMode,
                      (long)p.daemonOwnerUID, (long)p.daemonGroupGID]];
    [lines addObject:[NSString stringWithFormat:@"路径解析来源:     %@", p.pathResolutionSource.length ? p.pathResolutionSource : @"unknown"]];
    [lines addObject:[NSString stringWithFormat:@"最近写入:         stage=%@ verified=%@ error=%@/%ld errno=%ld",
                      p.lastWriteStage.length ? p.lastWriteStage : @"never",
                      p.lastWriteVerified ? @"YES" : @"NO",
                      p.lastWriteErrorDomain.length ? p.lastWriteErrorDomain : @"none",
                      (long)p.lastWriteErrorCode, (long)p.lastWriteErrno]];
    [lines addObject:[NSString stringWithFormat:@"daemon 已加载键数: %ld", (long)p.daemonLoadedKeyCount]];
    [lines addObject:[NSString stringWithFormat:@"最近 daemon 重载: state=%@ ok=%@",
                      p.daemonReloadState.length ? p.daemonReloadState : @"never",
                      p.daemonLastReloadOK ? @"YES" : @"NO"]];
    [lines addObject:@""];

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
            [out addObject:[NSString stringWithFormat:@"  %@", CLRedactJBRootTokensForDiag(line)]];
        }
    }
    return out.count ? out : @[@"  (空)"];
}

@end

@implementation CLDiagnosticCollector

+ (void)collectWithPolicySummary:(NSString *)policySummary
                   probeSummary:(NSString *)probeSummary
                 repairSummary:(NSString *)repairSummary
                     completion:(void (^)(CLDiagnosticReport *))completion {
    CLDiagnosticReport *report = [CLDiagnosticReport new];
    report.policySummaryText = policySummary;
    report.probeSummaryText = probeSummary;
    report.repairSummaryText = repairSummary;

    // 1) 本地环境（不依赖 daemon）；device/sys/app 先用 manager 缓存兜底
    CLBatteryManager *mgr = [CLBatteryManager shared];
    CLDiagEnvironment *env = [CLDiagEnvironment new];
    env.packageScheme = CLPackageSchemeString();
    env.jbType = CLJBTypeLabelFromCode(CLDiagGetJBTypeCode());
    env.exePath = CLSanitizePathForDiag(CLDiagCallGetSelfExePath());
    env.dataRootPath = CLSanitizePathForDiag(CLDiagCallGetRuntimeDataRootPath());
    NSTimeInterval boot = CLDiagCallGetSysBoottime();
    if (boot <= 0 && mgr.systemBootTime > 0) {
        boot = mgr.systemBootTime;
    }
    env.systemBootTime = boot;
    env.deviceModel = mgr.deviceModel.length ? mgr.deviceModel : CLDiagLocalDeviceModel();
    env.systemVersion = mgr.systemVersion.length ? mgr.systemVersion : CLDiagLocalSystemVersion();
    env.appVersion = mgr.appVersion.length ? mgr.appVersion : CLDiagLocalAppVersion();
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

    NSDictionary *appConfig = getConfigPersistenceDiagnostics_C() ?: @{};
    CLDiagConfigPersistence *config = [CLDiagConfigPersistence new];
    NSString *rawAppPath = [appConfig[@"config_path"] isKindOfClass:[NSString class]]
        ? appConfig[@"config_path"] : @"";
    config.appPath = CLSanitizePathForDiag(rawAppPath);
    config.appExists = [appConfig[@"config_exists"] boolValue];
    config.appParentWritable = [appConfig[@"config_parent_writable"] boolValue];
    config.appMode = appConfig[@"config_mode"] != nil ? [appConfig[@"config_mode"] integerValue] : -1;
    config.appOwnerUID = appConfig[@"config_owner_uid"] != nil ? [appConfig[@"config_owner_uid"] integerValue] : -1;
    config.appGroupGID = appConfig[@"config_group_gid"] != nil ? [appConfig[@"config_group_gid"] integerValue] : -1;
    config.appSize = [appConfig[@"config_size"] longLongValue];
    config.appModificationTime = [appConfig[@"config_mtime"] doubleValue];
    config.pathResolutionSource = [appConfig[@"path_resolution_source"] isKindOfClass:[NSString class]]
        ? appConfig[@"path_resolution_source"] : @"uninitialized";
    config.lastWriteStage = [appConfig[@"last_write_stage"] isKindOfClass:[NSString class]]
        ? appConfig[@"last_write_stage"] : @"never";
    config.lastWriteErrorDomain = [appConfig[@"last_write_error_domain"] isKindOfClass:[NSString class]]
        ? appConfig[@"last_write_error_domain"] : @"";
    config.lastWriteErrorCode = [appConfig[@"last_write_error_code"] integerValue];
    config.lastWriteErrno = [appConfig[@"last_write_errno"] integerValue];
    config.lastWriteVerified = [appConfig[@"last_write_verified"] boolValue];
    config.daemonPath = @"(daemon 离线)";
    config.daemonMode = -1;
    config.daemonOwnerUID = -1;
    config.daemonGroupGID = -1;
    config.daemonReloadState = @"never";
    config.daemonLastReloadOK = NO;
    report.configPersistence = config;

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
            link.daemonExecutable = [probeRaw[@"daemon_executable"] boolValue];
            link.daemonMode = [probeRaw[@"daemon_mode"] integerValue];
            link.daemonOwnerUID = [probeRaw[@"daemon_owner_uid"] integerValue];
            link.daemonGroupGID = [probeRaw[@"daemon_group_gid"] integerValue];
            link.daemonProcessPID = [probeRaw[@"daemon_process_pid"] integerValue];
            link.initialPortOpen = [probeRaw[@"initial_port_open"] boolValue];
            link.portProbe = [probeRaw[@"port_probe"] isKindOfClass:[NSDictionary class]] ? probeRaw[@"port_probe"] : @{};
            link.logPath = CLSanitizePathForDiag(probeRaw[@"log_path"]);
            link.logExists = [probeRaw[@"log_exists"] boolValue];
            link.logWritable = [probeRaw[@"log_writable"] boolValue];
            link.logParentWritable = [probeRaw[@"log_parent_writable"] boolValue];
            link.logMode = [probeRaw[@"log_mode"] integerValue];
            link.logOwnerUID = [probeRaw[@"log_owner_uid"] integerValue];
            link.logGroupGID = [probeRaw[@"log_group_gid"] integerValue];
            link.logSize = [probeRaw[@"log_size"] longLongValue];
            link.logModificationTime = [probeRaw[@"log_mtime"] doubleValue];
            link.logReadError = [probeRaw[@"log_read_error"] isKindOfClass:[NSString class]] ? probeRaw[@"log_read_error"] : @"";
            link.logTail = [probeRaw[@"log_tail"] isKindOfClass:[NSString class]] ? probeRaw[@"log_tail"] : @"";
            NSString *startupErrno = CLDiagValueBetween(link.logTail, @" errno=", @" error=");
            link.startupStage = CLDiagValueBetween(link.logTail, @" startup_stage=", @" errno=");
            link.startupErrno = startupErrno.length ? startupErrno.integerValue : -1;
            link.startupError = CLDiagValueBetween(link.logTail, @" error=", @" port=");
            report.daemonLink = link;
            // 离线时仍用本地 scheme 格式化 jailbreak 状态，避免误导
            probe.libjailbreakStatus = CLFormatLibjailbreakStatus(NO, env.packageScheme, env.jbType);
        } else {
            conn.httpReachable = YES;
            conn.daemonAlive = YES;
            conn.lastApiError = @"0";
            NSDictionary *data = response[@"data"];
            if ([data isKindOfClass:[NSDictionary class]]) {
                NSDictionary *daemonConfig = [data[@"config_persistence"] isKindOfClass:[NSDictionary class]]
                    ? data[@"config_persistence"] : @{};
                NSString *rawDaemonPath = [daemonConfig[@"config_path"] isKindOfClass:[NSString class]]
                    ? daemonConfig[@"config_path"] : @"";
                config.daemonPath = CLSanitizePathForDiag(rawDaemonPath);
                config.daemonExists = [daemonConfig[@"config_exists"] boolValue];
                config.daemonParentWritable = [daemonConfig[@"config_parent_writable"] boolValue];
                config.daemonMode = daemonConfig[@"config_mode"] != nil ? [daemonConfig[@"config_mode"] integerValue] : -1;
                config.daemonOwnerUID = daemonConfig[@"config_owner_uid"] != nil ? [daemonConfig[@"config_owner_uid"] integerValue] : -1;
                config.daemonGroupGID = daemonConfig[@"config_group_gid"] != nil ? [daemonConfig[@"config_group_gid"] integerValue] : -1;
                config.daemonSize = [daemonConfig[@"config_size"] longLongValue];
                config.daemonModificationTime = [daemonConfig[@"config_mtime"] doubleValue];
                config.daemonLoadedKeyCount = [data[@"loaded_key_count"] integerValue];
                NSDictionary *reload = [data[@"config_reload"] isKindOfClass:[NSDictionary class]]
                    ? data[@"config_reload"] : @{};
                config.daemonReloadState = [reload[@"state"] isKindOfClass:[NSString class]]
                    ? reload[@"state"] : @"never";
                config.daemonLastReloadOK = [reload[@"reload_ok"] boolValue];
                NSString *appIdentity = CLConfigIdentityForDiag(rawAppPath);
                NSString *daemonIdentity = CLConfigIdentityForDiag(rawDaemonPath);
                config.sameCanonicalPath = appIdentity.length > 0 && [appIdentity isEqualToString:daemonIdentity];

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
