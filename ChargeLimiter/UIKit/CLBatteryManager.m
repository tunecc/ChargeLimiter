//
//  CLBatteryManager.m
//  ChargeLimiter
//

#import "CLBatteryManager.h"
#import "CLAPIClient.h"

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
@end

@implementation CLBatteryManager

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
        _chargeBelow = 20;
        _chargeAbove = 80;
        _chargeTempBelow = 35;  // 降温恢复温度
        _chargeTempAbove = 40;  // 高温停充温度
        _chargeMode = CLChargeModePlugAndCharge;
    }
    return self;
}

#pragma mark - 刷新数据

- (void)refreshBatteryInfo {
    [[CLAPIClient shared] getBatteryInfoWithCompletion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        if (error || !response) {
            [self updateDaemonStatus:NO];
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
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:CLBatteryInfoDidUpdateNotification object:self];
    }];
}

- (void)refreshConfig {
    [[CLAPIClient shared] getConfigWithKey:nil completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        if (error || !response) {
            [self updateDaemonStatus:NO];
            return;
        }
        
        [self updateDaemonStatus:YES];
        
        NSDictionary *data = response[@"data"];
        if (!data) return;
        
        // 解析配置 - 直接设置 ivar 避免触发 setter 重新保存到服务器
        _enabled = [data[@"enable"] boolValue];
        
        NSString *mode = data[@"mode"];
        if ([mode isEqualToString:@"charge_on_plug"]) {
            _chargeMode = CLChargeModePlugAndCharge;
        } else if ([mode isEqualToString:@"edge_trigger"]) {
            _chargeMode = CLChargeModeEdgeTrigger;
        }
        
        _updateFrequency = [data[@"update_freq"] integerValue];
        _chargeBelow = [data[@"charge_below"] integerValue];
        _chargeAbove = [data[@"charge_above"] integerValue];
        _tempControlEnabled = [data[@"enable_temp"] boolValue];
        _chargeTempBelow = [data[@"charge_temp_below"] integerValue];
        _chargeTempAbove = [data[@"charge_temp_above"] integerValue];
        
        _accChargeEnabled = [data[@"acc_charge"] boolValue];
        _accChargeAirMode = [data[@"acc_charge_airmode"] boolValue];
        _accChargeWifi = [data[@"acc_charge_wifi"] boolValue];
        _accChargeBluetooth = [data[@"acc_charge_blue"] boolValue];
        _accChargeBrightness = [data[@"acc_charge_bright"] boolValue];
        _accChargeLPM = [data[@"acc_charge_lpm"] boolValue];
        
        _predictiveInhibitCharge = [data[@"adv_predictive_inhibit_charge"] boolValue];
        _disableInflow = [data[@"adv_disable_inflow"] boolValue];
        _limitInflow = [data[@"adv_limit_inflow"] boolValue];
        _thermalModeLock = [data[@"adv_thermal_mode_lock"] boolValue];
        
        _thermalMode = [self thermalModeFromString:data[@"adv_def_thermal_mode"]];
        _limitInflowThermalMode = [self thermalModeFromString:data[@"adv_limit_inflow_mode"]];
        _thermalSimulateMode = [self thermalModeFromString:data[@"thermal_simulate_mode"]];
        
        // 系统信息
        _appVersion = data[@"ver"];
        _systemVersion = data[@"sysver"];
        _deviceModel = data[@"devmodel"];
        _systemBootTime = [data[@"sys_boot"] doubleValue];
        _serviceBootTime = [data[@"serv_boot"] doubleValue];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigDidUpdateNotification object:self];
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

- (void)saveConfigKey:(NSString *)key value:(id)value completion:(void (^)(BOOL))completion {
    [[CLAPIClient shared] setConfigWithKey:key value:value completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        BOOL success = (response && [response[@"status"] intValue] == 0);
        if (completion) {
            completion(success);
        }
    }];
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
    if (_chargeMode != chargeMode) {
        _chargeMode = chargeMode;
        NSString *modeStr = (chargeMode == CLChargeModePlugAndCharge) ? @"charge_on_plug" : @"edge_trigger";
        [self saveConfigKey:@"mode" value:modeStr completion:nil];
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

- (void)setAccChargeEnabled:(BOOL)accChargeEnabled {
    if (_accChargeEnabled != accChargeEnabled) {
        _accChargeEnabled = accChargeEnabled;
        [self saveConfigKey:@"acc_charge" value:@(accChargeEnabled) completion:nil];
    }
}

@end
