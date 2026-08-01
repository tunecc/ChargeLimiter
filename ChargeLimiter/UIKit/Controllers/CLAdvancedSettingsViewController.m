//
//  CLAdvancedSettingsViewController.m
//  ChargeLimiter
//
//  高级设置页面
//

#import <UIKit/UIKit.h>
#import "../CLBatteryManager.h"
#import "../CLAPIClient.h"
#import "../CLSymbolImageSupport.h"
#import "../../CLLocalization.h"
#import <objc/runtime.h>

#pragma mark - 毛玻璃卡片（复用）

static char kCLAdvPickerColorKey;
static char kCLAdvPickerIconViewKey;
static char kCLAdvPickerTitleLabelKey;
static char kCLAdvPickerValueLabelKey;
static char kCLAdvPickerChevronKey;
static char kCLAdvSwitchColorKey;
static char kCLAdvSwitchIconViewKey;
static char kCLAdvSwitchTitleLabelKey;
static char kCLAdvSwitchSubtitleLabelKey;
static char kCLAdvSwitchViewKey;

@interface CLAdvSettingsCard : UIView
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
    self.layer.cornerRadius = 12;
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    
    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 0;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.contentStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
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
    row.tag = tag;
    
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
    titleLabel.numberOfLines = 0;
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
    [switchView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [switchView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:switchView];
    
    CGFloat minimumRowHeight = 50;
    UILabel *subtitleLabel = nil;
    
    if (subtitle) {
        subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        subtitleLabel.text = subtitle;
        subtitleLabel.font = [UIFont systemFontOfSize:12];
        subtitleLabel.textColor = [UIColor secondaryLabelColor];
        subtitleLabel.numberOfLines = 0;
        [row addSubview:subtitleLabel];
        minimumRowHeight = 70;
        
        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
            [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
            [subtitleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:switchView.leadingAnchor constant:-12],
            [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:switchView.leadingAnchor constant:-12],
            [subtitleLabel.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:switchView.leadingAnchor constant:-12],
            [titleLabel.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:10],
            [titleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-10]
        ]];
    }
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:minimumRowHeight],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [switchView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [switchView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];

    objc_setAssociatedObject(row, &kCLAdvSwitchColorKey, iconColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, &kCLAdvSwitchIconViewKey, iconView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, &kCLAdvSwitchTitleLabelKey, titleLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (subtitleLabel) {
        objc_setAssociatedObject(row, &kCLAdvSwitchSubtitleLabelKey, subtitleLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(row, &kCLAdvSwitchViewKey, switchView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [self.contentStack addArrangedSubview:row];
}

- (void)addPickerRowWithIcon:(NSString *)iconName title:(NSString *)title value:(NSString *)value color:(UIColor *)color tag:(NSInteger)tag target:(id)target action:(SEL)action {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.tag = tag;
    UIColor *rowColor = color ?: [UIColor systemBlueColor];
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = rowColor;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = CLSymbolImage(iconName, config);
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:16];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.numberOfLines = 0;
    [row addSubview:titleLabel];
    
    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont systemFontOfSize:16];
    valueLabel.textColor = [UIColor secondaryLabelColor];
    valueLabel.numberOfLines = 0;
    valueLabel.textAlignment = NSTextAlignmentRight;
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    valueLabel.tag = tag + 10000;
    [row addSubview:valueLabel];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.image = CLSymbolImage(@"chevron.right", nil);
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [chevron setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:chevron];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:action];
    [row addGestureRecognizer:tap];
    objc_setAssociatedObject(row, &kCLAdvPickerColorKey, rowColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, &kCLAdvPickerIconViewKey, iconView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, &kCLAdvPickerTitleLabelKey, titleLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, &kCLAdvPickerValueLabelKey, valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, &kCLAdvPickerChevronKey, chevron, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:50],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [titleLabel.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:10],
        [titleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-10],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [valueLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:10],
        [valueLabel.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-10]
    ]];
    
    [self.contentStack addArrangedSubview:row];
}

- (UILabel *)addValueRowWithIcon:(NSString *)iconName title:(NSString *)title value:(NSString *)value color:(UIColor *)color {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = color ?: [UIColor systemBlueColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = CLSymbolImage(iconName, config);
    [row addSubview:iconView];

    UIStackView *textStack = [[UIStackView alloc] init];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentFill;
    textStack.spacing = 4;
    [row addSubview:textStack];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    titleLabel.numberOfLines = 0;
    [textStack addArrangedSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont systemFontOfSize:15];
    valueLabel.textColor = [UIColor secondaryLabelColor];
    valueLabel.textAlignment = NSTextAlignmentLeft;
    valueLabel.numberOfLines = 0;
    valueLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [textStack addArrangedSubview:valueLabel];

    [titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:58],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:row.topAnchor constant:14],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [iconView.heightAnchor constraintEqualToConstant:20],
        [iconView.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-12],
        [textStack.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [textStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [textStack.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [textStack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10]
    ]];

    [self.contentStack addArrangedSubview:row];
    return valueLabel;
}

- (void)updateSwitchIconTint:(UISwitch *)sender {
    UIImageView *iconView = objc_getAssociatedObject(sender, "iconView");
    UIColor *iconColor = objc_getAssociatedObject(sender, "iconColor");
    if (iconView) {
        if (!sender.enabled) {
            iconView.tintColor = [UIColor tertiaryLabelColor];
            return;
        }
        iconView.tintColor = sender.on ? (iconColor ?: [UIColor systemBlueColor])
                                       : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    }
}

- (void)addSeparator {
    CGFloat hairline = 1.0 / UIScreen.mainScreen.scale;
    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor separatorColor];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:separator];
    
    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintEqualToConstant:hairline],
        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:56],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:hairline],
        [separator.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
    ]];
    
    [self.contentStack addArrangedSubview:container];
}

@end

static NSString *CLDebugValueWithRaw(NSString *label, NSString *raw) {
    NSString *safeLabel = label.length > 0 ? label : CLL(@"未知");
    if (raw.length == 0 || [safeLabel isEqualToString:raw]) {
        return safeLabel;
    }
    return [NSString stringWithFormat:@"%@ (%@)", safeLabel, raw];
}

static BOOL CLHoldSuppressedBySystemCapacityControl(CLBatteryManager *manager) {
    return manager.chargeAbove >= 100 && manager.systemCapacityControlAt100Enabled;
}

static NSString *CLHoldUnavailableReason(CLBatteryManager *manager) {
    if (CLHoldSuppressedBySystemCapacityControl(manager)) {
        return CLL(@"停止电量=100% 且交由系统控制时停用");
    }
    if (!manager.holdModeEnabled) {
        return CLL(@"未启用");
    }
    return nil;
}

static NSString *CLPolicyStateLabel(NSString *policyState) {
    if ([policyState isEqualToString:@"hold_recharge"]) {
        return CLL(@"插电保持中 · 补电");
    }
    if ([policyState isEqualToString:@"hold"]) {
        return CLL(@"插电保持中");
    }
    if ([policyState isEqualToString:@"stopped"]) {
        return CLL(@"已连接电源 · 停止充电");
    }
    if ([policyState isEqualToString:@"temp_paused"]) {
        return CLL(@"温控暂停充电");
    }
    if ([policyState isEqualToString:@"no_inflow"]) {
        return CLL(@"停充时已禁流");
    }
    if ([policyState isEqualToString:@"charging"]) {
        return CLL(@"正在充电");
    }
    if ([policyState isEqualToString:@"external_idle"]) {
        return CLL(@"已连接电源 · 未充电");
    }
    if ([policyState isEqualToString:@"battery"]) {
        return CLL(@"使用电池");
    }
    return CLL(@"未知");
}

static NSString *CLPolicyReasonLabel(NSString *reason) {
    if ([reason isEqualToString:@"daemon_boot"]) {
        return CLL(@"守护启动后的初始状态");
    }
    if ([reason isEqualToString:@"battery_idle"]) {
        return CLL(@"当前未连接外部电源");
    }
    if ([reason isEqualToString:@"external_idle"]) {
        return CLL(@"已连接电源，等待系统电流变化");
    }
    if ([reason isEqualToString:@"charging_active"]) {
        return CLL(@"系统当前正在充电");
    }
    if ([reason isEqualToString:@"critical_low_battery"]) {
        return CLL(@"低电量保护，强制恢复充电");
    }
    if ([reason isEqualToString:@"temperature_high"]) {
        return CLL(@"温度达到上限，暂停充电");
    }
    if ([reason isEqualToString:@"full_charge_window"]) {
        return CLL(@"满充计划窗口内，暂时解除上限");
    }
    if ([reason isEqualToString:@"hold_target_reached"]) {
        return CLL(@"达到保持目标，停止充电");
    }
    if ([reason isEqualToString:@"hold_band_lower_reached"]) {
        return CLL(@"低于保持下边界，开始补电");
    }
    if ([reason isEqualToString:@"hold_monitoring"]) {
        return CLL(@"保持区间内等待下一次检查");
    }
    if ([reason isEqualToString:@"hold_recharge_active"]) {
        return CLL(@"保持补电进行中");
    }
    if ([reason isEqualToString:@"capacity_high"]) {
        return CLL(@"达到电量上限，停止充电");
    }
    if ([reason isEqualToString:@"temperature_recovered"]) {
        return CLL(@"温度恢复到安全范围，恢复充电");
    }
    if ([reason isEqualToString:@"capacity_low"]) {
        return CLL(@"低于电量下限，恢复充电");
    }
    if ([reason isEqualToString:@"plug_mode_start"]) {
        return CLL(@"插电即充模式下检测到接入电源");
    }
    if ([reason isEqualToString:@"edge_mode_stop"]) {
        return CLL(@"检测到旧模式配置，已按插电即充处理");
    }
    if ([reason isEqualToString:@"adaptor_disconnected"]) {
        return CLL(@"检测到拔掉电源");
    }
    if ([reason isEqualToString:@"stopped_command_or_inhibit"]) {
        return CLL(@"由于停充命令或系统抑制，保持停止");
    }
    if ([reason isEqualToString:@"no_inflow_active"]) {
        return CLL(@"禁流已生效");
    }
    if ([reason isEqualToString:@"smart_charge_temporarily_disabled"]) {
        return CLL(@"当前策略进入接管范围，已临时停用系统优化充电");
    }
    if ([reason isEqualToString:@"smart_charge_restored"]) {
        return CLL(@"当前策略退出接管范围，已尝试恢复系统优化充电");
    }
    if ([reason isEqualToString:@"smart_charge_permanently_disabled"]) {
        return CLL(@"根据当前配置，已关闭系统优化充电");
    }
    if ([reason isEqualToString:@"smart_charge_session_released"]) {
        return CLL(@"系统优化充电状态已变化，本工具结束当前接管会话");
    }
    return CLL(@"未知");
}

