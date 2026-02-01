//
//  CLSettingsViewController.m
//  ChargeLimiter
//
//  紧凑型设置界面 - iOS 风格
//

#import "CLSettingsViewController.h"
#import "../CLBatteryManager.h"
#import "../CLAPIClient.h"
#import <objc/runtime.h>

#pragma mark - 紧凑型电池状态视图

@interface CLBatteryStatusView : UIView
@property (nonatomic, assign) CGFloat percentage;
@property (nonatomic, assign) BOOL isCharging;
@property (nonatomic, assign) NSInteger chargeBelow;
@property (nonatomic, assign) NSInteger chargeAbove;
@property (nonatomic, assign) BOOL showLowMarker;
@property (nonatomic, strong) UIView *batteryBody;
@property (nonatomic, strong) UIView *batteryTip;
@property (nonatomic, strong) UIView *batteryInner;
@property (nonatomic, strong) CAGradientLayer *fillGradient;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *glossView;
@property (nonatomic, strong) UIView *lowMarker;
@property (nonatomic, strong) UIView *highMarker;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIImageView *chargingIcon;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation CLBatteryStatusView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _chargeBelow = 20;
        _chargeAbove = 80;
        _percentage = 75;
        _showLowMarker = YES;
        [self setupView];
    }
    return self;
}

- (void)setupView {
    // ===== 精致的3D电池图标 =====
    
    // 电池主体外壳 - 带阴影和高级圆角
    self.batteryBody = [[UIView alloc] init];
    self.batteryBody.translatesAutoresizingMaskIntoConstraints = NO;
    self.batteryBody.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:0.25 alpha:1.0];
        }
        return [UIColor colorWithWhite:0.85 alpha:1.0];
    }];
    self.batteryBody.layer.cornerRadius = 10;
    self.batteryBody.layer.cornerCurve = kCACornerCurveContinuous;
    // 添加精致阴影
    self.batteryBody.layer.shadowColor = [UIColor blackColor].CGColor;
    self.batteryBody.layer.shadowOffset = CGSizeMake(0, 2);
    self.batteryBody.layer.shadowRadius = 4;
    self.batteryBody.layer.shadowOpacity = 0.15;
    [self addSubview:self.batteryBody];
    
    // 电池内部区域
    self.batteryInner = [[UIView alloc] init];
    self.batteryInner.translatesAutoresizingMaskIntoConstraints = NO;
    self.batteryInner.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:0.12 alpha:1.0];
        }
        return [UIColor colorWithWhite:0.95 alpha:1.0];
    }];
    self.batteryInner.layer.cornerRadius = 7;
    self.batteryInner.layer.cornerCurve = kCACornerCurveContinuous;
    self.batteryInner.clipsToBounds = YES;
    [self.batteryBody addSubview:self.batteryInner];
    
    // 电池头 - 更精致的圆角
    self.batteryTip = [[UIView alloc] init];
    self.batteryTip.translatesAutoresizingMaskIntoConstraints = NO;
    self.batteryTip.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:0.35 alpha:1.0];
        }
        return [UIColor colorWithWhite:0.75 alpha:1.0];
    }];
    self.batteryTip.layer.cornerRadius = 2.5;
    self.batteryTip.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    [self addSubview:self.batteryTip];
    
    // 填充视图 - 带渐变
    self.fillView = [[UIView alloc] init];
    self.fillView.translatesAutoresizingMaskIntoConstraints = NO;
    self.fillView.layer.cornerRadius = 5;
    self.fillView.layer.cornerCurve = kCACornerCurveContinuous;
    self.fillView.clipsToBounds = YES;
    [self.batteryInner addSubview:self.fillView];
    
    // 渐变层
    self.fillGradient = [CAGradientLayer layer];
    self.fillGradient.colors = @[(id)[UIColor systemGreenColor].CGColor, (id)[[UIColor systemGreenColor] colorWithAlphaComponent:0.7].CGColor];
    self.fillGradient.startPoint = CGPointMake(0, 0);
    self.fillGradient.endPoint = CGPointMake(0, 1);
    [self.fillView.layer addSublayer:self.fillGradient];
    
    // 光泽效果
    self.glossView = [[UIView alloc] init];
    self.glossView.translatesAutoresizingMaskIntoConstraints = NO;
    self.glossView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    self.glossView.layer.cornerRadius = 3;
    [self.fillView addSubview:self.glossView];
    
    // 下限标记线 - 更精致
    self.lowMarker = [[UIView alloc] init];
    self.lowMarker.backgroundColor = [UIColor systemBlueColor];
    self.lowMarker.layer.cornerRadius = 1.5;
    self.lowMarker.layer.shadowColor = [UIColor systemBlueColor].CGColor;
    self.lowMarker.layer.shadowOffset = CGSizeZero;
    self.lowMarker.layer.shadowRadius = 2;
    self.lowMarker.layer.shadowOpacity = 0.5;
    [self.batteryInner addSubview:self.lowMarker];
    
    // 上限标记线 - 更精致
    self.highMarker = [[UIView alloc] init];
    self.highMarker.backgroundColor = [UIColor systemGreenColor];
    self.highMarker.layer.cornerRadius = 1.5;
    self.highMarker.layer.shadowColor = [UIColor systemGreenColor].CGColor;
    self.highMarker.layer.shadowOffset = CGSizeZero;
    self.highMarker.layer.shadowRadius = 2;
    self.highMarker.layer.shadowOpacity = 0.5;
    [self.batteryInner addSubview:self.highMarker];
    
    // 百分比标签
    self.percentLabel = [[UILabel alloc] init];
    self.percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:42 weight:UIFontWeightBold];
    self.percentLabel.textColor = [UIColor labelColor];
    self.percentLabel.text = @"75%";
    [self addSubview:self.percentLabel];
    
    // 充电图标
    self.chargingIcon = [[UIImageView alloc] init];
    self.chargingIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.chargingIcon.contentMode = UIViewContentModeScaleAspectFit;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    self.chargingIcon.image = [UIImage systemImageNamed:@"bolt.fill" withConfiguration:config];
    self.chargingIcon.tintColor = [UIColor systemGreenColor];
    self.chargingIcon.hidden = YES;
    [self addSubview:self.chargingIcon];
    
    // 状态标签
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:15];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"使用电池";
    [self addSubview:self.statusLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        // 百分比在左边
        [self.percentLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.percentLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-10],
        
        // 充电图标
        [self.chargingIcon.leadingAnchor constraintEqualToAnchor:self.percentLabel.trailingAnchor constant:4],
        [self.chargingIcon.centerYAnchor constraintEqualToAnchor:self.percentLabel.centerYAnchor],
        
        // 状态标签
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.percentLabel.leadingAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.percentLabel.bottomAnchor constant:2],
        
        // 电池主体
        [self.batteryBody.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [self.batteryBody.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.batteryBody.widthAnchor constraintEqualToConstant:110],
        [self.batteryBody.heightAnchor constraintEqualToConstant:46],
        
        // 电池内部
        [self.batteryInner.leadingAnchor constraintEqualToAnchor:self.batteryBody.leadingAnchor constant:4],
        [self.batteryInner.trailingAnchor constraintEqualToAnchor:self.batteryBody.trailingAnchor constant:-4],
        [self.batteryInner.topAnchor constraintEqualToAnchor:self.batteryBody.topAnchor constant:4],
        [self.batteryInner.bottomAnchor constraintEqualToAnchor:self.batteryBody.bottomAnchor constant:-4],
        
        // 电池头
        [self.batteryTip.leadingAnchor constraintEqualToAnchor:self.batteryBody.trailingAnchor constant:-1],
        [self.batteryTip.centerYAnchor constraintEqualToAnchor:self.batteryBody.centerYAnchor],
        [self.batteryTip.widthAnchor constraintEqualToConstant:5],
        [self.batteryTip.heightAnchor constraintEqualToConstant:18],
        
        // 填充
        [self.fillView.leadingAnchor constraintEqualToAnchor:self.batteryInner.leadingAnchor constant:3],
        [self.fillView.topAnchor constraintEqualToAnchor:self.batteryInner.topAnchor constant:3],
        [self.fillView.bottomAnchor constraintEqualToAnchor:self.batteryInner.bottomAnchor constant:-3],
        
        // 光泽
        [self.glossView.leadingAnchor constraintEqualToAnchor:self.fillView.leadingAnchor constant:2],
        [self.glossView.trailingAnchor constraintEqualToAnchor:self.fillView.trailingAnchor constant:-2],
        [self.glossView.topAnchor constraintEqualToAnchor:self.fillView.topAnchor constant:2],
        [self.glossView.heightAnchor constraintEqualToConstant:8],
    ]];
    
    [self updateFillWidth];
    [self updateMarkersAnimated:NO];
}

