#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

#import <Foundation/Foundation.h>

int main(int argc, char** argv) {
    @autoreleasepool {
        NSLog(@"[CL-Daemon] simulator stub start");
        return 0;
    }
}

#else

#include <sqlite3.h>
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#include <notify.h>

#import "CLSimpleHTTPServer.h"

#include "utils.h"

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
static const unsigned int kCLCSOpsStatus = 0;

#define kHIDPage_PowerDevice                    0x84
#define kHIDUsage_PD_PeripheralDevice           0x06
#define kHIDPage_BatterySystem                  0x85
#define kHIDUsage_BS_PrimaryBattery             0x2e
#define kHIDPage_AppleVendor                    0xFF00
#define kHIDUsage_AppleVendor_AccessoryBattery  0x14

#define S_OK        0
#define S_FALSE     1

#define kIOMessageServiceIsTerminated           0xE0000010
#define kIOPMMessageBatteryStatusHasChanged     0xE0024100

typedef SInt32      HRESULT;
typedef UInt32      ULONG;
typedef void*       LPVOID;
typedef CFUUIDBytes REFIID;

typedef void (*IOUPSEventCallbackFunction)(void* target, IOReturn result, void* refcon, void* sender, CFDictionaryRef event);

struct IOUPSPlugInInterface {
    void*       _reserved;
    HRESULT     (*QueryInterface)(void* thisPointer, REFIID iid, LPVOID* ppv); // IUNKNOWN_C_GUTS
    ULONG       (*AddRef)(void* thisPointer); // IUNKNOWN_C_GUTS
    ULONG       (*Release)(void* thisPointer); // IUNKNOWN_C_GUTS
    IOReturn    (*getProperties)(void* thisPointer, CFDictionaryRef* properties);
    IOReturn    (*getCapabilities)(void* thisPointer, CFSetRef* capabilities);
    IOReturn    (*getEvent)(void* thisPointer, CFDictionaryRef* event);
    IOReturn    (*setEventCallback)(void* thisPointer, IOUPSEventCallbackFunction callback, void* target, void* refcon);
    IOReturn    (*sendCommand)(void* thisPointer, CFDictionaryRef command);
};

struct IOUPSPlugInInterface_v140 {
    void*       _reserved;
    HRESULT     (*QueryInterface)(void* thisPointer, REFIID iid, LPVOID* ppv); // IUNKNOWN_C_GUTS
    ULONG       (*AddRef)(void* thisPointer); // IUNKNOWN_C_GUTS
    ULONG       (*Release)(void* thisPointer); // IUNKNOWN_C_GUTS
    IOReturn    (*getProperties)(void* thisPointer, CFDictionaryRef* properties);
    IOReturn    (*getCapabilities)(void* thisPointer, CFSetRef* capabilities);
    IOReturn    (*getEvent)(void* thisPointer, CFDictionaryRef* event);
    IOReturn    (*setEventCallback)(void* thisPointer, IOUPSEventCallbackFunction callback, void* target, void* refcon);
    IOReturn    (*sendCommand)(void* thisPointer, CFDictionaryRef command);
    IOReturn    (*createAsyncEventSource)(void* thisPointer, CFTypeRef* source);
};

struct IOCFPlugInInterface {
    void*       _reserved;
    HRESULT     (*QueryInterface)(void* thisPointer, REFIID iid, LPVOID* ppv); // IUNKNOWN_C_GUTS
    ULONG       (*AddRef)(void* thisPointer); // IUNKNOWN_C_GUTS
    ULONG       (*Release)(void* thisPointer); // IUNKNOWN_C_GUTS
    UInt16      version;
    UInt16      revision;
    IOReturn    (*Probe)(void* thisPointer, CFDictionaryRef propertyTable, io_service_t service, SInt32* order);
    IOReturn    (*Start)(void* thisPointer, CFDictionaryRef propertyTable, io_service_t service);
    IOReturn    (*Stop)(void* thisPointer);
};

extern "C" {
kern_return_t IOCreatePlugInInterfaceForService(io_service_t service, CFUUIDRef pluginType, CFUUIDRef interfaceType, IOCFPlugInInterface*** theInterface, SInt32* theScore);
}

@interface UPSDataSlim: NSObject
@property IOUPSPlugInInterface_v140**   interface;
@property io_object_t                   noti;
@property CFRunLoopSourceRef            source;
@property CFRunLoopTimerRef             timer;
@property(retain) NSMutableDictionary*  props;
- (instancetype)init;
- (void)initDB;
- (void)updateProps:(NSDictionary*)props isEvent:(BOOL)event;
@end

enum {
    CL_MODE_PLUG = 1,
};

static NSDictionary* bat_info = nil;
static BOOL g_enable = NO;
static BOOL g_enable_floatwnd = NO;
static BOOL g_use_smart = NO;
static int g_jbtype = -1;
static int g_serv_boot = 0;
static BOOL g_fullChargeWindowActive = NO;
static NSTimer* g_fullChargeScheduleTimer = nil;
static time_t g_fullChargeScheduleBoundaryTs = 0;
static NSTimer* g_holdMonitorTimer = nil;
static int g_holdMonitorTimerIntervalSeconds = 0;
static NSTimer* g_disableInflowRetryTimer = nil;
static NSTimer* g_trollStoreBundleCheckTimer = nil;
static int g_disableInflowRetryAttemptsRemaining = 0;
static BOOL g_chargeCommandEnabled = YES;
static NSString* g_policyState = @"battery";
static NSString* g_policyReason = @"daemon_boot";
static NSString* g_lastPolicyChangeReason = @"daemon_boot";
static time_t g_lastPolicyChangeTs = 0;
static time_t g_lastChargeCommandTs = 0;
static time_t g_lastInflowCommandTs = 0;
static int g_smartChargeStatus = -1;
static BOOL g_tempSmartChargeDisabledByCL = NO;
static int g_smartChargeCoordinationOriginalStatus = -1;
static NSString* g_smartChargeCoordinationSessionID = nil;
static time_t g_smartChargeCoordinationStartedTs = 0;
static BOOL g_holdHasReachedTargetSincePlug = NO;
static BOOL g_holdMonitorCheckRequested = NO;
static NSArray* g_recentPolicyTransitions = nil;
static NSArray* g_policyEventHistory = nil;
static BOOL g_predictiveInhibitFallbackActive = NO;
static BOOL g_chargeControlProbeRunning = NO;
static NSObject *g_probeLock = nil;
static NSDictionary* g_lastConfigReloadDiagnostics = nil;

static NSObject *CLProbeGetLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_probeLock = [[NSObject alloc] init];
    });
    return g_probeLock;
}

static const int kHoldDefaultMonitorIntervalMinutes = 3;
static const int kHoldMinMonitorIntervalMinutes = 1;
static const int kHoldMaxMonitorIntervalMinutes = 10;
static const int kHoldCurrentChargeThresholdmA = 120;
static const int kHoldCurrentDischargeThresholdmA = -120;
static const NSUInteger kPolicyTransitionHistoryLimit = 8;
static const NSUInteger kPolicyEventHistoryLimit = 48;
static const NSUInteger kPolicyEventDBLimit = 5000;
static const int kDisableInflowRetryMaxAttempts = 3;
static const NSTimeInterval kDisableInflowRetryDelaySeconds = 0.6;
static const NSTimeInterval kPredictiveInhibitFallbackVerifyDelaySeconds = 8.0;
static NSString* const kDaemonResetAndExitNotifyName = @"com.chargelimiter.mod.daemon.reset_and_exit";
static NSString* const kDaemonRestoreNotifyName = @"com.chargelimiter.mod.daemon.restore";

// iOS 17 禁流态守卫：禁流态下 ExternalConnected/ExternalChargeCapable 由系统间接派生，息屏周期性刷新会抖动，
// 不能当插电边沿判据。此函数用语义判定当前是否处于禁流态：用户开关 adv_disable_inflow=YES，或上一轮
// policy 落在禁流相关态（no_inflow / temp_paused）。与 isInflowRuntimeLikelyDisabled 口径对齐，不引入时间窗口。
static BOOL isInflowGuardActive(BOOL advDisableInflow, NSString* policyState) {
    if (advDisableInflow) {
        return YES;
    }
    NSString* state = policyState ?: @"";
    return [state isEqualToString:@"no_inflow"] || [state isEqualToString:@"temp_paused"];
}

static BOOL isInflowRuntimeLikelyDisabled(BOOL advDisableInflow, BOOL inflowEnabledSnapshot, NSString* previousPolicyState) {
    if (!advDisableInflow || inflowEnabledSnapshot) {
        return NO;
    }
    // 禁流模式下 ExternalConnected 可能滞后，用上一轮 runtime policy 辅助判断当前是否已真正处于禁流态。
    return [previousPolicyState isEqualToString:@"no_inflow"];
}

static BOOL shouldIssueDisableInflowCommand(BOOL advDisableInflow, BOOL inflowEnabledSnapshot, NSString* previousPolicyState) {
    if (!advDisableInflow) {
        return NO;
    }
    if (inflowEnabledSnapshot) {
        return YES;
    }
    return ![previousPolicyState isEqualToString:@"no_inflow"];
}

static BOOL shouldIssueEnableInflowCommand(BOOL advDisableInflow, BOOL inflowEnabledSnapshot, NSString* previousPolicyState) {
    if (!advDisableInflow) {
        return NO;
    }
    if (!inflowEnabledSnapshot) {
        return YES;
    }
    return [previousPolicyState isEqualToString:@"no_inflow"];
}
static NSString* const kSmartChargeCoordinationStateKey = @"_runtime_smart_charge_coordination_state";
static NSString* const kPolicyEventHistoryKey = @"_runtime_policy_event_history";
static NSString* const kPolicyEventDBTableName = @"policy_events";

static IONotificationPortRef gNotifyPort = NULL;
static io_object_t iopmpsNoti = IO_OBJECT_NULL;
static UPSDataSlim* gUPSPS = nil;
static int gDaemonResetAndExitNotifyToken = 0;
static int gDaemonRestoreNotifyToken = 0;

NSDictionary* handleReq(NSDictionary* nsreq);
static void onBatteryEventEnd(void);
static void updateStatistics(void);
static void evaluateFullChargeSchedule(BOOL forceApply);
static void refreshBatteryStateAndApplyPolicy(void);
static void applyChargePolicy(NSDictionary* oldInfo, NSDictionary* info);
static BOOL historyStatsEnabled(void);
static BOOL hasPotentialExternalPowerSignal(NSDictionary* info);
static BOOL isDisableInflowRetryEligible(NSDictionary* info, NSString* policyState);
static void cancelDisableInflowRetry(void);
static void armDisableInflowRetryIfNeeded(NSDictionary* info, NSString* policyState, BOOL allowStart);
static void syncSmartChargeCoordination(NSDictionary* info, BOOL isAdaptorConnected);
static int getEffectiveBatteryCurrent(NSDictionary* info);
static BOOL currentLooksCharging(int current);
static void appendPolicyEventHistory(NSString* eventType, NSString* fromState, NSString* toState, NSString* reason, NSDictionary* info, NSDictionary* extras, time_t now);
static void insertPolicyEventDBData(NSDictionary* event);
static void migrateStoredPolicyEventsToDBIfNeeded(NSArray* history);
static NSString* policyEventTypeForTransition(NSString* nextPolicyState, NSString* reason);
static void appendSmartChargeCoordinationEvent(NSString* reason, int fromStatus, int toStatus, NSDictionary* info, NSDictionary* extras, time_t now);
static void loadSmartChargeCoordinationRuntimeState(void);
static void tryRestoreSmartChargeAfterCoordination(NSString* reason);
static NSDictionary* performFullSmartChargeRestore(NSString* reason);
static void performAcccharge(BOOL flag);
static void restoreSmartChargeForReset(NSString* reason);
static void restoreThermalSimulationForReset(void);
static void restoreAcceleratedChargeStateForReset(void);
static void refreshMCLMaintainTimer(void);
static NSDictionary* mclMaintainRuntimeSnapshot(void);
static void resetBatteryStatusWithContext(BOOL restoreRuntimeSideEffects, NSString* reason);
static void refreshTrollStoreBundleCheckTimer(void);
static NSDictionary* CLMasterOffGateRequest(NSString* api, NSDictionary* nsreq);
static void CLMasterOffShutdown(NSString* reason);
static void CLMasterOnBootstrapSelf(void);

@interface Service: NSObject<UNUserNotificationCenterDelegate>
+ (instancetype)inst;
- (instancetype)init;
- (void)serve;
- (void)initLocalPush;
- (void)localPush:(NSString*)title msg:(NSString*)msg identifier:(NSString*)identifier;
- (void)systemTimeContextDidChange:(NSNotification*)note;
@end

static int clampIntValue(int value, int minValue, int maxValue) {
    if (value < minValue) {
        return minValue;
    }
    if (value > maxValue) {
        return maxValue;
    }
    return value;
}

static BOOL shouldRefreshBatteryPolicyForConfigKey(NSString* key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return NO;
    }
    return [@[
        @"mode",
        @"charge_below",
        @"charge_above",
        @"enable_temp",
        @"charge_temp_below",
        @"charge_temp_above",
        @"adv_predictive_inhibit_charge",
        @"adv_system_capacity_control_at_100",
        @"adv_disable_inflow",
        @"adv_hold_enabled",
        @"adv_hold_band",
        @"adv_hold_behavior",
        @"adv_hold_temp_disable_smart_charge",
        @"disable_smart_charge"
    ] containsObject:key];
}

static BOOL isFullChargeScheduleEnabled() {
    return getLocalBool(@"full_charge_sched_enabled", NO);
}

static int getFullChargeScheduleIntervalDays() {
    return clampIntValue(getLocalInt(@"full_charge_sched_interval_days", 7), 1, 90);
}

static int getFullChargeScheduleStartMinute() {
    return clampIntValue(getLocalInt(@"full_charge_sched_start_minute", 120), 0, 23 * 60 + 59);
}

static int getFullChargeScheduleDurationHours() {
    return clampIntValue(getLocalInt(@"full_charge_sched_duration_hours", 4), 1, 12);
}

static BOOL isHoldModeEnabled() {
    return getLocalBool(@"adv_hold_enabled", NO);
}

static BOOL shouldHandOverCapacityControlAt100() {
    return getLocalBool(@"adv_system_capacity_control_at_100", YES);
}

static BOOL shouldDisableCapacityControlForTarget(int chargeAbove) {
    return chargeAbove >= 100 && shouldHandOverCapacityControlAt100();
}

static BOOL isHoldCapacityControlAvailableForConfiguredTarget() {
    return isHoldModeEnabled() && !shouldDisableCapacityControlForTarget(getLocalInt(@"charge_above", 100));
}

static int getHoldModeBand() {
    return clampIntValue(getLocalInt(@"adv_hold_band", 5), 1, 10);
}

static int getHoldCheckIntervalMinutes() {
    return clampIntValue(getLocalInt(@"adv_hold_check_interval_minutes", kHoldDefaultMonitorIntervalMinutes),
                         kHoldMinMonitorIntervalMinutes,
                         kHoldMaxMonitorIntervalMinutes);
}

static int getHoldCheckIntervalSeconds() {
    return getHoldCheckIntervalMinutes() * 60;
}

static BOOL isHoldSmartChargeCoordinationEnabled() {
    return getLocalBool(@"adv_hold_temp_disable_smart_charge", YES);
}

static int getHoldStrategyMonitorIntervalSeconds() {
    return getHoldCheckIntervalSeconds();
}

static void resetHoldSessionState() {
    g_holdHasReachedTargetSincePlug = NO;
}

static NSArray* recentPolicyTransitionHistory(void) {
    return g_recentPolicyTransitions ?: @[];
}

static NSArray* storedPolicyEventHistory(void) {
    NSArray* history = getLocalArray(kPolicyEventHistoryKey, @[]);
    if (![history isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray* sanitized = [NSMutableArray array];
    for (id item in history) {
        if ([item isKindOfClass:[NSDictionary class]]) {
            [sanitized addObject:item];
        }
    }
    return [sanitized copy];
}

static void persistPolicyEventHistory(void) {
    setLocalArray(kPolicyEventHistoryKey, g_policyEventHistory ?: @[]);
}

static void loadPolicyEventHistoryRuntimeState(void) {
    g_policyEventHistory = storedPolicyEventHistory();
    migrateStoredPolicyEventsToDBIfNeeded(g_policyEventHistory);
}

static NSArray* recentPolicyEventHistory(void) {
    return g_policyEventHistory ?: @[];
}

static NSDictionary* policyEventSnapshot(NSDictionary* info) {
    NSDictionary* safeInfo = info ?: bat_info ?: @{};
    NSMutableDictionary* snapshot = [NSMutableDictionary dictionary];
    snapshot[@"capacity"] = @([safeInfo[@"CurrentCapacity"] respondsToSelector:@selector(integerValue)] ? [safeInfo[@"CurrentCapacity"] integerValue] : 0);
    snapshot[@"temperature"] = @([safeInfo[@"Temperature"] respondsToSelector:@selector(integerValue)] ? [safeInfo[@"Temperature"] integerValue] : 0);
    snapshot[@"current"] = @(getEffectiveBatteryCurrent(safeInfo));
    snapshot[@"is_charging"] = @([safeInfo[@"IsCharging"] boolValue]);
    snapshot[@"external_connected"] = @([safeInfo[@"ExternalConnected"] boolValue]);
    snapshot[@"predictive_inhibit_active"] = @([safeInfo[@"PredictiveChargingInhibit"] boolValue]);
    snapshot[@"predictive_inhibit_fallback_active"] = @(g_predictiveInhibitFallbackActive);
    snapshot[@"charge_command_enabled"] = @(g_chargeCommandEnabled);
    snapshot[@"smart_charge_status"] = @(g_smartChargeStatus);
    snapshot[@"smart_charge_managed"] = @(g_tempSmartChargeDisabledByCL);
    snapshot[@"hold_behavior"] = @"balanced";
    snapshot[@"hold_check_interval_minutes"] = @(getHoldCheckIntervalMinutes());
    return snapshot;
}

static NSDictionary* buildPolicyEventRecord(NSString* eventType,
                                            NSString* fromState,
                                            NSString* toState,
                                            NSString* reason,
                                            NSDictionary* info,
                                            NSDictionary* extras,
                                            time_t now) {
    NSMutableDictionary* item = [policyEventSnapshot(info) mutableCopy];
    if (item == nil) {
        item = [NSMutableDictionary dictionary];
    }
    item[@"type"] = eventType ?: @"policy_transition";
    item[@"from"] = fromState ?: @"";
    item[@"to"] = toState ?: @"";
    item[@"reason"] = reason ?: @"unknown";
    item[@"ts"] = @(now);
    if ([extras isKindOfClass:[NSDictionary class]]) {
        for (NSString* key in extras) {
            if (key.length == 0 || extras[key] == nil) {
                continue;
            }
            item[key] = extras[key];
        }
    }
    return item;
}

static void appendPolicyEventHistory(NSString* eventType,
                                     NSString* fromState,
                                     NSString* toState,
                                     NSString* reason,
                                     NSDictionary* info,
                                     NSDictionary* extras,
                                     time_t now) {
    if (!historyStatsEnabled()) {
        return;
    }
    NSMutableArray* history = [recentPolicyEventHistory() mutableCopy];
    NSDictionary* item = buildPolicyEventRecord(eventType, fromState, toState, reason, info, extras, now);
    [history addObject:item];
    if (history.count > kPolicyEventHistoryLimit) {
        [history removeObjectsInRange:NSMakeRange(0, history.count - kPolicyEventHistoryLimit)];
    }
    g_policyEventHistory = [history copy];
    persistPolicyEventHistory();
    insertPolicyEventDBData(item);
}

static void notifyForChargeCommandTransition(BOOL previousExternalConnected,
                                             BOOL currentExternalConnected,
                                             BOOL previousEnabled,
                                             BOOL currentEnabled,
                                             NSString* previousState,
                                             NSString* currentState,
                                             NSString* previousReason,
                                             NSString* reason);

static NSString* policyEventTypeForTransition(NSString* nextPolicyState, NSString* reason) {
    NSString* safeState = nextPolicyState ?: @"";
    NSString* safeReason = reason ?: @"";
    if ([safeReason isEqualToString:@"temperature_high"] || [safeReason isEqualToString:@"temperature_recovered"] || [safeReason isEqualToString:@"temperature_hysteresis"] || [safeState isEqualToString:@"temp_paused"]) {
        return @"thermal_event";
    }
    if ([safeReason hasPrefix:@"hold_"] || [safeState hasPrefix:@"hold"]) {
        return @"hold_event";
    }
    return @"policy_transition";
}

static void appendSmartChargeCoordinationEvent(NSString* reason,
                                               int fromStatus,
                                               int toStatus,
                                               NSDictionary* info,
                                               NSDictionary* extras,
                                               time_t now) {
    if (fromStatus == toStatus) {
        return;
    }
    NSMutableDictionary* eventExtras = [NSMutableDictionary dictionary];
    if ([extras isKindOfClass:[NSDictionary class]]) {
        [eventExtras addEntriesFromDictionary:extras];
    }
    eventExtras[@"smart_charge_from"] = @(fromStatus);
    eventExtras[@"smart_charge_to"] = @(toStatus);
    if (g_smartChargeCoordinationSessionID.length > 0) {
        eventExtras[@"session_id"] = g_smartChargeCoordinationSessionID;
    }
    if (g_smartChargeCoordinationOriginalStatus >= 0) {
        eventExtras[@"original_status"] = @(g_smartChargeCoordinationOriginalStatus);
    }
    appendPolicyEventHistory(@"smart_charge_event",
                             @"",
                             @"",
                             reason,
                             info,
                             eventExtras,
                             now);
}

static void appendPolicyTransitionHistory(NSString* fromState, NSString* toState, NSString* reason, time_t now) {
    NSMutableArray* history = [recentPolicyTransitionHistory() mutableCopy];
    [history addObject:@{
        @"from": fromState ?: @"",
        @"to": toState ?: @"",
        @"reason": reason ?: @"unknown",
        @"ts": @(now),
    }];
    if (history.count > kPolicyTransitionHistoryLimit) {
        [history removeObjectsInRange:NSMakeRange(0, history.count - kPolicyTransitionHistoryLimit)];
    }
    g_recentPolicyTransitions = [history copy];
}

static void updatePolicyRuntimeState(NSString* nextPolicyState, NSString* reason, NSDictionary* info, time_t now) {
    NSString* safeState = nextPolicyState ?: @"battery";
    NSString* safeReason = reason ?: @"unknown";
    NSString* previousState = g_policyState ?: @"battery";
    NSString* eventType = policyEventTypeForTransition(safeState, safeReason);
    if (now <= 0) {
        now = time(0);
    }
    if (![previousState isEqualToString:safeState]) {
        g_lastPolicyChangeTs = now;
        g_lastPolicyChangeReason = safeReason;
        appendPolicyTransitionHistory(previousState, safeState, safeReason, now);
        appendPolicyEventHistory(eventType, previousState, safeState, safeReason, info, nil, now);
    } else if (g_lastPolicyChangeTs == 0) {
        g_lastPolicyChangeTs = now;
        g_lastPolicyChangeReason = safeReason;
        appendPolicyTransitionHistory(previousState, safeState, safeReason, now);
        appendPolicyEventHistory(eventType, previousState, safeState, safeReason, info, nil, now);
    }
    g_policyState = safeState;
    g_policyReason = safeReason;
}

static NSCalendar* fullChargeScheduleCalendar() {
    return [NSCalendar autoupdatingCurrentCalendar];
}

static NSString* fullChargeScheduleAnchorDateStringForDate(NSDate* date) {
    if (date == nil) {
        return @"";
    }
    NSDateComponents* comps = [[fullChargeScheduleCalendar() components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date] copy];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)comps.year, (long)comps.month, (long)comps.day];
}

static NSDate* fullChargeScheduleAnchorDateFromString(NSString* dateString) {
    if (![dateString isKindOfClass:[NSString class]] || dateString.length != 10) {
        return nil;
    }
    NSArray<NSString*>* parts = [dateString componentsSeparatedByString:@"-"];
    if (parts.count != 3) {
        return nil;
    }
    NSInteger year = [parts[0] integerValue];
    NSInteger month = [parts[1] integerValue];
    NSInteger day = [parts[2] integerValue];
    if (year < 2000 || month < 1 || month > 12 || day < 1 || day > 31) {
        return nil;
    }
    NSDateComponents* comps = [[NSDateComponents alloc] init];
    comps.year = year;
    comps.month = month;
    comps.day = day;
    comps.hour = 0;
    comps.minute = 0;
    comps.second = 0;
    NSDate* date = [fullChargeScheduleCalendar() dateFromComponents:comps];
    if (date == nil) {
        return nil;
    }
    if (![fullChargeScheduleAnchorDateStringForDate(date) isEqualToString:dateString]) {
        return nil;
    }
    return date;
}

static NSDate* fullChargeScheduleStartDateForDay(NSDate* day, int startMinute) {
    NSCalendar* calendar = fullChargeScheduleCalendar();
    NSDateComponents* comps = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:day];
    comps.hour = startMinute / 60;
    comps.minute = startMinute % 60;
    comps.second = 0;
    return [calendar dateFromComponents:comps];
}

static NSString* computeInitialFullChargeScheduleAnchorDateString(time_t now) {
    if (!isFullChargeScheduleEnabled()) {
        return @"";
    }
    int startMinute = getFullChargeScheduleStartMinute();
    int durationHours = getFullChargeScheduleDurationHours();
    NSDate* nowDate = [NSDate dateWithTimeIntervalSince1970:now];
    NSCalendar* calendar = fullChargeScheduleCalendar();
    NSDate* todayDay = [calendar startOfDayForDate:nowDate];
    NSDate* todayStart = fullChargeScheduleStartDateForDay(todayDay, startMinute);
    NSDate* todayEnd = [todayStart dateByAddingTimeInterval:durationHours * 3600.0];
    if ([nowDate compare:todayEnd] == NSOrderedAscending) {
        return fullChargeScheduleAnchorDateStringForDate(todayDay);
    }
    NSDate* nextDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:todayDay options:0];
    return fullChargeScheduleAnchorDateStringForDate(nextDay);
}

static void resetFullChargeScheduleAnchorDate(time_t now) {
    NSString* anchorDate = computeInitialFullChargeScheduleAnchorDateString(now);
    setLocalString(@"full_charge_sched_anchor_date", anchorDate ?: @"");
    // Legacy key retained for cleanup compatibility; no longer used for scheduling.
    setLocalInt(@"full_charge_sched_next_ts", 0);
}

static NSDate* resolvedFullChargeScheduleAnchorDate(time_t now) {
    if (!isFullChargeScheduleEnabled()) {
        return nil;
    }
    NSString* anchorString = getLocalString(@"full_charge_sched_anchor_date", @"");
    NSDate* anchorDate = fullChargeScheduleAnchorDateFromString(anchorString);
    if (anchorDate == nil) {
        resetFullChargeScheduleAnchorDate(now);
        anchorString = getLocalString(@"full_charge_sched_anchor_date", @"");
        anchorDate = fullChargeScheduleAnchorDateFromString(anchorString);
    }
    return anchorDate;
}

typedef struct {
    BOOL enabled;
    BOOL active;
    time_t startTs;
    time_t endTs;
    time_t nextBoundaryTs;
} CLFullChargeScheduleState;

static CLFullChargeScheduleState fullChargeScheduleStateForScheduledDay(NSDate* scheduledDay) {
    CLFullChargeScheduleState state = {};
    NSDate* scheduledStart = fullChargeScheduleStartDateForDay(scheduledDay, getFullChargeScheduleStartMinute());
    NSDate* scheduledEnd = [scheduledStart dateByAddingTimeInterval:getFullChargeScheduleDurationHours() * 3600.0];
    state.startTs = (time_t)llround(scheduledStart.timeIntervalSince1970);
    state.endTs = (time_t)llround(scheduledEnd.timeIntervalSince1970);
    return state;
}

static CLFullChargeScheduleState getFullChargeScheduleState(time_t now) {
    CLFullChargeScheduleState state = {};
    state.enabled = isFullChargeScheduleEnabled();
    if (!state.enabled) {
        return state;
    }

    NSDate* anchorDay = resolvedFullChargeScheduleAnchorDate(now);
    if (anchorDay == nil) {
        return state;
    }

    NSCalendar* calendar = fullChargeScheduleCalendar();
    NSDate* nowDate = [NSDate dateWithTimeIntervalSince1970:now];
    NSDate* todayDay = [calendar startOfDayForDate:nowDate];
    NSInteger intervalDays = getFullChargeScheduleIntervalDays();
    NSInteger dayOffset = [calendar components:NSCalendarUnitDay fromDate:anchorDay toDate:todayDay options:0].day;
    NSInteger baseCycle = 0;
    if (dayOffset > 0) {
        baseCycle = dayOffset / intervalDays;
    }

    CLFullChargeScheduleState nextState = {};
    nextState.enabled = state.enabled;
    BOOL hasNextState = NO;
    NSInteger startCycle = MAX((NSInteger)0, baseCycle - 1);
    NSInteger endCycle = baseCycle + 1;
    for (NSInteger cycleIndex = startCycle; cycleIndex <= endCycle; cycleIndex++) {
        NSDate* scheduledDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:(cycleIndex * intervalDays) toDate:anchorDay options:0];
        CLFullChargeScheduleState candidate = fullChargeScheduleStateForScheduledDay(scheduledDay);
        candidate.enabled = state.enabled;
        if (now >= candidate.startTs && now < candidate.endTs) {
            candidate.active = YES;
            candidate.nextBoundaryTs = candidate.endTs;
            return candidate;
        }
        if (candidate.startTs > now && (!hasNextState || candidate.startTs < nextState.startTs)) {
            candidate.nextBoundaryTs = candidate.startTs;
            nextState = candidate;
            hasNextState = YES;
        }
    }

    if (hasNextState) {
        return nextState;
    }

    NSDate* fallbackDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:((baseCycle + 2) * intervalDays) toDate:anchorDay options:0];
    CLFullChargeScheduleState fallbackState = fullChargeScheduleStateForScheduledDay(fallbackDay);
    fallbackState.enabled = state.enabled;
    fallbackState.nextBoundaryTs = fallbackState.startTs;
    return fallbackState;
}

static BOOL isFullChargeWindowActive(time_t now, time_t* startOut, time_t* endOut) {
    CLFullChargeScheduleState state = getFullChargeScheduleState(now);
    if (startOut) {
        *startOut = state.startTs;
    }
    if (endOut) {
        *endOut = state.endTs;
    }
    return state.enabled && state.active;
}

