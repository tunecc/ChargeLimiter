//
//  CLSettingsViewController.m
//  ChargeLimiter
//
//  紧凑型设置界面 - iOS 风格
//

#import "CLSettingsViewController.h"
#import "../CLBatteryManager.h"
#import "../CLAPIClient.h"
#import "../../CLLocalization.h"
NSString* getAppDocumentsPath_C(void);
NSString* getConfDirPath_C(void);
NSString* getConfPath_C(void);
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

#pragma mark - 毛玻璃卡片

@interface CLGlassCard : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, weak) UIViewController *viewController;
@end

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
    UIColor *iconColor = color ?: [UIColor systemBlueColor];
    iconView.tintColor = iconColor;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = CLSymbolImage(iconName, config);
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
    UIColor *iconColor = color ?: [UIColor systemBlueColor];
    iconView.tintColor = isOn ? iconColor : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    iconView.image = CLSymbolImage(iconName, config);
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
    switchView.onTintColor = iconColor;
    switchView.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [row addSubview:switchView];
    
    [switchView addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(switchView, "onChange", onChange, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(switchView, "iconView", iconView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(switchView, "iconColor", iconColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
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
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    UIImageView *iconView = objc_getAssociatedObject(sender, "iconView");
    UIColor *iconColor = objc_getAssociatedObject(sender, "iconColor");
    if (iconView) {
        iconView.tintColor = sender.on ? (iconColor ?: [UIColor systemBlueColor])
                                       : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    }
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

    if (@available(iOS 10.0, *)) {
        objc_setAssociatedObject(slider, "lastHapticValue", @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
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
                                                                   message:[NSString stringWithFormat:CLL(@"请输入 %ld ~ %ld 之间的数值"), (long)minValue, (long)maxValue]
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

    if (@available(iOS 10.0, *)) {
        NSNumber *lastValue = objc_getAssociatedObject(sender, "lastHapticValue");
        if (!lastValue || lastValue.integerValue != value) {
            NSInteger style = [[NSUserDefaults standardUserDefaults] integerForKey:@"SliderHapticStyle"];
            if (style < 0 || style > 3) {
                style = 2;
            }
            if (style != 0) {
                UIImpactFeedbackStyle impactStyle = UIImpactFeedbackStyleMedium;
                if (style == 1) impactStyle = UIImpactFeedbackStyleLight;
                if (style == 3) impactStyle = UIImpactFeedbackStyleHeavy;
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:impactStyle];
                [feedback impactOccurred];
                [feedback prepare];
            }
            objc_setAssociatedObject(sender, "lastHapticValue", @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    
    // 实时更新回调（用于电池图标实时显示）
    void(^onLiveChange)(NSInteger) = objc_getAssociatedObject(sender, "onLiveChange");
    if (onLiveChange) {
        onLiveChange(value);
    }
}

- (void)sliderEnded:(UISlider *)sender {
    NSInteger value = (NSInteger)roundf(sender.value);
    sender.value = value;
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
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
    iconView.image = CLSymbolImage(iconName, config);
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
    chevron.image = CLSymbolImage(@"chevron.right", nil);
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

#pragma mark - 历史统计页面

typedef NS_ENUM(NSInteger, CLHistoryMode) {
    CLHistoryModeShort = 0,
    CLHistoryModeLong = 1,
};

@interface CLHistoryChartView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, assign) CLHistoryMode mode;
@property (nonatomic, strong) NSArray<NSDictionary *> *data;
@property (nonatomic, assign) BOOL showAmperage;
@property (nonatomic, assign) BOOL showVoltage;
- (void)updateWithData:(NSArray<NSDictionary *> *)data mode:(CLHistoryMode)mode showAmperage:(BOOL)showAmperage showVoltage:(BOOL)showVoltage;
@end

@interface CLHistoryChartView ()
@property (nonatomic, strong) UIView *tooltipView;
@property (nonatomic, strong) UILabel *tooltipLabel;
@property (nonatomic, assign) NSInteger highlightIndex;
@end

@implementation CLHistoryChartView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.highlightIndex = NSNotFound;
        [self setupTooltip];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;
        [self addGestureRecognizer:pan];
        
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        press.minimumPressDuration = 0.2;
        press.delegate = self;
        [self addGestureRecognizer:press];
    }
    return self;
}

- (void)updateWithData:(NSArray<NSDictionary *> *)data mode:(CLHistoryMode)mode showAmperage:(BOOL)showAmperage showVoltage:(BOOL)showVoltage {
    self.data = data ?: @[];
    self.mode = mode;
    self.showAmperage = showAmperage;
    self.showVoltage = showVoltage;
    [self hideTooltip];
    [self setNeedsDisplay];
}

static CGFloat clamp(CGFloat v, CGFloat minv, CGFloat maxv) {
    if (v < minv) return minv;
    if (v > maxv) return maxv;
    return v;
}

- (CGRect)chartRectForBounds:(CGRect)bounds {
    CGFloat paddingLeft = 28;
    CGFloat paddingRight = 12;
    CGFloat paddingTop = 10;
    CGFloat paddingBottom = 34;
    return CGRectMake(paddingLeft, paddingTop, bounds.size.width - paddingLeft - paddingRight, bounds.size.height - paddingTop - paddingBottom);
}

- (void)setupTooltip {
    UIView *bubble = [[UIView alloc] initWithFrame:CGRectZero];
    bubble.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.05];
    bubble.layer.cornerRadius = 8;
    bubble.layer.masksToBounds = NO;
    bubble.layer.borderWidth = 0.5;
    bubble.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.7].CGColor;
    bubble.layer.shadowColor = [UIColor blackColor].CGColor;
    bubble.layer.shadowOpacity = 0.18;
    bubble.layer.shadowRadius = 5;
    bubble.layer.shadowOffset = CGSizeMake(0, 2);
    bubble.alpha = 0.0;
    
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor labelColor];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentLeft;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [bubble addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:6],
        [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-6],
        [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-8]
    ]];
    [self addSubview:bubble];
    self.tooltipView = bubble;
    self.tooltipLabel = label;
}

- (NSInteger)indexForLocation:(CGPoint)point {
    if (self.data.count == 0) return NSNotFound;
    CGRect chartRect = [self chartRectForBounds:self.bounds];
    if (point.x < chartRect.origin.x) point.x = chartRect.origin.x;
    if (point.x > chartRect.origin.x + chartRect.size.width) point.x = chartRect.origin.x + chartRect.size.width;
    CGFloat step = chartRect.size.width / MAX(self.data.count, 1);
    NSInteger index = (NSInteger)floor((point.x - chartRect.origin.x) / step);
    if (index < 0) index = 0;
    if (index >= (NSInteger)self.data.count) index = self.data.count - 1;
    return index;
}

- (NSString *)tooltipTextForIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.data.count) return @"";
    NSDictionary *item = self.data[index];
    if (self.mode == CLHistoryModeShort) {
        NSInteger cap = [item[@"CurrentCapacity"] integerValue];
        double tempRaw = [item[@"Temperature"] doubleValue];
        if (tempRaw > 200) tempRaw = tempRaw / 100.0;
        id ampVal = item[@"InstantAmperage"] ?: item[@"Amperage"] ?: item[@"IncomingCurrent"];
        NSInteger amp = [ampVal integerValue];
        id voltVal = item[@"Voltage"] ?: item[@"IncomingVoltage"];
        double volt = [voltVal doubleValue];
        if (volt > 1000) volt = volt / 1000.0;
        NSMutableString *text = [NSMutableString stringWithFormat:CLL(@"电量 %ld%%\n温度 %.1f℃"), (long)cap, tempRaw];
        if (self.showAmperage) {
            [text appendFormat:CLL(@"\n电流 %ld mA"), (long)amp];
        }
        if (self.showVoltage) {
            [text appendFormat:CLL(@"\n电压 %.2f V"), volt];
        }
        return text;
    }
    NSInteger cap = [item[@"NominalChargeCapacity"] integerValue];
    NSInteger cycles = [item[@"CycleCount"] integerValue];
    return [NSString stringWithFormat:CLL(@"容量 %ld mAh\n循环 %ld 次"), (long)cap, (long)cycles];
}

- (void)showTooltipAtIndex:(NSInteger)index location:(CGPoint)point {
    self.highlightIndex = index;
    NSString *text = [self tooltipTextForIndex:index];
    self.tooltipLabel.text = text;
    [self.tooltipLabel sizeToFit];
    
    CGSize maxSize = CGSizeMake(self.bounds.size.width - 24, CGFLOAT_MAX);
    CGSize labelSize = [self.tooltipLabel sizeThatFits:maxSize];
    CGFloat bubbleW = MIN(maxSize.width, labelSize.width + 16);
    CGFloat bubbleH = labelSize.height + 12;
    
    CGFloat x = point.x - bubbleW / 2.0;
    x = clamp(x, 8, self.bounds.size.width - bubbleW - 8);
    CGFloat y = 8;
    self.tooltipView.frame = CGRectMake(x, y, bubbleW, bubbleH);
    if (self.tooltipView.alpha < 1.0) {
        [UIView animateWithDuration:0.15 animations:^{
            self.tooltipView.alpha = 1.0;
        }];
    }
    [self setNeedsDisplay];
}