// 电池尺寸常量
#define BATTERY_BODY_WIDTH 110.0
#define BATTERY_BODY_HEIGHT 46.0
#define BATTERY_BODY_PADDING 4.0
#define BATTERY_FILL_PADDING 3.0

// 计算可用宽度: batteryInner宽度 - fillView左右边距
// batteryInner宽度 = BATTERY_BODY_WIDTH - 2*BATTERY_BODY_PADDING = 110 - 8 = 102
// 可用宽度 = 102 - 2*BATTERY_FILL_PADDING = 102 - 6 = 96
#define BATTERY_USABLE_WIDTH (BATTERY_BODY_WIDTH - 2*BATTERY_BODY_PADDING - 2*BATTERY_FILL_PADDING)
#define BATTERY_USABLE_HEIGHT (BATTERY_BODY_HEIGHT - 2*BATTERY_BODY_PADDING - 2*BATTERY_FILL_PADDING)

- (void)updateFillWidth {
    CGFloat fillWidth = BATTERY_USABLE_WIDTH * (self.percentage / 100.0);
    
    for (NSLayoutConstraint *c in self.fillView.constraints) {
        if (c.firstAttribute == NSLayoutAttributeWidth) {
            [self.fillView removeConstraint:c];
        }
    }
    [self.fillView.widthAnchor constraintEqualToConstant:MAX(fillWidth, 4)].active = YES;
    
    // 更新颜色和渐变
    UIColor *color;
    UIColor *colorLight;
    if (self.percentage <= 20) {
        color = [UIColor systemRedColor];
        colorLight = [[UIColor systemRedColor] colorWithAlphaComponent:0.6];
    } else if (self.percentage <= 50) {
        color = [UIColor systemOrangeColor];
        colorLight = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.6];
    } else {
        color = [UIColor systemGreenColor];
        colorLight = [[UIColor systemGreenColor] colorWithAlphaComponent:0.6];
    }
    
    // 更新渐变
    self.fillGradient.colors = @[(id)color.CGColor, (id)colorLight.CGColor];
    self.chargingIcon.tintColor = color;
    
    [self setNeedsLayout];
}

- (void)setPercentage:(CGFloat)percentage {
    _percentage = percentage;
    self.percentLabel.text = [NSString stringWithFormat:@"%.0f%%", percentage];
    [self updateFillWidth];
}

- (void)setIsCharging:(BOOL)isCharging {
    _isCharging = isCharging;
    self.chargingIcon.hidden = !isCharging;
}

- (void)setChargeBelow:(NSInteger)chargeBelow {
    _chargeBelow = chargeBelow;
    [self updateMarkersAnimated:YES];
}

- (void)setChargeAbove:(NSInteger)chargeAbove {
    _chargeAbove = chargeAbove;
    [self updateMarkersAnimated:YES];
}

- (void)updateMarkersAnimated:(BOOL)animated {
    // 标记线在 batteryInner 内，位置应该和 fillView 对齐
    // 标记线起始位置 = BATTERY_FILL_PADDING (fillView的左边距)
    CGFloat lowX = BATTERY_FILL_PADDING + BATTERY_USABLE_WIDTH * (self.chargeBelow / 100.0);
    CGFloat highX = BATTERY_FILL_PADDING + BATTERY_USABLE_WIDTH * (self.chargeAbove / 100.0);
    
    void (^updateBlock)(void) = ^{
        // 标记线高度和 fillView 一致
        self.lowMarker.frame = CGRectMake(lowX - 1.5, BATTERY_FILL_PADDING, 3, BATTERY_USABLE_HEIGHT);
        self.lowMarker.alpha = self.showLowMarker ? 1.0 : 0.0;
        self.highMarker.frame = CGRectMake(highX - 1.5, BATTERY_FILL_PADDING, 3, BATTERY_USABLE_HEIGHT);
    };
    
    if (animated) {
        [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:updateBlock completion:nil];
    } else {
        updateBlock();
    }
}

