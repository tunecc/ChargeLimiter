//
//  CLBatteryCompatibilityTestViewController.m
//  ChargeLimiter
//
//  电池兼容性测试页面 - 一键自动化停充/智能停充/禁流兼容性测试
//

#import "CLBatteryCompatibilityTestViewController.h"
#import "CLAPIClient.h"
#import "CLBatteryManager.h"
#import "CLLocalization.h"
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 常量与类型

typedef NS_ENUM(NSInteger, CLCompatTestKind) {
    CLCompatTestKindStopCharge = 0,
    CLCompatTestKindSmartStopCharge = 1,
    CLCompatTestKindInflow = 2,
};

typedef NS_ENUM(NSInteger, CLCompatTestVerdict) {
    CLCompatTestVerdictPending = 0,   // 未测/待测
    CLCompatTestVerdictSupported,     // 支持
    CLCompatTestVerdictUnsupported,   // 无法支持
    CLCompatTestVerdictError,         // 写入失败/采集中断等
};

typedef NS_ENUM(NSInteger, CLCompatEventKind) {
    CLCompatEventKindPhaseChanged = 0,
    CLCompatEventKindSample,
    CLCompatEventKindStateChange,
    CLCompatEventKindVerdict,
    CLCompatEventKindFinished,
    CLCompatEventKindAborted,
};

static const NSTimeInterval CLCompatSampleInterval     = 1.0;
static const NSTimeInterval CLCompatMonitorLimit       = 120.0;
static const NSTimeInterval CLCompatConfirmWindow      = 10.0;
static const NSTimeInterval CLCompatConfirmWindowMax   = 30.0;
static const NSInteger      CLCompatCurrentThresholdmA = 5;
static const NSTimeInterval CLCompatSettleLimit        = 15.0;
static NSString * const CLCompatSnapshotKey = @"cl_compat_test_snapshot";

#pragma mark - 事件模型

@interface CLCompatTestEvent : NSObject
@property (nonatomic, assign) CLCompatEventKind kind;
@property (nonatomic, assign) CLCompatTestKind testKind;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic, assign) NSInteger currentmA;
@property (nonatomic, assign) NSTimeInterval elapsed;
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) CLCompatTestVerdict verdict;
@property (nonatomic, assign) NSInteger maxCurrentmA;
@property (nonatomic, assign) NSInteger minCurrentmA;
@end

@implementation CLCompatTestEvent
@end

#pragma mark - 轻量卡片

static void *kCLCompatRowHandlerKey = &kCLCompatRowHandlerKey;

@interface CLCompatCard : UIView
@property (nonatomic, strong) UIStackView *contentStack;
- (UILabel *)addSectionHeader:(NSString *)title;
- (UIView *)addSwitchRowWithTitle:(NSString *)title isOn:(BOOL)isOn onChange:(void(^)(BOOL))onChange;
- (UIButton *)addActionButtonWithTitle:(NSString *)title color:(UIColor *)color handler:(void(^)(void))handler;
- (UILabel *)addValueRowWithTitle:(NSString *)title value:(NSString *)value;
- (UILabel *)addMultilineValueRowWithTitle:(NSString *)title value:(NSString *)value;
- (void)addSeparator;
- (void)addTipRow:(NSString *)text;
@end

@implementation CLCompatCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
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
    return self;
}

- (UILabel *)addSectionHeader:(NSString *)title {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    [row.heightAnchor constraintEqualToConstant:30].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    [self.contentStack addArrangedSubview:row];
    return label;
}

