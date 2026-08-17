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
static void performAcccharge(BOOL flag);
static void restoreSmartChargeForReset(NSString* reason);
static void restoreThermalSimulationForReset(void);
static void restoreAcceleratedChargeStateForReset(void);
static void resetBatteryStatusWithContext(BOOL restoreRuntimeSideEffects, NSString* reason);
static void refreshTrollStoreBundleCheckTimer(void);

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
    if (disableInflow.boolValue) { // 禁流模式下只能通过电源信息判断, 某些时候系统会缓存该信息导致不准确
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

static void refreshThermalSelfHealTimer(BOOL active);

static NSString* desiredThermalSimulationModeForCurrentState(NSDictionary* info) {
    NSString* defaultMode = getLocalString(@"adv_def_thermal_mode", @"off");
    if (getLocalBool(@"adv_thermal_mode_lock", NO)) {
        refreshThermalSelfHealTimer(NO);
        return defaultMode;
    }
    if (!getLocalBool(@"adv_limit_inflow", NO)) {
        refreshThermalSelfHealTimer(NO);
        return defaultMode;
    }

    NSDictionary* safeInfo = [info isKindOfClass:[NSDictionary class]] ? info : bat_info;
    if (safeInfo == nil) {
        safeInfo = @{};
    }

    // 限流只在真实充电会话激活：适配器已连接 +（充电命令允许 或 存在充电电流）。
    // 不单信 IsCharging（iOS17 粘滞为 true）与 g_chargeCommandEnabled（初始 YES 且可能粘滞），
    // 否则未插电时也会向 cltm 持续写限流模式，长期模拟高温态漂移。
    BOOL adaptorConnected = isAdaptorConnect(safeInfo, @(getLocalBool(@"adv_disable_inflow", NO)));
    BOOL chargeAllowed = g_chargeCommandEnabled || currentLooksCharging(getEffectiveBatteryCurrent(safeInfo));
    BOOL chargeSessionActive = adaptorConnected && chargeAllowed;
    if (!chargeSessionActive) {
        refreshThermalSelfHealTimer(NO);
        return defaultMode;
    }
    refreshThermalSelfHealTimer(YES);

    return getLocalString(@"adv_limit_inflow_mode", defaultMode);
}

// ensure 语义：读回 cltm pref 校验，不一致重写并记事件。
// 锁屏期间 cltm/cfprefsd 可能清除或覆盖 thermalSimulationMode，且锁屏期电池事件
// 稀疏，事件驱动 sync 存在空窗——写后无校验的话，pref 丢失无感知、无自愈。
static void syncThermalSimulationModeForCurrentState(NSDictionary* info) {
    NSString* desired = desiredThermalSimulationModeForCurrentState(info);
    NSString* actual = getThermalSimulationModePref();
    if ([actual isEqualToString:desired]) {
        return;
    }
    setThermalSimulationMode(desired);
    NSString* reread = getThermalSimulationModePref();
    if (![reread isEqualToString:desired]) {
        NSFileErrorLog(@"thermal write unconfirmed desired=%@ reread=%@", desired, reread);
        appendPolicyEventHistory(@"thermal_event",
                                 g_policyState ?: @"",
                                 g_policyState ?: @"",
                                 @"thermal_write_unconfirmed",
                                 info ?: bat_info,
                                 @{ @"desired_mode": desired ?: @"", @"reread_mode": reread ?: @"" },
                                 time(0));
    }
}

static dispatch_source_t g_thermalSelfHealTimer = nil;

// 限流会话激活期间启动 60s 周期自愈：锁屏期电池事件稀疏，事件驱动 sync 有空窗，
// cltm 若在锁屏期清了 pref，靠本定时器兜底重写（原版无此问题是因为它从不重写、
// pref 一次写入长期留存，但新架构需要主动维持）。
// 用 armed 标志而非 suspend：dispatch_suspend 重复调用会过度暂停导致崩溃。
static void refreshThermalSelfHealTimer(BOOL active) {
    if (active) {
        if (g_thermalSelfHealTimer == nil) {
            g_thermalSelfHealTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                            dispatch_get_global_queue(0, 0));
            dispatch_source_set_event_handler(g_thermalSelfHealTimer, ^{
                NSDictionary* info = nil;
                if (0 != getBatInfo(&info)) {
                    info = nil;
                }
                syncThermalSimulationModeForCurrentState(info);
            });
            dispatch_resume(g_thermalSelfHealTimer);
        }
        dispatch_source_set_timer(g_thermalSelfHealTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
                                  60 * NSEC_PER_SEC, 0);
    }
    // 停止即把间隔推到遥远未来；timer 保持 resumed，避免 suspend/resume 状态机问题
    else if (g_thermalSelfHealTimer != nil) {
        dispatch_source_set_timer(g_thermalSelfHealTimer,
                                  DISPATCH_TIME_FOREVER, 60 * NSEC_PER_SEC, 0);
    }
}

