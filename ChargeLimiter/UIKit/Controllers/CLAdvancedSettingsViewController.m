//
//  CLAdvancedSettingsViewController.m
//  ChargeLimiter
//
//  高级设置页面
//

#import <UIKit/UIKit.h>
#import "../CLBatteryManager.h"
#import "../CLAPIClient.h"
#import "../../CLLocalization.h"
#import <objc/runtime.h>

#pragma mark - 毛玻璃卡片（复用）

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

@interface CLAdvSettingsCard : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIStackView *contentStack;
@end

@implementation CLAdvSettingsCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupView];
    }
    return self;
}

- (void)setupView {
    self.layer.cornerRadius = 16;
    self.clipsToBounds = YES;
    
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.blurView];
    
    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 0;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.blurView.contentView addSubview:self.contentStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor]
    ]];
}

- (void)addSectionHeader:(NSString *)title {
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];
    
    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:36],
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [label.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6]
    ]];
    
    [self.contentStack addArrangedSubview:header];
}

- (void)addSwitchRowWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle isOn:(BOOL)isOn color:(UIColor *)color tag:(NSInteger)tag target:(id)target action:(SEL)action {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    UIColor *iconColor = color ?: [UIColor systemBlueColor];
    iconView.tintColor = isOn ? iconColor : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = CLSymbolImage(iconName, config);
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:16];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    UISwitch *switchView = [[UISwitch alloc] init];
    switchView.translatesAutoresizingMaskIntoConstraints = NO;
    switchView.on = isOn;
    switchView.tag = tag;
    switchView.onTintColor = iconColor;
    [switchView addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    [switchView addTarget:self action:@selector(updateSwitchIconTint:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(switchView, "iconView", iconView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(switchView, "iconColor", iconColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [row addSubview:switchView];
    
    CGFloat rowHeight = 50;
    
    if (subtitle) {
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        subtitleLabel.text = subtitle;
        subtitleLabel.font = [UIFont systemFontOfSize:12];
        subtitleLabel.textColor = [UIColor secondaryLabelColor];
        subtitleLabel.numberOfLines = 2;
        [row addSubview:subtitleLabel];
        rowHeight = 70;
        
        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
            [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
            [subtitleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
            [subtitleLabel.trailingAnchor constraintEqualToAnchor:switchView.leadingAnchor constant:-8]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
        ]];
    }
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:rowHeight],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [switchView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [switchView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    
    [self.contentStack addArrangedSubview:row];
}

- (void)addPickerRowWithIcon:(NSString *)iconName title:(NSString *)title value:(NSString *)value color:(UIColor *)color tag:(NSInteger)tag target:(id)target action:(SEL)action {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.tag = tag;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = color ?: [UIColor systemBlueColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = CLSymbolImage(iconName, config);
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:16];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont systemFontOfSize:16];
    valueLabel.textColor = [UIColor secondaryLabelColor];
    valueLabel.tag = tag + 10000;
    [row addSubview:valueLabel];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.image = CLSymbolImage(@"chevron.right", nil);
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [row addSubview:chevron];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:action];
    [row addGestureRecognizer:tap];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:50],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    
    [self.contentStack addArrangedSubview:row];
}

- (void)updateSwitchIconTint:(UISwitch *)sender {
    UIImageView *iconView = objc_getAssociatedObject(sender, "iconView");
    UIColor *iconColor = objc_getAssociatedObject(sender, "iconColor");
    if (iconView) {
        iconView.tintColor = sender.on ? (iconColor ?: [UIColor systemBlueColor])
                                       : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    }
}

- (void)addSeparator {
    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor separatorColor];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:separator];
    
    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintEqualToConstant:0.5],
        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:56],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
        [separator.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
    ]];
    
    [self.contentStack addArrangedSubview:container];
}

@end

#pragma mark - 高级设置控制器

@interface CLAdvancedSettingsViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
@end

@implementation CLAdvancedSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    CLApplyLanguageFromSettings();
    self.title = CLL(@"充电高级");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    if (@available(iOS 13.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles = NO;
    }
    
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
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];
    
    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 20;
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

