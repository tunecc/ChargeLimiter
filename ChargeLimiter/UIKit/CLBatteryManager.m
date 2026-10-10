//
//  CLBatteryManager.m
//  ChargeLimiter
//

#import "CLBatteryManager.h"
#import "CLAPIClient.h"
#import <IOKit/IOKitLib.h>
extern NSDictionary* getAllKV_C(void);
extern void setlocalKV_C(NSString* key, id val);
extern int spawnDaemonCLIVerb_C(NSArray<NSString*>* verbArgs); // utils.mm：一次性 root CLI（仅限流会话写入）
// utils.mm 内核态只读辅助（fix-thermal-limit-live-loop D3，C 链接，App/daemon 共用）
extern BOOL CLThermalReadSessionChannel(BOOL *enabled, uint64_t *chargeMode, uint64_t *idleMode);
extern NSString *CLThermalModeName(uint64_t mode);
extern NSString *CLThermalExternalSimulationSource(void);

NSNotificationName const CLBatteryInfoDidUpdateNotification = @"CLBatteryInfoDidUpdateNotification";
NSNotificationName const CLConfigDidUpdateNotification = @"CLConfigDidUpdateNotification";
NSNotificationName const CLDaemonStatusDidChangeNotification = @"CLDaemonStatusDidChangeNotification";

@interface CLBatteryManager ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, assign) BOOL daemonAlive;

// 电池信息 (内部可写)
@property (nonatomic, assign) NSInteger currentCapacity;
@property (nonatomic, assign) NSInteger rawCapacity;
@property (nonatomic, assign) NSInteger nominalCapacity;
@property (nonatomic, assign) NSInteger designCapacity;
@property (nonatomic, assign) CGFloat temperature;
@property (nonatomic, assign) NSInteger cycleCount;
@property (nonatomic, assign) NSInteger health;
@property (nonatomic, assign) NSInteger amperage;
@property (nonatomic, assign) NSInteger instantAmperage;
@property (nonatomic, assign) CGFloat voltage;
@property (nonatomic, assign) CGFloat bootVoltage;
@property (nonatomic, assign) BOOL isCharging;
@property (nonatomic, assign) BOOL externalConnected;
@property (nonatomic, assign) BOOL externalChargeCapable;
@property (nonatomic, assign) BOOL batteryInstalled;
@property (nonatomic, copy, nullable) NSString *serial;
@property (nonatomic, assign) NSTimeInterval updateTime;
@property (nonatomic, assign) BOOL predictiveChargingInhibitActive;
@property (nonatomic, assign) BOOL chargeCommandEnabled;
@property (nonatomic, assign) BOOL holdActive;
@property (nonatomic, assign) BOOL holdCharging;
@property (nonatomic, assign) NSInteger holdTarget;
@property (nonatomic, assign) NSInteger holdRangeLower;
@property (nonatomic, copy, nullable) NSString *policyState;
@property (nonatomic, copy, nullable) NSString *policyReason;
@property (nonatomic, copy, nullable) NSString *lastPolicyChangeReason;
@property (nonatomic, assign) NSTimeInterval lastPolicyChangeTime;
@property (nonatomic, assign) NSTimeInterval lastChargeCommandTime;
@property (nonatomic, assign) NSTimeInterval lastInflowCommandTime;
@property (nonatomic, assign) NSInteger smartChargeStatus;
@property (nonatomic, assign) BOOL smartChargeManagedByDaemon;
@property (nonatomic, assign) NSInteger smartChargeOriginalStatus;
@property (nonatomic, copy, nullable) NSString *smartChargeCoordinationSessionID;
@property (nonatomic, assign) NSTimeInterval smartChargeCoordinationStartTime;
@property (nonatomic, assign) NSInteger holdMonitorIntervalSeconds;
@property (nonatomic, copy) NSArray<NSDictionary *> *policyTransitionHistory;
@property (nonatomic, copy) NSArray<NSDictionary *> *policyEventHistory;

// 适配器信息
@property (nonatomic, copy, nullable) NSString *adapterName;
@property (nonatomic, copy, nullable) NSString *adapterDescription;
@property (nonatomic, copy, nullable) NSString *adapterManufacturer;
@property (nonatomic, assign) CGFloat adapterVoltage;
@property (nonatomic, assign) NSInteger adapterCurrent;
@property (nonatomic, assign) NSInteger adapterWatts;
@property (nonatomic, assign) BOOL isWirelessCharging;

// 系统信息
@property (nonatomic, copy, nullable) NSString *systemVersion;
@property (nonatomic, copy, nullable) NSString *deviceModel;
@property (nonatomic, copy, nullable) NSString *appVersion;
@property (nonatomic, assign) NSTimeInterval systemBootTime;
@property (nonatomic, assign) NSTimeInterval serviceBootTime;

// 仅限流模式（daemon-free）内部状态
@property (nonatomic, assign) BOOL limitOnlyModeFlag;      // conf: limit_only_mode
@property (nonatomic, assign) BOOL limitOnlySessionEnabled; // daemon 报告的 root 域会话键
@property (nonatomic, assign) BOOL directPlugConnected;     // 直读插电（零 daemon 依赖）
@property (nonatomic, assign) BOOL directIsCharging;        // 直读充电态（IsCharging 不可读时按 YES）
@property (nonatomic, assign) BOOL directReadAvailable;     // 直读是否成功
@property (nonatomic, assign) BOOL limitOnlyApplied;        // thermalState 探针判定

// 诚实诊断面内部状态（fix-thermal-limit-live-loop D3/D4）
@property (nonatomic, assign) BOOL sessionChannelEnabled;
@property (nonatomic, copy) NSString *sessionChannelMode;
@property (nonatomic, copy) NSString *sessionChannelIdleMode;
@property (nonatomic, copy) NSString *externalSimulationSource;
@property (nonatomic, copy) NSString *thermalApplySource;
@property (nonatomic, assign) NSTimeInterval thermalApplyCheckedAt;
@property (nonatomic, assign) CLLimitOnlyVerifyState limitOnlyVerifyState;
@property (nonatomic, assign) NSTimeInterval limitOnlyVerifyIssuedAt;
@property (nonatomic, strong) NSTimer *limitOnlyVerifyTimer; // 窗口限定计时器（非常驻）
@property (nonatomic, assign) BOOL previousDirectPlugConnected;
@property (nonatomic, assign) CLLimitOnlyActiveScope previousLimitOnlyScope; // 上一次的生效时段（边沿判据）
@property (nonatomic, assign) BOOL limitOnlyReestablishDone;  // D5 启动重建每启动至多一次
@property (nonatomic, copy) NSString *limitOnlyReestablishStatus; // D5 重建结果（诊断可见）
// thermal-sim-settings：生效范围由 daemon 裁决上报，外部只读、内部按刷新结果覆写
@property (nonatomic, copy, nullable) NSString *thermalActiveScope;
@end