static NSString *CLSmartChargeStatusLabel(NSInteger status, BOOL managedByDaemon) {
    switch (status) {
        case 0:
            return CLL(@"已关闭");
        case 1:
            return CLL(@"已启用");
        case 2:
            return CLL(@"满充窗口");
        case 3:
            return managedByDaemon ? CLL(@"已临时停用 · 由本工具控制") : CLL(@"已临时停用");
        default:
            return CLL(@"未知");
    }
}

static NSString *CLTimestampLabel(NSTimeInterval timestamp) {
    if (timestamp <= 0) {
        return CLL(@"未记录");
    }
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    formatter.locale = NSLocale.autoupdatingCurrentLocale;
    formatter.timeZone = NSTimeZone.localTimeZone;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

static NSString *CLCompactTimestampLabel(NSTimeInterval timestamp) {
    if (timestamp <= 0) {
        return @"--";
    }
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss";
    });
    formatter.locale = NSLocale.autoupdatingCurrentLocale;
    formatter.timeZone = NSTimeZone.localTimeZone;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

static NSString *CLYesNoLabel(BOOL value) {
    return value ? CLL(@"是") : CLL(@"否");
}

static const NSInteger CLAdvDisableInflowTag = 301;
static const NSInteger CLAdvHoldModeTag = 302;
static const NSInteger CLAdvSystemCapacityControlAt100Tag = 315;
static const NSInteger CLAdvHoldTempDisableSmartChargeTag = 312;
static const NSInteger CLAdvDisableSmartChargeTag = 311;
static const NSInteger CLAdvHoldModeBandTag = 305;
static const NSInteger CLAdvHoldModeBehaviorTag = 313;

#pragma mark - 策略诊断控制器

@interface CLPolicyDiagnosticsViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *valueLabels;
@property (nonatomic, assign) BOOL probeRunning;
@property (nonatomic, assign) BOOL lastProbeFailed;
@property (nonatomic, copy) NSString *lastProbeSummaryText;
@property (nonatomic, copy) NSDictionary *lastProbePayload;
@property (nonatomic, weak) UIButton *probeButton; // 若沿用 picker row，可改存 row view
@property (nonatomic, strong) UILabel *probeResultLabel;
@end

@implementation CLPolicyDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    CLApplyLanguageFromSettings();
    self.title = CLL(@"策略诊断");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.valueLabels = [NSMutableDictionary dictionary];

    if (@available(iOS 13.0, *)) {
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }

    [self setupScrollView];
    [self setupContent];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange)
                                                 name:CLAppLanguageDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(batteryInfoDidUpdate)
                                                 name:CLBatteryInfoDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(configDidUpdate)
                                                 name:CLConfigDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(daemonStatusDidChange)
                                                 name:CLDaemonStatusDidChangeNotification
                                               object:nil];

    [[CLBatteryManager shared] refreshAll];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateDiagnosticValues];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.alwaysBounceHorizontal = NO;
    [self.view addSubview:self.scrollView];

    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 20;
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:containerView];
    [containerView addSubview:self.mainStack];

    NSLayoutConstraint *widthConstraint = [self.mainStack.widthAnchor constraintEqualToAnchor:containerView.widthAnchor constant:-40];
    widthConstraint.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [containerView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
        [containerView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [containerView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [containerView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [containerView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],

        [self.mainStack.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:20],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-40],
        [self.mainStack.centerXAnchor constraintEqualToAnchor:containerView.centerXAnchor],
        [self.mainStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:containerView.leadingAnchor constant:20],
        [self.mainStack.trailingAnchor constraintLessThanOrEqualToAnchor:containerView.trailingAnchor constant:-20],
        widthConstraint,
        [self.mainStack.widthAnchor constraintLessThanOrEqualToConstant:600],
    ]];
}

- (void)setupContent {
    [self.valueLabels removeAllObjects];

    CLAdvSettingsCard *runtimeCard = [[CLAdvSettingsCard alloc] init];
    [runtimeCard addSectionHeader:CLL(@"策略运行时")];
    [self addDiagnosticRowToCard:runtimeCard key:@"policy_state" icon:@"point.topleft.down.curvedto.point.bottomright.up" title:CLL(@"守护策略") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"policy_reason" icon:@"info.circle" title:CLL(@"当前状态原因") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"last_policy_change_time" icon:@"clock" title:CLL(@"最近策略切换时间") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"last_policy_change_reason" icon:@"info.circle" title:CLL(@"最近策略切换原因") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"charge_command" icon:@"bolt.shield" title:CLL(@"充电命令") color:[UIColor systemGreenColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"last_charge_command_time" icon:@"clock" title:CLL(@"最近充电命令时间") color:[UIColor systemGreenColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"predictive_inhibit" icon:@"bolt.slash" title:CLL(@"系统停充抑制") color:[UIColor systemRedColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"smart_charge_status" icon:@"battery.100.circle" title:CLL(@"系统优化充电") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"smart_charge_managed" icon:@"gearshape.2" title:CLL(@"由本工具接管") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"smart_charge_original_status" icon:@"battery.100.circle" title:CLL(@"接管前系统状态") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"smart_charge_coordination_session" icon:@"number.square" title:CLL(@"协调会话") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"smart_charge_coordination_start_time" icon:@"clock" title:CLL(@"接管开始时间") color:[UIColor systemBlueColor]];
    [runtimeCard addSeparator];
    [self addDiagnosticRowToCard:runtimeCard key:@"last_inflow_command_time" icon:@"clock" title:CLL(@"最近禁流/恢复时间") color:[UIColor systemRedColor]];
    [self addTipRowToCard:runtimeCard text:CLL(@"仅用于观察插电保持当前状态与检查节奏，不会改变正常使用逻辑。")];
    [self.mainStack addArrangedSubview:runtimeCard];

    CLAdvSettingsCard *holdCard = [[CLAdvSettingsCard alloc] init];
    [holdCard addSectionHeader:CLL(@"保持诊断")];
    [self addDiagnosticRowToCard:holdCard key:@"hold_interval" icon:@"timer" title:CLL(@"检查间隔") color:[UIColor systemIndigoColor]];
    [holdCard addSeparator];
    [self addDiagnosticRowToCard:holdCard key:@"hold_target" icon:@"scope" title:CLL(@"保持目标") color:[UIColor systemIndigoColor]];
    [holdCard addSeparator];
    [self addDiagnosticRowToCard:holdCard key:@"hold_band" icon:@"arrow.left.arrow.right" title:CLL(@"补电阈值") color:[UIColor systemIndigoColor]];
    [holdCard addSeparator];
    [self addDiagnosticRowToCard:holdCard key:@"hold_lower_bound" icon:@"scope" title:CLL(@"保持下边界") color:[UIColor systemIndigoColor]];
    [self.mainStack addArrangedSubview:holdCard];

    CLAdvSettingsCard *signalCard = [[CLAdvSettingsCard alloc] init];
    [signalCard addSectionHeader:CLL(@"实时信号")];
    [self addDiagnosticRowToCard:signalCard key:@"current_capacity" icon:@"battery.50" title:CLL(@"当前电量") color:[UIColor systemTealColor]];
    [signalCard addSeparator];
    [self addDiagnosticRowToCard:signalCard key:@"temperature" icon:@"thermometer" title:CLL(@"电池温度") color:[UIColor systemTealColor]];
    [signalCard addSeparator];
    [self addDiagnosticRowToCard:signalCard key:@"amperage" icon:@"bolt.fill" title:CLL(@"电池电流") color:[UIColor systemTealColor]];
    [signalCard addSeparator];
    [self addDiagnosticRowToCard:signalCard key:@"instant_amperage" icon:@"bolt.circle" title:CLL(@"瞬时电流") color:[UIColor systemTealColor]];
    [signalCard addSeparator];
    [self addDiagnosticRowToCard:signalCard key:@"is_charging" icon:@"bolt" title:CLL(@"是否正在充电") color:[UIColor systemTealColor]];
    [signalCard addSeparator];
    [self addDiagnosticRowToCard:signalCard key:@"external_connected" icon:@"power" title:CLL(@"是否连接外部电源") color:[UIColor systemTealColor]];
    [signalCard addSeparator];
    [self addDiagnosticRowToCard:signalCard key:@"external_charge_capable" icon:@"power" title:CLL(@"系统判定可充电") color:[UIColor systemTealColor]];
    [self.mainStack addArrangedSubview:signalCard];

    CLAdvSettingsCard *powerCard = [[CLAdvSettingsCard alloc] init];
    [powerCard addSectionHeader:CLL(@"供电环境")];
    [self addDiagnosticRowToCard:powerCard key:@"adapter_name" icon:@"power" title:CLL(@"适配器") color:[UIColor systemOrangeColor]];
    [powerCard addSeparator];
    [self addDiagnosticRowToCard:powerCard key:@"adapter_watts" icon:@"bolt.fill" title:CLL(@"适配器功率") color:[UIColor systemOrangeColor]];
    [powerCard addSeparator];
    [self addDiagnosticRowToCard:powerCard key:@"power_source_kind" icon:@"bolt.circle" title:CLL(@"充电方式") color:[UIColor systemOrangeColor]];
    [self.mainStack addArrangedSubview:powerCard];

    CLAdvSettingsCard *historyCard = [[CLAdvSettingsCard alloc] init];
    [historyCard addSectionHeader:CLL(@"最近策略切换")];
    [self addDiagnosticRowToCard:historyCard key:@"policy_transition_history" icon:@"list.bullet.rectangle" title:CLL(@"最近若干次状态变化") color:[UIColor systemPurpleColor]];
    [self addTipRowToCard:historyCard text:CLL(@"这里展示 daemon 运行期内最近几次状态切换，便于回看进入保持、等待检查和恢复补电的变化。")];
    [self.mainStack addArrangedSubview:historyCard];

    CLAdvSettingsCard *timelineCard = [[CLAdvSettingsCard alloc] init];
    [timelineCard addSectionHeader:CLL(@"长时间事件时间线")];
    [self addDiagnosticRowToCard:timelineCard key:@"policy_event_history" icon:@"clock" title:CLL(@"最近持久化策略事件") color:[UIColor systemPurpleColor]];
    [self addTipRowToCard:timelineCard text:CLL(@"这里展示已持久化的最近策略事件，daemon 重启后也会尽量保留。")];
    [self.mainStack addArrangedSubview:timelineCard];

    CLAdvSettingsCard *probeCard = [[CLAdvSettingsCard alloc] init];
    [probeCard addSectionHeader:CLL(@"停充控制探针")];
    [probeCard addPickerRowWithIcon:@"waveform.path.ecg"
                              title:CLL(@"运行停充控制探针")
                              value:CLL(@"运行")
                              color:[UIColor systemTealColor]
                                tag:910
                             target:self
                             action:@selector(runChargeControlProbeTapped:)];
    [probeCard addSeparator];
    [probeCard addPickerRowWithIcon:@"doc.on.doc"
                              title:CLL(@"复制探针结果")
                              value:CLL(@"复制")
                              color:[UIColor systemBlueColor]
                                tag:911
                             target:self
                             action:@selector(copyChargeControlProbeResultTapped:)];
    UILabel *probeResult = [probeCard addValueRowWithIcon:@"text.alignleft"
                                                    title:CLL(@"最近探针结论")
                                                    value:CLL(@"尚未运行")
                                                    color:[UIColor systemGrayColor]];
    self.probeResultLabel = probeResult;
    [self addTipRowToCard:probeCard
                     text:CLL(@"建议插电后运行。将短暂尝试停充并自动恢复，用于确认 iOS 控制面是否真正生效。")];
    UIView *probeTipRow = probeCard.contentStack.arrangedSubviews.lastObject;
    for (UIView *subview in probeTipRow.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            ((UILabel *)subview).numberOfLines = 0;
            break;
        }
    }
    [self.mainStack addArrangedSubview:probeCard];
    [self restoreProbeResultLabelText];

    CLAdvSettingsCard *exportCard = [[CLAdvSettingsCard alloc] init];
    [exportCard addSectionHeader:CLL(@"导出与校准")];
    [exportCard addPickerRowWithIcon:@"doc.on.doc" title:CLL(@"复制诊断摘要") value:CLL(@"复制") color:[UIColor systemBlueColor] tag:900 target:self action:@selector(copyDiagnosticSummaryTapped:)];
    [exportCard addSeparator];
    [exportCard addPickerRowWithIcon:@"square.and.arrow.up" title:CLL(@"导出事件时间线") value:CLL(@"导出") color:[UIColor systemBlueColor] tag:901 target:self action:@selector(exportPolicyEventTimelineTapped:)];
    [exportCard addSeparator];
    [exportCard addPickerRowWithIcon:@"list.bullet.rectangle" title:CLL(@"复制长测校准模板") value:CLL(@"复制") color:[UIColor systemBlueColor] tag:902 target:self action:@selector(copyCalibrationChecklistTapped:)];
    [self addTipRowToCard:exportCard text:CLL(@"可导出当前关键状态、最近长时间事件，以及真机长测与阈值校准模板。")];
    [self.mainStack addArrangedSubview:exportCard];

    [self updateDiagnosticValues];
}

- (void)addDiagnosticRowToCard:(CLAdvSettingsCard *)card
                           key:(NSString *)key
                          icon:(NSString *)iconName
                         title:(NSString *)title
                         color:(UIColor *)color {
    UILabel *valueLabel = [card addValueRowWithIcon:iconName title:title value:@"--" color:color];
    if (key.length > 0 && valueLabel != nil) {
        self.valueLabels[key] = valueLabel;
    }
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

- (void)languageDidChange {
    CLApplyLanguageFromSettings();
    self.title = CLL(@"策略诊断");
    for (UIView *view in self.view.subviews) {
        [view removeFromSuperview];
    }
    [self setupScrollView];
    [self setupContent];
}

- (void)batteryInfoDidUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDiagnosticValues];
    });
}