- (void)languageDidChange {
    CLApplyLanguageFromSettings();
    self.title = CLL(@"充电高级");
    for (UIView *v in self.view.subviews) {
        [v removeFromSuperview];
    }
    [self setupScrollView];
    [self setupContent];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupContent {
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 加速充电
    CLAdvSettingsCard *accCard = [[CLAdvSettingsCard alloc] init];
    [accCard addSectionHeader:CLL(@"加速充电")];
    [accCard addPickerRowWithIcon:@"bolt.car" title:CLL(@"加速充电") value:CLL(@"进入") color:[UIColor systemGreenColor] tag:399 target:self action:@selector(accChargeTapped)];
    [self addTipRowToCard:accCard text:CLL(@"关闭部分功能以减少耗电，加快充电速度")];
    [self.mainStack addArrangedSubview:accCard];
    
    // 停充控制
    CLAdvSettingsCard *stopChargeCard = [[CLAdvSettingsCard alloc] init];
    [stopChargeCard addSectionHeader:CLL(@"停充控制")];
    [stopChargeCard addSwitchRowWithIcon:@"bolt.slash.fill" title:CLL(@"智能停充") subtitle:CLL(@"使用 SmartBattery API 进行停充") isOn:manager.predictiveInhibitCharge color:[UIColor systemRedColor] tag:300 target:self action:@selector(smartChargeChanged:)];
    [stopChargeCard addSeparator];
    [stopChargeCard addSwitchRowWithIcon:@"xmark.circle.fill" title:CLL(@"停充时启用禁流") subtitle:CLL(@"禁止电流流入设备，电池放电供电") isOn:manager.disableInflow color:[UIColor systemRedColor] tag:301 target:self action:@selector(disableInflowChanged:)];
    [self.mainStack addArrangedSubview:stopChargeCard];
    
    // 限流控制
    CLAdvSettingsCard *limitCard = [[CLAdvSettingsCard alloc] init];
    [limitCard addSectionHeader:CLL(@"限流控制")];
    [limitCard addSwitchRowWithIcon:@"thermometer" title:CLL(@"充电时自动限流") subtitle:CLL(@"充电时启用高温模拟以限制电流") isOn:manager.limitInflow color:[UIColor systemOrangeColor] tag:302 target:self action:@selector(limitInflowChanged:)];
    [limitCard addSeparator];
    [limitCard addPickerRowWithIcon:@"thermometer.sun.fill" title:CLL(@"限流等级") value:[self thermalModeString:manager.limitInflowThermalMode] color:[UIColor systemOrangeColor] tag:306 target:self action:@selector(limitInflowModeTapped:)];
    [self.mainStack addArrangedSubview:limitCard];
    
    // 高温模拟
    CLAdvSettingsCard *thermalCard = [[CLAdvSettingsCard alloc] init];
    [thermalCard addSectionHeader:CLL(@"高温模拟 (Powercuff)")];
    [thermalCard addPickerRowWithIcon:@"flame.fill" title:CLL(@"默认等级") value:[self thermalModeString:manager.thermalMode] color:[UIColor systemOrangeColor] tag:303 target:self action:@selector(thermalModeTapped:)];
    [thermalCard addSeparator];
    [thermalCard addSwitchRowWithIcon:@"thermometer" title:CLL(@"锁定等级") subtitle:CLL(@"防止系统自动调节温度模拟") isOn:manager.thermalModeLock color:[UIColor systemOrangeColor] tag:304 target:self action:@selector(thermalLockChanged:)];
    [self.mainStack addArrangedSubview:thermalCard];
    
    // 重置按钮
    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [resetButton setTitle:CLL(@"重置所有设置") forState:UIControlStateNormal];
    [resetButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:17];
    resetButton.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    resetButton.layer.cornerRadius = 12;
    [resetButton addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    
    [NSLayoutConstraint activateConstraints:@[
        [resetButton.heightAnchor constraintEqualToConstant:50]
    ]];
    
    [self.mainStack addArrangedSubview:resetButton];
}

- (void)addTipRowToCard:(CLAdvSettingsCard *)card text:(NSString *)text {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text ?: @"";
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 2;
    [row addSubview:label];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16]
    ]];
    
    [card.contentStack addArrangedSubview:row];
}

