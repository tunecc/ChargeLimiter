//
//  CLSimpleHTTPServer.m
//  ChargeLimiter
//
//  简易 HTTP 服务器，替代 GCDWebServers
//  使用 BSD Socket 实现
//

#import "CLSimpleHTTPServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#include <math.h>

static id CLJSONSafeObject(id object) {
    if (object == nil || object == [NSNull null]) {
        return [NSNull null];
    }
    if ([object isKindOfClass:[NSString class]]) {
        return object;
    }
    if ([object isKindOfClass:[NSNumber class]]) {
        double value = [(NSNumber *)object doubleValue];
        return isfinite(value) ? object : @0;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *safeDictionary = [NSMutableDictionary dictionary];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            NSString *safeKey = [key isKindOfClass:[NSString class]] ? key : [key description];
            if (safeKey.length == 0) {
                return;
            }
            safeDictionary[safeKey] = CLJSONSafeObject(value);
        }];
        return safeDictionary;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *safeArray = [NSMutableArray arrayWithCapacity:[(NSArray *)object count]];
        for (id value in (NSArray *)object) {
            [safeArray addObject:CLJSONSafeObject(value)];
        }
        return safeArray;
    }
    if ([object isKindOfClass:[NSSet class]]) {
        NSMutableArray *safeArray = [NSMutableArray arrayWithCapacity:[(NSSet *)object count]];
        for (id value in (NSSet *)object) {
            [safeArray addObject:CLJSONSafeObject(value)];
        }
        return safeArray;
    }
    if ([object isKindOfClass:[NSData class]]) {
        return [(NSData *)object base64EncodedStringWithOptions:0] ?: @"";
    }
    if ([object isKindOfClass:[NSDate class]]) {
        return @([(NSDate *)object timeIntervalSince1970]);
    }
    if ([object isKindOfClass:[NSURL class]]) {
        return [(NSURL *)object absoluteString] ?: @"";
    }
    return [object description] ?: @"";
}

static NSData *CLJSONResponseData(id object, NSInteger *statusCode) {
    id safeObject = CLJSONSafeObject(object);
    if (![NSJSONSerialization isValidJSONObject:safeObject]) {
        if (statusCode != NULL) {
            *statusCode = 500;
        }
        safeObject = @{@"error": @"Invalid JSON response"};
    }

    NSError *jsonError = nil;
    NSData *data = nil;
    @try {
        data = [NSJSONSerialization dataWithJSONObject:safeObject options:0 error:&jsonError];
    } @catch (NSException *exception) {
        NSLog(@"[CLSimpleHTTPServer] JSON response exception: %@", exception);
    }

    if (data == nil) {
        if (statusCode != NULL) {
            *statusCode = 500;
        }
        data = [@"{\"error\":\"Invalid JSON response\"}" dataUsingEncoding:NSUTF8StringEncoding];
        if (jsonError != nil) {
            NSLog(@"[CLSimpleHTTPServer] JSON response error: %@", jsonError);
        }
    }
    return data;
}

@interface CLSimpleHTTPServer ()
@property (nonatomic, assign) int serverSocket;
@property (nonatomic, strong) NSString *documentRoot;
@property (nonatomic, copy) CLHTTPRequestHandler postHandler;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, strong) dispatch_queue_t handlerQueue;
@property (nonatomic, assign) NSUInteger serverPort;
@end