@implementation CLBatteryManager

- (void)applyConfigData:(NSDictionary *)data {
    if (![data isKindOfClass:[NSDictionary class]]) return;

    _enabled = [data[@"enable"] boolValue];
    _notificationEnabled = [data[@"action"] isKindOfClass:[NSString class]] && [data[@"action"] isEqualToString:@"noti"];

    NSString *mode = data[@"mode"];
    if ([mode isEqualToString:@"charge_on_plug"]) {
        _chargeMode = CLChargeModePlugAndCharge;
    } else if ([mode isEqualToString:@"edge_trigger"]) {
        _chargeMode = CLChargeModePlugAndCharge;
        [self saveConfigKey:@"mode" value:@"charge_on_plug" completion:nil];
    } else {
        _chargeMode = CLChargeModePlugAndCharge;
    }

    _updateFrequency = [data[@"update_freq"] integerValue];
    _chargeBelow = [data[@"charge_below"] integerValue];
    _chargeAbove = [data[@"charge_above"] integerValue];
    _tempControlEnabled = [data[@"enable_temp"] boolValue];
    _chargeTempBelow = [data[@"charge_temp_below"] integerValue];
    _chargeTempAbove = [data[@"charge_temp_above"] integerValue];
    id historyStatsEnabledValue = data[@"history_stats_enabled"];
    _historyStatsEnabled = historyStatsEnabledValue == nil ? YES : [historyStatsEnabledValue boolValue];

    _accChargeEnabled = [data[@"acc_charge"] boolValue];
    _accChargeAirMode = [data[@"acc_charge_airmode"] boolValue];
    _accChargeWifi = [data[@"acc_charge_wifi"] boolValue];
    _accChargeBluetooth = [data[@"acc_charge_blue"] boolValue];
    _accChargeBrightness = [data[@"acc_charge_bright"] boolValue];
    _accChargeLPM = [data[@"acc_charge_lpm"] boolValue];

    _predictiveInhibitCharge = [data[@"adv_predictive_inhibit_charge"] boolValue];
    id systemCapacityControlAt100Value = data[@"adv_system_capacity_control_at_100"];
    _systemCapacityControlAt100Enabled = systemCapacityControlAt100Value == nil ? YES : [systemCapacityControlAt100Value boolValue];
    _disableSmartCharge = [data[@"disable_smart_charge"] boolValue];
    _disableInflow = [data[@"adv_disable_inflow"] boolValue];
    _holdModeEnabled = [data[@"adv_hold_enabled"] boolValue];
    _holdModeBand = MAX([data[@"adv_hold_band"] integerValue], 1);
    _holdCheckIntervalMinutes = MAX([data[@"adv_hold_check_interval_minutes"] integerValue], 1);
    _holdTempDisableSmartCharge = [data[@"adv_hold_temp_disable_smart_charge"] boolValue];
    _limitInflow = [data[@"adv_limit_inflow"] boolValue];

    _thermalMode = [self thermalModeFromString:data[@"adv_def_thermal_mode"]];
    _limitInflowThermalMode = [self thermalModeFromString:data[@"adv_limit_inflow_mode"]];
    _thermalSimulateMode = [self thermalModeFromString:data[@"thermal_simulate_mode"]];
    // 生效范围由 daemon 裁决并上报（thermal-sim-settings D7）：App 只显示，不自行推导。
    // 缺失（旧 daemon / 本地回退配置）时保持 nil，UI 显示占位而不编造。
    NSString *thermalActiveScopeValue = data[@"thermal_active_scope"];
    if ([thermalActiveScopeValue isKindOfClass:[NSString class]] && thermalActiveScopeValue.length > 0) {
        _thermalActiveScope = thermalActiveScopeValue;
    } else {
        _thermalActiveScope = nil;
    }
    // 合并前的旧配置标记（thermal-sim-settings）：只用于 App 弹一次合并说明
    _thermalMergeNoticePending = [data[@"thermal_merge_notice"] boolValue];
    // 生效验证诊断（design D5）：区分"已配置"与"已生效"。
    NSString *thermalConfigValue = data[@"thermal_config_mode"];
    _thermalConfigMode = ([thermalConfigValue isKindOfClass:[NSString class]] && thermalConfigValue.length > 0) ? thermalConfigValue : @"off";
    NSString *thermalApplyStatusValue = data[@"thermal_apply_status"];
    _thermalApplyStatus = ([thermalApplyStatusValue isKindOfClass:[NSString class]] && thermalApplyStatusValue.length > 0) ? thermalApplyStatusValue : @"unknown";
    // daemon-probe 口径的判定时间（D3 修复：完整控制模式显示 daemon 实际验证时间，
    // 非 App 观察时刻；仅限流模式由 refreshLimitOnlyDiagnostics 覆写为活探针时间）
    NSString *thermalApplyCheckedValue = data[@"thermal_apply_checked_at"];
    if ([thermalApplyCheckedValue isKindOfClass:[NSString class]] && thermalApplyCheckedValue.length > 0) {
        _thermalApplyCheckedAt = [thermalApplyCheckedValue doubleValue];
    }

    // 仅限流模式（limit-only daemon-free）：模式标志 + root 域会话诊断
    _limitOnlyModeFlag = [data[@"limit_only_mode"] boolValue];
    _limitOnlySessionEnabled = [data[@"limit_only_session_enabled"] boolValue];
    NSString *limitOnlyLevelValue = data[@"limit_only_level"];
    // 键在场就采纳，含「关闭」（limit-only-idle-thermal-level：off 是合法用户值）。
    // 旧实现在这里跳过 off，理由是"daemon 侧会话缺省的诊断值不得污染真实档位"——那个理由
    // 在 off 非法时代成立，合法化后反把用户选过的关闭冲掉：仅限流模式 daemon 不在场，
    // 走本地 KV 回退读到 off 也不覆写，重启后档位退回 init 缺省中度，再被 reestablish
    // 归一化并重写内核态。"缺省"与"选过关闭"的区分改由 daemon 侧不上报未配置键来保证
    // （getLimitOnlyLevelConfigured），这里只负责"在场即采纳"。
    if ([limitOnlyLevelValue isKindOfClass:[NSString class]] && limitOnlyLevelValue.length > 0) {
        _limitOnlyLevel = limitOnlyLevelValue;
    }
    NSString *limitOnlyIdleLevelValue = data[@"limit_only_idle_level"];
    // 平时档位同上：在场即采纳，含关闭
    if ([limitOnlyIdleLevelValue isKindOfClass:[NSString class]] && limitOnlyIdleLevelValue.length > 0) {
        _limitOnlyIdleLevel = limitOnlyIdleLevelValue;
    }
    _fullChargeScheduleEnabled = [data[@"full_charge_sched_enabled"] boolValue];
    _fullChargeScheduleIntervalDays = [data[@"full_charge_sched_interval_days"] integerValue];
    _fullChargeScheduleStartMinute = [data[@"full_charge_sched_start_minute"] integerValue];
    _fullChargeScheduleDurationHours = [data[@"full_charge_sched_duration_hours"] integerValue];

    _appVersion = data[@"ver"];
    _systemVersion = data[@"sysver"];
    _deviceModel = data[@"devmodel"];
    _systemBootTime = [data[@"sys_boot"] doubleValue];
    _serviceBootTime = [data[@"serv_boot"] doubleValue];
}

