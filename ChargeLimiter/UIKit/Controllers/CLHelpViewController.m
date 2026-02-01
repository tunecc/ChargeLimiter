//
//  CLHelpViewController.m
//  ChargeLimiter
//
//  帮助页面 - 使用纯 UIKit 实现，避免 roothide 环境下 WKWebView 的限制
//

#import <UIKit/UIKit.h>

#pragma mark - CLHelpCardView

@interface CLHelpCardView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *contentLabel;
@end

@implementation CLHelpCardView

- (instancetype)initWithTitle:(NSString *)title content:(NSString *)content {
    self = [super init];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.layer.cornerRadius = 12;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        
        if (title) {
            self.titleLabel = [[UILabel alloc] init];
            self.titleLabel.text = title;
            self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            self.titleLabel.textColor = [UIColor labelColor];
            self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:self.titleLabel];
        }
        
        self.contentLabel = [[UILabel alloc] init];
        self.contentLabel.text = content;
        self.contentLabel.font = [UIFont systemFontOfSize:15];
        self.contentLabel.textColor = [UIColor secondaryLabelColor];
        self.contentLabel.numberOfLines = 0;
        self.contentLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.contentLabel];
        
        if (title) {
            [NSLayoutConstraint activateConstraints:@[
                [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
                [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
                [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
                [self.contentLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
                [self.contentLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
                [self.contentLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
                [self.contentLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16]
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [self.contentLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
                [self.contentLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
                [self.contentLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
                [self.contentLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16]
            ]];
        }
    }
    return self;
}

@end

#pragma mark - CLHelpSectionHeader

@interface CLHelpSectionHeader : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation CLHelpSectionHeader

- (instancetype)initWithTitle:(NSString *)title {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.text = title;
        self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.titleLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:24],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12]
        ]];
    }
    return self;
}

@end

#pragma mark - CLHelpTipView

@interface CLHelpTipView : UIView
@property (nonatomic, strong) UILabel *contentLabel;
@end

@implementation CLHelpTipView

- (instancetype)initWithContent:(NSString *)content isWarning:(BOOL)isWarning {
    self = [super init];
    if (self) {
        self.backgroundColor = isWarning ? [UIColor systemOrangeColor] : [UIColor systemGreenColor];
        self.layer.cornerRadius = 8;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        
        self.contentLabel = [[UILabel alloc] init];
        self.contentLabel.text = content;
        self.contentLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.contentLabel.textColor = [UIColor whiteColor];
        self.contentLabel.numberOfLines = 0;
        self.contentLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.contentLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.contentLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [self.contentLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [self.contentLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [self.contentLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12]
        ]];
    }
    return self;
}

@end

#pragma mark - CLHelpLinkView

@interface CLHelpLinkView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *linkButton;
@property (nonatomic, copy) NSString *urlString;
@end

@implementation CLHelpLinkView

- (instancetype)initWithTitle:(NSString *)title url:(NSString *)url {
    self = [super init];
    if (self) {
        self.urlString = url;
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.layer.cornerRadius = 12;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.text = title;
        self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.titleLabel];
        
        self.linkButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.linkButton setTitle:url forState:UIControlStateNormal];
        self.linkButton.titleLabel.font = [UIFont systemFontOfSize:15];
        self.linkButton.titleLabel.numberOfLines = 0;
        self.linkButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [self.linkButton addTarget:self action:@selector(openLink) forControlEvents:UIControlEventTouchUpInside];
        self.linkButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.linkButton];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [self.linkButton.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
            [self.linkButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [self.linkButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [self.linkButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16]
        ]];
    }
    return self;
}

- (void)openLink {
    NSURL *url = [NSURL URLWithString:self.urlString];
    if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

@end

#pragma mark - CLHelpViewController

@interface CLHelpViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@end

@implementation CLHelpViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"帮助";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    [self setupScrollView];
    [self setupContent];
}

- (void)setupScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];
    
    self.stackView = [[UIStackView alloc] init];
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.spacing = 12;
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:20],
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:20],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-20],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-40],
        [self.stackView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-40]
    ]];
}