- (void)configDidUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDiagnosticValues];
    });
}

- (void)daemonStatusDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDiagnosticValues];
    });
}

- (void)updateDiagnosticValue:(NSString *)value forKey:(NSString *)key {
    UILabel *label = self.valueLabels[key];
    if (label != nil) {
        label.text = value ?: @"--";
    }
}

- (NSString *)holdBandTextForManager:(CLBatteryManager *)manager {
    NSString *base = [NSString stringWithFormat:CLL(@"目标下方 %ld%%"), (long)MAX(manager.holdModeBand, 1)];
    NSString *reason = CLHoldUnavailableReason(manager);
    if (reason.length > 0) {
        return [NSString stringWithFormat:@"%@ · %@", base, reason];
    }
    return base;
}

- (NSString *)holdTargetTextForManager:(CLBatteryManager *)manager {
    NSString *base = manager.holdTarget > 0 ? [NSString stringWithFormat:@"%ld%%", (long)manager.holdTarget] : CLL(@"未记录");
    NSString *reason = CLHoldUnavailableReason(manager);
    if (reason.length > 0) {
        return [NSString stringWithFormat:@"%@ · %@", base, reason];
    }
    return base;
}

- (NSString *)holdLowerBoundTextForManager:(CLBatteryManager *)manager {
    NSString *base = [NSString stringWithFormat:@"%ld%%", (long)MAX(manager.holdRangeLower, 0)];
    NSString *reason = CLHoldUnavailableReason(manager);
    if (reason.length > 0) {
        return [NSString stringWithFormat:@"%@ · %@", base, reason];
    }
    return base;
}

- (NSString *)holdIntervalTextForManager:(CLBatteryManager *)manager {
    NSString *base = [NSString stringWithFormat:CLL(@"%ld 分钟"), (long)MAX(manager.holdCheckIntervalMinutes, 1)];
    NSString *reason = CLHoldUnavailableReason(manager);
    if (reason.length > 0) {
        return [NSString stringWithFormat:@"%@ · %@", base, reason];
    }
    return base;
}

- (NSString *)smartChargeOriginalStatusTextForManager:(CLBatteryManager *)manager {
    if (manager.smartChargeCoordinationSessionID.length == 0 && manager.smartChargeCoordinationStartTime <= 0) {
        return CLL(@"未接管");
    }
    if (manager.smartChargeOriginalStatus < 0) {
        return CLL(@"未记录");
    }
    NSString *raw = [NSString stringWithFormat:@"%ld", (long)manager.smartChargeOriginalStatus];
    return CLDebugValueWithRaw(CLSmartChargeStatusLabel(manager.smartChargeOriginalStatus, NO), raw);
}

- (NSString *)smartChargeCoordinationSessionTextForManager:(CLBatteryManager *)manager {
    if (manager.smartChargeCoordinationSessionID.length == 0) {
        return CLL(@"未接管");
    }
    return manager.smartChargeCoordinationSessionID;
}

- (NSString *)smartChargeCoordinationStartTimeTextForManager:(CLBatteryManager *)manager {
    if (manager.smartChargeCoordinationStartTime <= 0) {
        return CLL(@"未接管");
    }
    return CLTimestampLabel(manager.smartChargeCoordinationStartTime);
}

- (NSString *)adapterNameTextForManager:(CLBatteryManager *)manager {
    if (!manager.externalConnected) {
        return CLL(@"未连接");
    }
    if (manager.adapterName.length > 0) {
        return manager.adapterName;
    }
    if (manager.adapterDescription.length > 0) {
        return manager.adapterDescription;
    }
    return CLL(@"未知");
}

- (NSString *)adapterWattsTextForManager:(CLBatteryManager *)manager {
    if (!manager.externalConnected) {
        return CLL(@"未连接");
    }
    if (manager.adapterWatts > 0) {
        return [NSString stringWithFormat:@"%ld W", (long)manager.adapterWatts];
    }
    return CLL(@"未知");
}

- (NSString *)powerSourceKindTextForManager:(CLBatteryManager *)manager {
    if (!manager.externalConnected) {
        return CLL(@"未连接");
    }
    return manager.isWirelessCharging ? CLL(@"无线充电") : CLL(@"有线充电");
}

