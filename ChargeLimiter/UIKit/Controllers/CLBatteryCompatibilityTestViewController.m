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

#pragma mark - 测试引擎

@interface CLBatteryCompatibilityEngine : NSObject
@property (nonatomic, copy, nullable) void (^onEvent)(CLCompatTestEvent *event);
- (void)startWithSelection:(NSArray<NSNumber *> *)selection;
- (void)cancel;
+ (void)runPrecheckWithCompletion:(void(^)(NSDictionary<NSString *, NSNumber *> *results))completion;
+ (void)writeSnapshotWithCompletion:(void(^)(BOOL ok))completion;
+ (void)applySnapshotWithCompletion:(void(^)(BOOL ok))completion;
+ (void)clearSnapshot;
+ (void)restoreSnapshot:(BOOL)alsoRestoreCharging completion:(nullable void(^)(BOOL ok))completion;
+ (BOOL)hasPendingSnapshot;
@end

@interface CLBatteryCompatibilityEngine ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL cancelRequested;
@property (nonatomic, assign) BOOL aborting;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *pendingKinds;
@property (nonatomic, assign) CLCompatTestKind currentKind;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) BOOL pollInFlight;
// 单项测试状态
@property (nonatomic, strong) NSMutableArray<NSNumber *> *samples;
@property (nonatomic, assign) NSInteger phase; // 0=等待状态变化 1=确认窗口
@property (nonatomic, assign) NSInteger confirmStartIndex;
@property (nonatomic, assign) NSTimeInterval elapsed;
@property (nonatomic, assign) NSTimeInterval changeElapsed;
@property (nonatomic, assign) NSInteger maxA;
@property (nonatomic, assign) NSInteger minA;
@property (nonatomic, assign) NSInteger failStreak;
@property (nonatomic, assign) BOOL restoreWarningShown;
@property (nonatomic, copy, nullable) void (^testDone)(void);
@end

@implementation CLBatteryCompatibilityEngine

- (void)startWithSelection:(NSArray<NSNumber *> *)selection {
    if (self.running) return;
    self.running = YES;
    self.cancelRequested = NO;
    self.aborting = NO;
    self.restoreWarningShown = NO;
    self.pendingKinds = [NSMutableArray array];
    for (NSInteger i = 0; i < selection.count && i < 3; i++) {
        if (selection[i].boolValue) [self.pendingKinds addObject:@(i)];
    }
    [self emitPhase:CLL(@"正在关闭 CL 全局开关…")];
    [[CLBatteryManager shared] saveConfigKey:@"enable" value:@NO completion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                [self abortRestoreWithReason:CLL(@"关闭 CL 全局开关失败")];
                return;
            }
            [self runNextTest];
        });
    }];
}

- (void)cancel {
    if (!self.running || self.cancelRequested) return;
    self.cancelRequested = YES;
    [self stopTimer];
    [self abortRestoreWithReason:CLL(@"已取消并恢复配置")];
}

#pragma mark - 编排

- (void)runNextTest {
    if (self.cancelRequested) {
        // cancel 已触发幂等 abort；此处仅在异常遗漏时兜底
        if (!self.aborting) [self abortRestoreWithReason:CLL(@"已取消并恢复配置")];
        return;
    }
    if (self.pendingKinds.count == 0) {
        [self finishAll];
        return;
    }
    self.currentKind = (CLCompatTestKind)self.pendingKinds.firstObject.integerValue;
    [self.pendingKinds removeObjectAtIndex:0];
    __weak typeof(self) weakSelf = self;
    self.testDone = ^{ [weakSelf runNextTest]; };
    // 每项开始前复核全局开关未被外部改回
    [[CLAPIClient shared] getConfigWithKey:nil completion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelRequested) return;
            NSDictionary *data = (error == nil && [resp isKindOfClass:[NSDictionary class]] && [resp[@"status"] integerValue] == 0)
                ? resp[@"data"] : nil;
            if (!data) {
                [self abortRestoreWithReason:CLL(@"daemon 已离线，测试中止")];
                return;
            }
            if ([data[@"enable"] boolValue]) {
                [self abortRestoreWithReason:CLL(@"CL 已被重新启用，测试中止")];
                return;
            }
            [self beginTest:self.currentKind];
        });
    }];
}