- (void)setShowLowMarker:(BOOL)showLowMarker {
    _showLowMarker = showLowMarker;
    [UIView animateWithDuration:0.25 animations:^{
        self.lowMarker.alpha = showLowMarker ? 1.0 : 0.0;
    }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 更新渐变层frame
    self.fillGradient.frame = self.fillView.bounds;
    [self updateMarkersAnimated:NO];
}

@end

#pragma mark - 毛玻璃卡片

@interface CLGlassCard : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, weak) UIViewController *viewController;
@end

@implementation CLGlassCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.layer.cornerRadius = 12;
    self.layer.masksToBounds = YES;
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

- (void)addRowWithIcon:(NSString *)iconName title:(NSString *)title value:(NSString *)value color:(UIColor *)color {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = color ?: [UIColor systemBlueColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    valueLabel.textColor = [UIColor secondaryLabelColor];
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.tag = [title hash];
    [row addSubview:valueLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:22],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8]
    ]];
    
    [self.contentStack addArrangedSubview:row];
}

- (void)addSwitchRowWithIcon:(NSString *)iconName title:(NSString *)title isOn:(BOOL)isOn color:(UIColor *)color tag:(NSInteger)tag onChange:(void(^)(BOOL))onChange {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = color ?: [UIColor systemBlueColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    UISwitch *switchView = [[UISwitch alloc] init];
    switchView.translatesAutoresizingMaskIntoConstraints = NO;
    switchView.on = isOn;
    switchView.tag = tag;
    switchView.onTintColor = color;
    switchView.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [row addSubview:switchView];
    
    [switchView addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(switchView, "onChange", onChange, OBJC_ASSOCIATION_COPY_NONATOMIC);
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:22],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [switchView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [switchView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    
    [self.contentStack addArrangedSubview:row];
}

- (void)switchChanged:(UISwitch *)sender {
    void(^onChange)(BOOL) = objc_getAssociatedObject(sender, "onChange");
    if (onChange) {
        onChange(sender.on);
    }
}

- (UIView *)addSliderRowWithTitle:(NSString *)title value:(NSInteger)value minValue:(NSInteger)minValue maxValue:(NSInteger)maxValue color:(UIColor *)color tag:(NSInteger)tag onChange:(void(^)(NSInteger))onChange onLiveChange:(void(^)(NSInteger))onLiveChange {
    return [self addSliderRowWithTitle:title value:value minValue:minValue maxValue:maxValue color:color tag:tag suffix:@"%" onChange:onChange onLiveChange:onLiveChange];
}

- (UIView *)addSliderRowWithTitle:(NSString *)title value:(NSInteger)value minValue:(NSInteger)minValue maxValue:(NSInteger)maxValue color:(UIColor *)color tag:(NSInteger)tag suffix:(NSString *)suffix onChange:(void(^)(NSInteger))onChange onLiveChange:(void(^)(NSInteger))onLiveChange {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 标题
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    // 数值标签（可点击输入）
    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)value, suffix];
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    valueLabel.textColor = color;
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.tag = tag + 10000;
    valueLabel.userInteractionEnabled = YES;
    [row addSubview:valueLabel];
    
    // 点击数值弹出输入框
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(valueLabelTapped:)];
    [valueLabel addGestureRecognizer:tap];
    
    // 减号按钮
    UIButton *minusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    minusBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [minusBtn setTitle:@"−" forState:UIControlStateNormal];
    minusBtn.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    minusBtn.tintColor = color;
    minusBtn.backgroundColor = [color colorWithAlphaComponent:0.15];
    minusBtn.layer.cornerRadius = 16;
    minusBtn.tag = tag + 20000;
    [minusBtn addTarget:self action:@selector(minusBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
    // 长按连续减
    UILongPressGestureRecognizer *longPressMinus = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(minusBtnLongPressed:)];
    longPressMinus.minimumPressDuration = 0.3;
    [minusBtn addGestureRecognizer:longPressMinus];
    [row addSubview:minusBtn];
    
    // 滑块
    UISlider *slider = [[UISlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = value;
    slider.tintColor = color;
    slider.tag = tag;
    [row addSubview:slider];
    
    // 加号按钮
    UIButton *plusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    plusBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [plusBtn setTitle:@"+" forState:UIControlStateNormal];
    plusBtn.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    plusBtn.tintColor = color;
    plusBtn.backgroundColor = [color colorWithAlphaComponent:0.15];
    plusBtn.layer.cornerRadius = 16;
    plusBtn.tag = tag + 30000;
    [plusBtn addTarget:self action:@selector(plusBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
    // 长按连续加
    UILongPressGestureRecognizer *longPressPlus = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(plusBtnLongPressed:)];
    longPressPlus.minimumPressDuration = 0.3;
    [plusBtn addGestureRecognizer:longPressPlus];
    [row addSubview:plusBtn];
    
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    
    // 关联对象
    objc_setAssociatedObject(slider, "onChange", onChange, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(slider, "onLiveChange", onLiveChange, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(slider, "valueLabel", valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, "suffix", suffix, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(minusBtn, "slider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(plusBtn, "slider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, "slider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, "title", title, OBJC_ASSOCIATION_COPY_NONATOMIC);
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:75],
        // 标题和数值
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [valueLabel.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        // 减号按钮
        [minusBtn.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [minusBtn.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [minusBtn.widthAnchor constraintEqualToConstant:32],
        [minusBtn.heightAnchor constraintEqualToConstant:32],
        // 滑块
        [slider.leadingAnchor constraintEqualToAnchor:minusBtn.trailingAnchor constant:10],
        [slider.trailingAnchor constraintEqualToAnchor:plusBtn.leadingAnchor constant:-10],
        [slider.centerYAnchor constraintEqualToAnchor:minusBtn.centerYAnchor],
        // 加号按钮
        [plusBtn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [plusBtn.centerYAnchor constraintEqualToAnchor:minusBtn.centerYAnchor],
        [plusBtn.widthAnchor constraintEqualToConstant:32],
        [plusBtn.heightAnchor constraintEqualToConstant:32]
    ]];
    
    [self.contentStack addArrangedSubview:row];
    return row;
}

#pragma mark - 微调按钮事件

- (void)minusBtnTapped:(UIButton *)sender {
    UISlider *slider = objc_getAssociatedObject(sender, "slider");
    [self adjustSlider:slider byAmount:-1];
}

- (void)plusBtnTapped:(UIButton *)sender {
    UISlider *slider = objc_getAssociatedObject(sender, "slider");
    [self adjustSlider:slider byAmount:1];
}

- (void)minusBtnLongPressed:(UILongPressGestureRecognizer *)gesture {
    UIButton *btn = (UIButton *)gesture.view;
    UISlider *slider = objc_getAssociatedObject(btn, "slider");
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self startContinuousAdjust:slider amount:-1 button:btn];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self stopContinuousAdjust];
    }
}

- (void)plusBtnLongPressed:(UILongPressGestureRecognizer *)gesture {
    UIButton *btn = (UIButton *)gesture.view;
    UISlider *slider = objc_getAssociatedObject(btn, "slider");
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self startContinuousAdjust:slider amount:1 button:btn];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self stopContinuousAdjust];
    }
}

- (void)startContinuousAdjust:(UISlider *)slider amount:(NSInteger)amount button:(UIButton *)button {
    // 存储当前调节的slider和方向
    objc_setAssociatedObject(self, "adjustingSlider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, "adjustAmount", @(amount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // 开始定时器，每 0.1 秒调节一次
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(continuousAdjustTick) userInfo:nil repeats:YES];
    objc_setAssociatedObject(self, "adjustTimer", timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)continuousAdjustTick {
    UISlider *slider = objc_getAssociatedObject(self, "adjustingSlider");
    NSNumber *amount = objc_getAssociatedObject(self, "adjustAmount");
    if (slider && amount) {
        [self adjustSlider:slider byAmount:amount.integerValue];
    }
}

- (void)stopContinuousAdjust {
    NSTimer *timer = objc_getAssociatedObject(self, "adjustTimer");
    [timer invalidate];
    objc_setAssociatedObject(self, "adjustTimer", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, "adjustingSlider", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // 触发最终的 onChange
    UISlider *slider = objc_getAssociatedObject(self, "adjustingSlider");
    if (slider) {
        [self sliderEnded:slider];
    }
}

- (void)adjustSlider:(UISlider *)slider byAmount:(NSInteger)amount {
    NSInteger newValue = (NSInteger)roundf(slider.value) + amount;
    newValue = MAX(slider.minimumValue, MIN(slider.maximumValue, newValue));
    
    [UIView animateWithDuration:0.1 animations:^{
        slider.value = newValue;
    }];
    
    // 更新标签（使用正确的后缀）
    UILabel *valueLabel = objc_getAssociatedObject(slider, "valueLabel");
    NSString *suffix = objc_getAssociatedObject(slider, "suffix") ?: @"%";
    valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)newValue, suffix];
    
    // 触发实时回调
    void(^onLiveChange)(NSInteger) = objc_getAssociatedObject(slider, "onLiveChange");
    if (onLiveChange) {
        onLiveChange(newValue);
    }
    
    // 触发最终回调
    void(^onChange)(NSInteger) = objc_getAssociatedObject(slider, "onChange");
    if (onChange) {
        onChange(newValue);
    }
    
    // 触觉反馈
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
}

#pragma mark - 点击数值输入

- (void)valueLabelTapped:(UITapGestureRecognizer *)gesture {
    UILabel *valueLabel = (UILabel *)gesture.view;
    UISlider *slider = objc_getAssociatedObject(valueLabel, "slider");
    NSString *title = objc_getAssociatedObject(valueLabel, "title");
    NSString *suffix = objc_getAssociatedObject(slider, "suffix") ?: @"%";
    
    NSInteger currentValue = (NSInteger)roundf(slider.value);
    NSInteger minValue = (NSInteger)slider.minimumValue;
    NSInteger maxValue = (NSInteger)slider.maximumValue;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:[NSString stringWithFormat:@"请输入 %ld ~ %ld 之间的数值", (long)minValue, (long)maxValue]
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *inputText = alert.textFields.firstObject.text;
        NSInteger inputValue = [inputText integerValue];
        inputValue = MAX(minValue, MIN(maxValue, inputValue));
        
        slider.value = inputValue;
        valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)inputValue, suffix];
        
        void(^onLiveChange)(NSInteger) = objc_getAssociatedObject(slider, "onLiveChange");
        if (onLiveChange) onLiveChange(inputValue);
        void(^onChange)(NSInteger) = objc_getAssociatedObject(slider, "onChange");
        if (onChange) onChange(inputValue);
    }]];
    
    [self.viewController presentViewController:alert animated:YES completion:nil];
}