static void refreshFullChargeScheduleTimer(time_t nextBoundaryTs) {
    BOOL shouldRun = (g_enable && isFullChargeScheduleEnabled() && nextBoundaryTs > 0);
    if (!shouldRun) {
        if (g_fullChargeScheduleTimer != nil) {
            [g_fullChargeScheduleTimer invalidate];
            g_fullChargeScheduleTimer = nil;
        }
        g_fullChargeScheduleBoundaryTs = 0;
        if (!isFullChargeScheduleEnabled()) {
            g_fullChargeWindowActive = NO;
        }
        return;
    }
    if (g_fullChargeScheduleTimer != nil && g_fullChargeScheduleBoundaryTs == nextBoundaryTs) {
        return;
    }
    if (g_fullChargeScheduleTimer != nil) {
        [g_fullChargeScheduleTimer invalidate];
        g_fullChargeScheduleTimer = nil;
    }

    NSDate* fireDate = [NSDate dateWithTimeIntervalSince1970:nextBoundaryTs];
    if (fireDate.timeIntervalSinceNow <= 0) {
        fireDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
        nextBoundaryTs = (time_t)llround(fireDate.timeIntervalSince1970);
    }

    g_fullChargeScheduleBoundaryTs = nextBoundaryTs;
    g_fullChargeScheduleTimer = [[NSTimer alloc] initWithFireDate:fireDate interval:0 repeats:NO block:^(NSTimer* timer) {
        @synchronized (Service.inst) {
            g_fullChargeScheduleTimer = nil;
            g_fullChargeScheduleBoundaryTs = 0;
            evaluateFullChargeSchedule(NO);
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_fullChargeScheduleTimer forMode:NSRunLoopCommonModes];
}

static void refreshHoldMonitorTimer(void) {
    BOOL shouldRun = (g_enable && isHoldCapacityControlAvailableForConfiguredTarget());
    if (!shouldRun) {
        if (g_holdMonitorTimer != nil) {
            [g_holdMonitorTimer invalidate];
            g_holdMonitorTimer = nil;
        }
        g_holdMonitorTimerIntervalSeconds = 0;
        return;
    }
    int intervalSeconds = getHoldCheckIntervalSeconds();
    if (g_holdMonitorTimer != nil && g_holdMonitorTimerIntervalSeconds == intervalSeconds) {
        return;
    }
    if (g_holdMonitorTimer != nil) {
        [g_holdMonitorTimer invalidate];
        g_holdMonitorTimer = nil;
    }
    g_holdMonitorTimerIntervalSeconds = intervalSeconds;
    g_holdMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:intervalSeconds repeats:YES block:^(NSTimer* timer) {
        @synchronized (Service.inst) {
            g_holdMonitorCheckRequested = YES;
            refreshBatteryStateAndApplyPolicy();
            g_holdMonitorCheckRequested = NO;
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_holdMonitorTimer forMode:NSRunLoopCommonModes];
}

static void cancelDisableInflowRetry(void) {
    if (g_disableInflowRetryTimer != nil) {
        [g_disableInflowRetryTimer invalidate];
        g_disableInflowRetryTimer = nil;
    }
    g_disableInflowRetryAttemptsRemaining = 0;
}

static void scheduleNextDisableInflowRetryAttempt(void) {
    if (g_disableInflowRetryTimer != nil || g_disableInflowRetryAttemptsRemaining <= 0) {
        return;
    }
    g_disableInflowRetryTimer = [NSTimer scheduledTimerWithTimeInterval:kDisableInflowRetryDelaySeconds repeats:NO block:^(NSTimer* timer) {
        @synchronized (Service.inst) {
            g_disableInflowRetryTimer = nil;
            if (g_disableInflowRetryAttemptsRemaining <= 0) {
                return;
            }
            if (!isDisableInflowRetryEligible(bat_info, g_policyState)) {
                cancelDisableInflowRetry();
                return;
            }
            g_disableInflowRetryAttemptsRemaining = MAX(g_disableInflowRetryAttemptsRemaining - 1, 0);
            refreshBatteryStateAndApplyPolicy();
            if (!isDisableInflowRetryEligible(bat_info, g_policyState) || g_disableInflowRetryAttemptsRemaining <= 0) {
                cancelDisableInflowRetry();
                return;
            }
            scheduleNextDisableInflowRetryAttempt();
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_disableInflowRetryTimer forMode:NSRunLoopCommonModes];
}

static void armDisableInflowRetryIfNeeded(NSDictionary* info, NSString* policyState, BOOL allowStart) {
    if (!isDisableInflowRetryEligible(info, policyState)) {
        cancelDisableInflowRetry();
        return;
    }
    if (!allowStart || g_disableInflowRetryTimer != nil || g_disableInflowRetryAttemptsRemaining > 0) {
        return;
    }
    g_disableInflowRetryAttemptsRemaining = kDisableInflowRetryMaxAttempts;
    scheduleNextDisableInflowRetryAttempt();
}

static void requestDaemonResetAndExit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        resetBatteryStatusWithContext(YES, @"daemon_reset_and_exit");
        exit(0);
    });
}

static void registerDaemonResetAndExitSignal(void) {
    if (gDaemonResetAndExitNotifyToken != 0) {
        return;
    }
    notify_register_dispatch(kDaemonResetAndExitNotifyName.UTF8String,
                             &gDaemonResetAndExitNotifyToken,
                             dispatch_get_main_queue(),
                             ^(int token) {
        requestDaemonResetAndExit();
    });
}

static void unregisterDaemonResetAndExitSignal(void) {
    if (gDaemonResetAndExitNotifyToken == 0) {
        return;
    }
    notify_cancel(gDaemonResetAndExitNotifyToken);
    gDaemonResetAndExitNotifyToken = 0;
}

static void requestDaemonSmartChargeRestore(void) {
    // 与 requestDaemonResetAndExit 同模式：notify 回调在主队列执行，电池事件同样
    // 跑在主 runloop，天然串行；还原为幂等系统级写，无需 Service 锁。
    dispatch_async(dispatch_get_main_queue(), ^{
        performFullSmartChargeRestore(@"daemon_restore_notify");
        refreshBatteryStateAndApplyPolicy();
    });
}

static void registerDaemonRestoreNotifySignal(void) {
    if (gDaemonRestoreNotifyToken != 0) {
        return;
    }
    notify_register_dispatch(kDaemonRestoreNotifyName.UTF8String,
                             &gDaemonRestoreNotifyToken,
                             dispatch_get_main_queue(),
                             ^(int token) {
        requestDaemonSmartChargeRestore();
    });
}

static void unregisterDaemonRestoreNotifySignal(void) {
    if (gDaemonRestoreNotifyToken == 0) {
        return;
    }
    notify_cancel(gDaemonRestoreNotifyToken);
    gDaemonRestoreNotifyToken = 0;
}

static void verifyBundleStillInstalledForCurrentMode(void) {
    if (g_jbtype != JBTYPE_TROLLSTORE) {
        return;
    }
    NSString* bundlePath = [getSelfExePath() stringByDeletingLastPathComponent];
    if (bundlePath.length == 0) {
        return;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
        return;
    }
    NSFileErrorLog(@"bundle missing for TrollStore path, restore and exit bundle=%@", bundlePath);
    resetBatteryStatusWithContext(YES, @"bundle_missing");
    exit(0);
}

static void refreshTrollStoreBundleCheckTimer(void) {
    if (g_jbtype != JBTYPE_TROLLSTORE) {
        if (g_trollStoreBundleCheckTimer != nil) {
            [g_trollStoreBundleCheckTimer invalidate];
            g_trollStoreBundleCheckTimer = nil;
        }
        return;
    }
    if (g_trollStoreBundleCheckTimer != nil) {
        return;
    }
    g_trollStoreBundleCheckTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer* timer) {
        @synchronized (Service.inst) {
            verifyBundleStillInstalledForCurrentMode();
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_trollStoreBundleCheckTimer forMode:NSRunLoopCommonModes];
}


// === iOS 17+ charge control override plane ============================
// iOS 17 重构了停充控制面。真机探针 + IDA 结论：
// - 读路径：AppleSmartBattery / IOPMPowerSource（发布 CurrentCapacity 等）
// - 写路径 service：AppleSmartBattery（Manager 的 setProperties 返回 Unsupported）
// - 可写 key：IsCharging (CH0C mode1) + PredictiveChargingInhibit (CH0B mode2)，极性相反
// - 可写禁流 key：FieldDiagsInflowInhibit (CH0J) / OBCInflowInhibit (CH0I)
// - ChargingOverride / InflowOverride 只是状态发布属性，当 setProperties key 会 BadArgument
// - 旧 IsCharging-only / ExternalConnected 在部分路径上仍可能 write_noop
static BOOL CLIsIOS17OrLater(void) {
    // getSysVer 返回形如 "17.1" / "16.6" / ""
    NSString* v = getSysVer() ?: @"";
    NSArray* parts = [v componentsSeparatedByString:@"."];
    NSInteger major = 0;
    if (parts.count >= 1 && [parts[0] respondsToSelector:@selector(integerValue)]) {
        major = [parts[0] integerValue];
    }
    return major >= 17;
}

static NSString* CLSmartBatteryManagerServiceName(void) {
    return @"AppleSmartBatteryManager";
}

// iOS 17 setProperties 目标是 AppleSmartBattery（属性发布 nub），不是 Manager。
// Manager 可匹配但：1) 不发布 CurrentCapacity 等读属性；2) setProperties 返回 kIOReturnUnsupported。
static NSString* CLOverrideWriteServiceName(void) {
    return @"AppleSmartBattery";
}

// 进程内缓存：首次 true 后不再重试匹配，避免每次写都做 IOServiceGetMatchingService。
// 缓存失败不致命，调用方回退旧逻辑。
static SInt8 g_overrideChargeControlCached = -1; // -1=未知, 0=否, 1=是

static BOOL CLCanUseOverrideChargeControl(void) {
    if (g_overrideChargeControlCached != -1) {
        return g_overrideChargeControlCached == 1;
    }
    if (!CLIsIOS17OrLater()) {
        g_overrideChargeControlCached = 0;
        return NO;
    }
    // 以真正可写 setProperties 的 AppleSmartBattery 为准；Manager 仅作诊断探针目标。
    io_service_t serv = IOServiceGetMatchingService(
        kIOMasterPortDefault,
        IOServiceMatching(CLOverrideWriteServiceName().UTF8String));
    BOOL ok = (serv != IO_OBJECT_NULL);
    if (ok) {
        IOObjectRelease(serv);
    }
    g_overrideChargeControlCached = ok ? 1 : 0;
    return ok;
}

// 复制一份 override 写 service；调用方必须 IOObjectRelease（与 getIOPMPSServ 缓存对象不同）。
static io_service_t CLCopyOverrideWriteService(void) {
    io_service_t serv = IOServiceGetMatchingService(
        kIOMasterPortDefault,
        IOServiceMatching(CLOverrideWriteServiceName().UTF8String));
    if (serv != IO_OBJECT_NULL) {
        return serv;
    }
    // 极端回退：个别环境只有 Manager 名可见
    return IOServiceGetMatchingService(
        kIOMasterPortDefault,
        IOServiceMatching(CLSmartBatteryManagerServiceName().UTF8String));
}

// iOS 17 停充：可写入口是 IsCharging (mode1/CH0C) + PredictiveChargingInhibit (mode2/CH0B)。
// ChargingOverride 只是状态发布属性，当 setProperties key 会返回 kIOReturnBadArgument
// （真机 2026-08-02 探针：ChargingOverride → -536870206，PCI 单独写 → 0）。
// 极性相反：停充 = IsCharging=NO + PredictiveChargingInhibit=YES；
//           恢复 = IsCharging=YES + PredictiveChargingInhibit=NO。
static kern_return_t writeChargeStatusOverride(io_service_t serv, BOOL stop) {
    if (serv == IO_OBJECT_NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    NSMutableDictionary* props = [NSMutableDictionary dictionary];
    props[@"IsCharging"] = @(stop ? NO : YES);
    props[@"PredictiveChargingInhibit"] = @(stop ? YES : NO);
    return IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props);
}

// iOS 17 禁流：可写入口是 FieldDiagsInflowInhibit（mode2/CH0J）+ OBCInflowInhibit（mode1/CH0I 备用）。
// InflowOverride 只是状态发布属性，当 setProperties key 会 BadArgument。
// flag=YES → 允许流入（inhibit=NO）；flag=NO → 禁流（inhibit=YES）。
static kern_return_t setInflowStatusOverride(io_service_t serv, BOOL flag) {
    if (serv == IO_OBJECT_NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    NSNumber* inhibit = @(flag ? NO : YES);
    NSMutableDictionary* props = [NSMutableDictionary dictionary];
    props[@"FieldDiagsInflowInhibit"] = inhibit;
    props[@"OBCInflowInhibit"] = inhibit;
    return IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props);
}

static io_service_t getIOPMPSServ() {
    static io_service_t serv = IO_OBJECT_NULL;
    if (serv == IO_OBJECT_NULL) {
        // 读路径必须用发布电池属性的 service（AppleSmartBattery / IOPMPowerSource）。
        // 切勿匹配 AppleSmartBatteryManager：它不发布 CurrentCapacity/Amperage，
        // 会导致 UI 电量全 0（真机 2026-08-02 探针已证实）。
        // iOS 17+ 默认优先 AppleSmartBattery（override 写目标与属性面一致）。
        BOOL try_smart = getLocalBool(@"adv_prefer_smart", NO) || CLIsIOS17OrLater();
        if (try_smart) {
            serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery")); // >=iPhone8
        }
        if (serv != IO_OBJECT_NULL) {
            g_use_smart = YES;
        } else {// SmartBattery not support, roll back to use IOPS
            serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
            // IOPMPowerSource:AppleARMPMUPowerSource:AppleARMPMUCharger
            //      IOAccessoryTransport:IOAccessoryPowerSource:AppleARMPMUAccessoryPS
            g_use_smart = NO;
        }
    }
    return serv;
}

static NSDictionary* getBatSlimInfo(NSDictionary* info) {
    NSMutableDictionary* filtered_info = [NSMutableDictionary dictionary];
    NSArray* keep = @[
        @"Amperage", @"AppleRawCurrentCapacity", @"BatteryInstalled", @"BootVoltage", @"CurrentCapacity", @"CycleCount", @"DesignCapacity", @"ExternalChargeCapable", @"ExternalConnected",
        @"InstantAmperage", @"IsCharging", @"ChargingOverride", @"NotChargingReason", @"NominalChargeCapacity", @"PostChargeWaitSeconds", @"PostDischargeWaitSeconds", @"PredictiveChargingInhibit", @"Serial", @"Temperature",
        @"UpdateTime", @"VirtualTemperature", @"Voltage"];
    for (NSString* key in info) {
        if ([keep containsObject:key]) {
            filtered_info[key] = info[key];
        }
    }
    if (filtered_info[@"NominalChargeCapacity"] == nil) {
        if (info[@"AppleRawMaxCapacity"] != nil) {
            filtered_info[@"NominalChargeCapacity"] = info[@"AppleRawMaxCapacity"];
        }
    }
    if (info[@"AdapterDetails"] != nil) {
        NSDictionary* adaptor_info = info[@"AdapterDetails"];
        NSMutableDictionary* filtered_adaptor_info = [NSMutableDictionary dictionary];
        keep = @[@"Current", @"Description", @"IsWireless", @"Manufacturer", @"Name", @"Voltage", @"Watts"];
        for (NSString* key in adaptor_info) {
            if ([keep containsObject:key]) {
                filtered_adaptor_info[key] = adaptor_info[key];
            }
        }
        if (filtered_adaptor_info[@"Voltage"] == nil) {
            if (adaptor_info[@"AdapterVoltage"] != nil) {
                filtered_adaptor_info[@"Voltage"] = adaptor_info[@"AdapterVoltage"];
            }
        }
        filtered_info[@"AdapterDetails"] = filtered_adaptor_info;
    }
    return filtered_info;
}

static int getBatInfoWithServ(io_service_t serv, NSDictionary* __strong* pinfo) {
    CFMutableDictionaryRef props = nil;
    IORegistryEntryCreateCFProperties(serv, &props, kCFAllocatorDefault, 0);
    if (props == nil) {
        return -2;
    }
    NSMutableDictionary* info = (__bridge_transfer NSMutableDictionary*)props;
    *pinfo = getBatSlimInfo(info);
    return 0;
}

static int getBatInfo(NSDictionary* __strong* pinfo, BOOL slim=YES) {
    io_service_t serv = getIOPMPSServ();
    if (serv == IO_OBJECT_NULL) {
        return -1;
    }
    CFMutableDictionaryRef props = nil;
    IORegistryEntryCreateCFProperties(serv, &props, kCFAllocatorDefault, 0);
    if (props == nil) {
        return -2;
    }
    NSMutableDictionary* info = (__bridge_transfer NSMutableDictionary*)props;
    if (slim) {
        *pinfo = getBatSlimInfo(info);
    } else {
        *pinfo = info;
    }
    return 0;
}

// 只读诊断:命中 service + 发布 key + 5 个关键 key 存在性 + 库加载。
// 硬约束:绝不 SetCFProperties / exit / kill / 写文件 / 改 g_use_smart。
static NSString* CLJBTypeString(void) {
    switch (getJBType()) {
        case JBTYPE_ROOTHIDE:   return @"roothide";
        case JBTYPE_ROOTLESS:   return @"rootless";
        case JBTYPE_ROOT:       return @"rootful";
        case JBTYPE_TROLLSTORE: return @"trollstore";
        default:                return @"unknown";
    }
}

static BOOL CLProbeLibJailbreakLoaded(void) {
    void* h = dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (h) {
        // 已加载则 NOLOAD 成功
        dlclose(h);
        return YES;
    }
    h = dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY);
    if (h) {
        dlclose(h);
        return YES;
    }
    return NO;
}

// roothide 下真实 /usr/lib 通常没有 libjailbreak；失败是预期，勿当故障。
static NSString* CLLibjailbreakStatusString(BOOL loaded) {
    if (loaded) {
        return @"OK";
    }
    if (getJBType() == JBTYPE_ROOTHIDE) {
        return @"N/A(roothide 预期:真实 /usr/lib 无此库)";
    }
    return @"❌dlopen失败";
}

static NSString* CLLibroothideStatusString(void) {
    if (getJBType() != JBTYPE_ROOTHIDE) {
        return @"N/A";
    }
    // 尝试若干常见路径（只读探测，立即 dlclose）
    const char* candidates[] = {
        "/usr/lib/libroothide.dylib",
        NULL,
    };
    for (int i = 0; candidates[i]; i++) {
        void* h = dlopen(candidates[i], RTLD_LAZY | RTLD_NOLOAD);
        if (!h) {
            h = dlopen(candidates[i], RTLD_LAZY);
        }
        if (h) {
            dlclose(h);
            return @"OK";
        }
    }
    // jbroot 内路径因随机前缀无法穷举；能判定 roothide 即说明运行时路径启发式可用
    return @"N/A(由 roothide 运行时解析,未在固定路径找到)";
}

static NSDictionary* getIOPMPSServDiagnostics(void) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    out[@"serv_boot"] = @(g_serv_boot);
    out[@"use_smart"] = @(g_use_smart);
    out[@"sysver"] = getSysVer() ?: @"";
    out[@"devmodel"] = getDevMdoel() ?: @"";
    out[@"ver"] = getAppVer() ?: @"";
    out[@"jbtype"] = CLJBTypeString();

    BOOL jbLoaded = CLProbeLibJailbreakLoaded();
    out[@"libjailbreak_loaded"] = @(jbLoaded);
    out[@"libjailbreak_status"] = CLLibjailbreakStatusString(jbLoaded);
    out[@"libroothide_status"] = CLLibroothideStatusString();

    // daemon 视角路径（App 侧 dlsym 失败时的权威来源）
    NSString* exe = getSelfExePath();
    if (exe.length > 0) {
        out[@"exe_path"] = exe;
    }
    NSString* dataRoot = getRuntimeDataRootPath();
    if (dataRoot.length > 0) {
        out[@"data_root"] = dataRoot;
    }

    NSDictionary* configPersistence = getConfigPersistenceDiagnostics_C();
    out[@"config_persistence"] = configPersistence ?: @{};
    out[@"loaded_key_count"] = @(getAllKV().count);
    out[@"config_reload"] = g_lastConfigReloadDiagnostics ?: @{
        @"state": @"never",
        @"reload_ok": @NO,
        @"loaded_key_count": @0,
        @"config_path": @"",
    };

    io_service_t serv = getIOPMPSServ();
    NSString* serviceName = @"(未匹配)";
    if (serv != IO_OBJECT_NULL) {
        serviceName = g_use_smart ? @"AppleSmartBattery" : @"IOPMPowerSource";
    }
    out[@"service_name"] = serviceName;

    NSArray* publishedKeys = @[];
    NSMutableDictionary* keyPresent = [@{
        @"CurrentCapacity": @NO,
        @"Amperage": @NO,
        @"Voltage": @NO,
        @"IsCharging": @NO,
        @"Temperature": @NO,
    } mutableCopy];
    NSInteger iokitReturn = 0;
    NSInteger currentCapacity = 0;
    NSInteger amperage = 0;
    NSInteger instantAmperage = 0;

    if (serv == IO_OBJECT_NULL) {
        iokitReturn = -1;
    } else {
        CFMutableDictionaryRef props = nil;
        kern_return_t kr = IORegistryEntryCreateCFProperties(serv, &props, kCFAllocatorDefault, 0);
        iokitReturn = (NSInteger)kr;
        if (props == nil) {
            if (iokitReturn == 0) iokitReturn = -2;
        } else {
            NSDictionary* info = (__bridge_transfer NSDictionary*)props;
            publishedKeys = [[info allKeys] sortedArrayUsingSelector:@selector(compare:)];
            for (NSString* k in keyPresent.allKeys) {
                keyPresent[k] = @(info[k] != nil);
            }
            if ([info[@"CurrentCapacity"] respondsToSelector:@selector(integerValue)]) {
                currentCapacity = [info[@"CurrentCapacity"] integerValue];
            }
            if ([info[@"Amperage"] respondsToSelector:@selector(integerValue)]) {
                amperage = [info[@"Amperage"] integerValue];
            }
            if ([info[@"InstantAmperage"] respondsToSelector:@selector(integerValue)]) {
                instantAmperage = [info[@"InstantAmperage"] integerValue];
            }
        }
    }
    out[@"published_keys"] = publishedKeys;
    out[@"key_present"] = keyPresent;
    out[@"iokit_return"] = @(iokitReturn);
    out[@"current_capacity"] = @(currentCapacity);
    out[@"amperage"] = @(amperage);
    out[@"instant_amperage"] = @(instantAmperage);
    return out;
}

static int setInflowStatus(BOOL flag) {
    if (g_chargeControlProbeRunning) {
        return 0; // 探针期间忽略自动写
    }
    // iOS 17+: 禁流写到 AppleSmartBattery 的 FieldDiagsInflowInhibit/OBCInflowInhibit。
    // InflowOverride 是发布属性，不能当 setProperties key（会 BadArgument）。
    if (CLCanUseOverrideChargeControl()) {
        io_service_t overrideServ = CLCopyOverrideWriteService();
        if (overrideServ != IO_OBJECT_NULL) {
            kern_return_t ret = setInflowStatusOverride(overrideServ, flag);
            IOObjectRelease(overrideServ);
            if (ret == 0) {
                g_lastInflowCommandTs = time(0);
                return 0;
            }
            NSFileErrorLog(@"override inflow write failed ret=%d flag=%d, fallback to legacy ExternalConnected", ret, flag);
            appendPolicyEventHistory(@"charge_path_event",
                                     g_policyState ?: @"",
                                     g_policyState ?: @"",
                                     @"override_inflow_write_failed",
                                     bat_info,
                                     @{ @"inflow_flag": @(flag), @"io_return": @(ret) },
                                     time(0));
            // 落到下方旧 ExternalConnected 逻辑
        }
    }
    io_service_t serv = getIOPMPSServ();
    if (serv == IO_OBJECT_NULL) {
        return -1;
    }
    // iPhone>=8 ExternalConnected重置可消除120秒延迟,且更新系统充电图标
    NSMutableDictionary* props = [NSMutableDictionary new];
    props[@"ExternalConnected"] = @(flag);
    kern_return_t ret = IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props);
    if (ret != 0) {
        return -2;
    }
    g_lastInflowCommandTs = time(0);
    return 0;
}

static BOOL isAdaptorConnect(NSDictionary* info, NSNumber* disableInflow) { // 是否连接电源
    if (gUPSPS != nil) { // UPS电源
        // 使用SBC时ExternalConnected/ExternalChargeCapable一直为false
        return YES;
    }
    // 某些充电器ExternalConnected为false,而禁流时ExternalConnected/ExternalChargeCapable均为false
    // iOS 17 禁流改写 override key 后，ExternalConnected/ExternalChargeCapable 由系统间接派生，
    // 息屏周期性刷新会抖动，不能当插电判据。禁流态下统一走 AdapterDetails["Description"]：
    // 既覆盖用户开关 adv_disable_inflow=YES，也覆盖热控/停充触发的 temp_paused/no_inflow 禁流稳态。
    if (disableInflow.boolValue || isInflowGuardActive(NO, g_policyState)) { // 禁流模式下只能通过电源信息判断, 某些时候系统会缓存该信息导致不准确
        NSDictionary* AdapterDetails = info[@"AdapterDetails"];
        if (AdapterDetails == nil) {
            return NO;
        }
        NSString* PSDesc = AdapterDetails[@"Description"];
        if (PSDesc == nil || [PSDesc isEqualToString:@"batt"]) {
            return NO;
        }
        return YES;
    } else {
        NSNumber* ExternalChargeCapable = info[@"ExternalChargeCapable"];
        return ExternalChargeCapable.boolValue;
    }
}

static BOOL isAdaptorNewConnect(NSDictionary* oldInfo, NSDictionary* info, NSNumber* disableInflow) {
    // iOS 17 禁流稳态守卫：禁流态下 ExternalChargeCapable/ExternalConnected 派生值抖动会制造 false→true 伪边沿。
    // 只要当前或上一轮处于禁流态（用户开关或 policy 为 no_inflow/temp_paused），就抑制插电边沿；
    // 真正拔线由 AdapterDetails 消失检测，拔线后 policy 转出禁流态、守卫解除，后续真插电边沿正常产生。
    if (disableInflow.boolValue || isInflowGuardActive(NO, g_policyState)) {
        return NO;
    }
    return !isAdaptorConnect(oldInfo, disableInflow) && isAdaptorConnect(info, disableInflow);
}

static BOOL isAdaptorNewDisconnect(NSDictionary* oldInfo, NSDictionary* info, NSNumber* disableInflow) {
    return isAdaptorConnect(oldInfo, disableInflow) && !isAdaptorConnect(info, disableInflow);
}

static void clearPredictiveInhibitFallbackRuntimeState(void) {
    g_predictiveInhibitFallbackActive = NO;
}

static BOOL shouldUsePredictiveInhibitChargePath(void) {
    if (g_predictiveInhibitFallbackActive) {
        return NO;
    }
    return getLocalBool(@"adv_predictive_inhibit_charge", YES);
}

static kern_return_t writeChargeStatus(io_service_t serv, BOOL flag, BOOL usePredictiveInhibit) {
    NSMutableDictionary* props = [NSMutableDictionary new];
    if (usePredictiveInhibit) { // 目前测试PredictiveChargingInhibit在iOS>=13生效
        props[@"IsCharging"] = @YES;
        props[@"PredictiveChargingInhibit"] = @(!flag);
    } else { // 传统停充路径
        props[@"IsCharging"] = @(flag);
        props[@"PredictiveChargingInhibit"] = @NO; // PredictiveChargingInhibit为IsCharging总开关
    }
    return IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props);
}

// Charge control probe helpers (diagnostic-only; user-triggered)
static NSArray* CLProbeDefaultPaths(void) {
    return @[
        @"is_charging_only",
        @"legacy_is_charging",
        @"charging_override",
        @"predictive_inhibit_override",
        @"inflow_override",
        @"predictive_inhibit",
        @"external_connected_off",
    ];
}
static NSArray* CLProbeDefaultServices(void) {
    // auto = 读路径 service（AppleSmartBattery / IOPMPowerSource）。
    // 写面探针显式测 AppleSmartBattery（override setProperties 目标）与 Manager（对照）。
    return @[@"auto", @"AppleSmartBattery", @"AppleSmartBatteryManager", @"IOPMPowerSource"];
}

static NSString* CLProbeVerdictForResult(kern_return_t writeRet,
                                         BOOL propChanged,
                                         BOOL currentStopped,
                                         BOOL serviceMissing) {
    if (serviceMissing) {
        return @"service_missing";
    }
    if (writeRet != KERN_SUCCESS) {
        return @"write_rejected";
    }
    // iOS17: hardware may drop current / flip ChargingOverride bitmask without
    // flipping the classic IsCharging bool. Treat current stop as effective even
    // when classic prop_changed is false (deep probe 2026-08-02).
    if (currentStopped) {
        return @"effective";
    }
    if (propChanged && !currentStopped) {
        return @"prop_only";
    }
    return @"write_noop";
}

static BOOL CLProbePropChangedForPath(NSString* path,
                                      NSDictionary* before,
                                      NSDictionary* after) {
    NSDictionary* safeBefore = before ?: @{};
    NSDictionary* safeAfter = after ?: @{};
    if ([path isEqualToString:@"is_charging_only"] ||
        [path isEqualToString:@"legacy_is_charging"] ||
        [path isEqualToString:@"charging_override"]) {
        // iOS17: hardware may drop current / flip ChargingOverride bitmask while
        // classic IsCharging stays true. Count any of:
        //  - IsCharging true→false
        //  - PCI false→true
        //  - ChargingOverride integer change
        //  - current looks-charging → not
        BOOL afterCharging = [safeAfter[@"IsCharging"] boolValue];
        BOOL afterInhibit = [safeAfter[@"PredictiveChargingInhibit"] boolValue];
        BOOL beforeCharging = [safeBefore[@"IsCharging"] boolValue];
        BOOL beforeInhibit = [safeBefore[@"PredictiveChargingInhibit"] boolValue];
        if ((!afterCharging && beforeCharging) || (afterInhibit && !beforeInhibit)) {
            return YES;
        }
        id beforeCOObj = safeBefore[@"ChargingOverride"];
        id afterCOObj = safeAfter[@"ChargingOverride"];
        NSInteger beforeCO = 0;
        NSInteger afterCO = 0;
        if (beforeCOObj != nil && beforeCOObj != [NSNull null] &&
            [beforeCOObj respondsToSelector:@selector(integerValue)]) {
            beforeCO = [beforeCOObj integerValue];
        }
        if (afterCOObj != nil && afterCOObj != [NSNull null] &&
            [afterCOObj respondsToSelector:@selector(integerValue)]) {
            afterCO = [afterCOObj integerValue];
        }
        if (afterCO != beforeCO) {
            return YES;
        }
        int beforeCur = getEffectiveBatteryCurrent(safeBefore);
        int afterCur = getEffectiveBatteryCurrent(safeAfter);
        if (currentLooksCharging(beforeCur) && !currentLooksCharging(afterCur)) {
            return YES;
        }
        return NO;
    }
    if ([path isEqualToString:@"predictive_inhibit"] ||
        [path isEqualToString:@"predictive_inhibit_override"]) {
        if ([safeAfter[@"PredictiveChargingInhibit"] boolValue] &&
            ![safeBefore[@"PredictiveChargingInhibit"] boolValue]) {
            return YES;
        }
        id beforeCOObj = safeBefore[@"ChargingOverride"];
        id afterCOObj = safeAfter[@"ChargingOverride"];
        NSInteger beforeCO = 0;
        NSInteger afterCO = 0;
        if (beforeCOObj != nil && beforeCOObj != [NSNull null] &&
            [beforeCOObj respondsToSelector:@selector(integerValue)]) {
            beforeCO = [beforeCOObj integerValue];
        }
        if (afterCOObj != nil && afterCOObj != [NSNull null] &&
            [afterCOObj respondsToSelector:@selector(integerValue)]) {
            afterCO = [afterCOObj integerValue];
        }
        return afterCO != beforeCO;
    }
    if ([path isEqualToString:@"external_connected_off"]) {
        return ![safeAfter[@"ExternalConnected"] boolValue] &&
               [safeBefore[@"ExternalConnected"] boolValue];
    }
    if ([path isEqualToString:@"inflow_override"]) {
        int beforeCur = getEffectiveBatteryCurrent(safeBefore);
        int afterCur = getEffectiveBatteryCurrent(safeAfter);
        return currentLooksCharging(beforeCur) && !currentLooksCharging(afterCur);
    }
    return NO;
}

static NSDictionary* CLProbeSummarizeResults(NSArray* results, BOOL hasExternalPower) {
    BOOL anyEffective = NO;
    NSString* bestPath = nil;
    NSMutableDictionary* failCounts = [NSMutableDictionary dictionary];
    for (NSDictionary* item in results ?: @[]) {
        NSString* verdict = [item[@"verdict"] description] ?: @"write_noop";
        if ([verdict isEqualToString:@"effective"]) {
            anyEffective = YES;
            if (bestPath == nil) {
                NSString* service = [item[@"service"] description] ?: @"";
                NSString* path = [item[@"path"] description] ?: @"";
                bestPath = [NSString stringWithFormat:@"%@|%@", service, path];
            }
            continue;
        }
        NSNumber* count = failCounts[verdict] ?: @0;
        failCounts[verdict] = @(count.integerValue + 1);
    }
    NSString* dominantFailure = @"none";
    NSInteger bestCount = -1;
    for (NSString* key in failCounts) {
        NSInteger c = [failCounts[key] integerValue];
        if (c > bestCount) {
            bestCount = c;
            dominantFailure = key;
        }
    }
    NSMutableDictionary* summary = [@{
        @"any_effective": @(anyEffective),
        @"best_path": bestPath ?: [NSNull null],
        @"dominant_failure": dominantFailure,
    } mutableCopy];
    if (!hasExternalPower) {
        summary[@"power_note"] = @"no_external_power";
    }
    return summary;
}

static io_service_t CLProbeCopyServiceNamed(NSString* serviceName) {
    if ([serviceName isEqualToString:@"auto"]) {
        io_service_t serv = getIOPMPSServ();
        if (serv != IO_OBJECT_NULL) {
            // getIOPMPSServ 返回缓存对象，调用方不要 IOObjectRelease
            return serv;
        }
        return IO_OBJECT_NULL;
    }
    if (serviceName.length == 0) {
        return IO_OBJECT_NULL;
    }
    return IOServiceGetMatchingService(kIOMasterPortDefault,
                                       IOServiceMatching(serviceName.UTF8String));
}

static BOOL CLProbeServiceNeedsRelease(NSString* serviceName) {
    return ![serviceName isEqualToString:@"auto"];
}

static NSString* CLProbeResolvedServiceName(NSString* requested, io_service_t serv) {
    if (serv == IO_OBJECT_NULL) {
        return requested ?: @"";
    }
    if ([requested isEqualToString:@"auto"]) {
        // auto 永远解析为读路径实际 service（getIOPMPSServ 结果），不伪装成 Manager。
        return g_use_smart ? @"AppleSmartBattery" : @"IOPMPowerSource";
    }
    return requested ?: @"";
}

static NSDictionary* CLProbeSnapshotFromInfo(NSDictionary* info) {
    NSDictionary* safe = info ?: @{};
    return @{
        @"IsCharging": @([safe[@"IsCharging"] boolValue]),
        @"ChargingOverride": safe[@"ChargingOverride"] ?: [NSNull null],
        @"NotChargingReason": safe[@"NotChargingReason"] ?: [NSNull null],
        @"PredictiveChargingInhibit": @([safe[@"PredictiveChargingInhibit"] boolValue]),
        @"ExternalConnected": @([safe[@"ExternalConnected"] boolValue]),
        @"ExternalChargeCapable": @([safe[@"ExternalChargeCapable"] boolValue]),
        @"CurrentCapacity": @([safe[@"CurrentCapacity"] intValue]),
        @"InstantAmperage": @(getEffectiveBatteryCurrent(safe)),
        @"Amperage": @([safe[@"Amperage"] intValue]),
        @"AdapterDetails": safe[@"AdapterDetails"] ?: [NSNull null],
    };
}