- (void)beginTest:(CLCompatTestKind)kind {
    self.phase = 0;
    self.elapsed = 0;
    self.changeElapsed = -1;
    self.maxA = NSIntegerMin;
    self.minA = NSIntegerMax;
    self.failStreak = 0;
    self.pollInFlight = NO;
    self.confirmStartIndex = 0;
    self.samples = [NSMutableArray array];
    [self emitPhase:[self nameForKind:kind]];

    // 基线复核：读不到数据视为 daemon 离线；非充电态无法判定状态变化
    [self fetchBatteryData:^(NSDictionary * _Nullable data) {
        if (self.cancelRequested) return;
        if (!data) {
            [self abortRestoreWithReason:CLL(@"daemon 已离线，测试中止")];
            return;
        }
        if (![data[@"IsCharging"] boolValue]) {
            [self finishTestWithVerdict:CLCompatTestVerdictError
                                message:CLL(@"基线异常：当前未在充电")];
            return;
        }
        [self applyPathConfigForKind:kind completion:^{
            if (self.cancelRequested) return;
            [self sendCommandForKind:kind completion:^(BOOL ok) {
                if (self.cancelRequested) return;
                if (!ok) {
                    [self finishTestWithVerdict:CLCompatTestVerdictError
                                        message:CLL(@"控制面写入失败")];
                    return;
                }
                [self startMonitoring];
            }];
        }];
    }];
}

- (NSString *)nameForKind:(CLCompatTestKind)kind {
    switch (kind) {
        case CLCompatTestKindStopCharge: return CLL(@"停充测试");
        case CLCompatTestKindSmartStopCharge: return CLL(@"智能停充测试");
        case CLCompatTestKindInflow: return CLL(@"禁流测试");
    }
}

- (void)applyPathConfigForKind:(CLCompatTestKind)kind completion:(void(^)(void))completion {
    if (kind == CLCompatTestKindInflow) {
        completion();
        return;
    }
    // 停充测传统 IsCharging 写法，智能停充测 PredictiveChargingInhibit 写法
    BOOL predictive = (kind == CLCompatTestKindSmartStopCharge);
    __weak typeof(self) weakSelf = self;
    [[CLBatteryManager shared] saveConfigKey:@"adv_predictive_inhibit_charge" value:@(predictive) completion:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 取消竞态：本写可能落在快照恢复之后，幂等补救一次
            if (weakSelf.cancelRequested) {
                [CLBatteryCompatibilityEngine applySnapshotWithCompletion:nil];
                return;
            }
            completion();
        });
    }];
}

- (void)sendCommandForKind:(CLCompatTestKind)kind completion:(void(^)(BOOL ok))completion {
    CLAPICallback handler = ^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = (error == nil && [resp isKindOfClass:[NSDictionary class]] && [resp[@"status"] integerValue] == 0);
            completion(ok);
        });
    };
    if (kind == CLCompatTestKindInflow) {
        [[CLAPIClient shared] setInflowStatus:NO completion:handler];
    } else {
        [[CLAPIClient shared] setChargeStatus:NO completion:handler];
    }
}

#pragma mark - 采样与判定

- (void)startMonitoring {
    __weak typeof(self) weakSelf = self;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(CLCompatSampleInterval * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf pollTick];
    });
    self.timer = timer;
    dispatch_resume(timer);
}

- (void)stopTimer {
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
}

- (void)pollTick {
    if (self.cancelRequested || self.pollInFlight) return;
    self.pollInFlight = YES;
    [self fetchBatteryData:^(NSDictionary * _Nullable data) {
        self.pollInFlight = NO;
        if (self.cancelRequested) return;
        if (!data) {
            self.failStreak++;
            if (self.failStreak >= 5) {
                [self finishTestWithVerdict:CLCompatTestVerdictError
                                    message:CLL(@"数据采集中断")];
            }
            return;
        }
        self.failStreak = 0;
        [self handleSample:data];
    }];
}

- (void)fetchBatteryData:(void(^)(NSDictionary * _Nullable data))completion {
    [[CLAPIClient shared] getBatteryInfoWithCompletion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error == nil && [resp isKindOfClass:[NSDictionary class]] && [resp[@"status"] integerValue] == 0) {
                completion([resp[@"data"] isKindOfClass:[NSDictionary class]] ? resp[@"data"] : nil);
            } else {
                completion(nil);
            }
        });
    }];
}

- (NSInteger)effectiveCurrentmA:(NSDictionary *)data {
    id instant = data[@"InstantAmperage"];
    if (instant != nil) return [instant integerValue];
    id amp = data[@"Amperage"];
    if (amp != nil) return [amp integerValue];
    return 0;
}