- (void)hideTooltip {
    self.highlightIndex = NSNotFound;
    if (self.tooltipView.alpha > 0.0) {
        [UIView animateWithDuration:0.15 animations:^{
            self.tooltipView.alpha = 0.0;
        }];
    }
    [self setNeedsDisplay];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (self.data.count == 0) return;
    CGPoint point = [gesture locationInView:self];
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        NSInteger index = [self indexForLocation:point];
        [self showTooltipAtIndex:index location:point];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self hideTooltip];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (self.data.count == 0) return;
    CGPoint point = [gesture locationInView:self];
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        NSInteger index = [self indexForLocation:point];
        [self showTooltipAtIndex:index location:point];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self hideTooltip];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
        CGPoint v = [pan velocityInView:self];
        return fabs(v.x) > fabs(v.y);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([otherGestureRecognizer isKindOfClass:[UISwipeGestureRecognizer class]]) {
        return YES;
    }
    return NO;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    
    CGRect bounds = self.bounds;
    CGRect chartRect = [self chartRectForBounds:bounds];
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor separatorColor].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    for (int i = 1; i <= 3; i++) {
        CGFloat y = chartRect.origin.y + chartRect.size.height * i / 4.0;
        CGContextMoveToPoint(ctx, chartRect.origin.x, y);
        CGContextAddLineToPoint(ctx, chartRect.origin.x + chartRect.size.width, y);
    }
    CGContextStrokePath(ctx);
    
    CGContextSetStrokeColorWithColor(ctx, [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.25].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    CGContextMoveToPoint(ctx, chartRect.origin.x, chartRect.origin.y + chartRect.size.height);
    CGContextAddLineToPoint(ctx, chartRect.origin.x + chartRect.size.width, chartRect.origin.y + chartRect.size.height);
    CGContextStrokePath(ctx);
    
    if (self.data.count == 0) {
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:12],
                                NSForegroundColorAttributeName: [UIColor secondaryLabelColor]};
        NSString *text = CLL(@"暂无数据");
        CGSize sz = [text sizeWithAttributes:attrs];
        CGRect tr = CGRectMake(CGRectGetMidX(bounds) - sz.width / 2.0, CGRectGetMidY(bounds) - sz.height / 2.0, sz.width, sz.height);
        [text drawInRect:tr withAttributes:attrs];
        return;
    }
    
    NSUInteger count = self.data.count;
    CGFloat step = chartRect.size.width / MAX(count, 1);
    CGFloat barWidth = step * 0.32;
    CGFloat barGap = step * 0.08;
    
    NSMutableArray<NSNumber *> *caps = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *temps = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *amps = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *volts = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *cycles = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *capsLong = [NSMutableArray arrayWithCapacity:count];
    
    for (NSDictionary *item in self.data) {
        [caps addObject:@([item[@"CurrentCapacity"] integerValue])];
        double tempRaw = [item[@"Temperature"] doubleValue];
        if (tempRaw > 200) tempRaw = tempRaw / 100.0;
        [temps addObject:@(tempRaw)];
        id ampVal = item[@"InstantAmperage"] ?: item[@"Amperage"] ?: item[@"IncomingCurrent"];
        [amps addObject:@([ampVal integerValue])];
        id voltVal = item[@"Voltage"] ?: item[@"IncomingVoltage"];
        double v = [voltVal doubleValue];
        if (v > 1000) v = v / 1000.0;
        [volts addObject:@(v)];
        [cycles addObject:@([item[@"CycleCount"] integerValue])];
        [capsLong addObject:@([item[@"NominalChargeCapacity"] integerValue])];
    }
    
    CGFloat capMin = 0, capMax = 100;
    CGFloat tempMin = 0, tempMax = 0;
    CGFloat ampMin = 0, ampMax = 0;
    CGFloat voltMin = 0, voltMax = 0;
    CGFloat cycleMin = 0, cycleMax = 0;
    CGFloat capLongMin = 0, capLongMax = 0;
    
    if (self.mode == CLHistoryModeShort) {
        tempMin = CGFLOAT_MAX; tempMax = -CGFLOAT_MAX;
        ampMin = CGFLOAT_MAX; ampMax = -CGFLOAT_MAX;
        voltMin = CGFLOAT_MAX; voltMax = -CGFLOAT_MAX;
        for (NSUInteger i = 0; i < count; i++) {
            tempMin = MIN(tempMin, temps[i].doubleValue);
            tempMax = MAX(tempMax, temps[i].doubleValue);
            ampMin = MIN(ampMin, amps[i].doubleValue);
            ampMax = MAX(ampMax, amps[i].doubleValue);
            voltMin = MIN(voltMin, volts[i].doubleValue);
            voltMax = MAX(voltMax, volts[i].doubleValue);
        }
        if (tempMax - tempMin < 1) { tempMax = tempMin + 1; }
        if (ampMax - ampMin < 1) { ampMax = ampMin + 1; }
        if (voltMax - voltMin < 0.1) { voltMax = voltMin + 0.1; }
    } else {
        cycleMin = CGFLOAT_MAX; cycleMax = -CGFLOAT_MAX;
        capLongMin = CGFLOAT_MAX; capLongMax = -CGFLOAT_MAX;
        for (NSUInteger i = 0; i < count; i++) {
            cycleMin = MIN(cycleMin, cycles[i].doubleValue);
            cycleMax = MAX(cycleMax, cycles[i].doubleValue);
            capLongMin = MIN(capLongMin, capsLong[i].doubleValue);
            capLongMax = MAX(capLongMax, capsLong[i].doubleValue);
        }
        if (cycleMax - cycleMin < 1) { cycleMax = cycleMin + 1; }
        if (capLongMax - capLongMin < 1) { capLongMax = capLongMin + 1; }
    }
    
    UIColor *capColor = [UIColor systemGreenColor];
    UIColor *tempColor = [UIColor systemOrangeColor];
    UIColor *ampColor = [UIColor systemBlueColor];
    UIColor *voltColor = [UIColor systemPurpleColor];
    UIColor *cycleColor = [UIColor systemTealColor];

    // X 轴时间标签
    NSDictionary *timeAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold],
                                NSForegroundColorAttributeName: [UIColor secondaryLabelColor]};
    CGFloat minSpacing = 52.0;
    NSInteger maxLabels = (NSInteger)floor(chartRect.size.width / minSpacing);
    if (maxLabels < 2) {
        maxLabels = 2;
    }
    NSInteger labelCount = (NSInteger)MIN((NSUInteger)maxLabels, count);
    if (labelCount >= 2) {
        CGFloat labelY = CGRectGetMaxY(chartRect) + 6;
        for (NSInteger i = 0; i < labelCount; i++) {
            CGFloat t = (CGFloat)i / (CGFloat)(labelCount - 1);
            NSInteger idx = (NSInteger)round((count - 1) * t);
            if (idx < 0) idx = 0;
            if (idx >= (NSInteger)count) idx = count - 1;
            NSDictionary *item = self.data[idx];
            NSString *timeText = item[@"DisplayTime"];
            if (![timeText isKindOfClass:[NSString class]] || timeText.length == 0) {
                id raw = item[@"UpdateTime"];
                timeText = [raw isKindOfClass:[NSString class]] ? (NSString *)raw : @"";
            }
            if (timeText.length == 0) continue;
            CGSize tSize = [timeText sizeWithAttributes:timeAttrs];
            CGFloat x = chartRect.origin.x + step * idx + step / 2.0 - tSize.width / 2.0;
            CGRect tRect = CGRectMake(clamp(x, chartRect.origin.x, chartRect.origin.x + chartRect.size.width - tSize.width),
                                      labelY,
                                      tSize.width,
                                      tSize.height);
            [timeText drawInRect:tRect withAttributes:timeAttrs];
        }
    }
    
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat xCenter = chartRect.origin.x + step * i + step / 2.0;
        if (self.mode == CLHistoryModeShort) {
            CGFloat capVal = clamp(caps[i].doubleValue, capMin, capMax);
            CGFloat capH = (capVal - capMin) / (capMax - capMin) * chartRect.size.height;
            CGFloat capX = xCenter - barWidth - barGap / 2.0;
            CGRect capRect = CGRectMake(capX, chartRect.origin.y + chartRect.size.height - capH, barWidth, capH);
            UIBezierPath *capPath = [UIBezierPath bezierPathWithRoundedRect:capRect cornerRadius:2];
            [capColor setFill];
            [capPath fill];
            
            CGFloat tVal = clamp(temps[i].doubleValue, tempMin, tempMax);
            CGFloat tH = (tVal - tempMin) / (tempMax - tempMin) * chartRect.size.height;
            CGFloat tX = xCenter + barGap / 2.0;
            CGRect tempRect = CGRectMake(tX, chartRect.origin.y + chartRect.size.height - tH, barWidth, tH);
            UIBezierPath *tempPath = [UIBezierPath bezierPathWithRoundedRect:tempRect cornerRadius:2];
            [tempColor setFill];
            [tempPath fill];
        } else {
            CGFloat capVal = clamp(capsLong[i].doubleValue, capLongMin, capLongMax);
            CGFloat capH = (capVal - capLongMin) / (capLongMax - capLongMin) * chartRect.size.height;
            CGRect capRect = CGRectMake(xCenter - barWidth / 2.0, chartRect.origin.y + chartRect.size.height - capH, barWidth, capH);
            UIBezierPath *capPath = [UIBezierPath bezierPathWithRoundedRect:capRect cornerRadius:2];
            [capColor setFill];
            [capPath fill];
        }
    }
    
    if (self.mode == CLHistoryModeShort) {
        if (self.showAmperage) {
            UIBezierPath *line = [UIBezierPath bezierPath];
            for (NSUInteger i = 0; i < count; i++) {
                CGFloat val = clamp(amps[i].doubleValue, ampMin, ampMax);
                CGFloat y = chartRect.origin.y + chartRect.size.height - (val - ampMin) / (ampMax - ampMin) * chartRect.size.height;
                CGFloat x = chartRect.origin.x + step * i + step / 2.0;
                if (i == 0) {
                    [line moveToPoint:CGPointMake(x, y)];
                } else {
                    [line addLineToPoint:CGPointMake(x, y)];
                }
            }
            [ampColor setStroke];
            line.lineWidth = 1.4;
            [line stroke];
        }
        if (self.showVoltage) {
            UIBezierPath *line = [UIBezierPath bezierPath];
            for (NSUInteger i = 0; i < count; i++) {
                CGFloat val = clamp(volts[i].doubleValue, voltMin, voltMax);
                CGFloat y = chartRect.origin.y + chartRect.size.height - (val - voltMin) / (voltMax - voltMin) * chartRect.size.height;
                CGFloat x = chartRect.origin.x + step * i + step / 2.0;
                if (i == 0) {
                    [line moveToPoint:CGPointMake(x, y)];
                } else {
                    [line addLineToPoint:CGPointMake(x, y)];
                }
            }
            [voltColor setStroke];
            line.lineWidth = 1.4;
            [line stroke];
        }
    } else {
        UIBezierPath *line = [UIBezierPath bezierPath];
        for (NSUInteger i = 0; i < count; i++) {
            CGFloat val = clamp(cycles[i].doubleValue, cycleMin, cycleMax);
            CGFloat y = chartRect.origin.y + chartRect.size.height - (val - cycleMin) / (cycleMax - cycleMin) * chartRect.size.height;
            CGFloat x = chartRect.origin.x + step * i + step / 2.0;
            if (i == 0) {
                [line moveToPoint:CGPointMake(x, y)];
            } else {
                [line addLineToPoint:CGPointMake(x, y)];
            }
        }
        [cycleColor setStroke];
        line.lineWidth = 1.4;
        [line stroke];
    }
    
    if (self.highlightIndex != NSNotFound && self.highlightIndex < (NSInteger)count) {
        NSInteger idx = self.highlightIndex;
        CGFloat x = chartRect.origin.x + step * idx + step / 2.0;
        CGContextSetStrokeColorWithColor(ctx, [[UIColor systemGrayColor] colorWithAlphaComponent:0.5].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextMoveToPoint(ctx, x, chartRect.origin.y);
        CGContextAddLineToPoint(ctx, x, chartRect.origin.y + chartRect.size.height);
        CGContextStrokePath(ctx);
        
        UIColor *accent = [UIColor systemBlueColor];
        CGFloat dotY = chartRect.origin.y + chartRect.size.height * 0.5;
        if (self.mode == CLHistoryModeShort) {
            CGFloat capVal = clamp(caps[idx].doubleValue, capMin, capMax);
            dotY = chartRect.origin.y + chartRect.size.height - (capVal - capMin) / (capMax - capMin) * chartRect.size.height;
        } else {
            CGFloat val = clamp(cycles[idx].doubleValue, cycleMin, cycleMax);
            dotY = chartRect.origin.y + chartRect.size.height - (val - cycleMin) / (cycleMax - cycleMin) * chartRect.size.height;
        }
        CGContextSetStrokeColorWithColor(ctx, [accent colorWithAlphaComponent:0.25].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(x - 6, dotY - 6, 12, 12));
        CGContextSetFillColorWithColor(ctx, accent.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(x - 2.5, dotY - 2.5, 5, 5));
    }
}