static kern_return_t CLProbeWritePath(io_service_t serv, NSString* path, BOOL stop) {
    NSMutableDictionary* props = [NSMutableDictionary dictionary];
    if ([path isEqualToString:@"is_charging_only"]) {
        // Single-key write: only IsCharging. Isolates whether PCI co-write blocks effect.
        props[@"IsCharging"] = @(stop ? NO : YES);
    } else if ([path isEqualToString:@"legacy_is_charging"]) {
        props[@"IsCharging"] = @(stop ? NO : YES);
        props[@"PredictiveChargingInhibit"] = @NO;
    } else if ([path isEqualToString:@"predictive_inhibit"]) {
        props[@"IsCharging"] = @YES;
        props[@"PredictiveChargingInhibit"] = @(stop ? YES : NO);
    } else if ([path isEqualToString:@"external_connected_off"]) {
        props[@"ExternalConnected"] = @(stop ? NO : YES);
    } else if ([path isEqualToString:@"charging_override"]) {
        // iOS 17 可写停充：IsCharging + PredictiveChargingInhibit 极性相反。
        // stop=YES → IsCharging=NO, PCI=YES；stop=NO → IsCharging=YES, PCI=NO。
        // 不要写 ChargingOverride（发布属性，会 BadArgument）。
        props[@"IsCharging"] = @(stop ? NO : YES);
        props[@"PredictiveChargingInhibit"] = @(stop ? YES : NO);
    } else if ([path isEqualToString:@"predictive_inhibit_override"]) {
        // 单独写 PredictiveChargingInhibit（mode2），用于隔离变量。
        props[@"PredictiveChargingInhibit"] = @(stop ? YES : NO);
    } else if ([path isEqualToString:@"inflow_override"]) {
        // iOS 17 可写禁流：FieldDiagsInflowInhibit / OBCInflowInhibit。
        // stop=YES → inhibit YES；stop=NO → inhibit NO。
        NSNumber* inhibit = @(stop ? YES : NO);
        props[@"FieldDiagsInflowInhibit"] = inhibit;
        props[@"OBCInflowInhibit"] = inhibit;
    } else {
        return KERN_INVALID_ARGUMENT;
    }
    return IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props);
}

static NSDictionary* CLProbeRunOne(NSString* serviceName, NSString* path, NSInteger waitMs, BOOL restore) {
    NSString* requestedName = serviceName ?: @"";
    NSString* safePath = path ?: @"";
    io_service_t serv = CLProbeCopyServiceNamed(requestedName);
    NSString* resolvedName = CLProbeResolvedServiceName(requestedName, serv);
    BOOL needsRelease = CLProbeServiceNeedsRelease(requestedName);

    if (serv == IO_OBJECT_NULL) {
        NSDictionary* emptySnap = CLProbeSnapshotFromInfo(@{});
        return @{
            @"service": resolvedName,
            @"requested_service": requestedName,
            @"path": safePath,
            @"write_ret": @(KERN_FAILURE),
            @"before": emptySnap,
            @"after": emptySnap,
            @"restored": [NSNull null],
            @"prop_changed": @NO,
            @"current_stopped": @NO,
            @"verdict": @"service_missing",
        };
    }

    NSDictionary* beforeInfo = nil;
    getBatInfoWithServ(serv, &beforeInfo);
    NSDictionary* beforeSnap = CLProbeSnapshotFromInfo(beforeInfo);

    kern_return_t writeRet = CLProbeWritePath(serv, safePath, YES);
    if (waitMs > 0) {
        usleep((useconds_t)(waitMs * 1000));
    }

    NSDictionary* afterInfo = nil;
    getBatInfoWithServ(serv, &afterInfo);
    NSDictionary* afterSnap = CLProbeSnapshotFromInfo(afterInfo);

    id restoredSnap = [NSNull null];
    BOOL didRestore = NO;
    kern_return_t restoreRet = KERN_SUCCESS;
    if (restore) {
        didRestore = YES;
        restoreRet = CLProbeWritePath(serv, safePath, NO);
        // iOS17: also clear hardware inhibit bitmask if still set after path restore.
        // Deep probe saw ChargingOverride stick at 1/2/3 after stop writes.
        NSMutableDictionary* clearProps = [NSMutableDictionary dictionary];
        clearProps[@"IsCharging"] = @YES;
        clearProps[@"PredictiveChargingInhibit"] = @NO;
        kern_return_t clearRet = IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)clearProps);
        if (restoreRet == KERN_SUCCESS && clearRet != KERN_SUCCESS) {
            restoreRet = clearRet;
        }
        NSDictionary* restoredInfo = nil;
        getBatInfoWithServ(serv, &restoredInfo);
        restoredSnap = CLProbeSnapshotFromInfo(restoredInfo);
    }

    if (needsRelease && serv != IO_OBJECT_NULL) {
        IOObjectRelease(serv);
    }

    BOOL propChanged = CLProbePropChangedForPath(safePath, beforeSnap, afterSnap);
    int beforeCurrent = getEffectiveBatteryCurrent(beforeInfo ?: @{});
    int afterCurrent = getEffectiveBatteryCurrent(afterInfo ?: @{});
    BOOL beforeLooks = currentLooksCharging(beforeCurrent);
    BOOL afterLooks = currentLooksCharging(afterCurrent);
    BOOL currentStopped = NO;
    BOOL baselineNotCharging = NO;
    if (!beforeLooks) {
        // before 本就不像充电：不把 current_stopped 算作有效停充证据（需真实 transition）
        baselineNotCharging = YES;
        currentStopped = NO;
    } else {
        currentStopped = !afterLooks && beforeLooks;
    }

    NSString* verdict = CLProbeVerdictForResult(writeRet, propChanged, currentStopped, NO);
    // Only mask with restore_failed when STOP write itself succeeded.
    // If stop write already failed, keep write_rejected (or other stop verdict).
    if (didRestore && writeRet == KERN_SUCCESS && restoreRet != KERN_SUCCESS) {
        verdict = @"restore_failed";
    }

    NSMutableDictionary* result = [@{
        @"service": resolvedName,
        @"requested_service": requestedName,
        @"path": safePath,
        @"write_ret": @(writeRet),
        @"before": beforeSnap,
        @"after": afterSnap,
        @"restored": restoredSnap,
        @"prop_changed": @(propChanged),
        @"current_stopped": @(currentStopped),
        @"before_current": @(beforeCurrent),
        @"after_current": @(afterCurrent),
        @"verdict": verdict,
    } mutableCopy];
    if (didRestore) {
        result[@"restore_ret"] = @(restoreRet);
    }
    if (baselineNotCharging) {
        result[@"current_baseline_not_charging"] = @YES;
    }
    return result;
}

static void markPredictiveInhibitFallbackActive(NSString* reason, NSDictionary* info, NSDictionary* extras, time_t now) {
    if (g_predictiveInhibitFallbackActive) {
        return;
    }
    g_predictiveInhibitFallbackActive = YES;
    appendPolicyEventHistory(@"charge_path_event",
                             g_policyState ?: @"",
                             g_policyState ?: @"",
                             reason ?: @"predictive_inhibit_fallback",
                             info ?: bat_info,
                             extras,
                             now > 0 ? now : time(0));
}

static BOOL shouldFallbackFromPredictiveInhibitStop(BOOL isAdaptorConnected,
                                                    BOOL isCharging,
                                                    BOOL currentLooksCharging,
                                                    BOOL predictiveInhibitActive,
                                                    time_t now) {
    if (!shouldUsePredictiveInhibitChargePath()) {
        return NO;
    }
    if (g_chargeCommandEnabled || !isAdaptorConnected || predictiveInhibitActive) {
        return NO;
    }
    if (!(isCharging || currentLooksCharging) || g_lastChargeCommandTs <= 0) {
        return NO;
    }
    return (now - g_lastChargeCommandTs) >= kPredictiveInhibitFallbackVerifyDelaySeconds;
}

static uint64_t g_chargeEnableVerifyGeneration = 0;

// 限流模式下电流被压制，验证阈值联动 thermal mode 降档。
static int chargeEnableThresholdForCurrentThermalMode(void) {
    NSString* mode = getLocalString(@"adv_limit_inflow_mode", @"moderate");
    BOOL limitActive = getLocalBool(@"adv_limit_inflow", NO) &&
                       !getLocalBool(@"adv_thermal_mode_lock", NO);
    if (limitActive && ([mode isEqualToString:@"moderate"] || [mode isEqualToString:@"heavy"])) {
        return 30;
    }
    return kHoldCurrentChargeThresholdmA;
}

// iOS17 restore 后 ChargingOverride 位图可能仍粘 inhibit（真机 2026-08-02），
// 命令层成功但硬件未恢复充电 → "已连接电源·未充电"。写后验证 + 一次重写 +
// legacy 回退，对称复用停充侧 shouldFallbackFromPredictiveInhibitStop 骨架。
static void scheduleChargeEnableVerification(void) {
    uint64_t gen = ++g_chargeEnableVerifyGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kPredictiveInhibitFallbackVerifyDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        if (gen != g_chargeEnableVerifyGeneration || !g_chargeCommandEnabled) {
            return; // 已被后续命令取代或已再次停充
        }
        NSDictionary* snapshot = nil;
        if (0 != getBatInfo(&snapshot)) {
            return;
        }
        NSDictionary* safe = snapshot ?: @{};
        int current = getEffectiveBatteryCurrent(safe);
        if (current >= chargeEnableThresholdForCurrentThermalMode()) {
            return; // 已恢复充电
        }
        // 未恢复：重写一次 override restore
        io_service_t serv = CLCopyOverrideWriteService();
        if (serv != IO_OBJECT_NULL) {
            writeChargeStatusOverride(serv, NO);
            IOObjectRelease(serv);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                       dispatch_get_global_queue(0, 0), ^{
            if (gen != g_chargeEnableVerifyGeneration || !g_chargeCommandEnabled) {
                return;
            }
            NSDictionary* recheck = nil;
            if (0 != getBatInfo(&recheck)) {
                return;
            }
            NSDictionary* safeRe = recheck ?: @{};
            int reCurrent = getEffectiveBatteryCurrent(safeRe);
            if (reCurrent >= chargeEnableThresholdForCurrentThermalMode()) {
                return;
            }
            // 重写仍无效：legacy 直写 + 事件记录
            kern_return_t legacyRet = KERN_FAILURE;
            io_service_t legacyServ = CLCopyOverrideWriteService();
            if (legacyServ != IO_OBJECT_NULL) {
                NSMutableDictionary* props = [NSMutableDictionary dictionary];
                props[@"IsCharging"] = @YES;
                props[@"PredictiveChargingInhibit"] = @NO;
                legacyRet = IORegistryEntrySetCFProperties(legacyServ, (__bridge CFTypeRef)props);
                IOObjectRelease(legacyServ);
            }
            NSDictionary* extras = @{
                @"charging_override": safeRe[@"ChargingOverride"] ?: @"nil",
                @"not_charging_reason": safeRe[@"NotChargingReason"] ?: @"nil",
                @"instant_amperage": @(reCurrent),
                @"legacy_io_return": @(legacyRet),
            };
            NSFileErrorLog(@"charge enable unconfirmed after rewrite, legacy fallback ret=%d", legacyRet);
            appendPolicyEventHistory(@"charge_path_event",
                                     g_policyState ?: @"",
                                     g_policyState ?: @"",
                                     @"charge_enable_unconfirmed",
                                     safeRe, extras, time(0));
        });
    });
}

static int setChargeStatus(BOOL flag) {
    if (g_chargeControlProbeRunning) {
        return 0; // 探针期间忽略自动/手动写
    }
    BOOL wasEnabled = g_chargeCommandEnabled;
    // iOS 17+: 写到 AppleSmartBattery 的 IsCharging+PredictiveChargingInhibit（极性相反）。
    // ChargingOverride 是发布属性，不能当 setProperties key（真机 BadArgument）。
    // Manager setProperties 返回 kIOReturnUnsupported。
    if (CLCanUseOverrideChargeControl()) {
        io_service_t overrideServ = CLCopyOverrideWriteService();
        if (overrideServ != IO_OBJECT_NULL) {
            // flag = charge-enabled; override helper takes stop = !chargeEnabled
            kern_return_t ret = writeChargeStatusOverride(overrideServ, !flag);
            IOObjectRelease(overrideServ);
            if (ret == 0) {
                g_chargeCommandEnabled = flag;
                g_lastChargeCommandTs = time(0);
                if (!wasEnabled && flag) {
                    scheduleChargeEnableVerification();
                }
                return 0;
            }
            // override 写失败：记事件后回退旧逻辑，不直接失败。
            NSDictionary* extras = @{
                @"charge_flag": @(flag),
                @"fallback_reason": @"override_write_failed",
                @"io_return": @(ret),
            };
            NSFileErrorLog(@"override charge write failed ret=%d flag=%d, fallback to legacy path", ret, flag);
            appendPolicyEventHistory(@"charge_path_event",
                                     g_policyState ?: @"",
                                     g_policyState ?: @"",
                                     @"override_charge_write_failed",
                                     bat_info, extras, time(0));
            // 落到下方旧逻辑
        }
    }
    io_service_t serv = getIOPMPSServ();
    if (serv == IO_OBJECT_NULL) {
        return -1;
    }
    BOOL usePredictiveInhibit = shouldUsePredictiveInhibitChargePath();
    kern_return_t ret = writeChargeStatus(serv, flag, usePredictiveInhibit);
    if (ret != 0 && usePredictiveInhibit) {
        time_t now = time(0);
        NSDictionary* extras = @{
            @"charge_flag": @(flag),
            @"fallback_reason": @"write_failed",
            @"io_return": @(ret),
        };
        NSFileErrorLog(@"predictive inhibit write failed ret=%d flag=%d, fallback to legacy stop path", ret, flag);
        markPredictiveInhibitFallbackActive(@"predictive_inhibit_write_failed", bat_info, extras, now);
        ret = writeChargeStatus(serv, flag, NO);
    }
    if (ret != 0) {
        return -2;
    }
    g_chargeCommandEnabled = flag;
    g_lastChargeCommandTs = time(0);
    return 0;
}


// 集中决策：thermal mode 只由命令和配置决定，不读系统实时信号。
// lock=YES → 默认档；charging+limit=YES → 限流档；其他 → 默认档。
static NSString* targetThermalModeForCurrentState(void) {
    BOOL lock = getLocalBool(@"adv_thermal_mode_lock", NO);
    NSString* defaultMode = getLocalString(@"adv_def_thermal_mode", @"off");
    if (lock) {
        return defaultMode;
    }
    BOOL limitInflow = getLocalBool(@"adv_limit_inflow", NO);
    if (g_chargeCommandEnabled && limitInflow) {
        return getLocalString(@"adv_limit_inflow_mode", @"moderate");
    }
    return defaultMode;
}

static void applyThermalModeForCurrentState(void) {
    setThermalSimulationMode(targetThermalModeForCurrentState());
}

static int setBatteryStatus(BOOL flag) {
    if (g_chargeControlProbeRunning) {
        return 0; // 探针期间忽略自动写
    }
    int ret = setChargeStatus(flag);
    applyThermalModeForCurrentState();
    return ret;
}

static void resetBatteryStatus() {
    resetBatteryStatusWithContext(NO, @"legacy_reset");
}

static BOOL shouldRestorePermanentSmartChargeDisableForResetReason(NSString* reason) {
    return [@[
        @"app_uninstall",
        @"bundle_missing",
        @"cli_reset",
        @"cli_reset_and_exit_fallback",
        @"daemon_reset_and_exit"
    ] containsObject:reason ?: @""];
}

// iOS 17+ MCL（Manual Charge Limit）联动：设置"充电优化"三选项 = OBC + MCL 组合
// （固件逆向 iPhone16,2 17.1：仅关 OBC 时设置 UI 仍显示开启，80% 限制也不受影响）。
// 永久停用前把 MCL 原状态记入本地配置，还原/自愈时恢复，避免把用户原选的
// "80% 限制"静默改成"优化电池充电"。旧系统 MCL 不受支持，全部为无效操作。
static NSString* const kSmartChargeMCLStateBeforeDisableKey = @"smart_charge_mcl_state_before_disable";

static void rememberMCLStateBeforeDisable(void) {
    if (!isSmartChargeMCLSupported()) {
        return;
    }
    setLocalBool(kSmartChargeMCLStateBeforeDisableKey, getSmartChargeMCLEnabled());
}

// 官方「关→开」重置序列：等价于用户在系统设置里把 80% 上限关一次再开一次——
// disableMCL 清 token 并取消 powerd 侧限制（固件 0x20237a41c clearChargeLimit），
// enableMCL 清临时停用窗口（setTemporarilyDisabled(0,0)）、重写 MCLFeatureState 并
// 重新 engage 80。必须绕过 setSmartChargeMCLEnabled 的读回短路：执行层残留坏状态
// 的设备读回值与目标相同，短路会把还原变成空操作（v1.16.1 语义对修复场景不适用）。
static void MCLResetViaOfficialToggle(BOOL endStateOn) {
    CLMCLForceDisable();
    if (endStateOn) {
        CLMCLForceEnable();
    }
}

static void restoreMCLStateAfterEnable(void) {
    if (!isSmartChargeMCLSupported()) {
        return;
    }
    // 记忆键不存在 = 当前版本的 CL 从未执行过永久停用。两种情形：
    // a) 旧版（未适配 iOS 17）执行过停用且未还原就卸载——旧版不写记忆键，
    //    MCL 执行层残留坏状态（token 被取消/临时停用窗口），单纯 enable 修不动；
    // b) 用户从未动过 MCL，或自己在系统设置里关着。
    // 处置：代理读回开 → 走官方关→开重置（终态不变，仅重建执行层）；读回关 → 尊重现状。
    if (getlocalKV(kSmartChargeMCLStateBeforeDisableKey) == nil) {
        if (getSmartChargeMCLEnabled()) {
            MCLResetViaOfficialToggle(YES);
        }
        return;
    }
    // 记忆键存在：恢复永久停用前的用户选择。开 = 关→开全量重置（token/临时停用/
    // engage 全部重建），关 = 仅关。
    MCLResetViaOfficialToggle(getLocalBool(kSmartChargeMCLStateBeforeDisableKey, NO));
}

static void disableMCLForPermanentDisable(void) {
    if (!isSmartChargeMCLSupported()) {
        return;
    }
    if (!setSmartChargeMCLEnabled(NO)) {
        NSFileErrorLog(@"MCL disable failed");
    }
}

/* ---------------- iOS 17+ MCL 诊断编排（Design Doc 3.3） ---------------- */

// 层3 证据候选键（re-notes.md 注册表稳定键实验定案；实验未找到稳定键时保持空数组，
// 证据等级如实退化为 indirect——实验失败是预期内结果，不是缺陷）。
static NSArray<NSString*>* MCLRegistryEvidenceCandidateKeys(void) {
    static NSArray<NSString*>* keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 按 re-notes.md §注册表稳定键实验 结论填写；无稳定键则保持空数组
        keys = @[];
    });
    return keys;
}

// 层3 单键查询（get_bat_info 高频路径用：只查候选键，不做全量 dump）。
static NSMutableDictionary* MCLRegistryProbeEvidenceKeys(void) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    NSArray<NSString*>* candidates = MCLRegistryEvidenceCandidateKeys();
    if (candidates.count == 0) {
        return out;
    }
    io_service_t serv = getIOPMPSServ();
    if (serv == IO_OBJECT_NULL) {
        return out;
    }
    for (NSString* key in candidates) {
        CFTypeRef raw = IORegistryEntrySearchCFProperty(serv, kIOServicePlane,
                                                        (__bridge CFStringRef)key,
                                                        kCFAllocatorDefault, 0);
        NSMutableDictionary* item = [NSMutableDictionary dictionary];
        item[@"present"] = @(raw != NULL);
        if (raw != NULL) {
            item[@"value"] = CFBridgingRelease(raw);
        }
        out[key] = item;
    }
    return out;
}

// 层3 全量数值属性快照（repair 前后 diff 用，Task 5 消费）。
static NSDictionary* MCLSnapshotRegistryNumericProps(void) {
    io_service_t serv = getIOPMPSServ();
    if (serv == IO_OBJECT_NULL) {
        return @{};
    }
    CFMutableDictionaryRef props = nil;
    kern_return_t kr = IORegistryEntryCreateCFProperties(serv, &props, kCFAllocatorDefault, 0);
    if (kr != 0 || props == nil) {
        return @{};
    }
    NSDictionary* info = (__bridge_transfer NSDictionary*)props;
    NSMutableDictionary* numeric = [NSMutableDictionary dictionary];
    for (NSString* key in info) {
        if ([info[key] isKindOfClass:[NSNumber class]]) {
            numeric[key] = info[key];
        }
    }
    return numeric;
}

// 前后 diff：limit/override 相关整型变化键（Design Doc 3.3-1 候选模式，Task 5 消费）。
static NSDictionary* MCLDiffRegistryProps(NSDictionary* before, NSDictionary* after) {
    NSMutableDictionary* changed = [NSMutableDictionary dictionary];
    NSMutableDictionary* limitRelated = [NSMutableDictionary dictionary];
    for (NSString* key in after) {
        NSNumber* beforeValue = before[key];
        NSNumber* afterValue = after[key];
        if (beforeValue == nil || afterValue == nil || [beforeValue isEqualToNumber:afterValue]) {
            continue;
        }
        changed[key] = @{@"before": beforeValue, @"after": afterValue};
        NSString* lower = key.lowercaseString;
        if ([lower containsString:@"limit"] || [lower containsString:@"override"]) {
            limitRelated[key] = changed[key];
        }
    }
    return @{@"changed": changed, @"limit_related": limitRelated};
}

// 活通道优先合并（v1.17.1 修复轮 2 修订冲突规则）：磁盘直读对 cfprefsd 缓冲态全盲
// （plist 可能长期不落盘甚至从不存在），磁盘 Missing/ReadFailed 的键以活通道值为准；
// 磁盘可读时磁盘优先（持久层真相）。唯一例外：MCLFeatureState 双通道同时 Found 且
// 磁盘=false / live=true 的值冲突——磁盘 plist 是 cfprefsd 异步落盘副本，新鲜度恒 ≤
// cfprefsd，该组合只能是服务端刚写、磁盘滞后，此键 live 优先；其余五键维持磁盘优先。
// 健康设备（disk=false/live=false）无冲突，零副作用。返回合并视图供判定，报告层1
// 原样保留磁盘真值 + live 子字典；*effectiveChannel 输出 MCLFeatureState 判定生效
// 通道：conflict_live_wins=双通道值冲突 live 优先、disk=磁盘可读、live=活通道补盲、
// none=双通道均未证实。
static NSDictionary* MCLLiveFirstLayer1(NSDictionary* layer1, NSString** effectiveChannel) {
    NSDictionary* states = layer1[@"states"] ?: @{};
    NSDictionary* values = layer1[@"values"] ?: @{};
    NSDictionary* live = [layer1[@"live"] isKindOfClass:[NSDictionary class]] ? layer1[@"live"] : @{};
    NSDictionary* liveStates = [live[@"states"] isKindOfClass:[NSDictionary class]] ? live[@"states"] : @{};
    NSDictionary* liveValues = [live[@"values"] isKindOfClass:[NSDictionary class]] ? live[@"values"] : @{};
    NSMutableDictionary* mergedValues = [NSMutableDictionary dictionary];
    NSMutableDictionary* mergedStates = [NSMutableDictionary dictionary];
    BOOL featureDisk = NO;
    BOOL featureLive = NO;
    BOOL featureConflictLiveWins = NO;
    for (NSString* key in CLMCLPrefKeys()) {
        int diskState = [states[key] intValue];
        int liveState = [liveStates[key] intValue];
        // 值冲突仅限 MCLFeatureState 一键：磁盘 Found 且为 false、live Found 且为 true
        // （磁盘滞后 + live true 只能是服务端刚写，cfprefsd 新鲜度恒 ≥ 磁盘副本）。
        BOOL featureConflict = [key isEqualToString:@"MCLFeatureState"]
            && diskState == CLMCLPrefFound && liveState == CLMCLPrefFound
            && values[key] != nil && liveValues[key] != nil
            && ![values[key] boolValue] && [liveValues[key] boolValue];
        if (diskState == CLMCLPrefFound && !featureConflict) {
            id value = values[key];
            if (value != nil) {
                mergedValues[key] = value;
            }
            mergedStates[key] = @(CLMCLPrefFound);
            if ([key isEqualToString:@"MCLFeatureState"]) {
                featureDisk = YES;
            }
        } else if (liveState == CLMCLPrefFound) {
            id value = liveValues[key];
            if (value != nil) {
                mergedValues[key] = value;
            }
            mergedStates[key] = @(CLMCLPrefFound);
            if ([key isEqualToString:@"MCLFeatureState"]) {
                featureLive = YES;
                if (featureConflict) {
                    featureConflictLiveWins = YES;
                }
            }
        } else {
            // 双通道均未证实：保留磁盘 Missing/ReadFailed 原状（判定走既有歧义行）
            mergedStates[key] = @(diskState);
        }
    }
    if (effectiveChannel != NULL) {
        if (featureConflictLiveWins) {
            *effectiveChannel = @"conflict_live_wins";
        } else if (featureDisk) {
            *effectiveChannel = @"disk";
        } else if (featureLive) {
            *effectiveChannel = @"live";
        } else {
            *effectiveChannel = @"none";
        }
    }
    return @{@"domain": layer1[@"domain"] ?: @"unresolved",
             @"plist_path": layer1[@"plist_path"] ?: @"",
             @"values": mergedValues,
             @"states": mergedStates};
}

// 派生判定（Design Doc 3.3 判定矩阵 v1；歧义行按 Global Constraints 的 V1–V3 优先级定案）。
// read_failed 的 MCLFeatureState 视同 missing 走 V3：报告原样携带 states 供人工判读。
// v1.17.1：入参 layer1 为活通道优先合并视图（collect 阶段合成），判定矩阵与枚举不变——
// 合并视图 missing = 双通道均无法证实，pref_lost 仅在该情形给出。
static NSString* MCLVerdictFromDiagnostics(BOOL mclSupported, NSDictionary* layer1, BOOL agentEnabled, NSDictionary* layer3) {
    if (!mclSupported) {
        return @"unsupported";
    }
    NSDictionary* states = layer1[@"states"] ?: @{};
    NSDictionary* values = layer1[@"values"] ?: @{};
    int featureState = [states[@"MCLFeatureState"] intValue];
    BOOL registryDiff = [layer3[@"evidence_grade"] isEqualToString:@"registry_diff"];
    BOOL layer3Present = [layer3[@"present"] boolValue];
    if (featureState == CLMCLPrefFound) {
        if ([values[@"MCLFeatureState"] boolValue]) {
            if (!agentEnabled) {
                return @"disconnected";          // 行3：agent 未载入/读回关闭（层1↔层2 脱节）
            }
            // 行1/行2 的执行层判据：物理电流证据优先于注册表候选键（本轮候选键实验为空，
            // 永远拿不到 registry_diff；而物理采样只要插电 + 电量到上限就可获得）。
            // conclusive=YES 且 physically_limited=NO = 插着电、电量已 >=80%、电流却 >=120mA
            // ——限制并未生效，层1/层2 双绿只是代理内存与偏好一致，与执行层无关。这正是
            // 固件逆向定案的「engage 时快照 101 / clearChargeLimit 取消 powerd」后果：
            // 三层全绿而实际充过头，必须判 disconnected 而不是 healthy_enabled。
            if ([layer3[@"evidence_grade"] isEqualToString:@"physical_current"]
                && [layer3[@"conclusive"] boolValue]
                && [layer3[@"physically_limited"] isKindOfClass:[NSNumber class]]
                && ![layer3[@"physically_limited"] boolValue]) {
                return @"disconnected";          // 行2 物理通道版：执行层未在限制
            }
            if (registryDiff && !layer3Present) {
                return @"disconnected";          // 行2：层1/层2 开但执行层证据缺失
            }
            return @"healthy_enabled";           // 行1 + indirect 退化（报告标注证据等级）
        }
        if (!agentEnabled) {
            return @"healthy_disabled";          // 行5：显式 false + 读回 NO
        }
        if (registryDiff && layer3Present) {
            return @"disconnected";              // 反向脱节：执行层在限制但偏好关
        }
        return @"pref_lost";                     // 行4 false 分支（indirect 层3 缺失）
    }
    if (registryDiff && layer3Present) {
        return @"disconnected";
    }
    return @"pref_lost";                         // 行4 missing 分支
}

/* ---------------- iOS 17+ MCL 执行层物理证据（固件逆向 iPhone16,2 17.1 21B80） ---------------- */

// 固件逆向定案（PowerUI/PowerUISmartChargeManager，见 re-notes）：
//   1. engageManualChargeLimit 只在 engage 那一刻快照 mclTargetSoC=80 或 101，
//      之后系统侧没有任何路径会重新 evaluate（handleNewBatteryLevelForMCL 只改 checkpoint，
//      不重新下发 IOPSLimitBatteryLevel）。一旦落在 101（=不限制），限制就是静默失效。
//   2. 101 的三个来源全部来自 PowerUIBatteryMitigationManager.additionalWaitTime：
//      - additionalWaitTimeForQMaxWithInterval:  距上次 QMax 变更 >= 1209600s(14天)，
//        且需 dod0AtLastQualQmax > 50000 且距 lastQualifiedQmaxDate >= 108000s(30h)
//      - additionalWaitTimeForDOD0WithInterval:  距上次 DOD0 变更 >= 259200s(3天)
//      - additionalWaitTimeWithProperties:       距 lastFullChargeDate > 1814400s(21天)
//      任一 >= maxAdditionalWaitTimeForQMax(常量 99999.0) 即中和为 101。注意末项是
//      **整体覆写**为 99999.0（不是相加）：additionalWaitTimeWithProperties 在越过 21 天
//      线时直接把等待时间改成 99999.0，覆盖前两项的返回。
//   3. clearChargeLimit 会调 IOPSLimitBatteryLevelCancel() 取消 powerd 侧 ChargeLimit。
//      反汇编确认调用场合为 handleCallback 的**拔电沿**（externalConnected==NO 且
//      lastPluginStatus!=externalConnected，0x20237173c 尾段）；handleCallback 里出现
//      checkpoint ∈ {5,6} 的另一处判定只决定是否进入主处理体，并非 clearChargeLimit
//      的调用条件——不得据此声称「电量跌出 checkpoint 会取消限制」。
//   4. isMCLCurrentlyEnabled 只读代理内存标志 _manualChargeLimitEnabled——「读回 YES」与
//      powerd 里是否有生效限制完全无关。这正是 v1.17.x 判定矩阵把受损设备误判为
//      healthy_enabled 的根因：三层全绿而执行层早已不见。
//   5. engage 失败不会回传：enableMCL 无条件置内存标志、写 MCLFeatureState、尾调 engage，
//      engage 的四个静默分支（gate1/gate2/QMax 中和/token==0）都不影响返回值。
//      因此「调用成功」同样不等于「限制在生效」。
//   6. chargeLimitToken 由 engage 自愈：loadChargeLimitToken 在偏好键缺失（clearChargeLimit
//      写 nil 即移除键）时自行创建新 token 并回写。所以客户端**不需要、也不应该** gate
//      在 token 上——前置检查只会挡住唯一能自愈的这次 engage。
//   7. mclTargetSoC 这个偏好键 PowerUI 从不写：engageManualChargeLimit 只赋 ivar，
//      setMclTargetSoC: 是纯 ivar setter 且无调用者。CLMCLPrefKeys 保留该键只为白名单
//      完整性，**不得**据此判定「上限值被中和」——域内恒缺失。
//
// 因此执行层证据不能只看注册表候选键（本轮实验仍未找到稳定键，MCLLayer3EvidenceCandidateKeys
// 为空），必须补一条不依赖猜键的物理通道：插电 + SoC 已到上限 + 电池仍在被供能时，
// 实际电流应已被压低。第一阶段已把「电流跨 120mA」定为 effective 的判据（停充控制面），
// 同一物理量在这里就是 80% 限制是否真的生效的唯一硬证据。
static const NSInteger kMCLExecutionAmperageThresholdMA = 120;
// SoC 达到上限后电流才应被限制。取 80 与 MCL 默认上限对齐：80% 是电量被钳住后的稳态值，
// 而 79→80 的过渡窗口内电流可能仍高（限制刚生效）。取 80 可把过渡窗口排除在「未限制」
// 判定之外；维持器另外要求连续两次采样一致，进一步压低误触发。
static const NSInteger kMCLExecutionTriggerSoC = 80;
// 观测窗口上沿：>95% 时电量已冲过上限或处于满充保持，低电流判不出 MCL 好坏
// （满电自然停充电流同样 <120mA），不得作为「限制生效」证据。
static const NSInteger kMCLExecutionWindowSoCMax = 95;

// 官方临时停用窗口证据（第五阶段逆向定案，固件 0x20236f898 / 0x20236f70c / 0x20237c400）：
// PowerUISmartChargeManager 的 setTemporarilyDisabled:until:（0x20236f898）把 disabledUntil
// （double，timeIntervalSinceReferenceDate）写进 com.apple.smartcharging.topoffprotection 域，
// until 由 defaultDateToDisableUntilGivenDate:（0x20236f70c）算成「下一个早上 6:00」。
// 设置来源只有 client:setState:withHandler:（0x20237c400）case 2/3（= 客户端 API
// temporarilyEnableCharging / temporarilyDisableSmartCharging，通知「立即充电」按钮走 case 2，
// 日志 "User requested immediate charge."）、initWithDefaults 恢复、以及清除路径。窗口 active
// 期间 MCL 限制完全不执行（setCurrentState 2/3 + setCheckpoint 9/11 + 时间线 TemporarilyDisabled
// 事件）；窗口结束（明早 6:00 dispatch_after）或之后首个插件沿 handleCallback 会自愈重新 engage。
// 因此「80% 到点却照常充电」不一定是执行层失效，可能是系统自己的临时窗口——维持器不得对抗。
// 只读 plist（与 CLMCLReadPrefs 同一路径），无 XPC、无子进程；键不在 F7 六键白名单内，
// 仅作只读诊断，不写入。
static NSDictionary* MCLTemporaryWindowEvidence(void) {
    NSMutableDictionary* ev = [NSMutableDictionary dictionary];
    ev[@"present"] = @NO;
    ev[@"active"] = @NO;
    NSString* path = @"/var/mobile/Library/Preferences/com.apple.smartcharging.topoffprotection.plist";
    NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (dict == nil) {
        ev[@"note"] = @"domain_plist_unreadable";
        return ev;
    }
    id value = dict[@"disabledUntil"];
    double refInterval = 0;
    if ([value isKindOfClass:[NSNumber class]]) {
        refInterval = [value doubleValue];
    } else if ([value isKindOfClass:[NSDate class]]) {
        refInterval = [value timeIntervalSinceReferenceDate];
    } else {
        ev[@"note"] = @"disabled_until_absent";
        return ev;
    }
    if (refInterval <= 0.0) {
        // 固件清除路径写 0/删键；<=0 视为无窗口。
        ev[@"note"] = @"disabled_until_zero";
        return ev;
    }
    ev[@"present"] = @YES;
    ev[@"disabled_until_ts"] = @(refInterval + 978307200);   // Apple epoch → Unix epoch
    time_t now = time(0);
    ev[@"active"] = @((refInterval + 978307200.0) > (double)now);
    ev[@"remaining_s"] = @(MAX(0, (time_t)(refInterval + 978307200.0) - now));
    return ev;
}