- (NSString *)recentPolicyTransitionsTextForManager:(CLBatteryManager *)manager {
    if (manager.policyTransitionHistory.count == 0) {
        return CLL(@"未记录");
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger lineCount = 0;
    for (NSDictionary *item in [manager.policyTransitionHistory reverseObjectEnumerator]) {
        NSString *fromState = [item[@"from"] isKindOfClass:[NSString class]] ? item[@"from"] : @"";
        NSString *toState = [item[@"to"] isKindOfClass:[NSString class]] ? item[@"to"] : @"";
        NSString *reason = [item[@"reason"] isKindOfClass:[NSString class]] ? item[@"reason"] : @"unknown";
        NSTimeInterval ts = [item[@"ts"] doubleValue];

        NSString *resolvedToState = toState.length > 0 ? toState : CLL(@"未知");
        NSString *transition = resolvedToState;
        if (fromState.length > 0 && ![fromState isEqualToString:toState]) {
            transition = [NSString stringWithFormat:@"%@ -> %@", fromState, resolvedToState];
        }

        [lines addObject:[NSString stringWithFormat:@"%@  %@ · %@",
                          CLCompactTimestampLabel(ts),
                          transition,
                          reason.length > 0 ? reason : @"unknown"]];
        lineCount += 1;
        if (lineCount >= 6) {
            break;
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSString *)policyEventLineTextForItem:(NSDictionary *)item includeRuntimeDetails:(BOOL)includeRuntimeDetails {
    NSString *reason = [item[@"reason"] isKindOfClass:[NSString class]] ? item[@"reason"] : @"unknown";
    NSTimeInterval ts = [item[@"ts"] doubleValue];

    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    [segments addObject:[NSString stringWithFormat:@"%@  %@", CLCompactTimestampLabel(ts), [self policyEventDisplayTextForItem:item]]];
    [segments addObject:CLPolicyReasonLabel(reason)];

    NSInteger capacity = [item[@"capacity"] integerValue];
    if (capacity > 0) {
        [segments addObject:[NSString stringWithFormat:@"%ld%%", (long)capacity]];
    }

    NSInteger current = [item[@"current"] integerValue];
    if (current != 0) {
        [segments addObject:[NSString stringWithFormat:@"%ld mA", (long)current]];
    }

    NSInteger temperature = [item[@"temperature"] integerValue];
    if (temperature > 0) {
        [segments addObject:[NSString stringWithFormat:@"%.1f°C", temperature / 100.0]];
    }

    if (includeRuntimeDetails) {
        NSNumber *holdCheckInterval = [item[@"hold_check_interval_minutes"] respondsToSelector:@selector(integerValue)] ? item[@"hold_check_interval_minutes"] : nil;
        if (holdCheckInterval != nil) {
            [segments addObject:[NSString stringWithFormat:@"%@: %@",
                                 CLL(@"检查间隔"),
                                 [NSString stringWithFormat:CLL(@"%ld 分钟"), (long)MAX(holdCheckInterval.integerValue, 1)]]];
        }

        NSInteger smartChargeStatus = [item[@"smart_charge_status"] integerValue];
        BOOL smartChargeManaged = [item[@"smart_charge_managed"] boolValue];
        [segments addObject:[NSString stringWithFormat:@"%@: %@",
                             CLL(@"系统优化充电"),
                             CLSmartChargeStatusLabel(smartChargeStatus, smartChargeManaged)]];
    }

    return [segments componentsJoinedByString:@" · "];
}

- (NSString *)policyEventDisplayTextForItem:(NSDictionary *)item {
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"policy_transition";
    if ([type isEqualToString:@"smart_charge_event"]) {
        NSInteger fromStatus = [item[@"smart_charge_from"] integerValue];
        NSInteger toStatus = [item[@"smart_charge_to"] integerValue];
        NSString *fromLabel = CLSmartChargeStatusLabel(fromStatus, fromStatus == 3);
        NSString *toLabel = CLSmartChargeStatusLabel(toStatus, toStatus == 3);
        NSString *resolvedLabel = toLabel.length > 0 ? toLabel : fromLabel;
        if (fromLabel.length > 0 && toLabel.length > 0 && fromStatus != toStatus) {
            return [NSString stringWithFormat:@"%@  %@ -> %@", CLL(@"系统优化充电"), fromLabel, toLabel];
        }
        return [NSString stringWithFormat:@"%@  %@", CLL(@"系统优化充电"), resolvedLabel.length > 0 ? resolvedLabel : CLL(@"未知")];
    }
    if ([type isEqualToString:@"hold_behavior_event"]) {
        return CLL(@"插电保持配置已更新");
    }

    NSString *fromState = [item[@"from"] isKindOfClass:[NSString class]] ? item[@"from"] : @"";
    NSString *toState = [item[@"to"] isKindOfClass:[NSString class]] ? item[@"to"] : @"";
    NSString *toLabel = toState.length > 0 ? CLPolicyStateLabel(toState) : CLL(@"未知");
    if (fromState.length > 0 && ![fromState isEqualToString:toState]) {
        return [NSString stringWithFormat:@"%@ -> %@", CLPolicyStateLabel(fromState), toLabel];
    }
    return toLabel;
}

- (NSString *)policyEventHistoryTextForManager:(CLBatteryManager *)manager {
    if (manager.policyEventHistory.count == 0) {
        return CLL(@"未记录");
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger lineCount = 0;
    for (NSDictionary *item in [manager.policyEventHistory reverseObjectEnumerator]) {
        [lines addObject:[self policyEventLineTextForItem:item includeRuntimeDetails:NO]];
        lineCount += 1;
        if (lineCount >= 8) {
            break;
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSString *)policyEventHistoryExportTextForManager:(CLBatteryManager *)manager {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:CLL(@"策略事件时间线")];
    if (manager.policyEventHistory.count == 0) {
        [lines addObject:CLL(@"未记录")];
        return [lines componentsJoinedByString:@"\n"];
    }

    NSInteger lineCount = 0;
    for (NSDictionary *item in [manager.policyEventHistory reverseObjectEnumerator]) {
        [lines addObject:[self policyEventLineTextForItem:item includeRuntimeDetails:YES]];
        lineCount += 1;
        if (lineCount >= 24) {
            break;
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSString *)diagnosticSummaryTextForManager:(CLBatteryManager *)manager {
    NSString *smartChargeCode = [NSString stringWithFormat:@"%ld", (long)manager.smartChargeStatus];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:CLL(@"策略诊断")];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"守护策略"),
                      CLDebugValueWithRaw(CLPolicyStateLabel(manager.policyState), manager.policyState)]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"当前状态原因"),
                      CLDebugValueWithRaw(CLPolicyReasonLabel(manager.policyReason), manager.policyReason)]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"检查间隔"),
                      [self holdIntervalTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"保持目标"),
                      [self holdTargetTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"补电阈值"),
                      [self holdBandTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"系统优化充电"),
                      CLDebugValueWithRaw(CLSmartChargeStatusLabel(manager.smartChargeStatus, manager.smartChargeManagedByDaemon), smartChargeCode)]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"由本工具接管"),
                      CLYesNoLabel(manager.smartChargeManagedByDaemon)]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"接管前系统状态"),
                      [self smartChargeOriginalStatusTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"协调会话"),
                      [self smartChargeCoordinationSessionTextForManager:manager]]];
    [lines addObject:@""];
    [lines addObject:[self policyEventHistoryExportTextForManager:manager]];
    return [lines componentsJoinedByString:@"\n"];
}

- (NSString *)calibrationChecklistTextForManager:(CLBatteryManager *)manager {
    NSString *smartChargeCode = [NSString stringWithFormat:@"%ld", (long)manager.smartChargeStatus];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:CLL(@"真机长测与阈值校准模板")];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"记录时间"),
                      CLTimestampLabel([[NSDate date] timeIntervalSince1970])]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"设备"),
                      manager.deviceModel.length > 0 ? manager.deviceModel : CLL(@"未知")]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"系统版本"),
                      manager.systemVersion.length > 0 ? manager.systemVersion : CLL(@"未知")]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"应用版本"),
                      manager.appVersion.length > 0 ? manager.appVersion : CLL(@"未知")]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"当前策略"),
                      CLDebugValueWithRaw(CLPolicyStateLabel(manager.policyState), manager.policyState)]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"检查间隔"),
                      [self holdIntervalTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"保持目标"),
                      [self holdTargetTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"补电阈值"),
                      [self holdBandTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"系统优化充电"),
                      CLDebugValueWithRaw(CLSmartChargeStatusLabel(manager.smartChargeStatus, manager.smartChargeManagedByDaemon), smartChargeCode)]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"适配器"),
                      [self adapterNameTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %@",
                      CLL(@"适配器功率"),
                      [self adapterWattsTextForManager:manager]]];
    [lines addObject:[NSString stringWithFormat:@"%@: %ld%%",
                      CLL(@"当前电量"),
                      (long)manager.currentCapacity]];
    [lines addObject:[NSString stringWithFormat:@"%@: %.1f°C",
                      CLL(@"电池温度"),
                      manager.temperature]];
    [lines addObject:[NSString stringWithFormat:@"%@: %ld mA",
                      CLL(@"瞬时电流"),
                      (long)manager.instantAmperage]];
    [lines addObject:@""];
    [lines addObject:CLL(@"建议验证项")];
    [lines addObject:CLL(@"1. 长时间轻负载插电：观察电量是否稳定停留在目标附近，是否频繁补电。")];
    [lines addObject:CLL(@"2. 中高负载插电：观察电量是否在保持区间内缓慢下滑，以及低于下边界后才恢复补电。")];
    [lines addObject:CLL(@"3. 温控往返：观察接近高温阈值后是否暂停充电，降温后是否平稳恢复。")];
    [lines addObject:CLL(@"4. Smart Charge 接管：观察进入 hold/stop 时是否临时停用，退出后或 daemon 重启后是否恢复。")];
    [lines addObject:CLL(@"5. 若结果不理想，优先调整补电阈值、检查间隔，再考虑温控阈值。")];
    [lines addObject:@""];
    [lines addObject:CLL(@"观察记录")];
    [lines addObject:CLL(@"- 期望现象：")];
    [lines addObject:CLL(@"- 实际现象：")];
    [lines addObject:CLL(@"- 建议调整：")];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)presentInfoAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreProbeResultLabelText {
    if (self.probeResultLabel == nil) {
        return;
    }
    if (self.probeRunning) {
        self.probeResultLabel.text = CLL(@"运行中…");
        return;
    }
    if (self.lastProbeFailed) {
        self.probeResultLabel.text = CLL(@"探针失败");
        return;
    }
    NSDictionary *data = self.lastProbePayload;
    if (![data isKindOfClass:[NSDictionary class]]) {
        self.probeResultLabel.text = CLL(@"尚未运行");
        return;
    }
    NSDictionary *summary = [data[@"summary"] isKindOfClass:[NSDictionary class]] ? data[@"summary"] : nil;
    if ([summary[@"any_effective"] boolValue]) {
        self.probeResultLabel.text = [NSString stringWithFormat:@"%@: %@",
                                      CLL(@"发现有效路径"),
                                      summary[@"best_path"] ?: @"-"];
    } else {
        self.probeResultLabel.text = [NSString stringWithFormat:@"%@: %@",
                                      CLL(@"未发现有效路径"),
                                      summary[@"dominant_failure"] ?: @"-"];
    }
}

