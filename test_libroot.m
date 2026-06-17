#import <Foundation/Foundation.h>

// 测试 libroot API 是否可用
#ifdef __OBJC__
#import <libroot/libroot.h>
#define HAS_LIBROOT 1
#else
#define HAS_LIBROOT 0
#endif

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"=== ChargeLimiter libroot API 测试 ===");

#if HAS_LIBROOT
        NSLog(@"✅ libroot 头文件可用");

        // 测试 JBROOT_PATH_NSSTRING 宏
        NSString* testPath1 = @"/var/mobile/Library/Preferences";
        NSString* resolved1 = JBROOT_PATH_NSSTRING(testPath1);
        NSLog(@"测试 1:");
        NSLog(@"  输入: %@", testPath1);
        NSLog(@"  输出: %@", resolved1 ?: @"(nil)");

        // 测试配置文件路径
        NSString* testPath2 = @"/var/mobile/Library/Preferences/com.chargelimiter.mod.plist";
        NSString* resolved2 = JBROOT_PATH_NSSTRING(testPath2);
        NSLog(@"测试 2:");
        NSLog(@"  输入: %@", testPath2);
        NSLog(@"  输出: %@", resolved2 ?: @"(nil)");

        // 测试 jbroot 前缀
        const char* jbrootPrefix = libroot_dyn_get_jbroot_prefix();
        NSLog(@"测试 3:");
        NSLog(@"  jbroot 前缀: %s", jbrootPrefix ?: "(null)");

        // 测试 boot UUID
        const char* bootUUID = libroot_dyn_get_boot_uuid();
        NSLog(@"测试 4:");
        NSLog(@"  Boot UUID: %s", bootUUID ?: "(null)");

        // 测试写入
        if (resolved2) {
            NSLog(@"测试 5: 尝试写入配置文件");

            // 确保目录存在
            NSString* dir = [resolved2 stringByDeletingLastPathComponent];
            NSError* error = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
            if (error) {
                NSLog(@"  创建目录失败: %@", error);
            } else {
                NSLog(@"  目录: %@", dir);
            }

            // 写入测试数据
            NSDictionary* testData = @{
                @"test": @"libroot API works!",
                @"timestamp": @([[NSDate date] timeIntervalSince1970])
            };

            BOOL success = [testData writeToFile:resolved2 atomically:YES];
            NSLog(@"  写入结果: %@", success ? @"成功" : @"失败");

            if (success) {
                // 验证读取
                NSDictionary* readBack = [NSDictionary dictionaryWithContentsOfFile:resolved2];
                NSLog(@"  读取验证: %@", readBack ? @"成功" : @"失败");
                if (readBack) {
                    NSLog(@"  读取内容: %@", readBack);
                }
            }
        }

        NSLog(@"✅ 所有测试完成");
#else
        NSLog(@"❌ libroot 头文件不可用");
        NSLog(@"请确保:");
        NSLog(@"  1. 已安装 Theos");
        NSLog(@"  2. /opt/theos/vendor/include/libroot/libroot.h 存在");
#endif

    }
    return 0;
}