@end

@interface CLHistoryViewController : UIViewController
@end

@interface CLHistoryViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) UISegmentedControl *segmentControl;
@property (nonatomic, strong) CLGlassCard *hintCard;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *ampButton;
@property (nonatomic, strong) UIButton *voltButton;
@property (nonatomic, strong) CLGlassCard *tableCard;
@property (nonatomic, strong) CLHistoryChartView *chartView;
@property (nonatomic, strong) UILabel *pageLabel;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIStackView *legendStack;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyMin5;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyHour;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyDay;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyMonth;
@property (nonatomic, assign) BOOL showAmperage;
@property (nonatomic, assign) BOOL showVoltage;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, assign) NSInteger offsetMin5;
@property (nonatomic, assign) NSInteger offsetHour;
@property (nonatomic, assign) NSInteger offsetDay;
@property (nonatomic, assign) NSInteger offsetMonth;
@property (nonatomic, assign) CGSize lastChartSize;
@end

@implementation CLHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    CLApplyLanguageFromSettings();
    self.title = CLL(@"历史统计");
    self.showAmperage = NO;
    self.showVoltage = NO;
    [self setupUI];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange)
                                                 name:CLAppLanguageDidChangeNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshHistoryData];
    if (!self.refreshTimer) {
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:60.0 target:self selector:@selector(refreshHistoryData) userInfo:nil repeats:YES];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(self.chartView.bounds.size, self.lastChartSize)) {
        self.lastChartSize = self.chartView.bounds.size;
        [self updateHistoryTable];
    }
}

- (void)languageDidChange {
    CLApplyLanguageFromSettings();
    self.title = CLL(@"历史统计");
    for (UIView *v in self.view.subviews) {
        [v removeFromSuperview];
    }
    [self setupUI];
}

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];
    
    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 16;
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.mainStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.mainStack.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:20],
        [self.mainStack.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:16],
        [self.mainStack.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-16],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-40],
        [self.mainStack.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-32]
    ]];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = CLL(@"历史统计");
    titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    [self.mainStack addArrangedSubview:titleLabel];
    
    self.segmentControl = [[UISegmentedControl alloc] initWithItems:@[CLL(@"5分钟"), CLL(@"小时"), CLL(@"天"), CLL(@"月")]];
    self.segmentControl.selectedSegmentIndex = 0;
    self.segmentControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.segmentControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.mainStack addArrangedSubview:self.segmentControl];
    
    self.hintCard = [[CLGlassCard alloc] init];
    [self setupHintCard];
    [self.mainStack addArrangedSubview:self.hintCard];
    
    self.tableCard = [[CLGlassCard alloc] init];
    [self setupChartCard];
    [self.mainStack addArrangedSubview:self.tableCard];
    
    [self updateHintForSegment];
    [self updateHistoryTable];
}

- (void)setupChartCard {
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    
    self.prevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.prevButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.prevButton setImage:CLSymbolImage(@"chevron.left", nil) forState:UIControlStateNormal];
    self.prevButton.tintColor = [UIColor labelColor];
    [self.prevButton addTarget:self action:@selector(prevPage) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.prevButton];
    
    self.pageLabel = [[UILabel alloc] init];
    self.pageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.pageLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.pageLabel.textColor = [UIColor secondaryLabelColor];
    self.pageLabel.textAlignment = NSTextAlignmentCenter;
    [header addSubview:self.pageLabel];
    
    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.nextButton setImage:CLSymbolImage(@"chevron.right", nil) forState:UIControlStateNormal];
    self.nextButton.tintColor = [UIColor labelColor];
    [self.nextButton addTarget:self action:@selector(nextPage) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.nextButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:36],
        [self.prevButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [self.prevButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.prevButton.widthAnchor constraintEqualToConstant:28],
        [self.prevButton.heightAnchor constraintEqualToConstant:28],
        [self.nextButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12],
        [self.nextButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.nextButton.widthAnchor constraintEqualToConstant:28],
        [self.nextButton.heightAnchor constraintEqualToConstant:28],
        [self.pageLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [self.pageLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]
    ]];
    
    [self.tableCard.contentStack addArrangedSubview:header];
    [self.tableCard addSeparator];
    
    self.chartView = [[CLHistoryChartView alloc] initWithFrame:CGRectZero];
    self.chartView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chartView.heightAnchor constraintEqualToConstant:220].active = YES;
    [self.tableCard.contentStack addArrangedSubview:self.chartView];
    
    [self.tableCard addSeparator];
    
    UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(prevPage)];
    swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
    swipeLeft.delegate = (id<UIGestureRecognizerDelegate>)self.chartView;
    [self.chartView addGestureRecognizer:swipeLeft];
    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(nextPage)];
    swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
    swipeRight.delegate = (id<UIGestureRecognizerDelegate>)self.chartView;
    [self.chartView addGestureRecognizer:swipeRight];

    UIView *legendRow = [[UIView alloc] init];
    legendRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.legendStack = [[UIStackView alloc] init];
    self.legendStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.legendStack.axis = UILayoutConstraintAxisHorizontal;
    self.legendStack.alignment = UIStackViewAlignmentCenter;
    self.legendStack.spacing = 12;
    [legendRow addSubview:self.legendStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [legendRow.heightAnchor constraintEqualToConstant:32],
        [self.legendStack.leadingAnchor constraintEqualToAnchor:legendRow.leadingAnchor constant:12],
        [self.legendStack.trailingAnchor constraintLessThanOrEqualToAnchor:legendRow.trailingAnchor constant:-12],
        [self.legendStack.centerYAnchor constraintEqualToAnchor:legendRow.centerYAnchor]
    ]];
    
    [self.tableCard.contentStack addArrangedSubview:legendRow];
}

- (void)setupHintCard {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hintLabel.font = [UIFont systemFontOfSize:13];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.numberOfLines = 0;
    [row addSubview:self.hintLabel];
    
    UIStackView *toggleStack = [[UIStackView alloc] init];
    toggleStack.translatesAutoresizingMaskIntoConstraints = NO;
    toggleStack.axis = UILayoutConstraintAxisHorizontal;
    toggleStack.spacing = 8;
    toggleStack.alignment = UIStackViewAlignmentCenter;
    [row addSubview:toggleStack];
    
    self.ampButton = [self buildToggleButtonWithTitle:CLL(@"电流") action:@selector(ampTapped)];
    self.voltButton = [self buildToggleButtonWithTitle:CLL(@"电压") action:@selector(voltTapped)];
    [toggleStack addArrangedSubview:self.ampButton];
    [toggleStack addArrangedSubview:self.voltButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:50],
        [self.hintLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [self.hintLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [self.hintLabel.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12],
        [toggleStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [toggleStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [self.hintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:toggleStack.leadingAnchor constant:-12]
    ]];
    
    [self.hintCard.contentStack addArrangedSubview:row];
    [self updateToggleButtons];
}

- (UIButton *)buildToggleButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 12;
    button.layer.masksToBounds = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:48],
        [button.heightAnchor constraintEqualToConstant:24]
    ]];
    return button;
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self updateHintForSegment];
    [self updateHistoryTable];
}

- (void)ampTapped {
    self.showAmperage = !self.showAmperage;
    [self updateToggleButtons];
    [self updateHistoryTable];
}

