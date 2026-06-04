//
//  CLAPIClient.m
//  ChargeLimiter
//

#import "CLAPIClient.h"
#import <TargetConditionals.h>

// Mock 模式开关 - 模拟器用 Mock 数据，真机用真实 HTTP 请求
#ifndef CL_USE_MOCK_DATA
    #if TARGET_OS_SIMULATOR
        #define CL_USE_MOCK_DATA 1  // 模拟器上使用 Mock 数据
    #else
        #define CL_USE_MOCK_DATA 0  // 真机上使用真正的 HTTP 请求
    #endif
#endif

// 仅在非 Mock 模式下包含 common.h
#if !CL_USE_MOCK_DATA
#import "../common.h"
extern void setlocalKV_C(NSString* key, id val);
extern NSString* getAppDocumentsPath_C(void);
extern BOOL localPortOpen_C(int port);
extern int restartDaemonForApp_C(NSString* appDocs);
#else
#define GSERV_PORT 1230
#endif

@interface CLAPIClient ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURL *baseURL;
@property (nonatomic, assign) BOOL useMockData;
@end

@implementation CLAPIClient

#if !CL_USE_MOCK_DATA
static void CLPersistLocalConfig(NSString *key, id value) {
    if (key.length == 0) {
        return;
    }
    // Keep a local on-disk mirror so settings survive even if daemon IPC fails.
    setlocalKV_C(key, value ?: @"");
}

static BOOL CLProcessLooksLikeTrollStore(void) {
    NSString *home = NSHomeDirectory();
    if (![home isKindOfClass:[NSString class]] || home.length == 0) {
        return NO;
    }
    NSString *lower = home.lowercaseString;
    return [lower containsString:@"/var/mobile/containers/data/application/"];
}

static int CLStartDaemonBestEffort(void) {
    NSString *appDocs = getAppDocumentsPath_C();
    int rc = restartDaemonForApp_C(appDocs);
    NSLog(@"[CL-API] daemon restart requested rc=%d docs=%@", rc, appDocs ?: @"");
    return rc;
}
#endif

+ (instancetype)shared {
    static CLAPIClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CLAPIClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 5.0;
        config.timeoutIntervalForResource = 10.0;
        _session = [NSURLSession sessionWithConfiguration:config];
        _baseURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d", GSERV_PORT]];
        _useMockData = CL_USE_MOCK_DATA;
#if !CL_USE_MOCK_DATA
        if (!localPortOpen_C(GSERV_PORT)) {
            CLStartDaemonBestEffort();
        }
#endif
    }
    return self;
}

#pragma mark - Mock 数据