- (void)handleSample:(NSDictionary *)data {
    NSInteger current = [self effectiveCurrentmA:data];
    self.elapsed += CLCompatSampleInterval;
    [self.samples addObject:@(current)];
    if (current > self.maxA) self.maxA = current;
    if (current < self.minA) self.minA = current;

    CLCompatTestEvent *event = [[CLCompatTestEvent alloc] init];
    event.kind = CLCompatEventKindSample;
    event.testKind = self.currentKind;
    event.currentmA = current;
    event.elapsed = self.elapsed;
    event.progress = MIN(self.elapsed / CLCompatMonitorLimit, 1.0);
    [self emitEvent:event];

    BOOL isCharging = [data[@"IsCharging"] boolValue];
    BOOL extCapable = [data[@"ExternalChargeCapable"] boolValue];
    BOOL extConnected = [data[@"ExternalConnected"] boolValue];

    if (self.phase == 0) {
        // 等待状态变化：禁流以电流特征为主（iOS17+ External* 派生值会抖动）
        BOOL changed;
        if (self.currentKind == CLCompatTestKindInflow) {
            changed = (!extCapable || !extConnected || !isCharging || current < 0);
        } else {
            changed = !isCharging;
        }
        if (changed) {
            self.phase = 1;
            self.changeElapsed = self.elapsed;
            self.confirmStartIndex = self.samples.count - 1;
            CLCompatTestEvent *changeEvent = [[CLCompatTestEvent alloc] init];
            changeEvent.kind = CLCompatEventKindStateChange;
            changeEvent.testKind = self.currentKind;
            changeEvent.elapsed = self.changeElapsed;
            [self emitEvent:changeEvent];
        } else if (self.elapsed >= CLCompatMonitorLimit) {
            [self finishTestWithVerdict:CLCompatTestVerdictUnsupported
                                message:CLL(@"120 秒内充电状态无变化")];
        }
        return;
    }

    // 确认窗口
    NSInteger confirmCount = (NSInteger)(self.samples.count - (NSUInteger)self.confirmStartIndex);
    if (confirmCount < (NSInteger)CLCompatConfirmWindow) return;
    NSUInteger start = (NSUInteger)self.confirmStartIndex;
    NSArray<NSNumber *> *window = [self.samples subarrayWithRange:NSMakeRange(start, self.samples.count - start)];
    BOOL allBelow = YES, allAbove = YES;
    for (NSNumber *v in window) {
        if (v.integerValue < CLCompatCurrentThresholdmA) allAbove = NO;
        else allBelow = NO;
    }
    if (allBelow) {
        [self finishTestWithVerdict:CLCompatTestVerdictSupported message:nil];
    } else if (allAbove) {
        [self finishTestWithVerdict:CLCompatTestVerdictUnsupported
                            message:CLL(@"停充后电流持续 ≥5mA")];
    } else if (confirmCount >= (NSInteger)CLCompatConfirmWindowMax) {
        // 混合抖动：按全窗口均值判定
        double sum = 0;
        for (NSNumber *v in window) sum += v.doubleValue;
        double mean = sum / (double)window.count;
        [self finishTestWithVerdict:(mean < (double)CLCompatCurrentThresholdmA
                                     ? CLCompatTestVerdictSupported
                                     : CLCompatTestVerdictUnsupported)
                            message:nil];
    }
}

#pragma mark - 单项收尾与回稳

- (void)finishTestWithVerdict:(CLCompatTestVerdict)verdict message:(nullable NSString *)message {
    [self stopTimer];
    CLCompatTestEvent *event = [[CLCompatTestEvent alloc] init];
    event.kind = CLCompatEventKindVerdict;
    event.testKind = self.currentKind;
    event.verdict = verdict;
    event.message = message;
    event.maxCurrentmA = self.maxA;
    event.minCurrentmA = self.minA;
    event.elapsed = self.changeElapsed;
    [self emitEvent:event];

    [self settleAfterTest:^(BOOL settled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelRequested) return;
            if (!settled) self.restoreWarningShown = YES;
            void (^done)(void) = self.testDone;
            self.testDone = nil;
            if (done) done();
        });
    }];
}

- (void)settleAfterTest:(void(^)(BOOL settled))completion {
    CLCompatTestKind kind = self.currentKind;
    void (^startSettle)(void) = ^{
        __block NSInteger tries = 0;
        __block void (^poll)(void);
        poll = ^{
            if (self.cancelRequested) { poll = nil; completion(NO); return; }
            if (tries >= (NSInteger)CLCompatSettleLimit) { poll = nil; completion(NO); return; }
            tries++;
            [self fetchBatteryData:^(NSDictionary * _Nullable data) {
                BOOL charging = [data[@"IsCharging"] boolValue];
                NSInteger current = data ? [self effectiveCurrentmA:data] : 0;
                if (charging && current > 0) {
                    poll = nil;
                    completion(YES);
                } else {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CLCompatSampleInterval * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), poll);
                }
            }];
        };
        poll();
    };
    if (kind == CLCompatTestKindInflow) {
        [[CLAPIClient shared] setInflowStatus:YES completion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[CLAPIClient shared] setChargeStatus:YES completion:^(NSDictionary * _Nullable r2, NSError * _Nullable e2) {
                    dispatch_async(dispatch_get_main_queue(), startSettle);
                }];
            });
        }];
    } else {
        [[CLAPIClient shared] setChargeStatus:YES completion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), startSettle);
        }];
    }
}

#pragma mark - 总收尾