- (void)voltTapped {
    self.showVoltage = !self.showVoltage;
    [self updateToggleButtons];
    [self updateHistoryTable];
}

- (void)updateToggleButtons {
    [self applyToggleStyle:self.ampButton selected:self.showAmperage];
    [self applyToggleStyle:self.voltButton selected:self.showVoltage];
}

- (void)applyToggleStyle:(UIButton *)button selected:(BOOL)selected {
    UIColor *bg = selected ? [UIColor systemBlueColor] : [UIColor tertiarySystemFillColor];
    UIColor *fg = selected ? [UIColor whiteColor] : [UIColor labelColor];
    button.backgroundColor = bg;
    [button setTitleColor:fg forState:UIControlStateNormal];
}

- (void)updateHintForSegment {
    BOOL showToggles = self.segmentControl.selectedSegmentIndex <= 1;
    self.ampButton.hidden = !showToggles;
    self.voltButton.hidden = !showToggles;
    if (showToggles) {
        self.hintLabel.text = CLL(@"默认显示电量/温度，点击右侧可展开电流、电压。左右滑动切换页");
    } else {
        self.hintLabel.text = CLL(@"该维度仅显示容量与循环次数。左右滑动切换页");
    }
}

- (void)refreshHistoryData {
    BOOL isInitial = (self.historyMin5.count == 0 && self.historyHour.count == 0 && self.historyDay.count == 0 && self.historyMonth.count == 0);
    NSDictionary *conf = nil;
    if (isInitial) {
        conf = @{
            @"min5": @{@"n": @10000, @"last_id": @0},
            @"hour": @{@"n": @1000, @"last_id": @0},
            @"day": @{@"n": @1000, @"last_id": @0},
            @"month": @{@"n": @1000, @"last_id": @0}
        };
    } else {
        conf = @{
            @"min5": @{@"n": @300, @"last_id": @([self lastIdForData:self.historyMin5 unit:300])},
            @"hour": @{@"n": @300, @"last_id": @([self lastIdForData:self.historyHour unit:3600])},
            @"day": @{@"n": @200, @"last_id": @([self lastIdForData:self.historyDay unit:86400])},
            @"month": @{@"n": @200, @"last_id": @([self lastIdForData:self.historyMonth unit:2592000])}
        };
    }
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] getStatisticsWithConf:conf completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        if (error || response == nil || [response[@"status"] intValue] != 0) {
            [weakSelf updateHistoryTable];
            return;
        }
        NSDictionary *data = response[@"data"];
        NSArray *min5 = [data[@"min5"] isKindOfClass:[NSArray class]] ? data[@"min5"] : @[];
        NSArray *hour = [data[@"hour"] isKindOfClass:[NSArray class]] ? data[@"hour"] : @[];
        NSArray *day = [data[@"day"] isKindOfClass:[NSArray class]] ? data[@"day"] : @[];
        NSArray *month = [data[@"month"] isKindOfClass:[NSArray class]] ? data[@"month"] : @[];
        if (isInitial) {
            weakSelf.historyMin5 = min5;
            weakSelf.historyHour = hour;
            weakSelf.historyDay = day;
            weakSelf.historyMonth = month;
        } else {
            weakSelf.historyMin5 = [weakSelf appendHistory:weakSelf.historyMin5 withNew:min5];
            weakSelf.historyHour = [weakSelf appendHistory:weakSelf.historyHour withNew:hour];
            weakSelf.historyDay = [weakSelf appendHistory:weakSelf.historyDay withNew:day];
            weakSelf.historyMonth = [weakSelf appendHistory:weakSelf.historyMonth withNew:month];
        }
        [weakSelf updateHistoryTable];
    }];
}

- (void)updateHistoryTable {
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    NSArray<NSDictionary *> *data = [self dataForSegment:idx];
    NSInteger windowSize = [self windowSizeForSegment:idx];
    NSInteger maxOffset = [self maxOffsetForSegment:idx totalCount:data.count window:windowSize];
    NSInteger offset = [self offsetForSegment:idx];
    if (offset > maxOffset) {
        [self setOffset:maxOffset forSegment:idx];
        offset = maxOffset;
    }
    NSArray<NSDictionary *> *visible = [self visibleDataForSegment:idx data:data offset:offset window:windowSize];
    CLHistoryMode mode = (idx <= 1) ? CLHistoryModeShort : CLHistoryModeLong;
    BOOL showAmp = (idx <= 1) ? self.showAmperage : NO;
    BOOL showVolt = (idx <= 1) ? self.showVoltage : NO;
    NSString *timeStyle;
    switch (idx) {
        case 0:
        case 1:
            timeStyle = @"time";
            break;
        case 2:
            timeStyle = @"day";
            break;
        default:
            timeStyle = @"month";
            break;
    }
    NSArray<NSDictionary *> *chartData = [self chartDataWithDisplayTimeFrom:visible style:timeStyle];
    [self.chartView updateWithData:chartData mode:mode showAmperage:showAmp showVoltage:showVolt];
    [self updateLegend];
    [self updatePageLabelWithTotal:data.count window:windowSize offset:offset maxOffset:maxOffset];
}

- (void)prevPage {
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    NSInteger offset = [self offsetForSegment:idx];
    NSInteger maxOffset = [self maxOffsetForSegment:idx totalCount:[self dataForSegment:idx].count window:[self windowSizeForSegment:idx]];
    if (offset < maxOffset) {
        [self setOffset:offset + 1 forSegment:idx];
        [self updateHistoryTable];
    }
}

- (void)nextPage {
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    NSInteger offset = [self offsetForSegment:idx];
    if (offset > 0) {
        [self setOffset:offset - 1 forSegment:idx];
        [self updateHistoryTable];
    }
}

- (NSArray<NSDictionary *> *)dataForSegment:(NSInteger)idx {
    switch (idx) {
        case 0: return self.historyMin5 ?: @[];
        case 1: return self.historyHour ?: @[];
        case 2: return self.historyDay ?: @[];
        default: return self.historyMonth ?: @[];
    }
}

- (NSInteger)offsetForSegment:(NSInteger)idx {
    switch (idx) {
        case 0: return self.offsetMin5;
        case 1: return self.offsetHour;
        case 2: return self.offsetDay;
        default: return self.offsetMonth;
    }
}

- (void)setOffset:(NSInteger)offset forSegment:(NSInteger)idx {
    switch (idx) {
        case 0: self.offsetMin5 = offset; break;
        case 1: self.offsetHour = offset; break;
        case 2: self.offsetDay = offset; break;
        default: self.offsetMonth = offset; break;
    }
}

- (NSInteger)windowSizeForSegment:(NSInteger)idx {
    CGFloat width = self.chartView.bounds.size.width;
    NSInteger base = (NSInteger)floor(width / 14.0);
    if (base < 16) {
        base = 16;
    }
    if (idx >= 2) {
        return MAX(12, base - 2);
    }
    return base;
}

- (NSInteger)maxOffsetForSegment:(NSInteger)idx totalCount:(NSInteger)count window:(NSInteger)window {
    if (count <= 0 || window <= 0) {
        return 0;
    }
    NSInteger pages = (count + window - 1) / window;
    return MAX(0, pages - 1);
}

- (NSArray<NSDictionary *> *)visibleDataForSegment:(NSInteger)idx data:(NSArray<NSDictionary *> *)data offset:(NSInteger)offset window:(NSInteger)window {
    if (data.count == 0 || window <= 0) {
        return @[];
    }
    NSInteger end = data.count - offset * window;
    if (end <= 0) {
        return @[];
    }
    NSInteger start = MAX(0, end - window);
    NSRange range = NSMakeRange((NSUInteger)start, (NSUInteger)(end - start));
    return [data subarrayWithRange:range];
}

- (void)updatePageLabelWithTotal:(NSInteger)total window:(NSInteger)window offset:(NSInteger)offset maxOffset:(NSInteger)maxOffset {
    if (total <= 0 || window <= 0) {
        self.pageLabel.text = CLL(@"暂无数据");
        self.prevButton.enabled = NO;
        self.nextButton.enabled = NO;
        return;
    }
    NSInteger page = offset + 1;
    NSInteger pages = maxOffset + 1;
    NSInteger visibleCount = MIN(window, total - offset * window);
    self.pageLabel.text = [NSString stringWithFormat:CLL(@"%ld/%ld · %ld条"), (long)page, (long)pages, (long)visibleCount];
    self.prevButton.enabled = (offset < maxOffset);
    self.nextButton.enabled = (offset > 0);
}

- (void)updateLegend {
    for (UIView *view in self.legendStack.arrangedSubviews) {
        [self.legendStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    if (idx <= 1) {
        [self addLegendItemWithColor:[UIColor systemGreenColor] text:CLL(@"电量")];
        [self addLegendItemWithColor:[UIColor systemOrangeColor] text:CLL(@"温度")];
        if (self.showAmperage) {
            [self addLegendItemWithColor:[UIColor systemBlueColor] text:CLL(@"电流")];
        }
        if (self.showVoltage) {
            [self addLegendItemWithColor:[UIColor systemPurpleColor] text:CLL(@"电压")];
        }
    } else {
        [self addLegendItemWithColor:[UIColor systemGreenColor] text:CLL(@"容量")];
        [self addLegendItemWithColor:[UIColor systemTealColor] text:CLL(@"循环")];
    }
}

- (void)addLegendItemWithColor:(UIColor *)color text:(NSString *)text {
    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 4;
    [dot.widthAnchor constraintEqualToConstant:8].active = YES;
    [dot.heightAnchor constraintEqualToConstant:8].active = YES;
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    
    UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[dot, label]];
    item.translatesAutoresizingMaskIntoConstraints = NO;
    item.axis = UILayoutConstraintAxisHorizontal;
    item.spacing = 4;
    item.alignment = UIStackViewAlignmentCenter;
    [self.legendStack addArrangedSubview:item];
}

- (int)lastIdForData:(NSArray<NSDictionary *> *)data unit:(int)unit {
    if (data.count == 0 || unit <= 0) {
        return 0;
    }
    id tsVal = data.lastObject[@"UpdateTime"];
    if (![tsVal respondsToSelector:@selector(doubleValue)]) {
        return 0;
    }
    double ts = [tsVal doubleValue];
    if (ts <= 0) {
        return 0;
    }
    return (int)floor(ts / unit);
}

- (NSArray<NSDictionary *> *)appendHistory:(NSArray<NSDictionary *> *)base withNew:(NSArray<NSDictionary *> *)incoming {
    if (incoming.count == 0) {
        return base ?: @[];
    }
    if (base.count == 0) {
        return incoming;
    }
    NSMutableArray *merged = [base mutableCopy];
    [merged addObjectsFromArray:incoming];
    return merged;
}

- (NSArray<NSDictionary *> *)chartDataWithDisplayTimeFrom:(NSArray<NSDictionary *> *)data style:(NSString *)style {
    if (data.count == 0) {
        return @[];
    }
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:data.count];
    for (NSDictionary *item in data) {
        NSMutableDictionary *mut = [item mutableCopy];
        NSString *time = [self formatHistoryTime:item[@"UpdateTime"] style:style];
        if (time.length > 0) {
            mut[@"DisplayTime"] = time;
        }
        [out addObject:mut];
    }
    return out;
}