@implementation CLSimpleHTTPServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _running = NO;
        _serverQueue = dispatch_queue_create("com.chargelimiter.httpserver", DISPATCH_QUEUE_SERIAL);
        // 请求处理走独立串行队列：acceptLoop 是死循环，不能与 handler 共用同一串行队列，
        // 否则 acceptLoop 永不返回会饿死后续请求；同时串行保证 handleReq 不会并发执行
        // （真机崩溃：并发队列里 get_statistics 与 reload_conf 的 uninitDB+initDB 互踩）。
        _handlerQueue = dispatch_queue_create("com.chargelimiter.httpserver.handler", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning {
    return _running;
}

- (NSUInteger)port {
    return _serverPort;
}

- (void)setDocumentRoot:(NSString *)path {
    _documentRoot = path;
}

- (void)setPostHandler:(CLHTTPRequestHandler)handler {
    _postHandler = handler;
}

- (BOOL)startOnPort:(NSUInteger)port bindToLocalhost:(BOOL)localhost {
    if (_running) {
        return YES;
    }
    
    _serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_serverSocket < 0) {
        NSLog(@"[CLSimpleHTTPServer] Failed to create socket");
        return NO;
    }
    
    // 允许端口重用
    int opt = 1;
    setsockopt(_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = localhost ? inet_addr("127.0.0.1") : INADDR_ANY;
    
    if (bind(_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[CLSimpleHTTPServer] Failed to bind to port %lu", (unsigned long)port);
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }
    
    if (listen(_serverSocket, 10) < 0) {
        NSLog(@"[CLSimpleHTTPServer] Failed to listen");
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }
    
    _serverPort = port;
    _running = YES;
    
    NSLog(@"[CLSimpleHTTPServer] Started on port %lu", (unsigned long)port);
    
    // 启动接受连接的循环
    dispatch_async(_serverQueue, ^{
        [self acceptLoop];
    });
    
    return YES;
}

- (void)stop {
    _running = NO;
    if (_serverSocket >= 0) {
        close(_serverSocket);
        _serverSocket = -1;
    }
    NSLog(@"[CLSimpleHTTPServer] Stopped");
}

- (void)acceptLoop {
    while (_running && _serverSocket >= 0) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientSocket = accept(_serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
        
        if (clientSocket < 0) {
            if (_running) {
                NSLog(@"[CLSimpleHTTPServer] Accept failed");
            }
            continue;
        }
        
        // 在串行 handler 队列中串行处理请求（保证 handleReq 幂等于同一时刻仅一条在跑）
        dispatch_async(_handlerQueue, ^{
            [self handleClient:clientSocket];
        });
    }
}

- (void)handleClient:(int)clientSocket {
    @autoreleasepool {
        // 设置超时
        struct timeval timeout;
        timeout.tv_sec = 5;
        timeout.tv_usec = 0;
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        
        // 读取请求
        char buffer[8192];
        ssize_t bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
        
        if (bytesRead <= 0) {
            close(clientSocket);
            return;
        }
        
        buffer[bytesRead] = '\0';
        NSString *request = [NSString stringWithUTF8String:buffer];
        
        // 解析请求
        NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) {
            close(clientSocket);
            return;
        }
        
        NSString *requestLine = lines[0];
        NSArray *parts = [requestLine componentsSeparatedByString:@" "];
        if (parts.count < 2) {
            close(clientSocket);
            return;
        }
        
        NSString *method = parts[0];
        NSString *path = parts[1];
        
        // 解析 Content-Length
        NSInteger contentLength = 0;
        NSInteger headerEndIndex = 0;
        for (NSInteger i = 1; i < lines.count; i++) {
            NSString *line = lines[i];
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                NSString *value = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                contentLength = [value integerValue];
            }
            if (line.length == 0) {
                headerEndIndex = i;
                break;
            }
        }
        
        // 获取请求体
        NSString *body = nil;
        if (contentLength > 0 && headerEndIndex > 0) {
            NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
            if (bodyRange.location != NSNotFound) {
                body = [request substringFromIndex:bodyRange.location + 4];
                
                // 如果 body 不完整，继续读取
                while (body.length < contentLength && _running) {
                    bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
                    if (bytesRead <= 0) break;
                    buffer[bytesRead] = '\0';
                    body = [body stringByAppendingString:[NSString stringWithUTF8String:buffer]];
                }
            }
        }
        
        // 处理请求
        NSData *responseData = nil;
        NSString *contentType = @"text/html";
        NSInteger statusCode = 200;
        
        if ([method isEqualToString:@"POST"]) {
            // 处理 POST 请求
            NSDictionary *jsonBody = nil;
            if (body.length > 0) {
                NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
                jsonBody = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
            }
            
            if (_postHandler) {
                NSDictionary *result = nil;
                @try {
                    result = _postHandler(jsonBody);
                } @catch (NSException *exception) {
                    NSLog(@"[CLSimpleHTTPServer] POST handler exception: %@", exception);
                }
                if (result) {
                    responseData = CLJSONResponseData(result, &statusCode);
                    contentType = @"application/json";
                } else {
                    statusCode = 500;
                    responseData = [@"{\"error\":\"Internal error\"}" dataUsingEncoding:NSUTF8StringEncoding];
                    contentType = @"application/json";
                }
            } else {
                statusCode = 404;
                responseData = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
            }
        } else if ([method isEqualToString:@"GET"]) {
            // 处理 GET 请求（静态文件）
            if (_documentRoot) {
                // 去除查询参数
                NSString *filePath = path;
                NSRange queryRange = [filePath rangeOfString:@"?"];
                if (queryRange.location != NSNotFound) {
                    filePath = [filePath substringToIndex:queryRange.location];
                }
                
                // 默认 index.html
                if ([filePath isEqualToString:@"/"] || [filePath hasSuffix:@"/"]) {
                    filePath = [filePath stringByAppendingString:@"index.html"];
                }
                
                // URL 解码
                filePath = [filePath stringByRemovingPercentEncoding];
                
                // 安全检查，防止路径遍历
                if ([filePath containsString:@".."]) {
                    statusCode = 403;
                    responseData = [@"Forbidden" dataUsingEncoding:NSUTF8StringEncoding];
                } else {
                    NSString *fullPath = [_documentRoot stringByAppendingPathComponent:filePath];
                    
                    if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
                        responseData = [NSData dataWithContentsOfFile:fullPath];
                        contentType = [self mimeTypeForPath:fullPath];
                    } else {
                        // 尝试 404.htm
                        NSString *notFoundPath = [_documentRoot stringByAppendingPathComponent:@"404.htm"];
                        if ([[NSFileManager defaultManager] fileExistsAtPath:notFoundPath]) {
                            statusCode = 404;
                            responseData = [NSData dataWithContentsOfFile:notFoundPath];
                        } else {
                            statusCode = 404;
                            responseData = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
                        }
                    }
                }
            } else {
                statusCode = 404;
                responseData = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
            }
        } else {
            statusCode = 405;
            responseData = [@"Method Not Allowed" dataUsingEncoding:NSUTF8StringEncoding];
        }
        
        // 发送响应
        [self sendResponse:clientSocket statusCode:statusCode contentType:contentType data:responseData];
        
        close(clientSocket);
    }
}