- (void)sliderChanged:(UISlider *)sender {
    NSInteger value = (NSInteger)roundf(sender.value);
    UILabel *valueLabel = objc_getAssociatedObject(sender, "valueLabel");
    NSString *suffix = objc_getAssociatedObject(sender, "suffix") ?: @"%";
    valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)value, suffix];
    
    // 实时更新回调（用于电池图标实时显示）
    void(^onLiveChange)(NSInteger) = objc_getAssociatedObject(sender, "onLiveChange");
    if (onLiveChange) {
        onLiveChange(value);
    }
}

- (void)sliderEnded:(UISlider *)sender {
    NSInteger value = (NSInteger)roundf(sender.value);
    sender.value = value;
    void(^onChange)(NSInteger) = objc_getAssociatedObject(sender, "onChange");
    if (onChange) {
        onChange(value);
    }
}

- (void)addNavigationRowWithIcon:(NSString *)iconName title:(NSString *)title value:(NSString *)value color:(UIColor *)color target:(id)target action:(SEL)action {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.userInteractionEnabled = YES;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = color ?: [UIColor systemBlueColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont systemFontOfSize:15];
    valueLabel.textColor = [UIColor secondaryLabelColor];
    valueLabel.tag = [title hash];
    [row addSubview:valueLabel];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.image = [UIImage systemImageNamed:@"chevron.right"];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [row addSubview:chevron];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:action];
    [row addGestureRecognizer:tap];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:22],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:10],
        [valueLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-6],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    
    [self.contentStack addArrangedSubview:row];
}