- (NSDictionary *)localConfigFallback {
    NSDictionary *all = getAllKV_C();
    if (![all isKindOfClass:[NSDictionary class]] || all.count == 0) {
        return nil;
    }
    NSMutableDictionary *m = [all mutableCopy];
    if (!m[@"enable"]) m[@"enable"] = @YES;
    if (!m[@"action"]) m[@"action"] = @"";
    if (!m[@"mode"]) m[@"mode"] = @"charge_on_plug";
    if (!m[@"update_freq"]) m[@"update_freq"] = @1;
    if (!m[@"charge_below"]) m[@"charge_below"] = @20;
    if (!m[@"charge_above"]) m[@"charge_above"] = @80;
    if (!m[@"enable_temp"]) m[@"enable_temp"] = @NO;
    if (!m[@"charge_temp_below"]) m[@"charge_temp_below"] = @35;
    if (!m[@"charge_temp_above"]) m[@"charge_temp_above"] = @40;
    if (!m[@"history_stats_enabled"]) m[@"history_stats_enabled"] = @YES;
    if (!m[@"disable_smart_charge"]) m[@"disable_smart_charge"] = @NO;
    if (!m[@"adv_system_capacity_control_at_100"]) m[@"adv_system_capacity_control_at_100"] = @YES;
    if (!m[@"adv_hold_enabled"]) m[@"adv_hold_enabled"] = @NO;
    if (!m[@"adv_hold_band"]) m[@"adv_hold_band"] = @5;
    if (!m[@"adv_hold_check_interval_minutes"]) m[@"adv_hold_check_interval_minutes"] = @3;
    if (!m[@"adv_hold_behavior"]) m[@"adv_hold_behavior"] = @"balanced";
    if (!m[@"adv_hold_temp_disable_smart_charge"]) m[@"adv_hold_temp_disable_smart_charge"] = @YES;
    if (!m[@"full_charge_sched_enabled"]) m[@"full_charge_sched_enabled"] = @NO;
    if (!m[@"full_charge_sched_interval_days"]) m[@"full_charge_sched_interval_days"] = @7;
    if (!m[@"full_charge_sched_start_minute"]) m[@"full_charge_sched_start_minute"] = @120;
    if (!m[@"full_charge_sched_duration_hours"]) m[@"full_charge_sched_duration_hours"] = @4;
    if (!m[@"limit_only_mode"]) m[@"limit_only_mode"] = @NO;
    // 两个档位键都不在这里填缺省值：缺键时由 init 的缺省（充电时中度 / 平时关闭）提供，
    // 而"用户选过关闭"必须能穿透到 applyConfigData——填了字面值反而分不出是谁的值。
    return m;
}

+ (instancetype)shared {
    static CLBatteryManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CLBatteryManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _updateFrequency = 1;
        _notificationEnabled = NO;
        _chargeBelow = 20;
        _chargeAbove = 80;
        _chargeTempBelow = 35;  // 降温恢复温度
        _chargeTempAbove = 40;  // 高温停充温度
        _historyStatsEnabled = YES;
        _chargeMode = CLChargeModePlugAndCharge;
        _systemCapacityControlAt100Enabled = YES;
        _holdModeBand = 2;
        _holdCheckIntervalMinutes = 3;
        _fullChargeScheduleIntervalDays = 7;
        _fullChargeScheduleStartMinute = 120;
        _fullChargeScheduleDurationHours = 4;
        _limitOnlyLevel = @"moderate"; // 档位缺省中度（fix-limit-only-restart-state M4）
        _limitOnlyIdleLevel = @"off";  // 平时档位缺省关闭：与升级前"拔线即解除"的实际效果一致
        _policyTransitionHistory = @[];
        _policyEventHistory = @[];
    }
    return self;
}

#pragma mark - 刷新数据