- (void)finishAll {
    self.running = NO;
    [CLBatteryCompatibilityEngine applySnapshotWithCompletion:^(BOOL ok) {
        NSString *message = self.restoreWarningShown ? CLL(@"测试后充电恢复异常，请手动检查") : nil;
        if (!ok) {
            NSString *restoreFail = CLL(@"配置恢复失败，请重进本页恢复");
            message = message ? [NSString stringWithFormat:@"%@\n%@", message, restoreFail] : restoreFail;
        }
        CLCompatTestEvent *event = [[CLCompatTestEvent alloc] init];
        event.kind = CLCompatEventKindFinished;
        event.message = message;
        [self emitEvent:event];
    }];
}

- (void)abortRestoreWithReason:(NSString *)reason {
    if (self.aborting) return;
    self.aborting = YES;
    [self stopTimer];
    [[CLAPIClient shared] setInflowStatus:YES completion:^(NSDictionary * _Nullable r1, NSError * _Nullable e1) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[CLAPIClient shared] setChargeStatus:YES completion:^(NSDictionary * _Nullable r2, NSError * _Nullable e2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [CLBatteryCompatibilityEngine applySnapshotWithCompletion:^(BOOL ok) {
                        self.running = NO;
                        NSString *message = reason;
                        if (!ok) {
                            message = [NSString stringWithFormat:@"%@\n%@", reason,
                                       CLL(@"配置恢复失败，请重进本页恢复")];
                        }
                        CLCompatTestEvent *event = [[CLCompatTestEvent alloc] init];
                        event.kind = CLCompatEventKindAborted;
                        event.message = message;
                        [self emitEvent:event];
                    }];
                });
            }];
        });
    }];
}

#pragma mark - 事件

- (void)emitPhase:(NSString *)text {
    CLCompatTestEvent *event = [[CLCompatTestEvent alloc] init];
    event.kind = CLCompatEventKindPhaseChanged;
    event.testKind = self.currentKind;
    event.message = text;
    [self emitEvent:event];
}

- (void)emitEvent:(CLCompatTestEvent *)event {
    void (^handler)(CLCompatTestEvent *) = self.onEvent;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(event); });
}

+ (void)runPrecheckWithCompletion:(void(^)(NSDictionary<NSString *, NSNumber *> *results))completion {    [[CLAPIClient shared] getBatteryInfoWithCompletion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary<NSString *, NSNumber *> *r = [@{
                @"daemon": @NO, @"plugged": @NO, @"charging": @NO, @"battery": @NO
            } mutableCopy];
            NSDictionary *data = nil;
            if (error == nil && [resp isKindOfClass:[NSDictionary class]] && [resp[@"status"] integerValue] == 0) {
                data = [resp[@"data"] isKindOfClass:[NSDictionary class]] ? resp[@"data"] : nil;
            }
            r[@"daemon"] = @(data != nil);
            if (data) {
                r[@"plugged"] = @([data[@"ExternalConnected"] boolValue]);
                r[@"charging"] = @([data[@"IsCharging"] boolValue]);
                NSInteger cap = [data[@"CurrentCapacity"] integerValue];
                r[@"battery"] = @(cap >= 10 && cap <= 95);
            }
            if (completion) completion(r);
        });
    }];
}

+ (void)writeSnapshotWithCompletion:(void(^)(BOOL ok))completion {
    [[CLAPIClient shared] getConfigWithKey:nil completion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *data = nil;
            if (error == nil && [resp isKindOfClass:[NSDictionary class]] && [resp[@"status"] integerValue] == 0) {
                data = [resp[@"data"] isKindOfClass:[NSDictionary class]] ? resp[@"data"] : nil;
            }
            if (!data) {
                if (completion) completion(NO);
                return;
            }
            NSDictionary *snap = @{
                @"enable": @([data[@"enable"] boolValue]),
                @"adv_predictive_inhibit_charge": data[@"adv_predictive_inhibit_charge"] == nil
                    ? @YES : @([data[@"adv_predictive_inhibit_charge"] boolValue]),
            };
            [NSUserDefaults.standardUserDefaults setObject:snap forKey:CLCompatSnapshotKey];
            if (completion) completion(YES);
        });
    }];
}