- (UIView *)addSeparator {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor separatorColor];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:separator];
    
    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintEqualToConstant:0.5],
        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:50],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
        [separator.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
    ]];
    
    [self.contentStack addArrangedSubview:container];
    return container;
}

@end

#pragma mark - 主控制器

@interface CLSettingsViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) CLBatteryStatusView *batteryStatus;
@property (nonatomic, strong) CLGlassCard *controlCard;
@property (nonatomic, strong) CLGlassCard *limitCard;
@property (nonatomic, strong) CLGlassCard *tempCard;       // 温度控制卡片
@property (nonatomic, strong) CLGlassCard *adapterCard;    // 适配器信息卡片
@property (nonatomic, strong) CLGlassCard *infoCard;
@property (nonatomic, strong) CLGlassCard *settingsCard;   // 系统设置卡片
@property (nonatomic, strong) CLGlassCard *moreCard;
@property (nonatomic, assign) NSInteger chargeBelow;
@property (nonatomic, assign) NSInteger chargeAbove;
@property (nonatomic, assign) NSInteger currentChargeMode; // 0=插电即充, 1=边缘触发
@property (nonatomic, strong) UIView *chargeBelowRow;
@property (nonatomic, strong) UIView *chargeAboveRow;      // 停止充电行
@property (nonatomic, strong) UIView *chargeBelowSeparator;
@property (nonatomic, strong) UIView *tempBelowRow;        // 温度下限行
@property (nonatomic, strong) UIView *tempAboveRow;        // 温度上限行
@property (nonatomic, strong) UIView *tempSeparator1;
@property (nonatomic, strong) UIView *tempSeparator2;
@property (nonatomic, assign) NSInteger chargeTempBelow;
@property (nonatomic, assign) NSInteger chargeTempAbove;
@end

@implementation CLSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.chargeBelow = 20;
    self.chargeAbove = 80;
    self.chargeTempBelow = 35;  // 降温恢复温度
    self.chargeTempAbove = 40;  // 高温停充温度
    
    [self setupUI];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(batteryInfoDidUpdate)
                                                 name:CLBatteryInfoDidUpdateNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(configDidUpdate)
                                                 name:CLConfigDidUpdateNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = YES;
    [[CLBatteryManager shared] startAutoRefresh];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBarHidden = NO;
    [[CLBatteryManager shared] stopAutoRefresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];
    
    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 20;
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.mainStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.mainStack.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:60],
        [self.mainStack.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:16],
        [self.mainStack.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-16],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-40],
        [self.mainStack.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-32]
    ]];
    
    // 标题
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"ChargeLimiter";
    titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    [self.mainStack addArrangedSubview:titleLabel];
    
    // 电池状态
    self.batteryStatus = [[CLBatteryStatusView alloc] init];
    self.batteryStatus.translatesAutoresizingMaskIntoConstraints = NO;
    [self.batteryStatus.heightAnchor constraintEqualToConstant:80].active = YES;
    [self.mainStack addArrangedSubview:self.batteryStatus];
    
    // 控制卡片
    [self setupControlCard];
    
    // 充电限制卡片
    [self setupLimitCard];
    
    // 温度控制卡片
    [self setupTempCard];
    
    // 适配器信息卡片
    [self setupAdapterCard];
    
    // 电池信息卡片
    [self setupInfoCard];
    
    // 系统设置卡片
    [self setupSettingsCard];
    
    // 更多功能卡片
    [self setupMoreCard];
    
    // 演示模式标签
    [self setupMockBanner];
}

- (void)setupControlCard {
    self.controlCard = [[CLGlassCard alloc] init];
    
    __weak typeof(self) weakSelf = self;
    [self.controlCard addSwitchRowWithIcon:@"bolt.fill" title:@"启用" isOn:YES color:[UIColor systemGreenColor] tag:100 onChange:^(BOOL isOn) {
        [[CLAPIClient shared] setConfigWithKey:@"enable" value:@(isOn) completion:nil];
        [CLBatteryManager shared].enabled = isOn;
    }];
    [self.controlCard addSeparator];
    [self.controlCard addNavigationRowWithIcon:@"gearshape" title:@"充电模式" value:@"插电即充" color:[UIColor systemBlueColor] target:self action:@selector(chargeModesTapped)];
    
    [self.mainStack addArrangedSubview:self.controlCard];
}

- (void)setupLimitCard {
    self.limitCard = [[CLGlassCard alloc] init];
    self.limitCard.viewController = self;
    
    __weak typeof(self) weakSelf = self;
    
    // 开始充电滑块 - 保存引用以便隐藏
    self.chargeBelowRow = [self.limitCard addSliderRowWithTitle:@"开始充电 (电量 ≤)" value:self.chargeBelow minValue:10 maxValue:95 color:[UIColor systemBlueColor] tag:200 onChange:^(NSInteger value) {
        // 最终确定时的回调
        if (value >= weakSelf.chargeAbove) {
            value = weakSelf.chargeAbove - 5;
        }
        weakSelf.chargeBelow = value;
        weakSelf.batteryStatus.chargeBelow = value;
        [CLBatteryManager shared].chargeBelow = value;
        [[CLAPIClient shared] setConfigWithKey:@"charge_below" value:@(value) completion:nil];
    } onLiveChange:^(NSInteger value) {
        // 实时更新电池图标上的标记线
        NSInteger adjustedValue = value;
        if (adjustedValue >= weakSelf.chargeAbove) {
            adjustedValue = weakSelf.chargeAbove - 5;
        }
        weakSelf.batteryStatus.chargeBelow = adjustedValue;
    }];
    
    // 保存分隔线引用
    self.chargeBelowSeparator = [self.limitCard addSeparator];
    
    // 停止充电滑块 - 保存引用以便更新
    self.chargeAboveRow = [self.limitCard addSliderRowWithTitle:@"停止充电 (电量 ≥)" value:self.chargeAbove minValue:15 maxValue:100 color:[UIColor systemGreenColor] tag:201 onChange:^(NSInteger value) {
        // 最终确定时的回调
        if (value <= weakSelf.chargeBelow) {
            value = weakSelf.chargeBelow + 5;
        }
        weakSelf.chargeAbove = value;
        weakSelf.batteryStatus.chargeAbove = value;
        [CLBatteryManager shared].chargeAbove = value;
        [[CLAPIClient shared] setConfigWithKey:@"charge_above" value:@(value) completion:nil];
    } onLiveChange:^(NSInteger value) {
        // 实时更新电池图标上的标记线
        NSInteger adjustedValue = value;
        if (adjustedValue <= weakSelf.chargeBelow) {
            adjustedValue = weakSelf.chargeBelow + 5;
        }
        weakSelf.batteryStatus.chargeAbove = adjustedValue;
    }];
    
    [self.mainStack addArrangedSubview:self.limitCard];
    
    // 默认模式是插电即充，隐藏开始充电选项
    self.currentChargeMode = 0;
    self.chargeBelowRow.hidden = YES;
    self.chargeBelowRow.alpha = 0;
}

