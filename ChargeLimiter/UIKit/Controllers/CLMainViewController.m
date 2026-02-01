//
//  CLMainViewController.m
//  ChargeLimiter
//
//  主入口控制器 - 包装新的设置界面到导航控制器
//

#import "CLMainViewController.h"
#import "CLSettingsViewController.h"

@interface CLMainViewController ()
@property (nonatomic, strong) UINavigationController *navController;
@end

@implementation CLMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 创建设置界面
    CLSettingsViewController *settingsVC = [[CLSettingsViewController alloc] init];
    
    // 包装到导航控制器
    self.navController = [[UINavigationController alloc] initWithRootViewController:settingsVC];
    self.navController.navigationBarHidden = YES;
    
    // 添加为子控制器
    [self addChildViewController:self.navController];
    self.navController.view.frame = self.view.bounds;
    self.navController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.navController.view];
    [self.navController didMoveToParentViewController:self];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return UIStatusBarStyleDefault;
    }
    return UIStatusBarStyleDefault;
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

@end