- (void)refreshBatteryInfo {
    [[CLAPIClient shared] getBatteryInfoWithCompletion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        if (error || !response) {
            [self updateDaemonStatus:NO];
            // daemon 不在场就没有裁决来源：清掉生效范围，UI 显示占位而不是上一次的残留
            self.thermalActiveScope = nil;
            // 仅限流模式：daemon 死亡路径无电池事件通知——复用既有 1s 刷新链观察
            // 插拔边沿与探针（会话状态行不滞留旧值；不新增常驻轮询，timer 本就存在）
            if (self.operationMode == CLOperationModeLimitOnly) {
                [self refreshDirectSessionState];
            }
            return;
        }
        
        [self updateDaemonStatus:YES];
        
        NSDictionary *data = response[@"data"];
        if (!data) return;
        
        // 解析电池信息
        self.currentCapacity = [data[@"CurrentCapacity"] integerValue];
        self.rawCapacity = [data[@"AppleRawCurrentCapacity"] integerValue];
        self.nominalCapacity = [data[@"NominalChargeCapacity"] integerValue];
        self.designCapacity = [data[@"DesignCapacity"] integerValue];
        self.temperature = [data[@"Temperature"] doubleValue] / 100.0;
        self.cycleCount = [data[@"CycleCount"] integerValue];
        self.amperage = [data[@"Amperage"] integerValue];
        self.instantAmperage = [data[@"InstantAmperage"] integerValue];
        self.voltage = [data[@"Voltage"] doubleValue] / 1000.0;
        self.bootVoltage = [data[@"BootVoltage"] doubleValue] / 1000.0;
        self.isCharging = [data[@"IsCharging"] boolValue];
        self.externalConnected = [data[@"ExternalConnected"] boolValue];
        self.externalChargeCapable = [data[@"ExternalChargeCapable"] boolValue];
        self.batteryInstalled = [data[@"BatteryInstalled"] boolValue];
        self.serial = data[@"Serial"];
        self.updateTime = [data[@"UpdateTime"] doubleValue];
        self.predictiveChargingInhibitActive = [data[@"PredictiveChargingInhibitActive"] boolValue];
        self.chargeCommandEnabled = [data[@"ChargeCommandEnabled"] boolValue];
        self.holdActive = [data[@"HoldActive"] boolValue];
        self.holdCharging = [data[@"HoldCharging"] boolValue];
        self.holdTarget = [data[@"HoldTarget"] integerValue];
        self.holdRangeLower = [data[@"HoldRangeLower"] integerValue];
        self.policyState = data[@"PolicyState"];
        self.policyReason = data[@"PolicyReason"];
        self.lastPolicyChangeReason = data[@"LastPolicyChangeReason"];
        self.lastPolicyChangeTime = [data[@"LastPolicyChangeTime"] doubleValue];
        self.lastChargeCommandTime = [data[@"LastChargeCommandTime"] doubleValue];
        self.lastInflowCommandTime = [data[@"LastInflowCommandTime"] doubleValue];
        self.thermalSimulateMode = [self thermalModeFromString:data[@"ThermalSimulateMode"]];
        // 生效范围随电池轮询活更新（thermal-sim-settings）：插拔边沿不必等整页重建。
        // 旧 daemon 不带该字段时保持 nil，由 UI 显示占位。
        NSString *batteryScope = data[@"ThermalActiveScope"];
        self.thermalActiveScope = ([batteryScope isKindOfClass:[NSString class]] && batteryScope.length > 0) ? batteryScope : nil;
        self.smartChargeStatus = [data[@"SmartChargeStatus"] integerValue];
        self.smartChargeManagedByDaemon = [data[@"SmartChargeManagedByDaemon"] boolValue];
        self.smartChargeOriginalStatus = [data[@"SmartChargeOriginalStatus"] integerValue];
        self.smartChargeCoordinationSessionID = [data[@"SmartChargeCoordinationSessionID"] isKindOfClass:[NSString class]] ? data[@"SmartChargeCoordinationSessionID"] : nil;
        self.smartChargeCoordinationStartTime = [data[@"SmartChargeCoordinationStartTime"] doubleValue];
        self.holdMonitorIntervalSeconds = [data[@"HoldMonitorIntervalSeconds"] integerValue];
        NSArray *history = data[@"PolicyTransitionHistory"];
        self.policyTransitionHistory = [history isKindOfClass:[NSArray class]] ? history : @[];
        NSArray *eventHistory = data[@"PolicyEventHistory"];
        self.policyEventHistory = [eventHistory isKindOfClass:[NSArray class]] ? eventHistory : @[];
        
        // 计算健康度
        if (self.designCapacity > 0) {
            self.health = (self.nominalCapacity * 100) / self.designCapacity;
        }
        
        // 解析适配器信息
        NSDictionary *adapter = data[@"AdapterDetails"];
        if (adapter) {
            self.adapterName = adapter[@"Name"];
            self.adapterDescription = adapter[@"Description"];
            self.adapterManufacturer = adapter[@"Manufacturer"];
            self.adapterVoltage = [adapter[@"Voltage"] doubleValue] / 1000.0;
            self.adapterCurrent = [adapter[@"Current"] integerValue];
            self.adapterWatts = [adapter[@"Watts"] integerValue];
            self.isWirelessCharging = [adapter[@"IsWireless"] boolValue];
        } else {
            self.adapterName = nil;
            self.adapterDescription = nil;
            self.adapterManufacturer = nil;
            self.adapterVoltage = 0;
            self.adapterCurrent = 0;
            self.adapterWatts = 0;
            self.isWirelessCharging = NO;
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:CLBatteryInfoDidUpdateNotification object:self];
    }];
}

- (void)refreshConfig {
    [[CLAPIClient shared] getConfigWithKey:nil completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        if (error || !response) {
            [self updateDaemonStatus:NO];
            NSDictionary *localData = [self localConfigFallback];
            if (localData) {
                [self applyConfigData:localData];
                [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
            }
            [self reestablishLimitOnlySessionIfNeeded]; // D5：daemon 死亡路径（仅限流常态）
            return;
        }

        [self updateDaemonStatus:YES];

        NSDictionary *data = response[@"data"];
        if (!data) return;
        [self applyConfigData:data];

        [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
        [self reestablishLimitOnlySessionIfNeeded]; // D5：daemon 在线路径
    }];
}

- (void)refreshAll {
    [self refreshBatteryInfo];
    [self refreshConfig];
}

#pragma mark - 自动刷新

- (void)startAutoRefresh {
    [self stopAutoRefresh];
    
    NSTimeInterval interval = MAX(self.updateFrequency, 1);
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                         target:self
                                                       selector:@selector(refreshBatteryInfo)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
    
    // 立即刷新一次
    [self refreshAll];
}

- (void)stopAutoRefresh {
    if (self.refreshTimer) {
        [self.refreshTimer invalidate];
        self.refreshTimer = nil;
    }
}

#pragma mark - 控制方法

- (void)setCharging:(BOOL)charging completion:(void (^)(BOOL))completion {
    [[CLAPIClient shared] setChargeStatus:charging completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        BOOL success = (response && [response[@"status"] intValue] == 0);
        if (completion) {
            completion(success);
        }
    }];
}

- (void)setInflow:(BOOL)inflow completion:(void (^)(BOOL))completion {
    [[CLAPIClient shared] setInflowStatus:inflow completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        BOOL success = (response && [response[@"status"] intValue] == 0);
        if (completion) {
            completion(success);
        }
    }];
}

- (void)resetConfigWithCompletion:(void (^)(BOOL))completion {
    [[CLAPIClient shared] resetConfigWithCompletion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        BOOL success = (response && [response[@"status"] intValue] == 0);
        if (success) {
            [self refreshConfig];
        }
        if (completion) {
            completion(success);
        }
    }];
}

- (void)clearStatisticsWithCompletion:(void (^)(BOOL))completion {
    [[CLAPIClient shared] clearStatisticsWithCompletion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        BOOL success = (response && [response[@"status"] intValue] == 0);
        if (success) {
            self.policyEventHistory = @[];
            self.policyTransitionHistory = @[];
        }
        if (completion) {
            completion(success);
        }
    }];
}

- (void)saveConfigKey:(NSString *)key value:(id)value completion:(void (^)(BOOL))completion {
    [[CLAPIClient shared] setConfigWithKey:key value:value completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        BOOL success = (response && [response[@"status"] intValue] == 0);
        if (completion) {
            completion(success);
        }
    }];
}

#pragma mark - 仅限流模式（daemon-free）

- (CLOperationMode)operationMode {
    // 三态派生（spec B1）：enable 优先——完整控制态忽略 limit_only_mode 残留
    if (_enabled) return CLOperationModeFullControl;
    return _limitOnlyModeFlag ? CLOperationModeLimitOnly : CLOperationModeOff;
}

// 分时段裁决（limit-only-idle-thermal-level）：与 tweak CLTSSessionEvaluate 同一判据——
// 插电且系统正在充电 → 充电时档位；未插电或插线未充电 → 平时档位。
// IsCharging 不可读时按"正在充电"处理（与 tweak 同向容错：误判充电会保留限流，更安全）。
// 当前是否处于"插电且正在充电"时段——分时段裁决的唯一判据实现。
// scope 计算与 UI 的关闭分支共用它：第 4 轮验收发现 UI 只用 directPlugConnected，
// 把"插着线但系统暂停充电"错判成充电时段，于是平时档位为关时显示成
// "已插电充电 · 充电档位已关闭"——设备并没在充电，该点名的是平时档位。
- (BOOL)limitOnlyChargingPeriodApplies {
    return _directPlugConnected && _directIsCharging;
}