- (void)setupTempCard {
    self.tempCard = [[CLGlassCard alloc] init];
    self.tempCard.viewController = self;
    
    __weak typeof(self) weakSelf = self;
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 温度控制开关
    [self.tempCard addSwitchRowWithIcon:@"thermometer.sun" title:@"温度控制" isOn:manager.tempControlEnabled color:[UIColor systemOrangeColor] tag:250 onChange:^(BOOL isOn) {
        [[CLAPIClient shared] setConfigWithKey:@"enable_temp" value:@(isOn) completion:nil];
        [CLBatteryManager shared].tempControlEnabled = isOn;
        [weakSelf updateTempControlVisibility:isOn];
    }];
    
    self.tempSeparator1 = [self.tempCard addSeparator];
    
    // 高温停充 - 温度 ≥ X°C 时停止充电
    self.tempAboveRow = [self.tempCard addSliderRowWithTitle:@"高温停充 (温度 ≥)" value:self.chargeTempAbove minValue:30 maxValue:50 color:[UIColor systemRedColor] tag:252 suffix:@"°C" onChange:^(NSInteger value) {
        // 确保停充温度 > 恢复温度
        if (value <= weakSelf.chargeTempBelow) {
            value = weakSelf.chargeTempBelow + 1;
            [weakSelf updateSliderValue:weakSelf.tempAboveRow value:value];
            [weakSelf updateSliderLabel:weakSelf.tempAboveRow value:value suffix:@"°C"];
        }
        weakSelf.chargeTempAbove = value;
        [CLBatteryManager shared].chargeTempAbove = value;
        [[CLAPIClient shared] setConfigWithKey:@"charge_temp_above" value:@(value) completion:nil];
    } onLiveChange:nil];
    
    self.tempSeparator2 = [self.tempCard addSeparator];
    
    // 降温恢复 - 温度 ≤ X°C 时恢复充电
    self.tempBelowRow = [self.tempCard addSliderRowWithTitle:@"降温恢复 (温度 ≤)" value:self.chargeTempBelow minValue:25 maxValue:45 color:[UIColor systemBlueColor] tag:251 suffix:@"°C" onChange:^(NSInteger value) {
        // 确保恢复温度 < 停充温度
        if (value >= weakSelf.chargeTempAbove) {
            value = weakSelf.chargeTempAbove - 1;
            [weakSelf updateSliderValue:weakSelf.tempBelowRow value:value];
            [weakSelf updateSliderLabel:weakSelf.tempBelowRow value:value suffix:@"°C"];
        }
        weakSelf.chargeTempBelow = value;
        [CLBatteryManager shared].chargeTempBelow = value;
        [[CLAPIClient shared] setConfigWithKey:@"charge_temp_below" value:@(value) completion:nil];
    } onLiveChange:nil];
    
    [self.mainStack addArrangedSubview:self.tempCard];
    
    // 默认隐藏温度滑块（如果温度控制未开启）
    [self updateTempControlVisibility:manager.tempControlEnabled];
}

- (void)updateSliderLabel:(UIView *)row value:(NSInteger)value suffix:(NSString *)suffix {
    for (UIView *subview in row.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview.tag >= 10000) {
            ((UILabel *)subview).text = [NSString stringWithFormat:@"%ld%@", (long)value, suffix];
            break;
        }
    }
}

- (void)updateTempControlVisibility:(BOOL)visible {
    [UIView animateWithDuration:0.3 animations:^{
        self.tempBelowRow.hidden = !visible;
        self.tempBelowRow.alpha = visible ? 1 : 0;
        self.tempAboveRow.hidden = !visible;
        self.tempAboveRow.alpha = visible ? 1 : 0;
        self.tempSeparator1.hidden = !visible;
        self.tempSeparator1.alpha = visible ? 1 : 0;
        self.tempSeparator2.hidden = !visible;
        self.tempSeparator2.alpha = visible ? 1 : 0;
    }];
}

- (void)setupAdapterCard {
    self.adapterCard = [[CLGlassCard alloc] init];
    
    [self.adapterCard addRowWithIcon:@"powerplug.fill" title:@"适配器" value:@"未连接" color:[UIColor systemGreenColor]];
    [self.adapterCard addSeparator];
    [self.adapterCard addRowWithIcon:@"bolt.fill" title:@"输出功率" value:@"-- W" color:[UIColor systemYellowColor]];
    [self.adapterCard addSeparator];
    [self.adapterCard addRowWithIcon:@"arrow.down.circle" title:@"输入电压" value:@"-- V" color:[UIColor systemBlueColor]];
    
    [self.mainStack addArrangedSubview:self.adapterCard];
    self.chargeBelowSeparator.hidden = YES;
    self.chargeBelowSeparator.alpha = 0;
    self.batteryStatus.showLowMarker = NO;
}