- (void)setupContent {
    // 标题
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"📱 ChargeLimiter";
    titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    [self.stackView addArrangedSubview:titleLabel];
    
    // 简介
    CLHelpCardView *introCard = [[CLHelpCardView alloc] initWithTitle:@"什么是 ChargeLimiter？" 
        content:@"ChargeLimiter 是一款电池充电限制工具，适用于 iOS 越狱和 TrollStore 环境。它可以帮助你控制手机充电行为，保护电池健康度。"];
    [self.stackView addArrangedSubview:introCard];
    
    // 充电模式
    [self.stackView addArrangedSubview:[[CLHelpSectionHeader alloc] initWithTitle:@"🔋 充电模式"]];
    
    CLHelpCardView *mode1 = [[CLHelpCardView alloc] initWithTitle:@"插电即充" 
        content:@"适合普通用户。接入电源时自动开始充电，达到上限时停止。"];
    [self.stackView addArrangedSubview:mode1];
    
    CLHelpCardView *mode2 = [[CLHelpCardView alloc] initWithTitle:@"边缘触发" 
        content:@"适合常年连接电源的场景。仅在电量低于下限时开始充电，高于上限时停止。"];
    [self.stackView addArrangedSubview:mode2];
    
    // 阈值设置
    [self.stackView addArrangedSubview:[[CLHelpSectionHeader alloc] initWithTitle:@"⚡️ 阈值设置"]];
    
    CLHelpCardView *thresholdCard = [[CLHelpCardView alloc] initWithTitle:nil 
        content:@"• 开始充电：电量低于此值时开始充电\n• 停止充电：电量高于此值时停止充电\n\n建议设置为 20%-80% 以延长电池寿命。"];
    [self.stackView addArrangedSubview:thresholdCard];
    
    // 高级功能
    [self.stackView addArrangedSubview:[[CLHelpSectionHeader alloc] initWithTitle:@"🔧 高级功能"]];
    
    CLHelpCardView *advancedCard = [[CLHelpCardView alloc] initWithTitle:nil 
        content:@"• 智能停充：使用系统 SmartBattery API\n• 禁流：禁止电流流入设备，适用于不支持停充的电池\n• 限流：通过高温模拟限制充电电流\n• 加速充电：临时关闭部分功能以加快充电"];
    [self.stackView addArrangedSubview:advancedCard];
    
    // 提示
    CLHelpTipView *warning = [[CLHelpTipView alloc] initWithContent:@"⚠️ 使用前请先测试电池是否支持停充功能" isWarning:YES];
    [self.stackView addArrangedSubview:warning];
    
    CLHelpTipView *tip = [[CLHelpTipView alloc] initWithContent:@"💡 建议每月至少满充满放一次以校准电池" isWarning:NO];
    [self.stackView addArrangedSubview:tip];
    
    // 常见问题
    [self.stackView addArrangedSubview:[[CLHelpSectionHeader alloc] initWithTitle:@"❓ 常见问题"]];
    
    CLHelpCardView *faq1 = [[CLHelpCardView alloc] initWithTitle:@"无法停充？" 
        content:@"可能原因：电池不支持、健康度过低、温度过高、电池未激活。"];
    [self.stackView addArrangedSubview:faq1];
    
    CLHelpCardView *faq2 = [[CLHelpCardView alloc] initWithTitle:@"健康度下降？" 
        content:@"长期停充可能导致统计不准。正常使用几次后会恢复。"];
    [self.stackView addArrangedSubview:faq2];
    
    // 相关链接
    [self.stackView addArrangedSubview:[[CLHelpSectionHeader alloc] initWithTitle:@"🔗 相关链接"]];
    
    CLHelpLinkView *linkView = [[CLHelpLinkView alloc] initWithTitle:@"原项目地址" 
        url:@"https://github.com/lich4/ChargeLimiter"];
    [self.stackView addArrangedSubview:linkView];
}

@end