- (NSArray<NSString *> *)shortColumns {
    NSMutableArray *cols = [@[CLL(@"时间"), CLL(@"电量"), CLL(@"温度")] mutableCopy];
    if (self.showAmperage) {
        [cols addObject:CLL(@"电流")];
    }
    if (self.showVoltage) {
        [cols addObject:CLL(@"电压")];
    }
    return cols;
}

- (NSArray<NSArray<NSString *> *> *)shortRows:(NSArray<NSDictionary *> *)data {
    if (data.count == 0) {
        return @[@[CLL(@"暂无数据")]];
    }
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:data.count];
    NSArray *src = [[data reverseObjectEnumerator] allObjects];
    for (NSDictionary *item in src) {
        NSString *time = [self formatHistoryTime:item[@"UpdateTime"] style:@"time"];
        NSString *cap = [self formatPercent:item[@"CurrentCapacity"]];
        NSString *temp = [self formatTemperature:item[@"Temperature"]];
        NSMutableArray *vals = [@[time, cap, temp] mutableCopy];
        if (self.showAmperage) {
            [vals addObject:[self formatAmperage:item[@"Amperage"]]];
        }
        if (self.showVoltage) {
            [vals addObject:[self formatVoltage:item[@"Voltage"]]];
        }
        [rows addObject:vals];
    }
    return rows;
}

- (NSArray<NSArray<NSString *> *> *)longRows:(NSArray<NSDictionary *> *)data {
    if (data.count == 0) {
        return @[@[CLL(@"暂无数据")]];
    }
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:data.count];
    NSArray *src = [[data reverseObjectEnumerator] allObjects];
    for (NSDictionary *item in src) {
        NSString *time = [self formatHistoryTime:item[@"UpdateTime"] style:@"day"];
        NSString *cap = [self formatCapacity:item[@"NominalChargeCapacity"]];
        NSString *cycle = [self formatCycle:item[@"CycleCount"]];
        [rows addObject:@[time, cap, cycle]];
    }
    return rows;
}

- (void)rebuildTableWithTitle:(NSString *)title columns:(NSArray<NSString *> *)columns rows:(NSArray<NSArray<NSString *> *> *)rows {
    for (UIView *view in self.tableCard.contentStack.arrangedSubviews) {
        [self.tableCard.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    
    BOOL isEmpty = (rows.count == 1 && rows.firstObject.count == 1);
    NSUInteger count = isEmpty ? 0 : rows.count;
    UIView *header = [self historyCardHeaderWithTitle:title count:count];
    [self.tableCard.contentStack addArrangedSubview:header];
    [self.tableCard addSeparator];
    
    UIView *colRow = [self historyRowWithValues:columns header:YES];
    [self.tableCard.contentStack addArrangedSubview:colRow];
    [self.tableCard addSeparator];
    
    if (isEmpty) {
        UIView *emptyRow = [self historyRowWithValues:@[CLL(@"暂无数据")] header:NO];
        [self.tableCard.contentStack addArrangedSubview:emptyRow];
        return;
    }
    
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *row = [self historyRowWithValues:rows[i] header:NO];
        if (i % 2 == 1) {
            row.backgroundColor = [[UIColor secondarySystemGroupedBackgroundColor] colorWithAlphaComponent:0.5];
        }
        [self.tableCard.contentStack addArrangedSubview:row];
        if (i < rows.count - 1) {
            [self.tableCard addSeparator];
        }
    }
}

- (UIView *)historyCardHeaderWithTitle:(NSString *)title count:(NSUInteger)count {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    UILabel *countLabel = [[UILabel alloc] init];
    countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    countLabel.text = [NSString stringWithFormat:CLL(@"最近 %lu 条"), (unsigned long)count];
    countLabel.font = [UIFont systemFontOfSize:12];
    countLabel.textColor = [UIColor secondaryLabelColor];
    [row addSubview:countLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:36],
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [countLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [countLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    return row;
}

- (UIView *)historyRowWithValues:(NSArray<NSString *> *)values header:(BOOL)header {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.layoutMargins = UIEdgeInsetsMake(6, 12, 6, 12);
    if (header) {
        row.backgroundColor = [UIColor tertiarySystemFillColor];
    }
    
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 6;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionFillEqually;
    [row addSubview:stack];
    
    for (NSString *text in values) {
        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.font = header ? [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]
                            : [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        label.textColor = header ? [UIColor secondaryLabelColor] : [UIColor labelColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 1;
        [stack addArrangedSubview:label];
    }
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:28],
        [stack.leadingAnchor constraintEqualToAnchor:row.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:row.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:row.layoutMarginsGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:row.layoutMarginsGuide.bottomAnchor]
    ]];
    return row;
}

- (NSString *)formatHistoryTime:(id)val style:(NSString *)style {
    if (![val respondsToSelector:@selector(doubleValue)]) {
        return @"--";
    }
    NSTimeInterval ts = [val doubleValue];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    static NSDateFormatter *fmtShort;
    static NSDateFormatter *fmtLong;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmtShort = [[NSDateFormatter alloc] init];
        fmtShort.dateFormat = @"HH:mm";
        fmtLong = [[NSDateFormatter alloc] init];
        fmtLong.dateFormat = @"MM-dd";
    });
    if ([style isEqualToString:@"day"] || [style isEqualToString:@"long"]) {
        return [fmtLong stringFromDate:date] ?: @"--";
    }
    if ([style isEqualToString:@"month"]) {
        static NSDateFormatter *fmtMonth;
        static dispatch_once_t onceTokenMonth;
        dispatch_once(&onceTokenMonth, ^{
            fmtMonth = [[NSDateFormatter alloc] init];
            fmtMonth.dateFormat = @"MM";
        });
        return [fmtMonth stringFromDate:date] ?: @"--";
    }
    return [fmtShort stringFromDate:date] ?: @"--";
}

- (NSString *)formatPercent:(id)val {
    if (![val respondsToSelector:@selector(integerValue)]) {
        return @"--";
    }
    return [NSString stringWithFormat:@"%ld%%", (long)[val integerValue]];
}

- (NSString *)formatTemperature:(id)val {
    if (![val respondsToSelector:@selector(doubleValue)]) {
        return @"--";
    }
    double temp = [val doubleValue];
    if (temp > 200) {
        temp = temp / 100.0;
    }
    return [NSString stringWithFormat:@"%.1f°C", temp];
}

- (NSString *)formatAmperage:(id)val {
    if (![val respondsToSelector:@selector(integerValue)]) {
        return @"--";
    }
    return [NSString stringWithFormat:@"%ld mA", (long)[val integerValue]];
}

- (NSString *)formatVoltage:(id)val {
    if (![val respondsToSelector:@selector(doubleValue)]) {
        return @"--";
    }
    double v = [val doubleValue];
    if (v > 1000) {
        v = v / 1000.0;
    }
    return [NSString stringWithFormat:@"%.2f V", v];
}

- (NSString *)formatCapacity:(id)val {
    if (![val respondsToSelector:@selector(integerValue)]) {
        return @"--";
    }
    return [NSString stringWithFormat:@"%ld mAh", (long)[val integerValue]];
}

- (NSString *)formatCycle:(id)val {
    if (![val respondsToSelector:@selector(integerValue)]) {
        return @"--";
    }
    return [NSString stringWithFormat:CLL(@"%ld 次"), (long)[val integerValue]];
}

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
    self.chargingIcon.image = CLSymbolImage(@"bolt.fill", config);
    self.chargingIcon.tintColor = [UIColor systemGreenColor];
    self.chargingIcon.hidden = YES;
    [self addSubview:self.chargingIcon];
    
    // 状态标签
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:15];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = CLL(@"使用电池");
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

#pragma mark - 软件设置页面

@interface CLSoftwareSettingsViewController : UIViewController
@end

@interface CLSoftwareSettingsViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) CLGlassCard *settingsCard;
@property (nonatomic, strong) UISlider *hapticTestSlider;
@property (nonatomic, strong) UILabel *hapticValueLabelView;
@property (nonatomic, strong) UIView *hapticRow;
@property (nonatomic, strong) UIView *hapticDetailView;
@property (nonatomic, strong) UIImageView *hapticChevron;
@property (nonatomic, strong) UISegmentedControl *hapticSegment;
@property (nonatomic, assign) BOOL hapticExpanded;
@end

@implementation CLSoftwareSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    CLApplyLanguageFromSettings();
    self.title = CLL(@"软件设置");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self setupUI];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange)
                                                 name:CLAppLanguageDidChangeNotification
                                               object:nil];
}

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];
    
    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 16;
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.mainStack];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.mainStack.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:20],
        [self.mainStack.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:16],
        [self.mainStack.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-16],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-40],
        [self.mainStack.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-32]
    ]];
    
    [self setupSettingsCard];
}