- (NSString *)mimeTypeForPath:(NSString *)path {
    NSString *ext = [path.pathExtension lowercaseString];
    
    static NSDictionary *mimeTypes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mimeTypes = @{
            @"html": @"text/html; charset=utf-8",
            @"htm": @"text/html; charset=utf-8",
            @"css": @"text/css; charset=utf-8",
            @"js": @"application/javascript; charset=utf-8",
            @"json": @"application/json; charset=utf-8",
            @"png": @"image/png",
            @"jpg": @"image/jpeg",
            @"jpeg": @"image/jpeg",
            @"gif": @"image/gif",
            @"svg": @"image/svg+xml",
            @"ico": @"image/x-icon",
            @"woff": @"font/woff",
            @"woff2": @"font/woff2",
            @"ttf": @"font/ttf",
            @"eot": @"application/vnd.ms-fontobject",
            @"md": @"text/markdown; charset=utf-8",
            @"txt": @"text/plain; charset=utf-8",
        };
    });
    
    return mimeTypes[ext] ?: @"application/octet-stream";
}

- (void)sendResponse:(int)socket statusCode:(NSInteger)statusCode contentType:(NSString *)contentType data:(NSData *)data {
    NSString *statusText = @"OK";
    switch (statusCode) {
        case 200: statusText = @"OK"; break;
        case 403: statusText = @"Forbidden"; break;
        case 404: statusText = @"Not Found"; break;
        case 405: statusText = @"Method Not Allowed"; break;
        case 500: statusText = @"Internal Server Error"; break;
    }
    
    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)statusCode, statusText];
    [header appendFormat:@"Content-Type: %@\r\n", contentType];
    [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)data.length];
    [header appendString:@"Connection: close\r\n"];
    [header appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [header appendString:@"\r\n"];
    
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    send(socket, headerData.bytes, headerData.length, 0);
    
    if (data.length > 0) {
        send(socket, data.bytes, data.length, 0);
    }
}

@end
