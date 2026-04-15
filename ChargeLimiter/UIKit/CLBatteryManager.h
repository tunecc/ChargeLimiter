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

typedef NS_ENUM(NSInteger, CLHoldModeBehavior) {
    CLHoldModeBehaviorBalanced = 0,
    CLHoldModeBehaviorPowerFirst,
    CLHoldModeBehaviorBatteryFirst,
    CLHoldModeBehaviorAdaptive
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
@property(nonatomic, assign, readonly) BOOL predictiveChargingInhibitActive; // 处于系统停充抑制
@property(nonatomic, assign, readonly) BOOL chargeCommandEnabled;            // daemon 允许继续充电
@property(nonatomic, assign, readonly) BOOL holdActive;                      // 插电保持模式生效中
@property(nonatomic, assign, readonly) BOOL holdCharging;                    // 插电保持模式正在补电
@property(nonatomic, assign, readonly) NSInteger holdTarget;                 // 插电保持目标
@property(nonatomic, assign, readonly) NSInteger holdRangeLower;             // 插电保持下边界
@property(nonatomic, assign, readonly) CLHoldModeBehavior holdRuntimeBehavior; // 插电保持当前生效策略
@property(nonatomic, copy, readonly, nullable) NSString *holdAdaptiveLoadLevel; // 自适应负载等级
@property(nonatomic, assign, readonly) NSInteger holdAdaptiveAverageCurrent; // 自适应近几次平均电流 mA
@property(nonatomic, copy, readonly, nullable) NSString *policyState;        // daemon 当前策略状态
@property(nonatomic, copy, readonly, nullable) NSString *policyReason;       // 当前策略原因
@property(nonatomic, copy, readonly, nullable) NSString *lastPolicyChangeReason; // 最近一次策略切换原因
@property(nonatomic, assign, readonly) NSTimeInterval lastPolicyChangeTime;  // 最近一次策略切换时间
@property(nonatomic, assign, readonly) NSTimeInterval lastChargeCommandTime; // 最近一次充电命令时间
@property(nonatomic, assign, readonly) NSTimeInterval lastInflowCommandTime; // 最近一次禁流/恢复时间
@property(nonatomic, assign, readonly) NSInteger smartChargeStatus;          // 系统优化充电状态
@property(nonatomic, assign, readonly) BOOL smartChargeManagedByDaemon;      // 由 daemon 临时停用
@property(nonatomic, assign, readonly) NSInteger smartChargeOriginalStatus;  // 接管前系统优化充电状态
@property(nonatomic, copy, readonly, nullable) NSString *smartChargeCoordinationSessionID; // 协调会话 ID
@property(nonatomic, assign, readonly) NSTimeInterval smartChargeCoordinationStartTime; // 本次协调开始时间
@property(nonatomic, assign, readonly) NSInteger holdDischargeStreak;        // 当前持续放电计数
@property(nonatomic, assign, readonly) NSInteger holdMonitorIntervalSeconds; // hold 轮询间隔
@property(nonatomic, assign, readonly) BOOL holdEarlyRechargeAssistEnabled;  // 提前补电辅助
@property(nonatomic, assign, readonly) NSInteger holdEarlyRechargeStreakRequired; // 提前补电所需计数
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *policyTransitionHistory; // 最近若干次策略切换
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *policyEventHistory; // 持久化策略事件时间线

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
@property(nonatomic, assign) BOOL systemCapacityControlAt100Enabled; // 100% 时交由系统控制
@property(nonatomic, assign) BOOL disableSmartCharge;      // 永久停用系统优化充电
@property(nonatomic, assign) BOOL disableInflow;           // 禁流
@property(nonatomic, assign) BOOL holdModeEnabled;         // 插电保持
@property(nonatomic, assign) NSInteger holdModeBand;       // 插电保持带宽
@property(nonatomic, assign) CLHoldModeBehavior holdModeBehavior; // 插电保持策略
@property(nonatomic, assign) BOOL holdTempDisableSmartCharge; // 插电保持时临时停用系统优化充电
@property(nonatomic, assign) BOOL limitInflow;             // 限流
@property(nonatomic, assign) CLThermalMode thermalMode;    // 高温模拟
@property(nonatomic, assign) CLThermalMode limitInflowThermalMode;
@property(nonatomic, assign) BOOL thermalModeLock;
@property(nonatomic, assign) CLThermalMode thermalSimulateMode; // 实际系统温度等级
@property(nonatomic, assign) BOOL fullChargeScheduleEnabled;    // 满充计划
@property(nonatomic, assign) NSInteger fullChargeScheduleIntervalDays;
@property(nonatomic, assign) NSInteger fullChargeScheduleStartMinute;
@property(nonatomic, assign) NSInteger fullChargeScheduleDurationHours;

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
