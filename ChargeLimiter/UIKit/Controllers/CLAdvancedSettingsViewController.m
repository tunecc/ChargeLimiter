//
//  CLAdvancedSettingsViewController.m
//  ChargeLimiter
//
//  高级设置页面
//

#import <UIKit/UIKit.h>
#import "../CLBatteryManager.h"
#import "../CLAPIClient.h"
#import <objc/runtime.h>

#pragma mark - 毛玻璃卡片（复用）

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
    iconView.tintColor = color ?: [UIColor systemBlueColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
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
    switchView.onTintColor = color;
    [switchView addTarget:target action:action forControlEvents:UIControlEventValueChanged];
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
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
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
    chevron.image = [UIImage systemImageNamed:@"chevron.right"];
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
    
    self.title = @"高级设置";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    if (@available(iOS 13.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles = NO;
    }
    
    [self setupScrollView];
    [self setupContent];
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

- (void)setupContent {
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 停充控制
    CLAdvSettingsCard *stopChargeCard = [[CLAdvSettingsCard alloc] init];
    [stopChargeCard addSectionHeader:@"停充控制"];
    [stopChargeCard addSwitchRowWithIcon:@"bolt.slash.fill" title:@"智能停充" subtitle:@"使用 SmartBattery API 进行停充" isOn:manager.predictiveInhibitCharge color:[UIColor systemBlueColor] tag:300 target:self action:@selector(smartChargeChanged:)];
    [stopChargeCard addSeparator];
    [stopChargeCard addSwitchRowWithIcon:@"xmark.circle.fill" title:@"停充时启用禁流" subtitle:@"禁止电流流入设备，电池放电供电" isOn:manager.disableInflow color:[UIColor systemOrangeColor] tag:301 target:self action:@selector(disableInflowChanged:)];
    [self.mainStack addArrangedSubview:stopChargeCard];
    
    // 限流控制
    CLAdvSettingsCard *limitCard = [[CLAdvSettingsCard alloc] init];
    [limitCard addSectionHeader:@"限流控制"];
    [limitCard addSwitchRowWithIcon:@"speedometer" title:@"充电时自动限流" subtitle:@"充电时启用高温模拟以限制电流" isOn:manager.limitInflow color:[UIColor systemRedColor] tag:302 target:self action:@selector(limitInflowChanged:)];
    [limitCard addSeparator];
    [limitCard addPickerRowWithIcon:@"thermometer.sun.fill" title:@"限流等级" value:[self thermalModeString:manager.limitInflowThermalMode] color:[UIColor systemOrangeColor] tag:306 target:self action:@selector(limitInflowModeTapped:)];
    [self.mainStack addArrangedSubview:limitCard];
    
    // 高温模拟
    CLAdvSettingsCard *thermalCard = [[CLAdvSettingsCard alloc] init];
    [thermalCard addSectionHeader:@"高温模拟 (Powercuff)"];
    [thermalCard addPickerRowWithIcon:@"thermometer.high" title:@"默认等级" value:[self thermalModeString:manager.thermalMode] color:[UIColor systemOrangeColor] tag:303 target:self action:@selector(thermalModeTapped:)];
    [thermalCard addSeparator];
    [thermalCard addSwitchRowWithIcon:@"lock.fill" title:@"锁定等级" subtitle:@"防止系统自动调节温度模拟" isOn:manager.thermalModeLock color:[UIColor systemGrayColor] tag:304 target:self action:@selector(thermalLockChanged:)];
    [self.mainStack addArrangedSubview:thermalCard];
    
    // 重置按钮
    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [resetButton setTitle:@"重置所有设置" forState:UIControlStateNormal];
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

- (NSString *)thermalModeString:(CLThermalMode)mode {
    switch (mode) {
        case CLThermalModeOff: return @"关闭";
        case CLThermalModeNominal: return @"正常";
        case CLThermalModeLight: return @"轻度";
        case CLThermalModeModerate: return @"中度";
        case CLThermalModeHeavy: return @"重度";
        default: return @"关闭";
    }
}

#pragma mark - Actions

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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"限流等级" message:@"充电时使用的高温模拟等级\n等级越高，充电电流越小" preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *modes = @[@"关闭", @"正常", @"轻度", @"中度", @"重度"];
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)thermalModeTapped:(UITapGestureRecognizer *)tap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"默认高温模拟等级" message:@"非充电时的高温模拟等级\n等级越高，性能越低，发热越少" preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *modes = @[@"关闭", @"正常", @"轻度", @"中度", @"重度"];
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)thermalLockChanged:(UISwitch *)sender {
    [CLBatteryManager shared].thermalModeLock = sender.on;
    [[CLAPIClient shared] setConfigWithKey:@"adv_thermal_mode_lock" value:@(sender.on) completion:nil];
}

- (void)resetTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认重置" message:@"这将重置所有设置为默认值" preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[CLBatteryManager shared] resetConfigWithCompletion:^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationController popViewControllerAnimated:YES];
            });
        }];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

@end