// App 不自行推导第二套真相以外的行为：这里只决定"此刻验证哪一档、状态行报哪一档"。
- (CLLimitOnlyActiveScope)limitOnlyActiveScope {
    NSString *charge = self.limitOnlyLevel ?: @"off";
    NSString *idle = self.limitOnlyIdleLevel ?: @"off";
    if ([self limitOnlyChargingPeriodApplies]) {
        return [charge isEqualToString:@"off"] ? CLLimitOnlyScopeOff : CLLimitOnlyScopeCharging;
    }
    return [idle isEqualToString:@"off"] ? CLLimitOnlyScopeOff : CLLimitOnlyScopeIdle;
}

// 当前生效时段对应的档位名；两侧皆关时返回 off。
- (NSString *)limitOnlyActiveLevel {
    switch (self.limitOnlyActiveScope) {
        case CLLimitOnlyScopeCharging: return self.limitOnlyLevel ?: @"off";
        case CLLimitOnlyScopeIdle: return self.limitOnlyIdleLevel ?: @"off";
        case CLLimitOnlyScopeOff: return @"off";
    }
}

// D5 同款探针：系统热状态达到当前生效档位即判已生效（本进程读数，零 daemon 依赖）。
// off/nominal 无可验证通路，对齐 daemon D5 off 跳过语义直接记已生效。
- (BOOL)computeLimitOnlyApplied {
    if (self.operationMode != CLOperationModeLimitOnly) return NO;
    CLThermalMode mode = [self thermalModeFromString:self.limitOnlyActiveLevel];
    NSInteger expected;
    switch (mode) {
        case CLThermalModeLight: expected = 1; break;
        case CLThermalModeModerate: expected = 2; break;
        case CLThermalModeHeavy: expected = 3; break;
        default: return YES;
    }
    NSInteger current = 0;
    NSProcessInfoThermalState state = NSProcessInfo.processInfo.thermalState;
    if (state == NSProcessInfoThermalStateFair) current = 1;
    else if (state == NSProcessInfoThermalStateSerious) current = 2;
    else if (state == NSProcessInfoThermalStateCritical) current = 3;
    return current >= expected;
}