// 电池计量中和门（engage_neutralize gate）。固件定案（0x202350354 / 0x2023506B0 /
// 0x202350E24，第五轮真机回灌定案为 80% 不限流主因）：engageManualChargeLimit 那一刻
// PowerUIBatteryMitigationManager.additionalWaitTime 任一命中即把限制值中和为 101
// （= 不限制），日志原话 "charge to full" / "feature is disengaged"。三条判据全部
// 只读 topoffprotection 域时间戳即可完全复算，无需 log stream：
//   DOD0   距上次更新 >= 259200s（3 天）→ 中和（真机 2026-09-28：38.5 天，主因）
//   QMax   距上次更新 >= 1209600s（14 天）且 lastQualQmaxDODValue > 50000
//          且距 lastQualQmaxDate >= 108000s（30h）→ 中和
//   满充   距上次满充 > 1814400s（21 天）→ 覆写中和
// 中和后充满一次即可刷新 DOD0/QMax/满充时间，下一次 engage 恢复 80。
static NSDictionary* MCLMitigationGateEvidence(void) {
    NSMutableDictionary* ev = [NSMutableDictionary dictionary];
    ev[@"will_neutralize"] = @NO;
    ev[@"reasons"] = [NSNull null];
    NSString* path = @"/var/mobile/Library/Preferences/com.apple.smartcharging.topoffprotection.plist";
    NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (dict == nil) {
        ev[@"note"] = @"domain_plist_unreadable";
        return ev;
    }
    double nowApple = [NSDate date].timeIntervalSinceReferenceDate;
    NSMutableArray* reasons = [NSMutableArray array];
    NSNumber* dod0Ts = [dict[@"lastDOD0Update"] isKindOfClass:[NSNumber class]] ? dict[@"lastDOD0Update"] : nil;
    if (dod0Ts != nil) {
        double interval = nowApple - dod0Ts.doubleValue;
        ev[@"dod0_age_days"] = @(interval / 86400.0);
        if (interval >= 259200.0) {
            [reasons addObject:@{ @"gate": @"dod0_stale",
                                  @"age_days": @(interval / 86400.0),
                                  @"threshold_days": @3 }];
        }
    }
    NSNumber* qmaxTs = [dict[@"lastQMaxUpdate"] isKindOfClass:[NSNumber class]] ? dict[@"lastQMaxUpdate"] : nil;
    NSNumber* qualQmaxDOD = [dict[@"lastQualQmaxDODValue"] isKindOfClass:[NSNumber class]] ? dict[@"lastQualQmaxDODValue"] : nil;
    NSNumber* qualQmaxTs = [dict[@"lastQualQmaxDate"] isKindOfClass:[NSNumber class]] ? dict[@"lastQualQmaxDate"] : nil;
    if (qmaxTs != nil) {
        double interval = nowApple - qmaxTs.doubleValue;
        ev[@"qmax_age_days"] = @(interval / 86400.0);
        BOOL dodBig = qualQmaxDOD != nil && qualQmaxDOD.doubleValue > 50000.0;
        BOOL qualAged = qualQmaxTs == nil || (nowApple - qualQmaxTs.doubleValue) >= 108000.0;
        if (interval >= 1209600.0 && dodBig && qualAged) {
            [reasons addObject:@{ @"gate": @"qmax_stale",
                                  @"age_days": @(interval / 86400.0),
                                  @"threshold_days": @14 }];
        }
    }
    NSNumber* fullTs = [dict[@"lastFullChargeDate"] isKindOfClass:[NSNumber class]] ? dict[@"lastFullChargeDate"] : nil;
    if (fullTs != nil) {
        double interval = nowApple - fullTs.doubleValue;
        ev[@"full_charge_age_days"] = @(interval / 86400.0);
        if (interval > 1814400.0) {
            [reasons addObject:@{ @"gate": @"full_charge_stale",
                                  @"age_days": @(interval / 86400.0),
                                  @"threshold_days": @21 }];
        }
    }
    ev[@"reasons"] = reasons;
    ev[@"will_neutralize"] = @(reasons.count > 0);
    return ev;
}

// 物理执行层证据采样。一次 getBatInfo 调用，无额外 IO、无子进程——get_bat_info 1Hz
// 轮询路径可承受。conclusive=NO 时不得据此下任何结论（未插电 / 电量未到上限 /
// 采样失败都无法区分「限制生效」与「本来就不需要限制」）。
static NSDictionary* MCLPhysicalExecutionEvidence(void) {
    NSMutableDictionary* ev = [NSMutableDictionary dictionary];
    ev[@"evidence_grade"] = @"physical_current";
    ev[@"threshold_ma"] = @(kMCLExecutionAmperageThresholdMA);
    ev[@"trigger_soc"] = @(kMCLExecutionTriggerSoC);
    ev[@"present"] = @NO;
    ev[@"conclusive"] = @NO;
    ev[@"physically_limited"] = [NSNull null];
    ev[@"limited"] = [NSNull null];
    NSDictionary* info = nil;
    if (0 != getBatInfo(&info, YES)) {
        // 采样失败：退回 indirect，不得伪装成「未被限制」。
        ev[@"evidence_grade"] = @"indirect";
        ev[@"note"] = @"battery_info_unavailable";
        return ev;
    }
    NSNumber* socObj = [info[@"CurrentCapacity"] isKindOfClass:[NSNumber class]] ? info[@"CurrentCapacity"] : nil;
    NSNumber* extObj = [info[@"ExternalConnected"] isKindOfClass:[NSNumber class]] ? info[@"ExternalConnected"] : nil;
    NSNumber* chargingObj = [info[@"IsCharging"] isKindOfClass:[NSNumber class]] ? info[@"IsCharging"] : nil;
    NSNumber* amperageObj = [info[@"InstantAmperage"] isKindOfClass:[NSNumber class]] ? info[@"InstantAmperage"] : nil;
    NSNumber* amperageFallbackObj = [info[@"Amperage"] isKindOfClass:[NSNumber class]] ? info[@"Amperage"] : nil;
    if (socObj == nil || extObj == nil) {
        ev[@"evidence_grade"] = @"indirect";
        ev[@"note"] = @"battery_properties_incomplete";
        return ev;
    }
    ev[@"soc"] = socObj;
    ev[@"external_connected"] = extObj;
    ev[@"is_charging"] = chargingObj ?: [NSNull null];
    ev[@"present"] = @YES;
    // 优先进阶瞬时电流；缺失时退回 Amperage（第一阶段停充判定同样两者都看）。
    NSNumber* current = amperageObj ?: amperageFallbackObj;
    ev[@"amperage"] = current ?: [NSNull null];
    ev[@"amperage_key"] = amperageObj != nil ? @"InstantAmperage" : (amperageFallbackObj != nil ? @"Amperage" : [NSNull null]);
    BOOL externalConnected = [extObj boolValue];
    NSInteger soc = [socObj integerValue];
    // 观测窗口 = [80, 95]：MCL 生效的稳态是电量钳在上限附近；>95 意味着电量已经
    // 冲过上限（限流未生效）或处于满充保持——两种情况下低电流都判不出 MCL 好坏
    // （真机 2026-09-29：100% 满电自然停充电流 81mA 被误判 physically_limited=true，
    // verdict 假绿）。超出窗口一律 conclusive=NO，不下「生效/未生效」结论。
    BOOL reachedTrigger = soc >= kMCLExecutionTriggerSoC && soc <= kMCLExecutionWindowSoCMax;
    // 决定性条件：插电 + 已到上限阈值。IsCharging 只作参考不作为闸门——iOS 17 上
    // 停充后 IsCharging 常保持 true（第一阶段硬结论），拿它当闸门会把有效限流误判成失效。
    if (externalConnected && reachedTrigger && current != nil) {
        NSInteger ma = [current integerValue];
        if (ma < 0) {
            ma = -ma;   // iOS 17 上 Amperage/InstantAmperage 极性随充放电翻转，取绝对值
        }
        BOOL limited = ma < kMCLExecutionAmperageThresholdMA;
        ev[@"amperage_ma"] = @(ma);
        ev[@"conclusive"] = @YES;
        ev[@"physically_limited"] = @(limited);
        ev[@"limited"] = @(limited);
    } else {
        NSString* note = externalConnected
            ? (soc > kMCLExecutionWindowSoCMax ? @"soc_above_mcl_window_full_charge"
               : (reachedTrigger ? @"amperage_unavailable" : @"soc_below_limit_trigger"))
            : @"not_externally_connected";
        ev[@"note"] = note;
    }
    return ev;
}

// 独立诊断的层3 证据：注册表候选键探测（既有，re-notes 稳定键实验）与物理电流证据（新增）
// 组合。优先返回 registry_diff（键级证据最强）；候选键未命中时若物理通道可采样，
// 返回 physical_current；两者都拿不到才退回 indirect（如实标注证据等级，不伪装）。
static NSDictionary* MCLLayer3EvidenceStandalone(void) {
    BOOL hasCandidates = MCLRegistryEvidenceCandidateKeys().count > 0;
    NSDictionary* registryEvidence = nil;
    if (hasCandidates) {
        NSDictionary* probed = MCLRegistryProbeEvidenceKeys();
        for (NSString* key in MCLRegistryEvidenceCandidateKeys()) {
            NSDictionary* item = probed[key];
            if (item != nil && [item[@"present"] boolValue]) {
                registryEvidence = @{@"evidence_grade": @"registry_diff",
                                     @"present": @YES,
                                     @"key": key,
                                     @"value": item[@"value"] ?: @""};
                break;
            }
        }
        if (registryEvidence == nil) {
            registryEvidence = @{@"evidence_grade": @"registry_diff",
                                 @"present": @NO,
                                 @"note": @"candidate_keys_absent"};
        }
    }
    NSDictionary* physical = MCLPhysicalExecutionEvidence();
    // registry_diff 的语义是「执行层在场」；present=NO 与 physical 未采样都不能升级它。
    if (hasCandidates && [registryEvidence[@"present"] boolValue]) {
        NSMutableDictionary* composed = [registryEvidence mutableCopy];
        composed[@"physical"] = physical;
        return composed;
    }
    if ([physical[@"evidence_grade"] isEqualToString:@"physical_current"] && [physical[@"present"] boolValue]) {
        NSMutableDictionary* composed = [physical mutableCopy];
        composed[@"registry"] = hasCandidates ? registryEvidence : [NSNull null];
        return composed;
    }
    if (hasCandidates) {
        NSMutableDictionary* composed = [registryEvidence mutableCopy];
        composed[@"physical"] = physical;
        return composed;
    }
    // 无候选键且物理不可采样：保持 indirect 退化，附上物理通道的真实原因供人工判读。
    NSMutableDictionary* indirect = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"indirect", @"evidence_grade",
        @NO, @"present",
        @"no_stable_registry_key", @"note",
        physical, @"physical", nil];
    return indirect;
}

// MCL 全链路诊断（单次收集 < 1s：plist 直读 + 既有 XPC 读回 + 候选键单查；不加轮询）。
// get_bat_info 子字典与 get_mcl_diagnostics 共用；iOS 16 及以下早退零收集（Design Doc 4）。
// v1.17.1 修复轮 2：forceRefresh 透传活通道——常规路径（get_bat_info/get_mcl_diagnostics/
// 修复前快照/kept after 快照）走 15s TTL 缓存；仅修复复核 ⑤ 传 YES 绕过缓存强制活读
// （必须看到 enableMCL 刚写入的 live 值，归因守卫依赖）。
static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {
    NSMutableDictionary* report = [NSMutableDictionary dictionary];
    report[@"collectedAt"] = @(time(0));
    BOOL mclSupported = isSmartChargeMCLSupported();
    report[@"supported"] = @(mclSupported);
    if (!mclSupported) {
        // iOS 16 及以下早退零收集（Design Doc 4）：旧系统 MCL 不受支持，三层收集通道
        // 在不支持的系统上要么恒空、要么是无意义开销；get_bat_info 是 App 高频轮询
        // 路径，诊断块必须保持旧机零成本——plist 直读、agent 读回、IORegistry 探测
        // 一概不发起。报告仅携带 supported=false + verdict=unsupported 两个判定字段
        // （外加 collectedAt），App 侧据此隐藏 MCL 诊断分区，不触发任何修复动作。
        report[@"verdict"] = @"unsupported";
        return report;
    }
    // 层1：偏好落盘直读（/var/mobile 域 plist，F7 白名单六键；outPrefs 含
    // domain/plist_path/values/states——states 标记每键 Missing/Found/ReadFailed，
    // 返回 YES 不代表 values 可信，判定一律先看 states，read_failed 走 V3）。
    NSMutableDictionary* layer1 = [NSMutableDictionary dictionary];
    CLMCLReadPrefs(layer1);
    report[@"domain"] = layer1[@"domain"];
    // 层1 活通道（v1.17.1 修复轮 1 回灌）：磁盘直读对 cfprefsd 缓冲态全盲——
    // poweruiagent 以 mobile 用户经 cfprefsd 写偏好，plist 可能长期不落盘甚至从
    // 不存在；"文件读不到"≠"偏好为空"≠"服务端没写"。live 子字典携带通道状态
    // （channel/channel_reason）、目录证据（pref_files）、六键解析与 defaults 原始输出（raw）。
    // forceRefresh 透传（修复轮 2）：常规路径命中 15s TTL 缓存即不 fork defaults 子进程。
    NSMutableDictionary* live = [NSMutableDictionary dictionary];
    CLMCLReadPrefsLive(live, forceRefresh);
    layer1[@"live"] = live;
    report[@"layer1"] = layer1;
    // 层2：agent 内存层读回（复用既有 XPC 通道，F1 语义）。
    int obcStatus = -1;
    BOOL agentSupported = NO;
    BOOL agentEnabled = NO;
    CLMCLReadAgentState(&obcStatus, &agentSupported, &agentEnabled);
    report[@"layer2"] = @{@"obc_status": @(obcStatus),
                          @"mcl_supported": @(agentSupported),
                          @"mcl_enabled": @(agentEnabled)};
    // 层3：执行层证据（repair 编排可传前后 diff 覆盖；独立诊断走候选键探测 + 物理电流采样）。
    report[@"layer3"] = layer3Override ?: MCLLayer3EvidenceStandalone();
    // 官方临时停用窗口（disabledUntil 直读）：区分「系统自己的 TemporarilyDisabled 窗口」
    // 与「真执行层失效」的关键证据；verdict 不因窗口单独翻转，由 maintain 层让位逻辑消费。
    report[@"temporary_window"] = MCLTemporaryWindowEvidence();
    // 电池计量中和门（DOD0/QMax/满充时间戳复算）：engage 会不会被中和成 101 当场可判，
    // 命中即提示「先充满一次校准」——不用抓 log stream。
    report[@"mitigation_gate"] = MCLMitigationGateEvidence();
    // 维持器运行时快照（只读）：即便维持器没跑（旧系统 / 不支持 / 用户关闭）也如实上报，
    // 便于把「执行层缺位却没有任何对抗动作」与「维持器在跑但仍在冷却」区分开。
    report[@"maintain"] = mclMaintainRuntimeSnapshot();
    // 判定活通道优先（v1.17.1）：磁盘 Missing/ReadFailed 的键以活通道值为准合成
    // 判定视图；pref_lost 仅在双通道均无法证实 MCLFeatureState=true 时给出。
    // 报告 layer1 保留磁盘真值 + live 子字典，effective_channel 标注判定生效通道
    // （disk/live/none，修复轮 2 增补 MCLFeatureState 值冲突场景 conflict_live_wins）。
    NSString* effectiveChannel = nil;
    NSDictionary* verdictLayer1 = MCLLiveFirstLayer1(layer1, &effectiveChannel);
    layer1[@"effective_channel"] = effectiveChannel ?: @"none";
    report[@"verdict"] = MCLVerdictFromDiagnostics(mclSupported, verdictLayer1, agentEnabled, report[@"layer3"]);
    return report;
}

// 常规收集包装：走活通道 15s TTL 缓存（get_bat_info 1Hz 轮询、get_mcl_diagnostics、
// 修复前快照与 kept after 快照共用）。修复复核 ⑤ 不得经由本包装（须强制刷新）。
static NSDictionary* collectMCLDiagnostics(void) {
    return collectMCLDiagnosticsWithLayer3(nil, NO);
}

/* ---------------- iOS 17+ MCL 强制修复编排（Design Doc 3.4，tasks 3.2） ---------------- */

// gate2（MobileGestalt）证据探测：re-notes F2——`DeviceSupports80ChargeLimit` 为假且
// isInternalBuild==0 时，poweruiagent enableMCL 在写任何偏好前静默 bail（不写不报错）。
// 返回 nil = MobileGestalt 探测不到该键，证据未知（报告 gate_evidence 以 NSNull 如实标注）。
// extern "C" 声明与 utils.mm 既有用法一致（同一二进制已链接 libMobileGestalt）；
// .mm 为 ObjC++，缺 extern "C" 会因 C++ 名字修饰在链接期找不到符号。
extern "C" CFTypeRef MGCopyAnswer(CFStringRef answer);

static NSNumber* MCLProbeDeviceSupports80ChargeLimit(void) {
    CFTypeRef raw = MGCopyAnswer(CFSTR("DeviceSupports80ChargeLimit"));
    if (raw == NULL) {
        return nil;
    }
    id value = CFBridgingRelease(raw);
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value respondsToSelector:@selector(boolValue)]) {
        return @([value boolValue]);
    }
    return nil;
}

// mcl_repair_* 时间线事件：MCL 修复不改 smart charge 状态，而 appendSmartChargeCoordinationEvent
// 在 from==to 时按转移语义丢弃事件——修复留痕直写同一 policy 事件时间线，extras 字段布局与
// 协调事件一致（smart_charge_from/to 记当前状态，协调会话在场时带 session_id）。
static void appendMCLRepairCoordinationEvent(NSString* reason, NSDictionary* extras) {
    NSMutableDictionary* eventExtras = [NSMutableDictionary dictionary];
    if ([extras isKindOfClass:[NSDictionary class]]) {
        [eventExtras addEntriesFromDictionary:extras];
    }
    eventExtras[@"smart_charge_from"] = @(g_smartChargeStatus);
    eventExtras[@"smart_charge_to"] = @(g_smartChargeStatus);
    if (g_smartChargeCoordinationSessionID.length > 0) {
        eventExtras[@"session_id"] = g_smartChargeCoordinationSessionID;
    }
    appendPolicyEventHistory(@"smart_charge_event", @"", @"", reason, nil, eventExtras, time(0));
}

static BOOL g_mclRepairRunning = NO;

static NSObject* MCLRepairLock(void) {
    static NSObject* lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}

// ④a 偏好规范化：只写白名单键（MCLFeatureState=true；mclLimitValue/mclTargetSoC 缺失补默认 80，
// F4 非 internal 构建 engage 固定用 80，规范化只为域内一致性）；已存在值不动（保留用户语义）。
// best-effort：逐键结果记入报告，失败不中止修复——F2 服务端 enableMCL 受理会自写 MCLFeatureState。
// 读取异常（ReadFailed）或重读失败（TOCTOU：快照后文件被删/损坏）时跳过写入，避免覆盖丢失非白名单键。
static NSDictionary* MCLNormalizePrefsForRepair(NSMutableDictionary* layer1) {
    NSString* domain = layer1[@"domain"] ?: @"";
    if ([domain isEqualToString:@"unresolved"] || domain.length == 0) {
        // Design Doc 4：域未解析 → 跳过规范化直接 force enable（engage 不依赖我们写偏好）
        return @{@"skipped": @YES, @"reason": @"domain_unresolved"};
    }
    NSDictionary* states = layer1[@"states"] ?: @{};
    for (NSString* key in CLMCLPrefKeys()) {
        if ([states[key] intValue] == CLMCLPrefReadFailed) {
            return @{@"skipped": @YES, @"reason": @"pref_read_failed"};
        }
    }
    NSString* path = layer1[@"plist_path"] ?: @"";
    if (path.length == 0) {
        return @{@"skipped": @YES, @"reason": @"plist_path_missing"};
    }
    NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (dict == nil) {
        // TOCTOU 加固（修复轮 1）：states 检查仅保证快照时刻可解析；重读失败（文件被删/
        // 损坏）时若以空字典继续写会整体覆盖 plist、丢掉全部非白名单键——跳过零写入，
        // 修复实质交由 force enable 路径兜底（F2 服务端受理自写偏好）。
        return @{@"skipped": @YES, @"reason": @"plist_unreadable_at_write"};
    }
    NSMutableDictionary* results = [NSMutableDictionary dictionary];
    dict[@"MCLFeatureState"] = @YES;
    results[@"MCLFeatureState"] = @YES;
    for (NSString* key in @[@"mclLimitValue", @"mclTargetSoC"]) {
        if ([states[key] intValue] != CLMCLPrefFound) {
            dict[key] = @80;
            results[key] = @YES;
        }
    }
    BOOL ok = [dict writeToFile:path atomically:YES];
    return @{@"skipped": @NO, @"ok": @(ok), @"keys": results};
}

// 失败回滚：把规范化写过的键恢复为快照原值（原不存在则移除）。返回 NO = 回滚失败。
static BOOL MCLRollbackPrefs(NSString* plistPath, NSDictionary* snapshotValues, NSArray<NSString*>* writtenKeys) {
    if (plistPath.length == 0 || writtenKeys.count == 0) {
        return YES; // 无写入则无需回滚
    }
    NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (dict == nil) {
        return NO;
    }
    for (NSString* key in writtenKeys) {
        id original = snapshotValues[key];
        if (original == nil) {
            [dict removeObjectForKey:key];
        } else {
            dict[key] = original;
        }
    }
    return [dict writeToFile:plistPath atomically:YES];
}

static NSDictionary* performMCLLimitRepairInner(void) {
    // ② busy 守卫：协调会话活跃拒绝（Design Doc 4：避免与 temp-disable/restore 竞争破坏 OBC 状态）
    if (g_tempSmartChargeDisabledByCL || g_smartChargeCoordinationSessionID.length > 0) {
        return @{@"supported": @YES, @"busy": @YES, @"verdict": @"busy",
                 @"reason": @"coordination_session_active"};
    }
    appendMCLRepairCoordinationEvent(@"mcl_repair_started", @{ @"trigger": @"api_repair_mcl_limit" });
    // ② 快照：白名单六键全量快照（供回滚）+ 层3 数值属性全量快照（供前后 diff）
    NSMutableDictionary* beforePrefs = [NSMutableDictionary dictionary];
    CLMCLReadPrefs(beforePrefs);
    NSDictionary* registryBefore = MCLSnapshotRegistryNumericProps();
    NSDictionary* snapshotValues = beforePrefs[@"values"] ?: @{};
    // ③ 健康语义判定（Design Doc 3.4-③ + 最终审查修复波）：healthy_disabled 保持用户
    // 选项——不写偏好、不 force、零副作用。healthy_enabled 仅在执行层在场证据
    // （evidence_grade == registry_diff 且 present == YES）证实时才同样 kept；v1 层3 只有
    // indirect（MCLRegistryEvidenceCandidateKeys() 为空、注册表稳定键无静态候选），受损
    // 设备（偏好 MCLFeatureState=true + 代理读回 YES + 执行层断）会被判定矩阵归为
    // healthy_enabled（行 2 需 registry_diff 证据，当前不可达）——读回短路 kept 会让修复
    // 按钮成空操作。按 delta spec「强制修复 80% 限制」第 1 条不信任读回短路：indirect
    // 下的 healthy_enabled 继续走完整修复序列（真健康设备 = 幂等重申，服务端重写
    // MCLFeatureState=true + 重设 limit 80，用户选项语义不变；假健康设备 = 真正修复），
    // 报告沿用 action=repaired / verdict_before=healthy_enabled。
    NSDictionary* beforeDiag = collectMCLDiagnostics();
    NSString* verdictBefore = beforeDiag[@"verdict"] ?: @"";
    NSDictionary* layer3Before = beforeDiag[@"layer3"] ?: @{};
    BOOL healthyEnabled = [verdictBefore isEqualToString:@"healthy_enabled"];
    BOOL executionLayerProven = healthyEnabled
        && [layer3Before[@"evidence_grade"] isEqualToString:@"registry_diff"]
        && [layer3Before[@"present"] boolValue];
    if ([verdictBefore isEqualToString:@"healthy_disabled"] || executionLayerProven) {
        NSDictionary* afterDiag = collectMCLDiagnostics();
        appendMCLRepairCoordinationEvent(@"mcl_repair_finished",
                                         @{ @"action": @"kept", @"verdict_before": verdictBefore });
        return @{@"supported": @YES, @"busy": @NO, @"action": @"kept",
                 @"success": @YES, @"verdict_before": verdictBefore,
                 @"before": beforeDiag, @"after": afterDiag};
    }
    // ④ 修复序列（目标=启用）：规范化偏好 → 无条件 enableMCL（Task 3 入口，绕过读回短路）
    NSDictionary* normalize = MCLNormalizePrefsForRepair(beforePrefs);
    BOOL forceOK = CLMCLForceEnable();
    // ⑤ 复核：层3 前后 diff + 重跑诊断（diff 出 limit/override 类整型变化 → layer3 升级 registry_diff）。
    // 修复复核必须绕过活通道 15s TTL 缓存强制刷新（forceRefresh=YES，修复轮 2 审查
    // 发现 1）：否则看不到 enableMCL 刚写入的 live 值，归因守卫（liveProven）失效。
    NSDictionary* registryAfter = MCLSnapshotRegistryNumericProps();
    NSDictionary* diff = MCLDiffRegistryProps(registryBefore, registryAfter);
    NSDictionary* limitRelated = diff[@"limit_related"] ?: @{};
    NSDictionary* layer3Override = nil;
    if (limitRelated.count > 0) {
        layer3Override = @{@"evidence_grade": @"registry_diff",
                           @"present": @YES,
                           @"diff": limitRelated};
    }
    NSDictionary* afterDiag = collectMCLDiagnosticsWithLayer3(layer3Override, YES);
    NSString* verdictAfter = afterDiag[@"verdict"] ?: @"";
    BOOL success = [verdictAfter isEqualToString:@"healthy_enabled"];
    if (success) {
        appendMCLRepairCoordinationEvent(@"mcl_repair_finished",
                                         @{ @"action": @"repaired", @"verdict_before": verdictBefore,
                                            @"verdict_after": verdictAfter, @"success": @YES });
        return @{@"supported": @YES, @"busy": @NO, @"action": @"repaired",
                 @"success": @YES, @"verdict_before": verdictBefore, @"verdict_after": verdictAfter,
                 @"before": beforeDiag, @"after": afterDiag,
                 @"normalize": normalize, @"force_enable_ok": @(forceOK), @"registry_diff": diff};
    }
    // ⑥ 失败：按 re-notes F2/F4/F5 静默分支族区分证据（gate1/gate2 写前 bail + QMax 中和 +
    // token==0 不下发 + 调用报错），给出建议并回滚 ④a 写入。判定一律用修复后快照
    // （afterDiag.layer1 为复核重读），避免用修复前状态误判分支。
    NSString* branch = @"still_disconnected";
    NSString* branchNote = nil;
    NSString* advice = @"reboot_and_retry";   // 默认建议；accepted_unverified 改 charge_test_now
    NSDictionary* gateEvidence = nil;
    if (!forceOK) {
        branch = @"call_error";              // enableMCL 报错/返回 NO（err 回调）
    } else {
        NSDictionary* afterStates = afterDiag[@"layer1"][@"states"] ?: @{};
        NSDictionary* afterValues = afterDiag[@"layer1"][@"values"] ?: @{};
        int featureState = [afterStates[@"MCLFeatureState"] intValue];
        BOOL diskProven = (featureState == CLMCLPrefFound) && [afterValues[@"MCLFeatureState"] boolValue];
        // 活通道证实（v1.17.1 修复轮 1 回灌）：磁盘直读对 cfprefsd 缓冲态全盲——
        // poweruiagent 经 cfprefsd 写偏好可能长期不落盘，"磁盘读不到"≠"服务端没写"。
        // mcl_supported=true 已证 augury 门是开的，仅凭磁盘单通道证伪归 gate1 自相
        // 矛盾。归因改为双通道任一证实 MCLFeatureState=true 即算写入；两通道都无法
        // 证实才归 gate1/gate2。
        NSDictionary* afterLive = [afterDiag[@"layer1"][@"live"] isKindOfClass:[NSDictionary class]]
            ? afterDiag[@"layer1"][@"live"] : @{};
        NSDictionary* afterLiveStates = [afterLive[@"states"] isKindOfClass:[NSDictionary class]] ? afterLive[@"states"] : @{};
        NSDictionary* afterLiveValues = [afterLive[@"values"] isKindOfClass:[NSDictionary class]] ? afterLive[@"values"] : @{};
        BOOL liveProven = [afterLive[@"channel"] isEqualToString:@"ok"]
            && [afterLiveStates[@"MCLFeatureState"] intValue] == CLMCLPrefFound
            && [afterLiveValues[@"MCLFeatureState"] boolValue];
        BOOL featureWritten = diskProven || liveProven;
        if (!featureWritten) {
            // 受理推断守卫（v1.17.2 归因修正，re-notes §7 / F2）：层2 内存标志置位
            // 代码（strb #1,[x19+0x14]）位于 gate1/gate2 之后执行——
            // after.layer2.mcl_enabled=YES 即服务端已通过全部门禁并受理 enableMCL
            // 的实锤，此时禁止归 gate1/gate2（自相矛盾）：双通道无法证实
            // MCLFeatureState 只说明 cfprefsd 持久化证据不可得，不代表 bail。
            // 报新分支 accepted_unverified，建议插电充电实测（charge_test_now）。
            if ([afterDiag[@"layer2"][@"mcl_enabled"] boolValue]) {
                branch = @"accepted_unverified";
                advice = @"charge_test_now";
            } else {
                // F2：enableMCL 真正受理会在返回前自写 MCLFeatureState 并置位层2 标志
                // ——双通道均无法证实写入且层2 未翻转 = 服务端在写偏好前静默 bail，
                // 归因 gate1/gate2（外部不可直接观测，按证据推断）。
                NSNumber* deviceGate = MCLProbeDeviceSupports80ChargeLimit();
                gateEvidence = @{@"DeviceSupports80ChargeLimit": deviceGate ?: NSNull.null};
                branch = (deviceGate != nil && ![deviceGate boolValue])
                    ? @"gate2_device_gate"       // 设备门为假：非内部构建下确定性 bail，优先归因
                    : @"gate1_augury_feature";   // 设备门为真/未知：剩余候选（augury feature 门）
            }
        } else if (liveProven && !diskProven) {
            // 活通道证实写入已受理、仅磁盘不可读（缓冲态未落盘）：gate 未拦截。
            // 代理内存读回仍未翻转 = 层2 侧断点（写入被服务端受理、代理未加载新值）。
            if (![afterDiag[@"layer2"][@"mcl_enabled"] boolValue]) {
                branch = @"still_disconnected";
                branchNote = @"mcl_feature_state_confirmed_by_live_channel; "
                             "agent_memory_mcl_enabled_false (write accepted by cfprefsd, agent not flipped)";
            }
            // 代理内存已翻转但判定仍不健康（罕见：执行层证据缺失行），branch 保持
            // still_disconnected——写入已被证实，断点在层2/层3 侧。
        } else {
            // 执行层物理证据（固件逆向定案 §10.4 新增）：偏好与代理层全绿、enableMCL 也已
            // 受理，但插电 + 电量已到上限 + 电流未被压低——这是「engage 那一刻被中和为
            // 101（QMax/DOD0/lastFullChargeDate 维护窗口）」或「powerd 侧 ChargeLimit 被
            // IOPSLimitBatteryLevelCancel 取消」的可观测指纹，比 qmax_neutralized（依赖
            // 注册表 diff，而候选键实验至今为空、永远拿不到）直接得多。取修复后即时采样：
            // enableMCL 同步走到 IOPSLimitBatteryLevel，此刻仍未限制即为实证。
            NSDictionary* physicalAfter = MCLPhysicalExecutionEvidence();
            if ([physicalAfter[@"conclusive"] boolValue]
                && [physicalAfter[@"physically_limited"] isKindOfClass:[NSNumber class]]
                && ![physicalAfter[@"physically_limited"] boolValue]) {
                // 中和门复算（第五轮真机定案主因）：DOD0/QMax/满充时间戳任一命中阈值，
                // engage 就会被中和成 101——此时重下发多少次都无效，唯一出路是充满一次
                // 校准后重新 engage。偏好时间戳可完全复算，无需 log stream。
                NSDictionary* gate = MCLMitigationGateEvidence();
                if ([gate[@"will_neutralize"] boolValue]) {
                    branch = @"engage_neutralized_mitigation";
                    advice = @"full_charge_calibration";
                    branchNote = @"engage-time value neutralized to 101 by battery mitigation (see after.mitigation_gate reasons); full-charge calibration required before re-engage can take effect";
                } else {
                    branch = @"execution_layer_not_limited";
                    // 归因边界（如实标注，不得过度归因）：本分支能证实的是「执行层未在限制」，
                    // 但它无法区分剩余两种上游原因——powerd 侧的 ChargeLimit 被
                    // IOPSLimitBatteryLevelCancel 取消、或官方临时停用窗口（disabledUntil）
                    // 在修复后立刻被触发源重新设置。理由：value 与 cancel 都不经 cfprefsd
                    // 落盘（mclTargetSoC 偏好键 PowerUI 从不写；IOPS* 状态只在 powerd 进程内），
                    // 外部拿不到可区分的持久证据；窗口侧看 after.temporary_window。
                    // 需要精确归因时须抓 `log stream` 的日志：
                    //   "Cleared current charge limit token"        → cancel 路径
                    //   "requests state: 2/3" + "Feature disabled until:" → 窗口触发源（clientName 即调用者）
                    branchNote = @"plugged in above limit but amperage still high: powerd charge limit cancelled or official temp window re-engaged (see log stream to distinguish)";
                    advice = @"re_engage_and_observe";
                }
            } else {
                BOOL qmaxNeutralized = NO;
                for (NSString* key in limitRelated) {
                    NSInteger afterValue = [limitRelated[key][@"after"] integerValue];
                    if (afterValue == 101 || afterValue == 0) {   // F4：0x65=101=不限制
                        qmaxNeutralized = YES;
                        break;
                    }
                }
                if (qmaxNeutralized) {
                    branch = @"qmax_neutralized";   // QMax 未就绪 → 限制值被中和，不下发限制
                } else {
                    // F5：engage 会自动创建并持久化 token（缺失不是断点）；修复后仍缺失/为 0
                    // 才是 "Charge token is 0, do not engage charge limit" 分支。
                    int tokenState = [afterStates[@"chargeLimitToken"] intValue];
                    id tokenValue = afterValues[@"chargeLimitToken"];
                    NSInteger tokenNumeric = [tokenValue respondsToSelector:@selector(integerValue)]
                        ? [tokenValue integerValue] : 0;
                    if (tokenState != CLMCLPrefFound || tokenNumeric == 0) {
                        branch = @"token_zero";
                    }
                }
            }
        }
    }
    NSArray<NSString*>* writtenKeys = [normalize[@"keys"] allKeys] ?: @[];
    BOOL rollbackAttempted = ![normalize[@"skipped"] boolValue] && writtenKeys.count > 0;
    BOOL rollbackOK = rollbackAttempted
        ? MCLRollbackPrefs(beforePrefs[@"plist_path"], snapshotValues, writtenKeys)
        : YES;
    appendMCLRepairCoordinationEvent(@"mcl_repair_finished",
                                     @{ @"action": @"repaired", @"verdict_before": verdictBefore,
                                        @"verdict_after": verdictAfter, @"success": @NO,
                                        @"failure_branch": branch });
    NSMutableDictionary* failure = [NSMutableDictionary dictionaryWithDictionary:@{
        @"supported": @YES, @"busy": @NO, @"action": @"repaired",
        @"success": @NO, @"verdict_before": verdictBefore, @"verdict_after": verdictAfter,
        @"before": beforeDiag, @"after": afterDiag,
        @"normalize": normalize, @"force_enable_ok": @(forceOK), @"registry_diff": diff,
        @"failure_branch": branch, @"advice": advice,
        @"rollback": @{@"attempted": @(rollbackAttempted), @"ok": @(rollbackOK),
                       @"failed": @(rollbackAttempted && !rollbackOK), @"snapshot": snapshotValues},
    }];
    if (gateEvidence != nil) {
        failure[@"gate_evidence"] = gateEvidence;
    }
    if (branchNote != nil) {
        failure[@"note"] = branchNote;   // 活通道证实写入/代理未翻转等归因注记
    }
    return failure;
}