- (NSString *)thermalModeString:(CLThermalMode)mode {
    switch (mode) {
        case CLThermalModeOff: return CLL(@"关闭");
        case CLThermalModeNominal: return CLL(@"正常");
        case CLThermalModeLight: return CLL(@"轻度");
        case CLThermalModeModerate: return CLL(@"中度");
        case CLThermalModeHeavy: return CLL(@"重度");
        default: return CLL(@"关闭");
    }
}

#pragma mark - Actions

- (void)accChargeTapped {
    Class vcClass = NSClassFromString(@"CLAccChargeViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)smartChargeChanged:(UISwitch *)sender {
    [CLBatteryManager shared].predictiveInhibitCharge = sender.on;
    [[CLAPIClient shared] setConfigWithKey:@"adv_predictive_inhibit_charge" value:@(sender.on) completion:nil];
}

- (void)disableInflowChanged:(UISwitch *)sender {
    [CLBatteryManager shared].disableInflow = sender.on;
    [[CLAPIClient shared] setConfigWithKey:@"adv_disable_inflow" value:@(sender.on) completion:nil];
}

- (void)limitInflowChanged:(UISwitch *)sender {
    [CLBatteryManager shared].limitInflow = sender.on;
    [[CLAPIClient shared] setConfigWithKey:@"adv_limit_inflow" value:@(sender.on) completion:nil];
}

- (void)limitInflowModeTapped:(UITapGestureRecognizer *)tap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"限流等级") message:CLL(@"充电时使用的高温模拟等级\n等级越高，充电电流越小") preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *modes = @[CLL(@"关闭"), CLL(@"正常"), CLL(@"轻度"), CLL(@"中度"), CLL(@"重度")];
    NSArray *modeValues = @[@"off", @"nominal", @"light", @"moderate", @"heavy"];
    __weak typeof(self) weakSelf = self;
    for (NSInteger i = 0; i < modes.count; i++) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:modes[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [CLBatteryManager shared].limitInflowThermalMode = (CLThermalMode)i;
            [[CLAPIClient shared] setConfigWithKey:@"adv_limit_inflow_mode" value:modeValues[i] completion:nil];
            // 刷新页面
            [weakSelf.mainStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
            [weakSelf setupContent];
        }];
        [alert addAction:action];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)thermalModeTapped:(UITapGestureRecognizer *)tap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"默认高温模拟等级") message:CLL(@"非充电时的高温模拟等级\n等级越高，性能越低，发热越少") preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *modes = @[CLL(@"关闭"), CLL(@"正常"), CLL(@"轻度"), CLL(@"中度"), CLL(@"重度")];
    NSArray *modeValues = @[@"off", @"nominal", @"light", @"moderate", @"heavy"];
    __weak typeof(self) weakSelf = self;
    for (NSInteger i = 0; i < modes.count; i++) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:modes[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [CLBatteryManager shared].thermalMode = (CLThermalMode)i;
            [[CLAPIClient shared] setConfigWithKey:@"adv_def_thermal_mode" value:modeValues[i] completion:nil];
            // 刷新页面
            [weakSelf.mainStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
            [weakSelf setupContent];
        }];
        [alert addAction:action];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)thermalLockChanged:(UISwitch *)sender {
    [CLBatteryManager shared].thermalModeLock = sender.on;
    [[CLAPIClient shared] setConfigWithKey:@"adv_thermal_mode_lock" value:@(sender.on) completion:nil];
}

- (void)resetTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"确认重置") message:CLL(@"这将重置所有设置为默认值") preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"重置") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[CLBatteryManager shared] resetConfigWithCompletion:^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationController popViewControllerAnimated:YES];
            });
        }];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

@end