// 直读 AppleSmartBattery（App 目标链接 IOKit.tbd）：插电/温度/电量/充电态，
// 零 daemon 依赖。master port 用 0（iOS SDK 将 kIOMasterPortDefault 标记不可用，值即 0）。
// 读失败保持 directReadAvailable=NO，UI 回退 daemon 按需数据。
- (void)refreshDirectSessionState {
    BOOL readOK = NO;
    BOOL plugged = NO;
    BOOL isChargingReadable = NO;
    io_service_t serv = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"));
    if (serv != IO_OBJECT_NULL) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(serv, CFSTR("ExternalChargeCapable"), kCFAllocatorDefault, 0);
        CFTypeRef connected = NULL;
        if (capable == NULL) {
            connected = IORegistryEntryCreateCFProperty(serv, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
        }
        CFTypeRef temperature = IORegistryEntryCreateCFProperty(serv, CFSTR("Temperature"), kCFAllocatorDefault, 0);
        CFTypeRef isCharging = IORegistryEntryCreateCFProperty(serv, CFSTR("IsCharging"), kCFAllocatorDefault, 0);
        CFTypeRef capacity = IORegistryEntryCreateCFProperty(serv, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
        CFTypeRef plugRef = capable ?: connected;
        if (plugRef != NULL) {
            readOK = YES;
            plugged = (CFGetTypeID(plugRef) == CFBooleanGetTypeID()) ? CFBooleanGetValue(plugRef) : NO;
            self.externalConnected = plugged;
            if (capable != NULL) {
                self.externalChargeCapable = plugged;
            }
        }
        if (readOK && temperature != NULL && CFGetTypeID(temperature) == CFNumberGetTypeID()) {
            self.temperature = [(__bridge NSNumber *)temperature doubleValue] / 100.0;
        }
        if (readOK && isCharging != NULL && CFGetTypeID(isCharging) == CFBooleanGetTypeID()) {
            self.isCharging = CFBooleanGetValue(isCharging);
            _directIsCharging = CFBooleanGetValue(isCharging);
            isChargingReadable = YES;
        }
        if (readOK && capacity != NULL && CFGetTypeID(capacity) == CFNumberGetTypeID()) {
            self.currentCapacity = [(__bridge NSNumber *)capacity integerValue];
        }
        if (capable) CFRelease(capable);
        if (connected) CFRelease(connected);
        if (temperature) CFRelease(temperature);
        if (isCharging) CFRelease(isCharging);
        if (capacity) CFRelease(capacity);
        IOObjectRelease(serv);
    }
    // 充电判定（limit-only-idle-thermal-level）：IsCharging 缺失、类型不符或整次 IOKit
    // 读取失败时都按"正在充电"处理——与 tweak CLTSIsCharging 同向的容错：误判充电会保留
    // 限流（更安全的错误方向），误判未充电会让插电时的限流静默失效。
    // 放在读取块之外：读失败时也必须落到确定值，不能沿用上一轮的陈旧值。
    _directIsCharging = (readOK && isChargingReadable) ? _directIsCharging : YES;
    _directReadAvailable = readOK;
    _directPlugConnected = readOK ? plugged : _externalConnected;
    _limitOnlyApplied = [self computeLimitOnlyApplied];
    // 诚实诊断面（D3）：内核态会话通道 + 外部模拟污染检测（App mobile 可读，无特权；
    // 会话通道 enabled 缺失而写方已写过 = 写侧问题的独立证据）
    BOOL sessionEnabled = NO;
    uint64_t sessionChargeRaw = 0;
    uint64_t sessionIdleRaw = 0;
    if (CLThermalReadSessionChannel(&sessionEnabled, &sessionChargeRaw, &sessionIdleRaw)) {
        _sessionChannelEnabled = sessionEnabled;
        _sessionChannelMode = CLThermalModeName(sessionChargeRaw);
        _sessionChannelIdleMode = CLThermalModeName(sessionIdleRaw);
    } else {
        _sessionChannelEnabled = NO;    // 读取失败：不用过期值冒充（派生走本地键回退）
        _sessionChannelMode = nil;
        _sessionChannelIdleMode = nil;
    }
    _externalSimulationSource = CLThermalExternalSimulationSource();
    [self refreshLimitOnlyDiagnostics];
    // 生效时段边沿（limit-only-idle-thermal-level）：边沿从"插电/拔线"扩为"生效时段翻转"——
    // 插线但系统暂停充电（优化充电 / 80% 限制）也会让生效方从充电时档位转到平时档位。
    // 两种边沿都要重开/停掉验证窗口；只有插拔边沿才自愈重下发会话。
    // 区分理由：IsCharging 在插着线时可能短暂翻转，每次翻转都 spawn 一次性 root 进程
    // 会造成无谓churn；tweak 自己有 IOPS/interest 边沿 + 30s watchdog 兜底，
    // 不需要 App 侧对每一次充电态抖动都补一次写。
    CLLimitOnlyActiveScope scope = self.limitOnlyActiveScope;
    BOOL scopeChanged = (_previousLimitOnlyScope != scope);
    BOOL plugEdge = (_previousDirectPlugConnected != _directPlugConnected);
    _previousDirectPlugConnected = _directPlugConnected;
    _previousLimitOnlyScope = scope;
    if (self.operationMode == CLOperationModeLimitOnly && (plugEdge || scopeChanged)) {
        if (scope == CLLimitOnlyScopeOff) {
            // 当前时段没有待生效对象：停窗回 Unknown，不刷假"验证失败"
            _limitOnlyVerifyState = CLLimitOnlyVerifyUnknown;
            [self stopLimitOnlyVerifyWindow];
        } else {
            [self startLimitOnlyVerifyWindow];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
        if (plugEdge) {
            // Bug B2 自愈（2026-10-05 真机：首次插电 tweak 边沿评估可能缺位）：
            // App 侧重下发一次会话，tweak 内部按当前插电/充电态裁决，与它的边沿互为冗余
            [self applyLimitOnlyLevelsWithChargeMode:self.limitOnlyLevel
                                           idleMode:self.limitOnlyIdleLevel
                                         completion:nil];
        }
    }
}

// D3 诚实诊断派生：仅限流模式下当前值以 App 侧活数据为准——档位=会话通道内核态
// 解码（enabled 在场时如实显示，含合法 off；会话写方允许 off 配置），应用结果=App
// 活探针当前判定；daemon 遗留 KV（daemon 死后的陈旧 thermal_apply_status/快照
// thermal_config_mode）不冒充当前值。完整控制模式维持 daemon get_conf KV 口径，
// 判定时间取 daemon 的 thermal_apply_checked_at（applyConfigData 解析），只标注来源。
- (void)refreshLimitOnlyDiagnostics {
    if (self.operationMode != CLOperationModeLimitOnly) {
        _thermalApplySource = @"daemon-probe";
        return;
    }
    _thermalApplySource = @"app-probe";
    _thermalApplyCheckedAt = [[NSDate date] timeIntervalSince1970];
    // 档位如实显示当前生效时段的那一档（limit-only-idle-thermal-level）：会话在内核态时
    // 取内核态解码（含合法 off），否则回退本地键。回退值按生效时段选，不固定报充电时档位。
    NSString *fallback = self.limitOnlyActiveLevel;
    if (_sessionChannelEnabled) {
        NSString *channel = self.limitOnlyActiveScope == CLLimitOnlyScopeIdle ? _sessionChannelIdleMode : _sessionChannelMode;
        _thermalConfigMode = channel.length > 0 ? channel : fallback;
    } else {
        _thermalConfigMode = fallback.length > 0 ? fallback : @"moderate";
    }
    _thermalApplyStatus = _limitOnlyApplied ? @"applied" : @"unverified";
}

// D4 失败终态：下发后有限窗口内 1s tick 探针；达标=applied，超窗=failed（可重试）。
// 窗口用自有计时器——不挂 CLBatteryInfoDidUpdateNotification（仅限流模式下 daemon
// 已死，该通知根本不会发出，每秒刷新是空转失败路径）。
static NSTimeInterval const CLLimitOnlyVerifyWindowSeconds = 15.0;

- (void)startLimitOnlyVerifyWindow {
    // Bug B1 修复（2026-10-05 真机）经 limit-only-idle-thermal-level 修订：没有"待生效
    // 对象"才不开窗。未插电时验证对象是「平时档位」——平时档位非关闭就有对象，照常开窗；
    // 两侧皆关（scope=off）时才停窗回 Unknown，否则 15s 后必然跳假"验证失败"。
    if (self.limitOnlyActiveScope == CLLimitOnlyScopeOff) {
        _limitOnlyVerifyState = CLLimitOnlyVerifyUnknown;
        [self stopLimitOnlyVerifyWindow];
        return;
    }
    _limitOnlyVerifyIssuedAt = [[NSDate date] timeIntervalSince1970];
    _limitOnlyVerifyState = CLLimitOnlyVerifyVerifying;
    [_limitOnlyVerifyTimer invalidate];
    _limitOnlyVerifyTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [self tickLimitOnlyVerifyWindow];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_limitOnlyVerifyTimer forMode:NSRunLoopCommonModes];
    [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
}

- (void)tickLimitOnlyVerifyWindow {
    if (self.operationMode != CLOperationModeLimitOnly) {
        [self stopLimitOnlyVerifyWindow];
        return;
    }
    [self refreshDirectSessionState];
    // 拔线竞态守卫：refresh 内的边沿处理可能已转移状态（拔线回 Unknown/停表，
    // 或插电重开了新窗口）——本 tick 不得用旧窗口的判定覆盖它
    if (_limitOnlyVerifyState != CLLimitOnlyVerifyVerifying || _limitOnlyVerifyTimer == nil) {
        return;
    }
    if (self.limitOnlyApplied) {
        _limitOnlyVerifyState = CLLimitOnlyVerifyApplied;
        [self stopLimitOnlyVerifyWindow];
        [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
        return;
    }
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - _limitOnlyVerifyIssuedAt;
    if (elapsed >= CLLimitOnlyVerifyWindowSeconds) {
        _limitOnlyVerifyState = CLLimitOnlyVerifyFailed;
        [self stopLimitOnlyVerifyWindow];
        [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
    }
}

- (void)stopLimitOnlyVerifyWindow {
    [_limitOnlyVerifyTimer invalidate];
    _limitOnlyVerifyTimer = nil;
}

// D5 重启重建：App 启动后首轮配置就绪时执行一次——仅限流模式且会话通道内核态
// enabled 位缺失（重启后内核态归零且 tweak best-effort 重挂失败的场景）→ 复用
// 既有 apply_limit_only verb 补写。失败入共享存储诊断键，不阻塞启动；完整控制/
// 关闭模式不触发。
- (void)reestablishLimitOnlySessionIfNeeded {
    if (_limitOnlyReestablishDone) return;
    _limitOnlyReestablishDone = YES;
    if (self.operationMode != CLOperationModeLimitOnly) return;
    [self refreshDirectSessionState]; // 先读会话通道内核态（判据数据源）
    // 两个档位都参与一致性核对（limit-only-idle-thermal-level）：任一档与内核态解码
    // 不一致都要补写。缺省值只发生在键从未写过时：充电时档位缺省中度，平时档位缺省关闭。
    // 这里刻意不再把 off 归一成中度——归一化会把用户选过的「关闭」在重启后改回中度，
    // 并与内核态的 off 判成 mismatch 后重写，是 off 合法化后暴露的漏网缺陷。
    NSString *charge = (_limitOnlyLevel.length > 0) ? _limitOnlyLevel : @"moderate";
    NSString *idle = (_limitOnlyIdleLevel.length > 0) ? _limitOnlyIdleLevel : @"off";
    // spec 口径：缺失（enabled 位不在）或不一致（在场但档位 ≠ 本地配置）都补写
    BOOL missing = !_sessionChannelEnabled;
    BOOL mismatch = _sessionChannelEnabled &&
                    (![_sessionChannelMode isEqualToString:charge] ||
                     ![_sessionChannelIdleMode isEqualToString:idle]);
    if (!missing && !mismatch) return; // 会话在内核态且一致：无需补写
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1", charge, idle]);
        if (rc != 0) {
            rc = spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1", charge, idle]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *status = rc == 0 ? @"ok" : [NSString stringWithFormat:@"spawn_failed_%d", rc];
            _limitOnlyReestablishStatus = status; // 诊断可见（D5 修复：不能只入 KV）
            setlocalKV_C(@"limit_only_reestablish_status", status);
            setlocalKV_C(@"limit_only_reestablish_ts",
                         [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]]);
            if (rc == 0) {
                [self refreshDirectSessionState];
                [self startLimitOnlyVerifyWindow];
                [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
            }
        });
    });
}

// 两个分时段档位一次性写入（limit-only-idle-thermal-level）。
// off 是合法值（该时段不施加热模拟），此处刻意不做归一化——归一化会把用户选的「关闭」
// 偷偷改成「中度」，正是本次要修掉的假控件。缺省值只发生在键从未写过时：充电时档位
// 缺省中度，平时档位缺省关闭（与升级前"插电时限流、拔线解除"的实际效果一致）。
- (void)applyLimitOnlyLevelsWithChargeMode:(NSString *)chargeMode
                                  idleMode:(NSString *)idleMode
                                completion:(void (^)(BOOL success))completion {
    NSString *charge = (chargeMode.length > 0) ? chargeMode : @"moderate";
    NSString *idle = (idleMode.length > 0) ? idleMode : @"off";
    // 失败要能把 UI 还原成写入前的真实档位（A9/A19：不得把失败后的旧值显示成新选的值）。
    // 只回滚内存不够——本地 KV 也写了新值，下次刷新会把它读回来，UI 又会翻成新值。
    NSString *previousCharge = self.limitOnlyLevel;
    NSString *previousIdle = self.limitOnlyIdleLevel;
    self.limitOnlyLevel = charge;
    self.limitOnlyIdleLevel = idle;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 一次性 root 进程写会话键 + thermal 镜像（spec B3/B5）：daemon 始终不驻留；
        // 档位偏好走本地配置（setlocalKV_C），同样不拉起 daemon。失败重试一次。
        int rc = spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1", charge, idle]);
        if (rc != 0) {
            rc = spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1", charge, idle]);
        }
        BOOL ok = (rc == 0);
        if (ok) {
            setlocalKV_C(@"limit_only_level", charge);
            setlocalKV_C(@"limit_only_idle_level", idle);
        } else {
            // 写入未生效：档位偏好与内存一起回滚，保持「UI、本地 KV、内核态」三者一致
            setlocalKV_C(@"limit_only_level", previousCharge.length > 0 ? previousCharge : @"moderate");
            setlocalKV_C(@"limit_only_idle_level", previousIdle.length > 0 ? previousIdle : @"off");
        }
        // 给 thermalState 一点收敛窗口（对齐 daemon D5 3s 探针）后刷新验证
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)1.5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (ok) {
                [self refreshDirectSessionState];
                [self startLimitOnlyVerifyWindow]; // D4：仅下发成功才开窗（失败≠探针超窗）
            } else {
                // 先回滚再刷新：UI 显示的是写入前的档位，不是用户刚选的那个
                self.limitOnlyLevel = previousCharge;
                self.limitOnlyIdleLevel = previousIdle;
                [self refreshDirectSessionState];
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
            if (completion) completion(ok);
        });
    });
}