- (void)setupInfoCard {
    self.infoCard = [[CLGlassCard alloc] init];
    
    [self.infoCard addRowWithIcon:@"heart.fill" title:@"电池健康" value:@"100%" color:[UIColor systemPinkColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"thermometer" title:@"温度" value:@"25.0°C" color:[UIColor systemOrangeColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"bolt.horizontal" title:@"电流" value:@"0 mA" color:[UIColor systemYellowColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"bolt.batteryblock" title:@"电压" value:@"0.00 V" color:[UIColor systemPurpleColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"arrow.triangle.2.circlepath" title:@"循环" value:@"0 次" color:[UIColor systemTealColor]];
    
    [self.mainStack addArrangedSubview:self.infoCard];
}

- (void)setupSettingsCard {
    self.settingsCard = [[CLGlassCard alloc] init];
    
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 刷新频率
    NSString *freqValue = [self frequencyString:manager.updateFrequency];
    [self.settingsCard addNavigationRowWithIcon:@"clock.arrow.circlepath" title:@"刷新频率" value:freqValue color:[UIColor systemTealColor] target:self action:@selector(frequencyTapped)];
    [self.settingsCard addSeparator];
    
    // 语言
    [self.settingsCard addNavigationRowWithIcon:@"globe" title:@"语言" value:@"中文" color:[UIColor systemBlueColor] target:self action:@selector(languageTapped)];
    [self.settingsCard addSeparator];
    
    // 深色模式
    [self.settingsCard addNavigationRowWithIcon:@"moon.fill" title:@"深色模式" value:@"跟随系统" color:[UIColor systemGrayColor] target:self action:@selector(darkModeTapped)];
    
    [self.mainStack addArrangedSubview:self.settingsCard];
}

- (NSString *)frequencyString:(NSInteger)freq {
    if (freq <= 1) return @"1 秒";
    if (freq <= 20) return @"20 秒";
    if (freq <= 60) return @"1 分钟";
    return @"10 分钟";
}

- (void)setupMoreCard {
    self.moreCard = [[CLGlassCard alloc] init];
    
    [self.moreCard addNavigationRowWithIcon:@"slider.horizontal.3" title:@"高级设置" value:@"" color:[UIColor systemGrayColor] target:self action:@selector(advancedTapped)];
    [self.moreCard addSeparator];
    [self.moreCard addNavigationRowWithIcon:@"bolt.car" title:@"加速充电" value:@"" color:[UIColor systemYellowColor] target:self action:@selector(accChargeTapped)];
    [self.moreCard addSeparator];
    [self.moreCard addNavigationRowWithIcon:@"questionmark.circle" title:@"帮助" value:@"" color:[UIColor systemBlueColor] target:self action:@selector(helpTapped)];
    
    [self.mainStack addArrangedSubview:self.moreCard];
}

- (void)setupMockBanner {
#if CL_USE_MOCK_DATA
    UILabel *mockLabel = [[UILabel alloc] init];
    mockLabel.text = @"📱 演示模式 - 仅供界面测试";
    mockLabel.font = [UIFont systemFontOfSize:12];
    mockLabel.textColor = [UIColor secondaryLabelColor];
    mockLabel.textAlignment = NSTextAlignmentCenter;
    [self.mainStack addArrangedSubview:mockLabel];
#endif
}

#pragma mark - Navigation Actions

- (void)chargeModesTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"充电模式" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"插电即充" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [CLBatteryManager shared].chargeMode = CLChargeModePlugAndCharge;
        [[CLAPIClient shared] setConfigWithKey:@"mode" value:@"charge_on_plug" completion:nil];
        [self updateCardValue:self.controlCard title:@"充电模式" value:@"插电即充"];
        self.currentChargeMode = 0;
        [self updateChargeBelowVisibility];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"边缘触发" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [CLBatteryManager shared].chargeMode = CLChargeModeEdgeTrigger;
        [[CLAPIClient shared] setConfigWithKey:@"mode" value:@"edge_trigger" completion:nil];
        [self updateCardValue:self.controlCard title:@"充电模式" value:@"边缘触发"];
        self.currentChargeMode = 1;
        [self updateChargeBelowVisibility];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateChargeBelowVisibility {
    // 插电即充模式下隐藏"开始充电"选项，边缘触发显示
    BOOL shouldHide = (self.currentChargeMode == 0);
    
    [UIView animateWithDuration:0.3 animations:^{
        self.chargeBelowRow.hidden = shouldHide;
        self.chargeBelowRow.alpha = shouldHide ? 0 : 1;
        self.chargeBelowSeparator.hidden = shouldHide;
        self.chargeBelowSeparator.alpha = shouldHide ? 0 : 1;
        self.batteryStatus.showLowMarker = !shouldHide;
    }];
}

- (void)advancedTapped {
    Class vcClass = NSClassFromString(@"CLAdvancedSettingsViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)accChargeTapped {
    Class vcClass = NSClassFromString(@"CLAccChargeViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)helpTapped {
    Class vcClass = NSClassFromString(@"CLHelpViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"帮助" message:@"ChargeLimiter 是一款电池充电限制工具。\n\n设置充电上下限来保护电池健康度。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)frequencyTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"刷新频率" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"1 秒" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self setUpdateFrequency:1];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"20 秒" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self setUpdateFrequency:20];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"1 分钟" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self setUpdateFrequency:60];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"10 分钟" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self setUpdateFrequency:600];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setUpdateFrequency:(NSInteger)freq {
    [[CLAPIClient shared] setConfigWithKey:@"update_freq" value:@(freq) completion:nil];
    [CLBatteryManager shared].updateFrequency = freq;
    [self updateCardValue:self.settingsCard title:@"刷新频率" value:[self frequencyString:freq]];
}

- (void)languageTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"语言" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"中文" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[NSUserDefaults standardUserDefaults] setObject:@"zh-Hans" forKey:@"AppLanguage"];
        [self updateCardValue:self.settingsCard title:@"语言" value:@"中文"];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"English" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[NSUserDefaults standardUserDefaults] setObject:@"en" forKey:@"AppLanguage"];
        [self updateCardValue:self.settingsCard title:@"语言" value:@"English"];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)darkModeTapped {
    if (@available(iOS 13.0, *)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"深色模式" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"跟随系统" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setAppearanceMode:0 label:@"跟随系统"];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"深色" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setAppearanceMode:2 label:@"深色"];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"浅色" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setAppearanceMode:1 label:@"浅色"];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"深色模式" message:@"iOS 13+ 才支持深色模式" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)setAppearanceMode:(NSInteger)style label:(NSString *)label {
    UIWindow *window = self.view.window;
    if (@available(iOS 13.0, *)) {
        window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)style;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:@"AppAppearance"];
    [self updateCardValue:self.settingsCard title:@"深色模式" value:label];
}