static NSDictionary* performMCLLimitRepair(void) {
    // ① 门控：iOS < 17 → unsupported，零写入零 MCL XPC 调用（Design Doc 4：旧系统零成本）
    if (@available(iOS 17.0, *)) {
        // 继续
    } else {
        return @{@"supported": @NO, @"unsupported": @YES, @"verdict": @"unsupported"};
    }
    if (!isSmartChargeMCLSupported()) {
        return @{@"supported": @NO, @"unsupported": @YES, @"verdict": @"unsupported"};
    }
    // ② 修复互斥（与 smart charge 协调会话的并发守卫见 Inner 内协调会话检查）
    @synchronized (MCLRepairLock()) {
        if (g_mclRepairRunning) {
            return @{@"supported": @YES, @"busy": @YES, @"verdict": @"busy"};
        }
        g_mclRepairRunning = YES;
    }
    NSDictionary* result = nil;
    @try {
        result = performMCLLimitRepairInner();
    } @finally {
        @synchronized (MCLRepairLock()) {
            g_mclRepairRunning = NO;
        }
    }
    return result;
}

/* ---------------- iOS 17+ MCL 自动维持（固件逆向定案：系统侧无重新 evaluate 路径） ---------------- */

// 固件逆向定案（PowerUI/PowerUISmartChargeManager）指出的真正缺口：MCL 的 80/101 值只在
// engageManualChargeLimit 执行那一刻决定，之后系统侧没有任何路径会重新 evaluate——
//   1. mclTargetSoC=101（QMax/DOD0/lastFullChargeDate 维护窗口中和，日志
//      "QMax update needed, do not limit charging"）→ IOPSLimitBatteryLevel 收到 101=不限制，
//      窗口过去后也不会有第二次 engage；
//   2. clearChargeLimit 调 IOPSLimitBatteryLevelCancel() 取消 powerd 侧限制（拔电沿），
//      重新插电时 handleCallback 才会再 engage；
//   3. 排障三重奏（偏好/代理内存/token 全绿）永远无法暴露上面两条——isMCLCurrentlyEnabled
//      只读代理内存标志，与 powerd 里是否有生效限制无关。
//
// 因此需要外部对抗：在「用户原意是 80% 限制」且「插电 + 电量已到上限 + 电流未被压低」
// 同时成立时，重新走一次与设置 UI 等价的 enableMCL（PowerUISmartChargeClient 公共 selector，
// 不引入新的私有入口），迫使系统侧重新 evaluate 当前维护窗口。
//
// 安全边界（缺一不可）：
//   - 不新增常驻进程：挂在既有 daemon 的主 runloop NSTimer 上，随 daemon 生命周期走。
//   - 不覆盖用户选择：只在代理内存层读回 MCL=YES 时才维持；用户显式关掉 MCL 时 classify
//     为 off，维持器一概不动。永久停用系统优化充电（disableMCLForPermanentDisable）后
//     读回为 NO，天然出局。
//   - 不覆盖 CL 自己的策略：满充计划窗口 / 协调会话 / 手动修复进行中一律暂停。
//   - 抑制误触发：要求物理证据连续两次一致（默认 60s 间隔 ≈ 1 分钟稳态），再加冷却期。
static const NSTimeInterval kMCLMaintainIntervalSeconds = 60.0;
static const NSTimeInterval kMCLMaintainCooldownSeconds = 300.0;
static const NSInteger kMCLMaintainNegativeStreakRequired = 2;

static NSTimer* g_mclMaintainTimer = nil;
static time_t g_mclMaintainLastEngageTs = 0;
static NSInteger g_mclMaintainNegativeStreak = 0;
static NSMutableDictionary* g_mclMaintainRuntimeState = nil;

// 维持器是否应该跑：iOS17+、MCL 受支持、CL 总开关开着、维持功能未被人为关闭。
// 不在这里判断 MCL 开/关——那属于「用户选择」，由 tick 内读回值决定。
static BOOL mclMaintainShouldRun(void) {
    if (!g_enable) {
        return NO;
    }
    if (!getLocalBool(@"mcl_auto_maintain", NO)) {
        return NO;
    }
    if (@available(iOS 17.0, *)) {
        // 继续
    } else {
        return NO;
    }
    return isSmartChargeMCLSupported();
}

static void mclMaintainRecordState(NSString* classification, NSDictionary* evidence, NSString* action) {
    if (g_mclMaintainRuntimeState == nil) {
        g_mclMaintainRuntimeState = [NSMutableDictionary dictionary];
    }
    g_mclMaintainRuntimeState[@"lastCheckAt"] = @(time(0));
    g_mclMaintainRuntimeState[@"classification"] = classification ?: @"unknown";
    if (evidence != nil) {
        g_mclMaintainRuntimeState[@"lastEvidence"] = evidence;
    }
    g_mclMaintainRuntimeState[@"lastAction"] = action ?: @"none";
    g_mclMaintainRuntimeState[@"lastEngageAt"] = @(g_mclMaintainLastEngageTs);
    g_mclMaintainRuntimeState[@"negativeStreak"] = @(g_mclMaintainNegativeStreak);
}

// 单次维持检查：采样物理证据 → 分类 → 需要时重新 engage。
// 返回值仅供日志/测试观察，不影响调用方。
static NSString* mclMaintainTick(void) {
    if (!mclMaintainShouldRun()) {
        return @"inactive";
    }
    // 与 repair 的 busy 守卫同一语义：手动修复进行中时维持器让位，避免两个入口并发
    // 下发（虽然 enableMCL: 幂等且整体由 @synchronized(Service.inst) 串行，但手动修复
    // 会做前后快照/回滚，并发 tick 的写入可能落进它的回滚窗口）。
    @synchronized (MCLRepairLock()) {
        if (g_mclRepairRunning) {
            g_mclMaintainNegativeStreak = 0;
            mclMaintainRecordState(@"paused", nil, @"repair_in_progress");
            return @"paused";
        }
    }
    // 协调会话在场（temp-disable/restore）：OBC 状态语义正在被临时改写，维持器不得插手。
    if (g_tempSmartChargeDisabledByCL || g_smartChargeCoordinationSessionID.length > 0) {
        g_mclMaintainNegativeStreak = 0;
        mclMaintainRecordState(@"paused", nil, @"coordination_active");
        return @"paused";
    }
    if (g_fullChargeWindowActive) {
        // 满充计划正在主动允许充到更高电量：此刻「电流未被压低」是预期行为，
        // 维持器不得把用户排期的满充窗口顶掉。
        g_mclMaintainNegativeStreak = 0;
        mclMaintainRecordState(@"paused", nil, @"full_charge_window_active");
        return @"paused";
    }
    // 用户选择优先：代理内存读回关 = 用户没要 80% 限制（含 CL 永久停用后的显式关）。
    if (!getSmartChargeMCLEnabled()) {
        g_mclMaintainNegativeStreak = 0;
        mclMaintainRecordState(@"mcl_off_by_user", nil, @"none");
        return @"mcl_off_by_user";
    }
    // 官方临时停用窗口在场（disabledUntil 未过期，明早 6:00 截止）：此刻「电流未被压低」
    // 是系统明确的窗口语义而非执行层失效，窗口结束后的插件沿 handleCallback 会自愈重新
    // engage。窗口内重下发 enableMCL 只会对抗系统语义（真机「修好一下又坏」的对抗循环
    // 嫌疑路径），让位并如实记录窗口。
    NSDictionary* window = MCLTemporaryWindowEvidence();
    if ([window[@"active"] boolValue]) {
        g_mclMaintainNegativeStreak = 0;
        mclMaintainRecordState(@"official_temp_window", window, @"none");
        return @"official_temp_window";
    }
    NSDictionary* evidence = MCLPhysicalExecutionEvidence();
    // 非决定性采样（未插电 / 电量未到上限 / 采样失败）不得进入判定。
    if (![evidence[@"conclusive"] boolValue]) {
        g_mclMaintainNegativeStreak = 0;
        mclMaintainRecordState(@"not_applicable", evidence, @"none");
        return @"not_applicable";
    }
    if ([evidence[@"physically_limited"] boolValue]) {
        // 执行层在场：限制正常生效，清零误触计数。
        g_mclMaintainNegativeStreak = 0;
        mclMaintainRecordState(@"healthy", evidence, @"none");
        return @"healthy";
    }
    // 执行层缺位：插着电、电量 >=80%、电流 >=120mA。
    g_mclMaintainNegativeStreak += 1;
    mclMaintainRecordState(@"execution_layer_missing", evidence, @"pending");
    if (g_mclMaintainNegativeStreak < kMCLMaintainNegativeStreakRequired) {
        return @"pending";
    }
    // 冷却期：避免在边界抖动时反复重下发（enableMCL 是幂等系统级写，但每次都走 XPC
    // 与偏好写入，仍应限量）。
    time_t now = time(0);
    if (g_mclMaintainLastEngageTs > 0 && (now - g_mclMaintainLastEngageTs) < (time_t)kMCLMaintainCooldownSeconds) {
        return @"cooling_down";
    }
    // TOCTOU 复查：两次采样之间用户/CL 可能刚把 MCL 关掉（例如手动修复的 disable 路径），
    // 直接重下发会把用户的选择覆盖回去。
    if (!getSmartChargeMCLEnabled()) {
        g_mclMaintainNegativeStreak = 0;
        mclMaintainRecordState(@"mcl_off_by_user", evidence, @"none");
        return @"mcl_off_by_user";
    }
    // 刻意不 gate 在 chargeLimitToken 上（firmware 定案，见文件头部注释第 6 条）：
    // loadChargeLimitToken 在偏好键缺失时自行创建新 token 并回写，engage 才真正调用
    // IOPSLimitBatteryLevel。前置检查 token==0 只会挡住唯一能自愈的那次 engage。
    BOOL ok = CLMCLForceEnable();
    g_mclMaintainLastEngageTs = now;
    g_mclMaintainNegativeStreak = 0;
    mclMaintainRecordState(ok ? @"re_engaged" : @"re_engage_failed", evidence,
                           ok ? @"force_enable" : @"force_enable_failed");
    // 时间线留痕：与 mcl_repair_* 同一 policy 事件时间线，方便诊断页与历史页看到维持动作。
    appendMCLRepairCoordinationEvent(@"mcl_maintain_re_engaged",
                                     @{@"trigger": @"execution_layer_missing",
                                       @"success": @(ok),
                                       @"soc": evidence[@"soc"] ?: [NSNull null],
                                       @"amperage_key": evidence[@"amperage_key"] ?: [NSNull null],
                                       @"amperage_ma": evidence[@"amperage_ma"] ?: [NSNull null]});
    return ok ? @"re_engaged" : @"re_engage_failed";
}

static void refreshMCLMaintainTimer(void) {
    BOOL shouldRun = mclMaintainShouldRun();
    if (!shouldRun) {
        if (g_mclMaintainTimer != nil) {
            [g_mclMaintainTimer invalidate];
            g_mclMaintainTimer = nil;
        }
        g_mclMaintainNegativeStreak = 0;
        return;
    }
    if (g_mclMaintainTimer != nil) {
        return;
    }
    g_mclMaintainTimer = [NSTimer scheduledTimerWithTimeInterval:kMCLMaintainIntervalSeconds
                                                       repeats:YES
                                                         block:^(NSTimer* timer) {
        @synchronized (Service.inst) {
            mclMaintainTick();
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_mclMaintainTimer forMode:NSRunLoopCommonModes];
}

// 诊断报告用的维持器运行时快照（只读：get_mcl_diagnostics / get_bat_info 直接嵌入）。
static NSDictionary* mclMaintainRuntimeSnapshot(void) {
    NSMutableDictionary* snap = [NSMutableDictionary dictionary];
    snap[@"enabled"] = @(getLocalBool(@"mcl_auto_maintain", NO));
    snap[@"interval_seconds"] = @(kMCLMaintainIntervalSeconds);
    snap[@"cooldown_seconds"] = @(kMCLMaintainCooldownSeconds);
    snap[@"negative_streak_required"] = @(kMCLMaintainNegativeStreakRequired);
    snap[@"amperage_threshold_ma"] = @(kMCLExecutionAmperageThresholdMA);
    snap[@"trigger_soc"] = @(kMCLExecutionTriggerSoC);
    snap[@"running"] = @(g_mclMaintainTimer != nil);
    snap[@"lastEngageAt"] = @(g_mclMaintainLastEngageTs);
    if (g_mclMaintainRuntimeState != nil) {
        [snap addEntriesFromDictionary:g_mclMaintainRuntimeState];
    }
    return snap;
}

static void restoreSmartChargeForReset(NSString* reason) {
    loadSmartChargeCoordinationRuntimeState();
    tryRestoreSmartChargeAfterCoordination(reason ?: @"reset");

    BOOL permanentlyDisableSmartCharge = getLocalBool(@"disable_smart_charge", NO);
    if (!permanentlyDisableSmartCharge) {
        return;
    }

    int smartChargeStatus = getSmartChargeStatus();
    if (smartChargeStatus < 0) {
        return;
    }
    BOOL restoreEnable = shouldRestorePermanentSmartChargeDisableForResetReason(reason);
    setSmartChargeEnable(restoreEnable ? YES : NO);
    if (restoreEnable) {
        restoreMCLStateAfterEnable();
    }
}

static void restoreThermalSimulationForReset(void) {
    setThermalSimulationMode(@"off");
    // spec『还原的对象与语义』第 5 条：温控与 PPM 模拟双双归零。
    setPPMSimulationMode(@"off");
}

static void restoreAcceleratedChargeStateForReset(void) {
    performAcccharge(NO);
}

// 重置/卸载路径补写禁流键：上方 props 只覆盖 IsCharging/PCI/ExternalConnected，
// iOS 17 禁流写在 FieldDiagsInflowInhibit/OBCInflowInhibit（override 写平面），
// 不显式复位会残留到系统对抗自愈为止（非确定性）。
static void restoreInflowOverrideForReset(void) {
    if (!CLCanUseOverrideChargeControl()) {
        return;
    }
    io_service_t overrideServ = CLCopyOverrideWriteService();
    if (overrideServ == IO_OBJECT_NULL) {
        return;
    }
    kern_return_t ret = setInflowStatusOverride(overrideServ, YES);
    IOObjectRelease(overrideServ);
    if (ret != 0) {
        NSFileErrorLog(@"reset inflow restore write failed ret=%d", ret);
    }
}

static void resetBatteryStatusWithContext(BOOL restoreRuntimeSideEffects, NSString* reason) {
    io_service_t serv = getIOPMPSServ();
    cancelDisableInflowRetry();
    time_t now = time(0);
    if (restoreRuntimeSideEffects) {
        restoreAcceleratedChargeStateForReset();
        restoreSmartChargeForReset(reason);
        restoreThermalSimulationForReset();
    }
    if (serv != IO_OBJECT_NULL) {
        NSMutableDictionary* props = [NSMutableDictionary new];
        props[@"IsCharging"] = @YES;
        props[@"PredictiveChargingInhibit"] = @NO;
        props[@"ExternalConnected"] = @YES;
        IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props);
    }
    restoreInflowOverrideForReset();
    g_chargeCommandEnabled = YES;
    g_lastChargeCommandTs = now;
    g_lastInflowCommandTs = now;
    resetHoldSessionState();
    clearPredictiveInhibitFallbackRuntimeState();
    g_policyState = @"battery";
    g_policyReason = reason ?: @"reset";
    g_lastPolicyChangeReason = g_policyReason;
    g_lastPolicyChangeTs = now;
}

static void performAcccharge(BOOL flag) {
    static NSMutableDictionary* cache_status = nil;
    BOOL acc_charge = getLocalBool(@"acc_charge", NO);
    BOOL acc_charge_airmode = getLocalBool(@"acc_charge_airmode", NO);
    BOOL acc_charge_wifi = getLocalBool(@"acc_charge_wifi", NO);
    BOOL acc_charge_blue = getLocalBool(@"acc_charge_blue", NO);
    BOOL acc_charge_bright = getLocalBool(@"acc_charge_bright", NO);
    BOOL acc_charge_lpm = getLocalBool(@"acc_charge_lpm", NO);
    if (acc_charge) {
        if (flag) { // 修改状态
            // 幂等守卫：充电态稳态重申路径每个电池事件都会调用 performAcccharge(YES)，
            // cache_status != nil 时直接 return，避免覆盖亮度缓存并重复写系统开关。
            // 这也是 userspace 重启后已插电稳态首次应用加速项的兜底入口：
            // 稳态重申不依赖 is_adaptor_new_connected 边沿，只要处于充电稳态即补首次应用。
            if (cache_status != nil) {
                return;
            }
            cache_status = [NSMutableDictionary new];
            if (acc_charge_airmode) {
                setAirEnable(YES);
            }
            if (acc_charge_wifi) {
                setWiFiEnable(NO); // todo 支持16
            }
            if (acc_charge_blue) {
                setBlueEnable(NO);
            }
            if (acc_charge_bright) {
                float val = getBrightness();
                cache_status[@"acc_charge_bright"] = @(val);
                if (isAutoBrightEnable()) {
                    setAutoBrightEnable(NO);
                    cache_status[@"acc_charge_bright_auto"] = @YES;
                }
                setBrightness(0.0);
            }
            if (acc_charge_lpm) {
                setLPMEnable(YES);
            }
        } else if (cache_status != nil) { // 还原状态
            if (acc_charge_airmode) {
                setAirEnable(NO);
            }
            if (acc_charge_wifi) {
                setWiFiEnable(YES);
            }
            if (acc_charge_blue) {
                setBlueEnable(YES);
            }
            if (acc_charge_bright) {
                if (cache_status[@"acc_charge_bright"] != nil) {
                    NSNumber* acc_charge_bright = cache_status[@"acc_charge_bright"];
                    setBrightness(acc_charge_bright.floatValue);
                }
                if (cache_status[@"acc_charge_bright_auto"] != nil) {
                    setAutoBrightEnable(YES);
                }
            }
            if (acc_charge_lpm) {
                setLPMEnable(NO);
            }
            cache_status = nil;
        }
    }
}

static NSString* getMsgForLang(NSString* msgid, NSString* lang) {
    static NSDictionary* messages = nil;
    if (messages == nil) {
        NSString* bundlePath = [getSelfExePath() stringByDeletingLastPathComponent];
        NSString* langPath = [bundlePath stringByAppendingString:@"/lang.json"];
        NSData* data = [NSData dataWithContentsOfFile:langPath];
        messages = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
    if (messages[lang] == nil) {
        lang = @"en";
    }
    NSString* msg = messages[lang][msgid];
    if (msg.length == 0 && ![lang isEqualToString:@"en"]) {
        msg = messages[@"en"][msgid];
    }
    return msg;
}

static BOOL notificationsEnabled() {
    return [getLocalString(@"action", @"") isEqualToString:@"noti"];
}

static NSString* notificationKeyForMessageID(NSString* msgid) {
    if ([msgid isEqualToString:@"noti_start_charge"]) {
        return @"start_charge";
    }
    if ([msgid isEqualToString:@"noti_stop_charge_capacity"]) {
        return @"stop_charge_capacity";
    }
    if ([msgid isEqualToString:@"noti_stop_charge_temperature"]) {
        return @"stop_charge_temperature";
    }
    if ([msgid isEqualToString:@"noti_resume_charge_temperature"]) {
        return @"resume_charge_temperature";
    }
    return nil;
}

static NSString* identifierForNotificationKey(NSString* key) {
    if (key.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"com.chargelimiter.noti.%@", key];
}

static BOOL shouldSendNotificationForKey(NSString* key) {
    static NSMutableDictionary<NSString*, NSNumber*>* lastSentTsByKey = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lastSentTsByKey = [NSMutableDictionary dictionary];
    });

    if (key.length == 0) {
        return NO;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval cooldown = 5.0;
    NSNumber* lastSent = lastSentTsByKey[key];
    if (lastSent != nil && (now - lastSent.doubleValue) < cooldown) {
        return NO;
    }
    lastSentTsByKey[key] = @(now);
    return YES;
}

static NSString* notificationMessageIDForChargeCommandTransition(BOOL previousExternalConnected,
                                                                 BOOL currentExternalConnected,
                                                                 BOOL previousEnabled,
                                                                 BOOL currentEnabled,
                                                                 NSString* previousState,
                                                                 NSString* currentState,
                                                                 NSString* previousReason,
                                                                 NSString* reason) {
    BOOL freshPlug = (!previousExternalConnected && currentExternalConnected);
    BOOL stillPlugged = (previousExternalConnected && currentExternalConnected);

    if (freshPlug) {
        // iOS 17 禁流态 freshPlug 门禁兜底：禁流稳态下 ExternalConnected/ExternalChargeCapable 派生值抖动
        // 会制造伪插电边沿（previousExternalConnected 因禁流被读成 false、current 被系统刷新回 true）。
        // 此时充电线未动，不应误发 noti_start_charge。当前或上一轮处于禁流态时抑制此 freshPlug。
        // 热控恢复（temperature_recovered）走下方 stillPlugged 分支发 noti_resume_charge_temperature，不受影响。
        if (isInflowGuardActive(NO, currentState) || isInflowGuardActive(NO, previousState)) {
            return nil;
        }
        if ([currentState isEqualToString:@"charging"]) {
            return @"noti_start_charge";
        }
        return nil;
    }

    if (!stillPlugged) {
        return nil;
    }

    if (previousEnabled == currentEnabled) {
        return nil;
    }

    if (!currentEnabled) {
        if ([reason isEqualToString:@"temperature_high"]) {
            return @"noti_stop_charge_temperature";
        }
        if ([@[@"capacity_high", @"hold_target_reached"] containsObject:reason]) {
            return @"noti_stop_charge_capacity";
        }
        return nil;
    }

    BOOL resumedFromTempPause = [previousReason isEqualToString:@"temperature_high"] ||
                                [previousState isEqualToString:@"temp_paused"];
    if ([reason isEqualToString:@"temperature_recovered"] && resumedFromTempPause) {
        return @"noti_resume_charge_temperature";
    }
    if ([@[@"capacity_low", @"critical_low_battery", @"full_charge_window"] containsObject:reason]) {
        return @"noti_start_charge";
    }
    return nil;
}

static void notifyForChargeCommandTransition(BOOL previousExternalConnected,
                                             BOOL currentExternalConnected,
                                             BOOL previousEnabled,
                                             BOOL currentEnabled,
                                             NSString* previousState,
                                             NSString* currentState,
                                             NSString* previousReason,
                                             NSString* reason) {
    if (!notificationsEnabled()) {
        return;
    }
    NSString* msgid = notificationMessageIDForChargeCommandTransition(previousExternalConnected,
                                                                      currentExternalConnected,
                                                                      previousEnabled,
                                                                      currentEnabled,
                                                                      previousState,
                                                                      currentState,
                                                                      previousReason,
                                                                      reason);
    if (msgid.length == 0) {
        return;
    }
    NSString* notificationKey = notificationKeyForMessageID(msgid);
    if (!shouldSendNotificationForKey(notificationKey)) {
        return;
    }
    NSString* lang = getLocalString(@"lang", @"en");
    NSString* msg = getMsgForLang(msgid, lang);
    if (msg.length == 0) {
        return;
    }
    [Service.inst localPush:@PRODUCT msg:msg identifier:identifierForNotificationKey(notificationKey)];
}

static sqlite3* db = NULL;

// ---------------------------------------------------------------------------
// sqlite 全局句柄锁：所有对 `db` 的访问必须经由同一把可重入锁串行。
// 背景：真机崩溃（EXC_BAD_ACCESS，故障地址 0x61746164 == "data"）——
// http 并发队列的 get_statistics/get_bat_info 读 + battery 事件写 +
// reload_conf/app_docs 的 uninitDB+initDB 关重开，同时操作同一连接，
// 其中一个线程释放连接后，另一线程 prepare/step 读到被字符串覆写的悬垂指针。
// 系统 libsqlite3 为 THREADSAFE=2（multi-thread），同一连接本就不允许跨线程并发。
// 相关函数如 insertPolicyEventDBData->prune、migrate->insert 等存在互相嵌套调用，
// 故用 PTHREAD_MUTEX_RECURSIVE；CL_DB_GUARD 借 cleanup 保证任何 return 路径都解锁。
// ---------------------------------------------------------------------------
static pthread_mutex_t g_dbMutex;
static pthread_once_t g_dbMutexOnce = PTHREAD_ONCE_INIT;
static void clDbMutexInit(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_dbMutex, &attr);
    pthread_mutexattr_destroy(&attr);
}
static void clDbLock(void) {
    pthread_once(&g_dbMutexOnce, clDbMutexInit);
    pthread_mutex_lock(&g_dbMutex);
}
static void clDbUnlock(void) {
    pthread_mutex_unlock(&g_dbMutex);
}
typedef struct CLDbLockGuard { char _pad; } CLDbLockGuard;
static void CLDbLockGuardCleanup(CLDbLockGuard* guard) {
    (void)guard;
    clDbUnlock();
}
#define CL_DB_GUARD()                                                               \
    CLDbLockGuard cl_db_guard __attribute__((cleanup(CLDbLockGuardCleanup)));       \
    clDbLock()

static NSSet<NSString*>* allowedStatsTableSuffixes() {
    static NSSet<NSString*>* set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[@"min5", @"hour", @"day", @"month"]];
    });
    return set;
}

static BOOL isSafeTableToken(NSString* token) {
    if (token.length == 0 || token.length > 64) {
        return NO;
    }
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    return [token rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

static NSString* sanitizeTableToken(NSString* token) {
    if (![token isKindOfClass:[NSString class]] || token.length == 0) {
        return nil;
    }
    NSMutableString* out = [NSMutableString stringWithCapacity:token.length];
    for (NSUInteger i = 0; i < token.length; i++) {
        unichar c = [token characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        [out appendFormat:@"%c", ok ? (char)c : '_'];
    }
    if (out.length == 0 || out.length > 64) {
        return nil;
    }
    return out;
}

static BOOL isAllowedStatsTableName(NSString* tblName) {
    if (![tblName isKindOfClass:[NSString class]] || tblName.length == 0 || tblName.length > 140) {
        return NO;
    }
    NSArray<NSString*>* parts = [tblName componentsSeparatedByString:@"."];
    if (parts.count == 1) {
        return [allowedStatsTableSuffixes() containsObject:parts[0]];
    }
    if (parts.count == 2) {
        NSString* prefix = parts[0];
        NSString* suffix = parts[1];
        return isSafeTableToken(prefix) && [allowedStatsTableSuffixes() containsObject:suffix];
    }
    return NO;
}

static NSString* quoteSQLiteIdent(NSString* ident) {
    if (ident.length == 0) {
        return nil;
    }
    NSString* escaped = [ident stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static NSString* tableNameForSuffix(NSString* suffix, NSString* batId) {
    if (![allowedStatsTableSuffixes() containsObject:suffix]) {
        return nil;
    }
    if (batId.length == 0) {
        return suffix;
    }
    NSString* prefix = sanitizeTableToken(batId);
    if (prefix.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@.%@", prefix, suffix];
}

static NSString* policyEventDBTableNameQuoted(void) {
    return quoteSQLiteIdent(kPolicyEventDBTableName);
}

static BOOL historyStatsEnabled(void) {
    return getLocalBool(@"history_stats_enabled", YES);
}

static void updateDBData(NSString* tbl, int tid, NSDictionary* info) {
    CL_DB_GUARD();
    @autoreleasepool {
        if (!db) {
            return;
        }
        if (!isAllowedStatsTableName(tbl)) {
            return;
        }
        NSData* jdata = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
        if (jdata == nil) {
            return;
        }
        NSString* jstr = [[NSString alloc] initWithData:jdata encoding:NSUTF8StringEncoding];
        NSString* quotedTbl = quoteSQLiteIdent(tbl);
        if (quotedTbl.length == 0) {
            return;
        }
        NSString* sql = [NSString stringWithFormat:@"insert or ignore into %@ values(?1, ?2)", quotedTbl];
        sqlite3_stmt* stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
            return;
        }
        sqlite3_bind_int(stmt, 1, tid);
        sqlite3_bind_text(stmt, 2, jstr.UTF8String, -1, SQLITE_STATIC);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

static void prunePolicyEventDBIfNeeded(void) {
    CL_DB_GUARD(); // insertPolicyEventDBData 嵌套调用，可重入
    if (!db) {
        return;
    }
    NSString* quotedTbl = policyEventDBTableNameQuoted();
    if (quotedTbl.length == 0) {
        return;
    }
    NSString* sql = [NSString stringWithFormat:
                     @"delete from %@ where id not in (select id from %@ order by id desc limit %lu)",
                     quotedTbl,
                     quotedTbl,
                     (unsigned long)kPolicyEventDBLimit];
    char* err = NULL;
    sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err);
    if (err != NULL) {
        sqlite3_free(err);
    }
}

static void insertPolicyEventDBData(NSDictionary* event) {
    CL_DB_GUARD();
    @autoreleasepool {
        if (!db || ![event isKindOfClass:[NSDictionary class]] || event.count == 0) {
            return;
        }
        NSData* jdata = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        if (jdata == nil) {
            return;
        }
        NSString* jstr = [[NSString alloc] initWithData:jdata encoding:NSUTF8StringEncoding];
        if (jstr.length == 0) {
            return;
        }
        NSString* quotedTbl = policyEventDBTableNameQuoted();
        if (quotedTbl.length == 0) {
            return;
        }
        NSString* eventType = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"policy_transition";
        sqlite3_int64 ts = [event[@"ts"] respondsToSelector:@selector(longLongValue)] ? [event[@"ts"] longLongValue] : (sqlite3_int64)time(0);
        NSString* sql = [NSString stringWithFormat:@"insert into %@ (ts, type, data) values(?1, ?2, ?3)", quotedTbl];
        sqlite3_stmt* stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
            return;
        }
        sqlite3_bind_int64(stmt, 1, ts);
        sqlite3_bind_text(stmt, 2, eventType.UTF8String, -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 3, jstr.UTF8String, -1, SQLITE_STATIC);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        prunePolicyEventDBIfNeeded();
    }
}

static void initDB(NSString* batId) {
    CL_DB_GUARD();
    @autoreleasepool {
        if (!db) {
            sqlite3* cdb = NULL;
            NSString* dbPath = getDbPath();
            if (dbPath.length == 0) {
                return;
            }
            if (sqlite3_open(dbPath.UTF8String, &cdb) != SQLITE_OK) {
                return;
            }
            db = cdb;
        }
        if (db) {
            NSString* eventTbl = policyEventDBTableNameQuoted();
            if (eventTbl.length > 0) {
                NSString* createEventTableSQL = [NSString stringWithFormat:@"create table if not exists %@ (id integer primary key autoincrement, ts integer not null, type text not null, data text not null)", eventTbl];
                NSString* createEventIndexSQL = [NSString stringWithFormat:@"create index if not exists %@ on %@ (ts)", quoteSQLiteIdent(@"policy_events_ts_idx"), eventTbl];
                char* err = NULL;
                sqlite3_exec(db, createEventTableSQL.UTF8String, NULL, NULL, &err);
                if (err != NULL) {
                    sqlite3_free(err);
                }
                err = NULL;
                sqlite3_exec(db, createEventIndexSQL.UTF8String, NULL, NULL, &err);
                if (err != NULL) {
                    sqlite3_free(err);
                }
            }
            for (NSString* rawTbl in @[@"min5", @"hour", @"day", @"month"]) {
                NSString* tblName = tableNameForSuffix(rawTbl, batId);
                if (tblName.length == 0 || !isAllowedStatsTableName(tblName)) {
                    continue;
                }
                NSString* sql = [NSString stringWithFormat:@"create table if not exists %@ (id integer primary key, data text)", quoteSQLiteIdent(tblName)];
                char* err = NULL;
                sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err);
                if (err != NULL) {
                    sqlite3_free(err);
                }
            }
        }
    }
}

static void uninitDB() {
    CL_DB_GUARD();
    if (db != NULL) {
        int rc = sqlite3_close(db);
        if (rc != SQLITE_OK) {
            sqlite3_close_v2(db);
        }
        db = NULL;
    }
}

static NSArray* getPolicyEventDBData(int n, int last_id) {
    CL_DB_GUARD();
    @autoreleasepool {
        if (!db) {
            return @[];
        }
        if (n < 1) {
            n = 1;
        }
        if (n > (int)kPolicyEventDBLimit) {
            n = (int)kPolicyEventDBLimit;
        }
        NSMutableArray* result = [NSMutableArray array];
        NSString* quotedTbl = policyEventDBTableNameQuoted();
        if (quotedTbl.length == 0) {
            return @[];
        }
        NSString* sql = [NSString stringWithFormat:@"select id, ts, type, data from %@ where id > ?1 order by id desc limit ?2", quotedTbl];
        sqlite3_stmt* stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
            return @[];
        }
        sqlite3_bind_int(stmt, 1, MAX(last_id, 0));
        sqlite3_bind_int(stmt, 2, n);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int rowID = sqlite3_column_int(stmt, 0);
            sqlite3_int64 ts = sqlite3_column_int64(stmt, 1);
            const char* typeText = (const char*)sqlite3_column_text(stmt, 2);
            const char* jstr = (const char*)sqlite3_column_text(stmt, 3);
            NSMutableDictionary* jobj = nil;
            if (jstr != NULL) {
                NSData* jdata = [NSData dataWithBytes:(void*)jstr length:strlen(jstr)];
                NSDictionary* parsed = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:nil];
                if ([parsed isKindOfClass:[NSDictionary class]]) {
                    jobj = [parsed mutableCopy];
                }
            }
            if (jobj == nil) {
                jobj = [NSMutableDictionary dictionary];
            }
            jobj[@"id"] = @(rowID);
            if (jobj[@"ts"] == nil) {
                jobj[@"ts"] = @(ts);
            }
            if (typeText != NULL && jobj[@"type"] == nil) {
                jobj[@"type"] = @(typeText);
            }
            [result addObject:jobj];
        }
        sqlite3_finalize(stmt);
        return [[result reverseObjectEnumerator] allObjects];
    }
}

static void migrateStoredPolicyEventsToDBIfNeeded(NSArray* history) {
    CL_DB_GUARD(); // 内部会调 insertPolicyEventDBData，可重入
    if (!db || ![history isKindOfClass:[NSArray class]] || history.count == 0) {
        return;
    }
    NSString* quotedTbl = policyEventDBTableNameQuoted();
    if (quotedTbl.length == 0) {
        return;
    }
    NSString* sql = [NSString stringWithFormat:@"select count(1) from %@", quotedTbl];
    sqlite3_stmt* stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
        return;
    }
    int rowCount = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        rowCount = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    if (rowCount > 0) {
        return;
    }
    for (id item in history) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        insertPolicyEventDBData(item);
    }
}