- (NSString *)chargeControlProbeExportTextFromPayload:(NSDictionary *)payload {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return CLL(@"尚无探针结果");
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:CLL(@"停充控制探针结果")];
    [lines addObject:[NSString stringWithFormat:@"device: %@", payload[@"device"] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"sysver: %@", payload[@"sysver"] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"jb_type: %@", payload[@"jb_type"] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"use_smart: %@", payload[@"use_smart"] ?: @"-"]];
    NSDictionary *summary = [payload[@"summary"] isKindOfClass:[NSDictionary class]] ? payload[@"summary"] : @{};
    [lines addObject:[NSString stringWithFormat:@"any_effective: %@", summary[@"any_effective"] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"best_path: %@", summary[@"best_path"] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"dominant_failure: %@", summary[@"dominant_failure"] ?: @"-"]];
    if (summary[@"power_note"]) {
        [lines addObject:[NSString stringWithFormat:@"power_note: %@", summary[@"power_note"]]];
    }
    [lines addObject:@""];
    [lines addObject:CLL(@"分项结果")];
    NSArray *results = [payload[@"results"] isKindOfClass:[NSArray class]] ? payload[@"results"] : @[];
    for (NSDictionary *item in results) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        [lines addObject:[NSString stringWithFormat:@"- %@ / %@ => %@ (write_ret=%@, prop_changed=%@, current_stopped=%@)",
                          item[@"service"] ?: @"-",
                          item[@"path"] ?: @"-",
                          item[@"verdict"] ?: @"-",
                          item[@"write_ret"] ?: @"-",
                          item[@"prop_changed"] ?: @"-",
                          item[@"current_stopped"] ?: @"-"]];
    }
    [lines addObject:@""];
    [lines addObject:CLL(@"完整 JSON")];
    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&err];
    if (jsonData && !err) {
        NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if (json.length > 0) {
            [lines addObject:json];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (void)runChargeControlProbeTapped:(UITapGestureRecognizer *)tap {
    if (self.probeRunning) {
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:CLL(@"运行停充控制探针")
                                                                     message:CLL(@"将短暂尝试多种停充写法并自动恢复。建议插着充电器运行。")
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:CLL(@"运行") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.probeRunning = YES;
        strongSelf.probeResultLabel.text = CLL(@"运行中…");
        [[CLAPIClient shared] runChargeControlProbeWithWaitMs:500 restore:YES completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.probeRunning = NO;
                if (error || response == nil || [response[@"status"] intValue] != 0) {
                    NSString *errMsg = error.localizedDescription
                        ?: [response[@"msg"] description]
                        ?: CLL(@"daemon 未响应");
                    strongSelf.lastProbeFailed = YES;
                    strongSelf.lastProbePayload = nil;
                    strongSelf.lastProbeSummaryText = [NSString stringWithFormat:@"%@\n%@", CLL(@"探针失败"), errMsg];
                    [strongSelf restoreProbeResultLabelText];
                    [strongSelf presentInfoAlertWithTitle:CLL(@"探针失败") message:errMsg];
                    return;
                }
                NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : nil;
                strongSelf.lastProbeFailed = NO;
                strongSelf.lastProbePayload = data;
                NSString *exportText = [strongSelf chargeControlProbeExportTextFromPayload:data];
                strongSelf.lastProbeSummaryText = exportText;
                [strongSelf restoreProbeResultLabelText];
            });
        }];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)copyChargeControlProbeResultTapped:(UITapGestureRecognizer *)tap {
    NSString *text = self.lastProbeSummaryText;
    if (text.length == 0) {
        [self presentInfoAlertWithTitle:CLL(@"尚无结果") message:CLL(@"请先运行停充控制探针。")];
        return;
    }
    [UIPasteboard generalPasteboard].string = text;
    [self presentInfoAlertWithTitle:CLL(@"已复制") message:CLL(@"探针结果已复制到剪贴板。")];
}

- (void)copyDiagnosticSummaryTapped:(UITapGestureRecognizer *)tap {
    NSString *summary = [self diagnosticSummaryTextForManager:[CLBatteryManager shared]];
    [UIPasteboard generalPasteboard].string = summary ?: @"";
    [self presentInfoAlertWithTitle:CLL(@"已复制") message:CLL(@"诊断摘要已复制到剪贴板。")];
}

- (void)exportPolicyEventTimelineTapped:(UITapGestureRecognizer *)tap {
    NSString *text = [self policyEventHistoryExportTextForManager:[CLBatteryManager shared]];
    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[text ?: @""] applicationActivities:nil];
    controller.popoverPresentationController.sourceView = tap.view ?: self.view;
    controller.popoverPresentationController.sourceRect = tap.view ? tap.view.bounds : self.view.bounds;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)copyCalibrationChecklistTapped:(UITapGestureRecognizer *)tap {
    NSString *summary = [self calibrationChecklistTextForManager:[CLBatteryManager shared]];
    [UIPasteboard generalPasteboard].string = summary ?: @"";
    [self presentInfoAlertWithTitle:CLL(@"已复制") message:CLL(@"真机长测与校准模板已复制到剪贴板。")];
}

- (void)updateDiagnosticValues {
    CLBatteryManager *manager = [CLBatteryManager shared];
    NSString *smartChargeCode = [NSString stringWithFormat:@"%ld", (long)manager.smartChargeStatus];

    [self updateDiagnosticValue:CLDebugValueWithRaw(CLPolicyStateLabel(manager.policyState), manager.policyState) forKey:@"policy_state"];
    [self updateDiagnosticValue:CLDebugValueWithRaw(CLPolicyReasonLabel(manager.policyReason), manager.policyReason) forKey:@"policy_reason"];
    [self updateDiagnosticValue:CLTimestampLabel(manager.lastPolicyChangeTime) forKey:@"last_policy_change_time"];
    [self updateDiagnosticValue:CLDebugValueWithRaw(CLPolicyReasonLabel(manager.lastPolicyChangeReason), manager.lastPolicyChangeReason) forKey:@"last_policy_change_reason"];
    [self updateDiagnosticValue:(manager.chargeCommandEnabled ? CLL(@"允许充电") : CLL(@"保持停止")) forKey:@"charge_command"];
    [self updateDiagnosticValue:CLTimestampLabel(manager.lastChargeCommandTime) forKey:@"last_charge_command_time"];
    [self updateDiagnosticValue:(manager.predictiveChargingInhibitActive ? CLL(@"已启用") : CLL(@"未启用")) forKey:@"predictive_inhibit"];
    [self updateDiagnosticValue:CLDebugValueWithRaw(CLSmartChargeStatusLabel(manager.smartChargeStatus, manager.smartChargeManagedByDaemon), smartChargeCode) forKey:@"smart_charge_status"];
    [self updateDiagnosticValue:CLYesNoLabel(manager.smartChargeManagedByDaemon) forKey:@"smart_charge_managed"];
    [self updateDiagnosticValue:[self smartChargeOriginalStatusTextForManager:manager] forKey:@"smart_charge_original_status"];
    [self updateDiagnosticValue:[self smartChargeCoordinationSessionTextForManager:manager] forKey:@"smart_charge_coordination_session"];
    [self updateDiagnosticValue:[self smartChargeCoordinationStartTimeTextForManager:manager] forKey:@"smart_charge_coordination_start_time"];
    [self updateDiagnosticValue:CLTimestampLabel(manager.lastInflowCommandTime) forKey:@"last_inflow_command_time"];

    [self updateDiagnosticValue:[self holdIntervalTextForManager:manager] forKey:@"hold_interval"];
    [self updateDiagnosticValue:[self holdTargetTextForManager:manager] forKey:@"hold_target"];
    [self updateDiagnosticValue:[self holdBandTextForManager:manager] forKey:@"hold_band"];
    [self updateDiagnosticValue:[self holdLowerBoundTextForManager:manager] forKey:@"hold_lower_bound"];

    [self updateDiagnosticValue:[NSString stringWithFormat:@"%ld%%", (long)manager.currentCapacity] forKey:@"current_capacity"];
    [self updateDiagnosticValue:[NSString stringWithFormat:@"%.1f°C", manager.temperature] forKey:@"temperature"];
    [self updateDiagnosticValue:[NSString stringWithFormat:@"%ld mA", (long)manager.amperage] forKey:@"amperage"];
    [self updateDiagnosticValue:[NSString stringWithFormat:@"%ld mA", (long)manager.instantAmperage] forKey:@"instant_amperage"];
    [self updateDiagnosticValue:CLYesNoLabel(manager.isCharging) forKey:@"is_charging"];
    [self updateDiagnosticValue:(manager.externalConnected ? CLL(@"已连接") : CLL(@"未连接")) forKey:@"external_connected"];
    [self updateDiagnosticValue:CLYesNoLabel(manager.externalChargeCapable) forKey:@"external_charge_capable"];
    [self updateDiagnosticValue:[self adapterNameTextForManager:manager] forKey:@"adapter_name"];
    [self updateDiagnosticValue:[self adapterWattsTextForManager:manager] forKey:@"adapter_watts"];
    [self updateDiagnosticValue:[self powerSourceKindTextForManager:manager] forKey:@"power_source_kind"];
    [self updateDiagnosticValue:[self recentPolicyTransitionsTextForManager:manager] forKey:@"policy_transition_history"];
    [self updateDiagnosticValue:[self policyEventHistoryTextForManager:manager] forKey:@"policy_event_history"];
}

@end

#pragma mark - 高级设置控制器

@interface CLAdvancedSettingsViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
- (BOOL)isHoldSuppressedBySystemCapacityControlForManager:(CLBatteryManager *)manager;
- (BOOL)isHoldControlAvailableForManager:(CLBatteryManager *)manager;
- (NSString *)holdUnavailableReasonForManager:(CLBatteryManager *)manager;
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(configDidUpdate)
                                                 name:CLConfigDidUpdateNotification
                                               object:nil];
    if ([self normalizeAdvancedOptionInterlocksIfNeeded]) {
        [self reloadContentRows];
    }
}

