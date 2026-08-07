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

@interface CLDiagnosticReport : NSObject
@property (nonatomic, strong) CLDiagEnvironment *environment;
@property (nonatomic, strong) CLDiagConnectivity *connectivity;
@property (nonatomic, strong) CLDiagBatteryProbe *batteryProbe;
@property (nonatomic, copy, nullable) NSString *policySummaryText;
@property (nonatomic, copy, nullable) NSString *probeSummaryText;
- (NSString *)markdownText;
@end

@interface CLDiagnosticCollector : NSObject
/// 异步采集完整诊断。completion 保证在主线程回调。
+ (void)collectWithPolicySummary:(nullable NSString *)policySummary
                   probeSummary:(nullable NSString *)probeSummary
                     completion:(void (^)(CLDiagnosticReport *report))completion;
@end

FOUNDATION_EXPORT NSString *CLPackageSchemeString(void);
FOUNDATION_EXPORT NSString *CLSanitizePathForDiag(NSString * _Nullable path);
FOUNDATION_EXPORT NSString *CLJBTypeLabelFromCode(int code);

NS_ASSUME_NONNULL_END