static NSArray* getDBData(NSString* tbl, int n, int last_id) {
    CL_DB_GUARD();
    @autoreleasepool {
        if (!db) {
            return @[];
        }
        if (!isAllowedStatsTableName(tbl)) {
            return @[];
        }
        if (n < 1) {
            n = 1;
        }
        if (n > 1000) {
            n = 1000;
        }
        NSMutableArray* result = [NSMutableArray array];
        NSString* quotedTbl = quoteSQLiteIdent(tbl);
        if (quotedTbl.length == 0) {
            return @[];
        }
        NSString* sql = [NSString stringWithFormat:@"select data from %@ where id > %d order by id desc limit %d", quotedTbl, last_id, n];
        sqlite3_stmt* stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
            return @[];
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char* jstr = (const char*)sqlite3_column_text(stmt, 0);
            if (jstr == NULL) {
                continue;
            }
            NSData* jdata = [NSData dataWithBytes:(void*)jstr length:strlen(jstr)];
            NSDictionary* jobj = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:nil];
            if (jobj == nil) {
                continue;
            }
            [result addObject:jobj];
        }
        NSArray* result_ = [[result reverseObjectEnumerator] allObjects]; // order by id desc
        sqlite3_finalize(stmt);
        return result_;
    }
}

static NSMutableDictionary* getFilteredMDic(NSDictionary* dic, NSArray* filter) {
    NSMutableDictionary* mdic = [NSMutableDictionary new];
    for (NSString* key in filter) {
        if (dic[key] != nil) {
            mdic[key] = dic[key];
        }
    }
    return mdic;
}

static void updateStatistics() {
    // 主开关关闭（master-off B5）：非驻留形态不写历史统计，「所有功能禁用」包含数据采集。
    if (!g_enable) {
        return;
    }
    if (!historyStatsEnabled()) {
        return;
    }
    int ts = (int)time(0);
    NSDictionary* info_h = nil;
    NSDictionary* info_d = nil;
    info_h = getFilteredMDic(bat_info, @[
        @"Amperage", @"AppleRawCurrentCapacity", @"CurrentCapacity", @"ExternalChargeCapable", @"ExternalConnected",
        @"InstantAmperage", @"IsCharging", @"Temperature", @"UpdateTime", @"Voltage"
    ]);
    updateDBData(@"min5", ts / 300, info_h);
    updateDBData(@"hour", ts / 3600, info_h);
    info_d = getFilteredMDic(bat_info, @[
        @"CycleCount", @"DesignCapacity", @"NominalChargeCapacity", @"UpdateTime"
    ]);
    updateDBData(@"day", ts / 86400, info_d);
    updateDBData(@"month", ts / 2592000, info_d);
    if (gUPSPS != nil && gUPSPS.props[@"Serial"] != nil && gUPSPS.props[@"UpdateTime"] != nil) {
        NSString* batId = gUPSPS.props[@"Serial"];
        NSString* tblMin5 = tableNameForSuffix(@"min5", batId);
        info_h = getFilteredMDic(gUPSPS.props, @[
            @"Amperage", @"AppleRawCurrentCapacity", @"CurrentCapacity", @"IncomingCurrent", @"IncomingVoltage", @"IsCharging", @"Temperature", @"UpdateTime", @"Voltage"
        ]);
        updateDBData(tblMin5, ts / 300, info_h);
        NSString* tblHour = tableNameForSuffix(@"hour", batId);
        updateDBData(tblHour, ts / 3600, info_h);
        info_d = getFilteredMDic(gUPSPS.props, @[
            @"CycleCount", @"MaxCapacity", @"NominalCapacity", @"UpdateTime"
        ]);
        NSString* tblDay = tableNameForSuffix(@"day", batId);
        updateDBData(tblDay, ts / 86400, info_d);
        NSString* tblMonth = tableNameForSuffix(@"month", batId);
        updateDBData(tblMonth, ts / 2592000, info_d);
    }
}

static void clearStatisticsTablesForBattery(NSString* batId) {
    CL_DB_GUARD(); // clearAllStatisticsData 内部调用，可重入
    if (!db) {
        return;
    }
    for (NSString* suffix in @[@"min5", @"hour", @"day", @"month"]) {
        NSString* tblName = tableNameForSuffix(suffix, batId);
        if (tblName.length == 0 || !isAllowedStatsTableName(tblName)) {
            continue;
        }
        NSString* quotedTbl = quoteSQLiteIdent(tblName);
        if (quotedTbl.length == 0) {
            continue;
        }
        NSString* sql = [NSString stringWithFormat:@"delete from %@", quotedTbl];
        char* err = NULL;
        sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err);
        if (err != NULL) {
            sqlite3_free(err);
        }
    }
}

static void clearAllStatisticsData(void) {
    CL_DB_GUARD();
    clearStatisticsTablesForBattery(nil);
    NSString* serial = [gUPSPS.props[@"Serial"] isKindOfClass:[NSString class]] ? gUPSPS.props[@"Serial"] : nil;
    if (serial.length > 0) {
        clearStatisticsTablesForBattery(serial);
    }
    g_policyEventHistory = @[];
    persistPolicyEventHistory();
    NSString* quotedTbl = policyEventDBTableNameQuoted();
    if (db && quotedTbl.length > 0) {
        NSString* sql = [NSString stringWithFormat:@"delete from %@", quotedTbl];
        char* err = NULL;
        sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err);
        if (err != NULL) {
            sqlite3_free(err);
        }
    }
}

static void onBatteryEventEnd() {
    // 原版语义：thermal 模式只在命令边沿/配置变更时写入，电池事件流不参与。
    // 锁屏期读数塌陷正是 v1.15.x 闭环同步自取消限流的根因，已整体退回命令驱动。
}

static NSSet* gConfBoolKeys = nil;
static NSSet* gConfIntKeys = nil;
static NSSet* gConfFloatKeys = nil;
static NSSet* gConfStringKeys = nil;

static void initConfKeySets() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gConfBoolKeys = [NSSet setWithArray:@[
            @"enable",
            @"disable_smart_charge",
            @"enable_temp",
            @"acc_charge",
            @"acc_charge_airmode",
            @"acc_charge_wifi",
            @"acc_charge_blue",
            @"acc_charge_bright",
            @"acc_charge_lpm",
            @"floatwnd_auto",
            @"adv_prefer_smart",
            @"adv_predictive_inhibit_charge",
            @"adv_system_capacity_control_at_100",
            @"adv_disable_inflow",
            @"adv_hold_enabled",
            @"adv_hold_temp_disable_smart_charge",
            @"adv_limit_inflow",
            @"adv_thermal_mode_lock",
            @"full_charge_sched_enabled",
            @"history_stats_enabled"
        ]];
        gConfIntKeys = [NSSet setWithArray:@[
            @"charge_below",
            @"charge_above",
            @"temp_mode",
            @"update_freq",
            @"adv_hold_band",
            @"adv_hold_check_interval_minutes",
            @"full_charge_sched_interval_days",
            @"full_charge_sched_start_minute",
            @"full_charge_sched_duration_hours",
            @"full_charge_sched_next_ts"
        ]];
        gConfFloatKeys = [NSSet setWithArray:@[
            @"charge_temp_below",
            @"charge_temp_above"
        ]];
        gConfStringKeys = [NSSet setWithArray:@[
            @"mode",
            @"lang",
            @"action",
            @"adv_hold_behavior",
            @"adv_limit_inflow_mode",
            @"adv_def_thermal_mode",
            @"full_charge_sched_anchor_date",
            @"log_level"
        ]];
    });
}

static void setConfigValueForKey(NSString* key, id val) {
    if (key.length == 0) {
        return;
    }
    initConfKeySets();
    if ([gConfBoolKeys containsObject:key]) {
        setLocalBool(key, [val boolValue]);
        return;
    }
    if ([gConfIntKeys containsObject:key]) {
        setLocalInt(key, [val intValue]);
        return;
    }
    if ([gConfFloatKeys containsObject:key]) {
        setLocalFloat(key, [val floatValue]);
        return;
    }
    if ([gConfStringKeys containsObject:key]) {
        NSString* str = nil;
        if ([val isKindOfClass:[NSString class]]) {
            str = (NSString*)val;
        } else if (val != nil) {
            str = [val description];
        } else {
            str = @"";
        }
        setLocalString(key, str);
        return;
    }
    if ([val isKindOfClass:[NSArray class]]) {
        setLocalArray(key, (NSArray*)val);
        return;
    }
    if ([val isKindOfClass:[NSDictionary class]]) {
        setLocalDict(key, (NSDictionary*)val);
        return;
    }
    if (val != nil) {
        setLocalString(key, [val description]);
    } else {
        setLocalString(key, @"");
    }
}

static float getTempAsC(NSString* key) {
    int temp_mode = getLocalInt(@"temp_mode", 0);
    float temp_c = getLocalFloat(key, 0.0f);
    if (temp_mode == 0) { // °C
        return temp_c;
    } else if (temp_mode == 1) { // °F
        float temp_f = (temp_c - 32) / 1.8;
        return temp_f;
    }
    return 0;
}

static int getEffectiveBatteryCurrent(NSDictionary* info) {
    id instant = info[@"InstantAmperage"];
    if ([instant respondsToSelector:@selector(intValue)]) {
        return [instant intValue];
    }
    id amp = info[@"Amperage"];
    if ([amp respondsToSelector:@selector(intValue)]) {
        return [amp intValue];
    }
    return 0;
}

static BOOL currentLooksCharging(int current) {
    return current > kHoldCurrentChargeThresholdmA;
}

static BOOL currentLooksDischarging(int current) {
    return current < kHoldCurrentDischargeThresholdmA;
}

static BOOL hasPotentialExternalPowerSignal(NSDictionary* info) {
    NSDictionary* safeInfo = info ?: @{};
    if ([safeInfo[@"ExternalConnected"] boolValue] ||
        [safeInfo[@"ExternalChargeCapable"] boolValue] ||
        safeInfo[@"AdapterDetails"] != nil ||
        [safeInfo[@"IsCharging"] boolValue]) {
        return YES;
    }
    return currentLooksCharging(getEffectiveBatteryCurrent(safeInfo));
}

static BOOL isDisableInflowRetryEligible(NSDictionary* info, NSString* policyState) {
    if (!g_enable || !getLocalBool(@"adv_disable_inflow", NO)) {
        return NO;
    }
    NSDictionary* safeInfo = info ?: @{};
    NSNumber* capacity = safeInfo[@"CurrentCapacity"];
    if (![capacity respondsToSelector:@selector(intValue)]) {
        return NO;
    }
    time_t now = time(0);
    int chargeAbove = getLocalInt(@"charge_above", 100);
    BOOL fullChargeWindowActive = isFullChargeWindowActive(now, nil, nil);
    if (fullChargeWindowActive) {
        chargeAbove = 100;
    }
    if (fullChargeWindowActive || shouldDisableCapacityControlForTarget(chargeAbove)) {
        return NO;
    }
    if (capacity.intValue < chargeAbove) {
        return NO;
    }
    NSString* safePolicyState = policyState ?: g_policyState ?: @"";
    return ![safePolicyState isEqualToString:@"no_inflow"];
}

static int getHoldModeLowerBound(int target) {
    return MAX(5, target - getHoldModeBand());
}

static NSDictionary* storedSmartChargeCoordinationState(void) {
    NSDictionary* state = getLocalDict(kSmartChargeCoordinationStateKey, @{});
    if (![state isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    return state;
}

static void clearLoadedSmartChargeCoordinationRuntimeState(void) {
    g_tempSmartChargeDisabledByCL = NO;
    g_smartChargeCoordinationOriginalStatus = -1;
    g_smartChargeCoordinationSessionID = nil;
    g_smartChargeCoordinationStartedTs = 0;
}

static void persistSmartChargeCoordinationRuntimeState(void) {
    if (!g_tempSmartChargeDisabledByCL || g_smartChargeCoordinationSessionID.length == 0) {
        setLocalDict(kSmartChargeCoordinationStateKey, @{});
        return;
    }
    setLocalDict(kSmartChargeCoordinationStateKey, @{
        @"active": @YES,
        @"original_status": @(g_smartChargeCoordinationOriginalStatus),
        @"session_id": g_smartChargeCoordinationSessionID,
        @"started_ts": @(g_smartChargeCoordinationStartedTs),
    });
}

static void loadSmartChargeCoordinationRuntimeState(void) {
    NSDictionary* state = storedSmartChargeCoordinationState();
    if (![state[@"active"] boolValue]) {
        clearLoadedSmartChargeCoordinationRuntimeState();
        return;
    }
    NSString* sessionID = [state[@"session_id"] isKindOfClass:[NSString class]] ? state[@"session_id"] : nil;
    if (sessionID.length == 0) {
        clearLoadedSmartChargeCoordinationRuntimeState();
        setLocalDict(kSmartChargeCoordinationStateKey, @{});
        return;
    }
    g_tempSmartChargeDisabledByCL = YES;
    g_smartChargeCoordinationOriginalStatus = [state[@"original_status"] respondsToSelector:@selector(intValue)] ? [state[@"original_status"] intValue] : -1;
    g_smartChargeCoordinationSessionID = sessionID;
    g_smartChargeCoordinationStartedTs = [state[@"started_ts"] respondsToSelector:@selector(longLongValue)] ? (time_t)[state[@"started_ts"] longLongValue] : 0;
}

static NSString* newSmartChargeCoordinationSessionID(time_t now) {
    if (now <= 0) {
        now = time(0);
    }
    return [NSString stringWithFormat:@"%d-%lld-%u", getpid(), (long long)now, arc4random_uniform(1000000)];
}

static void beginSmartChargeCoordinationSession(int originalStatus, time_t now) {
    if (now <= 0) {
        now = time(0);
    }
    g_tempSmartChargeDisabledByCL = YES;
    g_smartChargeCoordinationOriginalStatus = originalStatus;
    g_smartChargeCoordinationSessionID = newSmartChargeCoordinationSessionID(now);
    g_smartChargeCoordinationStartedTs = now;
    persistSmartChargeCoordinationRuntimeState();
}

static void endSmartChargeCoordinationSession(void) {
    clearLoadedSmartChargeCoordinationRuntimeState();
    persistSmartChargeCoordinationRuntimeState();
}

static void finishSmartChargeCoordinationSessionWithObservedStatus(int observedStatus,
                                                                  NSString* reason,
                                                                  NSDictionary* info,
                                                                  time_t now) {
    if (!g_tempSmartChargeDisabledByCL) {
        return;
    }
    if (observedStatus >= 0 && observedStatus != 3) {
        appendSmartChargeCoordinationEvent(@"smart_charge_session_released",
                                           3,
                                           observedStatus,
                                           info,
                                           @{
                                               @"trigger": reason ?: @"",
                                           },
                                           now > 0 ? now : time(0));
    }
    endSmartChargeCoordinationSession();
}

static BOOL shouldRestoreSmartChargeAfterCoordination(void) {
    return g_smartChargeCoordinationOriginalStatus > 0;
}

static void tryRestoreSmartChargeAfterCoordination(NSString* reason) {
    if (!g_tempSmartChargeDisabledByCL) {
        return;
    }
    verifyBundleStillInstalledForCurrentMode();
    if (g_smartChargeStatus < 0) {
        g_smartChargeStatus = getSmartChargeStatus();
    }
    if (g_smartChargeStatus >= 0 && g_smartChargeStatus != 3) {
        finishSmartChargeCoordinationSessionWithObservedStatus(g_smartChargeStatus, reason, nil, time(0));
        return;
    }
    if (g_smartChargeStatus == 3 && shouldRestoreSmartChargeAfterCoordination()) {
        int fromStatus = g_smartChargeStatus;
        setSmartChargeEnable(YES);
        g_smartChargeStatus = getSmartChargeStatus();
        appendSmartChargeCoordinationEvent(@"smart_charge_restored",
                                           fromStatus,
                                           g_smartChargeStatus,
                                           nil,
                                           @{
                                               @"trigger": reason ?: @"",
                                           },
                                           time(0));
    }
    if (g_smartChargeStatus != 3) {
        endSmartChargeCoordinationSession();
    }
}

// 完整还原系统优化充电与充电控制残留（App「还原系统优化充电」入口 / CLI restore）。
// 与 reset 路径的差异：不依赖本地 disable_smart_charge 配置，无条件强制重新打开
// 系统优化充电，并清除本地「永久停用」配置——否则 daemon 会在下一个电池事件
// 按旧配置立即重新停用，还原无效。
static NSDictionary* performFullSmartChargeRestore(NSString* reason) {
    loadSmartChargeCoordinationRuntimeState();
    BOOL sessionCleared = g_tempSmartChargeDisabledByCL;
    if (sessionCleared) {
        endSmartChargeCoordinationSession();
    }
    int beforeStatus = getSmartChargeStatus();
    BOOL clearedPermanentDisable = getLocalBool(@"disable_smart_charge", NO);
    if (clearedPermanentDisable) {
        setLocalBool(@"disable_smart_charge", NO);
    }
    setSmartChargeEnable(YES);
    // iOS 17+：完整还原含 MCL（80% 限制开关）——恢复永久停用前记住的状态。
    restoreMCLStateAfterEnable();
    int afterStatus = getSmartChargeStatus();
    restoreInflowOverrideForReset();
    io_service_t serv = getIOPMPSServ();
    if (serv != IO_OBJECT_NULL) {
        NSMutableDictionary* props = [NSMutableDictionary new];
        props[@"IsCharging"] = @YES;
        props[@"PredictiveChargingInhibit"] = @NO;
        props[@"ExternalConnected"] = @YES;
        IORegistryEntrySetCFProperties(serv, (__bridge CFTypeRef)props);
    }
    restoreThermalSimulationForReset();
    // spec『还原的对象与语义』第 6 条：还原加速充电项。daemon 存活时按内存缓存
    // 还原（performAcccharge 的幂等守卫保证安全）；CLI/崩溃残留场景缓存为空，
    // performAcccharge(NO) 为无害 no-op。
    restoreAcceleratedChargeStateForReset();
    appendSmartChargeCoordinationEvent(@"smart_charge_restored",
                                       beforeStatus,
                                       afterStatus,
                                       nil,
                                       @{
                                           @"trigger": reason ?: @"",
                                           @"session_cleared": @(sessionCleared),
                                           @"cleared_permanent_disable": @(clearedPermanentDisable),
                                       },
                                       time(0));
    return @{
        @"before_status": @(beforeStatus),
        @"after_status": @(afterStatus),
        @"session_cleared": @(sessionCleared),
        @"cleared_permanent_disable": @(clearedPermanentDisable),
    };
}

static void recoverSmartChargeCoordinationOnBootstrap(void) {
    // 主开关关闭（master-off B5）：非驻留诊断形态不做任何系统写；协调会话残留由
    // 主开关关闭路径的全量还原收尾，这里不得替用户重开/重关系统优化充电。
    if (!g_enable) {
        return;
    }
    loadSmartChargeCoordinationRuntimeState();
    if (!g_tempSmartChargeDisabledByCL) {
        return;
    }
    if (g_smartChargeStatus < 0) {
        g_smartChargeStatus = getSmartChargeStatus();
    }
    if (g_smartChargeStatus < 0) {
        return;
    }
    BOOL permanentlyDisableSmartCharge = getLocalBool(@"disable_smart_charge", NO);
    if (permanentlyDisableSmartCharge) {
        if (g_smartChargeStatus != 0) {
            rememberMCLStateBeforeDisable();
            setSmartChargeEnable(NO);
            disableMCLForPermanentDisable();
            g_smartChargeStatus = getSmartChargeStatus();
        }
        if (g_smartChargeStatus != 3) {
            endSmartChargeCoordinationSession();
        }
        return;
    }
    if (g_smartChargeStatus == 3) {
        NSDictionary* snapshot = nil;
        if (0 == getBatInfo(&snapshot)) {
            applyChargePolicy(nil, snapshot);
            return;
        }
        NSFileErrorLog(@"smart charge bootstrap restore fallback session=%@ original=%d",
                       g_smartChargeCoordinationSessionID ?: @"",
                       g_smartChargeCoordinationOriginalStatus);
        tryRestoreSmartChargeAfterCoordination(@"daemon_bootstrap_recovery");
    } else {
        finishSmartChargeCoordinationSessionWithObservedStatus(g_smartChargeStatus,
                                                              @"daemon_bootstrap_cleanup",
                                                              nil,
                                                              time(0));
    }
}

static BOOL policyNeedsSmartChargeCoordination(NSString* policyState) {
    return [@[@"hold", @"hold_recharge", @"stopped", @"temp_paused", @"no_inflow"] containsObject:policyState ?: @""];
}

static void selfHealSmartChargeOnBootstrap(void) {
    // 主开关关闭（master-off B5）：非驻留形态禁止擅自打开系统优化充电——这正是
    // 「关了总开关高级里还有东西生效」的主路径之一。自愈仅在用户重新打开主开关后
    // 的常驻态执行。
    if (!g_enable) {
        return;
    }
    // 启动自愈：若本地配置已放行(disable_smart_charge=NO)但系统的「优化充电」仍
    // 处于关闭态（常见于旧版永久停用的残留），自动重新打开，让已卡死的用户
    // 装新包重启 daemon 后无需任何手动操作即可恢复。
    BOOL permanentlyDisableSmartCharge = getLocalBool(@"disable_smart_charge", NO);
    if (permanentlyDisableSmartCharge) {
        return;
    }
    if (!isSmartChargeEnable()) {
        setSmartChargeEnable(YES);
        restoreMCLStateAfterEnable();
    }
}

static void syncSmartChargeCoordination(NSDictionary* info, BOOL isAdaptorConnected) {
    g_smartChargeStatus = getSmartChargeStatus();
    if (g_smartChargeStatus < 0) {
        return;
    }

    BOOL permanentlyDisableSmartCharge = getLocalBool(@"disable_smart_charge", NO);
    if (permanentlyDisableSmartCharge) {
        if (g_smartChargeStatus != 0) {
            int fromStatus = g_smartChargeStatus;
            rememberMCLStateBeforeDisable();
            setSmartChargeEnable(NO);
            disableMCLForPermanentDisable();
            g_smartChargeStatus = getSmartChargeStatus();
            appendSmartChargeCoordinationEvent(@"smart_charge_permanently_disabled",
                                               fromStatus,
                                               g_smartChargeStatus,
                                               info,
                                               nil,
                                               time(0));
        }
        if (g_smartChargeStatus != 3) {
            endSmartChargeCoordinationSession();
        }
        return;
    }

    BOOL shouldCoordinate = isAdaptorConnected && isHoldSmartChargeCoordinationEnabled() && policyNeedsSmartChargeCoordination(g_policyState);
    if (shouldCoordinate) {
        if (g_tempSmartChargeDisabledByCL && g_smartChargeStatus != 3) {
            finishSmartChargeCoordinationSessionWithObservedStatus(g_smartChargeStatus,
                                                                  @"coordination_state_changed",
                                                                  info,
                                                                  time(0));
        }
        if (g_smartChargeStatus > 0 && g_smartChargeStatus != 3) {
            int originalStatus = g_smartChargeStatus;
            if (temporarilyDisableSmartCharge()) {
                beginSmartChargeCoordinationSession(originalStatus, time(0));
                g_smartChargeStatus = getSmartChargeStatus();
                appendSmartChargeCoordinationEvent(@"smart_charge_temporarily_disabled",
                                                   originalStatus,
                                                   g_smartChargeStatus,
                                                   info,
                                                   nil,
                                                   time(0));
            }
        }
    } else if (g_tempSmartChargeDisabledByCL) {
        tryRestoreSmartChargeAfterCoordination(@"coordination_exit");
    }
}

static void applyChargePolicy(NSDictionary* oldInfo, NSDictionary* info) {
    NSDictionary* safeInfo = info ?: @{};
    NSDictionary* safeOld = oldInfo ?: safeInfo;
    verifyBundleStillInstalledForCurrentMode();
    time_t now = time(0);
    BOOL previousExternalConnected = isAdaptorConnect(safeOld, @(getLocalBool(@"adv_disable_inflow", NO)));
    BOOL previousChargeCommandEnabled = g_chargeCommandEnabled;
    NSString* previousPolicyState = g_policyState ?: @"battery";
    NSString* previousPolicyReason = g_policyReason ?: @"battery_idle";
    NSString* raw_mode = getLocalString(@"mode", @"charge_on_plug");
    int mode = CL_MODE_PLUG;
    if ([raw_mode isEqualToString:@"edge_trigger"] ||
        (raw_mode.length > 0 && ![raw_mode isEqualToString:@"charge_on_plug"])) {
        setLocalString(@"mode", @"charge_on_plug");
    }
    int charge_below = getLocalInt(@"charge_below", 0);
    int charge_above = getLocalInt(@"charge_above", 100);
    BOOL full_charge_window_active = isFullChargeWindowActive(now, nil, nil);
    if (full_charge_window_active) {
        // 满充计划窗口内只解除电量上限，温控逻辑仍然保留。
        charge_above = 100;
    }
    // 只有在显式选择“100% 交由系统控制”或满充计划临时放开上限时，
    // 才旁路容量控制；否则 100% 也继续由软件参与策略控制。
    BOOL disable_capacity_control = full_charge_window_active || shouldDisableCapacityControlForTarget(charge_above);
    BOOL enable_temp = getLocalBool(@"enable_temp", NO);
    NSNumber* capacity = safeInfo[@"CurrentCapacity"];
    BOOL is_charging = [safeInfo[@"IsCharging"] boolValue];
    BOOL inflow_enabled_snapshot = [safeInfo[@"ExternalConnected"] boolValue];
    BOOL adv_disable_inflow = getLocalBool(@"adv_disable_inflow", NO);
    BOOL adv_hold_enabled = (isHoldModeEnabled() && !adv_disable_inflow);
    BOOL is_adaptor_connected = isAdaptorConnect(safeInfo, @(adv_disable_inflow));
    BOOL is_adaptor_new_connected = isAdaptorNewConnect(safeOld, safeInfo, @(adv_disable_inflow));
    BOOL is_adaptor_new_disconnected = isAdaptorNewDisconnect(safeOld, safeInfo, @(adv_disable_inflow));
    BOOL inflow_runtime_disabled = isInflowRuntimeLikelyDisabled(adv_disable_inflow, inflow_enabled_snapshot, previousPolicyState);
    BOOL has_raw_external_power_signal = hasPotentialExternalPowerSignal(safeInfo);
    NSNumber* temperature_ = safeInfo[@"Temperature"];
    float charge_temp_above = getTempAsC(@"charge_temp_above");
    float charge_temp_below = getTempAsC(@"charge_temp_below");
    float temperature = temperature_.intValue / 100.0;
    int effective_current = getEffectiveBatteryCurrent(safeInfo);
    BOOL current_looks_charging = currentLooksCharging(effective_current);
    BOOL current_looks_discharging = currentLooksDischarging(effective_current);
    (void)current_looks_discharging; // 预留：放电态判定，保留供后续策略分支使用
    BOOL predictive_inhibit_active = [safeInfo[@"PredictiveChargingInhibit"] boolValue];
    if (shouldFallbackFromPredictiveInhibitStop(is_adaptor_connected,
                                                is_charging,
                                                current_looks_charging,
                                                predictive_inhibit_active,
                                                now)) {
        NSDictionary* extras = @{
            @"charge_flag": @NO,
            @"fallback_reason": @"stop_not_reflected",
            @"verify_delay_seconds": @(kPredictiveInhibitFallbackVerifyDelaySeconds),
            @"is_charging": @(is_charging),
            @"current_looks_charging": @(current_looks_charging),
        };
        NSFileErrorLog(@"predictive inhibit stop not reflected after %.1fs, fallback to legacy stop path",
                       kPredictiveInhibitFallbackVerifyDelaySeconds);
        markPredictiveInhibitFallbackActive(@"predictive_inhibit_stop_unconfirmed", safeInfo, extras, now);
        setBatteryStatus(NO);
    }
    BOOL holdCapacityControlActive = (!disable_capacity_control && adv_hold_enabled && is_adaptor_connected);
    if (!holdCapacityControlActive || is_adaptor_new_connected) {
        resetHoldSessionState();
    }
    int hold_lower = getHoldModeLowerBound(charge_above);
    BOOL within_hold_band = (holdCapacityControlActive &&
                             g_holdHasReachedTargetSincePlug &&
                             capacity.intValue > hold_lower &&
                             capacity.intValue < charge_above);
    NSString* nextPolicyState = @"battery";
    NSString* nextPolicyReason = @"battery_idle";
    if (is_adaptor_connected) {
        if (inflow_runtime_disabled) {
            nextPolicyState = @"no_inflow";
            nextPolicyReason = @"no_inflow_active";
        } else if (!g_chargeCommandEnabled || predictive_inhibit_active) {
            nextPolicyState = @"stopped";
            nextPolicyReason = @"stopped_command_or_inhibit";
        } else if (is_charging || current_looks_charging) {
            nextPolicyState = @"charging";
            nextPolicyReason = @"charging_active";
        } else {
            nextPolicyState = @"external_idle";
            nextPolicyReason = @"external_idle";
        }
    }
    // 优先级: 电量极低 > 停充(电量>温度) > 充电(电量>温度) > 插电
    do {
        if (is_adaptor_connected && capacity.intValue <= 5) { // 电量极低,优先级=1
            // 防止误用或意外造成无法充电
            if (is_adaptor_connected && (!g_chargeCommandEnabled || !is_charging || predictive_inhibit_active)) {
                setInflowStatus(YES);
                setBatteryStatus(YES);
                performAcccharge(YES);
            }
            nextPolicyState = @"charging";
            nextPolicyReason = @"critical_low_battery";
            break;
        }
        if (is_adaptor_connected && enable_temp && temperature >= charge_temp_above) { // 停充-温度高,优先级=3
            if (g_chargeCommandEnabled || current_looks_charging) {
                setBatteryStatus(NO);
                performAcccharge(NO);
            }
            if (shouldIssueDisableInflowCommand(adv_disable_inflow, inflow_enabled_snapshot, previousPolicyState)) {
                setInflowStatus(NO);
            }
            nextPolicyState = adv_disable_inflow ? @"no_inflow" : @"temp_paused";
            nextPolicyReason = @"temperature_high";
            break;
        }
        if (is_adaptor_connected && full_charge_window_active) { // 满充计划窗口内，只跳过电量上限控制
            if (is_adaptor_connected && (!g_chargeCommandEnabled || !is_charging || predictive_inhibit_active) && capacity.intValue < 100) {
                if (shouldIssueEnableInflowCommand(adv_disable_inflow, inflow_enabled_snapshot, previousPolicyState)) {
                    setInflowStatus(YES);
                }
                setBatteryStatus(YES);
                performAcccharge(YES);
            }
            nextPolicyState = @"charging";
            nextPolicyReason = @"full_charge_window";
            break;
        }
        if (holdCapacityControlActive) {
            if (capacity.intValue >= charge_above) {
                if (g_chargeCommandEnabled || current_looks_charging) {
                    setBatteryStatus(NO);
                    performAcccharge(NO);
                }
                g_holdHasReachedTargetSincePlug = YES;
                nextPolicyState = @"hold";
                nextPolicyReason = @"hold_target_reached";
                break;
            }
            if (g_holdHasReachedTargetSincePlug) {
                BOOL should_recharge_for_hold = (capacity.intValue <= hold_lower);
                NSString* holdRechargeReason = @"hold_band_lower_reached";
                if (!should_recharge_for_hold && within_hold_band && !g_holdMonitorCheckRequested) {
                    should_recharge_for_hold = NO;
                }
                if (should_recharge_for_hold) {
                    if (!g_chargeCommandEnabled || predictive_inhibit_active || !current_looks_charging) {
                        setBatteryStatus(YES);
                        performAcccharge(YES);
                    }
                    nextPolicyState = @"hold_recharge";
                    nextPolicyReason = holdRechargeReason;
                    break;
                }
                nextPolicyState = (g_chargeCommandEnabled && (is_charging || current_looks_charging)) ? @"hold_recharge" : @"hold";
                nextPolicyReason = [nextPolicyState isEqualToString:@"hold_recharge"] ? @"hold_recharge_active" : @"hold_monitoring";
                break;
            }
        }
        if (is_adaptor_connected && !disable_capacity_control && capacity.intValue >= charge_above) { // 停充-电量高,优先级=2
            // 温控滞回：此前因温度暂停、且温度尚未降到恢复线以下时，归因保持 temp_paused。
            // 否则温度在 charge_temp_above 附近振荡时，状态会在 temp_paused 与
            // stopped/capacity_high 间每个电池事件翻转一次，顶部电池图标跟着跳变
            // （两条路径充电行为相同，都停充，跳的只是状态归因/显示）。
            BOOL temp_hysteresis_active = (enable_temp &&
                                           [previousPolicyState isEqualToString:@"temp_paused"] &&
                                           temperature > charge_temp_below);
            if (g_chargeCommandEnabled || current_looks_charging) {
                setBatteryStatus(NO);
                performAcccharge(NO);
            }
            if (shouldIssueDisableInflowCommand(adv_disable_inflow, inflow_enabled_snapshot, previousPolicyState)) {
                setInflowStatus(NO);
            }
            if (temp_hysteresis_active && !adv_disable_inflow) {
                nextPolicyState = @"temp_paused";
                nextPolicyReason = @"temperature_hysteresis";
                break;
            }
            nextPolicyState = adv_disable_inflow ? @"no_inflow" : @"stopped";
            nextPolicyReason = @"capacity_high";
            break;
        }
        // 温度恢复充电 - 在所有模式下都生效，优先级=4
        // 只有当温度控制开启且当前温度在安全范围内时才考虑恢复
        if (enable_temp && temperature <= charge_temp_below && (!g_chargeCommandEnabled || !is_charging || predictive_inhibit_active)) {
            // 温度已降到安全范围，可以恢复充电
            // 但需要确保电量也在合理范围内（低于上限）
            if (is_adaptor_connected && capacity.intValue < charge_above) {
                if (shouldIssueEnableInflowCommand(adv_disable_inflow, inflow_enabled_snapshot, previousPolicyState)) {
                    setInflowStatus(YES);
                }
                setBatteryStatus(YES);
                performAcccharge(YES);
                nextPolicyState = @"charging";
                nextPolicyReason = @"temperature_recovered";
                break;
            }
        }
        if (is_adaptor_connected && !disable_capacity_control && capacity.intValue <= charge_below) { // 充电-电量低,优先级=5
            // 禁流模式下电量下降后恢复充电
            if (is_adaptor_connected) {
                if (shouldIssueEnableInflowCommand(adv_disable_inflow, inflow_enabled_snapshot, previousPolicyState)) {
                    setInflowStatus(YES);
                }
                setBatteryStatus(YES);
                performAcccharge(YES);
            }
            nextPolicyState = @"charging";
            nextPolicyReason = @"capacity_low";
            break;
        }
        if (is_adaptor_connected && !disable_capacity_control && mode == CL_MODE_PLUG) {
            if (is_adaptor_new_connected) { // 充电-插电,优先级=6
                if (shouldIssueEnableInflowCommand(adv_disable_inflow, inflow_enabled_snapshot, previousPolicyState)) {
                    setInflowStatus(YES);
                }
                setBatteryStatus(YES);
                performAcccharge(YES);
                nextPolicyState = @"charging";
                nextPolicyReason = @"plug_mode_start";
                break;
            }
        }
    } while(false);
    // 稳态重申加速充电状态：充电稳态每个电池事件重申 performAcccharge(YES)。
    // 这是 userspace 重启 / 重越狱后已插电稳态首次应用加速项的兜底入口——
    // 不依赖 is_adaptor_new_connected 边沿（拔→插），也不依赖电量跨阈值，
    // 只要 is_adaptor_connected 且 nextPolicyState==charging 即补首次应用/恢复。
    // performAcccharge 内 cache_status 幂等守卫保证同一会话只真正应用一次。
    // 未插电稳态（is_adaptor_connected==NO）天然不进入，不会开 app 秒进 LPM。
    if (is_adaptor_connected && [nextPolicyState isEqualToString:@"charging"] && !is_adaptor_new_disconnected) {
        performAcccharge(YES);
    }
    if (is_adaptor_new_disconnected) {
        performAcccharge(NO);
        resetHoldSessionState();
        // 拔线清除软件停充抑制：下次插线从干净状态开始，也避免粘滞 YES
        // 在未插电时维持限流模拟。
        g_chargeCommandEnabled = YES;
        nextPolicyState = @"battery";
        nextPolicyReason = @"adaptor_disconnected";
    }
    updatePolicyRuntimeState(nextPolicyState, nextPolicyReason, safeInfo, now);
    notifyForChargeCommandTransition(previousExternalConnected,
                                     is_adaptor_connected,
                                     previousChargeCommandEnabled,
                                     g_chargeCommandEnabled,
                                     previousPolicyState,
                                     nextPolicyState,
                                     previousPolicyReason,
                                     nextPolicyReason);
    BOOL shouldStartDisableInflowRetry = (has_raw_external_power_signal &&
                                          !is_adaptor_new_disconnected &&
                                          isDisableInflowRetryEligible(safeInfo, nextPolicyState));
    armDisableInflowRetryIfNeeded(safeInfo, nextPolicyState, shouldStartDisableInflowRetry);
    syncSmartChargeCoordination(safeInfo, is_adaptor_connected);
}

static void refreshBatteryStateAndApplyPolicy(void) {
    NSDictionary* old_bat_info = bat_info;
    if (0 != getBatInfo(&bat_info)) {
        return;
    }
    updateStatistics();
    if (!g_enable) {
        return;
    }
    applyChargePolicy(old_bat_info, bat_info);
    onBatteryEventEnd();
}

static void evaluateFullChargeSchedule(BOOL forceApply) {
    time_t now = time(0);
    BOOL wasActive = g_fullChargeWindowActive;
    CLFullChargeScheduleState state = getFullChargeScheduleState(now);
    g_fullChargeWindowActive = state.active;
    refreshFullChargeScheduleTimer(state.nextBoundaryTs);
    if (!g_enable) {
        return;
    }
    if (!forceApply && wasActive == state.active) {
        return;
    }
    refreshBatteryStateAndApplyPolicy();
}

static void onBatteryEvent(io_service_t serv) {
    @autoreleasepool {
        NSDictionary* old_bat_info = bat_info;
        if (0 != getBatInfoWithServ(serv, &bat_info)) {
            return;
        }
        updateStatistics();
        if (!g_enable) {
            return;
        }
        applyChargePolicy(old_bat_info, bat_info);
        onBatteryEventEnd();
    }
}

static void initConf(BOOL reset) {
    if (reset) {
        clearPredictiveInhibitFallbackRuntimeState();
    }
    BOOL adv_thermal_avail = getThermalData() != nil;
    NSDictionary* def_dic = @{
        @"charge_below": @20,
        @"charge_above": @80,
        @"enable_temp": @NO,
        @"temp_mode": @0,
        @"charge_temp_above": @40,
        @"charge_temp_below": @35,
        @"history_stats_enabled": @YES,
        @"acc_charge": @NO,
        @"acc_charge_airmode": @YES,
        @"acc_charge_wifi": @NO,
        @"acc_charge_blue": @NO,
        @"acc_charge_bright": @NO,
        @"acc_charge_lpm": @YES,
        @"adv_prefer_smart": @NO, // iPhone8+ iOS13+
        @"adv_predictive_inhibit_charge": @YES, // 默认开启，停充时优先走 PredictiveChargingInhibit，失败自动回退
        @"adv_system_capacity_control_at_100": @YES,
        @"adv_disable_inflow": @NO, // all (iPhone8+ iOS13+会改变系统充电图标)
        @"adv_hold_enabled": @NO, // 默认关闭插电保持
        @"adv_hold_band": @5,
        @"adv_hold_behavior": @"balanced",
        @"adv_hold_temp_disable_smart_charge": @YES,
        @"disable_smart_charge": @NO, // 清除配置时一并还原系统优化充电开关，避免永久停用残留无法恢复
        @"adv_thermal_avail": @(adv_thermal_avail),
        @"adv_limit_inflow": @NO,
        @"adv_limit_inflow_mode": @"moderate",
        @"adv_def_thermal_mode": @"off", // powercuff
        @"adv_thermal_mode_lock": @NO,
        @"full_charge_sched_enabled": @NO,
        @"full_charge_sched_interval_days": @7,
        @"full_charge_sched_start_minute": @120,
        @"full_charge_sched_duration_hours": @4,
        @"full_charge_sched_anchor_date": @"",
        @"full_charge_sched_next_ts": @0,
        @"action": @"",
        @"log_level": @"normal",
    };
    if (reset) {
        BOOL resetBattery = NO;
        BOOL restartDaemon = NO;
        for (NSString* key in def_dic) {
            id valDef = def_dic[key];
            id val = getAllKV()[key];
            if (![valDef isEqual:val]) {
                if ([@[@"adv_predictive_inhibit_charge", @"adv_system_capacity_control_at_100", @"adv_disable_inflow"] containsObject:key]) {
                    resetBattery = YES;
                }
                if ([key isEqualToString:@"adv_prefer_smart"]) {
                    restartDaemon = YES;
                }
                setConfigValueForKey(key, valDef);
            }
        }
        if (resetBattery) {
            resetBatteryStatus();
        }
        if (restartDaemon) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
                exit(0);
            });
        }
    } else {
        NSMutableDictionary* def_mdic = def_dic.mutableCopy;
        [def_mdic addEntriesFromDictionary:@{
            @"enable": @YES,
            @"disable_smart_charge": @NO, // Prefer temporary coordination for new installs
            @"mode": @"charge_on_plug",
            @"update_freq": @1,
            @"lang": @"en",
            @"floatwnd_auto": @NO,
            @"log_level": @"normal",
            // iOS 17+ MCL 80% 限制自动维持（固件逆向定案：系统侧无重新 evaluate 路径）。
            // 默认开：只在用户原意是 80% 限制且插电+电量已到上限但电流未被压低时，
            // 重新走一次与设置 UI 等价的 enableMCL。用户显式关掉 MCL 时维持器不动。
            @"mcl_auto_maintain": @NO,
        }];
        for (NSString* key in def_mdic) {
            id val = getAllKV()[key];
            if (val == nil) {
                setConfigValueForKey(key, def_mdic[key]);
            }
        }
    }
    g_enable = getLocalBool(@"enable", YES);
    refreshHoldMonitorTimer();
    refreshMCLMaintainTimer();
    loadPolicyEventHistoryRuntimeState();
    loadSmartChargeCoordinationRuntimeState();
}