- (void)setupSettingsCard {
    self.settingsCard = [[CLGlassCard alloc] init];
    
    CLBatteryManager *manager = [CLBatteryManager shared];
    NSString *freqValue = [self frequencyString:manager.updateFrequency];
    
    [self.settingsCard addNavigationRowWithIcon:@"clock.arrow.circlepath" title:CLL(@"刷新频率") value:freqValue color:[UIColor systemTealColor] target:self action:@selector(frequencyTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"globe" title:CLL(@"语言") value:[self languageValueLabel] color:[UIColor systemBlueColor] target:self action:@selector(languageTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"moon.fill" title:CLL(@"深色模式") value:[self appearanceValueLabel] color:[UIColor systemGrayColor] target:self action:@selector(darkModeTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard.contentStack addArrangedSubview:[self buildHapticRow]];
    [self.settingsCard addSeparator];
    [self.settingsCard.contentStack addArrangedSubview:[self buildHapticDetailRow]];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"folder" title:CLL(@"配置文件夹") value:@"" color:[UIColor systemTealColor] target:self action:@selector(configFolderTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"questionmark.circle" title:CLL(@"帮助") value:@"" color:[UIColor systemBlueColor] target:self action:@selector(helpTapped)];
    
    [self.mainStack addArrangedSubview:self.settingsCard];
}

- (NSString *)frequencyString:(NSInteger)freq {
    if (freq <= 1) return CLL(@"1 秒");
    if (freq <= 20) return CLL(@"20 秒");
    if (freq <= 60) return CLL(@"1 分钟");
    return CLL(@"10 分钟");
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

- (UIAlertAction *)checkedActionWithTitle:(NSString *)title checked:(BOOL)checked handler:(void (^)(UIAlertAction *action))handler {
    UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:handler];
    @try {
        [action setValue:@(checked) forKey:@"checked"];
    } @catch (NSException *exception) {
    }
    return action;
}

- (void)frequencyTapped {
    NSString *message = CLL(@"影响主页面电池状态/适配器/电池信息等数据的刷新频率，不影响后台守护策略。");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"刷新频率") message:message preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger current = [CLBatteryManager shared].updateFrequency;
    
    __weak typeof(self) weakSelf = self;
    [alert addAction:[self checkedActionWithTitle:CLL(@"1 秒") checked:(current == 1) handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf setUpdateFrequency:1];
    }]];
    [alert addAction:[self checkedActionWithTitle:CLL(@"20 秒") checked:(current == 20) handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf setUpdateFrequency:20];
    }]];
    [alert addAction:[self checkedActionWithTitle:CLL(@"1 分钟") checked:(current == 60) handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf setUpdateFrequency:60];
    }]];
    [alert addAction:[self checkedActionWithTitle:CLL(@"10 分钟") checked:(current == 600) handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf setUpdateFrequency:600];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setUpdateFrequency:(NSInteger)freq {
    [[CLAPIClient shared] setConfigWithKey:@"update_freq" value:@(freq) completion:nil];
    [CLBatteryManager shared].updateFrequency = freq;
    [self updateCardValue:self.settingsCard title:CLL(@"刷新频率") value:[self frequencyString:freq]];
}

- (void)languageTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"语言") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    CLAppLanguage current = CLGetAppLanguage();

    [alert addAction:[self checkedActionWithTitle:CLL(@"跟随系统") checked:(current == CLAppLanguageSystem) handler:^(UIAlertAction * _Nonnull action) {
        CLSetAppLanguage(CLAppLanguageSystem);
    }]];
    [alert addAction:[self checkedActionWithTitle:CLL(@"English") checked:(current == CLAppLanguageEnglish) handler:^(UIAlertAction * _Nonnull action) {
        CLSetAppLanguage(CLAppLanguageEnglish);
    }]];
    [alert addAction:[self checkedActionWithTitle:CLL(@"简体中文") checked:(current == CLAppLanguageChineseSimplified) handler:^(UIAlertAction * _Nonnull action) {
        CLSetAppLanguage(CLAppLanguageChineseSimplified);
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)darkModeTapped {
    if (@available(iOS 13.0, *)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"深色模式") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"跟随系统") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setAppearanceMode:0 label:CLL(@"跟随系统")];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"深色") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setAppearanceMode:2 label:CLL(@"深色")];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"浅色") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setAppearanceMode:1 label:CLL(@"浅色")];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"深色模式") message:CLL(@"iOS 13+ 才支持深色模式") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (NSInteger)hapticStyleValue {
    NSInteger style = [[NSUserDefaults standardUserDefaults] integerForKey:@"SliderHapticStyle"];
    if (style < 0 || style > 3) {
        return 2;
    }
    return style;
}

- (NSString *)hapticValueText {
    switch ([self hapticStyleValue]) {
        case 0: return CLL(@"关闭");
        case 1: return CLL(@"轻");
        case 3: return CLL(@"强");
        default: return CLL(@"中");
    }
}