static uint64_t g_thermalSyncGeneration = 0;

// UI 切限流等级会连发两条 set_conf（开关+等级）；逐键立即 sync 会在两条间
// 用旧等级写一次 thermalSimulationMode。合并为 200ms 去抖，最终只写一次最终配置。
// 每次 dispatch_after 各自捕获 gen，被更新请求取代的旧块在触发时早退。
// （不能用单一 dispatch_source：其 handler 只创建一次，捕获首次 gen，后续触发会被误判为过期。）
static void scheduleDebouncedThermalSync(void) {
    uint64_t gen = ++g_thermalSyncGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(0, 0), ^{
        if (gen != g_thermalSyncGeneration) {
            return;
        }
        // 用局部快照，不写共享 bat_info（该块跑在 global queue，与 handler/runloop 并发）
        NSDictionary* info = nil;
        if (0 != getBatInfo(&info)) {
            info = nil;
        }
        syncThermalSimulationModeForCurrentState(info);
    });
}

static int setBatteryStatus(BOOL flag) {
    if (g_chargeControlProbeRunning) {
        return 0; // 探针期间忽略自动写
    }
    int ret = setChargeStatus(flag);
    syncThermalSimulationModeForCurrentState(bat_info);
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
    setSmartChargeEnable(shouldRestorePermanentSmartChargeDisableForResetReason(reason) ? YES : NO);
}

static void restoreThermalSimulationForReset(void) {
    setThermalSimulationMode(@"off");
}

static void restoreAcceleratedChargeStateForReset(void) {
    performAcccharge(NO);
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
    syncThermalSimulationModeForCurrentState(bat_info);
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

static void recoverSmartChargeCoordinationOnBootstrap(void) {
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
            setSmartChargeEnable(NO);
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
    // 启动自愈：若本地配置已放行(disable_smart_charge=NO)但系统的「优化充电」仍
    // 处于关闭态（常见于旧版永久停用的残留），自动重新打开，让已卡死的用户
    // 装新包重启 daemon 后无需任何手动操作即可恢复。
    BOOL permanentlyDisableSmartCharge = getLocalBool(@"disable_smart_charge", NO);
    if (permanentlyDisableSmartCharge) {
        return;
    }
    if (!isSmartChargeEnable()) {
        setSmartChargeEnable(YES);
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
            setSmartChargeEnable(NO);
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

NSDictionary* handleReq(NSDictionary* nsreq) {
    syncDaemonDocumentsForRequest(nsreq);
    NSString* api = nsreq[@"api"];
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
            if (!g_enable) {
                resetBatteryStatus();
                tryRestoreSmartChargeAfterCoordination(@"daemon_disabled");
            } else { // 启用时检查
                BOOL disableSmartCharge = getLocalBool(@"disable_smart_charge", NO);
                if (disableSmartCharge) {
                    if (isSmartChargeEnable()) {
                        setSmartChargeEnable(NO);
                    }
                }
                evaluateFullChargeSchedule(YES);
            }
        } else if ([key isEqualToString:@"disable_smart_charge"]) {
            // 关闭「永久停用系统优化充电」时，必须把系统优化充电重新打开。
            // disableSmartCharging: 写的是系统级开关，仅改本地配置不会恢复。
            if (![val boolValue] && !isSmartChargeEnable()) {
                setSmartChargeEnable(YES);
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
        if ([@[
            @"adv_limit_inflow",
            @"adv_limit_inflow_mode",
            @"adv_def_thermal_mode",
            @"adv_thermal_mode_lock"
        ] containsObject:key]) {
            scheduleDebouncedThermalSync();
        }
        if (shouldRefreshBatteryPolicyForConfigKey(key)) {
            refreshBatteryStateAndApplyPolicy();
        }
        return @{
            @"status": @0,
        };
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