- (void)switchToMode:(CLOperationMode)mode completion:(void (^)(BOOL))completion {
    CLOperationMode current = self.operationMode;
    if (current == mode) {
        if (completion) completion(YES);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = YES;
        switch (mode) {
            case CLOperationModeLimitOnly: {
                // 两个档位照本地 KV 的既有值建立会话，不做 off→moderate 归一化
                // （limit-only-idle-thermal-level：off 是合法用户值，归一化即假控件）。
                // 键从未写过时用缺省：充电时档位中度、平时档位关闭。
                // 完整控制阶段 get_conf 上报的 "off" 缺省值不会污染真实档位——applyConfigData
                // 对 off 一律跳过不覆写，本地 KV 才是权威值。
                NSString *charge = self.limitOnlyLevel;
                if (charge.length == 0) {
                    charge = @"moderate";
                }
                NSString *idle = self.limitOnlyIdleLevel;
                if (idle.length == 0) {
                    idle = @"off";
                }
                self.limitOnlyLevel = charge;
                self.limitOnlyIdleLevel = idle;
                // 先落盘模式标志与档位，再停常驻（spec B1 修订次序）：daemon 关停期的
                // 配置写经共享锁与本写串行，limit_only_mode 不再被覆盖丢失；
                // daemon 配置（模式/档位/enable）仍全部先于 CLI 会话建立。
                setlocalKV_C(@"limit_only_level", charge);
                setlocalKV_C(@"limit_only_idle_level", idle);
                setlocalKV_C(@"limit_only_mode", @YES);
                if (current == CLOperationModeFullControl) {
                    [self saveConfigKey:@"enable" value:@NO completion:nil];
                }
                int rc = spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1", charge, idle]);
                if (rc != 0) {
                    rc = spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"1", charge, idle]); // 一次性重试
                }
                ok = (rc == 0);
                break;
            }
            case CLOperationModeFullControl: {
                // 仅限流→完整控制：先清会话（一次性 CLI），再开常驻（daemon bootstrap 回驻留；
                // daemon 侧 enable=YES 分支另有防御清理，双保险防会话与常驻策略打架）
                if (current == CLOperationModeLimitOnly) {
                    spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"0"]);
                }
                [self saveConfigKey:@"enable" value:@YES completion:nil];
                break;
            }
            case CLOperationModeOff: {
                if (current == CLOperationModeLimitOnly) {
                    // 先清会话（CLI），再清模式标志（本地键）；系统 thermal 已由 CLI 归零
                    spawnDaemonCLIVerb_C(@[@"apply_limit_only", @"0"]);
                    setlocalKV_C(@"limit_only_mode", @NO);
                } else if (current == CLOperationModeFullControl) {
                    [self saveConfigKey:@"enable" value:@NO completion:nil]; // master-off 全还原
                }
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                // 切换成功：乐观同步内存模式状态（operation-mode-live-refresh M1）。
                // _enabled/_limitOnlyModeFlag 仅在 refreshConfig 中赋值，不同步的话
                // operationMode 派生自过期字段，UI 要等重进页面/重启才能看到新模式。
                // （集成审查修复：先对齐再刷新——插电边沿以新派生模式判定，防会话复活竞态）
                [self alignModeStateInMemory:mode];
            }
            [self refreshDirectSessionState];
            if (ok) {
                if (mode == CLOperationModeLimitOnly) {
                    [self startLimitOnlyVerifyWindow]; // D4：切换成功即开验证窗口
                }
            } else {
                [self refreshConfig]; // 失败：以磁盘真值为准重取，完成后自行发通知
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
            if (completion) completion(ok);
        });
    });
}