- (NSDictionary *)mockBatteryInfo {
    // 模拟电池数据，用于 UI 测试
    static NSInteger mockCapacity = 75;
    static BOOL mockCharging = YES;
    static BOOL mockHoldArmed = NO;
    NSInteger now = (NSInteger)[[NSDate date] timeIntervalSince1970];
    NSDictionary *config = [self mockConfig][@"data"];
    NSInteger chargeAbove = [config[@"charge_above"] integerValue];
    NSInteger holdBand = MAX([config[@"adv_hold_band"] integerValue], 1);
    BOOL holdEnabled = [config[@"adv_hold_enabled"] boolValue];
    id systemCapacityControlAt100Value = config[@"adv_system_capacity_control_at_100"];
    BOOL systemCapacityControlAt100Enabled = systemCapacityControlAt100Value == nil ? YES : [systemCapacityControlAt100Value boolValue];
    BOOL handOverCapacityControl = (chargeAbove >= 100 && systemCapacityControlAt100Enabled);
    BOOL holdCapacityControlAvailable = holdEnabled && !handOverCapacityControl;
    NSInteger holdLower = MAX(chargeAbove - holdBand, 5);
    NSInteger holdCheckIntervalMinutes = MAX([config[@"adv_hold_check_interval_minutes"] integerValue], 1);
    
    // 模拟电量变化
    if (!holdCapacityControlAvailable) {
        mockHoldArmed = NO;
    }
    if (mockCharging) {
        mockCapacity = MIN(mockCapacity + 1, 100);
        if (holdCapacityControlAvailable && mockCapacity >= chargeAbove) {
            mockHoldArmed = YES;
            mockCharging = NO;
        } else if (!holdCapacityControlAvailable && mockCapacity >= 80) {
            mockCharging = NO;
        }
    } else {
        mockCapacity = MAX(mockCapacity - 1, 20);
        if (holdCapacityControlAvailable && mockHoldArmed && mockCapacity <= holdLower) {
            mockCharging = YES;
        } else if (!holdCapacityControlAvailable && mockCapacity <= 20) {
            mockCharging = YES;
        }
    }

    NSInteger simulatedAmperage = mockCharging ? (800 + arc4random_uniform(200)) : (-300 - arc4random_uniform(100));
    NSInteger simulatedInstantAmperage = mockCharging ? (850 + arc4random_uniform(150)) : (-280 - arc4random_uniform(80));
    BOOL holdActive = holdCapacityControlAvailable && mockHoldArmed && mockCapacity >= holdLower && mockCapacity <= chargeAbove;
    BOOL holdCharging = holdActive && mockCharging && mockCapacity < chargeAbove;
    BOOL predictiveInhibit = holdCapacityControlAvailable && mockHoldArmed && !holdCharging && mockCapacity >= holdLower && mockCapacity <= chargeAbove;
    BOOL smartChargeManaged = holdActive;
    NSString *policyState = holdCharging ? @"hold_recharge" : (predictiveInhibit ? @"hold" : (mockCharging ? @"charging" : @"battery"));
    NSString *policyReason = holdCharging ? @"hold_band_lower_reached" : (predictiveInhibit ? @"hold_target_reached" : (mockCharging ? @"charging_active" : @"battery_idle"));
    NSInteger holdMonitorIntervalSeconds = holdCheckIntervalMinutes * 60;
    NSArray *policyHistory = @[
        @{@"from": @"charging", @"to": @"hold", @"reason": @"hold_target_reached", @"ts": @(now - 180)},
        @{@"from": @"hold", @"to": @"hold_recharge", @"reason": @"hold_band_lower_reached", @"ts": @(now - 60)},
        @{@"from": holdCharging ? @"hold" : @"charging", @"to": policyState, @"reason": policyReason, @"ts": @(now - 10)}
    ];
    NSArray *policyEventHistory = @[
        @{
            @"from": @"charging",
            @"to": @"hold",
            @"reason": @"hold_target_reached",
            @"ts": @(now - 180),
            @"capacity": @(chargeAbove),
            @"temperature": @(2720),
            @"current": @(-110),
            @"is_charging": @NO,
            @"external_connected": @YES,
            @"predictive_inhibit_active": @YES,
            @"charge_command_enabled": @NO,
            @"smart_charge_status": @(3),
            @"smart_charge_managed": @YES,
            @"hold_behavior": @"balanced",
            @"hold_check_interval_minutes": @(holdCheckIntervalMinutes)
        },
        @{
            @"from": @"hold",
            @"to": @"hold_recharge",
            @"reason": @"hold_band_lower_reached",
            @"ts": @(now - 60),
            @"capacity": @(MAX(chargeAbove - holdBand, 5)),
            @"temperature": @(2810),
            @"current": @(-320),
            @"is_charging": @YES,
            @"external_connected": @YES,
            @"predictive_inhibit_active": @NO,
            @"charge_command_enabled": @YES,
            @"smart_charge_status": @(3),
            @"smart_charge_managed": @YES,
            @"hold_behavior": @"balanced",
            @"hold_check_interval_minutes": @(holdCheckIntervalMinutes)
        },
        @{
            @"from": holdCharging ? @"hold" : @"charging",
            @"to": policyState,
            @"reason": policyReason,
            @"ts": @(now - 10),
            @"capacity": @(mockCapacity),
            @"temperature": @(2500 + arc4random_uniform(500)),
            @"current": @(simulatedInstantAmperage),
            @"is_charging": @(mockCharging || predictiveInhibit),
            @"external_connected": @YES,
            @"predictive_inhibit_active": @(predictiveInhibit),
            @"charge_command_enabled": @(!predictiveInhibit),
            @"smart_charge_status": @(smartChargeManaged ? 3 : 1),
            @"smart_charge_managed": @(smartChargeManaged),
            @"hold_behavior": @"balanced",
            @"hold_check_interval_minutes": @(holdCheckIntervalMinutes)
        }
    ];

    return @{
        @"status": @0,
        @"data": @{
            @"CurrentCapacity": @(mockCapacity),
            @"AppleRawCurrentCapacity": @(2800 + arc4random_uniform(100)),
            @"NominalChargeCapacity": @3687,
            @"DesignCapacity": @3687,
            @"Temperature": @(2500 + arc4random_uniform(500)),  // 25-30℃
            @"CycleCount": @156,
            @"Amperage": @(simulatedAmperage),
            @"InstantAmperage": @(simulatedInstantAmperage),
            @"Voltage": @(3850 + arc4random_uniform(200)),
            @"BootVoltage": @3750,
            @"IsCharging": @(mockCharging || predictiveInhibit),
            @"ExternalConnected": @YES,
            @"ExternalChargeCapable": @YES,
            @"BatteryInstalled": @YES,
            @"Serial": @"MOCK12345",
            @"UpdateTime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
            @"PredictiveChargingInhibitActive": @(predictiveInhibit),
            @"ChargeCommandEnabled": @(!predictiveInhibit),
            @"HoldActive": @(holdActive),
            @"HoldCharging": @(holdCharging),
            @"HoldTarget": @(holdCapacityControlAvailable ? chargeAbove : 0),
            @"HoldRangeLower": @(holdCapacityControlAvailable ? holdLower : 0),
            @"HoldRuntimeBehavior": @"balanced",
            @"PolicyState": policyState,
            @"PolicyReason": policyReason,
            @"LastPolicyChangeReason": policyReason,
            @"LastPolicyChangeTime": @(now - 10),
            @"LastChargeCommandTime": @(now - 20),
            @"LastInflowCommandTime": @(now - 30),
            @"PolicyTransitionHistory": policyHistory,
            @"PolicyEventHistory": policyEventHistory,
            @"SmartChargeStatus": @(smartChargeManaged ? 3 : 1),
            @"SmartChargeManagedByDaemon": @(smartChargeManaged),
            @"SmartChargeOriginalStatus": @(smartChargeManaged ? 1 : -1),
            @"SmartChargeCoordinationSessionID": smartChargeManaged ? @"mock-smart-charge-session" : @"",
            @"SmartChargeCoordinationStartTime": @(smartChargeManaged ? (now - 180) : 0),
            @"HoldMonitorIntervalSeconds": @(holdCapacityControlAvailable ? holdMonitorIntervalSeconds : 0),
            @"AdapterDetails": @{
                @"Name": @"USB-C Power Adapter",
                @"Description": @"usb host",
                @"Manufacturer": @"Apple Inc.",
                @"Voltage": @5000,
                @"Current": @1500,
                @"Watts": @20,
                @"IsWireless": @NO
            }
        }
    };
}

