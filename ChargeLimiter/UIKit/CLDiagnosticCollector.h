//
//  CLDiagnosticCollector.h
//  ChargeLimiter
//
//  诊断采集模型与 Markdown 格式化（纯 Foundation，不含 UI）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLDiagEnvironment : NSObject
@property (nonatomic, copy) NSString *deviceModel;
@property (nonatomic, copy) NSString *systemVersion;
@property (nonatomic, copy) NSString *appVersion;
@property (nonatomic, copy) NSString *packageScheme;
@property (nonatomic, copy) NSString *jbType;
@property (nonatomic, assign) int jbRawCode;              // getJBType 原始 code；-1=未取到
@property (nonatomic, copy) NSString *jbProbeDetail;       // symbol/jbroot/libroot 探测串
@property (nonatomic, copy) NSString *exePath;
@property (nonatomic, copy) NSString *dataRootPath;
@property (nonatomic, assign) NSTimeInterval systemBootTime;
@end

@interface CLDiagConnectivity : NSObject
@property (nonatomic, assign) BOOL daemonAlive;
@property (nonatomic, assign) BOOL httpReachable;
@property (nonatomic, copy) NSString *daemonUptimeText;
@property (nonatomic, copy) NSString *lastApiError;
@end

@interface CLDiagBatteryProbe : NSObject
@property (nonatomic, copy) NSString *serviceName;
@property (nonatomic, copy) NSArray<NSString *> *publishedKeys;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *keyPresent;
@property (nonatomic, assign) NSInteger iokitReturn;
@property (nonatomic, assign) BOOL useSmart;
/// 展示用文案：OK / 预期失败(roothide) / ❌dlopen失败 / N/A
@property (nonatomic, copy) NSString *libjailbreakStatus;
@property (nonatomic, copy) NSString *libroothideStatus;
/// 当前读到的电量/电流（来自 App 侧 manager 缓存；daemon 离线时仍可能有上次值）
@property (nonatomic, assign) NSInteger currentCapacityPercent;
@property (nonatomic, assign) NSInteger amperageMilliAmps;
@property (nonatomic, assign) BOOL hasLiveBatterySample;
@end

@interface CLDiagDaemonLink : NSObject
@property (nonatomic, copy) NSString *daemonPath;
@property (nonatomic, assign) BOOL daemonExists;
@property (nonatomic, assign) BOOL daemonExecutable;
@property (nonatomic, assign) NSInteger daemonMode;
@property (nonatomic, assign) NSInteger daemonOwnerUID;
@property (nonatomic, assign) NSInteger daemonGroupGID;
@property (nonatomic, assign) NSInteger daemonProcessPID;
@property (nonatomic, assign) BOOL initialPortOpen;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *portProbe;
@property (nonatomic, copy) NSString *logPath;
@property (nonatomic, assign) BOOL logExists;
@property (nonatomic, assign) BOOL logWritable;
@property (nonatomic, assign) BOOL logParentWritable;
@property (nonatomic, assign) NSInteger logMode;
@property (nonatomic, assign) NSInteger logOwnerUID;
@property (nonatomic, assign) NSInteger logGroupGID;
@property (nonatomic, assign) long long logSize;
@property (nonatomic, assign) NSTimeInterval logModificationTime;
@property (nonatomic, copy) NSString *logReadError;
@property (nonatomic, copy) NSString *logTail;
@property (nonatomic, copy) NSString *startupStage;
@property (nonatomic, assign) NSInteger startupErrno;
@property (nonatomic, copy) NSString *startupError;
@end

@interface CLDiagnosticReport : NSObject
@property (nonatomic, strong) CLDiagEnvironment *environment;
@property (nonatomic, strong) CLDiagConnectivity *connectivity;
@property (nonatomic, strong) CLDiagBatteryProbe *batteryProbe;
@property (nonatomic, strong) CLDiagDaemonLink *daemonLink; // 离线时才填充
@property (nonatomic, copy, nullable) NSString *policySummaryText;
@property (nonatomic, copy, nullable) NSString *probeSummaryText;
@property (nonatomic, copy, nullable) NSString *repairSummaryText; // 最近一次「修复 daemon 启动」结果摘要
- (NSString *)markdownText;
@end

@interface CLDiagnosticCollector : NSObject
/// 异步采集完整诊断。completion 保证在主线程回调。
+ (void)collectWithPolicySummary:(nullable NSString *)policySummary
                   probeSummary:(nullable NSString *)probeSummary
                 repairSummary:(nullable NSString *)repairSummary
                     completion:(void (^)(CLDiagnosticReport *report))completion;
@end

FOUNDATION_EXPORT NSString *CLPackageSchemeString(void);
FOUNDATION_EXPORT NSString *CLSanitizePathForDiag(NSString * _Nullable path);
FOUNDATION_EXPORT NSString *CLJBTypeLabelFromCode(int code);
FOUNDATION_EXPORT NSString *CLDiagErrnoLabel(NSInteger rc);

NS_ASSUME_NONNULL_END