+ (void)applySnapshotWithCompletion:(void(^)(BOOL ok))completion {
    NSDictionary *snap = [NSUserDefaults.standardUserDefaults dictionaryForKey:CLCompatSnapshotKey];
    if (snap.count == 0) {
        if (completion) completion(YES);
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    __block BOOL ok = YES;
    dispatch_group_enter(group);
    [[CLBatteryManager shared] saveConfigKey:@"enable" value:snap[@"enable"] ?: @YES completion:^(BOOL success) {
        if (!success) ok = NO;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[CLBatteryManager shared] saveConfigKey:@"adv_predictive_inhibit_charge" value:snap[@"adv_predictive_inhibit_charge"] ?: @YES completion:^(BOOL success) {
        if (!success) ok = NO;
        dispatch_group_leave(group);
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // 仅全部恢复成功才清快照；失败保留以便下次进入补救
        if (ok) [NSUserDefaults.standardUserDefaults removeObjectForKey:CLCompatSnapshotKey];
        if (completion) completion(ok);
    });
}

+ (void)clearSnapshot {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CLCompatSnapshotKey];
}

+ (void)restoreSnapshot:(BOOL)alsoRestoreCharging completion:(nullable void(^)(BOOL ok))completion {
    if (!alsoRestoreCharging) {
        [self applySnapshotWithCompletion:completion];
        return;
    }
    // 残留快照场景无法得知上次停在哪一步，禁流与停充都显式恢复
    [[CLAPIClient shared] setInflowStatus:YES completion:^(NSDictionary * _Nullable r1, NSError * _Nullable e1) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[CLAPIClient shared] setChargeStatus:YES completion:^(NSDictionary * _Nullable r2, NSError * _Nullable e2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self applySnapshotWithCompletion:completion];
                });
            }];
        });
    }];
}

+ (BOOL)hasPendingSnapshot {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:CLCompatSnapshotKey].count > 0;
}

@end

#pragma mark - 控制器

@interface CLBatteryCompatibilityTestViewController ()

@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) CLBatteryCompatibilityEngine *engine;
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
@property (nonatomic, assign) BOOL starting;
@property (nonatomic, strong, nullable) NSDictionary *lastProbePayload;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *verdicts;

@end

@implementation CLBatteryCompatibilityTestViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = CLL(@"电池兼容性测试");
    self.engine = [[CLBatteryCompatibilityEngine alloc] init];

    self.precheckRows = [NSMutableDictionary dictionary];
    self.testSwitches = [NSMutableArray array];
    self.resultCards = [NSMutableArray array];
    self.resultRows = [NSMutableArray array];
    self.verdicts = [NSMutableArray arrayWithArray:@[@(CLCompatTestVerdictPending), @(CLCompatTestVerdictPending), @(CLCompatTestVerdictPending)]];

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
    for (UIView *row in self.selectionCard.contentStack.arrangedSubviews) {
        for (UIView *sub in row.subviews) {
            if ([sub isKindOfClass:[UISwitch class]]) {
                [self.testSwitches addObject:sub];
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
        rows[@"maxCurrent"] = [card addValueRowWithTitle:CLL(@"最大电流") value:@"—"];
        rows[@"minCurrent"] = [card addValueRowWithTitle:CLL(@"最低电流") value:@"—"];
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
    [self.probeCard addActionButtonWithTitle:CLL(@"复制详细") color:[UIColor systemGrayColor] handler:^{
        [weakSelf copyProbeDetails];
    }];
    [self.probeCard addTipRow:CLL(@"将尝试多种停充写法并自动恢复，整轮可能需要 1–2 分钟。请插着充电器运行。")];
    [self.mainStack addArrangedSubview:self.probeCard];
}

#pragma mark - 状态

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if ([CLBatteryCompatibilityEngine hasPendingSnapshot]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"检测到未完成的测试")
                                                                       message:CLL(@"上次测试未正常结束，是否恢复配置？")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"恢复") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [CLBatteryCompatibilityEngine restoreSnapshot:YES completion:^(BOOL ok) {
                NSString *msg = ok ? CLL(@"配置已恢复") : CLL(@"恢复失败，请检查 daemon 状态");
                UIAlertController *done = [UIAlertController alertControllerWithTitle:nil
                                                                              message:msg
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:done animated:YES completion:nil];
            }];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"丢弃") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [CLBatteryCompatibilityEngine clearSnapshot];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.engineRunning) {
        [self.engine cancel];
    }
}

- (void)updateControlsForRunning:(BOOL)running {
    self.engineRunning = running;
    [self.startButton setTitle:running ? CLL(@"取消测试") : CLL(@"开始测试") forState:UIControlStateNormal];
    self.startButton.backgroundColor = running ? [UIColor systemRedColor] : [UIColor systemIndigoColor];
    // 测试与探针互斥：探针运行期间控制写会被 daemon 假成功，禁止开始测试
    self.startButton.enabled = running ? YES : !self.probeRunning;
    self.startButton.alpha = self.startButton.enabled ? 1.0 : 0.4;
    for (UISwitch *sw in self.testSwitches) {
        sw.enabled = !running;
    }
    self.probeButton.enabled = !running && !self.probeRunning;
    self.probeButton.alpha = self.probeButton.enabled ? 1.0 : 0.4;
}

#pragma mark - 动作

