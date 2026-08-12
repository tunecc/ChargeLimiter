//
//  CLTestApp.m
//  ChargeLimiter
//
//  独立 UI 测试入口 - 不依赖 daemon，使用 Mock 数据
//

#import <UIKit/UIKit.h>
#import <TargetConditionals.h>

// 使用新的 Apple 风格设置界面
#import "Controllers/CLSettingsViewController.h"
#if TARGET_OS_SIMULATOR || defined(CL_TEST_MODE)
BOOL CLRunLocalizationPersistenceSelfTest(NSString **failureReason);
#endif

@interface CLTestAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation CLTestAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSLog(@"[CL-Test] 启动 UIKit 测试模式 (Apple 风格)");
#if TARGET_OS_SIMULATOR || defined(CL_TEST_MODE)
    NSString *failureReason = nil;
    BOOL passed = CLRunLocalizationPersistenceSelfTest(&failureReason);
    NSLog(@"[CL-Test] localization persistence self-test: %@", passed ? @"PASS" : @"FAIL");
    if (!passed && failureReason.length > 0) {
        NSLog(@"[CL-Test] localization persistence failure: %@", failureReason);
    }
#endif
    NSLog(@"[CL-Test] UI 初始化完成");
    return YES;
}

@end

// 仅在测试模式下使用此 main
#if TARGET_OS_SIMULATOR || defined(CL_TEST_MODE)

int main(int argc, char * argv[]) {
    @autoreleasepool {
        NSLog(@"[CL-Test] 进入测试模式 main()");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([CLTestAppDelegate class]));
    }
}

#endif
