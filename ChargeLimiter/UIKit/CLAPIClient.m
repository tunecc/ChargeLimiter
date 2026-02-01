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
#else
#define GSERV_PORT 1230
#endif

@interface CLAPIClient ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURL *baseURL;
@property (nonatomic, assign) BOOL useMockData;
@end

@implementation CLAPIClient

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
    }
    return self;
}

#pragma mark - Mock 数据

- (NSDictionary *)mockBatteryInfo {
    // 模拟电池数据，用于 UI 测试
    static NSInteger mockCapacity = 75;
    static BOOL mockCharging = YES;
    
    // 模拟电量变化
    if (mockCharging) {
        mockCapacity = MIN(mockCapacity + 1, 100);
        if (mockCapacity >= 80) mockCharging = NO;
    } else {
        mockCapacity = MAX(mockCapacity - 1, 20);
        if (mockCapacity <= 20) mockCharging = YES;
    }
    
    return @{
        @"status": @0,
        @"data": @{
            @"CurrentCapacity": @(mockCapacity),
            @"AppleRawCurrentCapacity": @(2800 + arc4random_uniform(100)),
            @"NominalChargeCapacity": @3687,
            @"DesignCapacity": @3687,
            @"Temperature": @(2500 + arc4random_uniform(500)),  // 25-30℃
            @"CycleCount": @156,
            @"Amperage": mockCharging ? @(800 + arc4random_uniform(200)) : @(-300 - arc4random_uniform(100)),
            @"InstantAmperage": mockCharging ? @(850 + arc4random_uniform(150)) : @(-280 - arc4random_uniform(80)),
            @"Voltage": @(3850 + arc4random_uniform(200)),
            @"BootVoltage": @3750,
            @"IsCharging": @(mockCharging),
            @"ExternalConnected": @YES,
            @"ExternalChargeCapable": @YES,
            @"BatteryInstalled": @YES,
            @"Serial": @"MOCK12345",
            @"UpdateTime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
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
            @"acc_charge": @NO,
            @"acc_charge_airmode": @YES,
            @"acc_charge_wifi": @NO,
            @"acc_charge_blue": @NO,
            @"acc_charge_bright": @NO,
            @"acc_charge_lpm": @YES,
            @"use_smart": @YES,
            @"adv_predictive_inhibit_charge": @NO,
            @"adv_disable_inflow": @NO,
            @"adv_limit_inflow": @NO,
            @"adv_def_thermal_mode": @"off",
            @"adv_limit_inflow_mode": @"off",
            @"adv_thermal_mode_lock": @NO,
            @"ver": @"1.7.0",
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
    } else if ([api isEqualToString:@"reset_conf"]) {
        NSLog(@"[CL-Mock] 重置配置");
        return @{@"status": @0};
    }
    return @{@"status": @(-1), @"error": @"Unknown API"};
}

#pragma mark - 基础请求

- (void)sendRequest:(NSDictionary *)params completion:(CLAPICallback)completion {
    // Mock 模式
    if (self.useMockData) {
        NSString *api = params[@"api"];
        NSDictionary *response = [self mockResponseForAPI:api params:params];
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:params options:0 error:&jsonError];
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
    [self sendRequest:params completion:completion];
}

- (void)getBatteryInfoWithCompletion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"get_bat_info"} completion:completion];
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

- (void)getHistoryWithType:(NSString *)type completion:(CLAPICallback)completion {
    [self sendRequest:@{@"api": @"get_history", @"type": type} completion:completion];
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
