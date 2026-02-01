//
//  CLSimpleHTTPServer.h
//  ChargeLimiter
//
//  简易 HTTP 服务器，替代 GCDWebServers
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSDictionary *_Nullable (^CLHTTPRequestHandler)(NSDictionary *_Nullable jsonBody);

@interface CLSimpleHTTPServer : NSObject

@property(nonatomic, readonly) BOOL isRunning;
@property(nonatomic, readonly) NSUInteger port;

- (instancetype)init;

/// 设置静态文件目录
- (void)setDocumentRoot:(NSString *)path;

/// 设置 POST 请求处理器
- (void)setPostHandler:(CLHTTPRequestHandler)handler;

/// 启动服务器
- (BOOL)startOnPort:(NSUInteger)port bindToLocalhost:(BOOL)localhost;

/// 停止服务器
- (void)stop;

@end

NS_ASSUME_NONNULL_END