static void showFloatwnd(BOOL flag) {
    static int floatwnd_pid = -1;
    if (flag) { // open
        if (floatwnd_pid == -1) {
            NSDictionary* param = @{
                @"close": getUnusedFds(),
            };
            NSString* bundlePath = [getSelfExePath() stringByDeletingLastPathComponent];
            NSString* appExePath = [bundlePath stringByAppendingPathComponent:@"ChargeLimiter"];
            spawn(@[appExePath, @"floatwnd"], nil, nil, &floatwnd_pid, SPAWN_FLAG_NOWAIT, param);
        }
    } else { // close
        if (floatwnd_pid != -1) {
            kill(floatwnd_pid, SIGKILL);
            floatwnd_pid = -1;
        }
    }
}

static void syncDaemonDocumentsForRequest(NSDictionary* nsreq) {
    NSString* appDocs = nsreq[@"app_docs"];
    if (![appDocs isKindOfClass:[NSString class]] || appDocs.length == 0) {
        return;
    }

    NSString* currentDocs = getAppDocumentsPath();
    if ([currentDocs isEqualToString:appDocs]) {
        return;
    }

    NSString* oldConf = getConfPath();
    NSString* oldDbPath = getDbPath();
    setAppDocumentsPathOverride(appDocs);
    reloadLocalKVFromDisk();
    // Keep sqlite handle aligned with the active app_docs container.
    uninitDB();
    initDB(nil);
    NSString* serial = gUPSPS.props[@"Serial"];
    if (serial.length > 0) {
        initDB(serial);
    }
    initConf(NO);
    refreshFullChargeScheduleTimer(0);
    evaluateFullChargeSchedule(NO);
    recoverSmartChargeCoordinationOnBootstrap();

    NSString* newDocs = getAppDocumentsPath();
    NSString* newConf = getConfPath();
    NSString* newDbPath = getDbPath();
    BOOL confExists = (newConf.length > 0) && [[NSFileManager defaultManager] fileExistsAtPath:newConf];
    BOOL dbExists = (newDbPath.length > 0) && [[NSFileManager defaultManager] fileExistsAtPath:newDbPath];
    NSLog2(@"[CL] sync app_docs old=%@ req=%@ old_conf=%@ new_docs=%@ new_conf=%@ conf_exists=%d old_db=%@ new_db=%@ db_exists=%d",
           currentDocs ?: @"", appDocs ?: @"", oldConf ?: @"", newDocs ?: @"", newConf ?: @"", confExists,
           oldDbPath ?: @"", newDbPath ?: @"", dbExists);
}

/* ---------------- 主开关全禁用（master-off-full-disable，用户决定 D1/D2/D3） ----------------
 * 目标语义：主页面「启用」关闭 = 软件对系统零干预 + 后台零驻留。
 * - B1/B2：运行中收到 enable=NO → 全量还原（与 daemon_exit 同级、幂等）→ 越狱形态从
 *   launchd 注销自身（bootout 以 SIGTERM 终止本进程，atexit 不再执行，无重复还原）→ 退出；
 *   TrollStore 无 launchd，直接退出（App 打开时按需拉起）。
 * - B3：launchd 拉起（开机自启，ppid==1）时若 g_enable=NO → 还原后自注销退出，保证零驻留；
 *   App spawn 的实例（ppid!=1）保留为非驻留诊断形态，继续白名单服务（B4）。
 * - B5：g_enable=NO 时 HTTP 只放行「只读诊断 + 修复/还原 + 重开开关」，其余写入拒绝；
 *   启动自愈与统计写入一并停止。
 * - B6：重新打开主开关时越狱形态 bootstrap 自我注册回 launchd 常驻。
 * launchd plist 文件不改（KeepAlive/RunAtLoad 保持 true）：设备重启后 launchd 拉起一次，
 * 由 B3 自检退出；bootout/bootstrap 均用 service target 形式（system/<label>），无需解析
 * plist 路径的仅 bootout。 */

// launchctl 尽力而为执行；返回 rc，-1=launchctl 不可用。daemon 自身已 root，无需再提权。
static int CLMasterLaunchctl(NSArray* args) {
    NSString* jbRoot = CLDaemonJbRootPath();
    NSMutableArray* candidates = [NSMutableArray arrayWithObjects:
        @"/bin/launchctl", @"/usr/bin/launchctl", nil];
    if (jbRoot.length > 0) {
        [candidates addObject:[jbRoot stringByAppendingPathComponent:@"bin/launchctl"]];
        [candidates addObject:[jbRoot stringByAppendingPathComponent:@"usr/bin/launchctl"]];
    }
    NSString* launchctlPath = nil;
    for (NSString* candidate in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) {
            launchctlPath = candidate;
            break;
        }
    }
    if (launchctlPath == nil) {
        return -1;
    }
    NSString* out = nil;
    NSString* err = nil;
    return spawn([@[launchctlPath] arrayByAddingObjectsFromArray:args], &out, &err, nil, 0, nil);
}

// B2：从 launchd 注销自身（service target 形式）。返回 0=已注销（本进程随即被 SIGTERM
// 终止，正常情况下读不到返回值）；非 0=job 未注册/launchctl 不可用，调用方直接 exit。
static int CLMasterBootoutSelf(void) {
    return CLMasterLaunchctl(@[@"bootout", @"system/com.chargelimiter.mod"]);
}

// B6：恢复 launchd 常驻注册。已注册（print rc==0）则跳过；TrollStore 无 launchd 直接返回。
static void CLMasterOnBootstrapSelf(void) {
    if (g_jbtype == JBTYPE_TROLLSTORE) {
        return;
    }
    int printRc = CLMasterLaunchctl(@[@"print", @"system/com.chargelimiter.mod"]);
    if (printRc == 0) {
        return;   // 常驻态已在 launchd 注册
    }
    NSString* jbRoot = CLDaemonJbRootPath();
    NSMutableArray* plists = [NSMutableArray arrayWithObject:
        @"/Library/LaunchDaemons/com.chargelimiter.mod.plist"];
    if (jbRoot.length > 0) {
        [plists addObject:[jbRoot stringByAppendingPathComponent:
            @"Library/LaunchDaemons/com.chargelimiter.mod.plist"]];
    }
    for (NSString* plist in plists) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:plist]) {
            continue;
        }
        int rc = CLMasterLaunchctl(@[@"bootstrap", @"system", plist]);
        // EPERM 等失败不阻塞开关状态：本次进程内继续服务，下次启动/重启后自愈。
        NSLog2(@"%@ master_on_bootstrap plist=%@ rc=%d", log_prefix, plist, rc);
        return;
    }
    NSLog2(@"%@ master_on_bootstrap no_plist_found jbtype=%d", log_prefix, g_jbtype);
}

// 非驻留诊断形态的空闲退出阈值（B4）：>充电控制探针长会话上限（180s），避免误杀。
static const time_t kMasterIdleExitSeconds = 300;
static volatile time_t g_lastMasterOffRequestTs = 0;

// B1：主开关关闭的全量还原（与 daemon_exit 同级，幂等），随后按 B2 退出。不返回。
static void CLMasterOffShutdown(NSString* reason) {
    NSLog2(@"%@ master_off_shutdown reason=%@ jbtype=%d pid=%d ppid=%d",
           log_prefix, reason, g_jbtype, getpid(), getppid());
    resetBatteryStatusWithContext(YES, reason);
    if (g_jbtype != JBTYPE_TROLLSTORE) {
        // bootout 由 launchd 向本进程发 SIGTERM：越狱形态未忽略 SIGTERM（仅 TrollStore
        // 忽略），进程终止于此且 atexit 不执行——还原已在上方完成，无重复写。
        int rc = CLMasterBootoutSelf();
        // 走到这里说明 SIGTERM 未按预期终止（防御）：job 已注销，直接退出不会被重拉。
        NSLog2(@"%@ master_off_bootout rc=%d fallback_exit", log_prefix, rc);
    }
    exit(0);
}

// B5：g_enable=NO 时 HTTP 面白名单。返回非 nil = 拒绝（调用方直接回包）；nil = 放行。
// 保留：只读诊断、修复/还原类（用户决定 D1——软件的核心用途）、重开主开关。
static NSDictionary* CLMasterOffGateRequest(NSString* api, NSDictionary* nsreq) {
    if (g_enable) {
        return nil;
    }
    static NSSet* allowedAPIs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedAPIs = [NSSet setWithArray:@[
            // 只读诊断
            @"get_conf", @"get_bat_info", @"get_mcl_diagnostics", @"get_statistics",
            @"get_policy_events", @"get_diag", @"reload_conf",
            // 修复/还原类（D1）
            @"restore_smart_charge", @"repair_mcl_limit", @"charge_control_probe",
            // App 自身数据管理（不触碰系统状态；真机回灌：主开关关闭时用户
            // 需要能关闭/清空历史记录，否则统计页表现为「关不掉删不掉」）
            @"clear_statistics",
        ]];
    });
    if ([allowedAPIs containsObject:api]) {
        return nil;
    }
    if ([api isEqualToString:@"set_conf"]) {
        NSString* key = nsreq[@"key"];
        if ([key isEqualToString:@"enable"]) {
            return nil;   // 重开主开关（B6）
        }
        if ([key isEqualToString:@"disable_smart_charge"] && ![nsreq[@"val"] boolValue]) {
            return nil;   // 关闭「永久停用」= 还原语义，允许（D1 同类）
        }
        // App 本地数据/UI 配置：不构成系统干预，拒绝会让用户「关不掉」
        if ([key isEqualToString:@"history_stats_enabled"] || [key isEqualToString:@"lang"]) {
            return nil;
        }
        return @{@"status": @(-403),
                 @"error": @"master_switch_off",
                 @"key": key ?: @""};
    }
    return @{@"status": @(-403), @"error": @"master_switch_off"};
}

NSDictionary* handleReq(NSDictionary* nsreq) {
    g_lastMasterOffRequestTs = time(0);   // 非驻留形态空闲退出计时（B4）
    syncDaemonDocumentsForRequest(nsreq);
    NSString* api = nsreq[@"api"];
    // 主开关关闭：白名单门（B5）。放行 nil；拒绝直接回包，不落任何系统写。
    NSDictionary* masterGate = CLMasterOffGateRequest(api, nsreq);
    if (masterGate != nil) {
        return masterGate;
    }
    if ([api isEqualToString:@"get_conf"]) {
        NSString* key = nsreq[@"key"];
        if (key == nil) {
            NSMutableDictionary* kv = [getAllKV() mutableCopy];
            kv[@"enable"] = @(g_enable);
            kv[@"floatwnd"] = @(g_enable_floatwnd);
            //kv[@"dark"] = @(isDarkMode());  daemon获取到的结果不随系统变化,需要从app获取
            kv[@"sysver"] = getSysVer();
            kv[@"devmodel"] = getDevMdoel();
            kv[@"ver"] = getAppVer();
            kv[@"serv_boot"] = @(g_serv_boot);
            kv[@"sys_boot"] = @(get_sys_boottime());
            kv[@"thermal_simulate_mode"] = getThermalSimulationMode();
            kv[@"ppm_simulate_mode"] = getPPMSimulationMode();
            kv[@"use_smart"] = @(g_use_smart);
            kv[@"smart_charge_status"] = @(g_smartChargeStatus);
            kv[@"smart_charge_managed_by_daemon"] = @(g_tempSmartChargeDisabledByCL);
            return @{
                @"status": @0,
                @"data": kv,
            };
        } else {
            return @{
                @"status": @0,
                @"data": getAllKV()[key],
            };
        }
    } else if ([api isEqualToString:@"set_conf"]) {
        NSString* key = nsreq[@"key"];
        id val = nsreq[@"val"];
        if ([key isEqualToString:@"mode"]) {
            val = @"charge_on_plug";
        }
        if ([key isEqualToString:@"floatwnd"]) {
            g_enable_floatwnd = [val boolValue];
            showFloatwnd(g_enable_floatwnd);
        } else if ([key isEqualToString:@"ppm_simulate_mode"]) {
            setPPMSimulationMode(val);
        } else {
            setConfigValueForKey(key, val);
        }
        if ([key isEqualToString:@"enable"]) {
            g_enable = [val boolValue];
            refreshFullChargeScheduleTimer(0);
            refreshHoldMonitorTimer();
            refreshMCLMaintainTimer();
            if (!g_enable) {
                // 主开关关闭（用户决定 D2/D3）：全量还原系统状态后退出进程并从 launchd
                // 注销，后台零驻留。resetBatteryStatus() 旧路径（restore=NO）会留下 MCL/
                // thermal 等残留，必须走完整还原（与 daemon_exit 同级）。
                CLMasterOffShutdown(@"master_off_set_conf");
                return @{@"status": @0};   // unreachable：Shutdown 不返回
            } else { // 启用时检查
                BOOL disableSmartCharge = getLocalBool(@"disable_smart_charge", NO);
                if (disableSmartCharge) {
                    if (isSmartChargeEnable()) {
                        rememberMCLStateBeforeDisable();
                        setSmartChargeEnable(NO);
                        disableMCLForPermanentDisable();
                    }
                }
                evaluateFullChargeSchedule(YES);
                // B6：非驻留形态（App 按需拉起）重开主开关时，恢复 launchd 常驻注册；
                // 常驻态已注册则幂等跳过；TrollStore 无 launchd。
                CLMasterOnBootstrapSelf();
            }
        } else if ([key isEqualToString:@"disable_smart_charge"]) {
            // 关闭「永久停用系统优化充电」时，必须把系统优化充电重新打开。
            // disableSmartCharging: 写的是系统级开关，仅改本地配置不会恢复。
            if (![val boolValue] && !isSmartChargeEnable()) {
                setSmartChargeEnable(YES);
                restoreMCLStateAfterEnable();
            }
            refreshMCLMaintainTimer();
        } else if ([key isEqualToString:@"mcl_auto_maintain"]) {
            // 维持开关切换：立即重排定时器，并在关闭时清零误触计数（避免遗留半程状态）。
            refreshMCLMaintainTimer();
            if (![val boolValue]) {
                g_mclMaintainNegativeStreak = 0;
            }
        } else if ([key isEqualToString:@"action"]) {
            if ([val isEqualToString:@"noti"]) {
                [Service.inst initLocalPush];
            }
        } else if ([key isEqualToString:@"adv_hold_enabled"]) {
            resetHoldSessionState();
            refreshHoldMonitorTimer();
        } else if ([key isEqualToString:@"adv_hold_behavior"]) {
            refreshHoldMonitorTimer();
        } else if ([key isEqualToString:@"adv_predictive_inhibit_charge"]) {
            clearPredictiveInhibitFallbackRuntimeState();
            resetBatteryStatus();
        } else if ([key isEqualToString:@"adv_system_capacity_control_at_100"]) {
            resetHoldSessionState();
            refreshHoldMonitorTimer();
            if (getLocalInt(@"charge_above", 100) >= 100) {
                resetBatteryStatus();
            }
        } else if ([key isEqualToString:@"adv_disable_inflow"]) {
            resetBatteryStatus();
            refreshBatteryStateAndApplyPolicy();
            armDisableInflowRetryIfNeeded(bat_info, g_policyState, hasPotentialExternalPowerSignal(bat_info));
        } else if ([key isEqualToString:@"charge_above"]) {
            resetHoldSessionState();
            refreshHoldMonitorTimer();
            if ([val intValue] >= 100) {
                resetBatteryStatus();
            }
        } else if ([@[
            @"full_charge_sched_enabled",
            @"full_charge_sched_interval_days",
            @"full_charge_sched_start_minute",
            @"full_charge_sched_duration_hours"
        ] containsObject:key]) {
            resetFullChargeScheduleAnchorDate(time(0));
            refreshFullChargeScheduleTimer(0);
            evaluateFullChargeSchedule(YES);
        } else if ([key isEqualToString:@"adv_prefer_smart"]) {
            clearPredictiveInhibitFallbackRuntimeState();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
                exit(0);
            });
        } else if ([key isEqualToString:@"temp_mode"]) {
            NSArray* vals = nsreq[@"vals"];
            if (vals != nil && vals.count >= 2) {
                setLocalFloat(@"charge_temp_below", [vals[0] floatValue]);
                setLocalFloat(@"charge_temp_above", [vals[1] floatValue]);
            }
        }
        if ([key isEqualToString:@"adv_def_thermal_mode"]) {
            // 默认档变更后经决策函数决定当前应写入的 thermal mode
            applyThermalModeForCurrentState();
        }
        if ([key isEqualToString:@"adv_limit_inflow"] ||
            [key isEqualToString:@"adv_limit_inflow_mode"] ||
            [key isEqualToString:@"adv_thermal_mode_lock"]) {
            applyThermalModeForCurrentState();
        }
        if (shouldRefreshBatteryPolicyForConfigKey(key)) {
            refreshBatteryStateAndApplyPolicy();
        }
       return @{
           @"status": @0,
       };
    } else if ([api isEqualToString:@"set_limit_inflow_config"]) {
        // 原子限流配置：一次请求同时提交 enabled + mode，串行 handler 内完成。
        NSDictionary* body = nsreq[@"body"] ?: nsreq;
        id enabledVal = body[@"enabled"];
        id modeVal = body[@"mode"];
        if (enabledVal == nil || modeVal == nil) {
            return @{@"status": @(-1), @"error": @"missing enabled or mode"};
        }
        BOOL enabled = [enabledVal boolValue];
        NSString* mode = [modeVal isKindOfClass:[NSString class]] ? modeVal : [NSString stringWithFormat:@"%@", modeVal];
        NSSet* validModes = [NSSet setWithArray:@[@"off", @"nominal", @"light", @"moderate", @"heavy"]];
        if (![validModes containsObject:mode]) {
            return @{@"status": @(-1), @"error": @"invalid mode"};
        }
        // 批量写两键，一次 apply，失败时 reloadFromDisk 回滚
        NSDictionary* batch = @{
            @"adv_limit_inflow": @(enabled),
            @"adv_limit_inflow_mode": mode,
        };
        BOOL ok = setlocalKVBatch_C(batch);
        if (!ok) {
            return @{@"status": @(-2), @"error": @"config write failed"};
        }
        // 成功后经决策函数更新一次 thermal mode
        applyThermalModeForCurrentState();
        return @{@"status": @0};
   } else if ([api isEqualToString:@"reset_conf"]) {
       initConf(YES);
        // 清除配置后必须把系统的「优化充电」重新打开：永久停用会写系统级开关，
        // 仅还原本地 disable_smart_charge=NO 无法恢复，需显式 enable。
        if (!getLocalBool(@"disable_smart_charge", NO) && !isSmartChargeEnable()) {
            setSmartChargeEnable(YES);
        }
        tryRestoreSmartChargeAfterCoordination(@"reset_conf");
        refreshFullChargeScheduleTimer(0);
        evaluateFullChargeSchedule(YES);
        return @{
            @"status": @0,
        };
    } else if ([api isEqualToString:@"get_bat_info"]) {
        getBatInfo(&bat_info);
        NSMutableDictionary* data = [bat_info mutableCopy];
        if (data == nil) {
            data = [NSMutableDictionary dictionary];
        }
        int target = getLocalInt(@"charge_above", 100);
        BOOL holdCapacityControlAvailable = (isHoldModeEnabled() && !shouldDisableCapacityControlForTarget(target));
        data[@"PredictiveChargingInhibitActive"] = @([data[@"PredictiveChargingInhibit"] boolValue]);
        data[@"PredictiveInhibitFallbackActive"] = @(g_predictiveInhibitFallbackActive);
        data[@"ChargeCommandEnabled"] = @(g_chargeCommandEnabled);
        data[@"PolicyState"] = g_policyState ?: @"battery";
        data[@"HoldActive"] = @([g_policyState hasPrefix:@"hold"]);
        data[@"HoldCharging"] = @([g_policyState isEqualToString:@"hold_recharge"]);
        data[@"HoldTarget"] = holdCapacityControlAvailable ? @(target) : @0;
        data[@"HoldRangeLower"] = holdCapacityControlAvailable ? @(getHoldModeLowerBound(target)) : @0;
        data[@"HoldBand"] = @(getHoldModeBand());
        data[@"HoldBehavior"] = @"balanced";
        data[@"HoldRuntimeBehavior"] = @"balanced";
        data[@"HoldAdaptiveLoadLevel"] = @"fixed";
        data[@"HoldAdaptiveAverageCurrent"] = @0;
        data[@"HoldDischargeStreak"] = @0;
        data[@"HoldMonitorIntervalSeconds"] = holdCapacityControlAvailable ? @((g_holdMonitorTimerIntervalSeconds > 0) ? g_holdMonitorTimerIntervalSeconds : getHoldStrategyMonitorIntervalSeconds()) : @0;
        data[@"HoldEarlyRechargeAssistEnabled"] = @NO;
        data[@"HoldEarlyRechargeStreakRequired"] = @0;
        data[@"SmartChargeStatus"] = @(g_smartChargeStatus);
        data[@"SmartChargeManagedByDaemon"] = @(g_tempSmartChargeDisabledByCL);
        // iOS 17+ MCL（80% 限制开关）状态：App 显示与诊断用。旧系统恒 false/false。
        data[@"SmartChargeMCLSupported"] = @(isSmartChargeMCLSupported());
        data[@"SmartChargeMCLEnabled"] = @(getSmartChargeMCLEnabled());
        // iOS 17+ MCL 全链路诊断（Design Doc 3.3）：App 诊断页与导出用。旧系统仅 {supported:false}。
        data[@"MCLDiagnostics"] = collectMCLDiagnostics();
        data[@"SmartChargeOriginalStatus"] = @(g_smartChargeCoordinationOriginalStatus);
        data[@"SmartChargeCoordinationSessionID"] = g_smartChargeCoordinationSessionID ?: @"";
        data[@"SmartChargeCoordinationStartTime"] = @(g_smartChargeCoordinationStartedTs);
        data[@"PolicyReason"] = g_policyReason ?: @"unknown";
        data[@"LastPolicyChangeReason"] = g_lastPolicyChangeReason ?: @"unknown";
        data[@"LastPolicyChangeTime"] = @(g_lastPolicyChangeTs);
        data[@"LastChargeCommandTime"] = @(g_lastChargeCommandTs);
        data[@"LastInflowCommandTime"] = @(g_lastInflowCommandTs);
        // 主页"高温模拟"卡片随电池刷新轮询实时更新：get_conf 只在进页面/手动刷新时
        // 拉取，若只在 get_conf 里带 thermal_simulate_mode，切换等级后卡片最长滞后到
        // 下次进入页面（原版 Web UI 每秒轮询 get_conf，UIKit 版丢了这条链路）。
        data[@"ThermalSimulateMode"] = getThermalSimulationMode();
        data[@"PolicyTransitionHistory"] = recentPolicyTransitionHistory();
        NSArray* dbPolicyEvents = getPolicyEventDBData((int)kPolicyEventHistoryLimit, 0);
        data[@"PolicyEventHistory"] = dbPolicyEvents.count > 0 ? dbPolicyEvents : recentPolicyEventHistory();
        if (gUPSPS.props != nil) {
            return @{
                @"status": @0,
                @"data": data,
                @"data_ups": gUPSPS.props,
            };
        }
        return @{
            @"status": @0,
            @"enable": @(g_enable), // for floatwnd
            @"data": data,
        };
    } else if ([api isEqualToString:@"get_diag"]) {
        NSDictionary* data = getIOPMPSServDiagnostics();
        return @{
            @"status": @0,
            @"data": data ?: @{},
        };
    } else if ([api isEqualToString:@"get_mcl_diagnostics"]) {
        // 独立只读诊断 API（Design Doc 3.3）：诊断页手动刷新用，读写分离。
        return @{
            @"status": @0,
            @"data": collectMCLDiagnostics(),
        };
    } else if ([api isEqualToString:@"apply_now"]) {
        refreshBatteryStateAndApplyPolicy();
        return @{
            @"status": @0,
        };
    } else if ([api isEqualToString:@"reload_conf"]) {
        NSString* reloadPath = getConfPath();
        NSDictionary* diskConfig = reloadPath.length > 0
            ? [NSDictionary dictionaryWithContentsOfFile:reloadPath]
            : nil;
        BOOL reloadOK = [diskConfig isKindOfClass:[NSDictionary class]];
        NSUInteger loadedKeyCount = reloadOK ? diskConfig.count : 0;

        reloadLocalKVFromDisk();
        // Migration may replace db file in-place. Reopen sqlite handle to pick up new file.
        uninitDB();
        initDB(nil);
        initConf(NO);
        recoverSmartChargeCoordinationOnBootstrap();
        refreshFullChargeScheduleTimer(0);
        evaluateFullChargeSchedule(YES);
        NSDictionary* reloadResult = @{
            @"state": @"reload_conf",
            @"reload_ok": @(reloadOK),
            @"loaded_key_count": @(loadedKeyCount),
            @"config_path": reloadPath ?: @"",
        };
        g_lastConfigReloadDiagnostics = reloadResult;
        if (reloadOK) {
            NSFileInfoLog(@"config_reload ok=1 key_count=%lu",
                          (unsigned long)loadedKeyCount);
        } else {
            NSFileErrorLog(@"config_reload failed key_count=%lu path=%@",
                           (unsigned long)loadedKeyCount, reloadPath ?: @"(nil)");
        }
        return @{
            @"status": reloadOK ? @0 : @1,
            @"data": @{ @"config_reload": reloadResult },
        };
    } else if ([api isEqualToString:@"get_statistics"]) {
        NSDictionary* conf = nsreq[@"conf"];
        NSMutableDictionary* data = [NSMutableDictionary dictionary];
        for (NSString* tbl in conf) {
            NSDictionary* conf_for_tbl = conf[tbl];
            NSNumber* n = conf_for_tbl[@"n"];
            NSNumber* last_id = conf_for_tbl[@"last_id"];
            if (!isAllowedStatsTableName(tbl)) {
                data[tbl] = @[];
                continue;
            }
            data[tbl] = getDBData(tbl, n.intValue, last_id.intValue);
        }
        return @{
            @"status": @0,
            @"data": data,
        };
    } else if ([api isEqualToString:@"get_policy_events"]) {
        int n = [nsreq[@"n"] respondsToSelector:@selector(intValue)] ? [nsreq[@"n"] intValue] : 200;
        int lastID = [nsreq[@"last_id"] respondsToSelector:@selector(intValue)] ? [nsreq[@"last_id"] intValue] : 0;
        return @{
            @"status": @0,
            @"data": getPolicyEventDBData(n, lastID),
        };
    } else if ([api isEqualToString:@"clear_statistics"]) {
        clearAllStatisticsData();
        return @{
            @"status": @0,
        };
    } else if ([api isEqualToString:@"set_charge_status"]) {
        NSNumber* flag = nsreq[@"flag"];
        getBatInfo(&bat_info);
        int status = setChargeStatus(flag.boolValue);
        return @{
            @"status": @(status)
        };
    } else if ([api isEqualToString:@"set_inflow_status"]) {
        NSNumber* flag = nsreq[@"flag"];
        getBatInfo(&bat_info);
        int status = setInflowStatus(flag.boolValue);
        return @{
            @"status": @(status)
        };
    } else if ([api isEqualToString:@"restore_smart_charge"]) {
        // App「还原系统优化充电」入口：清除本工具残留并强制恢复系统优化充电。
        NSDictionary* result = performFullSmartChargeRestore(@"api_restore_smart_charge");
        refreshBatteryStateAndApplyPolicy();
        return @{
            @"status": @0,
            @"data": result,
        };
    } else if ([api isEqualToString:@"repair_mcl_limit"]) {
        // App「强制修复 80% 限制」入口（Design Doc 3.4）：不信任读回短路的修复编排。
        NSDictionary* result = performMCLLimitRepair();
        return @{
            @"status": @0,
            @"data": result,
        };
    } else if ([api isEqualToString:@"charge_control_probe"]) {
        @synchronized (CLProbeGetLock()) {
            if (g_chargeControlProbeRunning) {
                return @{ @"status": @-12, @"msg": @"probe_busy" };
            }
            g_chargeControlProbeRunning = YES;
        }
        NSDictionary* response = nil;
        @try {
            // Deep probe default 2000ms: give hardware time to react after prop-only writes.
            // Matrix is larger now; total time can exceed 5s — acceptable for diagnostic.
            NSInteger waitMs = 2000;
            if (nsreq[@"wait_ms"] != nil && [nsreq[@"wait_ms"] respondsToSelector:@selector(integerValue)]) {
                waitMs = [nsreq[@"wait_ms"] integerValue];
            }
            if (waitMs < 200) waitMs = 200;
            if (waitMs > 2000) waitMs = 2000;
            BOOL restore = YES;
            if (nsreq[@"restore"] != nil) {
                restore = [nsreq[@"restore"] boolValue];
            }
            NSArray* paths = nsreq[@"paths"];
            if (![paths isKindOfClass:[NSArray class]] || paths.count == 0) {
                paths = CLProbeDefaultPaths();
            }
            NSArray* services = nsreq[@"services"];
            if (![services isKindOfClass:[NSArray class]] || services.count == 0) {
                services = CLProbeDefaultServices();
            }

            // Refresh bat_info once so external-power note / history extras are current.
            getBatInfo(&bat_info);
            NSMutableArray* results = [NSMutableArray array];
            BOOL hasExternalPower = hasPotentialExternalPowerSignal(bat_info);
            // Skip services that resolve to an underlying name already probed (e.g. auto == AppleSmartBattery).
            NSMutableSet* probedResolvedServices = [NSMutableSet set];
            for (id serviceObj in services) {
                NSString* serviceName = [serviceObj isKindOfClass:[NSString class]] ? (NSString*)serviceObj : [serviceObj description];
                // auto 解析必须与 CLProbeResolvedServiceName 一致，避免把 auto 错记成 Manager
                // 从而跳过真正的 AppleSmartBattery 探针（真机 2026-08-02 复现）。
                NSString* resolvedPeek = [serviceName isEqualToString:@"auto"]
                    ? (g_use_smart ? @"AppleSmartBattery" : @"IOPMPowerSource")
                    : (serviceName ?: @"");
                if (resolvedPeek.length > 0 && [probedResolvedServices containsObject:resolvedPeek]) {
                    continue;
                }
                if (resolvedPeek.length > 0) {
                    [probedResolvedServices addObject:resolvedPeek];
                }
                for (id pathObj in paths) {
                    NSString* path = [pathObj isKindOfClass:[NSString class]] ? (NSString*)pathObj : [pathObj description];
                    NSDictionary* one = CLProbeRunOne(serviceName, path, waitMs, restore);
                    if (one != nil) {
                        [results addObject:one];
                    }
                }
            }

            NSDictionary* summary = CLProbeSummarizeResults(results, hasExternalPower);
            appendPolicyEventHistory(@"charge_path_event",
                                     g_policyState ?: @"",
                                     g_policyState ?: @"",
                                     @"charge_control_probe",
                                     bat_info,
                                     @{ @"summary": summary, @"result_count": @(results.count) },
                                     time(0));

            response = @{
                @"status": @0,
                @"data": @{
                    @"device": getDevMdoel() ?: @"",
                    @"sysver": getSysVer() ?: @"",
                    @"jb_type": @(getJBType()),
                    @"use_smart": @(g_use_smart),
                    @"probe_ts": @(time(0)),
                    @"wait_ms": @(waitMs),
                    @"restore": @(restore),
                    @"results": results,
                    @"summary": summary,
                },
            };
        } @finally {
            @synchronized (CLProbeGetLock()) {
                g_chargeControlProbeRunning = NO;
            }
        }
        // 探针结束后拉回正常策略（必须在互斥释放后，否则 setBatteryStatus/setInflowStatus 会被短路）
        refreshBatteryStateAndApplyPolicy();
        return response ?: @{ @"status": @-11, @"msg": @"probe_failed" };
    }
    return @{
        @"status": @-10
    };
}