- (void)startButtonTapped {
    if (self.engineRunning) {
        [self.engine cancel];
        return;
    }
    if (self.probeRunning || self.starting) return;
    self.starting = YES;
    self.startButton.enabled = NO;
    self.startButton.alpha = 0.4;
    __weak typeof(self) weakSelf = self;
    [self setPrecheckRowsPending];
    [CLBatteryCompatibilityEngine runPrecheckWithCompletion:^(NSDictionary<NSString *, NSNumber *> *results) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf applyPrecheckResults:results];
        BOOL allOK = results[@"daemon"].boolValue && results[@"plugged"].boolValue &&
                     results[@"charging"].boolValue && results[@"battery"].boolValue;
        if (!allOK) {
            strongSelf.starting = NO;
            strongSelf.startButton.enabled = !strongSelf.probeRunning;
            strongSelf.startButton.alpha = strongSelf.startButton.enabled ? 1.0 : 0.4;
            return;
        }
        [CLBatteryCompatibilityEngine writeSnapshotWithCompletion:^(BOOL ok) {
            __strong typeof(weakSelf) strongSelf3 = weakSelf;
            if (!strongSelf3) return;
            if (!ok) {
                strongSelf3.starting = NO;
                strongSelf3.startButton.enabled = !strongSelf3.probeRunning;
                strongSelf3.startButton.alpha = strongSelf3.startButton.enabled ? 1.0 : 0.4;
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"无法读取当前配置")
                                                                               message:CLL(@"daemon 未响应，请重试。")
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf3 presentViewController:alert animated:YES completion:nil];
                return;
            }
            strongSelf3.starting = NO;
            [strongSelf3 beginTestFlow];
        }];
    }];
}

- (void)beginTestFlow {
    BOOL stopOn = self.testSwitches.count > 0 ? self.testSwitches[0].on : NO;
    BOOL smartOn = self.testSwitches.count > 1 ? self.testSwitches[1].on : NO;
    BOOL inflowOn = self.testSwitches.count > 2 ? self.testSwitches[2].on : NO;
    if (!stopOn && !smartOn && !inflowOn) {
        [CLBatteryCompatibilityEngine clearSnapshot];
        [self showSimpleAlert:CLL(@"请至少选择一项测试")];
        return;
    }
    NSArray<NSNumber *> *selection = @[@(stopOn), @(smartOn), @(inflowOn)];
    [self resetUIForNewRun];
    __weak typeof(self) weakSelf = self;
    self.engine.onEvent = ^(CLCompatTestEvent *event) {
        [weakSelf handleEngineEvent:event];
    };
    [self updateControlsForRunning:YES];
    [self.engine startWithSelection:selection];
}

- (void)resetUIForNewRun {
    for (NSInteger i = 0; i < 3; i++) self.verdicts[i] = @(CLCompatTestVerdictPending);
    for (NSDictionary<NSString *, UILabel *> *rows in self.resultRows) {
        rows[@"verdict"].text = CLL(@"未测试");
        rows[@"verdict"].textColor = [UIColor secondaryLabelColor];
        rows[@"maxCurrent"].text = @"—";
        rows[@"minCurrent"].text = @"—";
        rows[@"elapsed"].text = @"—";
    }
    self.overallLabel.text = CLL(@"待测试");
    self.overallLabel.textColor = [UIColor secondaryLabelColor];
    self.overallWarningLabel.hidden = YES;
    self.eventLabel.text = @"—";
    self.liveCurrentLabel.text = @"— mA";
    self.elapsedLabel.text = @"0s";
    self.progressView.progress = 0.0;
    self.currentTestLabel.text = @"—";
}

- (void)showSimpleAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleEngineEvent:(CLCompatTestEvent *)event {
    switch (event.kind) {
        case CLCompatEventKindPhaseChanged:
            self.currentTestLabel.text = event.message ?: @"—";
            self.progressView.progress = 0;
            break;
        case CLCompatEventKindSample:
            self.liveCurrentLabel.text = [NSString stringWithFormat:@"%ld mA", (long)event.currentmA];
            self.elapsedLabel.text = [NSString stringWithFormat:CLL(@"%lds / 剩余约 %lds"),
                                      (long)event.elapsed,
                                      (long)MAX(0, (NSTimeInterval)(CLCompatMonitorLimit - event.elapsed))];
            self.progressView.progress = (float)event.progress;
            break;
        case CLCompatEventKindStateChange:
            self.eventLabel.text = [NSString stringWithFormat:CLL(@"检测到状态变化（%ds）"), (long)event.elapsed];
            break;
        case CLCompatEventKindVerdict:
            [self applyVerdictEvent:event];
            self.progressView.progress = 0.0;
            break;
        case CLCompatEventKindFinished:
            self.currentTestLabel.text = CLL(@"测试完成");
            self.progressView.progress = 1.0;
            [self updateOverallVerdict];
            if (event.message.length > 0) {
                self.overallWarningLabel.text = event.message;
                self.overallWarningLabel.hidden = NO;
                self.overallWarningLabel.textColor = [UIColor systemOrangeColor];
            }
            [self updateControlsForRunning:NO];
            break;
        case CLCompatEventKindAborted:
            self.currentTestLabel.text = CLL(@"已中止");
            if (event.message.length > 0) self.eventLabel.text = event.message;
            [self updateControlsForRunning:NO];
            break;
    }
}