- (UIView *)buildHapticRow {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.userInteractionEnabled = YES;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor systemOrangeColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIFontWeightMedium];
    iconView.image = CLSymbolImage(@"waveform.path.ecg", config);
    [row addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = CLL(@"滑动震动");
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];
    
    self.hapticValueLabelView = [[UILabel alloc] init];
    self.hapticValueLabelView.translatesAutoresizingMaskIntoConstraints = NO;
    self.hapticValueLabelView.text = [self hapticValueText];
    self.hapticValueLabelView.font = [UIFont systemFontOfSize:15];
    self.hapticValueLabelView.textColor = [UIColor secondaryLabelColor];
    self.hapticValueLabelView.textAlignment = NSTextAlignmentRight;
    [row addSubview:self.hapticValueLabelView];
    
    self.hapticChevron = [[UIImageView alloc] init];
    self.hapticChevron.translatesAutoresizingMaskIntoConstraints = NO;
    self.hapticChevron.image = CLSymbolImage(@"chevron.right", nil);
    self.hapticChevron.tintColor = [UIColor tertiaryLabelColor];
    [row addSubview:self.hapticChevron];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleHapticExpanded)];
    [row addGestureRecognizer:tap];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:22],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [self.hapticChevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [self.hapticChevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [self.hapticChevron.widthAnchor constraintEqualToConstant:10],
        [self.hapticValueLabelView.trailingAnchor constraintEqualToAnchor:self.hapticChevron.leadingAnchor constant:-6],
        [self.hapticValueLabelView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    
    self.hapticRow = row;
    return row;
}

- (UIView *)buildHapticDetailRow {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.alpha = 0.0;
    row.hidden = YES;
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = CLL(@"滑动震动强度");
    titleLabel.font = [UIFont systemFontOfSize:12];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    titleLabel.numberOfLines = 1;
    [row addSubview:titleLabel];
    
    self.hapticSegment = [[UISegmentedControl alloc] initWithItems:@[CLL(@"关闭"), CLL(@"轻"), CLL(@"中"), CLL(@"强")]];
    self.hapticSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.hapticSegment.selectedSegmentIndex = [self hapticStyleValue];
    self.hapticSegment.apportionsSegmentWidthsByContent = YES;
    [self.hapticSegment setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    [self.hapticSegment addTarget:self action:@selector(hapticSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:self.hapticSegment];
    
    self.hapticTestSlider = [[UISlider alloc] init];
    self.hapticTestSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.hapticTestSlider.minimumValue = 0;
    self.hapticTestSlider.maximumValue = 100;
    self.hapticTestSlider.continuous = YES;
    self.hapticTestSlider.value = 0;
    self.hapticTestSlider.tintColor = [UIColor systemOrangeColor];
    [self.hapticTestSlider addTarget:self action:@selector(hapticSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:self.hapticTestSlider];
    
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:124],
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [titleLabel.heightAnchor constraintEqualToConstant:16],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-16],
        [self.hapticSegment.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [self.hapticSegment.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [self.hapticSegment.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [self.hapticSegment.heightAnchor constraintEqualToConstant:30],
        [self.hapticTestSlider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [self.hapticTestSlider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [self.hapticTestSlider.topAnchor constraintEqualToAnchor:self.hapticSegment.bottomAnchor constant:16],
        [self.hapticTestSlider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12]
    ]];
    
    self.hapticDetailView = row;
    return row;
}

- (void)toggleHapticExpanded {
    self.hapticExpanded = !self.hapticExpanded;
    CGFloat angle = self.hapticExpanded ? (M_PI_2) : 0;
    if (self.hapticExpanded) {
        self.hapticDetailView.hidden = NO;
    }
    [UIView animateWithDuration:0.2 animations:^{
        self.hapticChevron.transform = CGAffineTransformMakeRotation(angle);
        self.hapticDetailView.alpha = self.hapticExpanded ? 1.0 : 0.0;
    } completion:^(BOOL finished) {
        if (!self.hapticExpanded) {
            self.hapticDetailView.hidden = YES;
        }
    }];
}

- (void)updateHapticSliderUI {
    NSInteger style = [self hapticStyleValue];
    if (self.hapticValueLabelView) {
        self.hapticValueLabelView.text = [self hapticValueText];
    }
    if (self.hapticSegment) {
        self.hapticSegment.selectedSegmentIndex = style;
    }
}

- (void)hapticSliderChanged:(UISlider *)sender {
    if (@available(iOS 10.0, *)) {
        NSInteger styleValue = [self hapticStyleValue];
        if (styleValue == 0) return;
        UIImpactFeedbackStyle style = UIImpactFeedbackStyleMedium;
        if (styleValue == 1) style = UIImpactFeedbackStyleLight;
        if (styleValue == 3) style = UIImpactFeedbackStyleHeavy;
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
        [feedback impactOccurred];
        [feedback prepare];
    }
}

- (void)hapticSegmentChanged:(UISegmentedControl *)sender {
    NSInteger value = sender.selectedSegmentIndex;
    [[NSUserDefaults standardUserDefaults] setInteger:value forKey:@"SliderHapticStyle"];
    [self updateHapticSliderUI];
}

- (void)setAppearanceMode:(NSInteger)style label:(NSString *)label {
    UIWindow *window = self.view.window;
    if (@available(iOS 13.0, *)) {
        window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)style;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:@"AppAppearance"];
    [self updateCardValue:self.settingsCard title:CLL(@"深色模式") value:label];
}

- (void)configFolderTapped {
    NSString *path = getConfDirPath_C();
    if (path.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"无法打开") message:CLL(@"未能定位配置目录") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (![path hasSuffix:@"/"]) {
        path = [path stringByAppendingString:@"/"];
    }
    NSString *encodedPath = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"filza://view%@", encodedPath ?: @""];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"无法打开") message:CLL(@"配置目录 URL 无效") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"未检测到 Filza") message:CLL(@"请先安装 Filza 文件管理器，再重试打开配置目录。") preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

- (void)helpTapped {
    Class vcClass = NSClassFromString(@"CLHelpViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"帮助") message:CLL(@"ChargeLimiter 是一款电池充电限制工具。\n\n设置充电上下限来保护电池健康度。") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (NSString *)languageValueLabel {
    CLAppLanguage lang = CLGetAppLanguage();
    switch (lang) {
        case CLAppLanguageEnglish: return CLL(@"English");
        case CLAppLanguageChineseSimplified: return CLL(@"简体中文");
        default: return CLL(@"跟随系统");
    }
}

- (NSString *)appearanceValueLabel {
    NSInteger style = [[NSUserDefaults standardUserDefaults] integerForKey:@"AppAppearance"];
    switch (style) {
        case 1: return CLL(@"浅色");
        case 2: return CLL(@"深色");
        default: return CLL(@"跟随系统");
    }
}

- (void)languageDidChange {
    CLApplyLanguageFromSettings();
    self.title = CLL(@"软件设置");
    __weak typeof(self) weakSelf = self;
    void (^rebuildContent)(void) = ^{
        if (!weakSelf) { return; }
        [weakSelf.mainStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        [weakSelf setupSettingsCard];
    };
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:NO completion:rebuildContent];
    } else {
        rebuildContent();
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
@property (nonatomic, strong) CLGlassCard *softwareSettingsEntryCard;
@property (nonatomic, strong) CLGlassCard *historyEntryCard;
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
    CLApplyLanguageFromSettings();
    (void)getAppDocumentsPath_C();
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

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange)
                                                 name:CLAppLanguageDidChangeNotification
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
    titleLabel.text = CLL(@"ChargeLimiter");
    titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    [self.mainStack addArrangedSubview:titleLabel];
    
    // 标题下不再显示副标题
    
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
    
    UILabel *toolsTitle = [[UILabel alloc] init];
    toolsTitle.text = CLL(@"更多功能");
    toolsTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    toolsTitle.textColor = [UIColor secondaryLabelColor];
    [self.mainStack addArrangedSubview:toolsTitle];
    
    // 历史统计入口
    [self setupHistoryEntryCard];
    
    // 充电高级入口
    [self setupMoreCard];
    
    // 软件设置入口（放最底下）
    [self setupSoftwareSettingsEntryCard];

    // 演示模式标签
    [self setupMockBanner];
}

- (void)setupControlCard {
    self.controlCard = [[CLGlassCard alloc] init];
    
    __weak typeof(self) weakSelf = self;
    [self.controlCard addSwitchRowWithIcon:@"bolt.fill" title:CLL(@"启用") isOn:YES color:[UIColor systemGreenColor] tag:100 onChange:^(BOOL isOn) {
        [[CLAPIClient shared] setConfigWithKey:@"enable" value:@(isOn) completion:nil];
        [CLBatteryManager shared].enabled = isOn;
    }];
    [self.controlCard addSeparator];
    [self.controlCard addNavigationRowWithIcon:@"gearshape" title:CLL(@"充电模式") value:CLL(@"插电即充") color:[UIColor systemBlueColor] target:self action:@selector(chargeModesTapped)];
    
    [self.mainStack addArrangedSubview:self.controlCard];
}

- (void)setupLimitCard {
    self.limitCard = [[CLGlassCard alloc] init];
    self.limitCard.viewController = self;
    
    __weak typeof(self) weakSelf = self;
    
    // 开始充电滑块 - 保存引用以便隐藏
    self.chargeBelowRow = [self.limitCard addSliderRowWithTitle:CLL(@"开始充电 (电量 ≤)") value:self.chargeBelow minValue:10 maxValue:95 color:[UIColor systemBlueColor] tag:200 onChange:^(NSInteger value) {
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
    self.chargeAboveRow = [self.limitCard addSliderRowWithTitle:CLL(@"停止充电 (电量 ≥)") value:self.chargeAbove minValue:15 maxValue:100 color:[UIColor systemGreenColor] tag:201 onChange:^(NSInteger value) {
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
    [self.tempCard addSwitchRowWithIcon:@"thermometer.sun" title:CLL(@"温度控制") isOn:manager.tempControlEnabled color:[UIColor systemOrangeColor] tag:250 onChange:^(BOOL isOn) {
        [[CLAPIClient shared] setConfigWithKey:@"enable_temp" value:@(isOn) completion:nil];
        [CLBatteryManager shared].tempControlEnabled = isOn;
        [weakSelf updateTempControlVisibility:isOn];
    }];
    
    self.tempSeparator1 = [self.tempCard addSeparator];
    
    // 高温停充 - 温度 ≥ X°C 时停止充电
    self.tempAboveRow = [self.tempCard addSliderRowWithTitle:CLL(@"高温停充 (温度 ≥)") value:self.chargeTempAbove minValue:30 maxValue:50 color:[UIColor systemRedColor] tag:252 suffix:@"°C" onChange:^(NSInteger value) {
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
    self.tempBelowRow = [self.tempCard addSliderRowWithTitle:CLL(@"降温恢复 (温度 ≤)") value:self.chargeTempBelow minValue:25 maxValue:45 color:[UIColor systemBlueColor] tag:251 suffix:@"°C" onChange:^(NSInteger value) {
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
    
    [self.adapterCard addRowWithIcon:@"powerplug.fill" title:CLL(@"适配器") value:CLL(@"未连接") color:[UIColor systemGreenColor]];
    [self.adapterCard addSeparator];
    [self.adapterCard addRowWithIcon:@"bolt.fill" title:CLL(@"输出功率") value:@"-- W" color:[UIColor systemGreenColor]];
    [self.adapterCard addSeparator];
    [self.adapterCard addRowWithIcon:@"bolt.batteryblock" title:CLL(@"输入电压") value:@"-- V" color:[UIColor systemPurpleColor]];
    
    [self.mainStack addArrangedSubview:self.adapterCard];
    self.chargeBelowSeparator.hidden = YES;
    self.chargeBelowSeparator.alpha = 0;
    self.batteryStatus.showLowMarker = NO;
}

- (void)setupInfoCard {
    self.infoCard = [[CLGlassCard alloc] init];
    
    [self.infoCard addRowWithIcon:@"heart.fill" title:CLL(@"电池健康") value:@"100%" color:[UIColor systemPinkColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"thermometer" title:CLL(@"温度") value:@"25.0°C" color:[UIColor systemOrangeColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"flame.fill" title:CLL(@"高温模拟") value:@"--" color:[UIColor systemOrangeColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"bolt.horizontal" title:CLL(@"电流") value:@"0 mA" color:[UIColor systemPurpleColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"bolt.batteryblock" title:CLL(@"电压") value:@"0.00 V" color:[UIColor systemPurpleColor]];
    [self.infoCard addSeparator];
    [self.infoCard addRowWithIcon:@"arrow.triangle.2.circlepath" title:CLL(@"循环") value:@"0 次" color:[UIColor systemTealColor]];
    
    [self.mainStack addArrangedSubview:self.infoCard];
}

- (void)setupSoftwareSettingsEntryCard {
    self.softwareSettingsEntryCard = [[CLGlassCard alloc] init];
    
    UIControl *entry = [[UIControl alloc] init];
    entry.translatesAutoresizingMaskIntoConstraints = NO;
    entry.layer.cornerRadius = 12;
    entry.clipsToBounds = YES;
    [entry addTarget:self action:@selector(softwareSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    
    UIView *iconWrap = [[UIView alloc] init];
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    iconWrap.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
    iconWrap.layer.cornerRadius = 18;
    [entry addSubview:iconWrap];
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    iconView.image = CLSymbolImage(@"gearshape.2.fill", iconConfig);
    iconView.tintColor = [UIColor systemBlueColor];
    [iconWrap addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = CLL(@"软件设置");
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = CLL(@"刷新频率 / 语言 / 外观 / 配置");
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    [entry addSubview:textStack];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *chevConfig = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightSemibold];
    chevron.image = CLSymbolImage(@"chevron.right", chevConfig);
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [entry addSubview:chevron];
    
    [NSLayoutConstraint activateConstraints:@[
        [entry.heightAnchor constraintEqualToConstant:76],
        [iconWrap.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:16],
        [iconWrap.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [iconWrap.widthAnchor constraintEqualToConstant:36],
        [iconWrap.heightAnchor constraintEqualToConstant:36],
        [iconView.centerXAnchor constraintEqualToAnchor:iconWrap.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconWrap.centerYAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:iconWrap.trailingAnchor constant:12],
        [textStack.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-12],
        [chevron.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor]
    ]];
    
    [self.softwareSettingsEntryCard.contentStack addArrangedSubview:entry];
    [self.mainStack addArrangedSubview:self.softwareSettingsEntryCard];
}

- (void)setupHistoryEntryCard {
    self.historyEntryCard = [[CLGlassCard alloc] init];
    
    UIControl *entry = [[UIControl alloc] init];
    entry.translatesAutoresizingMaskIntoConstraints = NO;
    entry.layer.cornerRadius = 12;
    entry.clipsToBounds = YES;
    [entry addTarget:self action:@selector(historyTapped) forControlEvents:UIControlEventTouchUpInside];
    
    UIView *iconWrap = [[UIView alloc] init];
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    iconWrap.backgroundColor = [[UIColor systemTealColor] colorWithAlphaComponent:0.15];
    iconWrap.layer.cornerRadius = 18;
    [entry addSubview:iconWrap];
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    iconView.image = CLSymbolImage(@"chart.line.uptrend.xyaxis", iconConfig);
    iconView.tintColor = [UIColor systemTealColor];
    [iconWrap addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = CLL(@"历史统计");
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = CLL(@"5分钟/小时/天/月趋势图表");
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    [entry addSubview:textStack];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *chevConfig = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    chevron.image = CLSymbolImage(@"chevron.right", chevConfig);
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [entry addSubview:chevron];
    
    [NSLayoutConstraint activateConstraints:@[
        [entry.heightAnchor constraintEqualToConstant:76],
        [iconWrap.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:16],
        [iconWrap.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [iconWrap.widthAnchor constraintEqualToConstant:36],
        [iconWrap.heightAnchor constraintEqualToConstant:36],
        [iconView.centerXAnchor constraintEqualToAnchor:iconWrap.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconWrap.centerYAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:iconWrap.trailingAnchor constant:12],
        [textStack.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-12],
        [chevron.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor]
    ]];
    
    [self.historyEntryCard.contentStack addArrangedSubview:entry];
    [self.mainStack addArrangedSubview:self.historyEntryCard];
}

- (NSString *)frequencyString:(NSInteger)freq {
    if (freq <= 1) return CLL(@"1 秒");
    if (freq <= 20) return CLL(@"20 秒");
    if (freq <= 60) return CLL(@"1 分钟");
    return CLL(@"10 分钟");
}

- (void)setupMoreCard {
    self.moreCard = [[CLGlassCard alloc] init];
    UIControl *entry = [[UIControl alloc] init];
    entry.translatesAutoresizingMaskIntoConstraints = NO;
    entry.layer.cornerRadius = 12;
    entry.clipsToBounds = YES;
    [entry addTarget:self action:@selector(advancedTapped) forControlEvents:UIControlEventTouchUpInside];
    
    UIView *iconWrap = [[UIView alloc] init];
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    iconWrap.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.15];
    iconWrap.layer.cornerRadius = 18;
    [entry addSubview:iconWrap];
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightSemibold];
    iconView.image = CLSymbolImage(@"slider.horizontal.3", iconConfig);
    iconView.tintColor = [UIColor systemOrangeColor];
    [iconWrap addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = CLL(@"充电高级");
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = CLL(@"停充 / 限流 / 高温模拟");
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    [entry addSubview:textStack];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *chevConfig = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightSemibold];
    chevron.image = CLSymbolImage(@"chevron.right", chevConfig);
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [entry addSubview:chevron];
    
    [NSLayoutConstraint activateConstraints:@[
        [entry.heightAnchor constraintEqualToConstant:76],
        [iconWrap.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:16],
        [iconWrap.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [iconWrap.widthAnchor constraintEqualToConstant:36],
        [iconWrap.heightAnchor constraintEqualToConstant:36],
        [iconView.centerXAnchor constraintEqualToAnchor:iconWrap.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconWrap.centerYAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:iconWrap.trailingAnchor constant:12],
        [textStack.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-12],
        [chevron.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor]
    ]];
    
    [self.moreCard.contentStack addArrangedSubview:entry];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"充电模式") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"插电即充") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [CLBatteryManager shared].chargeMode = CLChargeModePlugAndCharge;
        [[CLAPIClient shared] setConfigWithKey:@"mode" value:@"charge_on_plug" completion:nil];
        [self updateCardValue:self.controlCard title:CLL(@"充电模式") value:CLL(@"插电即充")];
        self.currentChargeMode = 0;
        [self updateChargeBelowVisibility];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"边缘触发") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [CLBatteryManager shared].chargeMode = CLChargeModeEdgeTrigger;
        [[CLAPIClient shared] setConfigWithKey:@"mode" value:@"edge_trigger" completion:nil];
        [self updateCardValue:self.controlCard title:CLL(@"充电模式") value:CLL(@"边缘触发")];
        self.currentChargeMode = 1;
        [self updateChargeBelowVisibility];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
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

- (void)softwareSettingsTapped {
    Class vcClass = NSClassFromString(@"CLSoftwareSettingsViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)historyTapped {
    CLHistoryViewController *vc = [[CLHistoryViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Update UI

- (void)batteryInfoDidUpdate {
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 更新电池状态
    self.batteryStatus.percentage = manager.currentCapacity;
    self.batteryStatus.isCharging = manager.isCharging;
    
    // 更新状态文字
    if (manager.isCharging) {
        self.batteryStatus.statusLabel.text = CLL(@"正在充电");
    } else if (manager.externalConnected) {
        self.batteryStatus.statusLabel.text = CLL(@"已连接电源 · 未充电");
    } else {
        self.batteryStatus.statusLabel.text = CLL(@"使用电池");
    }
    
    // 更新信息卡片
    CGFloat health = manager.designCapacity > 0 ? (manager.nominalCapacity * 100.0 / manager.designCapacity) : 100;
    [self updateCardValue:self.infoCard title:CLL(@"电池健康") value:[NSString stringWithFormat:@"%.0f%%", health]];
    [self updateCardValue:self.infoCard title:CLL(@"温度") value:[NSString stringWithFormat:@"%.1f°C", manager.temperature]];
    [self updateCardValue:self.infoCard title:CLL(@"高温模拟") value:[self thermalModeLabel:manager.thermalSimulateMode]];
    [self updateCardValue:self.infoCard title:CLL(@"电流") value:[NSString stringWithFormat:@"%ld mA", (long)manager.amperage]];
    [self updateCardValue:self.infoCard title:CLL(@"电压") value:[NSString stringWithFormat:@"%.2f V", manager.voltage]];
    [self updateCardValue:self.infoCard title:CLL(@"循环") value:[NSString stringWithFormat:@"%ld 次", (long)manager.cycleCount]];
    
    // 更新适配器卡片
    if (manager.externalConnected && manager.adapterName.length > 0) {
        [self updateCardValue:self.adapterCard title:CLL(@"适配器") value:manager.adapterName];
        [self updateCardValue:self.adapterCard title:CLL(@"输出功率") value:[NSString stringWithFormat:@"%ld W", (long)manager.adapterWatts]];
        [self updateCardValue:self.adapterCard title:CLL(@"输入电压") value:[NSString stringWithFormat:@"%.1f V", manager.adapterVoltage]];
    } else if (manager.externalConnected) {
        [self updateCardValue:self.adapterCard title:CLL(@"适配器") value:CLL(@"已连接")];
        CGFloat watts = (manager.adapterVoltage * manager.adapterCurrent) / 1000.0;
        [self updateCardValue:self.adapterCard title:CLL(@"输出功率") value:[NSString stringWithFormat:@"%.1f W", watts]];
        [self updateCardValue:self.adapterCard title:CLL(@"输入电压") value:[NSString stringWithFormat:@"%.1f V", manager.adapterVoltage]];
    } else {
        [self updateCardValue:self.adapterCard title:CLL(@"适配器") value:CLL(@"未连接")];
        [self updateCardValue:self.adapterCard title:CLL(@"输出功率") value:@"-- W"];
        [self updateCardValue:self.adapterCard title:CLL(@"输入电压") value:@"-- V"];
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
            UIImageView *iconView = objc_getAssociatedObject(switchControl, "iconView");
            UIColor *iconColor = objc_getAssociatedObject(switchControl, "iconColor");
            if (iconView) {
                iconView.tintColor = value ? (iconColor ?: [UIColor systemBlueColor])
                                           : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
            }
            return;
        }
    }
}

- (NSString *)thermalModeLabel:(CLThermalMode)mode {
    switch (mode) {
        case CLThermalModeNominal: return CLL(@"正常");
        case CLThermalModeLight: return CLL(@"轻度");
        case CLThermalModeModerate: return CLL(@"中度");
        case CLThermalModeHeavy: return CLL(@"重度");
        default: return CLL(@"关闭");
    }
}

- (void)configDidUpdate {
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 更新控制卡片的开关和值
    [self updateSwitchInCard:self.controlCard tag:100 value:manager.enabled];
    
    // 更新充电模式显示
    NSString *modeStr = (manager.chargeMode == CLChargeModePlugAndCharge) ? CLL(@"插电即充") : CLL(@"边缘触发");
    [self updateCardValue:self.controlCard title:CLL(@"充电模式") value:modeStr];
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
    
    // 更新高温模拟状态
    [self updateCardValue:self.infoCard title:CLL(@"高温模拟") value:[self thermalModeLabel:manager.thermalSimulateMode]];
    self.chargeTempBelow = manager.chargeTempBelow;
    self.chargeTempAbove = manager.chargeTempAbove;
    [self updateSliderValue:self.tempBelowRow value:manager.chargeTempBelow];
    [self updateSliderLabel:self.tempBelowRow value:manager.chargeTempBelow suffix:@"°C"];
    [self updateSliderValue:self.tempAboveRow value:manager.chargeTempAbove];
    [self updateSliderLabel:self.tempAboveRow value:manager.chargeTempAbove suffix:@"°C"];
    
    // 软件设置入口不需要实时刷新
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

- (void)languageDidChange {
    CLApplyLanguageFromSettings();
    for (UIView *v in self.view.subviews) {
        [v removeFromSuperview];
    }
    [self setupUI];
    [self batteryInfoDidUpdate];
    [self configDidUpdate];
}

@end