- (void)setupScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.alwaysBounceHorizontal = NO;
    [self.view addSubview:self.scrollView];
    
    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 20;
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:containerView];
    [containerView addSubview:self.mainStack];
    
    NSLayoutConstraint *widthConstraint = [self.mainStack.widthAnchor constraintEqualToAnchor:containerView.widthAnchor constant:-40];
    widthConstraint.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        
        [containerView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
        [containerView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [containerView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [containerView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [containerView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],
        
        [self.mainStack.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:20],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-40],
        [self.mainStack.centerXAnchor constraintEqualToAnchor:containerView.centerXAnchor],
        [self.mainStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:containerView.leadingAnchor constant:20],
        [self.mainStack.trailingAnchor constraintLessThanOrEqualToAnchor:containerView.trailingAnchor constant:-20],
        widthConstraint,
        [self.mainStack.widthAnchor constraintLessThanOrEqualToConstant:600],
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
    if ([self normalizeAdvancedOptionInterlocksIfNeeded]) {
        [self reloadContentRows];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)configDidUpdate {
    [self normalizeAdvancedOptionInterlocksIfNeeded];
    [self reloadContentRows];
}

- (BOOL)normalizeAdvancedOptionInterlocksIfNeeded {
    CLBatteryManager *manager = [CLBatteryManager shared];
    BOOL changed = NO;
    if ([self shouldDisableInflowForCurrentModeAndSmartStopWithManager:manager] && manager.disableInflow) {
        manager.disableInflow = NO;
        [[CLAPIClient shared] setConfigWithKey:@"adv_disable_inflow" value:@NO completion:nil];
        changed = YES;
    }
    if (manager.holdModeEnabled && manager.disableInflow) {
        manager.holdModeEnabled = NO;
        [[CLAPIClient shared] setConfigWithKey:@"adv_hold_enabled" value:@NO completion:nil];
        changed = YES;
    }
    if (manager.holdTempDisableSmartCharge && manager.disableSmartCharge) {
        manager.holdTempDisableSmartCharge = NO;
        [[CLAPIClient shared] setConfigWithKey:@"adv_hold_temp_disable_smart_charge" value:@NO completion:nil];
        changed = YES;
    }
    return changed;
}

- (UIView *)switchRowInCard:(CLAdvSettingsCard *)card tag:(NSInteger)tag {
    for (UIView *row in card.contentStack.arrangedSubviews) {
        if (row.tag == tag) {
            return row;
        }
    }
    return nil;
}

- (UIView *)pickerRowInCard:(CLAdvSettingsCard *)card tag:(NSInteger)tag {
    for (UIView *row in card.contentStack.arrangedSubviews) {
        if (row.tag == tag) {
            return row;
        }
    }
    return nil;
}

- (void)updatePickerRow:(UIView *)row enabled:(BOOL)enabled {
    if (!row) {
        return;
    }
    row.userInteractionEnabled = enabled;
    row.alpha = enabled ? 1.0 : 0.5;

    UIColor *baseColor = objc_getAssociatedObject(row, &kCLAdvPickerColorKey);
    UIImageView *iconView = objc_getAssociatedObject(row, &kCLAdvPickerIconViewKey);
    UILabel *titleLabel = objc_getAssociatedObject(row, &kCLAdvPickerTitleLabelKey);
    UILabel *valueLabel = objc_getAssociatedObject(row, &kCLAdvPickerValueLabelKey);
    UIImageView *chevron = objc_getAssociatedObject(row, &kCLAdvPickerChevronKey);

    if (iconView) {
        iconView.tintColor = enabled ? (baseColor ?: [UIColor systemBlueColor]) : [UIColor tertiaryLabelColor];
    }
    if (titleLabel) {
        titleLabel.textColor = enabled ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    }
    if (valueLabel) {
        valueLabel.textColor = enabled ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
    }
    if (chevron) {
        chevron.tintColor = enabled ? [UIColor tertiaryLabelColor] : [UIColor quaternaryLabelColor];
    }
}

- (void)updateSwitchRow:(UIView *)row enabled:(BOOL)enabled {
    if (!row) {
        return;
    }
    UIColor *baseColor = objc_getAssociatedObject(row, &kCLAdvSwitchColorKey);
    UIImageView *iconView = objc_getAssociatedObject(row, &kCLAdvSwitchIconViewKey);
    UILabel *titleLabel = objc_getAssociatedObject(row, &kCLAdvSwitchTitleLabelKey);
    UILabel *subtitleLabel = objc_getAssociatedObject(row, &kCLAdvSwitchSubtitleLabelKey);
    UISwitch *switchView = objc_getAssociatedObject(row, &kCLAdvSwitchViewKey);

    switchView.enabled = enabled;
    switchView.alpha = enabled ? 1.0 : 0.55;

    if (iconView) {
        iconView.tintColor = enabled
            ? (switchView.on ? (baseColor ?: [UIColor systemBlueColor]) : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7])
            : [UIColor tertiaryLabelColor];
    }
    if (titleLabel) {
        titleLabel.textColor = enabled ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    }
    if (subtitleLabel) {
        subtitleLabel.textColor = enabled ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
    }
}

- (void)updateHoldOptionInterlockStateInCard:(CLAdvSettingsCard *)card manager:(CLBatteryManager *)manager {
    BOOL holdOptionsEnabled = [self isHoldControlAvailableForManager:manager];
    [self updateSwitchRow:[self switchRowInCard:card tag:CLAdvHoldModeTag] enabled:holdOptionsEnabled];
    [self updatePickerRow:[self pickerRowInCard:card tag:CLAdvHoldModeBandTag] enabled:holdOptionsEnabled];
    [self updatePickerRow:[self pickerRowInCard:card tag:CLAdvHoldModeBehaviorTag] enabled:holdOptionsEnabled];
}

- (BOOL)shouldDisableInflowForCurrentModeAndSmartStopWithManager:(CLBatteryManager *)manager {
    return manager.chargeMode == CLChargeModePlugAndCharge && manager.predictiveInhibitCharge;
}

- (BOOL)isDisableInflowEffectivelyEnabledForManager:(CLBatteryManager *)manager {
    return manager.disableInflow && ![self shouldDisableInflowForCurrentModeAndSmartStopWithManager:manager];
}

- (BOOL)isHoldSuppressedBySystemCapacityControlForManager:(CLBatteryManager *)manager {
    return CLHoldSuppressedBySystemCapacityControl(manager);
}

- (BOOL)isHoldControlAvailableForManager:(CLBatteryManager *)manager {
    return ![self isDisableInflowEffectivelyEnabledForManager:manager] &&
           ![self isHoldSuppressedBySystemCapacityControlForManager:manager];
}

- (NSString *)holdUnavailableReasonForManager:(CLBatteryManager *)manager {
    return CLHoldUnavailableReason(manager);
}

- (void)updateDisableInflowInterlockStateInCard:(CLAdvSettingsCard *)card manager:(CLBatteryManager *)manager {
    BOOL disableInflowEnabled = ![self shouldDisableInflowForCurrentModeAndSmartStopWithManager:manager];
    [self updateSwitchRow:[self switchRowInCard:card tag:CLAdvDisableInflowTag] enabled:disableInflowEnabled];
}

- (void)updateSmartChargeOptionInterlockStateInCard:(CLAdvSettingsCard *)card manager:(CLBatteryManager *)manager {
    BOOL tempDisableEnabled = !manager.disableSmartCharge;
    [self updateSwitchRow:[self switchRowInCard:card tag:CLAdvHoldTempDisableSmartChargeTag] enabled:tempDisableEnabled];
}

- (void)setupContent {
    CLBatteryManager *manager = [CLBatteryManager shared];
    BOOL disableInflowAvailable = ![self shouldDisableInflowForCurrentModeAndSmartStopWithManager:manager];
    BOOL disableInflowEnabled = [self isDisableInflowEffectivelyEnabledForManager:manager] && disableInflowAvailable;
    BOOL holdModeEnabled = manager.holdModeEnabled;
    BOOL holdTempDisableSmartChargeEnabled = manager.holdTempDisableSmartCharge && !manager.disableSmartCharge;
    
    // 加速充电
    CLAdvSettingsCard *accCard = [[CLAdvSettingsCard alloc] init];
    [accCard addSectionHeader:CLL(@"加速充电")];
    [accCard addPickerRowWithIcon:@"bolt.car" title:CLL(@"加速充电") value:CLL(@"进入") color:[UIColor systemGreenColor] tag:399 target:self action:@selector(accChargeTapped)];
    [self addTipRowToCard:accCard text:CLL(@"关闭部分功能以减少耗电，加快充电速度")];
    [self.mainStack addArrangedSubview:accCard];
    
    // 停充控制
    CLAdvSettingsCard *stopChargeCard = [[CLAdvSettingsCard alloc] init];
    [stopChargeCard addSectionHeader:CLL(@"停充控制")];
    [stopChargeCard addSwitchRowWithIcon:@"bolt.slash.fill" title:CLL(@"智能停充") subtitle:CLL(@"停充时优先使用 PredictiveChargingInhibit 抑制充电；不生效时自动回退到传统 IsCharging 停充") isOn:manager.predictiveInhibitCharge color:[UIColor systemRedColor] tag:300 target:self action:@selector(smartChargeChanged:)];
    [stopChargeCard addSeparator];
    [stopChargeCard addSwitchRowWithIcon:@"battery.100.circle" title:CLL(@"停止电量=100% 时交由系统控制") subtitle:CLL(@"开启后由系统接管电量上限；软件仅保留温度停充。关闭后，100% 仍由本工具继续控制。") isOn:manager.systemCapacityControlAt100Enabled color:[UIColor systemBlueColor] tag:CLAdvSystemCapacityControlAt100Tag target:self action:@selector(systemCapacityControlAt100Changed:)];
    [stopChargeCard addSeparator];
    [stopChargeCard addSwitchRowWithIcon:@"xmark.circle.fill" title:CLL(@"停充时启用禁流") subtitle:CLL(@"禁止电流流入设备，电池放电供电") isOn:disableInflowEnabled color:[UIColor systemRedColor] tag:CLAdvDisableInflowTag target:self action:@selector(disableInflowChanged:)];
    [stopChargeCard addSeparator];
    [stopChargeCard addSwitchRowWithIcon:@"battery.100" title:CLL(@"插电保持") subtitle:CLL(@"围绕“停止充电”目标维持一个缓冲区间，模拟 AlDente 的 Sailing Mode") isOn:holdModeEnabled color:[UIColor systemIndigoColor] tag:CLAdvHoldModeTag target:self action:@selector(holdModeChanged:)];
    if (holdModeEnabled) {
        [stopChargeCard addSeparator];
        [stopChargeCard addPickerRowWithIcon:@"arrow.left.arrow.right" title:CLL(@"补电阈值") value:[self holdModeBandText] color:[UIColor systemIndigoColor] tag:CLAdvHoldModeBandTag target:self action:@selector(holdModeBandTapped:)];
        [stopChargeCard addSeparator];
        [stopChargeCard addPickerRowWithIcon:@"timer" title:CLL(@"检查间隔") value:[self holdCheckIntervalText] color:[UIColor systemIndigoColor] tag:CLAdvHoldModeBehaviorTag target:self action:@selector(holdCheckIntervalTapped:)];
    }
    if ([self isHoldSuppressedBySystemCapacityControlForManager:manager]) {
        [self addTipRowToCard:stopChargeCard text:CLL(@"当前“停止充电”已设为 100%，且选择由系统接管，插电保持暂时停用并置灰；当关闭系统接管或把上限调回 100% 以下时，会自动恢复到你之前的 hold 设置。")];
    }
    [self updateDisableInflowInterlockStateInCard:stopChargeCard manager:manager];
    [self updateHoldOptionInterlockStateInCard:stopChargeCard manager:manager];
    [self.mainStack addArrangedSubview:stopChargeCard];

    // 限流控制
    CLAdvSettingsCard *limitCard = [[CLAdvSettingsCard alloc] init];
    [limitCard addSectionHeader:CLL(@"限流控制")];
    [limitCard addPickerRowWithIcon:@"thermometer.sun.fill" title:CLL(@"限流等级") value:[self limitInflowValueText] color:[UIColor systemOrangeColor] tag:306 target:self action:@selector(limitInflowModeTapped:)];
    [self addTipRowToCard:limitCard text:CLL(@"选择“关闭”可禁用自动限流；其他等级会自动启用。")];
    [self.mainStack addArrangedSubview:limitCard];
    
    // 高温模拟
    CLAdvSettingsCard *thermalCard = [[CLAdvSettingsCard alloc] init];
    [thermalCard addSectionHeader:CLL(@"高温模拟 (Powercuff)")];
    [thermalCard addPickerRowWithIcon:@"flame.fill" title:CLL(@"默认等级") value:[self thermalModeString:manager.thermalMode] color:[UIColor systemOrangeColor] tag:303 target:self action:@selector(thermalModeTapped:)];
    [thermalCard addSeparator];
    [thermalCard addSwitchRowWithIcon:@"thermometer" title:CLL(@"锁定等级") subtitle:CLL(@"防止系统自动调节温度模拟") isOn:manager.thermalModeLock color:[UIColor systemOrangeColor] tag:304 target:self action:@selector(thermalLockChanged:)];
    [self.mainStack addArrangedSubview:thermalCard];

    CLAdvSettingsCard *smartChargeCard = [[CLAdvSettingsCard alloc] init];
    [smartChargeCard addSectionHeader:CLL(@"系统优化充电")];
    [smartChargeCard addSwitchRowWithIcon:@"battery.100.circle" title:CLL(@"永久停用系统优化充电") subtitle:CLL(@"直接关闭系统的优化充电策略；旧版本默认可能已开启") isOn:manager.disableSmartCharge color:[UIColor systemBlueColor] tag:CLAdvDisableSmartChargeTag target:self action:@selector(disableSmartChargeChanged:)];
    [smartChargeCard addSeparator];
    [smartChargeCard addSwitchRowWithIcon:@"clock.badge.checkmark" title:CLL(@"插电保持时临时停用") subtitle:CLL(@"仅在保持/停充阶段暂时停用，退出后尝试恢复系统优化充电") isOn:holdTempDisableSmartChargeEnabled color:[UIColor systemBlueColor] tag:CLAdvHoldTempDisableSmartChargeTag target:self action:@selector(holdTempDisableSmartChargeChanged:)];
    [self updateSmartChargeOptionInterlockStateInCard:smartChargeCard manager:manager];
    [self.mainStack addArrangedSubview:smartChargeCard];

    // 满充计划
    CLAdvSettingsCard *scheduleCard = [[CLAdvSettingsCard alloc] init];
    [scheduleCard addSectionHeader:CLL(@"满充计划")];
    [scheduleCard addSwitchRowWithIcon:@"calendar" title:CLL(@"启用满充计划") subtitle:nil isOn:manager.fullChargeScheduleEnabled color:[UIColor systemTealColor] tag:307 target:self action:@selector(fullChargeScheduleEnabledChanged:)];
    if (manager.fullChargeScheduleEnabled) {
        [scheduleCard addSeparator];
        [scheduleCard addPickerRowWithIcon:@"repeat" title:CLL(@"每隔天数") value:[self fullChargeScheduleIntervalText] color:[UIColor systemTealColor] tag:308 target:self action:@selector(fullChargeScheduleIntervalTapped:)];
        [scheduleCard addSeparator];
        [scheduleCard addPickerRowWithIcon:@"clock" title:CLL(@"开始时间") value:[self fullChargeScheduleStartTimeText] color:[UIColor systemTealColor] tag:309 target:self action:@selector(fullChargeScheduleStartTimeTapped:)];
        [scheduleCard addSeparator];
        [scheduleCard addPickerRowWithIcon:@"timer" title:CLL(@"持续时长") value:[self fullChargeScheduleDurationText] color:[UIColor systemTealColor] tag:310 target:self action:@selector(fullChargeScheduleDurationTapped:)];
    }
    [self addTipRowToCard:scheduleCard text:CLL(@"让设备每隔几天在指定时间暂时解除电量上限；温度控制仍会保留。")];
    [self.mainStack addArrangedSubview:scheduleCard];

    CLAdvSettingsCard *diagnosticsCard = [[CLAdvSettingsCard alloc] init];
    [diagnosticsCard addSectionHeader:CLL(@"调试与观测")];
    [diagnosticsCard addPickerRowWithIcon:@"waveform.path.ecg" title:CLL(@"策略诊断") value:CLL(@"查看") color:[UIColor systemTealColor] tag:314 target:self action:@selector(policyDiagnosticsTapped)];
    [self addTipRowToCard:diagnosticsCard text:CLL(@"集中查看策略切换原因、hold 运行时参数和 Smart Charge 接管状态。")];
    [self.mainStack addArrangedSubview:diagnosticsCard];
    
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

- (NSString *)limitInflowValueText {
    CLBatteryManager *manager = [CLBatteryManager shared];
    if (!manager.limitInflow) {
        return CLL(@"关闭");
    }
    return [self thermalModeString:manager.limitInflowThermalMode];
}

- (NSString *)holdModeBandText {
    NSInteger band = MAX([CLBatteryManager shared].holdModeBand, 1);
    return [NSString stringWithFormat:CLL(@"目标下方 %ld%%"), (long)band];
}

- (NSString *)holdCheckIntervalText {
    NSInteger minutes = MAX([CLBatteryManager shared].holdCheckIntervalMinutes, 1);
    return [NSString stringWithFormat:CLL(@"%ld 分钟"), (long)minutes];
}

- (NSString *)fullChargeScheduleIntervalText {
    NSInteger intervalDays = MAX([CLBatteryManager shared].fullChargeScheduleIntervalDays, 1);
    return [NSString stringWithFormat:CLL(@"每 %ld 天"), (long)intervalDays];
}

- (NSString *)fullChargeScheduleStartTimeText {
    NSInteger startMinute = [CLBatteryManager shared].fullChargeScheduleStartMinute;
    startMinute = MAX(0, MIN(startMinute, 23 * 60 + 59));
    NSInteger hour = startMinute / 60;
    NSInteger minute = startMinute % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)hour, (long)minute];
}

- (NSString *)fullChargeScheduleDurationText {
    NSInteger durationHours = MAX([CLBatteryManager shared].fullChargeScheduleDurationHours, 1);
    return [NSString stringWithFormat:CLL(@"%ld 小时"), (long)durationHours];
}

- (void)reloadContentRows {
    [self.mainStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [self setupContent];
}

- (void)presentIntegerInputAlertWithTitle:(NSString *)title
                                  message:(NSString *)message
                             currentValue:(NSInteger)currentValue
                                 minValue:(NSInteger)minValue
                                 maxValue:(NSInteger)maxValue
                               completion:(void (^)(NSInteger value))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = [NSString stringWithFormat:@"%ld", (long)currentValue];
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.textAlignment = NSTextAlignmentCenter;
        textField.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightMedium];
        dispatch_async(dispatch_get_main_queue(), ^{
            [textField selectAll:nil];
        });
    }];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSInteger value = [alert.textFields.firstObject.text integerValue];
        value = MAX(minValue, MIN(maxValue, value));
        if (completion) {
            completion(value);
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Actions

- (void)accChargeTapped {
    Class vcClass = NSClassFromString(@"CLAccChargeViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)policyDiagnosticsTapped {
    CLPolicyDiagnosticsViewController *vc = [[CLPolicyDiagnosticsViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)smartChargeChanged:(UISwitch *)sender {
    CLBatteryManager *manager = [CLBatteryManager shared];
    manager.predictiveInhibitCharge = sender.on;
    if ([self shouldDisableInflowForCurrentModeAndSmartStopWithManager:manager] && manager.disableInflow) {
        manager.disableInflow = NO;
        [[CLAPIClient shared] setConfigWithKey:@"adv_disable_inflow" value:@NO completion:nil];
    }
    [[CLAPIClient shared] setConfigWithKey:@"adv_predictive_inhibit_charge" value:@(sender.on) completion:nil];
    [self reloadContentRows];
}

- (void)systemCapacityControlAt100Changed:(UISwitch *)sender {
    [CLBatteryManager shared].systemCapacityControlAt100Enabled = sender.on;
    [self reloadContentRows];
}

- (void)disableInflowChanged:(UISwitch *)sender {
    CLBatteryManager *manager = [CLBatteryManager shared];
    if ([self shouldDisableInflowForCurrentModeAndSmartStopWithManager:manager]) {
        manager.disableInflow = NO;
        sender.on = NO;
        [self reloadContentRows];
        return;
    }
    manager.disableInflow = sender.on;
    if (sender.on && manager.holdModeEnabled) {
        manager.holdModeEnabled = NO;
        [[CLAPIClient shared] setConfigWithKey:@"adv_hold_enabled" value:@NO completion:nil];
    }
    [[CLAPIClient shared] setConfigWithKey:@"adv_disable_inflow" value:@(sender.on) completion:nil];
    [self reloadContentRows];
}

- (void)disableSmartChargeChanged:(UISwitch *)sender {
    CLBatteryManager *manager = [CLBatteryManager shared];
    manager.disableSmartCharge = sender.on;
    if (sender.on && manager.holdTempDisableSmartCharge) {
        manager.holdTempDisableSmartCharge = NO;
        [[CLAPIClient shared] setConfigWithKey:@"adv_hold_temp_disable_smart_charge" value:@NO completion:nil];
    }
    [[CLAPIClient shared] setConfigWithKey:@"disable_smart_charge" value:@(sender.on) completion:nil];
    [self reloadContentRows];
}

- (void)holdModeChanged:(UISwitch *)sender {
    CLBatteryManager *manager = [CLBatteryManager shared];
    if (sender.on && [self isHoldSuppressedBySystemCapacityControlForManager:manager]) {
        sender.on = NO;
        [self reloadContentRows];
        return;
    }
    manager.holdModeEnabled = sender.on;
    if (sender.on && manager.disableInflow) {
        manager.disableInflow = NO;
        [[CLAPIClient shared] setConfigWithKey:@"adv_disable_inflow" value:@NO completion:nil];
    }
    [[CLAPIClient shared] setConfigWithKey:@"adv_hold_enabled" value:@(sender.on) completion:nil];
    [self reloadContentRows];
}

- (void)holdTempDisableSmartChargeChanged:(UISwitch *)sender {
    CLBatteryManager *manager = [CLBatteryManager shared];
    if (manager.disableSmartCharge) {
        manager.holdTempDisableSmartCharge = NO;
        sender.on = NO;
        [self reloadContentRows];
        return;
    }
    manager.holdTempDisableSmartCharge = sender.on;
    [[CLAPIClient shared] setConfigWithKey:@"adv_hold_temp_disable_smart_charge" value:@(sender.on) completion:nil];
}

- (void)holdModeBandTapped:(UITapGestureRecognizer *)tap {
    NSInteger currentValue = MAX([CLBatteryManager shared].holdModeBand, 1);
    __weak typeof(self) weakSelf = self;
    [self presentIntegerInputAlertWithTitle:CLL(@"补电阈值")
                                    message:CLL(@"请输入 1 ~ 10 之间的百分比\n达到目标后，电量低于这个阈值时才会恢复补电")
                               currentValue:currentValue
                                   minValue:1
                                   maxValue:10
                                 completion:^(NSInteger value) {
        [CLBatteryManager shared].holdModeBand = value;
        [[CLAPIClient shared] setConfigWithKey:@"adv_hold_band" value:@(value) completion:nil];
        [weakSelf reloadContentRows];
    }];
}

- (void)holdCheckIntervalTapped:(UITapGestureRecognizer *)tap {
    NSInteger currentValue = MAX([CLBatteryManager shared].holdCheckIntervalMinutes, 1);
    __weak typeof(self) weakSelf = self;
    [self presentIntegerInputAlertWithTitle:CLL(@"检查间隔")
                                    message:CLL(@"请输入 1 ~ 10 之间的分钟数\n达到保持目标后，会按这个间隔检查一次是否需要恢复补电")
                               currentValue:currentValue
                                   minValue:1
                                   maxValue:10
                                 completion:^(NSInteger value) {
        [CLBatteryManager shared].holdCheckIntervalMinutes = value;
        [[CLAPIClient shared] setConfigWithKey:@"adv_hold_check_interval_minutes" value:@(value) completion:nil];
        [weakSelf reloadContentRows];
    }];
}

- (void)fullChargeScheduleEnabledChanged:(UISwitch *)sender {
    [CLBatteryManager shared].fullChargeScheduleEnabled = sender.on;
    [[CLAPIClient shared] setConfigWithKey:@"full_charge_sched_enabled" value:@(sender.on) completion:nil];
    [self reloadContentRows];
}

- (void)fullChargeScheduleIntervalTapped:(UITapGestureRecognizer *)tap {
    NSInteger currentValue = MAX([CLBatteryManager shared].fullChargeScheduleIntervalDays, 1);
    __weak typeof(self) weakSelf = self;
    [self presentIntegerInputAlertWithTitle:CLL(@"每隔天数")
                                    message:CLL(@"请输入 1 ~ 90 之间的天数")
                               currentValue:currentValue
                                   minValue:1
                                   maxValue:90
                                 completion:^(NSInteger value) {
        [CLBatteryManager shared].fullChargeScheduleIntervalDays = value;
        [[CLAPIClient shared] setConfigWithKey:@"full_charge_sched_interval_days" value:@(value) completion:nil];
        [weakSelf reloadContentRows];
    }];
}

- (void)fullChargeScheduleStartTimeTapped:(UITapGestureRecognizer *)tap {
    NSInteger startMinute = MAX(0, MIN([CLBatteryManager shared].fullChargeScheduleStartMinute, 23 * 60 + 59));
    NSInteger hour = startMinute / 60;
    NSInteger minute = startMinute % 60;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"开始时间")
                                                                   message:CLL(@"请分别输入小时和分钟")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = CLL(@"小时");
        textField.text = [NSString stringWithFormat:@"%ld", (long)hour];
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.textAlignment = NSTextAlignmentCenter;
        textField.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightMedium];
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = CLL(@"分钟");
        textField.text = [NSString stringWithFormat:@"%02ld", (long)minute];
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.textAlignment = NSTextAlignmentCenter;
        textField.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightMedium];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSInteger inputHour = [alert.textFields.firstObject.text integerValue];
        NSInteger inputMinute = [alert.textFields.lastObject.text integerValue];
        inputHour = MAX(0, MIN(23, inputHour));
        inputMinute = MAX(0, MIN(59, inputMinute));
        NSInteger value = inputHour * 60 + inputMinute;
        [CLBatteryManager shared].fullChargeScheduleStartMinute = value;
        [[CLAPIClient shared] setConfigWithKey:@"full_charge_sched_start_minute" value:@(value) completion:nil];
        [weakSelf reloadContentRows];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)fullChargeScheduleDurationTapped:(UITapGestureRecognizer *)tap {
    NSInteger currentValue = MAX([CLBatteryManager shared].fullChargeScheduleDurationHours, 1);
    __weak typeof(self) weakSelf = self;
    [self presentIntegerInputAlertWithTitle:CLL(@"持续时长")
                                    message:CLL(@"请输入 1 ~ 12 之间的小时数")
                               currentValue:currentValue
                                   minValue:1
                                   maxValue:12
                                 completion:^(NSInteger value) {
        [CLBatteryManager shared].fullChargeScheduleDurationHours = value;
        [[CLAPIClient shared] setConfigWithKey:@"full_charge_sched_duration_hours" value:@(value) completion:nil];
        [weakSelf reloadContentRows];
    }];
}

- (void)limitInflowModeTapped:(UITapGestureRecognizer *)tap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"限流等级") message:CLL(@"选择“关闭”可禁用自动限流\n等级越高，充电电流越小") preferredStyle:UIAlertControllerStyleAlert];
    
    NSArray *modes = @[CLL(@"关闭"), CLL(@"正常"), CLL(@"轻度"), CLL(@"中度"), CLL(@"重度")];
    NSArray *modeValues = @[@"off", @"nominal", @"light", @"moderate", @"heavy"];
    __weak typeof(self) weakSelf = self;
    for (NSInteger i = 0; i < modes.count; i++) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:modes[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            BOOL enableLimit = (i != 0);
            [CLBatteryManager shared].limitInflowThermalMode = (CLThermalMode)i;
            [CLBatteryManager shared].limitInflow = enableLimit;
            [[CLAPIClient shared] setConfigWithKey:@"adv_limit_inflow" value:@(enableLimit) completion:nil];
            [[CLAPIClient shared] setConfigWithKey:@"adv_limit_inflow_mode" value:modeValues[i] completion:nil];
            [weakSelf reloadContentRows];
        }];
        [alert addAction:action];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)thermalModeTapped:(UITapGestureRecognizer *)tap {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"默认高温模拟等级") message:CLL(@"非充电时的高温模拟等级\n等级越高，性能越低，发热越少") preferredStyle:UIAlertControllerStyleAlert];
    
    NSArray *modes = @[CLL(@"关闭"), CLL(@"正常"), CLL(@"轻度"), CLL(@"中度"), CLL(@"重度")];
    NSArray *modeValues = @[@"off", @"nominal", @"light", @"moderate", @"heavy"];
    __weak typeof(self) weakSelf = self;
    for (NSInteger i = 0; i < modes.count; i++) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:modes[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [CLBatteryManager shared].thermalMode = (CLThermalMode)i;
            [[CLAPIClient shared] setConfigWithKey:@"adv_def_thermal_mode" value:modeValues[i] completion:nil];
            [weakSelf reloadContentRows];
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