- (void)applyVerdictEvent:(CLCompatTestEvent *)event {
    NSInteger kind = (NSInteger)event.testKind;
    if (kind < 0 || kind > 2) return;
    self.verdicts[kind] = @(event.verdict);
    NSMutableDictionary<NSString *, UILabel *> *rows = self.resultRows[kind];

    NSString *verdictText;
    UIColor *verdictColor;
    switch (event.verdict) {
        case CLCompatTestVerdictSupported:
            verdictText = CLL(@"支持");
            verdictColor = [UIColor systemGreenColor];
            break;
        case CLCompatTestVerdictUnsupported:
            verdictText = CLL(@"无法支持");
            verdictColor = [UIColor systemRedColor];
            break;
        case CLCompatTestVerdictError:
            verdictText = CLL(@"异常");
            verdictColor = [UIColor systemOrangeColor];
            break;
        default:
            verdictText = CLL(@"未测试");
            verdictColor = [UIColor secondaryLabelColor];
            break;
    }
    rows[@"verdict"].text = verdictText;
    rows[@"verdict"].textColor = verdictColor;
    rows[@"maxCurrent"].text = event.maxCurrentmA == NSIntegerMin
        ? @"—" : [NSString stringWithFormat:@"%ld mA", (long)event.maxCurrentmA];
    rows[@"minCurrent"].text = event.minCurrentmA == NSIntegerMax
        ? @"—" : [NSString stringWithFormat:@"%ld mA", (long)event.minCurrentmA];
    rows[@"elapsed"].text = event.elapsed >= 0
        ? [NSString stringWithFormat:CLL(@"状态变化耗时 %ds"), (long)event.elapsed]
        : @"—";
}

- (void)updateOverallVerdict {
    BOOL stopTested = self.verdicts[0].integerValue != CLCompatTestVerdictPending;
    BOOL smartTested = self.verdicts[1].integerValue != CLCompatTestVerdictPending;
    BOOL inflowTested = self.verdicts[2].integerValue != CLCompatTestVerdictPending;
    if (!stopTested && !smartTested && !inflowTested) {
        self.overallLabel.text = CLL(@"待测试");
        self.overallLabel.textColor = [UIColor secondaryLabelColor];
        return;
    }
    BOOL stopOK = (self.verdicts[0].integerValue == CLCompatTestVerdictSupported) ||
                  (self.verdicts[1].integerValue == CLCompatTestVerdictSupported);
    BOOL inflowOK = self.verdicts[2].integerValue == CLCompatTestVerdictSupported;
    BOOL smartOnly = self.verdicts[1].integerValue == CLCompatTestVerdictSupported &&
                     self.verdicts[0].integerValue == CLCompatTestVerdictUnsupported;
    // Error 是"测不了"而非"不支持"，只有明确 Unsupported 才能给出不被支持的结论
    BOOL stopUnsupported = self.verdicts[0].integerValue == CLCompatTestVerdictUnsupported ||
                           self.verdicts[1].integerValue == CLCompatTestVerdictUnsupported;
    BOOL inflowUnsupported = self.verdicts[2].integerValue == CLCompatTestVerdictUnsupported;

    NSString *text;
    UIColor *color;
    if (stopOK && inflowOK) {
        text = CLL(@"设备支持 CL 充电控制");
        color = [UIColor systemGreenColor];
    } else if (smartOnly) {
        text = CLL(@"仅智能停充可用，建议开启充电高级-智能停充");
        color = [UIColor systemOrangeColor];
    } else if ((stopTested || smartTested) && stopUnsupported && inflowTested && inflowUnsupported) {
        text = CLL(@"既不支持停充也不支持禁流，设备不被 CL 支持");
        color = [UIColor systemRedColor];
    } else {
        text = CLL(@"部分能力可用，建议结合探针结果判断");
        color = [UIColor systemOrangeColor];
    }
    self.overallLabel.text = text;
    self.overallLabel.textColor = color;
}