- (UIView *)addSwitchRowWithTitle:(NSString *)title isOn:(BOOL)isOn onChange:(void(^)(BOOL))onChange {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = [UIColor labelColor];
    [row addSubview:titleLabel];

    UISwitch *switchView = [[UISwitch alloc] init];
    switchView.translatesAutoresizingMaskIntoConstraints = NO;
    switchView.on = isOn;
    switchView.onTintColor = [UIColor systemIndigoColor];
    switchView.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [row addSubview:switchView];
    objc_setAssociatedObject(switchView, kCLCompatRowHandlerKey, onChange, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [switchView addTarget:self action:@selector(compatSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44],
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [switchView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [switchView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    [self.contentStack addArrangedSubview:row];
    return row;
}

- (void)compatSwitchChanged:(UISwitch *)sender {
    void (^onChange)(BOOL) = objc_getAssociatedObject(sender, kCLCompatRowHandlerKey);
    if (onChange) onChange(sender.on);
}

- (UIButton *)addActionButtonWithTitle:(NSString *)title color:(UIColor *)color handler:(void(^)(void))handler {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = color ?: [UIColor systemIndigoColor];
    button.layer.cornerRadius = 12;
    objc_setAssociatedObject(button, kCLCompatRowHandlerKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [button addTarget:self action:@selector(compatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:button];
    [row.heightAnchor constraintEqualToConstant:56].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [button.topAnchor constraintEqualToAnchor:row.topAnchor constant:6],
        [button.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-6]
    ]];
    [self.contentStack addArrangedSubview:row];
    return button;
}

- (void)compatButtonTapped:(UIButton *)sender {
    void (^handler)(void) = objc_getAssociatedObject(sender, kCLCompatRowHandlerKey);
    if (handler) handler();
}

- (UILabel *)addValueRowWithTitle:(NSString *)title value:(NSString *)value {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

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
    valueLabel.adjustsFontSizeToFitWidth = YES;
    [row addSubview:valueLabel];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44],
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8]
    ]];
    [self.contentStack addArrangedSubview:row];
    return valueLabel;
}

- (UILabel *)addMultilineValueRowWithTitle:(NSString *)title value:(NSString *)value {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    [row addSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    valueLabel.textColor = [UIColor labelColor];
    valueLabel.numberOfLines = 0;
    [row addSubview:valueLabel];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [titleLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [valueLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [valueLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [valueLabel.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10]
    ]];
    [self.contentStack addArrangedSubview:row];
    return valueLabel;
}

- (void)addSeparator {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor separatorColor];
    [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
    [self.contentStack addArrangedSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:self.contentStack.leadingAnchor constant:16],
        [line.trailingAnchor constraintEqualToAnchor:self.contentStack.trailingAnchor constant:-16]
    ]];
}

- (void)addTipRow:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8]
    ]];
    [self.contentStack addArrangedSubview:row];
}

@end

#pragma mark - 控制器

@interface CLBatteryCompatibilityTestViewController ()

@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) CLCompatCard *precheckCard;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *precheckRows;
@property (nonatomic, strong) CLCompatCard *selectionCard;
@property (nonatomic, strong) NSMutableArray<UISwitch *> *testSwitches;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) CLCompatCard *progressCard;
@property (nonatomic, strong) UILabel *currentTestLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *liveCurrentLabel;
@property (nonatomic, strong) UILabel *eventLabel;
@property (nonatomic, strong) NSMutableArray<CLCompatCard *> *resultCards;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, UILabel *> *> *resultRows;
@property (nonatomic, strong) UILabel *overallLabel;
@property (nonatomic, strong) UILabel *overallWarningLabel;
@property (nonatomic, strong) CLCompatCard *probeCard;
@property (nonatomic, strong) UIButton *probeButton;
@property (nonatomic, strong) UILabel *probeResultLabel;
@property (nonatomic, assign) BOOL engineRunning;
@property (nonatomic, assign) BOOL probeRunning;

@end

@implementation CLBatteryCompatibilityTestViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = CLL(@"电池兼容性测试");

    self.precheckRows = [NSMutableDictionary dictionary];
    self.testSwitches = [NSMutableArray array];
    self.resultCards = [NSMutableArray array];
    self.resultRows = [NSMutableArray array];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 12;
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:self.mainStack];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.mainStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:12],
        [self.mainStack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [self.mainStack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        [self.mainStack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    [self setupIntroCard];
    [self setupPrecheckCard];
    [self setupSelectionCard];
    [self setupStartButton];
    [self setupProgressCard];
    [self setupResultCards];
    [self setupOverallCard];
    [self setupProbeCard];
    [self updateControlsForRunning:NO];
}

#pragma mark - UI 构建

- (void)setupIntroCard {
    CLCompatCard *card = [[CLCompatCard alloc] init];
    [card addSectionHeader:CLL(@"说明")];
    [card addTipRow:CLL(@"一键检测本机是否支持 CL 的停充与禁流控制。测试会短暂停充或禁流（每项最长 2 分钟），结束后自动恢复配置。")];
    [card addTipRow:CLL(@"请在插电且正在充电时运行；既不支持停充也不支持禁流的设备不被 CL 支持。")];
    [self.mainStack addArrangedSubview:card];
}

- (void)setupPrecheckCard {
    self.precheckCard = [[CLCompatCard alloc] init];
    [self.precheckCard addSectionHeader:CLL(@"前置检查")];
    self.precheckRows[@"daemon"] = [self.precheckCard addValueRowWithTitle:CLL(@"daemon 在线") value:@"—"];
    self.precheckRows[@"plugged"] = [self.precheckCard addValueRowWithTitle:CLL(@"已插电") value:@"—"];
    self.precheckRows[@"charging"] = [self.precheckCard addValueRowWithTitle:CLL(@"正在充电") value:@"—"];
    self.precheckRows[@"battery"] = [self.precheckCard addValueRowWithTitle:CLL(@"电量 10%–95%") value:@"—"];
    [self.mainStack addArrangedSubview:self.precheckCard];
}

- (void)setupSelectionCard {
    self.selectionCard = [[CLCompatCard alloc] init];
    [self.selectionCard addSectionHeader:CLL(@"测试项")];
    [self.selectionCard addSwitchRowWithTitle:CLL(@"停充测试") isOn:YES onChange:nil];
    [self.selectionCard addSeparator];
    [self.selectionCard addSwitchRowWithTitle:CLL(@"智能停充测试") isOn:YES onChange:nil];
    [self.selectionCard addSeparator];
    [self.selectionCard addSwitchRowWithTitle:CLL(@"禁流测试") isOn:YES onChange:nil];

    // 记录 switch 引用（按 CLCompatTestKind 下标）
    __block NSInteger index = 0;
    for (UIView *row in self.selectionCard.contentStack.arrangedSubviews) {
        for (UIView *sub in row.subviews) {
            if ([sub isKindOfClass:[UISwitch class]]) {
                [self.testSwitches addObject:sub];
                index++;
            }
        }
    }
    [self.mainStack addArrangedSubview:self.selectionCard];
}

- (void)setupStartButton {
    self.startButton = [self mainStackAddActionButton];
}

- (UIButton *)mainStackAddActionButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [button setTitle:CLL(@"开始测试") forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = [UIColor systemIndigoColor];
    button.layer.cornerRadius = 12;
    [button.heightAnchor constraintEqualToConstant:48].active = YES;
    [button addTarget:self action:@selector(startButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.mainStack addArrangedSubview:button];
    return button;
}

- (void)setupProgressCard {
    self.progressCard = [[CLCompatCard alloc] init];
    [self.progressCard addSectionHeader:CLL(@"进度")];
    self.currentTestLabel = [self.progressCard addValueRowWithTitle:CLL(@"当前测试") value:CLL(@"未测试")];

    UIView *progressRow = [[UIView alloc] init];
    progressRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progress = 0;
    [progressRow addSubview:self.progressView];
    [progressRow.heightAnchor constraintEqualToConstant:20].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [self.progressView.leadingAnchor constraintEqualToAnchor:progressRow.leadingAnchor constant:16],
        [self.progressView.trailingAnchor constraintEqualToAnchor:progressRow.trailingAnchor constant:-16],
        [self.progressView.centerYAnchor constraintEqualToAnchor:progressRow.centerYAnchor]
    ]];
    [self.progressCard.contentStack addArrangedSubview:progressRow];

    self.elapsedLabel = [self.progressCard addValueRowWithTitle:CLL(@"已用时") value:@"0s"];
    self.liveCurrentLabel = [self.progressCard addValueRowWithTitle:CLL(@"实时电流") value:@"— mA"];
    self.eventLabel = [self.progressCard addMultilineValueRowWithTitle:CLL(@"事件") value:@"—"];
    [self.mainStack addArrangedSubview:self.progressCard];
}

- (void)setupResultCards {
    NSArray<NSString *> *names = @[CLL(@"停充测试"), CLL(@"智能停充测试"), CLL(@"禁流测试")];
    for (NSInteger i = 0; i < 3; i++) {
        CLCompatCard *card = [[CLCompatCard alloc] init];
        [card addSectionHeader:names[i]];
        NSMutableDictionary<NSString *, UILabel *> *rows = [NSMutableDictionary dictionary];
        rows[@"verdict"] = [card addValueRowWithTitle:CLL(@"结论") value:CLL(@"未测试")];
        rows[@"current"] = [card addValueRowWithTitle:CLL(@"最大电流") value:@"—"];
        rows[@"elapsed"] = [card addValueRowWithTitle:CLL(@"状态变化") value:@"—"];
        [self.resultCards addObject:card];
        [self.resultRows addObject:rows];
        [self.mainStack addArrangedSubview:card];
    }
}

- (void)setupOverallCard {
    CLCompatCard *card = [[CLCompatCard alloc] init];
    [card addSectionHeader:CLL(@"总体判定")];
    self.overallLabel = [card addMultilineValueRowWithTitle:CLL(@"结论") value:CLL(@"待测试")];
    self.overallWarningLabel = [card addMultilineValueRowWithTitle:CLL(@"警告") value:@""];
    self.overallWarningLabel.hidden = YES;
    [self.mainStack addArrangedSubview:card];
}

- (void)setupProbeCard {
    self.probeCard = [[CLCompatCard alloc] init];
    [self.probeCard addSectionHeader:CLL(@"停充控制探针")];
    __weak typeof(self) weakSelf = self;
    self.probeButton = [self.probeCard addActionButtonWithTitle:CLL(@"运行停充控制探针") color:[UIColor systemBlueColor] handler:^{
        [weakSelf probeButtonTapped];
    }];
    self.probeResultLabel = [self.probeCard addMultilineValueRowWithTitle:CLL(@"最近探针结论") value:CLL(@"尚未运行")];
    [self.probeCard addTipRow:CLL(@"将尝试多种停充写法并自动恢复，整轮可能需要 1–2 分钟。请插着充电器运行。")];
    [self.mainStack addArrangedSubview:self.probeCard];
}

#pragma mark - 状态

- (void)updateControlsForRunning:(BOOL)running {
    self.engineRunning = running;
    [self.startButton setTitle:running ? CLL(@"取消测试") : CLL(@"开始测试") forState:UIControlStateNormal];
    self.startButton.backgroundColor = running ? [UIColor systemRedColor] : [UIColor systemIndigoColor];
    for (UISwitch *sw in self.testSwitches) {
        sw.enabled = !running;
    }
    self.probeButton.enabled = !running && !self.probeRunning;
    self.probeButton.alpha = self.probeButton.enabled ? 1.0 : 0.4;
}

#pragma mark - 动作

- (void)startButtonTapped {
    if (self.engineRunning) {
        // 取消路径由引擎接入后实现
        return;
    }
    // 前置检查由引擎接入后实现
}

- (void)probeButtonTapped {
    if (self.probeRunning || self.engineRunning) {
        return;
    }
    // 探针调用后续接入
}

@end

NS_ASSUME_NONNULL_END
