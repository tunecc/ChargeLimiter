//
//  CLAccChargeViewController.m
//  ChargeLimiter
//
//  加速充电设置页面
//

#import <UIKit/UIKit.h>
#import "../CLBatteryManager.h"
#import "../CLAPIClient.h"
#import "../../CLLocalization.h"
#import <objc/runtime.h>

static UIImage *CLSymbolImage(NSString *name, UIImageSymbolConfiguration *config) {
    static NSDictionary<NSString *, NSString *> *fallbacks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fallbacks = @{
            @"chart.line.uptrend.xyaxis": @"chart.xyaxis.line",
            @"bolt.batteryblock": @"battery.100.bolt",
            @"thermometer.sun.fill": @"thermometer",
            @"thermometer.sun": @"thermometer"
        };
    });
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:config];
    if (!img) {
        NSString *fallback = fallbacks[name];
        if (fallback.length > 0) {
            img = [UIImage systemImageNamed:fallback withConfiguration:config];
        }
    }
    return img;
}

@interface CLAccChargeViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
@end

@implementation CLAccChargeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    CLApplyLanguageFromSettings();
    self.title = CLL(@"加速充电");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    [self setupScrollView];
    [self setupContent];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange)
                                                 name:CLAppLanguageDidChangeNotification
                                               object:nil];
}

- (void)setupScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    
    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 0;
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.mainStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.mainStack.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:20],
        [self.mainStack.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:20],
        [self.mainStack.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-20],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-40],
        [self.mainStack.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-40]
    ]];
}

- (void)setupContent {
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 说明文字
    UILabel *descLabel = [[UILabel alloc] init];
    descLabel.text = CLL(@"加速充电通过关闭部分功能来减少电量消耗，从而加快充电速度。充电完成后会自动恢复。");
    descLabel.font = [UIFont systemFontOfSize:14];
    descLabel.textColor = [UIColor secondaryLabelColor];
    descLabel.numberOfLines = 0;
    descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *descContainer = [[UIView alloc] init];
    descContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [descContainer addSubview:descLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [descLabel.topAnchor constraintEqualToAnchor:descContainer.topAnchor],
        [descLabel.leadingAnchor constraintEqualToAnchor:descContainer.leadingAnchor],
        [descLabel.trailingAnchor constraintEqualToAnchor:descContainer.trailingAnchor],
        [descLabel.bottomAnchor constraintEqualToAnchor:descContainer.bottomAnchor constant:-24]
    ]];
    
    [self.mainStack addArrangedSubview:descContainer];
    
    // 主开关卡片
    UIView *mainCard = [self createCardWithCornerRadius:16];
    [self addSwitchToCard:mainCard icon:@"bolt.fill" title:CLL(@"启用加速充电") isOn:manager.accChargeEnabled color:[UIColor systemGreenColor] tag:400];
    [self.mainStack addArrangedSubview:mainCard];
    
    // 间隔
    UIView *spacer = [[UIView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[spacer.heightAnchor constraintEqualToConstant:20]]];
    [self.mainStack addArrangedSubview:spacer];
    
    // 选项卡片
    UIView *optionsCard = [self createCardWithCornerRadius:16];
    
    [self addSwitchToCard:optionsCard icon:@"airplane" title:CLL(@"飞行模式") isOn:manager.accChargeAirMode color:[UIColor systemOrangeColor] tag:401];
    [self addSeparatorToCard:optionsCard];
    [self addSwitchToCard:optionsCard icon:@"wifi" title:CLL(@"关闭 WiFi") isOn:manager.accChargeWifi color:[UIColor systemBlueColor] tag:402];
    [self addSeparatorToCard:optionsCard];
    [self addSwitchToCard:optionsCard icon:@"antenna.radiowaves.left.and.right" title:CLL(@"关闭蓝牙") isOn:manager.accChargeBluetooth color:[UIColor systemIndigoColor] tag:403];
    [self addSeparatorToCard:optionsCard];
    [self addSwitchToCard:optionsCard icon:@"sun.max.fill" title:CLL(@"降低亮度") isOn:manager.accChargeBrightness color:[UIColor systemYellowColor] tag:404];
    [self addSeparatorToCard:optionsCard];
    [self addSwitchToCard:optionsCard icon:@"battery.25" title:CLL(@"低电量模式") isOn:manager.accChargeLPM color:[UIColor systemGreenColor] tag:405];
    
    [self.mainStack addArrangedSubview:optionsCard];
}

- (void)languageDidChange {
    CLApplyLanguageFromSettings();
    self.title = CLL(@"加速充电");
    for (UIView *v in self.view.subviews) {
        [v removeFromSuperview];
    }
    [self setupScrollView];
    [self setupContent];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIView *)createCardWithCornerRadius:(CGFloat)radius {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = radius;
    card.clipsToBounds = YES;
    
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:blurView];
    
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.tag = 999;
    [blurView.contentView addSubview:stack];
    
    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor]
    ]];
    
    return card;
}

- (void)addSwitchToCard:(UIView *)card icon:(NSString *)iconName title:(NSString *)title isOn:(BOOL)isOn color:(UIColor *)color tag:(NSInteger)tag {
    UIStackView *stack = [card viewWithTag:999];
    
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = isOn ? color : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = CLSymbolImage(iconName, config);
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:16];
    [row addSubview:titleLabel];
    
    UISwitch *switchView = [[UISwitch alloc] init];
    switchView.translatesAutoresizingMaskIntoConstraints = NO;
    switchView.on = isOn;
    switchView.tag = tag;
    switchView.onTintColor = color;
    [switchView addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(switchView, "iconView", iconView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(switchView, "iconColor", color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [row addSubview:switchView];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:50],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [switchView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [switchView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    
    [stack addArrangedSubview:row];
}

- (void)addSeparatorToCard:(UIView *)card {
    UIStackView *stack = [card viewWithTag:999];
    
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor separatorColor];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:separator];
    
    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintEqualToConstant:0.5],
        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:56],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
        [separator.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
    ]];
    
    [stack addArrangedSubview:container];
}

- (void)switchChanged:(UISwitch *)sender {
    UIImageView *iconView = objc_getAssociatedObject(sender, "iconView");
    UIColor *iconColor = objc_getAssociatedObject(sender, "iconColor");
    if (iconView) {
        iconView.tintColor = sender.on ? (iconColor ?: [UIColor systemBlueColor])
                                       : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    }
    CLBatteryManager *manager = [CLBatteryManager shared];
    NSString *key = nil;
    
    switch (sender.tag) {
        case 400:
            manager.accChargeEnabled = sender.on;
            key = @"acc_charge";
            break;
        case 401:
            manager.accChargeAirMode = sender.on;
            key = @"acc_charge_airmode";
            break;
        case 402:
            manager.accChargeWifi = sender.on;
            key = @"acc_charge_wifi";
            break;
        case 403:
            manager.accChargeBluetooth = sender.on;
            key = @"acc_charge_blue";
            break;
        case 404:
            manager.accChargeBrightness = sender.on;
            key = @"acc_charge_bright";
            break;
        case 405:
            manager.accChargeLPM = sender.on;
            key = @"acc_charge_lpm";
            break;
    }
    
    if (key) {
        [[CLAPIClient shared] setConfigWithKey:key value:@(sender.on) completion:nil];
    }
}

@end