- (void)setPrecheckRowsPending {    for (NSString *key in self.precheckRows) {
        UILabel *label = self.precheckRows[key];
        label.text = @"…";
        label.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)applyPrecheckResults:(NSDictionary<NSString *, NSNumber *> *)results {
    NSDictionary<NSString *, NSString *> *failMessages = @{
        @"daemon": CLL(@"daemon 未运行"),
        @"plugged": CLL(@"未插电，请插电后重试"),
        @"charging": CLL(@"当前未在充电，无法测试"),
        @"battery": CLL(@"电量需在 10%–95% 之间"),
    };
    for (NSString *key in self.precheckRows) {
        UILabel *label = self.precheckRows[key];
        BOOL ok = results[key].boolValue;
        label.text = ok ? @"✓" : failMessages[key];
        label.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        // 失败文案较长，放宽右对齐截断
        label.adjustsFontSizeToFitWidth = ok ? YES : NO;
        label.minimumScaleFactor = ok ? 1.0 : 0.7;
        label.numberOfLines = ok ? 1 : 2;
    }
}

- (void)probeButtonTapped {
    if (self.probeRunning || self.engineRunning) {
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:CLL(@"运行停充控制探针")
                                                                     message:CLL(@"将尝试多种停充写法并自动恢复，整轮可能需要 1–2 分钟。请插着充电器运行。")
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:CLL(@"运行") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf runProbe];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)runProbe {
    self.probeRunning = YES;
    self.probeResultLabel.text = CLL(@"运行中…");
    [self updateControlsForRunning:self.engineRunning];
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] runChargeControlProbeWithWaitMs:2000 restore:YES paths:nil services:nil completion:^(NSDictionary * _Nullable resp, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.probeRunning = NO;
            [strongSelf updateControlsForRunning:strongSelf.engineRunning];
            if (error || resp == nil || [resp[@"status"] integerValue] != 0) {
                NSInteger status = resp ? [resp[@"status"] integerValue] : -999;
                strongSelf.lastProbePayload = nil;
                NSString *msg;
                if (status == -12) {
                    msg = CLL(@"探针正在运行，请稍候");
                } else {
                    msg = error.localizedDescription ?: ([resp[@"msg"] description] ?: CLL(@"daemon 未运行"));
                }
                strongSelf.probeResultLabel.text = [NSString stringWithFormat:@"%@: %@", CLL(@"探针失败"), msg];
                return;
            }
            NSDictionary *data = [resp[@"data"] isKindOfClass:[NSDictionary class]] ? resp[@"data"] : nil;
            strongSelf.lastProbePayload = data;
            strongSelf.probeResultLabel.text = [strongSelf probeSummaryFromPayload:data];
        });
    }];
}

- (NSString *)probeSummaryFromPayload:(NSDictionary *)payload {
    if (![payload isKindOfClass:[NSDictionary class]]) return CLL(@"尚无探针结果");
    NSDictionary *summary = [payload[@"summary"] isKindOfClass:[NSDictionary class]] ? payload[@"summary"] : @{};
    if ([summary[@"any_effective"] boolValue]) {
        return [NSString stringWithFormat:CLL(@"探针结论：控制面可生效（best_path: %@）"),
                [summary[@"best_path"] description] ?: @"-"];
    }
    return [NSString stringWithFormat:CLL(@"探针结论：未发现可生效写法（dominant_failure: %@）"),
            [summary[@"dominant_failure"] description] ?: @"-"];
}

- (void)copyProbeDetails {
    if (self.lastProbePayload == nil) {
        [self showSimpleAlert:CLL(@"请先运行停充控制探针。")];
        return;
    }
    NSDictionary *payload = self.lastProbePayload;
    NSDictionary *summary = [payload[@"summary"] isKindOfClass:[NSDictionary class]] ? payload[@"summary"] : @{};
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:CLL(@"停充控制探针结果")];
    [lines addObject:[NSString stringWithFormat:@"device: %@", [payload[@"device"] description] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"sysver: %@", [payload[@"sysver"] description] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"use_smart: %@", [payload[@"use_smart"] description] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"any_effective: %@", [summary[@"any_effective"] description] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"best_path: %@", [summary[@"best_path"] description] ?: @"-"]];
    [lines addObject:[NSString stringWithFormat:@"dominant_failure: %@", [summary[@"dominant_failure"] description] ?: @"-"]];
    NSArray *results = [payload[@"results"] isKindOfClass:[NSArray class]] ? payload[@"results"] : @[];
    for (NSDictionary *item in results) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        [lines addObject:[NSString stringWithFormat:@"- %@ / %@ => %@ (write_ret=%@, prop_changed=%@, current_stopped=%@)",
                          [item[@"service"] description] ?: @"-",
                          [item[@"path"] description] ?: @"-",
                          [item[@"verdict"] description] ?: @"-",
                          [item[@"write_ret"] description] ?: @"-",
                          [item[@"prop_changed"] description] ?: @"-",
                          [item[@"current_stopped"] description] ?: @"-"]];
    }
    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&jsonErr];
    if (jsonData) {
        [lines addObject:@""];
        [lines addObject:[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @""];
    }
    UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
    [self showSimpleAlert:CLL(@"已复制到剪贴板")];
}

@end

NS_ASSUME_NONNULL_END