- (NSDictionary *)mockConfig {
    static NSMutableDictionary *config = nil;
    if (!config) {
        config = [@{
            @"enable": @YES,
            @"floatwnd": @NO,
            @"floatwnd_auto": @YES,
            @"mode": @"charge_on_plug",
            @"update_freq": @1,
            @"charge_below": @20,
            @"charge_above": @80,
            @"enable_temp": @YES,
            @"charge_temp_below": @35,   // 降温恢复温度
            @"charge_temp_above": @40,   // 高温停充温度
            @"history_stats_enabled": @YES,
            @"acc_charge": @NO,
            @"acc_charge_airmode": @YES,
            @"acc_charge_wifi": @NO,
            @"acc_charge_blue": @NO,
            @"acc_charge_bright": @NO,
            @"acc_charge_lpm": @YES,
            @"use_smart": @YES,
            @"adv_predictive_inhibit_charge": @YES,
            @"adv_system_capacity_control_at_100": @YES,
            @"disable_smart_charge": @NO,
            @"adv_disable_inflow": @NO,
            @"adv_hold_enabled": @NO,
            @"adv_hold_band": @5,
            @"adv_hold_check_interval_minutes": @3,
            @"adv_hold_behavior": @"balanced",
            @"adv_hold_temp_disable_smart_charge": @YES,
            @"adv_limit_inflow": @NO,
            @"adv_def_thermal_mode": @"off",
            @"adv_limit_inflow_mode": @"off",
            @"adv_thermal_mode_lock": @NO,
            @"full_charge_sched_enabled": @NO,
            @"full_charge_sched_interval_days": @7,
            @"full_charge_sched_start_minute": @120,
            @"full_charge_sched_duration_hours": @4,
            @"ver": @"1.13.5",
            @"sysver": @"iOS 16.1.2",
            @"devmodel": @"iPhone14,2",
            @"sys_boot": @((NSInteger)[[NSDate date] timeIntervalSince1970] - 86400),
            @"serv_boot": @((NSInteger)[[NSDate date] timeIntervalSince1970] - 3600)
        } mutableCopy];
    }
    return @{@"status": @0, @"data": config};
}

