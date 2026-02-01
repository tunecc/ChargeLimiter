//
//  CLBatteryManager.h
//  ChargeLimiter
//
//  电池数据管理器 - 管理电池状态和配置
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 充电模式
typedef NS_ENUM(NSInteger, CLChargeMode) {
    CLChargeModePlugAndCharge = 1, // 插电即充
    CLChargeModeEdgeTrigger = 2    // 边缘触发
};

// 高温模拟等级
typedef NS_ENUM(NSInteger, CLThermalMode) {
    CLThermalModeOff = 0,
    CLThermalModeNominal,
    CLThermalModeLight,
    CLThermalModeModerate,
    CLThermalModeHeavy
};

// 数据更新通知
extern NSNotificationName const CLBatteryInfoDidUpdateNotification;
extern NSNotificationName const CLConfigDidUpdateNotification;
extern NSNotificationName const CLDaemonStatusDidChangeNotification;

@interface CLBatteryManager : NSObject

+ (instancetype)shared;

#pragma mark - 连接状态
@property(nonatomic, assign, readonly) BOOL daemonAlive;

#pragma mark - 电池信息 (只读)
@property(nonatomic, assign, readonly) NSInteger currentCapacity;  // 当前电量 %
@property(nonatomic, assign, readonly) NSInteger rawCapacity;      // 原始容量 mAh
@property(nonatomic, assign, readonly) NSInteger nominalCapacity;  // 实际容量 mAh
@property(nonatomic, assign, readonly) NSInteger designCapacity;   // 设计容量 mAh
@property(nonatomic, assign, readonly) CGFloat temperature;        // 温度 ℃
@property(nonatomic, assign, readonly) NSInteger cycleCount;       // 循环次数
@property(nonatomic, assign, readonly) NSInteger health;           // 健康度 %
@property(nonatomic, assign, readonly) NSInteger amperage;         // 电流 mA
@property(nonatomic, assign, readonly) NSInteger instantAmperage;  // 瞬时电流 mA
@property(nonatomic, assign, readonly) CGFloat voltage;            // 电压 V
@property(nonatomic, assign, readonly) CGFloat bootVoltage;        // 启动电压 V
@property(nonatomic, assign, readonly) BOOL isCharging;            // 正在充电
@property(nonatomic, assign, readonly) BOOL externalConnected;     // 电源已连接
@property(nonatomic, assign, readonly) BOOL externalChargeCapable; // 电源可充电
@property(nonatomic, assign, readonly) BOOL batteryInstalled;      // 电池已安装
@property(nonatomic, copy, readonly, nullable) NSString *serial;   // 序列号
@property(nonatomic, assign, readonly) NSTimeInterval updateTime;  // 更新时间

#pragma mark - 适配器信息
@property(nonatomic, copy, readonly, nullable) NSString *adapterName;
@property(nonatomic, copy, readonly, nullable) NSString *adapterDescription;
@property(nonatomic, copy, readonly, nullable) NSString *adapterManufacturer;
@property(nonatomic, assign, readonly) CGFloat adapterVoltage;   // V
@property(nonatomic, assign, readonly) NSInteger adapterCurrent; // mA
@property(nonatomic, assign, readonly) NSInteger adapterWatts;   // W
@property(nonatomic, assign, readonly) BOOL isWirelessCharging;

#pragma mark - 配置项
@property(nonatomic, assign) BOOL enabled;              // 全局启用
@property(nonatomic, assign) CLChargeMode chargeMode;   // 充电模式
@property(nonatomic, assign) NSInteger updateFrequency; // 更新频率 (秒)
@property(nonatomic, assign) NSInteger chargeBelow;     // 电量下限 %
@property(nonatomic, assign) NSInteger chargeAbove;     // 电量上限 %
@property(nonatomic, assign) BOOL tempControlEnabled;   // 温控开关
@property(nonatomic, assign) NSInteger chargeTempBelow; // 温度下限 ℃
@property(nonatomic, assign) NSInteger chargeTempAbove; // 温度上限 ℃
@property(nonatomic, assign) BOOL accChargeEnabled;     // 加速充电
@property(nonatomic, assign) BOOL accChargeAirMode;
@property(nonatomic, assign) BOOL accChargeWifi;
@property(nonatomic, assign) BOOL accChargeBluetooth;
@property(nonatomic, assign) BOOL accChargeBrightness;
@property(nonatomic, assign) BOOL accChargeLPM;

#pragma mark - 高级选项
@property(nonatomic, assign) BOOL predictiveInhibitCharge; // 智能停充
@property(nonatomic, assign) BOOL disableInflow;           // 禁流
@property(nonatomic, assign) BOOL limitInflow;             // 限流
@property(nonatomic, assign) CLThermalMode thermalMode;    // 高温模拟
@property(nonatomic, assign) CLThermalMode limitInflowThermalMode;
@property(nonatomic, assign) BOOL thermalModeLock;

#pragma mark - 系统信息
@property(nonatomic, copy, readonly, nullable) NSString *systemVersion;
@property(nonatomic, copy, readonly, nullable) NSString *deviceModel;
@property(nonatomic, copy, readonly, nullable) NSString *appVersion;
@property(nonatomic, assign, readonly) NSTimeInterval systemBootTime;
@property(nonatomic, assign, readonly) NSTimeInterval serviceBootTime;

#pragma mark - 方法

// 刷新数据
- (void)refreshBatteryInfo;
- (void)refreshConfig;
- (void)refreshAll;

// 开始/停止自动更新
- (void)startAutoRefresh;
- (void)stopAutoRefresh;

// 控制充电
- (void)setCharging:(BOOL)charging completion:(nullable void (^)(BOOL success))completion;
- (void)setInflow:(BOOL)inflow completion:(nullable void (^)(BOOL success))completion;

// 重置配置
- (void)resetConfigWithCompletion:(nullable void (^)(BOOL success))completion;

// 保存单个配置项
- (void)saveConfigKey:(NSString *)key value:(id)value completion:(nullable void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