// 三态与配置键映射是静态的（enable + limit_only_mode）：切换成功后直接对齐派生源。
- (void)alignModeStateInMemory:(CLOperationMode)mode {
    switch (mode) {
        case CLOperationModeFullControl:
            _enabled = YES;
            _limitOnlyModeFlag = NO;
            break;
        case CLOperationModeLimitOnly:
            _enabled = NO;
            _limitOnlyModeFlag = YES;
            break;
        case CLOperationModeOff:
            _enabled = NO;
            _limitOnlyModeFlag = NO;
            break;
    }
}

#pragma mark - 私有方法

- (void)updateDaemonStatus:(BOOL)alive {
    if (self.daemonAlive != alive) {
        self.daemonAlive = alive;
        [[NSNotificationCenter defaultCenter] postNotificationName:CLDaemonStatusDidChangeNotification object:self];
    }
}

- (CLThermalMode)thermalModeFromString:(id)value {
    // 处理 NSNumber 类型（当保存为数字时）
    if ([value isKindOfClass:[NSNumber class]]) {
        NSInteger intValue = [value integerValue];
        if (intValue >= CLThermalModeOff && intValue <= CLThermalModeHeavy) {
            return (CLThermalMode)intValue;
        }
        return CLThermalModeOff;
    }
    // 处理字符串类型
    NSString *string = value;
    if ([string isEqualToString:@"nominal"]) return CLThermalModeNominal;
    if ([string isEqualToString:@"light"]) return CLThermalModeLight;
    if ([string isEqualToString:@"moderate"]) return CLThermalModeModerate;
    if ([string isEqualToString:@"heavy"]) return CLThermalModeHeavy;
    return CLThermalModeOff;
}

- (NSString *)stringFromThermalMode:(CLThermalMode)mode {
    switch (mode) {
        case CLThermalModeNominal: return @"nominal";
        case CLThermalModeLight: return @"light";
        case CLThermalModeModerate: return @"moderate";
        case CLThermalModeHeavy: return @"heavy";
        default: return @"off";
    }
}

#pragma mark - 配置 Setter (自动保存)

- (void)setEnabled:(BOOL)enabled {
    if (_enabled != enabled) {
        _enabled = enabled;
        [self saveConfigKey:@"enable" value:@(enabled) completion:nil];
    }
}

- (void)setChargeMode:(CLChargeMode)chargeMode {
    if (_chargeMode != CLChargeModePlugAndCharge) {
        _chargeMode = CLChargeModePlugAndCharge;
    }
    [self saveConfigKey:@"mode" value:@"charge_on_plug" completion:nil];
    if (self.predictiveInhibitCharge && self.disableInflow) {
        _disableInflow = NO;
        [self saveConfigKey:@"adv_disable_inflow" value:@NO completion:nil];
    }
}

- (void)setUpdateFrequency:(NSInteger)updateFrequency {
    NSInteger normalized = MAX(updateFrequency, 1);
    if (_updateFrequency != normalized) {
        _updateFrequency = normalized;
        [self saveConfigKey:@"update_freq" value:@(normalized) completion:nil];
        // Recreate timer immediately so runtime refresh interval matches UI selection.
        if (self.refreshTimer) {
            [self startAutoRefresh];
        }
    }
}

- (void)setNotificationEnabled:(BOOL)notificationEnabled {
    if (_notificationEnabled != notificationEnabled) {
        _notificationEnabled = notificationEnabled;
        [self saveConfigKey:@"action" value:(notificationEnabled ? @"noti" : @"") completion:nil];
    }
}

- (void)setChargeBelow:(NSInteger)chargeBelow {
    if (_chargeBelow != chargeBelow) {
        _chargeBelow = chargeBelow;
        [self saveConfigKey:@"charge_below" value:@(chargeBelow) completion:nil];
    }
}

- (void)setChargeAbove:(NSInteger)chargeAbove {
    if (_chargeAbove != chargeAbove) {
        _chargeAbove = chargeAbove;
        [self saveConfigKey:@"charge_above" value:@(chargeAbove) completion:nil];
    }
}

- (void)setSystemCapacityControlAt100Enabled:(BOOL)systemCapacityControlAt100Enabled {
    if (_systemCapacityControlAt100Enabled != systemCapacityControlAt100Enabled) {
        _systemCapacityControlAt100Enabled = systemCapacityControlAt100Enabled;
        [self saveConfigKey:@"adv_system_capacity_control_at_100" value:@(systemCapacityControlAt100Enabled) completion:nil];
    }
}

- (void)setTempControlEnabled:(BOOL)tempControlEnabled {
    if (_tempControlEnabled != tempControlEnabled) {
        _tempControlEnabled = tempControlEnabled;
        [self saveConfigKey:@"enable_temp" value:@(tempControlEnabled) completion:nil];
    }
}

- (void)setChargeTempBelow:(NSInteger)chargeTempBelow {
    if (_chargeTempBelow != chargeTempBelow) {
        _chargeTempBelow = chargeTempBelow;
        [self saveConfigKey:@"charge_temp_below" value:@(chargeTempBelow) completion:nil];
    }
}

- (void)setChargeTempAbove:(NSInteger)chargeTempAbove {
    if (_chargeTempAbove != chargeTempAbove) {
        _chargeTempAbove = chargeTempAbove;
        [self saveConfigKey:@"charge_temp_above" value:@(chargeTempAbove) completion:nil];
    }
}

- (void)setHistoryStatsEnabled:(BOOL)historyStatsEnabled {
    if (_historyStatsEnabled != historyStatsEnabled) {
        _historyStatsEnabled = historyStatsEnabled;
        [self saveConfigKey:@"history_stats_enabled" value:@(historyStatsEnabled) completion:nil];
    }
}

- (void)setAccChargeEnabled:(BOOL)accChargeEnabled {
    if (_accChargeEnabled != accChargeEnabled) {
        _accChargeEnabled = accChargeEnabled;
        [self saveConfigKey:@"acc_charge" value:@(accChargeEnabled) completion:nil];
    }
}

@end