- (NSDictionary *)mockResponseForAPI:(NSString *)api params:(NSDictionary *)params {
    if ([api isEqualToString:@"get_bat_info"]) {
        return [self mockBatteryInfo];
    } else if ([api isEqualToString:@"get_conf"]) {
        return [self mockConfig];
    } else if ([api isEqualToString:@"set_conf"]) {
        // 模拟保存配置
        NSString *key = params[@"key"];
        id value = params[@"val"];
        if (key && value) {
            NSMutableDictionary *config = [self mockConfig][@"data"];
            config[key] = value;
            NSLog(@"[CL-Mock] 设置配置: %@ = %@", key, value);
        }
        return @{@"status": @0};
    } else if ([api isEqualToString:@"set_charge_status"]) {
        NSLog(@"[CL-Mock] 设置充电状态: %@", params[@"flag"]);
        return @{@"status": @0};
    } else if ([api isEqualToString:@"set_inflow_status"]) {
        NSLog(@"[CL-Mock] 设置电源连接: %@", params[@"flag"]);
        return @{@"status": @0};
    } else if ([api isEqualToString:@"apply_now"]) {
        NSLog(@"[CL-Mock] 立即执行策略");
        return @{@"status": @0};
    } else if ([api isEqualToString:@"reset_conf"]) {
        NSLog(@"[CL-Mock] 重置配置");
        return @{@"status": @0};
    } else if ([api isEqualToString:@"clear_statistics"]) {
        NSLog(@"[CL-Mock] 清空历史统计");
        return @{@"status": @0};
    } else if ([api isEqualToString:@"get_statistics"]) {
        NSDictionary *conf = params[@"conf"];
        NSMutableDictionary *data = [NSMutableDictionary dictionary];
        NSInteger now = (NSInteger)[[NSDate date] timeIntervalSince1970];
        for (NSString *key in conf) {
            NSDictionary *confForKey = conf[key];
            NSInteger n = [confForKey[@"n"] integerValue];
            if (n <= 0) n = 10;
            NSMutableArray *rows = [NSMutableArray arrayWithCapacity:n];
            NSInteger step = 300;
            if ([key isEqualToString:@"hour"]) step = 3600;
            else if ([key isEqualToString:@"day"]) step = 86400;
            else if ([key isEqualToString:@"month"]) step = 2592000;
            
            for (NSInteger i = 0; i < n; i++) {
                NSInteger ts = now - i * step;
                NSInteger cap = 40 + (NSInteger)(arc4random_uniform(50));
                NSInteger temp = 2400 + (NSInteger)(arc4random_uniform(600));
                NSInteger amp = (NSInteger)(arc4random_uniform(1200)) - 400;
                NSInteger volt = 3700 + (NSInteger)(arc4random_uniform(300));
                NSInteger cycle = 120 + (NSInteger)(arc4random_uniform(50));
                NSInteger nominal = 3200 + (NSInteger)(arc4random_uniform(300));
                NSMutableDictionary *row = [@{
                    @"UpdateTime": @(ts),
                    @"CurrentCapacity": @(cap),
                    @"Temperature": @(temp),
                    @"Amperage": @(amp),
                    @"Voltage": @(volt),
                    @"CycleCount": @(cycle),
                    @"NominalChargeCapacity": @(nominal),
                } mutableCopy];
                [rows addObject:row];
            }
            data[key] = [[rows reverseObjectEnumerator] allObjects];
        }
        return @{@"status": @0, @"data": data};
    } else if ([api isEqualToString:@"get_policy_events"]) {
        NSDictionary *bat = [self mockBatteryInfo][@"data"];
        NSArray *events = [bat[@"PolicyEventHistory"] isKindOfClass:[NSArray class]] ? bat[@"PolicyEventHistory"] : @[];
        NSInteger limit = [params[@"n"] integerValue];
        NSInteger lastID = [params[@"last_id"] integerValue];
        if (limit <= 0) {
            limit = 200;
        }
        NSMutableArray *result = [NSMutableArray array];
        NSInteger nextID = 1;
        for (NSDictionary *item in events) {
            NSMutableDictionary *row = [item mutableCopy];
            row[@"id"] = @(nextID);
            row[@"type"] = row[@"type"] ?: @"policy_transition";
            if (nextID > lastID) {
                [result addObject:row];
            }
            nextID += 1;
        }
        if (result.count > limit) {
            NSRange range = NSMakeRange(result.count - limit, limit);
            result = [[result subarrayWithRange:range] mutableCopy];
        }
        return @{@"status": @0, @"data": result};
    }
    return @{@"status": @(-1), @"error": @"Unknown API"};
}