static void processUPSEventSource(UPSDataSlim* upsPS, CFTypeRef typeRef) {
    CFRunLoopTimerRef timer = nil;
    CFRunLoopSourceRef source = nil;
    if (CFGetTypeID(typeRef) == CFArrayGetTypeID()) {
        NSArray* arrayRef = (__bridge_transfer NSArray*)typeRef;
        for (CFIndex i = 0; i < arrayRef.count; i++) {
            CFTypeRef typeRefI = (__bridge CFTypeRef)arrayRef[i];
            if (CFGetTypeID(typeRefI) == CFRunLoopTimerGetTypeID()) {
                timer = (CFRunLoopTimerRef)typeRefI;
            } else if (CFGetTypeID(typeRefI) == CFRunLoopSourceGetTypeID()) {
                source = (CFRunLoopSourceRef)typeRefI;
            }
        }
    } else if (CFGetTypeID(typeRef) == CFRunLoopTimerGetTypeID()) {
        timer = (CFRunLoopTimerRef)typeRef;
    } else if (CFGetTypeID(typeRef) == CFRunLoopSourceGetTypeID()) {
        source = (CFRunLoopSourceRef)typeRef;
    }
    if (timer != nil) {
        upsPS.timer = timer;
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    }
    if (source != nil) {
        upsPS.source = source;
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    }
}

static void releaseUPSBattery(UPSDataSlim* upsPS) {
    if (upsPS == nil) {
        return;
    }
    if (upsPS.interface != NULL) {
        (*upsPS.interface)->Release(upsPS.interface);
    }
    if (upsPS.source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), upsPS.source, kCFRunLoopDefaultMode);
        CFRelease(upsPS.source);
    }
    if (upsPS.timer) {
        CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), upsPS.timer, kCFRunLoopDefaultMode);
        CFRelease(upsPS.timer);
    }
    if (upsPS.noti != MACH_PORT_NULL) {
        IOObjectRelease(upsPS.noti);
    }
}

static void addUPSBattery(void* refCon, io_iterator_t iterator) {
    @autoreleasepool {
        static CFUUIDRef kIOUPSPlugInTypeID             = CFUUIDCreateFromString(NULL, CFSTR("40A57A4E-26A0-11D8-9295-000A958A2C78"));
        static CFUUIDRef kIOUPSPlugInInterfaceID        = CFUUIDCreateFromString(NULL, CFSTR("63F8BFC4-26A0-11D8-88B4-000A958A2C78"));
        static CFUUIDRef kIOUPSPlugInInterfaceID_v140   = CFUUIDCreateFromString(NULL, CFSTR("E60E0799-9AA6-49DF-B55B-A5C94BA07A4A"));
        static CFUUIDRef kIOCFPlugInInterfaceID         = CFUUIDCreateFromString(NULL, CFSTR("C244E858-109C-11D4-91D4-0050E4C6426F"));
        io_object_t upsDevice = MACH_PORT_NULL;
        while ((upsDevice = IOIteratorNext(iterator))) {
            IOReturn kr = 0;
            HRESULT result = S_FALSE;
            IOCFPlugInInterface** plugInInterface = NULL;
            IOUPSPlugInInterface_v140** upsPlugInInterface = NULL;
            SInt32 score;
            kr = IOCreatePlugInInterfaceForService(upsDevice, kIOUPSPlugInTypeID, kIOCFPlugInInterfaceID, &plugInInterface, &score);
            if (kr == kIOReturnSuccess && plugInInterface != NULL) {
                UPSDataSlim* upsPS = [UPSDataSlim new];
                result = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUPSPlugInInterfaceID_v140), (LPVOID*)&upsPlugInInterface);
                if (result == S_OK && upsPlugInInterface != nil) {
                    CFTypeRef typeRef = nil;
                    (*upsPlugInInterface)->createAsyncEventSource(upsPlugInInterface, &typeRef);
                    if (typeRef != nil) {
                        processUPSEventSource(upsPS, typeRef);
                    }
                } else {
                    result = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUPSPlugInInterfaceID), (LPVOID*)&upsPlugInInterface);
                }
                if (result == S_OK && upsPlugInInterface != NULL) {
                    gUPSPS = upsPS;
                    gUPSPS.interface = upsPlugInInterface;
                    CFMutableDictionaryRef props = nil;
                    IORegistryEntryCreateCFProperties(upsDevice, &props, kCFAllocatorDefault, 0);
                    if (props != nil) {
                        [gUPSPS updateProps:(__bridge NSDictionary*)props isEvent:NO];
                    }
                    [gUPSPS initDB];
                    CFDictionaryRef upsEvent = nil;
                    kr = (*upsPlugInInterface)->getEvent(upsPlugInInterface, &upsEvent);
                    if (kr == kIOReturnSuccess && upsEvent != nil) {
                        [gUPSPS updateProps:(__bridge NSDictionary*)upsEvent isEvent:NO];
                    }
                    (*upsPlugInInterface)->setEventCallback(upsPlugInInterface, [](void* target, IOReturn kr, void* refcon, void* sender, CFDictionaryRef event) {
                        @autoreleasepool {
                            if (gUPSPS != nil && event != nil) {
                                [gUPSPS updateProps:(__bridge NSDictionary*)event isEvent:NO];
                            }
                        }
                    }, NULL, NULL);
                    io_object_t noti = IO_OBJECT_NULL;
                    IOServiceAddInterestNotification(gNotifyPort, upsDevice, "IOGeneralInterest", [](void* refcon, io_service_t service, uint32_t type, void* args) {
                        @autoreleasepool {
                            if (type == kIOMessageServiceIsTerminated) {
                                releaseUPSBattery(gUPSPS);
                                gUPSPS = nil;
                            }
                        }
                    }, nil, &noti);
                    gUPSPS.noti = noti;
                }
                (*plugInInterface)->Release(plugInInterface);
            }
            IOObjectRelease(upsDevice);
            if (gUPSPS != nil) {
                break;
            }
        }
    }
}

void detectUPSBattery() {
    @autoreleasepool {
        if (gUPSPS != nil) { // 存在电池则忽略
            return;
        }
        NSDictionary* dic = @{
            @"IOProviderClass": @"IOHIDDevice",
            @"DeviceUsagePairs": @[
                @{ // kDeviceTypeAccessoryBattery
                    @"DeviceUsagePage": @kHIDPage_AppleVendor,
                    @"DeviceUsage": @kHIDUsage_AppleVendor_AccessoryBattery,
                }, @{ // kDeviceTypeAccessoryBattery
                    @"DeviceUsagePage": @kHIDPage_PowerDevice,
                    @"DeviceUsage": @kHIDUsage_PD_PeripheralDevice,
                }, @{ // kDeviceTypeBatteryCase
                    @"DeviceUsagePage": @kHIDPage_BatterySystem,
                    @"DeviceUsage": @kHIDUsage_BS_PrimaryBattery,
                },
            ]
        };
        io_iterator_t gAddedIter = MACH_PORT_NULL;
        kern_return_t kr = IOServiceAddMatchingNotification(gNotifyPort, kIOMatchedNotification, (__bridge_retained CFDictionaryRef)dic, addUPSBattery, NULL, &gAddedIter);
        if (kr == kIOReturnSuccess) {
            if (gAddedIter != MACH_PORT_NULL) {
                addUPSBattery(NULL, gAddedIter);
                IOObjectRelease(gAddedIter);
            }
        }
    }
}

@implementation UPSDataSlim
- (instancetype)init {
    self = [super init];
    self.noti = IO_OBJECT_NULL;
    self.source = nil;
    self.timer = nil;
    self.props = [NSMutableDictionary dictionary];
    return self;
}
- (void)initDB {
    NSString* serial = self.props[@"Serial"];
    if (serial != nil) {
        initDB(serial);
    }
}
- (void)updateProps:(NSDictionary*)propsSrc isEvent:(BOOL)event {
    NSDictionary* keep = @{
        @"Authenticated": @"Authenticated",
        @"Manufacturer": @"Manufacturer",
        @"ModelNumber": @"ModelNumber",
        @"PrimaryUsagePage": @"UsagePage",
        @"PrimaryUsage": @"Usage",
        @"Product": @"Name",
        @"ProductID": @"ProductID",
        @"ReportInterval": @"ReportInterval",
        @"SerialNumber": @"Serial",
        @"Transport": @"Transport",
        @"VendorID": @"VendorID",
        @"VersionNumber": @"VersionNumber",
        @"AppleRawCurrentCapacity": @"AppleRawCurrentCapacity",
        @"BatteryCaseChargingVoltage": @"BatteryCaseChargingVoltage",
        @"Cell0Voltage": @"Cell0Voltage",
        @"Cell1Voltage": @"Cell1Voltage",
        @"Current": @"Amperage",
        @"CurrentCapacity": @"CurrentCapacity",
        @"CycleCount": @"CycleCount",
        @"IncomingCurrent": @"IncomingCurrent",
        @"IncomingVoltage": @"IncomingVoltage",
        @"IsCharging": @"IsCharging",
        @"MaxCapacity": @"MaxCapacity",
        @"NominalCapacity": @"NominalCapacity",
        @"PowerSourceState": @"PowerSourceState",
        @"Temperature": @"Temperature",
        @"Voltage": @"Voltage",
    };
    for (NSString* rawkey in propsSrc) {
        NSString* key = [rawkey stringByReplacingOccurrencesOfString:@" " withString:@""];
        if (keep[key] == nil) {
            continue;
        } else {
            key = keep[key];
        }
        id val = propsSrc[rawkey];
        self.props[key] = val;
    }
    if (event) {
        self.props[@"UpdateTime"] = @(time(0));
    }
}
@end

@implementation Service {
    NSString* bid;
}
+ (instancetype)inst {
    static dispatch_once_t pred = 0;
    static Service* inst_ = nil;
    dispatch_once(&pred, ^{
        inst_ = [self new];
    });
    return inst_;
}
- (void)applicationsDidUninstall:(NSArray<LSApplicationProxy*>*)list {
    @autoreleasepool {
        for (LSApplicationProxy* proxy in list) {
            if ([proxy.bundleIdentifier isEqualToString:self->bid]) {
                resetBatteryStatusWithContext(YES, @"app_uninstall");
                exit(0);
            }
        }
    }
}
- (void)applicationsDidInstall:(NSArray<LSApplicationProxy*>*)list {
    for (LSApplicationProxy* proxy in list) {
        if ([proxy.bundleIdentifier isEqualToString:self->bid]) {
            exit(0);
        }
    }
}
- (instancetype)init {
    self = super.init;
    self->bid = NSBundle.mainBundle.bundleIdentifier;
    return self;
}
- (void)initLocalPush {
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    // getNotificationSettingsWithCompletionHandler返回结果不准确,忽略
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge completionHandler:^(BOOL granted, NSError* error) {
    }];
}
- (void)localPush:(NSString*)title msg:(NSString*)msg identifier:(NSString*)identifier {
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = msg;
    content.sound = UNNotificationSound.defaultSound;
    NSString* stableIdentifier = identifier.length > 0 ? identifier : @"com.chargelimiter.noti.generic";
    [center removePendingNotificationRequestsWithIdentifiers:@[stableIdentifier]];
    [center removeDeliveredNotificationsWithIdentifiers:@[stableIdentifier]];
    UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:stableIdentifier content:content trigger:nil];
    [center addNotificationRequest:request withCompletionHandler:nil];
}
- (void)systemTimeContextDidChange:(NSNotification*)note {
    @synchronized (Service.inst) {
        evaluateFullChargeSchedule(NO);
    }
}
- (void)serve {
    initConf(NO);
    initDB(nil);

    // B3：主开关关闭 + launchd 拉起（设备重启自启场景，ppid==1）→ 完成还原后自注销退出，
    // 保证后台零驻留。App spawn 的实例（ppid!=1）保留为非驻留诊断形态（B4），继续白名单服务。
    if (!g_enable && getppid() == 1 && g_jbtype != JBTYPE_TROLLSTORE) {
        CLMasterOffShutdown(@"master_off_boot_check");
        return;   // unreachable：Shutdown 不返回
    }
    // B4：主开关关闭 + App spawn 的非驻留诊断形态——空闲自动退出（App 退后台后不留孤儿
    // 进程；下次 App 请求失败时既有机制自动重新 spawn）。阈值 300s 覆盖充电控制探针的
    // 120s/180s 长会话；收到 enable=YES 后 g_enable 翻转，退出条件不再成立（常驻化）。
    if (!g_enable) {
        static dispatch_source_t g_masterIdleMonitor = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            g_masterIdleMonitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_global_queue(0, 0));
            dispatch_source_set_timer(g_masterIdleMonitor,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)kMasterIdleExitSeconds * NSEC_PER_SEC),
                                      (uint64_t)kMasterIdleExitSeconds * NSEC_PER_SEC,
                                      (uint64_t)5 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(g_masterIdleMonitor, ^{
                if (!g_enable && (time(0) - g_lastMasterOffRequestTs) >= kMasterIdleExitSeconds) {
                    NSLog2(@"%@ master_off_idle_exit idle=%lds", log_prefix,
                           (long)(time(0) - g_lastMasterOffRequestTs));
                    exit(0);   // atexit 兜底再做一次幂等全量还原
                }
            });
            dispatch_resume(g_masterIdleMonitor);
        });
    }

    // 使用自己的简易 HTTP 服务器
    static CLSimpleHTTPServer* _webServer = nil;
    if (_webServer == nil) {
        if (localPortOpen(GSERV_PORT)) {
            NSLog(@"%@ already served, exit", log_prefix);
            exit(0); // 服务已存在,退出
        }
        _webServer = [[CLSimpleHTTPServer alloc] init];
        [_webServer setPostHandler:^NSDictionary*(NSDictionary* jsonBody) {
            @autoreleasepool {
                return handleReq(jsonBody);
            }
        }];
        BOOL status = [_webServer startOnPort:GSERV_PORT bindToLocalhost:YES];
        if (!status && _webServer.failureErrno == EADDRINUSE) {
            // A stale listener can win the launchd/spawn race. Retry once after
            // it has had time to close; never widen the localhost exposure.
            NSFileErrorLog(@"%@ serve retry startup_stage=bind errno=%d error=%@ port=%d pid=%d",
                           log_prefix, _webServer.failureErrno,
                           _webServer.failureErrnoMessage ?: @"Address already in use", GSERV_PORT, getpid());
            usleep(300 * 1000);
            status = [_webServer startOnPort:GSERV_PORT bindToLocalhost:YES];
        }
        if (!status) {
            NSFileErrorLog(@"%@ serve failed, exit startup_stage=%@ errno=%d error=%@ port=%d pid=%d ppid=%d uid=%d euid=%d jbtype=%d",
                           log_prefix,
                           _webServer.failureStage.length ? _webServer.failureStage : @"unknown",
                           _webServer.failureErrno,
                           _webServer.failureErrnoMessage.length ? _webServer.failureErrnoMessage : @"unknown",
                           GSERV_PORT, getpid(), getppid(), getuid(), geteuid(), getJBType());
            NSLog(@"%@ serve failed, exit", log_prefix);
            exit(0);
        }
        NSFileInfoLog(@"%@ listen_ready backend=bsd_socket port=%d",
                       log_prefix, GSERV_PORT);
        getBatInfo(&bat_info);
        gNotifyPort = IONotificationPortCreate(kIOMasterPortDefault);
        CFRunLoopSourceRef runSrc = IONotificationPortGetRunLoopSource(gNotifyPort);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runSrc, kCFRunLoopDefaultMode);
        registerDaemonResetAndExitSignal();
        registerDaemonRestoreNotifySignal();
        refreshTrollStoreBundleCheckTimer();
        io_service_t serv = getIOPMPSServ();
        if (serv != IO_OBJECT_NULL) {
            IOServiceAddInterestNotification(gNotifyPort, serv, "IOGeneralInterest", [](void* refcon, io_service_t service, uint32_t type, void* args) { // type == kIOPMMessageBatteryStatusHasChanged
                @synchronized (Service.inst) {
                    detectUPSBattery(); // 在USB插拔事件中更新
                    onBatteryEvent(service);
                }
            }, nil, &iopmpsNoti);
            detectUPSBattery();
        }
        [LSApplicationWorkspace.defaultWorkspace addObserver:self];
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(systemTimeContextDidChange:) name:NSSystemClockDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(systemTimeContextDidChange:) name:NSSystemTimeZoneDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(systemTimeContextDidChange:) name:NSCalendarDayChangedNotification object:nil];
        isBlueEnable(); // init
        isLPMEnable();
        g_smartChargeStatus = getSmartChargeStatus();
        recoverSmartChargeCoordinationOnBootstrap();
        selfHealSmartChargeOnBootstrap();
        refreshFullChargeScheduleTimer(0);
        evaluateFullChargeSchedule(YES);
        // 开机越狱后已插电时，电池通知尚未到达、命令翻转分支走不到，加速项等
        // 充电态副作用无路径首次应用。bat_info 已由 getBatInfo 填充，主动跑一次
        // 策略；applyChargePolicy 稳态重申段会在 is_adaptor_connected &&
        // nextPolicyState==charging 时调用 performAcccharge(YES)，命中幂等守卫
        // 首次应用加速项。这是 userspace 重启后已插电稳态首次应用加速项的兜底。
        refreshBatteryStateAndApplyPolicy();
        NSFileInfoLog(@"%@ daemon_started backend=%@ port=%d",
                      log_prefix,
                      @"bsd_socket",
                      GSERV_PORT);
    }
}
@end


int main(int argc, char** argv) { // daemon_main
    @autoreleasepool {
        g_jbtype = getJBType();
        int argIndex = 1;
        while (argIndex + 1 < argc) {
            if (0 == strcmp(argv[argIndex], "--app-docs")) {
                setAppDocumentsPathOverride(@(argv[argIndex + 1]));
                argIndex += 2;
                continue;
            }
            break;
        }

        if (argIndex >= argc) {
            g_serv_boot = (int)time(0);
            uint32_t entryCSFlags = 0;
            errno = 0;
            int entryCSOpsRc = csops(getpid(), kCLCSOpsStatus, &entryCSFlags, sizeof(entryCSFlags));
            int entryCSOpsErrno = entryCSOpsRc == 0 ? 0 : errno;
            NSLog2(@"daemon_entry pid=%d ppid=%d uid=%d euid=%d gid=%d egid=%d csops_rc=%d csops_errno=%d csflags=0x%08x jbtype=%d app_docs_override=%d",
                           getpid(), getppid(), getuid(), geteuid(), getgid(), getegid(),
                           entryCSOpsRc, entryCSOpsErrno, entryCSFlags,
                           g_jbtype, argIndex > 1 ? 1 : 0);
            // 路径解析诊断：记录数据文件落点，不暴露包含 jbroot UUID 的可执行路径。
            @try {
                NSString* dLogPath = getLogPath();
                NSString* dConfPath = getConfPath();
                NSString* dDbPath = getDbPath();
                NSString* dDataRoot = getRuntimeDataRootPath();
                NSLog2(@"daemon_paths log=%@ conf=%@ db=%@ dataRoot=%@",
                               dLogPath ?: @"(nil)",
                               dConfPath ?: @"(nil)",
                               dDbPath ?: @"(nil)",
                               dDataRoot ?: @"(nil)");
            } @catch (NSException* e) {
                NSFileErrorLog(@"daemon_paths EXCEPTION %@", e);
            }
            int platformizeRc = -999;
            int memlimitRc = -999;
            int launchPlistRepairRc = 0;
            if (g_jbtype == JBTYPE_TROLLSTORE) {
                signal(SIGHUP, SIG_IGN);
                signal(SIGTERM, SIG_IGN); // 防止App被Kill以后daemon退出
            } else {
                platformizeRc = platformize_me(); // for jailbreak
                memlimitRc = set_mem_limit(getpid(), 80);
            }
            launchPlistRepairRc = CLRepairRoothideLaunchDaemonPlist();
            uint32_t privilegeCSFlags = 0;
            errno = 0;
            int privilegeCSOpsRc = csops(getpid(), kCLCSOpsStatus, &privilegeCSFlags, sizeof(privilegeCSFlags));
            int privilegeCSOpsErrno = privilegeCSOpsRc == 0 ? 0 : errno;
            NSLog2(@"daemon_privilege platformize_rc=%d memlimit_rc=%d launch_plist_repair_rc=%d pid=%d uid=%d euid=%d gid=%d egid=%d csops_rc=%d csops_errno=%d csflags=0x%08x",
                           platformizeRc, memlimitRc, launchPlistRepairRc, getpid(), getuid(), geteuid(), getgid(), getegid(),
                           privilegeCSOpsRc, privilegeCSOpsErrno, privilegeCSFlags);
            [Service.inst serve];
            atexit_b(^{
                if (g_fullChargeScheduleTimer != nil) {
                    [g_fullChargeScheduleTimer invalidate];
                    g_fullChargeScheduleTimer = nil;
                }
                if (g_disableInflowRetryTimer != nil) {
                    [g_disableInflowRetryTimer invalidate];
                    g_disableInflowRetryTimer = nil;
                }
                if (g_trollStoreBundleCheckTimer != nil) {
                    [g_trollStoreBundleCheckTimer invalidate];
                    g_trollStoreBundleCheckTimer = nil;
                }
                unregisterDaemonResetAndExitSignal();
                unregisterDaemonRestoreNotifySignal();
                resetBatteryStatusWithContext(YES, @"daemon_exit");
                if (iopmpsNoti != IO_OBJECT_NULL) {
                    IOObjectRelease(iopmpsNoti);
                    iopmpsNoti = IO_OBJECT_NULL;
                }
                releaseUPSBattery(gUPSPS);
                if (gNotifyPort != 0) {
                    IONotificationPortDestroy(gNotifyPort);
                    gNotifyPort = 0;
                }
                showFloatwnd(NO);
                uninitDB();
                [NSNotificationCenter.defaultCenter removeObserver:Service.inst];
                [LSApplicationWorkspace.defaultWorkspace removeObserver:Service.inst];
            });
            [NSRunLoop.mainRunLoop run];
            NSFileErrorLog(@"daemon unexpected");
            return 0;
        } else if (argIndex < argc) {
            if (0 == strcmp(argv[argIndex], "reset")) { // 越狱下卸载前重置
                resetBatteryStatusWithContext(YES, @"cli_reset");
                return 0;
            } else if (0 == strcmp(argv[argIndex], "reset_and_exit")) {
                notify_post(kDaemonResetAndExitNotifyName.UTF8String);
                usleep(300 * 1000);
                resetBatteryStatusWithContext(YES, @"cli_reset_and_exit_fallback");
                return 0;
            } else if (0 == strcmp(argv[argIndex], "restore")) {
                // CLI 还原入口：先通知运行中的 daemon 进程内还原（清会话/配置一致），
                // 再由本进程兜底执行（daemon 未运行时无进程内状态问题）。
                notify_post(kDaemonRestoreNotifyName.UTF8String);
                usleep(300 * 1000);
                NSDictionary* result = performFullSmartChargeRestore(@"cli_restore");
                NSLog(@"restore result: %@", result);
                return 0;
            } else if (0 == strcmp(argv[argIndex], "cleanup_data_container")) {
                return cleanupAppDataContainer_C();
            } else if (0 == strcmp(argv[argIndex], "watch_bat_info")) {
                BOOL slim = (argc - argIndex) >= 2;
                while (true) {
                    getBatInfo(&bat_info, slim);
                    NSLog(@"%@", bat_info);
                    [NSThread sleepForTimeInterval:1.0];
                    spawn(@[@"clear"], nil, nil, nil, 0, nil);
                }
                return 0;
            } else if (0 == strcmp(argv[argIndex], "set_charge") && (argIndex + 1) < argc) {
                bool flag = argv[argIndex + 1][0] - '0';
                setChargeStatus(flag);
                return 0;
            } else if (0 == strcmp(argv[argIndex], "set_inflow") && (argIndex + 1) < argc) {
                bool flag = argv[argIndex + 1][0] - '0';
                setInflowStatus(flag);
                return 0;
            }
        }
        return -1;
    }
}

#endif
