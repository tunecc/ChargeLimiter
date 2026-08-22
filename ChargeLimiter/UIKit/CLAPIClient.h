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
- (void)setLimitInflowEnabled:(BOOL)enabled mode:(NSString *)mode completion:(nullable CLAPICallback)completion;

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

// 便捷方法 - 获取策略事件
- (void)getPolicyEventsWithLimit:(NSInteger)limit lastID:(NSInteger)lastID completion:(CLAPICallback)completion;

// 便捷方法 - 清空历史统计
- (void)clearStatisticsWithCompletion:(nullable CLAPICallback)completion;

// 便捷方法 - 运行停充控制探针（诊断用）
- (void)runChargeControlProbeWithWaitMs:(NSInteger)waitMs
                                restore:(BOOL)restore
                             completion:(CLAPICallback)completion;

// 便捷方法 - 运行停充控制探针（诊断用，可指定自定义 paths/services；nil 用 daemon 默认）
- (void)runChargeControlProbeWithWaitMs:(NSInteger)waitMs
                                restore:(BOOL)restore
                                  paths:(nullable NSArray<NSString *> *)paths
                               services:(nullable NSArray<NSString *> *)services
                             completion:(CLAPICallback)completion;

// 便捷方法 - 拉取只读诊断(环境/读电量链路);失败不重启 daemon
- (void)getDiagWithCompletion:(CLAPICallback)completion;

@end

NS_ASSUME_NONNULL_END