#pragma mark - 基础请求

- (void)sendRequestInternal:(NSDictionary *)params allowRetry:(BOOL)allowRetry completion:(CLAPICallback)completion {
    NSMutableDictionary *effectiveParams = [params mutableCopy];
#if !CL_USE_MOCK_DATA
    NSString *appDocs = CLProcessLooksLikeTrollStore() ? getAppDocumentsPath_C() : nil;
    if (appDocs.length > 0) {
        effectiveParams[@"app_docs"] = appDocs;
    }
#endif

    // Mock 模式
    if (self.useMockData) {
        NSString *api = effectiveParams[@"api"];
        NSDictionary *response = [self mockResponseForAPI:api params:effectiveParams];
        NSLog(@"[CL-Mock] API: %@ -> %@", api, response[@"status"]);
        
        // 模拟网络延迟
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (completion) {
                completion(response, nil);
            }
        });
        return;
    }
    
    // 真实请求
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.baseURL];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:effectiveParams options:0 error:&jsonError];
    if (jsonError) {
        NSLog(@"[CL-API] JSON序列化错误: %@", jsonError);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, jsonError);
            });
        }
        return;
    }
    request.HTTPBody = jsonData;
    
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[CL-API] 请求错误: %@", error);
#if !CL_USE_MOCK_DATA
            BOOL canRetry = allowRetry && (error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorTimedOut);
            if (canRetry) {
                int rc = CLStartDaemonBestEffort();
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    BOOL opened = NO;
                    for (int i = 0; i < 10; i++) {
                        if (localPortOpen_C(GSERV_PORT)) {
                            opened = YES;
                            break;
                        }
                        usleep(200 * 1000);
                    }
                    NSLog(@"[CL-API] retry after daemon start rc=%d portOpened=%d", rc, opened);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self sendRequestInternal:params allowRetry:NO completion:completion];
                    });
                });
                return;
            }
