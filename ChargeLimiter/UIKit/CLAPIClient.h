//
//  CLAPIClient.h
//  ChargeLimiter
//
//  HTTP API 客户端 - 与 daemon 通信
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CLAPICallback)(NSDictionary *_Nullable response, NSError *_Nullable error);

@interface CLAPIClient : NSObject

+ (instancetype)shared;

// 基础请求方法
- (void)sendRequest:(NSDictionary *)params completion:(CLAPICallback)completion;

// 便捷方法 - 获取配置
- (void)getConfigWithKey:(nullable NSString *)key completion:(CLAPICallback)completion;

// 便捷方法 - 设置配置
- (void)setConfigWithKey:(NSString *)key value:(id)value completion:(nullable CLAPICallback)completion;

// 便捷方法 - 获取电池信息
- (void)getBatteryInfoWithCompletion:(CLAPICallback)completion;

// 便捷方法 - 立即执行策略
- (void)applyNowWithCompletion:(nullable CLAPICallback)completion;

// 便捷方法 - 设置充电状态
- (void)setChargeStatus:(BOOL)charging completion:(nullable CLAPICallback)completion;

// 便捷方法 - 设置电源连接状态
- (void)setInflowStatus:(BOOL)connected completion:(nullable CLAPICallback)completion;

// 便捷方法 - 重置配置
- (void)resetConfigWithCompletion:(nullable CLAPICallback)completion;

// 便捷方法 - 获取历史统计数据
- (void)getStatisticsWithConf:(NSDictionary *)conf completion:(CLAPICallback)completion;

// 便捷方法 - 获取历史数据
- (void)getHistoryWithType:(NSString *)type completion:(CLAPICallback)completion;

// 检查 daemon 是否存活
- (void)checkDaemonAliveWithCompletion:(void (^)(BOOL alive))completion;

@end

NS_ASSUME_NONNULL_END