#pragma mark - Update UI

- (void)batteryInfoDidUpdate {
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 更新电池状态
    self.batteryStatus.percentage = manager.currentCapacity;
    self.batteryStatus.isCharging = manager.isCharging;
    
    // 更新状态文字
    if (manager.isCharging) {
        self.batteryStatus.statusLabel.text = @"正在充电";
    } else if (manager.externalConnected) {
        self.batteryStatus.statusLabel.text = @"已连接电源 · 未充电";
    } else {
        self.batteryStatus.statusLabel.text = @"使用电池";
    }
    
    // 更新信息卡片
    CGFloat health = manager.designCapacity > 0 ? (manager.nominalCapacity * 100.0 / manager.designCapacity) : 100;
    [self updateCardValue:self.infoCard title:@"电池健康" value:[NSString stringWithFormat:@"%.0f%%", health]];
    [self updateCardValue:self.infoCard title:@"温度" value:[NSString stringWithFormat:@"%.1f°C", manager.temperature]];
    [self updateCardValue:self.infoCard title:@"电流" value:[NSString stringWithFormat:@"%ld mA", (long)manager.amperage]];
    [self updateCardValue:self.infoCard title:@"电压" value:[NSString stringWithFormat:@"%.2f V", manager.voltage]];
    [self updateCardValue:self.infoCard title:@"循环" value:[NSString stringWithFormat:@"%ld 次", (long)manager.cycleCount]];
    
    // 更新适配器卡片
    if (manager.externalConnected && manager.adapterName.length > 0) {
        [self updateCardValue:self.adapterCard title:@"适配器" value:manager.adapterName];
        [self updateCardValue:self.adapterCard title:@"输出功率" value:[NSString stringWithFormat:@"%ld W", (long)manager.adapterWatts]];
        [self updateCardValue:self.adapterCard title:@"输入电压" value:[NSString stringWithFormat:@"%.1f V", manager.adapterVoltage]];
    } else if (manager.externalConnected) {
        [self updateCardValue:self.adapterCard title:@"适配器" value:@"已连接"];
        CGFloat watts = (manager.adapterVoltage * manager.adapterCurrent) / 1000.0;
        [self updateCardValue:self.adapterCard title:@"输出功率" value:[NSString stringWithFormat:@"%.1f W", watts]];
        [self updateCardValue:self.adapterCard title:@"输入电压" value:[NSString stringWithFormat:@"%.1f V", manager.adapterVoltage]];
    } else {
        [self updateCardValue:self.adapterCard title:@"适配器" value:@"未连接"];
        [self updateCardValue:self.adapterCard title:@"输出功率" value:@"-- W"];
        [self updateCardValue:self.adapterCard title:@"输入电压" value:@"-- V"];
    }
}

- (void)updateCardValue:(CLGlassCard *)card title:(NSString *)title value:(NSString *)value {
    NSInteger tag = [title hash];
    for (UIView *row in card.contentStack.arrangedSubviews) {
        UILabel *label = [row viewWithTag:tag];
        if ([label isKindOfClass:[UILabel class]]) {
            label.text = value;
            return;
        }
    }
}

- (void)updateSwitchInCard:(CLGlassCard *)card tag:(NSInteger)tag value:(BOOL)value {
    for (UIView *row in card.contentStack.arrangedSubviews) {
        UISwitch *switchControl = [row viewWithTag:tag];
        if ([switchControl isKindOfClass:[UISwitch class]]) {
            [switchControl setOn:value animated:YES];
            return;
        }
    }
}

- (void)configDidUpdate {
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 更新控制卡片的开关和值
    [self updateSwitchInCard:self.controlCard tag:100 value:manager.enabled];
    
    // 更新充电模式显示
    NSString *modeStr = (manager.chargeMode == CLChargeModePlugAndCharge) ? @"插电即充" : @"边缘触发";
    [self updateCardValue:self.controlCard title:@"充电模式" value:modeStr];
    self.currentChargeMode = (manager.chargeMode == CLChargeModePlugAndCharge) ? 0 : 1;
    [self updateChargeBelowVisibility];
    
    // 更新充电阈值
    self.chargeBelow = manager.chargeBelow;
    self.chargeAbove = manager.chargeAbove;
    [self updateSliderValue:self.chargeBelowRow value:manager.chargeBelow];
    [self updateSliderValue:self.chargeAboveRow value:manager.chargeAbove];
    [self updateSliderLabel:self.chargeBelowRow value:manager.chargeBelow suffix:@"%"];
    [self updateSliderLabel:self.chargeAboveRow value:manager.chargeAbove suffix:@"%"];
    self.batteryStatus.chargeBelow = manager.chargeBelow;
    self.batteryStatus.chargeAbove = manager.chargeAbove;
    
    // 更新温度控制卡片
    [self updateSwitchInCard:self.tempCard tag:250 value:manager.tempControlEnabled];
    [self updateTempControlVisibility:manager.tempControlEnabled];
    self.chargeTempBelow = manager.chargeTempBelow;
    self.chargeTempAbove = manager.chargeTempAbove;
    [self updateSliderValue:self.tempBelowRow value:manager.chargeTempBelow];
    [self updateSliderLabel:self.tempBelowRow value:manager.chargeTempBelow suffix:@"°C"];
    [self updateSliderValue:self.tempAboveRow value:manager.chargeTempAbove];
    [self updateSliderLabel:self.tempAboveRow value:manager.chargeTempAbove suffix:@"°C"];
    
    // 更新系统设置卡片
    [self updateCardValue:self.settingsCard title:@"刷新频率" value:[self frequencyString:manager.updateFrequency]];
}

- (void)updateSliderValue:(UIView *)row value:(NSInteger)value {
    for (UIView *subview in row.subviews) {
        if ([subview isKindOfClass:[UISlider class]]) {
            [(UISlider *)subview setValue:value animated:YES];
            return;
        }
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDefault;
}

@end