#endif
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, error);
                });
            }
            return;
        }
        
        if (!data) {
            NSLog(@"[CL-API] 无响应数据");
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, [NSError errorWithDomain:@"CLAPIClient" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]);
                });
            }
            return;
        }
        
        NSError *parseError = nil;
        NSDictionary *responseDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (parseError) {
            NSLog(@"[CL-API] JSON解析错误: %@", parseError);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, parseError);
                });
            }
            return;
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(responseDict, nil);
            });
        }
    }];
    [task resume];
}

- (void)sendRequest:(NSDictionary *)params completion:(CLAPICallback)completion {
    [self sendRequestInternal:params allowRetry:YES completion:completion];
}

#pragma mark - 便捷方法

- (void)getConfigWithKey:(NSString *)key completion:(CLAPICallback)completion {
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObject:@"get_conf" forKey:@"api"];
    if (key) {
        params[@"key"] = key;
    }
    [self sendRequest:params completion:completion];
}

- (void)setConfigWithKey:(NSString *)key value:(id)value completion:(CLAPICallback)completion {
    NSDictionary *params = @{
        @"api": @"set_conf",
        @"key": key,
        @"val": value
    };
    [self sendRequest:params completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
#if !CL_USE_MOCK_DATA
        BOOL accepted = (response && [response[@"status"] intValue] == 0);
        BOOL transportFailure = (error != nil || response == nil);
        // Keep local mirror for successful updates and transport failures (offline resilience),
        // but avoid persisting when daemon explicitly rejects the write.
        if (accepted || transportFailure) {
            CLPersistLocalConfig(key, value);
        }
#endif
        if (completion) {
            completion(response, error);
        }
    }];
}

- (void)getBatteryInfoWithCompletion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"get_bat_info"} completion:completion];
}

- (void)applyNowWithCompletion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"apply_now"} completion:completion];
}

- (void)setChargeStatus:(BOOL)charging completion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"set_charge_status", @"flag": @(charging)} completion:completion];
}

- (void)setInflowStatus:(BOOL)connected completion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"set_inflow_status", @"flag": @(connected)} completion:completion];
}

- (void)resetConfigWithCompletion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"reset_conf"} completion:completion];
}

- (void)getStatisticsWithConf:(NSDictionary *)conf completion:(CLAPICallback)completion {
    NSDictionary *params = @{
        @"api": @"get_statistics",
        @"conf": conf ?: @{}
    };
    [self sendRequest:params completion:completion];
}

- (void)getHistoryWithType:(NSString *)type completion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"get_history", @"type": type} completion:completion];
}

- (void)getPolicyEventsWithLimit:(NSInteger)limit lastID:(NSInteger)lastID completion:(CLAPICallback)completion {
    NSDictionary *params = @{
        @"api": @"get_policy_events",
        @"n": @(MAX(limit, 1)),
        @"last_id": @(MAX(lastID, 0))
    };
    [self sendRequest:params completion:completion];
}

- (void)clearStatisticsWithCompletion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"clear_statistics"} completion:completion];
}

- (void)checkDaemonAliveWithCompletion:(void (^)(BOOL))completion {
    [self getConfigWithKey:@"enable" completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        BOOL alive = (response != nil && [response[@"status"] intValue] == 0);
        if (completion) {
            completion(alive);
        }
    }];
}

@end
