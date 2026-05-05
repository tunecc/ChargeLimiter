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
NSString* getConfPath_C(void);
NSArray<NSString*>* getLegacyConfigDirsWithData_C(void);
NSArray<NSString*>* getLegacyResidualFiles_C(void);
NSDictionary* cleanupLegacyResidualFiles_C(void);
NSDictionary* migrateLegacyConfigFiles_C(void);
#import <objc/runtime.h>

#pragma mark - 紧凑型电池状态视图

@interface CLBatteryStatusView : UIView
@property (nonatomic, assign) CGFloat percentage;
@property (nonatomic, assign) BOOL isCharging;
@property (nonatomic, assign) NSInteger chargeBelow;
@property (nonatomic, assign) NSInteger chargeAbove;
@property (nonatomic, assign) BOOL showLowMarker;
@property (nonatomic, strong) NSLayoutConstraint *fillWidthConstraint;
@property (nonatomic, strong) UIView *batteryBody;
@property (nonatomic, strong) UIView *batteryTip;
@property (nonatomic, strong) UIView *batteryInner;
@property (nonatomic, strong) CAGradientLayer *fillGradient;
@property (nonatomic, strong) CAGradientLayer *flowOverlayLayer;
@property (nonatomic, strong) CAGradientLayer *temperatureGlowLayer;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *glossView;
@property (nonatomic, strong) UIView *lowMarker;
@property (nonatomic, strong) UIView *highMarker;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIImageView *chargingIcon;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) NSInteger visualState;
@property (nonatomic, strong) UIColor *fillPrimaryColor;
@property (nonatomic, strong) UIColor *fillSecondaryColor;
@property (nonatomic, strong) UIColor *statusAccentColor;
- (void)applyBatteryManager:(CLBatteryManager *)manager statusText:(NSString *)statusText;
@end

typedef NS_ENUM(NSInteger, CLBatteryVisualState) {
    CLBatteryVisualStateIdleNormal = 0,
    CLBatteryVisualStateCharging,
    CLBatteryVisualStateLowBattery,
    CLBatteryVisualStatePaused,
    CLBatteryVisualStateHold,
    CLBatteryVisualStateHoldRecharge,
    CLBatteryVisualStateTempPaused,
    CLBatteryVisualStateNoInflow
};

#pragma mark - 毛玻璃卡片

@protocol CLChargeSliderEnforcing <NSObject>
- (NSInteger)normalizedChargeValueForSlider:(UISlider *)slider value:(NSInteger)value;
@end

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

static NSString *CLFirstFailedRemovePathFromResult(NSDictionary *result) {
    NSArray *errors = result[@"errors"];
    if (![errors isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (id item in errors) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *line = (NSString *)item;
        NSRange mark = [line rangeOfString:@" remove failed"];
        if (mark.location == NSNotFound) {
            continue;
        }
        NSString *path = [line substringToIndex:mark.location];
        if (path.length == 0) {
            continue;
        }
        return path;
    }
    return nil;
}

static id CLPerformSelectorNoArg(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [target performSelector:selector];
#pragma clang diagnostic pop
}

static NSInteger CLEffectiveBatteryCurrentForManager(CLBatteryManager *manager);
static BOOL CLManagerLooksChargingForDisplay(CLBatteryManager *manager);
static BOOL CLManagerLooksDischargingForDisplay(CLBatteryManager *manager);
static NSString *CLDisplayedPowerStateForManager(CLBatteryManager *manager);
static BOOL CLDisplayedPowerStateUsesExternalPower(CLBatteryManager *manager);

static const void *kCLCardValueTitleKey = &kCLCardValueTitleKey;

static NSArray<NSString *> *CLKnownFilzaBundleIDs(void) {
    return @[
        @"com.tigisoftware.Filza",
        @"com.tigisoftware.Filza64bit",
        @"com.tigisoftware.filza",
        @"com.tigisoftware.filza64bit",
        @"com.filza.filemanager"
    ];
}

static NSArray *CLGetInstalledApplications(void) {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = CLPerformSelectorNoArg(wsClass, NSSelectorFromString(@"defaultWorkspace"));
    for (NSString *selName in @[@"allInstalledApplications", @"allApplications"]) {
        id val = CLPerformSelectorNoArg(workspace, NSSelectorFromString(selName));
        if ([val isKindOfClass:[NSArray class]]) {
            return (NSArray *)val;
        }
    }
    return @[];
}

static BOOL CLCanOpenURLString(NSString *urlString) {
    if (urlString.length == 0) {
        return NO;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return NO;
    }
    return [[UIApplication sharedApplication] canOpenURL:url];
}

static NSArray<NSString *> *CLCollectFilzaInstallHints(void) {
    NSMutableArray<NSString *> *hints = [NSMutableArray array];
    NSArray *apps = CLGetInstalledApplications();
    NSMutableSet<NSString *> *installedBIDs = [NSMutableSet set];
    for (id app in apps) {
        NSString *bid = CLPerformSelectorNoArg(app, NSSelectorFromString(@"bundleIdentifier"));
        NSString *name = CLPerformSelectorNoArg(app, NSSelectorFromString(@"localizedName"));
        if (name.length == 0) {
            name = CLPerformSelectorNoArg(app, NSSelectorFromString(@"itemName"));
        }
        NSString *lower = [NSString stringWithFormat:@"%@ %@", bid ?: @"", name ?: @""].lowercaseString;
        if ([lower containsString:@"filza"]) {
            [hints addObject:[NSString stringWithFormat:@"installed: %@ (%@)", name ?: @"<no-name>", bid ?: @"<no-bid>"]];
            if (bid.length > 0) {
                [installedBIDs addObject:bid];
            }
        }
    }

    for (NSString *knownBid in CLKnownFilzaBundleIDs()) {
        [hints addObject:[NSString stringWithFormat:@"known-bid %@ installed=%@", knownBid, [installedBIDs containsObject:knownBid] ? @"yes" : @"no"]];
    }
    [hints addObject:[NSString stringWithFormat:@"canOpen filza:// = %@", CLCanOpenURLString(@"filza://") ? @"yes" : @"no"]];
    [hints addObject:[NSString stringWithFormat:@"canOpen filzaescaped:// = %@", CLCanOpenURLString(@"filzaescaped://") ? @"yes" : @"no"]];

    // Dedupe
    NSMutableArray<NSString *> *dedup = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *line in hints) {
        if (line.length == 0 || [seen containsObject:line]) {
            continue;
        }
        [seen addObject:line];
        [dedup addObject:line];
    }
    return dedup;
}

static NSString *CLBuildFilzaDebugReport(NSString *targetPath, NSArray<NSURL *> *candidates, NSArray<NSString *> *attemptLogs) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *appDocsPath = getAppDocumentsPath_C() ?: @"";
    NSString *confPath = getConfPath_C() ?: @"";
    BOOL targetIsDir = NO;
    BOOL targetExists = (targetPath.length > 0) && [[NSFileManager defaultManager] fileExistsAtPath:targetPath isDirectory:&targetIsDir];
    BOOL confExists = (confPath.length > 0) && [[NSFileManager defaultManager] fileExistsAtPath:confPath];

    [lines addObject:@"[ChargeLimiter Filza Debug]"];
    [lines addObject:[NSString stringWithFormat:@"bundleID=%@", NSBundle.mainBundle.bundleIdentifier ?: @""]];
    [lines addObject:[NSString stringWithFormat:@"home=%@", NSHomeDirectory() ?: @""]];
    [lines addObject:[NSString stringWithFormat:@"appDocuments=%@", appDocsPath]];
    [lines addObject:[NSString stringWithFormat:@"confPath=%@", confPath]];
    [lines addObject:[NSString stringWithFormat:@"targetPath=%@", targetPath ?: @""]];
    [lines addObject:[NSString stringWithFormat:@"targetExists=%@ isDir=%@", targetExists ? @"yes" : @"no", targetIsDir ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"confExists=%@", confExists ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"canOpen(filza://)=%@", CLCanOpenURLString(@"filza://") ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"canOpen(filzaescaped://)=%@", CLCanOpenURLString(@"filzaescaped://") ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"candidateCount=%lu", (unsigned long)candidates.count]];
    for (NSUInteger i = 0; i < candidates.count; i++) {
        NSURL *u = candidates[i];
        NSString *result = (i < attemptLogs.count) ? attemptLogs[i] : @"not-tried";
        [lines addObject:[NSString stringWithFormat:@"[%lu] %@ => %@", (unsigned long)i, u.absoluteString ?: @"<nil>", result]];
    }

    NSArray<NSString *> *hints = CLCollectFilzaInstallHints();
    if (hints.count == 0) {
        [lines addObject:@"filzaHints=none"];
    } else {
        [lines addObject:@"filzaHints:"];
        for (NSString *hint in hints) {
            [lines addObject:[NSString stringWithFormat:@"- %@", hint]];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

static void CLPresentFilzaOpenedWithoutPathAlert(UIViewController *vc, NSString *targetPath) {
    if (!vc) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"已打开 Filza")
                                                                   message:CLL(@"当前 Filza 版本未接受目录直达 URL，已复制路径，请在 Filza 中粘贴后前往。")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
    [UIPasteboard generalPasteboard].string = targetPath ?: @"";
}

static void CLPresentFilzaFailureAlert(UIViewController *vc, NSString *targetPath, NSArray<NSURL *> *candidates, NSArray<NSString *> *attemptLogs) {
    if (!vc) {
        return;
    }
    NSString *debugInfo = CLBuildFilzaDebugReport(targetPath, candidates, attemptLogs);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"未检测到 Filza")
                                                                   message:CLL(@"请先安装 Filza 文件管理器，再重试跳转。")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"复制路径")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = targetPath ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"复制调试信息")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = debugInfo ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void CLOpenPathInFilza(UIViewController *vc, NSString *path) {
    if (path.length == 0 || vc == nil) {
        return;
    }

    NSString *pathA = path;
    NSString *pathB = pathA;
    if ([pathB hasPrefix:@"/private/var/"]) {
        pathB = [@"/var/" stringByAppendingString:[pathB substringFromIndex:@"/private/var/".length]];
    }

    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    NSArray<NSString *> *schemes = @[@"filza", @"filzaescaped"];
    for (NSString *p in @[pathA ?: @"", pathB ?: @""]) {
        if (p.length == 0) continue;
        NSString *encodedPath = [p stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        if (encodedPath.length == 0) continue;
        NSString *queryEncodedPath = [p stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *fileURLPath = [NSString stringWithFormat:@"file://%@", p];
        NSString *queryEncodedFileURLPath = [fileURLPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *withTrailingSlash = [p hasSuffix:@"/"] ? p : [p stringByAppendingString:@"/"];
        NSString *queryEncodedTrailing = [withTrailingSlash stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        for (NSString *scheme in schemes) {
            NSURL *u1 = [NSURL URLWithString:[NSString stringWithFormat:@"%@://view%@", scheme, encodedPath]];
            NSURL *u2 = [NSURL URLWithString:[NSString stringWithFormat:@"%@://view?path=%@", scheme, encodedPath]];
            NSURL *u3 = [NSURL URLWithString:[NSString stringWithFormat:@"%@://view?path=%@", scheme, queryEncodedPath ?: encodedPath]];
            NSURL *u4 = [NSURL URLWithString:[NSString stringWithFormat:@"%@://view?path=%@", scheme, queryEncodedFileURLPath ?: @""]];
            NSURL *u5 = [NSURL URLWithString:[NSString stringWithFormat:@"%@://view?path=%@", scheme, queryEncodedTrailing ?: queryEncodedPath ?: encodedPath]];
            if (u1) [candidates addObject:u1];
            if (u2) [candidates addObject:u2];
            if (u3) [candidates addObject:u3];
            if (u4) [candidates addObject:u4];
            if (u5) [candidates addObject:u5];
        }
    }

    // Dedupe deep-link candidates first.
    NSMutableArray<NSURL *> *deduped = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSURL *u in candidates) {
        NSString *abs = u.absoluteString ?: @"";
        if (abs.length == 0 || [seen containsObject:abs]) {
            continue;
        }
        [seen addObject:abs];
        [deduped addObject:u];
    }
    candidates = deduped;
    NSUInteger deepLinkCount = candidates.count;

    for (NSString *scheme in schemes) {
        NSURL *probe1 = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", scheme]];
        NSURL *probe2 = [NSURL URLWithString:[NSString stringWithFormat:@"%@://view", scheme]];
        if (probe1) [candidates addObject:probe1];
        if (probe2) [candidates addObject:probe2];
    }

    // Dedupe again after adding probes.
    deduped = [NSMutableArray array];
    seen = [NSMutableSet set];
    for (NSURL *u in candidates) {
        NSString *abs = u.absoluteString ?: @"";
        if (abs.length == 0 || [seen containsObject:abs]) {
            continue;
        }
        [seen addObject:abs];
        [deduped addObject:u];
    }
    candidates = deduped;

    if (candidates.count == 0) {
        CLPresentFilzaFailureAlert(vc, path, candidates, @[]);
        return;
    }

    __weak UIViewController *weakVC = vc;
    __block NSUInteger idx = 0;
    __block NSMutableArray<NSString *> *attemptLogs = [NSMutableArray array];
    __block void (^tryOpen)(void) = nil;
    tryOpen = ^{
        if (idx >= candidates.count) {
            CLPresentFilzaFailureAlert(weakVC, path, candidates, attemptLogs);
            tryOpen = nil;
            return;
        }

        NSURL *url = candidates[idx++];
        __block BOOL handled = NO;
        void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *source) {
            if (handled) {
                return;
            }
            handled = YES;
            [attemptLogs addObject:[NSString stringWithFormat:@"%@ (%@)", success ? @"ok" : @"fail", source ?: @""]];
            if (success) {
                NSUInteger succeededIndex = idx - 1;
                if (succeededIndex >= deepLinkCount) {
                    CLPresentFilzaOpenedWithoutPathAlert(weakVC, path);
                }
                tryOpen = nil;
                return;
            }
            if (tryOpen) {
                tryOpen();
            }
        };

        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                finish(success, @"completion");
            });
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(700 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (!handled) {
                finish(NO, @"timeout");
            }
        });
    };
    tryOpen();
}

static NSString *CLNumberedLegacyDirsText(NSArray<NSString *> *dirs) {
    if (![dirs isKindOfClass:[NSArray class]] || dirs.count == 0) {
        return @"";
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:dirs.count];
    [dirs enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (![obj isKindOfClass:[NSString class]] || obj.length == 0) {
            return;
        }
        [lines addObject:[NSString stringWithFormat:@"%lu. %@", (unsigned long)(idx + 1), obj]];
    }];
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *CLNumberedPathsText(NSArray<NSString *> *paths) {
    if (![paths isKindOfClass:[NSArray class]] || paths.count == 0) {
        return @"";
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:paths.count];
    [paths enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (![obj isKindOfClass:[NSString class]] || obj.length == 0) {
            return;
        }
        [lines addObject:[NSString stringWithFormat:@"%lu. %@", (unsigned long)(idx + 1), obj]];
    }];
    return [lines componentsJoinedByString:@"\n"];
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
    objc_setAssociatedObject(valueLabel, kCLCardValueTitleKey, title, OBJC_ASSOCIATION_COPY_NONATOMIC);
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
    [slider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    
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
    UISlider *slider = objc_getAssociatedObject(self, "adjustingSlider");
    objc_setAssociatedObject(self, "adjustTimer", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, "adjustingSlider", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, "adjustAmount", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 触发最终的 onChange
    if (slider) {
        [self sliderEnded:slider];
    }
}

- (void)adjustSlider:(UISlider *)slider byAmount:(NSInteger)amount {
    NSInteger newValue = (NSInteger)roundf(slider.value) + amount;
    newValue = MAX(slider.minimumValue, MIN(slider.maximumValue, newValue));
    id<CLChargeSliderEnforcing> vc = (id)self.viewController;
    if ([vc respondsToSelector:@selector(normalizedChargeValueForSlider:value:)]) {
        newValue = [vc normalizedChargeValueForSlider:slider value:newValue];
    }
    
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
        id<CLChargeSliderEnforcing> vc = (id)self.viewController;
        if ([vc respondsToSelector:@selector(normalizedChargeValueForSlider:value:)]) {
            inputValue = [vc normalizedChargeValueForSlider:slider value:inputValue];
        }
        
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
    id<CLChargeSliderEnforcing> vc = (id)self.viewController;
    if ([vc respondsToSelector:@selector(normalizedChargeValueForSlider:value:)]) {
        NSInteger normalized = [vc normalizedChargeValueForSlider:sender value:value];
        if (normalized != value) {
            value = normalized;
            sender.value = value;
        }
    }
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
    id<CLChargeSliderEnforcing> vc = (id)self.viewController;
    if ([vc respondsToSelector:@selector(normalizedChargeValueForSlider:value:)]) {
        value = [vc normalizedChargeValueForSlider:sender value:value];
    }
    sender.value = value;
    UILabel *valueLabel = objc_getAssociatedObject(sender, "valueLabel");
    NSString *suffix = objc_getAssociatedObject(sender, "suffix") ?: @"%";
    valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)value, suffix];
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
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    valueLabel.textColor = [UIColor secondaryLabelColor];
    valueLabel.tag = [title hash];
    objc_setAssociatedObject(valueLabel, kCLCardValueTitleKey, title, OBJC_ASSOCIATION_COPY_NONATOMIC);
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
    CGFloat hairline = 1.0 / UIScreen.mainScreen.scale;
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    
    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor separatorColor];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:separator];
    
    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintEqualToConstant:hairline],
        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:50],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:hairline],
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

static NSString *CLHistoryPolicyStateLabel(NSString *policyState) {
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

static NSString *CLHistoryPolicyReasonLabel(NSString *reason) {
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
    if ([reason isEqualToString:@"hold_discharge_trend"]) {
        return CLL(@"检测到持续放电趋势，提前补电");
    }
    if ([reason isEqualToString:@"hold_monitoring"]) {
        return CLL(@"保持区间内观察中");
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
        return CLL(@"边缘触发模式下插电后保持停充");
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
    if ([reason isEqualToString:@"hold_behavior_changed"]) {
        return CLL(@"自适应判断负载变化，已切换当前生效保持策略");
    }
    return CLL(@"未知");
}

static NSString *CLHistoryAdaptiveLoadLevelLabel(NSString *loadLevel) {
    if ([loadLevel isEqualToString:@"high"]) {
        return CLL(@"高负载");
    }
    if ([loadLevel isEqualToString:@"medium"]) {
        return CLL(@"中负载");
    }
    if ([loadLevel isEqualToString:@"low"]) {
        return CLL(@"低负载");
    }
    if ([loadLevel isEqualToString:@"thermal_guard"]) {
        return CLL(@"温控保护");
    }
    if ([loadLevel isEqualToString:@"wireless_guard"]) {
        return CLL(@"无线充保护");
    }
    if ([loadLevel isEqualToString:@"fixed"]) {
        return CLL(@"固定策略");
    }
    return CLL(@"未知");
}

static NSString *CLHistoryHoldBehaviorLabel(NSString *behavior) {
    if ([behavior isEqualToString:@"power_first"]) {
        return CLL(@"偏向外接供电");
    }
    if ([behavior isEqualToString:@"battery_first"]) {
        return CLL(@"偏向减少循环");
    }
    if ([behavior isEqualToString:@"adaptive"]) {
        return CLL(@"智能自适应");
    }
    if ([behavior isEqualToString:@"balanced"]) {
        return CLL(@"平衡");
    }
    return CLL(@"未知");
}

static NSString *CLHistorySmartChargeStatusLabel(NSInteger status, BOOL managedByDaemon) {
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

static NSString *CLHistoryEventTimestampLabel(NSTimeInterval timestamp) {
    if (timestamp <= 0) {
        return @"--";
    }
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm";
    });
    formatter.locale = NSLocale.autoupdatingCurrentLocale;
    formatter.timeZone = NSTimeZone.localTimeZone;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

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
@property (nonatomic, strong) CLGlassCard *eventCard;
@property (nonatomic, strong) CLHistoryChartView *chartView;
@property (nonatomic, strong) UILabel *pageLabel;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIStackView *legendStack;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyMin5;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyHour;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyDay;
@property (nonatomic, strong) NSArray<NSDictionary *> *historyMonth;
@property (nonatomic, strong) NSArray<NSDictionary *> *policyEventHistory;
@property (nonatomic, assign) NSInteger policyEventLastID;
@property (nonatomic, assign) NSInteger policyEventFilterIndex;
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
    [self.mainStack setCustomSpacing:10 afterView:titleLabel];
    
    self.segmentControl = [[UISegmentedControl alloc] initWithItems:@[CLL(@"5分钟"), CLL(@"小时"), CLL(@"天"), CLL(@"月")]];
    self.segmentControl.selectedSegmentIndex = 0;
    self.segmentControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.segmentControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.mainStack addArrangedSubview:self.segmentControl];
    [self.mainStack setCustomSpacing:12 afterView:self.segmentControl];
    
    self.hintCard = [[CLGlassCard alloc] init];
    [self setupHintCard];
    [self.mainStack addArrangedSubview:self.hintCard];
    [self.mainStack setCustomSpacing:12 afterView:self.hintCard];
    
    self.tableCard = [[CLGlassCard alloc] init];
    [self setupChartCard];
    [self.mainStack addArrangedSubview:self.tableCard];
    [self.mainStack setCustomSpacing:12 afterView:self.tableCard];

    self.eventCard = [[CLGlassCard alloc] init];
    [self.mainStack addArrangedSubview:self.eventCard];
    
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
    [self updateHistoryTableAnimated:YES];
}

- (void)ampTapped {
    self.showAmperage = !self.showAmperage;
    [self updateToggleButtons];
    [self updateHistoryTableAnimated:YES];
}

- (void)voltTapped {
    self.showVoltage = !self.showVoltage;
    [self updateToggleButtons];
    [self updateHistoryTableAnimated:YES];
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

- (NSArray<NSDictionary *> *)currentVisibleHistoryData {
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    return [self visibleDataForSegment:idx
                                  data:[self dataForSegment:idx]
                                offset:[self offsetForSegment:idx]
                                window:[self windowSizeForSegment:idx]];
}

- (void)rebuildPolicyEventCardForCurrentSelection {
    [self rebuildPolicyEventCardForVisibleData:[self currentVisibleHistoryData]
                                      segment:self.segmentControl.selectedSegmentIndex];
}

- (void)policyEventFilterChanged:(UISegmentedControl *)sender {
    self.policyEventFilterIndex = sender.selectedSegmentIndex;
    [self rebuildPolicyEventCardForCurrentSelection];
}

- (void)refreshHistoryData {
    [self refreshPolicyEventHistory];
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

- (void)refreshPolicyEventHistory {
    BOOL isInitial = (self.policyEventHistory.count == 0);
    NSInteger limit = isInitial ? 5000 : 500;
    NSInteger lastID = isInitial ? 0 : self.policyEventLastID;
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] getPolicyEventsWithLimit:limit lastID:lastID completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
        if (error || response == nil || [response[@"status"] intValue] != 0) {
            [weakSelf rebuildPolicyEventCardForCurrentSelection];
            return;
        }
        NSArray *eventHistory = [response[@"data"] isKindOfClass:[NSArray class]] ? response[@"data"] : @[];
        if (isInitial) {
            weakSelf.policyEventHistory = eventHistory;
        } else {
            weakSelf.policyEventHistory = [weakSelf appendPolicyEvents:weakSelf.policyEventHistory withNew:eventHistory];
        }
        weakSelf.policyEventLastID = [weakSelf lastPolicyEventID];
        [weakSelf rebuildPolicyEventCardForCurrentSelection];
    }];
}

- (NSInteger)lastPolicyEventID {
    id value = self.policyEventHistory.lastObject[@"id"];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

- (NSArray<NSDictionary *> *)appendPolicyEvents:(NSArray<NSDictionary *> *)base withNew:(NSArray<NSDictionary *> *)incoming {
    if (incoming.count == 0) {
        return base ?: @[];
    }
    if (base.count == 0) {
        return incoming;
    }
    NSMutableArray<NSDictionary *> *merged = [base mutableCopy];
    NSInteger lastID = [self lastPolicyEventID];
    for (NSDictionary *item in incoming) {
        NSInteger eventID = [item[@"id"] integerValue];
        if (eventID <= lastID) {
            continue;
        }
        [merged addObject:item];
    }
    return merged;
}

- (NSString *)policyEventRangeTextForVisibleData:(NSArray<NSDictionary *> *)visible segment:(NSInteger)segment {
    if (visible.count == 0) {
        return CLL(@"暂无数据");
    }
    NSTimeInterval startTs = [visible.firstObject[@"UpdateTime"] doubleValue];
    NSTimeInterval endTs = [visible.lastObject[@"UpdateTime"] doubleValue];
    NSString *startText = [self formatHistoryTime:@(startTs) style:(segment >= 2 ? @"day" : @"time")];
    NSString *endText = [self formatHistoryTime:@(endTs) style:(segment >= 2 ? @"day" : @"time")];
    if (segment == 1) {
        startText = CLHistoryEventTimestampLabel(startTs);
        endText = CLHistoryEventTimestampLabel(endTs);
    } else if (segment == 2) {
        startText = [self formatHistoryTime:@(startTs) style:@"day"];
        endText = [self formatHistoryTime:@(endTs) style:@"day"];
    } else if (segment == 3) {
        startText = [self formatHistoryTime:@(startTs) style:@"month"];
        endText = [self formatHistoryTime:@(endTs) style:@"month"];
    }
    if (startText.length == 0 || endText.length == 0) {
        return CLL(@"暂无数据");
    }
    return [NSString stringWithFormat:@"%@ - %@", startText, endText];
}

- (NSInteger)policyEventCategoryForItem:(NSDictionary *)item {
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"policy_transition";
    if ([type isEqualToString:@"smart_charge_event"]) {
        return 3;
    }
    if ([type isEqualToString:@"thermal_event"]) {
        return 4;
    }
    if ([type isEqualToString:@"hold_event"] || [type isEqualToString:@"hold_behavior_event"]) {
        return 2;
    }
    return 1;
}

- (BOOL)policyEventMatchesCurrentFilter:(NSDictionary *)item {
    NSInteger filterIndex = self.policyEventFilterIndex;
    if (filterIndex <= 0) {
        return YES;
    }
    return [self policyEventCategoryForItem:item] == filterIndex;
}

- (NSArray<NSDictionary *> *)policyEventSourceForCurrentFilter {
    NSArray<NSDictionary *> *source = self.policyEventHistory ?: @[];
    if (source.count == 0 || self.policyEventFilterIndex <= 0) {
        return source;
    }
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (NSDictionary *item in source) {
        if ([self policyEventMatchesCurrentFilter:item]) {
            [filtered addObject:item];
        }
    }
    return filtered;
}

- (NSArray<NSDictionary *> *)policyEventsForVisibleData:(NSArray<NSDictionary *> *)visible fallbackUsed:(BOOL *)fallbackUsed {
    if (fallbackUsed) {
        *fallbackUsed = NO;
    }
    NSArray<NSDictionary *> *source = [self policyEventSourceForCurrentFilter];
    if (source.count == 0) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    if (visible.count > 0) {
        NSTimeInterval startTs = [visible.firstObject[@"UpdateTime"] doubleValue];
        NSTimeInterval endTs = [visible.lastObject[@"UpdateTime"] doubleValue];
        if (startTs > 0 && endTs > 0) {
            for (NSDictionary *item in source) {
                NSTimeInterval ts = [item[@"ts"] doubleValue];
                if (ts >= startTs && ts <= endTs) {
                    [filtered addObject:item];
                }
            }
        }
    }

    NSArray<NSDictionary *> *display = filtered;
    if (display.count == 0) {
        if (fallbackUsed) {
            *fallbackUsed = YES;
        }
        NSInteger limit = MIN((NSInteger)source.count, 8);
        if (limit <= 0) {
            return @[];
        }
        NSRange range = NSMakeRange(source.count - limit, limit);
        display = [source subarrayWithRange:range];
    }

    return [[display reverseObjectEnumerator] allObjects];
}

- (NSString *)policyEventTypeLabelForItem:(NSDictionary *)item {
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"policy_transition";
    if ([type isEqualToString:@"smart_charge_event"]) {
        return CLL(@"接管");
    }
    if ([type isEqualToString:@"thermal_event"]) {
        return CLL(@"温控");
    }
    if ([type isEqualToString:@"hold_behavior_event"]) {
        return CLL(@"策略");
    }
    if ([type isEqualToString:@"hold_event"]) {
        return CLL(@"保持");
    }
    return CLL(@"状态");
}

- (NSString *)policyEventIconNameForItem:(NSDictionary *)item {
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"policy_transition";
    if ([type isEqualToString:@"smart_charge_event"]) {
        return @"battery.100.circle";
    }
    if ([type isEqualToString:@"thermal_event"]) {
        return @"thermometer.medium";
    }
    if ([type isEqualToString:@"hold_behavior_event"]) {
        return @"slider.horizontal.3";
    }
    if ([type isEqualToString:@"hold_event"]) {
        return @"arrow.triangle.2.circlepath";
    }
    return @"list.bullet.rectangle";
}

- (UIColor *)policyEventTintColorForItem:(NSDictionary *)item {
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"policy_transition";
    if ([type isEqualToString:@"smart_charge_event"]) {
        return [UIColor systemBlueColor];
    }
    if ([type isEqualToString:@"thermal_event"]) {
        return [UIColor systemOrangeColor];
    }
    if ([type isEqualToString:@"hold_behavior_event"]) {
        return [UIColor systemIndigoColor];
    }
    if ([type isEqualToString:@"hold_event"]) {
        return [UIColor systemGreenColor];
    }
    return [UIColor systemPurpleColor];
}

- (NSString *)policyEventDisplayTextForItem:(NSDictionary *)item {
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"policy_transition";
    if ([type isEqualToString:@"smart_charge_event"]) {
        NSInteger fromStatus = [item[@"smart_charge_from"] integerValue];
        NSInteger toStatus = [item[@"smart_charge_to"] integerValue];
        NSString *fromLabel = CLHistorySmartChargeStatusLabel(fromStatus, fromStatus == 3);
        NSString *toLabel = CLHistorySmartChargeStatusLabel(toStatus, toStatus == 3);
        NSString *resolvedLabel = toLabel.length > 0 ? toLabel : fromLabel;
        if (fromLabel.length > 0 && toLabel.length > 0 && fromStatus != toStatus) {
            return [NSString stringWithFormat:@"%@  %@ -> %@", CLL(@"系统优化充电"), fromLabel, toLabel];
        }
        return [NSString stringWithFormat:@"%@  %@", CLL(@"系统优化充电"), resolvedLabel.length > 0 ? resolvedLabel : CLL(@"未知")];
    }
    if ([type isEqualToString:@"hold_behavior_event"]) {
        NSString *fromBehavior = CLHistoryHoldBehaviorLabel([item[@"from"] isKindOfClass:[NSString class]] ? item[@"from"] : @"");
        NSString *toBehavior = CLHistoryHoldBehaviorLabel([item[@"to"] isKindOfClass:[NSString class]] ? item[@"to"] : @"");
        if (fromBehavior.length > 0 && toBehavior.length > 0 && ![fromBehavior isEqualToString:toBehavior]) {
            return [NSString stringWithFormat:@"%@  %@ -> %@", CLL(@"保持策略"), fromBehavior, toBehavior];
        }
        return [NSString stringWithFormat:@"%@  %@", CLL(@"保持策略"), toBehavior.length > 0 ? toBehavior : CLL(@"未知")];
    }
    NSString *fromState = [item[@"from"] isKindOfClass:[NSString class]] ? item[@"from"] : @"";
    NSString *toState = [item[@"to"] isKindOfClass:[NSString class]] ? item[@"to"] : @"";
    NSString *toLabel = CLHistoryPolicyStateLabel(toState);
    if (fromState.length > 0 && ![fromState isEqualToString:toState]) {
        return [NSString stringWithFormat:@"%@ -> %@", CLHistoryPolicyStateLabel(fromState), toLabel];
    }
    return toLabel;
}

- (NSString *)policyEventTitleForItem:(NSDictionary *)item {
    return [NSString stringWithFormat:@"%@  [%@] %@",
            CLHistoryEventTimestampLabel([item[@"ts"] doubleValue]),
            [self policyEventTypeLabelForItem:item],
            [self policyEventDisplayTextForItem:item]];
}

- (NSString *)policyEventDetailForItem:(NSDictionary *)item {
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"policy_transition";
    NSString *reason = [item[@"reason"] isKindOfClass:[NSString class]] ? item[@"reason"] : @"unknown";
    [segments addObject:CLHistoryPolicyReasonLabel(reason)];

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

    NSString *loadLevel = [item[@"hold_load_level"] isKindOfClass:[NSString class]] ? item[@"hold_load_level"] : @"";
    if (loadLevel.length > 0 && ![loadLevel isEqualToString:@"fixed"]) {
        [segments addObject:CLHistoryAdaptiveLoadLevelLabel(loadLevel)];
    }

    NSInteger smartChargeStatus = [item[@"smart_charge_status"] integerValue];
    BOOL smartChargeManaged = [item[@"smart_charge_managed"] boolValue];
    if (![type isEqualToString:@"smart_charge_event"] && (smartChargeManaged || smartChargeStatus == 3)) {
        [segments addObject:CLHistorySmartChargeStatusLabel(smartChargeStatus, smartChargeManaged)];
    }

    return [segments componentsJoinedByString:@" · "];
}

- (UIView *)policyEventFilterRow {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[
        CLL(@"全部"),
        CLL(@"状态"),
        CLL(@"保持"),
        CLL(@"接管"),
        CLL(@"温控")
    ]];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    control.selectedSegmentIndex = MAX(0, MIN(self.policyEventFilterIndex, (NSInteger)control.numberOfSegments - 1));
    control.selectedSegmentTintColor = [UIColor systemBlueColor];
    [control setTitleTextAttributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor labelColor]
    } forState:UIControlStateNormal];
    [control setTitleTextAttributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    } forState:UIControlStateSelected];
    [control addTarget:self action:@selector(policyEventFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:control];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44],
        [control.topAnchor constraintEqualToAnchor:row.topAnchor constant:6],
        [control.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-6],
        [control.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [control.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16]
    ]];
    return row;
}

- (UIView *)policyEventInfoRowWithText:(NSString *)text {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor secondaryLabelColor];
    iconView.image = CLSymbolImage(@"clock", [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium]);
    [row addSubview:iconView];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text ?: @"";
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 2;
    [row addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:38],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [iconView.widthAnchor constraintEqualToConstant:18],
        [iconView.heightAnchor constraintEqualToConstant:18],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
        [label.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16]
    ]];

    return row;
}

- (UIView *)policyEventRowWithItem:(NSDictionary *)item {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [self policyEventTintColorForItem:item];
    iconView.image = CLSymbolImage([self policyEventIconNameForItem:item], [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]);
    [row addSubview:iconView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = [self policyEventTitleForItem:item];
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.numberOfLines = 2;
    [row addSubview:titleLabel];

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.text = [self policyEventDetailForItem:item];
    detailLabel.font = [UIFont systemFontOfSize:12];
    detailLabel.textColor = [UIColor secondaryLabelColor];
    detailLabel.numberOfLines = 0;
    [row addSubview:detailLabel];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:56],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:row.topAnchor constant:14],
        [iconView.widthAnchor constraintEqualToConstant:20],
        [iconView.heightAnchor constraintEqualToConstant:20],
        [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [titleLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [detailLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [detailLabel.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10]
    ]];

    return row;
}

- (void)rebuildPolicyEventCardForVisibleData:(NSArray<NSDictionary *> *)visible segment:(NSInteger)segment {
    if (self.eventCard == nil) {
        return;
    }
    for (UIView *view in self.eventCard.contentStack.arrangedSubviews) {
        [self.eventCard.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    BOOL fallbackUsed = NO;
    NSArray<NSDictionary *> *events = [self policyEventsForVisibleData:visible fallbackUsed:&fallbackUsed];
    UIView *header = [self historyCardHeaderWithTitle:CLL(@"策略事件时间线") count:events.count];
    [self.eventCard.contentStack addArrangedSubview:header];
    [self.eventCard addSeparator];
    [self.eventCard.contentStack addArrangedSubview:[self policyEventFilterRow]];
    [self.eventCard addSeparator];

    NSString *rangeText = [self policyEventRangeTextForVisibleData:visible segment:segment];
    NSString *infoText = nil;
    if (visible.count == 0 && events.count > 0) {
        infoText = [NSString stringWithFormat:CLL(@"当前暂无历史曲线数据，已显示最近 %ld 条持久化事件"), (long)events.count];
    } else if (events.count == 0) {
        infoText = [NSString stringWithFormat:CLL(@"当前页时间范围 %@ · 暂无策略事件"), rangeText];
    } else if (fallbackUsed) {
        infoText = [NSString stringWithFormat:CLL(@"当前页时间范围 %@ · 当前页无匹配事件，已显示最近 %ld 条持久化事件"),
                    rangeText,
                    (long)events.count];
    } else {
        infoText = [NSString stringWithFormat:CLL(@"当前页时间范围 %@ · 共 %ld 条策略事件"),
                    rangeText,
                    (long)events.count];
    }
    [self.eventCard.contentStack addArrangedSubview:[self policyEventInfoRowWithText:infoText]];

    if (events.count == 0) {
        [self.eventCard addSeparator];
        [self.eventCard.contentStack addArrangedSubview:[self historyRowWithValues:@[CLL(@"暂无数据")] header:NO]];
        return;
    }

    [self.eventCard addSeparator];
    for (NSUInteger i = 0; i < events.count; i++) {
        UIView *row = [self policyEventRowWithItem:events[i]];
        if (i % 2 == 1) {
            row.backgroundColor = [[UIColor secondarySystemGroupedBackgroundColor] colorWithAlphaComponent:0.5];
        }
        [self.eventCard.contentStack addArrangedSubview:row];
        if (i < events.count - 1) {
            [self.eventCard addSeparator];
        }
    }
}

- (void)updateHistoryTable {
    [self updateHistoryTableAnimated:NO];
}

- (void)updateHistoryTableAnimated:(BOOL)animated {
    if (animated) {
        [UIView transitionWithView:self.chartView duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction animations:^{
            [self updateHistoryTableInternal];
        } completion:nil];
    } else {
        [self updateHistoryTableInternal];
    }
}

- (void)updateHistoryTableInternal {
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
    [self rebuildPolicyEventCardForVisibleData:visible segment:idx];
}

- (void)prevPage {
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    NSInteger offset = [self offsetForSegment:idx];
    NSInteger maxOffset = [self maxOffsetForSegment:idx totalCount:[self dataForSegment:idx].count window:[self windowSizeForSegment:idx]];
    if (offset < maxOffset) {
        [self setOffset:offset + 1 forSegment:idx];
        [self updateHistoryTableAnimated:YES];
    }
}

- (void)nextPage {
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    NSInteger offset = [self offsetForSegment:idx];
    if (offset > 0) {
        [self setOffset:offset - 1 forSegment:idx];
        [self updateHistoryTableAnimated:YES];
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

typedef NS_ENUM(NSInteger, CLUpdateCheckState) {
    CLUpdateCheckStateUnknown = 0,
    CLUpdateCheckStateChecking,
    CLUpdateCheckStateUpToDate,
    CLUpdateCheckStateUpdateAvailable,
    CLUpdateCheckStateFailed,
};

typedef void (^CLUpdateReleaseFetchCompletion)(NSString *latestVersion,
                                               NSString *releaseURLString,
                                               NSString *releaseNotes,
                                               NSString *errorMessage);

static NSString * const CLUpdateCheckStatusDidChangeNotification = @"CLUpdateCheckStatusDidChangeNotification";
static NSString * const CLUpdateCheckLastDateKey = @"CLUpdateCheckLastDate";
static NSString * const CLUpdateCheckLatestVersionKey = @"CLUpdateCheckLatestVersion";
static NSString * const CLUpdateCheckLatestURLKey = @"CLUpdateCheckLatestURL";
static NSString * const CLUpdateCheckLatestNotesKey = @"CLUpdateCheckLatestNotes";
static NSString * const CLUpdateCheckLastErrorKey = @"CLUpdateCheckLastError";
static NSString * const CLUpdateCheckStateKey = @"CLUpdateCheckState";
static NSString * const CLUpdateCheckLastAlertedVersionKey = @"CLUpdateCheckLastAlertedVersion";
static NSString * const CLUpdateCheckAPIURLString = @"https://api.github.com/repos/tunecc/ChargeLimiter/releases/latest";
static NSString * const CLUpdateCheckFallbackReleaseURLString = @"https://github.com/tunecc/ChargeLimiter/releases/latest";
static NSTimeInterval const CLUpdateCheckAutoInterval = 24 * 60 * 60;
static NSTimeInterval const CLUpdateCheckFailureRetryInterval = 15 * 60;

static NSString *CLCurrentAppVersion(void) {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version isKindOfClass:[NSString class]]) {
        return @"";
    }
    return version;
}

static NSString *CLNormalizeVersionString(NSString *version) {
    if (![version isKindOfClass:[NSString class]]) {
        return @"";
    }
    NSString *trimmed = [version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasPrefix:@"v"] || [trimmed hasPrefix:@"V"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    return trimmed;
}

static NSComparisonResult CLCompareVersionStrings(NSString *lhs, NSString *rhs) {
    NSString *normalizedLHS = CLNormalizeVersionString(lhs);
    NSString *normalizedRHS = CLNormalizeVersionString(rhs);
    return [normalizedLHS compare:normalizedRHS options:NSNumericSearch];
}

static NSString *CLCompactReleaseNotes(NSString *notes) {
    if (![notes isKindOfClass:[NSString class]]) {
        return @"";
    }
    NSArray<NSString *> *lines = [notes componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSUInteger totalLength = 0;
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }
        [kept addObject:trimmed];
        totalLength += trimmed.length;
        if (kept.count >= 6 || totalLength >= 260) {
            break;
        }
    }
    NSString *summary = [kept componentsJoinedByString:@"\n"];
    if (summary.length > 320) {
        summary = [[summary substringToIndex:320] stringByAppendingString:@"…"];
    }
    return summary;
}

static NSString *CLGitHubReleaseVersionFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return @"";
    }
    NSString *host = [url.host.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (host.length == 0 || [host rangeOfString:@"github.com"].location == NSNotFound) {
        return @"";
    }

    NSArray<NSString *> *pathComponents = url.pathComponents ?: @[];
    NSUInteger tagIndex = [pathComponents indexOfObject:@"tag"];
    if (tagIndex == NSNotFound || tagIndex + 1 >= pathComponents.count) {
        return @"";
    }

    return CLNormalizeVersionString(pathComponents[tagIndex + 1]);
}

static NSString *CLCombineUpdateCheckErrorMessages(NSString *primary, NSString *secondary) {
    NSString *trimmedPrimary = [primary isKindOfClass:[NSString class]]
        ? [primary stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    NSString *trimmedSecondary = [secondary isKindOfClass:[NSString class]]
        ? [secondary stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";

    if (trimmedPrimary.length == 0) {
        return trimmedSecondary;
    }
    if (trimmedSecondary.length == 0 || [trimmedPrimary isEqualToString:trimmedSecondary]) {
        return trimmedPrimary;
    }
    return [NSString stringWithFormat:@"%@\n%@", trimmedPrimary, trimmedSecondary];
}

static UIWindow *CLActiveKeyWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive &&
                windowScene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }
    return application.keyWindow;
}

static UIViewController *CLVisibleViewControllerFromRoot(UIViewController *rootViewController) {
    UIViewController *current = rootViewController;
    while (current) {
        if ([current isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)current;
            current = nav.visibleViewController ?: nav.topViewController ?: current;
            continue;
        }
        if ([current isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tab = (UITabBarController *)current;
            current = tab.selectedViewController ?: current;
            continue;
        }
        if (current.presentedViewController && ![current.presentedViewController isKindOfClass:[UIAlertController class]]) {
            current = current.presentedViewController;
            continue;
        }
        break;
    }
    return current;
}

static UIViewController *CLTopVisibleViewController(void) {
    UIWindow *window = CLActiveKeyWindow();
    if (!window) {
        return nil;
    }
    return CLVisibleViewControllerFromRoot(window.rootViewController);
}

@interface CLUpdateCheckManager : NSObject
@property (nonatomic, assign, readonly) CLUpdateCheckState state;
+ (instancetype)sharedManager;
- (NSString *)statusText;
- (void)performAutomaticCheck;
- (void)performManualCheckFromPresenter:(UIViewController *)presenter;
- (void)presentPendingAlertIfNeeded;
@end

@interface CLUpdateCheckManager ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign, readwrite) CLUpdateCheckState state;
@property (nonatomic, strong) NSDate *lastCheckDate;
@property (nonatomic, copy) NSString *latestVersion;
@property (nonatomic, copy) NSString *latestReleaseURLString;
@property (nonatomic, copy) NSString *latestReleaseNotes;
@property (nonatomic, copy) NSString *lastErrorMessage;
@property (nonatomic, copy) NSString *lastAlertedVersion;
@property (nonatomic, assign) BOOL checking;
- (NSTimeInterval)automaticCheckInterval;
- (void)fetchLatestReleaseFromAPIWithCompletion:(CLUpdateReleaseFetchCompletion)completion;
- (void)fetchLatestReleaseFromFallbackPageWithCompletion:(CLUpdateReleaseFetchCompletion)completion;
- (void)finishCheckWithLatestVersion:(NSString *)latestVersion
                    releaseURLString:(NSString *)releaseURLString
                        releaseNotes:(NSString *)releaseNotes
                        errorMessage:(NSString *)errorMessage
                       previousState:(CLUpdateCheckState)previousState
               previousLatestVersion:(NSString *)previousLatestVersion
                           presenter:(UIViewController *)presenter
                       userInitiated:(BOOL)userInitiated;
@end

@implementation CLUpdateCheckManager

+ (instancetype)sharedManager {
    static CLUpdateCheckManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[CLUpdateCheckManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 10.0;
        config.timeoutIntervalForResource = 15.0;
        _session = [NSURLSession sessionWithConfiguration:config];
        [self loadPersistedState];
        [self normalizePersistedStateIfNeeded];
    }
    return self;
}

- (void)loadPersistedState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id savedDate = [defaults objectForKey:CLUpdateCheckLastDateKey];
    if ([savedDate isKindOfClass:[NSDate class]]) {
        self.lastCheckDate = savedDate;
    }
    self.latestVersion = CLNormalizeVersionString([defaults stringForKey:CLUpdateCheckLatestVersionKey]);
    self.latestReleaseURLString = [defaults stringForKey:CLUpdateCheckLatestURLKey] ?: CLUpdateCheckFallbackReleaseURLString;
    self.latestReleaseNotes = [defaults stringForKey:CLUpdateCheckLatestNotesKey] ?: @"";
    self.lastErrorMessage = [defaults stringForKey:CLUpdateCheckLastErrorKey] ?: @"";
    self.lastAlertedVersion = CLNormalizeVersionString([defaults stringForKey:CLUpdateCheckLastAlertedVersionKey]);
    NSInteger savedState = [defaults integerForKey:CLUpdateCheckStateKey];
    if (savedState < CLUpdateCheckStateUnknown || savedState > CLUpdateCheckStateFailed) {
        savedState = CLUpdateCheckStateUnknown;
    }
    self.state = (CLUpdateCheckState)savedState;
}

- (void)normalizePersistedStateIfNeeded {
    NSString *currentVersion = CLNormalizeVersionString(CLCurrentAppVersion());
    if (self.state == CLUpdateCheckStateChecking) {
        self.state = CLUpdateCheckStateUnknown;
    }
    if (self.latestVersion.length == 0 && self.state == CLUpdateCheckStateUpdateAvailable) {
        self.state = CLUpdateCheckStateUnknown;
    }
    if (self.latestVersion.length > 0 &&
        CLCompareVersionStrings(self.latestVersion, currentVersion) != NSOrderedDescending &&
        self.state == CLUpdateCheckStateUpdateAvailable) {
        self.state = CLUpdateCheckStateUpToDate;
    }
    [self persistState];
}

- (void)persistState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (self.lastCheckDate) {
        [defaults setObject:self.lastCheckDate forKey:CLUpdateCheckLastDateKey];
    } else {
        [defaults removeObjectForKey:CLUpdateCheckLastDateKey];
    }
    if (self.latestVersion.length > 0) {
        [defaults setObject:self.latestVersion forKey:CLUpdateCheckLatestVersionKey];
    } else {
        [defaults removeObjectForKey:CLUpdateCheckLatestVersionKey];
    }
    if (self.latestReleaseURLString.length > 0) {
        [defaults setObject:self.latestReleaseURLString forKey:CLUpdateCheckLatestURLKey];
    } else {
        [defaults removeObjectForKey:CLUpdateCheckLatestURLKey];
    }
    if (self.latestReleaseNotes.length > 0) {
        [defaults setObject:self.latestReleaseNotes forKey:CLUpdateCheckLatestNotesKey];
    } else {
        [defaults removeObjectForKey:CLUpdateCheckLatestNotesKey];
    }
    if (self.lastErrorMessage.length > 0) {
        [defaults setObject:self.lastErrorMessage forKey:CLUpdateCheckLastErrorKey];
    } else {
        [defaults removeObjectForKey:CLUpdateCheckLastErrorKey];
    }
    if (self.lastAlertedVersion.length > 0) {
        [defaults setObject:self.lastAlertedVersion forKey:CLUpdateCheckLastAlertedVersionKey];
    } else {
        [defaults removeObjectForKey:CLUpdateCheckLastAlertedVersionKey];
    }
    [defaults setInteger:self.state forKey:CLUpdateCheckStateKey];
    [defaults synchronize];
}

- (void)postStatusDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CLUpdateCheckStatusDidChangeNotification object:self];
    });
}

- (BOOL)shouldPerformAutomaticCheck {
    if (!self.lastCheckDate) {
        return YES;
    }
    return [[NSDate date] timeIntervalSinceDate:self.lastCheckDate] >= [self automaticCheckInterval];
}

- (NSTimeInterval)automaticCheckInterval {
    return self.state == CLUpdateCheckStateFailed ? CLUpdateCheckFailureRetryInterval : CLUpdateCheckAutoInterval;
}

- (NSString *)statusText {
    switch (self.state) {
        case CLUpdateCheckStateChecking:
            return CLL(@"检查中...");
        case CLUpdateCheckStateUpdateAvailable:
            return self.latestVersion.length > 0
                ? [NSString stringWithFormat:CLL(@"发现新版本 %@"), self.latestVersion]
                : CLL(@"发现新版本");
        case CLUpdateCheckStateUpToDate:
            return CLL(@"已是最新版本");
        case CLUpdateCheckStateFailed:
            return CLL(@"更新检查失败");
        default:
            return CLL(@"未检查更新");
    }
}

- (void)fetchLatestReleaseFromAPIWithCompletion:(CLUpdateReleaseFetchCompletion)completion {
    NSURL *url = [NSURL URLWithString:CLUpdateCheckAPIURLString];
    if (!url) {
        if (completion) {
            completion(@"", CLUpdateCheckFallbackReleaseURLString, @"", CLL(@"无法获取最新版本信息。"));
        }
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"ChargeLimiter/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSString *latestVersion = @"";
        NSString *releaseURLString = CLUpdateCheckFallbackReleaseURLString;
        NSString *releaseNotes = @"";
        NSString *errorMessage = @"";

        if (!error && httpResponse && (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300)) {
            errorMessage = [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode];
        }

        if (!error && errorMessage.length == 0) {
            NSError *jsonError = nil;
            id jsonObject = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&jsonError];
            if (![jsonObject isKindOfClass:[NSDictionary class]]) {
                errorMessage = jsonError.localizedDescription ?: CLL(@"无法获取最新版本信息。");
            } else {
                NSDictionary *release = (NSDictionary *)jsonObject;
                latestVersion = CLNormalizeVersionString(release[@"tag_name"] ?: release[@"name"]);
                releaseURLString = [release[@"html_url"] isKindOfClass:[NSString class]] ? release[@"html_url"] : CLUpdateCheckFallbackReleaseURLString;
                releaseNotes = CLCompactReleaseNotes(release[@"body"]);
                if (latestVersion.length == 0) {
                    errorMessage = CLL(@"无法获取最新版本信息。");
                }
            }
        }

        if (error && errorMessage.length == 0) {
            errorMessage = error.localizedDescription ?: CLL(@"更新检查失败");
        }

        if (completion) {
            completion(latestVersion, releaseURLString, releaseNotes, errorMessage);
        }
    }];
    [task resume];
}

- (void)fetchLatestReleaseFromFallbackPageWithCompletion:(CLUpdateReleaseFetchCompletion)completion {
    NSURL *url = [NSURL URLWithString:CLUpdateCheckFallbackReleaseURLString];
    if (!url) {
        if (completion) {
            completion(@"", CLUpdateCheckFallbackReleaseURLString, @"", CLL(@"无法从 GitHub Releases 页面解析最新版本信息。"));
        }
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10.0;
    [request setValue:@"text/html,application/xhtml+xml" forHTTPHeaderField:@"Accept"];
    [request setValue:@"ChargeLimiter/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSString *latestVersion = @"";
        NSString *releaseURLString = CLUpdateCheckFallbackReleaseURLString;
        NSString *errorMessage = @"";

        if (!error && httpResponse && (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300)) {
            errorMessage = [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode];
        }

        if (!error && errorMessage.length == 0) {
            NSURL *finalURL = response.URL ?: url;
            releaseURLString = finalURL.absoluteString.length > 0 ? finalURL.absoluteString : CLUpdateCheckFallbackReleaseURLString;
            latestVersion = CLGitHubReleaseVersionFromURL(finalURL);
            if (latestVersion.length == 0) {
                errorMessage = CLL(@"无法从 GitHub Releases 页面解析最新版本信息。");
            }
        }

        if (error && errorMessage.length == 0) {
            errorMessage = error.localizedDescription ?: CLL(@"更新检查失败");
        }

        if (completion) {
            completion(latestVersion, releaseURLString, @"", errorMessage);
        }
    }];
    [task resume];
}

- (void)finishCheckWithLatestVersion:(NSString *)latestVersion
                    releaseURLString:(NSString *)releaseURLString
                        releaseNotes:(NSString *)releaseNotes
                        errorMessage:(NSString *)errorMessage
                       previousState:(CLUpdateCheckState)previousState
               previousLatestVersion:(NSString *)previousLatestVersion
                           presenter:(UIViewController *)presenter
                       userInitiated:(BOOL)userInitiated {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.checking = NO;
        self.lastCheckDate = [NSDate date];

        if (errorMessage.length > 0) {
            BOOL keepKnownUpdate = previousLatestVersion.length > 0 &&
                CLCompareVersionStrings(previousLatestVersion, CLCurrentAppVersion()) == NSOrderedDescending &&
                (previousState == CLUpdateCheckStateUpdateAvailable || previousState == CLUpdateCheckStateFailed || previousState == CLUpdateCheckStateChecking);
            self.state = keepKnownUpdate ? CLUpdateCheckStateUpdateAvailable : CLUpdateCheckStateFailed;
            self.lastErrorMessage = errorMessage;
            [self persistState];
            [self postStatusDidChange];
            if (userInitiated) {
                [self presentFailureAlertFromPresenter:(presenter ?: CLTopVisibleViewController())];
            }
            return;
        }

        self.latestVersion = CLNormalizeVersionString(latestVersion);
        self.latestReleaseURLString = releaseURLString.length > 0 ? releaseURLString : CLUpdateCheckFallbackReleaseURLString;
        self.latestReleaseNotes = releaseNotes ?: @"";
        self.lastErrorMessage = @"";

        if (CLCompareVersionStrings(self.latestVersion, CLCurrentAppVersion()) == NSOrderedDescending) {
            self.state = CLUpdateCheckStateUpdateAvailable;
        } else {
            self.state = CLUpdateCheckStateUpToDate;
        }
        [self persistState];
        [self postStatusDidChange];

        if (self.state == CLUpdateCheckStateUpdateAvailable) {
            UIViewController *alertPresenter = presenter ?: CLTopVisibleViewController();
            if (userInitiated) {
                [self presentUpdateAlertFromPresenter:alertPresenter];
            } else {
                [self presentPendingAlertIfNeeded];
            }
        } else if (userInitiated) {
            [self presentUpToDateAlertFromPresenter:(presenter ?: CLTopVisibleViewController())];
        }
    });
}

- (void)performAutomaticCheck {
    if (self.checking) {
        return;
    }
    if (![self shouldPerformAutomaticCheck]) {
        [self presentPendingAlertIfNeeded];
        [self postStatusDidChange];
        return;
    }
    [self startCheckForced:NO presenter:nil userInitiated:NO];
}

- (void)performManualCheckFromPresenter:(UIViewController *)presenter {
    if (self.checking) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"检查更新")
                                                                       message:CLL(@"正在检查更新，请稍候。")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self startCheckForced:YES presenter:presenter userInitiated:YES];
}

- (void)startCheckForced:(BOOL)forced presenter:(UIViewController *)presenter userInitiated:(BOOL)userInitiated {
    if (!forced && ![self shouldPerformAutomaticCheck]) {
        [self presentPendingAlertIfNeeded];
        return;
    }
    CLUpdateCheckState previousState = self.state;
    NSString *previousLatestVersion = self.latestVersion ?: @"";
    self.checking = YES;
    self.state = CLUpdateCheckStateChecking;
    self.lastErrorMessage = @"";
    [self persistState];
    [self postStatusDidChange];

    __weak typeof(self) weakSelf = self;
    [self fetchLatestReleaseFromAPIWithCompletion:^(NSString *latestVersion, NSString *releaseURLString, NSString *releaseNotes, NSString *errorMessage) {
        CLUpdateCheckManager *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (errorMessage.length == 0) {
            [strongSelf finishCheckWithLatestVersion:latestVersion
                                    releaseURLString:releaseURLString
                                        releaseNotes:releaseNotes
                                        errorMessage:@""
                                       previousState:previousState
                               previousLatestVersion:previousLatestVersion
                                           presenter:presenter
                                       userInitiated:userInitiated];
            return;
        }

        [strongSelf fetchLatestReleaseFromFallbackPageWithCompletion:^(NSString *fallbackVersion, NSString *fallbackReleaseURLString, NSString *fallbackReleaseNotes, NSString *fallbackErrorMessage) {
            NSString *finalErrorMessage = @"";
            NSString *finalLatestVersion = fallbackVersion;
            NSString *finalReleaseURLString = fallbackReleaseURLString;
            NSString *finalReleaseNotes = fallbackReleaseNotes;

            if (fallbackVersion.length == 0) {
                finalErrorMessage = CLCombineUpdateCheckErrorMessages(errorMessage, fallbackErrorMessage);
                finalReleaseURLString = CLUpdateCheckFallbackReleaseURLString;
                finalReleaseNotes = @"";
            }

            [strongSelf finishCheckWithLatestVersion:finalLatestVersion
                                    releaseURLString:finalReleaseURLString
                                        releaseNotes:finalReleaseNotes
                                        errorMessage:finalErrorMessage
                                       previousState:previousState
                               previousLatestVersion:previousLatestVersion
                                           presenter:presenter
                                       userInitiated:userInitiated];
        }];
    }];
}

- (BOOL)shouldPresentAutoAlert {
    if (self.state != CLUpdateCheckStateUpdateAvailable || self.latestVersion.length == 0) {
        return NO;
    }
    NSString *alertedVersion = CLNormalizeVersionString(self.lastAlertedVersion);
    return alertedVersion.length == 0 || ![alertedVersion isEqualToString:self.latestVersion];
}

- (void)presentPendingAlertIfNeeded {
    if (self.checking || ![self shouldPresentAutoAlert]) {
        return;
    }
    UIViewController *presenter = CLTopVisibleViewController();
    if (!presenter) {
        return;
    }
    if ([presenter isKindOfClass:[UIAlertController class]] ||
        [presenter.presentedViewController isKindOfClass:[UIAlertController class]]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf presentPendingAlertIfNeeded];
        });
        return;
    }
    [self presentUpdateAlertFromPresenter:presenter];
}

- (void)presentUpToDateAlertFromPresenter:(UIViewController *)presenter {
    if (!presenter) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"检查更新")
                                                                   message:[NSString stringWithFormat:CLL(@"当前已是最新版本 %@"), CLCurrentAppVersion()]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)presentFailureAlertFromPresenter:(UIViewController *)presenter {
    if (!presenter) {
        return;
    }
    NSString *message = self.lastErrorMessage.length > 0 ? self.lastErrorMessage : CLL(@"更新检查失败");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"更新检查失败")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)presentUpdateAlertFromPresenter:(UIViewController *)presenter {
    if (!presenter || self.latestVersion.length == 0) {
        return;
    }
    self.lastAlertedVersion = self.latestVersion;
    [self persistState];

    NSMutableString *message = [NSMutableString stringWithFormat:CLL(@"当前版本：%@\n最新版本：%@"),
                                CLCurrentAppVersion(),
                                self.latestVersion];
    if (self.latestReleaseNotes.length > 0) {
        [message appendFormat:@"\n\n%@", [NSString stringWithFormat:CLL(@"更新说明：\n%@"), self.latestReleaseNotes]];
    }
    [message appendFormat:@"\n\n%@", CLL(@"是否前往 GitHub Releases 查看更新？")];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:CLL(@"发现新版本 %@"), self.latestVersion]
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"稍后") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"查看更新")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        NSURL *url = [NSURL URLWithString:weakSelf.latestReleaseURLString.length > 0 ? weakSelf.latestReleaseURLString : CLUpdateCheckFallbackReleaseURLString];
        if (!url) {
            return;
        }
        if (@available(iOS 10.0, *)) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [UIApplication.sharedApplication openURL:url];
#pragma clang diagnostic pop
        }
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

@implementation CLBatteryStatusView

// 电池尺寸常量
#define BATTERY_BODY_WIDTH 110.0
#define BATTERY_BODY_HEIGHT 46.0
#define BATTERY_BODY_PADDING 4.0
#define BATTERY_FILL_PADDING 3.0
#define BATTERY_USABLE_WIDTH (BATTERY_BODY_WIDTH - 2*BATTERY_BODY_PADDING - 2*BATTERY_FILL_PADDING)
#define BATTERY_USABLE_HEIGHT (BATTERY_BODY_HEIGHT - 2*BATTERY_BODY_PADDING - 2*BATTERY_FILL_PADDING)

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _chargeBelow = 20;
        _chargeAbove = 80;
        _percentage = 75;
        _showLowMarker = YES;
        _visualState = CLBatteryVisualStateIdleNormal;
        [self setupView];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(accessibilitySettingsDidChange)
                                                     name:UIAccessibilityReduceMotionStatusDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

    self.flowOverlayLayer = [CAGradientLayer layer];
    self.flowOverlayLayer.colors = @[
        (id)[UIColor clearColor].CGColor,
        (id)[[UIColor whiteColor] colorWithAlphaComponent:0.7].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    self.flowOverlayLayer.startPoint = CGPointMake(0, 0.5);
    self.flowOverlayLayer.endPoint = CGPointMake(1, 0.5);
    self.flowOverlayLayer.locations = @[@(-1.0), @(-0.45), @(0.1)];
    self.flowOverlayLayer.opacity = 0.0;
    [self.fillView.layer addSublayer:self.flowOverlayLayer];

    self.temperatureGlowLayer = [CAGradientLayer layer];
    self.temperatureGlowLayer.colors = @[
        (id)[[UIColor systemOrangeColor] colorWithAlphaComponent:0.6].CGColor,
        (id)[[UIColor systemRedColor] colorWithAlphaComponent:0.16].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    self.temperatureGlowLayer.startPoint = CGPointMake(0.5, 0);
    self.temperatureGlowLayer.endPoint = CGPointMake(0.5, 1);
    self.temperatureGlowLayer.opacity = 0.0;
    [self.fillView.layer addSublayer:self.temperatureGlowLayer];
    
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

    self.fillWidthConstraint = [self.fillView.widthAnchor constraintEqualToConstant:MAX(BATTERY_USABLE_WIDTH * (self.percentage / 100.0), 4)];
    self.fillWidthConstraint.active = YES;

    self.fillPrimaryColor = [UIColor systemGreenColor];
    self.fillSecondaryColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.6];
    self.statusAccentColor = [UIColor systemGreenColor];
    [self updateFillWidth];
    [self applyVisualStateAnimated:NO forceAnimationRestart:YES];
    [self updateMarkersAnimated:NO];
}

- (void)updateFillWidth {
    CGFloat fillWidth = BATTERY_USABLE_WIDTH * (self.percentage / 100.0);

    self.fillWidthConstraint.constant = MAX(fillWidth, 4);
    [self setNeedsLayout];
}

- (void)setPercentage:(CGFloat)percentage {
    _percentage = MAX(0.0, MIN(percentage, 100.0));
    self.percentLabel.text = [NSString stringWithFormat:@"%.0f%%", _percentage];
    [self updateFillWidth];
}

- (void)setIsCharging:(BOOL)isCharging {
    _isCharging = isCharging;
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
    BOOL showHighMarker = (self.chargeAbove < 100);
    
    void (^updateBlock)(void) = ^{
        // 标记线高度和 fillView 一致
        self.lowMarker.frame = CGRectMake(lowX - 1.5, BATTERY_FILL_PADDING, 3, BATTERY_USABLE_HEIGHT);
        self.lowMarker.alpha = self.showLowMarker ? 1.0 : 0.0;
        self.highMarker.frame = CGRectMake(highX - 1.5, BATTERY_FILL_PADDING, 3, BATTERY_USABLE_HEIGHT);
        self.highMarker.alpha = showHighMarker ? 1.0 : 0.0;
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
    self.fillGradient.frame = self.fillView.bounds;
    self.flowOverlayLayer.frame = self.fillView.bounds;
    self.temperatureGlowLayer.frame = self.fillView.bounds;
    self.flowOverlayLayer.cornerRadius = self.fillView.layer.cornerRadius;
    self.temperatureGlowLayer.cornerRadius = self.fillView.layer.cornerRadius;
    [self updateMarkersAnimated:NO];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyVisualStateAnimated:NO forceAnimationRestart:YES];
}

- (void)accessibilitySettingsDidChange {
    [self applyVisualStateAnimated:NO forceAnimationRestart:YES];
}

- (BOOL)shouldReduceMotion {
    return UIAccessibilityIsReduceMotionEnabled() || self.window == nil;
}

- (CLBatteryVisualState)visualStateForManager:(CLBatteryManager *)manager {
    NSString *policyState = CLDisplayedPowerStateForManager(manager);
    if ([policyState isEqualToString:@"temp_paused"]) {
        return CLBatteryVisualStateTempPaused;
    }
    if ([policyState isEqualToString:@"hold_recharge"]) {
        return CLBatteryVisualStateHoldRecharge;
    }
    if ([policyState isEqualToString:@"hold"]) {
        return CLBatteryVisualStateHold;
    }
    if ([policyState isEqualToString:@"no_inflow"]) {
        return CLBatteryVisualStateNoInflow;
    }
    if ([policyState isEqualToString:@"charging"] || manager.holdCharging) {
        return CLBatteryVisualStateCharging;
    }
    if ([policyState isEqualToString:@"stopped"] || [policyState isEqualToString:@"external_idle"]) {
        return CLBatteryVisualStatePaused;
    }
    if (manager.currentCapacity <= 20) {
        return CLBatteryVisualStateLowBattery;
    }
    return CLBatteryVisualStateIdleNormal;
}

- (NSString *)statusIconNameForVisualState:(CLBatteryVisualState)state {
    switch (state) {
        case CLBatteryVisualStateCharging:
        case CLBatteryVisualStateHoldRecharge:
            return @"bolt.fill";
        case CLBatteryVisualStatePaused:
            return @"pause.fill";
        case CLBatteryVisualStateHold:
            return @"pause.circle.fill";
        case CLBatteryVisualStateTempPaused:
            return @"thermometer.sun";
        case CLBatteryVisualStateNoInflow:
            return @"slash.circle.fill";
        default:
            return nil;
    }
}

- (void)applyBatteryManager:(CLBatteryManager *)manager statusText:(NSString *)statusText {
    if (!manager) {
        return;
    }

    self.statusLabel.text = statusText ?: @"";
    self.percentage = manager.currentCapacity;
    self.isCharging = manager.isCharging;

    CLBatteryVisualState nextState = [self visualStateForManager:manager];
    BOOL stateChanged = (nextState != (CLBatteryVisualState)self.visualState);
    self.visualState = nextState;
    [self applyVisualStateAnimated:(self.window != nil && stateChanged) forceAnimationRestart:stateChanged];
}

- (void)applyVisualStateAnimated:(BOOL)animated forceAnimationRestart:(BOOL)forceAnimationRestart {
    CLBatteryVisualState state = (CLBatteryVisualState)self.visualState;
    BOOL reduceMotion = [self shouldReduceMotion];
    UIColor *primaryColor = [UIColor systemGreenColor];
    UIColor *secondaryColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.68];
    UIColor *accentColor = primaryColor;
    UIColor *glossColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    UIColor *statusColor = [UIColor secondaryLabelColor];
    NSString *iconName = [self statusIconNameForVisualState:state];

    CGFloat fillAlpha = 1.0;
    CGFloat flowOpacity = 0.0;
    CGFloat temperatureOpacity = 0.0;

    switch (state) {
        case CLBatteryVisualStateCharging:
            primaryColor = [UIColor systemGreenColor];
            secondaryColor = [[UIColor systemTealColor] colorWithAlphaComponent:0.72];
            accentColor = primaryColor;
            glossColor = [UIColor colorWithWhite:1.0 alpha:0.36];
            flowOpacity = reduceMotion ? 0.14 : 0.45;
            break;
        case CLBatteryVisualStateLowBattery:
            if (self.percentage <= 10) {
                primaryColor = [UIColor systemRedColor];
                secondaryColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.65];
                statusColor = [UIColor systemRedColor];
            } else {
                primaryColor = [UIColor systemOrangeColor];
                secondaryColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.42];
                statusColor = [UIColor systemOrangeColor];
            }
            accentColor = primaryColor;
            glossColor = [primaryColor colorWithAlphaComponent:0.2];
            break;
        case CLBatteryVisualStatePaused:
            primaryColor = [UIColor systemBlueColor];
            secondaryColor = [[UIColor systemIndigoColor] colorWithAlphaComponent:0.48];
            accentColor = primaryColor;
            glossColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.16];
            break;
        case CLBatteryVisualStateHold:
            primaryColor = [UIColor systemTealColor];
            secondaryColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.5];
            accentColor = primaryColor;
            glossColor = [[UIColor systemTealColor] colorWithAlphaComponent:0.18];
            break;
        case CLBatteryVisualStateHoldRecharge:
            primaryColor = [UIColor systemGreenColor];
            secondaryColor = [[UIColor systemTealColor] colorWithAlphaComponent:0.66];
            accentColor = primaryColor;
            glossColor = [UIColor colorWithWhite:1.0 alpha:0.34];
            flowOpacity = reduceMotion ? 0.12 : 0.3;
            break;
        case CLBatteryVisualStateTempPaused:
            primaryColor = [UIColor systemOrangeColor];
            secondaryColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.55];
            accentColor = [UIColor systemOrangeColor];
            glossColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.2];
            statusColor = [UIColor systemOrangeColor];
            temperatureOpacity = reduceMotion ? 0.2 : 0.34;
            break;
        case CLBatteryVisualStateNoInflow:
            primaryColor = [UIColor systemGrayColor];
            secondaryColor = [[UIColor systemTealColor] colorWithAlphaComponent:0.35];
            accentColor = [UIColor systemTealColor];
            glossColor = [[UIColor systemGrayColor] colorWithAlphaComponent:0.14];
            statusColor = [UIColor tertiaryLabelColor];
            fillAlpha = 0.9;
            break;
        case CLBatteryVisualStateIdleNormal:
        default:
            primaryColor = [UIColor systemGreenColor];
            secondaryColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.62];
            accentColor = primaryColor;
            glossColor = [UIColor colorWithWhite:1.0 alpha:0.28];
            break;
    }

    self.fillPrimaryColor = primaryColor;
    self.fillSecondaryColor = secondaryColor;
    self.statusAccentColor = accentColor;
    self.statusLabel.textColor = statusColor;
    self.fillView.alpha = fillAlpha;
    self.glossView.backgroundColor = glossColor;
    self.flowOverlayLayer.opacity = flowOpacity;
    self.temperatureGlowLayer.opacity = temperatureOpacity;

    [self applyGradientColorsAnimated:animated];
    [self updateStatusIconWithName:iconName animated:animated];

    BOOL needsAnimation = [self needsContinuousAnimationForState:state];
    BOOL hasAnimation = [self hasContinuousAnimationForState:state];

    if (forceAnimationRestart || (!needsAnimation && hasAnimation)) {
        [self stopContinuousAnimations];
    }

    if (needsAnimation && (forceAnimationRestart || !hasAnimation)) {
        [self startContinuousAnimationIfNeeded];
    }
}

- (BOOL)needsContinuousAnimationForState:(CLBatteryVisualState)state {
    switch (state) {
        case CLBatteryVisualStateCharging:
        case CLBatteryVisualStateHoldRecharge:
        case CLBatteryVisualStateTempPaused:
            return YES;
        case CLBatteryVisualStateLowBattery:
            return (self.percentage <= 10);
        case CLBatteryVisualStateIdleNormal:
            return YES;
        default:
            return NO;
    }
}

- (BOOL)hasContinuousAnimationForState:(CLBatteryVisualState)state {
    switch (state) {
        case CLBatteryVisualStateCharging:
        case CLBatteryVisualStateHoldRecharge:
            return ([self.flowOverlayLayer animationForKey:@"cl.flow"] != nil);
        case CLBatteryVisualStateLowBattery:
            return ([self.fillView.layer animationForKey:@"cl.lowBatteryPulse"] != nil);
        case CLBatteryVisualStateTempPaused:
            return ([self.temperatureGlowLayer animationForKey:@"cl.temperature"] != nil);
        case CLBatteryVisualStateIdleNormal:
            return ([self.glossView.layer animationForKey:@"cl.gloss"] != nil);
        default:
            return NO;
    }
}

- (void)applyGradientColorsAnimated:(BOOL)animated {
    NSArray *targetColors = @[(id)self.fillPrimaryColor.CGColor, (id)self.fillSecondaryColor.CGColor];
    id currentColors = self.fillGradient.presentationLayer ? ((CAGradientLayer *)self.fillGradient.presentationLayer).colors : self.fillGradient.colors;
    self.fillGradient.colors = targetColors;
    self.chargingIcon.tintColor = self.statusAccentColor;

    if (animated && currentColors) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"colors"];
        animation.fromValue = currentColors;
        animation.toValue = targetColors;
        animation.duration = 0.22;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.fillGradient addAnimation:animation forKey:@"cl.gradient.transition"];
    }
}

- (void)updateStatusIconWithName:(NSString *)iconName animated:(BOOL)animated {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    UIImage *icon = iconName.length > 0 ? CLSymbolImage(iconName, config) : nil;
    void (^changes)(void) = ^{
        self.chargingIcon.image = icon;
        self.chargingIcon.tintColor = self.statusAccentColor;
        self.chargingIcon.alpha = icon ? 1.0 : 0.0;
    };

    if (animated && self.window != nil) {
        if (!self.chargingIcon.hidden || icon != nil) {
            self.chargingIcon.hidden = NO;
            [UIView transitionWithView:self.chargingIcon
                              duration:0.18
                               options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                            animations:changes
                            completion:^(BOOL finished) {
                                self.chargingIcon.hidden = (icon == nil);
                            }];
            return;
        }
    }

    changes();
    self.chargingIcon.hidden = (icon == nil);
}

- (void)stopContinuousAnimations {
    [self.flowOverlayLayer removeAnimationForKey:@"cl.flow"];
    [self.temperatureGlowLayer removeAnimationForKey:@"cl.temperature"];
    [self.glossView.layer removeAnimationForKey:@"cl.gloss"];
    [self.fillView.layer removeAnimationForKey:@"cl.lowBatteryPulse"];
    [self.chargingIcon.layer removeAnimationForKey:@"cl.iconPulse"];
}

- (void)startContinuousAnimationIfNeeded {
    if ([self shouldReduceMotion]) {
        return;
    }

    CLBatteryVisualState state = (CLBatteryVisualState)self.visualState;
    switch (state) {
        case CLBatteryVisualStateCharging:
            [self startFlowAnimationWithDuration:1.25 opacity:0.45];
            [self startIconPulseWithScale:1.06 duration:0.95];
            break;
        case CLBatteryVisualStateHoldRecharge:
            [self startFlowAnimationWithDuration:2.0 opacity:0.28];
            [self startIconPulseWithScale:1.04 duration:1.35];
            break;
        case CLBatteryVisualStateLowBattery:
            if (self.percentage <= 10) {
                CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
                pulse.fromValue = @0.78;
                pulse.toValue = @1.0;
                pulse.duration = 0.9;
                pulse.autoreverses = YES;
                pulse.repeatCount = HUGE_VALF;
                pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [self.fillView.layer addAnimation:pulse forKey:@"cl.lowBatteryPulse"];
            }
            break;
        case CLBatteryVisualStateTempPaused: {
            [self startIconPulseWithScale:1.03 duration:1.45];
            CABasicAnimation *heat = [CABasicAnimation animationWithKeyPath:@"opacity"];
            heat.fromValue = @0.16;
            heat.toValue = @0.42;
            heat.duration = 1.45;
            heat.autoreverses = YES;
            heat.repeatCount = HUGE_VALF;
            heat.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self.temperatureGlowLayer addAnimation:heat forKey:@"cl.temperature"];
            break;
        }
        case CLBatteryVisualStateIdleNormal:
            {
                CABasicAnimation *gloss = [CABasicAnimation animationWithKeyPath:@"opacity"];
                gloss.fromValue = @0.12;
                gloss.toValue = @0.28;
                gloss.duration = 2.6;
                gloss.autoreverses = YES;
                gloss.repeatCount = HUGE_VALF;
                gloss.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [self.glossView.layer addAnimation:gloss forKey:@"cl.gloss"];
            }
            break;
        default:
            break;
    }
}

- (void)startFlowAnimationWithDuration:(CFTimeInterval)duration opacity:(CGFloat)opacity {
    self.flowOverlayLayer.opacity = opacity;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"locations"];
    animation.fromValue = @[@(-1.0), @(-0.45), @(0.1)];
    animation.toValue = @[@(0.9), @(1.35), @(1.8)];
    animation.duration = duration;
    animation.repeatCount = HUGE_VALF;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.flowOverlayLayer addAnimation:animation forKey:@"cl.flow"];
}

- (void)startIconPulseWithScale:(CGFloat)scale duration:(CFTimeInterval)duration {
    if (self.chargingIcon.hidden) {
        return;
    }
    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pulse.values = @[@1.0, @(scale), @1.0];
    pulse.duration = duration;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]
    ];
    [self.chargingIcon.layer addAnimation:pulse forKey:@"cl.iconPulse"];
}

@end

#pragma mark - 软件设置页面

static const NSInteger CLSoftwareNotificationSwitchTag = 4201;

static NSString *CLDaemonLanguageValueForLocaleIdentifier(NSString *identifier) {
    NSString *lang = [identifier isKindOfClass:[NSString class]] ? identifier.lowercaseString : @"";
    if ([lang hasPrefix:@"zh-hans"] || [lang hasPrefix:@"zh-cn"] || [lang hasPrefix:@"zh-sg"]) {
        return @"zh_CN";
    }
    if ([lang hasPrefix:@"zh-hant"] || [lang hasPrefix:@"zh-tw"] || [lang hasPrefix:@"zh-hk"] || [lang hasPrefix:@"zh-mo"]) {
        return @"zh_TW";
    }
    if ([lang hasPrefix:@"ar"]) {
        return @"ar";
    }
    if ([lang hasPrefix:@"vi"]) {
        return @"vi";
    }
    return @"en";
}

static NSString * const CLStopChargePresetDefaultsKey = @"StopChargePresetValue";

static NSInteger CLNormalizedStopChargePresetValue(NSInteger value) {
    if (value <= 0) {
        return 0;
    }
    if (value < 15) {
        return 15;
    }
    if (value > 100) {
        return 100;
    }
    return value;
}

static NSInteger CLStoredStopChargePresetValue(void) {
    return CLNormalizedStopChargePresetValue([[NSUserDefaults standardUserDefaults] integerForKey:CLStopChargePresetDefaultsKey]);
}

static void CLStoreStopChargePresetValue(NSInteger value) {
    [[NSUserDefaults standardUserDefaults] setInteger:CLNormalizedStopChargePresetValue(value) forKey:CLStopChargePresetDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *CLStopChargePresetSettingsText(NSInteger value) {
    NSInteger normalized = CLNormalizedStopChargePresetValue(value);
    if (normalized <= 0) {
        return CLL(@"未设置");
    }
    return [NSString stringWithFormat:@"%ld%%", (long)normalized];
}

static NSString *CLStopChargePresetButtonTitle(NSInteger value) {
    NSInteger normalized = CLNormalizedStopChargePresetValue(value);
    if (normalized <= 0) {
        return CLL(@"预设");
    }
    return [NSString stringWithFormat:@"%ld", (long)normalized];
}

static UIColor *CLStopChargePresetAccentColor(void) {
    UIColor *lightColor = [UIColor colorWithRed:0.64 green:0.79 blue:0.20 alpha:1.0];
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
            if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0.76 green:0.90 blue:0.34 alpha:1.0];
            }
            return lightColor;
        }];
    }
    return lightColor;
}

static void CLPresentStopChargePresetEditor(UIViewController *presenter,
                                            NSInteger currentPreset,
                                            NSInteger suggestedValue,
                                            void (^saveHandler)(NSInteger value),
                                            dispatch_block_t clearHandler) {
    NSInteger normalizedPreset = CLNormalizedStopChargePresetValue(currentPreset);
    NSInteger normalizedSuggested = CLNormalizedStopChargePresetValue(suggestedValue);
    if (normalizedSuggested <= 0) {
        normalizedSuggested = 80;
    }

    NSString *message = normalizedPreset > 0
        ? CLL(@"输入 15 到 100 的预设电量。主页按钮点击即可一键应用，长按可再次调整。")
        : CLL(@"输入 15 到 100 的预设电量。保存后，主页按钮会显示该电量，并可一键应用。");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"设置停充预设")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.placeholder = @"15-100";
        NSInteger initialValue = normalizedPreset > 0 ? normalizedPreset : normalizedSuggested;
        textField.text = [NSString stringWithFormat:@"%ld", (long)initialValue];
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (normalizedPreset > 0 && clearHandler) {
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"清除预设")
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            clearHandler();
        }]];
    }

    if (saveHandler) {
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"保存")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            UITextField *textField = alert.textFields.firstObject;
            NSInteger inputValue = CLNormalizedStopChargePresetValue(textField.text.integerValue);
            if (inputValue <= 0) {
                inputValue = normalizedSuggested;
            }
            saveHandler(inputValue);
        }]];
    }

    [presenter presentViewController:alert animated:YES completion:nil];
}

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
- (void)configDidUpdate;
- (UISwitch *)switchInCard:(CLGlassCard *)card tag:(NSInteger)tag;
- (NSString *)daemonLanguageValueForAppLanguage:(CLAppLanguage)language;
- (void)syncDaemonLanguageWithAppLanguage:(CLAppLanguage)language;
- (void)promptLegacyResidualCleanupWithPaths:(NSArray<NSString *> *)paths completion:(dispatch_block_t)completion;
- (void)showLegacyResidualCleanupResult:(NSDictionary *)result;
@end

@implementation CLSoftwareSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    CLApplyLanguageFromSettings();
    self.title = CLL(@"软件设置");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self setupUI];
    [self syncDaemonLanguageWithAppLanguage:CLGetAppLanguage()];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange)
                                                 name:CLAppLanguageDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateCheckStatusDidChange)
                                                 name:CLUpdateCheckStatusDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(configDidUpdate)
                                                 name:CLConfigDidUpdateNotification
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
    
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:containerView];
    [containerView addSubview:self.mainStack];
    
    NSLayoutConstraint *widthConstraint = [self.mainStack.widthAnchor constraintEqualToAnchor:containerView.widthAnchor constant:-32];
    widthConstraint.priority = UILayoutPriorityDefaultHigh;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
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
        widthConstraint,
        [self.mainStack.widthAnchor constraintLessThanOrEqualToConstant:600],
    ]];
    
    [self setupSettingsCard];
}

- (void)setupSettingsCard {
    self.settingsCard = [[CLGlassCard alloc] init];
    
    CLBatteryManager *manager = [CLBatteryManager shared];
    NSString *freqValue = [self frequencyString:manager.updateFrequency];
    
    [self.settingsCard addSwitchRowWithIcon:@"bell.badge.fill" title:CLL(@"通知") isOn:manager.notificationEnabled color:[UIColor systemOrangeColor] tag:CLSoftwareNotificationSwitchTag onChange:^(BOOL isOn) {
        [manager setNotificationEnabled:isOn];
    }];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"clock.arrow.circlepath" title:CLL(@"刷新频率") value:freqValue color:[UIColor systemTealColor] target:self action:@selector(frequencyTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"globe" title:CLL(@"语言") value:[self languageValueLabel] color:[UIColor systemBlueColor] target:self action:@selector(languageTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"moon.fill" title:CLL(@"深色模式") value:[self appearanceValueLabel] color:[UIColor systemGrayColor] target:self action:@selector(darkModeTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"tag.fill" title:CLL(@"停充预设") value:[self chargeAbovePresetValueLabel] color:CLStopChargePresetAccentColor() target:self action:@selector(stopChargePresetTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard.contentStack addArrangedSubview:[self buildHapticRow]];
    [self.settingsCard addSeparator];
    [self.settingsCard.contentStack addArrangedSubview:[self buildHapticDetailRow]];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"folder" title:CLL(@"应用数据目录") value:@"" color:[UIColor systemTealColor] target:self action:@selector(configFolderTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"arrow.triangle.swap" title:CLL(@"迁移/删除旧版数据") value:@"" color:[UIColor systemOrangeColor] target:self action:@selector(migrateLegacyDataTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"arrow.triangle.2.circlepath" title:CLL(@"检查更新") value:[self updateStatusValue] color:[UIColor systemIndigoColor] target:self action:@selector(checkUpdateTapped)];
    [self.settingsCard addSeparator];
    [self.settingsCard addNavigationRowWithIcon:@"questionmark.circle" title:CLL(@"帮助") value:@"" color:[UIColor systemBlueColor] target:self action:@selector(helpTapped)];
    
    [self.mainStack addArrangedSubview:self.settingsCard];
}

- (NSString *)updateStatusValue {
    return [[CLUpdateCheckManager sharedManager] statusText];
}

- (NSString *)frequencyString:(NSInteger)freq {
    if (freq <= 1) return CLL(@"1 秒");
    if (freq <= 20) return CLL(@"20 秒");
    if (freq <= 60) return CLL(@"1 分钟");
    return CLL(@"10 分钟");
}

- (NSString *)chargeAbovePresetValueLabel {
    return CLStopChargePresetSettingsText(CLStoredStopChargePresetValue());
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
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0, 0);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setUpdateFrequency:(NSInteger)freq {
    [CLBatteryManager shared].updateFrequency = freq;
    [self updateCardValue:self.settingsCard title:CLL(@"刷新频率") value:[self frequencyString:freq]];
}

- (void)languageTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"语言") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    CLAppLanguage current = CLGetAppLanguage();

    [alert addAction:[self checkedActionWithTitle:CLL(@"跟随系统") checked:(current == CLAppLanguageSystem) handler:^(UIAlertAction * _Nonnull action) {
        CLSetAppLanguage(CLAppLanguageSystem);
        [self syncDaemonLanguageWithAppLanguage:CLAppLanguageSystem];
    }]];
    [alert addAction:[self checkedActionWithTitle:CLL(@"English") checked:(current == CLAppLanguageEnglish) handler:^(UIAlertAction * _Nonnull action) {
        CLSetAppLanguage(CLAppLanguageEnglish);
        [self syncDaemonLanguageWithAppLanguage:CLAppLanguageEnglish];
    }]];
    [alert addAction:[self checkedActionWithTitle:CLL(@"简体中文") checked:(current == CLAppLanguageChineseSimplified) handler:^(UIAlertAction * _Nonnull action) {
        CLSetAppLanguage(CLAppLanguageChineseSimplified);
        [self syncDaemonLanguageWithAppLanguage:CLAppLanguageChineseSimplified];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0, 0);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }
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
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            alert.popoverPresentationController.sourceView = self.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0, 0);
            alert.popoverPresentationController.permittedArrowDirections = 0;
        }
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"深色模式") message:CLL(@"iOS 13+ 才支持深色模式") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)stopChargePresetTapped {
    CLBatteryManager *manager = [CLBatteryManager shared];
    NSInteger currentPreset = CLStoredStopChargePresetValue();
    NSInteger suggestedValue = currentPreset > 0 ? currentPreset : manager.chargeAbove;
    __weak typeof(self) weakSelf = self;
    CLPresentStopChargePresetEditor(self,
                                    currentPreset,
                                    suggestedValue,
                                    ^(NSInteger value) {
        CLStoreStopChargePresetValue(value);
        [weakSelf updateCardValue:weakSelf.settingsCard title:CLL(@"停充预设") value:[weakSelf chargeAbovePresetValueLabel]];
    }, ^{
        CLStoreStopChargePresetValue(0);
        [weakSelf updateCardValue:weakSelf.settingsCard title:CLL(@"停充预设") value:[weakSelf chargeAbovePresetValueLabel]];
    });
}

- (NSString *)daemonLanguageValueForAppLanguage:(CLAppLanguage)language {
    switch (language) {
        case CLAppLanguageEnglish:
            return @"en";
        case CLAppLanguageChineseSimplified:
            return @"zh_CN";
        case CLAppLanguageSystem:
        default: {
            NSString *preferred = NSLocale.preferredLanguages.firstObject ?: @"en";
            return CLDaemonLanguageValueForLocaleIdentifier(preferred);
        }
    }
}

- (void)syncDaemonLanguageWithAppLanguage:(CLAppLanguage)language {
    NSString *langValue = [self daemonLanguageValueForAppLanguage:language];
    if (langValue.length == 0) {
        return;
    }
    [[CLAPIClient shared] setConfigWithKey:@"lang" value:langValue completion:nil];
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
    NSString *confPath = getConfPath_C();
    NSString *dirPath = getAppDocumentsPath_C();
    NSString *targetPath = confPath;

    // Prefer opening the config file directly, matching previous behavior.
    if (targetPath.length == 0 && dirPath.length > 0) {
        targetPath = [dirPath stringByAppendingPathComponent:@"aldente.conf"];
    }

    // Fallback to app data directory when file path cannot be resolved.
    if (targetPath.length == 0 && dirPath.length > 0) {
        targetPath = dirPath;
    }

    if (targetPath.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"无法打开") message:CLL(@"未能定位应用数据目录") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    CLOpenPathInFilza(self, targetPath);
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

- (void)checkUpdateTapped {
    [[CLUpdateCheckManager sharedManager] performManualCheckFromPresenter:self];
}

- (void)migrateLegacyDataTapped {
    NSArray<NSString*> *legacyDirs = getLegacyConfigDirsWithData_C();
    NSArray<NSString*> *residualFiles = getLegacyResidualFiles_C();
    if (legacyDirs.count == 0 && residualFiles.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"未发现旧版数据")
                                                                       message:CLL(@"当前未检测到可迁移的旧版配置文件。")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (legacyDirs.count == 0) {
        [self promptLegacyResidualCleanupWithPaths:residualFiles completion:nil];
        return;
    }

    NSString *displayLegacyDir = CLNumberedLegacyDirsText(legacyDirs);
    NSMutableString *message = [NSMutableString stringWithFormat:
                                CLL(@"检测到旧版本配置文件可能在：\n%@\n\n是否迁移到当前版本的 Documents 目录？\n\n提示：迁移会覆盖当前同名文件，并删除旧目录中的原文件。"),
                                displayLegacyDir];
    if (residualFiles.count > 0) {
        NSString *displayResidualFiles = CLNumberedPathsText(residualFiles);
        [message appendFormat:CLL(@"\n\n同时检测到旧版残留文件，可先删除残留再迁移：\n%@"), displayResidualFiles];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"迁移/删除旧版数据")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    if (residualFiles.count > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"删除残留")
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            [weakSelf promptLegacyResidualCleanupWithPaths:residualFiles completion:nil];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"立即迁移")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        NSDictionary *result = migrateLegacyConfigFiles_C();
        NSInteger migrated = [result[@"migrated"] integerValue];
        NSInteger replaced = [result[@"replaced"] integerValue];
        NSInteger missing = [result[@"missing"] integerValue];
        NSInteger failed = [result[@"failed"] integerValue];
        NSString *resultMessage = [NSString stringWithFormat:
                                   CLL(@"迁移完成。\n新建: %ld\n已覆盖: %ld\n未找到: %ld\n失败: %ld"),
                                   (long)migrated, (long)replaced, (long)missing, (long)failed];
        NSArray *errors = result[@"errors"];
        if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) {
            NSString *firstError = [errors.firstObject description];
            resultMessage = [resultMessage stringByAppendingFormat:CLL(@"\n\n首个错误：%@"), firstError];
        }
        NSString *failedPath = CLFirstFailedRemovePathFromResult(result);
        UIAlertController *done = [UIAlertController alertControllerWithTitle:CLL(@"迁移结果")
                                                                      message:resultMessage
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:CLL(@"确定") style:UIAlertActionStyleDefault handler:nil]];
        if (failedPath.length > 0) {
            [done addAction:[UIAlertAction actionWithTitle:CLL(@"跳转目录手动删除")
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction * _Nonnull action) {
                CLOpenPathInFilza(weakSelf, failedPath);
            }]];
        }
        [weakSelf presentViewController:done animated:YES completion:nil];
        [[CLAPIClient shared] sendRequest:@{@"api": @"reload_conf"} completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
            [[CLAPIClient shared] applyNowWithCompletion:^(NSDictionary * _Nullable response2, NSError * _Nullable error2) {
                [[CLBatteryManager shared] refreshAll];
            }];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptLegacyResidualCleanupWithPaths:(NSArray<NSString *> *)paths completion:(dispatch_block_t)completion {
    NSString *displayPaths = CLNumberedPathsText(paths);
    NSString *message = [NSString stringWithFormat:
                         CLL(@"检测到旧版残留文件：\n%@\n\n这些文件不满足迁移条件，是否直接删除？"),
                         displayPaths];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"检测到旧版残留文件")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"暂不处理")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        if (completion) completion();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"删除残留")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        NSDictionary *result = cleanupLegacyResidualFiles_C();
        [weakSelf showLegacyResidualCleanupResult:result];
        if (completion) completion();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLegacyResidualCleanupResult:(NSDictionary *)result {
    NSInteger removed = [result[@"removed"] integerValue];
    NSInteger failed = [result[@"failed"] integerValue];
    NSString *message = [NSString stringWithFormat:
                         CLL(@"残留清理完成。\n已删除: %ld\n失败: %ld"),
                         (long)removed, (long)failed];
    NSArray *errors = result[@"errors"];
    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) {
        NSString *firstError = [errors.firstObject description];
        message = [message stringByAppendingFormat:CLL(@"\n\n首个错误：%@"), firstError];
    }

    NSString *failedPath = CLFirstFailedRemovePathFromResult(result);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"残留清理结果")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    if (failedPath.length > 0) {
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"跳转目录手动删除")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            CLOpenPathInFilza(weakSelf, failedPath);
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
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

- (void)updateCheckStatusDidChange {
    [self updateCardValue:self.settingsCard title:CLL(@"检查更新") value:[self updateStatusValue]];
}

- (void)configDidUpdate {
    UISwitch *switchControl = [self switchInCard:self.settingsCard tag:CLSoftwareNotificationSwitchTag];
    if (!switchControl) {
        return;
    }
    BOOL enabled = [CLBatteryManager shared].notificationEnabled;
    [switchControl setOn:enabled animated:YES];
    UIImageView *iconView = objc_getAssociatedObject(switchControl, "iconView");
    UIColor *iconColor = objc_getAssociatedObject(switchControl, "iconColor");
    if (iconView) {
        iconView.tintColor = enabled ? (iconColor ?: [UIColor systemOrangeColor])
                                     : [[UIColor secondaryLabelColor] colorWithAlphaComponent:0.7];
    }
    [self updateCardValue:self.settingsCard title:CLL(@"停充预设") value:[self chargeAbovePresetValueLabel]];
}

- (UISwitch *)switchInCard:(CLGlassCard *)card tag:(NSInteger)tag {
    for (UIView *row in card.contentStack.arrangedSubviews) {
        UISwitch *switchControl = [row viewWithTag:tag];
        if ([switchControl isKindOfClass:[UISwitch class]]) {
            return switchControl;
        }
    }
    return nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

#pragma mark - 主控制器

@interface CLSettingsViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *mainStack;
@property (nonatomic, strong) UIView *contentContainerView;
@property (nonatomic, strong) CLBatteryStatusView *batteryStatus;
@property (nonatomic, strong) CLGlassCard *controlCard;
@property (nonatomic, strong) CLGlassCard *limitCard;
@property (nonatomic, strong) CLGlassCard *tempCard;       // 温度控制卡片
@property (nonatomic, strong) CLGlassCard *adapterCard;    // 适配器信息卡片
@property (nonatomic, strong) CLGlassCard *powerPathCard;  // 电源路径卡片
@property (nonatomic, strong) CLGlassCard *infoCard;
@property (nonatomic, strong) CLGlassCard *softwareSettingsEntryCard;
@property (nonatomic, strong) CLGlassCard *historyEntryCard;
@property (nonatomic, strong) CLGlassCard *moreCard;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, strong) UILabel *softwareSettingsSubtitleLabel;
@property (nonatomic, assign) NSInteger chargeBelow;
@property (nonatomic, assign) NSInteger chargeAbove;
@property (nonatomic, assign) NSInteger currentChargeMode; // 0=插电即充, 1=边缘触发
@property (nonatomic, strong) UIView *chargeBelowRow;
@property (nonatomic, strong) UIView *chargeAboveRow;      // 停止充电行
@property (nonatomic, strong) UIButton *chargeAbovePresetButton;
@property (nonatomic, strong) UIButton *setChargeAboveCurrentButton;
@property (nonatomic, strong) UIView *chargeBelowSeparator;
@property (nonatomic, strong) UIView *tempBelowRow;        // 温度下限行
@property (nonatomic, strong) UIView *tempAboveRow;        // 温度上限行
@property (nonatomic, strong) UIView *tempSeparator1;
@property (nonatomic, strong) UIView *tempSeparator2;
@property (nonatomic, assign) NSInteger chargeTempBelow;
@property (nonatomic, assign) NSInteger chargeTempAbove;
@property (nonatomic, strong) UIView *systemControlHintView;
@property (nonatomic, strong) UILabel *systemControlHintLabel;
@property (nonatomic, strong) NSTimer *systemControlHintTimer;
@property (nonatomic, assign) NSInteger lastChargeAboveForHint;
@property (nonatomic, assign) BOOL lastSystemCapacityControlActiveForHint;
@property (nonatomic, assign) BOOL didCheckLegacyMigrationPrompt;
@property (nonatomic, assign) BOOL tempControlsShouldBeVisible;
- (void)promptLegacyMigrationIfNeeded;
- (void)showLegacyMigrationResult:(NSDictionary *)result;
- (void)promptLegacyResidualCleanupWithPaths:(NSArray<NSString *> *)paths completion:(dispatch_block_t)completion;
- (void)showLegacyResidualCleanupResult:(NSDictionary *)result;
- (void)setupSystemControlHintFloating;
- (void)updateSystemControlHintForChargeAbove:(NSInteger)newValue;
- (void)showSystemControlHint;
- (void)showSystemControlHintWithText:(NSString *)text;
- (BOOL)usesSystemCapacityControlForManager:(CLBatteryManager *)manager chargeAbove:(NSInteger)chargeAbove;
- (BOOL)isHoldSuppressedBySystemCapacityControlForManager:(CLBatteryManager *)manager;
@end

@implementation CLSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    CLApplyLanguageFromSettings();
    (void)getAppDocumentsPath_C();
    self.chargeBelow = 20;
    self.chargeAbove = 80;
    self.lastChargeAboveForHint = self.chargeAbove;
    self.lastSystemCapacityControlActiveForHint = NO;
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateCheckStatusDidChange)
                                                 name:CLUpdateCheckStatusDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    [self updateCheckStatusDidChange];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = YES;
    [[CLBatteryManager shared] startAutoRefresh];
    [self updateChargeAbovePresetButtonAppearance];
    if (!self.didCheckLegacyMigrationPrompt) {
        self.didCheckLegacyMigrationPrompt = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self promptLegacyMigrationIfNeeded];
        });
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[CLUpdateCheckManager sharedManager] performAutomaticCheck];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBarHidden = NO;
    [[CLBatteryManager shared] stopAutoRefresh];
    [self.systemControlHintTimer invalidate];
    self.systemControlHintTimer = nil;
    self.systemControlHintView.alpha = 0;
    self.systemControlHintView.hidden = YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Legacy Migration

- (void)promptLegacyMigrationIfNeeded {
    static NSString * const kLegacyMigrationCheckedTokenKey = @"LegacyMigrationCheckedToken";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *shortVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *buildVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (![shortVer isKindOfClass:[NSString class]]) {
        shortVer = @"";
    }
    if (![buildVer isKindOfClass:[NSString class]]) {
        buildVer = @"";
    }
    NSString *currentToken = [NSString stringWithFormat:@"%@(%@)", shortVer, buildVer];
    NSString *checkedToken = [defaults stringForKey:kLegacyMigrationCheckedTokenKey];
    if ([checkedToken isKindOfClass:[NSString class]] && [checkedToken isEqualToString:currentToken]) {
        return;
    }

    NSArray<NSString*> *legacyDirs = getLegacyConfigDirsWithData_C();
    NSArray<NSString*> *residualFiles = getLegacyResidualFiles_C();
    if (legacyDirs.count == 0) {
        if (residualFiles.count > 0) {
            [self promptLegacyResidualCleanupWithPaths:residualFiles completion:^{
                [defaults setObject:currentToken forKey:kLegacyMigrationCheckedTokenKey];
                [defaults synchronize];
            }];
        } else {
            [defaults setObject:currentToken forKey:kLegacyMigrationCheckedTokenKey];
            [defaults synchronize];
        }
        return;
    }

    NSString *displayLegacyDir = CLNumberedLegacyDirsText(legacyDirs);
    NSMutableString *message = [NSMutableString stringWithFormat:
                                CLL(@"检测到旧版本配置文件可能在：\n%@\n\n是否迁移到当前版本的 Documents 目录？\n\n提示：新版卸载时会删除当前应用数据目录，历史记录会丢失。"),
                                displayLegacyDir];
    if (residualFiles.count > 0) {
        NSString *displayResidualFiles = CLNumberedPathsText(residualFiles);
        [message appendFormat:CLL(@"\n\n同时检测到旧版残留文件，可先删除残留再迁移：\n%@"), displayResidualFiles];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"检测到旧版本数据")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"暂不迁移")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        [defaults setObject:currentToken forKey:kLegacyMigrationCheckedTokenKey];
        [defaults synchronize];
    }]];
    if (residualFiles.count > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"删除残留")
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self promptLegacyResidualCleanupWithPaths:residualFiles completion:^{
                [defaults setObject:currentToken forKey:kLegacyMigrationCheckedTokenKey];
                [defaults synchronize];
            }];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"立即迁移")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [defaults setObject:currentToken forKey:kLegacyMigrationCheckedTokenKey];
        [defaults synchronize];
        NSDictionary *result = migrateLegacyConfigFiles_C();
        [weakSelf showLegacyMigrationResult:result];
        [[CLAPIClient shared] sendRequest:@{@"api": @"reload_conf"} completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
            [[CLAPIClient shared] applyNowWithCompletion:^(NSDictionary * _Nullable response2, NSError * _Nullable error2) {
                [[CLBatteryManager shared] refreshAll];
            }];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptLegacyResidualCleanupWithPaths:(NSArray<NSString *> *)paths completion:(dispatch_block_t)completion {
    NSString *displayPaths = CLNumberedPathsText(paths);
    NSString *message = [NSString stringWithFormat:
                         CLL(@"检测到旧版残留文件：\n%@\n\n这些文件不满足迁移条件，是否直接删除？"),
                         displayPaths];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"检测到旧版残留文件")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"暂不处理")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        if (completion) completion();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"删除残留")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        NSDictionary *result = cleanupLegacyResidualFiles_C();
        [weakSelf showLegacyResidualCleanupResult:result];
        if (completion) completion();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLegacyMigrationResult:(NSDictionary *)result {
    NSInteger migrated = [result[@"migrated"] integerValue];
    NSInteger replaced = [result[@"replaced"] integerValue];
    NSInteger missing = [result[@"missing"] integerValue];
    NSInteger failed = [result[@"failed"] integerValue];
    NSString *message = [NSString stringWithFormat:
                         CLL(@"迁移完成。\n新建: %ld\n已覆盖: %ld\n未找到: %ld\n失败: %ld"),
                         (long)migrated, (long)replaced, (long)missing, (long)failed];
    NSArray *errors = result[@"errors"];
    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) {
        NSString *firstError = [errors.firstObject description];
        message = [message stringByAppendingFormat:CLL(@"\n\n首个错误：%@"), firstError];
    }
    message = [message stringByAppendingString:CLL(@"\n\n提示：若你之后卸载新版，历史记录会随应用数据目录一起删除。")];

    NSString *failedPath = CLFirstFailedRemovePathFromResult(result);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"迁移结果")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    if (failedPath.length > 0) {
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"跳转目录手动删除")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            CLOpenPathInFilza(weakSelf, failedPath);
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLegacyResidualCleanupResult:(NSDictionary *)result {
    NSInteger removed = [result[@"removed"] integerValue];
    NSInteger failed = [result[@"failed"] integerValue];
    NSString *message = [NSString stringWithFormat:
                         CLL(@"残留清理完成。\n已删除: %ld\n失败: %ld"),
                         (long)removed, (long)failed];
    NSArray *errors = result[@"errors"];
    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) {
        NSString *firstError = [errors.firstObject description];
        message = [message stringByAppendingFormat:CLL(@"\n\n首个错误：%@"), firstError];
    }

    NSString *failedPath = CLFirstFailedRemovePathFromResult(result);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"残留清理结果")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"确定")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    if (failedPath.length > 0) {
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:CLL(@"跳转目录手动删除")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            CLOpenPathInFilza(weakSelf, failedPath);
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
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
    
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:containerView];
    [containerView addSubview:self.mainStack];
    self.contentContainerView = containerView;
    
    NSLayoutConstraint *widthConstraint = [self.mainStack.widthAnchor constraintEqualToAnchor:containerView.widthAnchor constant:-32];
    widthConstraint.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        
        [containerView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
        [containerView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [containerView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [containerView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [containerView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],
        
        [self.mainStack.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:60],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-40],
        [self.mainStack.centerXAnchor constraintEqualToAnchor:containerView.centerXAnchor],
        widthConstraint,
        [self.mainStack.widthAnchor constraintLessThanOrEqualToConstant:600],
    ]];
    
    // 标题
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = CLL(@"ChargeLimiter");
    titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];

    self.refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *refreshConfig = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    [self.refreshButton setImage:CLSymbolImage(@"arrow.clockwise", refreshConfig) forState:UIControlStateNormal];
    self.refreshButton.tintColor = [UIColor secondaryLabelColor];
    self.refreshButton.accessibilityLabel = CLL(@"立即刷新");
    [self.refreshButton addTarget:self action:@selector(refreshNowTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.refreshButton.widthAnchor constraintEqualToConstant:28].active = YES;
    [self.refreshButton.heightAnchor constraintEqualToConstant:28].active = YES;

    UIView *titleSpacer = [[UIView alloc] init];
    titleSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [titleSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [titleSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, titleSpacer, self.refreshButton]];
    titleStack.axis = UILayoutConstraintAxisHorizontal;
    titleStack.alignment = UIStackViewAlignmentFirstBaseline;
    titleStack.spacing = 12;
    [self.mainStack addArrangedSubview:titleStack];
    
    // 标题下不再显示副标题
    
    // 电池状态
    self.batteryStatus = [[CLBatteryStatusView alloc] init];
    self.batteryStatus.translatesAutoresizingMaskIntoConstraints = NO;
    [self.batteryStatus.heightAnchor constraintEqualToConstant:80].active = YES;
    [self.mainStack addArrangedSubview:self.batteryStatus];
    [self.mainStack setCustomSpacing:12 afterView:self.batteryStatus];
    
    
    // 控制卡片
    [self setupControlCard];
    
    // 充电限制卡片
    [self setupLimitCard];

    // 系统接管电量控制提示（悬浮显示在控制卡片和充电限制卡片之间）
    [self setupSystemControlHintFloating];
    
    // 温度控制卡片
    [self setupTempCard];
    
    // 适配器信息卡片
    [self setupAdapterCard];

    // 电源路径卡片
    [self setupPowerPathCard];
    
    // 电池信息卡片
    [self setupInfoCard];
    
    UILabel *toolsTitle = [[UILabel alloc] init];
    toolsTitle.text = CLL(@"更多功能");
    toolsTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    toolsTitle.textColor = [UIColor secondaryLabelColor];
    [self.mainStack addArrangedSubview:toolsTitle];
    [self.mainStack setCustomSpacing:8 afterView:toolsTitle];
    
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
    [self.controlCard addSwitchRowWithIcon:@"bolt.fill" title:CLL(@"启用") isOn:YES color:[UIColor systemGreenColor] tag:100 onChange:^(BOOL isOn) {
        [CLBatteryManager shared].enabled = isOn;
    }];
    [self.controlCard addSeparator];
    [self.controlCard addNavigationRowWithIcon:@"gearshape" title:CLL(@"充电模式") value:CLL(@"插电即充") color:[UIColor systemBlueColor] target:self action:@selector(chargeModesTapped)];
    
    [self.mainStack addArrangedSubview:self.controlCard];
}

- (void)setupSystemControlHintFloating {
    UIView *hint = [[UIView alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.96];
    hint.layer.cornerRadius = 10;
    hint.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    hint.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.55].CGColor;
    hint.layer.shadowColor = [UIColor blackColor].CGColor;
    hint.layer.shadowOpacity = 0.12;
    hint.layer.shadowRadius = 8;
    hint.layer.shadowOffset = CGSizeMake(0, 3);
    hint.userInteractionEnabled = NO;
    hint.hidden = YES;
    hint.alpha = 0;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = [UIColor systemBlueColor];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightSemibold];
    icon.image = CLSymbolImage(@"info.circle.fill", config);

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor labelColor];
    label.numberOfLines = 0;
    label.text = CLL(@"已切换为系统电量控制，温度控制仍生效");

    [hint addSubview:icon];
    [hint addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:hint.leadingAnchor constant:12],
        [icon.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:hint.trailingAnchor constant:-12],
        [label.topAnchor constraintEqualToAnchor:hint.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:hint.bottomAnchor constant:-10]
    ]];

    UIView *container = self.contentContainerView ?: self.view;
    [container addSubview:hint];
    UILayoutGuide *betweenGuide = [[UILayoutGuide alloc] init];
    [container addLayoutGuide:betweenGuide];
    [NSLayoutConstraint activateConstraints:@[
        [betweenGuide.topAnchor constraintEqualToAnchor:self.controlCard.bottomAnchor],
        [betweenGuide.bottomAnchor constraintEqualToAnchor:self.limitCard.topAnchor],

        [hint.centerXAnchor constraintEqualToAnchor:self.mainStack.centerXAnchor],
        [hint.centerYAnchor constraintEqualToAnchor:betweenGuide.centerYAnchor],
        [hint.widthAnchor constraintLessThanOrEqualToAnchor:self.mainStack.widthAnchor constant:-24],
        [hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.mainStack.leadingAnchor constant:12],
        [hint.trailingAnchor constraintLessThanOrEqualToAnchor:self.mainStack.trailingAnchor constant:-12]
    ]];
    self.systemControlHintView = hint;
    self.systemControlHintLabel = label;
}

- (void)setupLimitCard {
    self.limitCard = [[CLGlassCard alloc] init];
    self.limitCard.viewController = self;
    
    __weak typeof(self) weakSelf = self;
    
    // 停止充电滑块 - 保存引用以便更新
    self.chargeAboveRow = [self.limitCard addSliderRowWithTitle:CLL(@"停止充电 (电量 ≥)") value:self.chargeAbove minValue:15 maxValue:100 color:[UIColor systemGreenColor] tag:201 onChange:^(NSInteger value) {
        NSInteger adjustedAbove = value;
        BOOL enforceEdge = (weakSelf.currentChargeMode == 1);
        NSInteger belowValue = weakSelf.chargeBelow;
        UISlider *belowSlider = [weakSelf sliderForTag:200];
        if (belowSlider) {
            belowValue = (NSInteger)roundf(belowSlider.value);
        }
        if (enforceEdge && adjustedAbove <= belowValue) {
            adjustedAbove = belowValue + 1;
            [weakSelf updateSliderValue:weakSelf.chargeAboveRow value:adjustedAbove];
            [weakSelf updateSliderLabel:weakSelf.chargeAboveRow value:adjustedAbove suffix:@"%"];
        }
        weakSelf.chargeAbove = adjustedAbove;
        weakSelf.batteryStatus.chargeAbove = adjustedAbove;
        [CLBatteryManager shared].chargeAbove = adjustedAbove;
        [weakSelf updateSystemControlHintForChargeAbove:adjustedAbove];
    } onLiveChange:^(NSInteger value) {
        // 实时更新电池图标上的标记线
        NSInteger adjustedValue = value;
        BOOL enforceEdge = (weakSelf.currentChargeMode == 1);
        NSInteger belowValue = weakSelf.chargeBelow;
        UISlider *belowSlider = [weakSelf sliderForTag:200];
        if (belowSlider) {
            belowValue = (NSInteger)roundf(belowSlider.value);
        }
        if (enforceEdge && adjustedValue <= belowValue) {
            adjustedValue = belowValue + 1;
            [weakSelf updateSliderValue:weakSelf.chargeAboveRow value:adjustedValue];
            [weakSelf updateSliderLabel:weakSelf.chargeAboveRow value:adjustedValue suffix:@"%"];
        }
        weakSelf.batteryStatus.chargeAbove = adjustedValue;
        [weakSelf updateSystemControlHintForChargeAbove:adjustedValue];
    }];
    [self attachSetCurrentButtonToChargeAboveRow];

    // 保存分隔线引用
    self.chargeBelowSeparator = [self.limitCard addSeparator];
    
    // 开始充电滑块 - 保存引用以便隐藏
    self.chargeBelowRow = [self.limitCard addSliderRowWithTitle:CLL(@"开始充电 (电量 ≤)") value:self.chargeBelow minValue:10 maxValue:95 color:[UIColor systemBlueColor] tag:200 onChange:^(NSInteger value) {
        NSInteger adjustedBelow = value;
        BOOL enforceEdge = (weakSelf.currentChargeMode == 1);
        NSInteger aboveValue = weakSelf.chargeAbove;
        UISlider *aboveSlider = [weakSelf sliderForTag:201];
        if (aboveSlider) {
            aboveValue = (NSInteger)roundf(aboveSlider.value);
        }
        if (enforceEdge && adjustedBelow >= aboveValue) {
            adjustedBelow = aboveValue - 1;
            [weakSelf updateSliderValue:weakSelf.chargeBelowRow value:adjustedBelow];
            [weakSelf updateSliderLabel:weakSelf.chargeBelowRow value:adjustedBelow suffix:@"%"];
        }
        weakSelf.chargeBelow = adjustedBelow;
        weakSelf.batteryStatus.chargeBelow = adjustedBelow;
        [CLBatteryManager shared].chargeBelow = adjustedBelow;
    } onLiveChange:^(NSInteger value) {
        // 实时更新电池图标上的标记线
        NSInteger adjustedValue = value;
        BOOL enforceEdge = (weakSelf.currentChargeMode == 1);
        NSInteger aboveValue = weakSelf.chargeAbove;
        UISlider *aboveSlider = [weakSelf sliderForTag:201];
        if (aboveSlider) {
            aboveValue = (NSInteger)roundf(aboveSlider.value);
        }
        if (enforceEdge && adjustedValue >= aboveValue) {
            adjustedValue = aboveValue - 1;
            [weakSelf updateSliderValue:weakSelf.chargeBelowRow value:adjustedValue];
            [weakSelf updateSliderLabel:weakSelf.chargeBelowRow value:adjustedValue suffix:@"%"];
        }
        weakSelf.batteryStatus.chargeBelow = adjustedValue;
    }];
    
    [self.mainStack addArrangedSubview:self.limitCard];
    
    // 默认模式是插电即充，隐藏开始充电选项
    self.currentChargeMode = 0;
    self.chargeBelowRow.hidden = YES;
    self.chargeBelowRow.alpha = 0;
}

- (void)attachSetCurrentButtonToChargeAboveRow {
    if (!self.chargeAboveRow || self.setChargeAboveCurrentButton || self.chargeAbovePresetButton) {
        return;
    }

    UILabel *valueLabel = (UILabel *)[self.chargeAboveRow viewWithTag:(201 + 10000)];
    if (![valueLabel isKindOfClass:[UILabel class]]) {
        return;
    }

    UILabel *titleLabel = nil;
    for (UIView *subview in self.chargeAboveRow.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview != valueLabel) {
            titleLabel = (UILabel *)subview;
            break;
        }
    }

    UIButton *presetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    presetButton.translatesAutoresizingMaskIntoConstraints = NO;
    presetButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    presetButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    presetButton.titleLabel.minimumScaleFactor = 0.85;
    presetButton.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    presetButton.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    presetButton.layer.cornerRadius = 11;
    if (@available(iOS 13.0, *)) {
        presetButton.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [presetButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [presetButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [presetButton addTarget:self action:@selector(chargeAbovePresetTapped) forControlEvents:UIControlEventTouchUpInside];
    presetButton.accessibilityLabel = CLL(@"预设");
    [self applyPressEffectToControl:presetButton];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(chargeAbovePresetLongPressed:)];
    longPress.minimumPressDuration = 0.45;
    longPress.cancelsTouchesInView = YES;
    [presetButton addGestureRecognizer:longPress];
    [self.chargeAboveRow addSubview:presetButton];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:CLL(@"设为当前") forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.85;
    button.tintColor = [UIColor systemGreenColor];
    button.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.16];
    button.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    button.layer.cornerRadius = 11;
    if (@available(iOS 13.0, *)) {
        button.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button addTarget:self action:@selector(setChargeAboveToCurrentTapped) forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = CLL(@"设为当前");
    [self applyPressEffectToControl:button];
    [self.chargeAboveRow addSubview:button];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [button.trailingAnchor constraintEqualToAnchor:valueLabel.leadingAnchor constant:-8],
        [button.centerYAnchor constraintEqualToAnchor:valueLabel.centerYAnchor],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:22],
        [presetButton.trailingAnchor constraintEqualToAnchor:button.leadingAnchor constant:-8],
        [presetButton.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [presetButton.heightAnchor constraintGreaterThanOrEqualToConstant:22]
    ]];
    if (titleLabel) {
        [constraints addObject:[presetButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:12]];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    self.chargeAbovePresetButton = presetButton;
    self.setChargeAboveCurrentButton = button;
    [self updateChargeAbovePresetButtonAppearance];
    [self updateSetChargeAboveCurrentButtonState];
}

- (void)updateChargeAbovePresetButtonAppearance {
    if (!self.chargeAbovePresetButton) {
        return;
    }

    NSInteger presetValue = CLStoredStopChargePresetValue();
    NSString *title = CLStopChargePresetButtonTitle(presetValue);
    UIColor *tintColor = CLStopChargePresetAccentColor();
    self.chargeAbovePresetButton.tintColor = tintColor;
    self.chargeAbovePresetButton.backgroundColor = [tintColor colorWithAlphaComponent:(presetValue > 0 ? 0.18 : 0.12)];
    [self.chargeAbovePresetButton setImage:nil forState:UIControlStateNormal];
    [self.chargeAbovePresetButton setTitle:title forState:UIControlStateNormal];
    self.chargeAbovePresetButton.accessibilityLabel = (presetValue > 0)
        ? [NSString stringWithFormat:@"%@ %@", CLL(@"预设"), CLStopChargePresetSettingsText(presetValue)]
        : CLL(@"预设");
}

- (void)updateSetChargeAboveCurrentButtonState {
    if (!self.setChargeAboveCurrentButton) {
        return;
    }
    CLBatteryManager *manager = [CLBatteryManager shared];
    BOOL enabled = manager.batteryInstalled && manager.currentCapacity > 0;
    self.setChargeAboveCurrentButton.enabled = enabled;
    self.setChargeAboveCurrentButton.alpha = enabled ? 1.0 : 0.45;
}

- (void)applyChargeAboveValue:(NSInteger)value emitFeedback:(BOOL)emitFeedback {
    self.chargeAbove = value;
    self.batteryStatus.chargeAbove = value;
    [CLBatteryManager shared].chargeAbove = value;

    [self updateSliderValue:self.chargeAboveRow value:value];
    [self updateSliderLabel:self.chargeAboveRow value:value suffix:@"%"];
    [self updateSystemControlHintForChargeAbove:value];

    if (emitFeedback) {
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
        }
    }
}

- (void)saveChargeAbovePresetValue:(NSInteger)value {
    CLStoreStopChargePresetValue(value);
    [self updateChargeAbovePresetButtonAppearance];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
}

- (void)presentChargeAbovePresetEditor {
    NSInteger currentPreset = CLStoredStopChargePresetValue();
    NSInteger suggestedValue = currentPreset > 0 ? currentPreset : self.chargeAbove;
    __weak typeof(self) weakSelf = self;
    CLPresentStopChargePresetEditor(self,
                                    currentPreset,
                                    suggestedValue,
                                    ^(NSInteger value) {
        [weakSelf saveChargeAbovePresetValue:value];
    }, ^{
        CLStoreStopChargePresetValue(0);
        [weakSelf updateChargeAbovePresetButtonAppearance];
    });
}

- (void)chargeAbovePresetTapped {
    NSInteger presetValue = CLStoredStopChargePresetValue();
    if (presetValue <= 0) {
        [self presentChargeAbovePresetEditor];
        return;
    }

    UISlider *slider = [self sliderForTag:201];
    if (!slider) {
        return;
    }
    NSInteger adjustedValue = [self normalizedChargeValueForSlider:slider value:presetValue];
    [self applyChargeAboveValue:adjustedValue emitFeedback:YES];
}

- (void)chargeAbovePresetLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    [self presentChargeAbovePresetEditor];
}

- (void)setChargeAboveToCurrentTapped {
    CLBatteryManager *manager = [CLBatteryManager shared];
    UISlider *slider = [self sliderForTag:201];
    if (!slider || !manager.batteryInstalled || manager.currentCapacity <= 0) {
        return;
    }

    NSInteger minValue = (NSInteger)roundf(slider.minimumValue);
    NSInteger maxValue = (NSInteger)roundf(slider.maximumValue);
    NSInteger clampedValue = MIN(MAX(manager.currentCapacity, minValue), maxValue);
    NSInteger adjustedValue = [self normalizedChargeValueForSlider:slider value:clampedValue];
    [self applyChargeAboveValue:adjustedValue emitFeedback:YES];
}

- (void)setupTempCard {
    self.tempCard = [[CLGlassCard alloc] init];
    self.tempCard.viewController = self;
    
    __weak typeof(self) weakSelf = self;
    CLBatteryManager *manager = [CLBatteryManager shared];
    
    // 温度控制开关
    [self.tempCard addSwitchRowWithIcon:@"thermometer.sun" title:CLL(@"温度控制") isOn:manager.tempControlEnabled color:[UIColor systemOrangeColor] tag:250 onChange:^(BOOL isOn) {
        [CLBatteryManager shared].tempControlEnabled = isOn;
        [weakSelf updateTempControlVisibility:isOn];
        [weakSelf.view setNeedsLayout];
        [weakSelf.view layoutIfNeeded];
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
    self.tempControlsShouldBeVisible = visible;

    NSMutableArray<UIView *> *targets = [NSMutableArray array];
    if (self.tempAboveRow) [targets addObject:self.tempAboveRow];
    if (self.tempSeparator2) [targets addObject:self.tempSeparator2];
    if (self.tempBelowRow) [targets addObject:self.tempBelowRow];
    if (self.tempSeparator1) [targets addObject:self.tempSeparator1];
    if (targets.count == 0) {
        return;
    }

    for (UIView *v in targets) {
        [v.layer removeAllAnimations];
    }

    if (visible) {
        for (UIView *v in targets) {
            if (v.hidden) {
                v.alpha = 0.0;
            }
            v.hidden = NO;
        }
        [self.view layoutIfNeeded];
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            for (UIView *v in targets) {
                v.alpha = 1.0;
            }
            [self.mainStack layoutIfNeeded];
        } completion:nil];
    } else {
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            for (UIView *v in targets) {
                v.alpha = 0.0;
            }
            [self.mainStack layoutIfNeeded];
        } completion:^(BOOL finished) {
            if (self.tempControlsShouldBeVisible) {
                return;
            }
            for (UIView *v in targets) {
                v.hidden = YES;
            }
        }];
    }
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

- (void)setupPowerPathCard {
    self.powerPathCard = [[CLGlassCard alloc] init];

    [self.powerPathCard addRowWithIcon:@"point.topleft.down.curvedto.point.bottomright.up" title:CLL(@"供电状态") value:CLL(@"使用电池") color:[UIColor systemBlueColor]];
    [self.powerPathCard addSeparator];
    [self.powerPathCard addRowWithIcon:@"bolt.shield" title:CLL(@"充电命令") value:CLL(@"允许充电") color:[UIColor systemGreenColor]];
    [self.powerPathCard addSeparator];
    [self.powerPathCard addRowWithIcon:@"bolt.slash" title:CLL(@"系统停充抑制") value:CLL(@"未启用") color:[UIColor systemRedColor]];
    [self.powerPathCard addSeparator];
    [self.powerPathCard addRowWithIcon:@"battery.100.circle" title:CLL(@"系统优化充电") value:CLL(@"未知") color:[UIColor systemBlueColor]];
    [self.powerPathCard addSeparator];
    [self.powerPathCard addRowWithIcon:@"slider.horizontal.3" title:CLL(@"保持策略") value:CLL(@"平衡") color:[UIColor systemIndigoColor]];
    [self.powerPathCard addSeparator];
    [self.powerPathCard addRowWithIcon:@"scope" title:CLL(@"保持范围") value:@"--" color:[UIColor systemIndigoColor]];

    [self.mainStack addArrangedSubview:self.powerPathCard];
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
    entry.userInteractionEnabled = YES;
    entry.accessibilityTraits = UIAccessibilityTraitButton;
    [entry addTarget:self action:@selector(softwareSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self applyPressEffectToControl:entry];
    
    UIView *iconWrap = [[UIView alloc] init];
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    iconWrap.userInteractionEnabled = NO;
    iconWrap.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
    iconWrap.layer.cornerRadius = 18;
    [entry addSubview:iconWrap];
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    iconView.image = CLSymbolImage(@"gearshape.2.fill", iconConfig);
    iconView.tintColor = [UIColor systemBlueColor];
    [iconWrap addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.userInteractionEnabled = NO;
    titleLabel.text = CLL(@"软件设置");
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.userInteractionEnabled = NO;
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 2;
    self.softwareSettingsSubtitleLabel = subtitleLabel;
    [self updateSoftwareSettingsEntrySubtitle];
    
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.userInteractionEnabled = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;
    [entry addSubview:textStack];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.userInteractionEnabled = NO;
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

- (NSString *)softwareSettingsSubtitleText {
    return CLL(@"刷新频率 / 语言 / 外观 / 配置");
}

- (void)updateSoftwareSettingsEntrySubtitle {
    if (!self.softwareSettingsSubtitleLabel) {
        return;
    }
    self.softwareSettingsSubtitleLabel.text = [self softwareSettingsSubtitleText];
    self.softwareSettingsSubtitleLabel.textColor = [UIColor secondaryLabelColor];
}

- (void)setupHistoryEntryCard {
    self.historyEntryCard = [[CLGlassCard alloc] init];
    
    UIControl *entry = [[UIControl alloc] init];
    entry.translatesAutoresizingMaskIntoConstraints = NO;
    entry.layer.cornerRadius = 12;
    entry.clipsToBounds = YES;
    entry.userInteractionEnabled = YES;
    entry.accessibilityTraits = UIAccessibilityTraitButton;
    [entry addTarget:self action:@selector(historyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self applyPressEffectToControl:entry];
    
    UIView *iconWrap = [[UIView alloc] init];
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    iconWrap.userInteractionEnabled = NO;
    iconWrap.backgroundColor = [[UIColor systemTealColor] colorWithAlphaComponent:0.15];
    iconWrap.layer.cornerRadius = 18;
    [entry addSubview:iconWrap];
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    iconView.image = CLSymbolImage(@"chart.line.uptrend.xyaxis", iconConfig);
    iconView.tintColor = [UIColor systemTealColor];
    [iconWrap addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.userInteractionEnabled = NO;
    titleLabel.text = CLL(@"历史统计");
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.userInteractionEnabled = NO;
    subtitleLabel.text = CLL(@"5分钟/小时/天/月趋势图表");
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.userInteractionEnabled = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;
    [entry addSubview:textStack];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.userInteractionEnabled = NO;
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
    entry.userInteractionEnabled = YES;
    entry.accessibilityTraits = UIAccessibilityTraitButton;
    [entry addTarget:self action:@selector(advancedTapped) forControlEvents:UIControlEventTouchUpInside];
    [self applyPressEffectToControl:entry];
    
    UIView *iconWrap = [[UIView alloc] init];
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    iconWrap.userInteractionEnabled = NO;
    iconWrap.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.15];
    iconWrap.layer.cornerRadius = 18;
    [entry addSubview:iconWrap];
    
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightSemibold];
    iconView.image = CLSymbolImage(@"slider.horizontal.3", iconConfig);
    iconView.tintColor = [UIColor systemOrangeColor];
    [iconWrap addSubview:iconView];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.userInteractionEnabled = NO;
    titleLabel.text = CLL(@"充电高级");
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.userInteractionEnabled = NO;
    subtitleLabel.text = CLL(@"停充 / 限流 / 高温模拟");
    subtitleLabel.font = [UIFont systemFontOfSize:12];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.userInteractionEnabled = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;
    [entry addSubview:textStack];
    
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.userInteractionEnabled = NO;
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

#pragma mark - Slider Constraint

- (UISlider *)sliderForTag:(NSInteger)tag {
    for (UIView *row in self.limitCard.contentStack.arrangedSubviews) {
        UIView *maybeSlider = [row viewWithTag:tag];
        if ([maybeSlider isKindOfClass:[UISlider class]]) {
            return (UISlider *)maybeSlider;
        }
    }
    return nil;
}

static const NSInteger CLDisplayChargingThresholdmA = 120;
static const NSInteger CLDisplayDischargingThresholdmA = -120;

static NSInteger CLEffectiveBatteryCurrentForManager(CLBatteryManager *manager) {
    if (!manager) {
        return 0;
    }
    if (manager.instantAmperage != 0) {
        return manager.instantAmperage;
    }
    return manager.amperage;
}

static BOOL CLManagerLooksChargingForDisplay(CLBatteryManager *manager) {
    if (!manager) {
        return NO;
    }
    NSInteger current = CLEffectiveBatteryCurrentForManager(manager);
    return manager.isCharging || manager.holdCharging || current > CLDisplayChargingThresholdmA;
}

static BOOL CLManagerLooksDischargingForDisplay(CLBatteryManager *manager) {
    if (!manager) {
        return NO;
    }
    return CLEffectiveBatteryCurrentForManager(manager) < CLDisplayDischargingThresholdmA;
}

static NSString *CLDisplayedPowerStateForManager(CLBatteryManager *manager) {
    if (!manager) {
        return @"battery";
    }

    NSString *policyState = [manager.policyState isKindOfClass:[NSString class]] ? manager.policyState : @"";
    if (CLManagerLooksChargingForDisplay(manager)) {
        if ([policyState isEqualToString:@"hold_recharge"] || manager.holdCharging) {
            return @"hold_recharge";
        }
        return @"charging";
    }
    if ([policyState isEqualToString:@"no_inflow"]) {
        return @"battery";
    }
    if (CLManagerLooksDischargingForDisplay(manager)) {
        return @"battery";
    }

    BOOL hasRealtimeExternalPower = manager.externalConnected
        || manager.adapterWatts > 0
        || (manager.adapterCurrent > 0 && manager.adapterVoltage > 0.1);
    if (!hasRealtimeExternalPower) {
        return @"battery";
    }
    if ([policyState isEqualToString:@"temp_paused"]) {
        return @"temp_paused";
    }
    if ([policyState isEqualToString:@"hold"] || manager.holdActive) {
        return @"hold";
    }
    if ([policyState isEqualToString:@"stopped"] || manager.predictiveChargingInhibitActive || !manager.chargeCommandEnabled) {
        return @"stopped";
    }
    return @"external_idle";
}

static BOOL CLDisplayedPowerStateUsesExternalPower(CLBatteryManager *manager) {
    return ![[CLDisplayedPowerStateForManager(manager) lowercaseString] isEqualToString:@"battery"];
}

- (NSInteger)normalizedChargeValueForSlider:(UISlider *)slider value:(NSInteger)value {
    BOOL enforceEdge = (self.currentChargeMode == 1);
    if (!enforceEdge) {
        return value;
    }
    if (slider.tag == 201) { // stop charge
        NSInteger belowValue = self.chargeBelow;
        UISlider *belowSlider = [self sliderForTag:200];
        if (belowSlider) {
            belowValue = (NSInteger)roundf(belowSlider.value);
        }
        if (value <= belowValue) {
            return belowValue + 1;
        }
    }
    if (slider.tag == 200) { // start charge
        NSInteger aboveValue = self.chargeAbove;
        UISlider *aboveSlider = [self sliderForTag:201];
        if (aboveSlider) {
            aboveValue = (NSInteger)roundf(aboveSlider.value);
        }
        if (value >= aboveValue) {
            return aboveValue - 1;
        }
    }
    return value;
}

#pragma mark - Navigation Actions

- (void)chargeModesTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CLL(@"充电模式") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"插电即充") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [CLBatteryManager shared].chargeMode = CLChargeModePlugAndCharge;
        [self updateCardValue:self.controlCard title:CLL(@"充电模式") value:CLL(@"插电即充")];
        self.currentChargeMode = 0;
        [self updateChargeBelowVisibility];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"边缘触发") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [CLBatteryManager shared].chargeMode = CLChargeModeEdgeTrigger;
        [self updateCardValue:self.controlCard title:CLL(@"充电模式") value:CLL(@"边缘触发")];
        self.currentChargeMode = 1;
        [self updateChargeBelowVisibility];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:CLL(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0, 0);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }
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

- (void)updateSystemControlHintForChargeAbove:(NSInteger)newValue {
    CLBatteryManager *manager = [CLBatteryManager shared];
    BOOL oldSystemControlActive = self.lastSystemCapacityControlActiveForHint;
    BOOL newSystemControlActive = [self usesSystemCapacityControlForManager:manager chargeAbove:newValue];
    self.lastChargeAboveForHint = newValue;
    self.lastSystemCapacityControlActiveForHint = newSystemControlActive;
    if (!oldSystemControlActive && newSystemControlActive) {
        [self showSystemControlHintWithText:CLL(@"已切换为系统电量控制，温度控制仍生效，插电保持暂时停用")];
    } else if (oldSystemControlActive && !newSystemControlActive) {
        [self showSystemControlHintWithText:CLL(@"已恢复停充控制，插电保持设置已恢复可用")];
    }
}

- (void)showSystemControlHint {
    [self showSystemControlHintWithText:CLL(@"已切换为系统电量控制，温度控制仍生效")];
}

- (void)showSystemControlHintWithText:(NSString *)text {
    if (!self.isViewLoaded) {
        return;
    }
    if (!self.systemControlHintView || !self.systemControlHintLabel) {
        return;
    }

    self.systemControlHintLabel.text = text.length > 0 ? text : CLL(@"已切换为系统电量控制，温度控制仍生效");
    [self.systemControlHintTimer invalidate];
    self.systemControlHintView.hidden = NO;
    self.systemControlHintView.transform = CGAffineTransformMakeTranslation(0, -4);
    self.systemControlHintTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        [UIView animateWithDuration:0.2 animations:^{
            self.systemControlHintView.alpha = 0;
            self.systemControlHintView.transform = CGAffineTransformMakeTranslation(0, -4);
        } completion:^(BOOL finished) {
            self.systemControlHintView.hidden = YES;
            self.systemControlHintView.transform = CGAffineTransformIdentity;
        }];
    }];

    [UIView animateWithDuration:0.2 animations:^{
        self.systemControlHintView.alpha = 1;
        self.systemControlHintView.transform = CGAffineTransformIdentity;
    }];
}

- (void)advancedTapped {
    Class vcClass = NSClassFromString(@"CLAdvancedSettingsViewController");
    if (vcClass) {
        UIViewController *vc = [[vcClass alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark - Touch Feedback

- (void)applyPressEffectToControl:(UIControl *)control {
    [control addTarget:self action:@selector(entryTouchDown:) forControlEvents:UIControlEventTouchDown];
    [control addTarget:self action:@selector(entryTouchUp:) forControlEvents:UIControlEventTouchUpInside];
    [control addTarget:self action:@selector(entryTouchUp:) forControlEvents:UIControlEventTouchUpOutside];
    [control addTarget:self action:@selector(entryTouchUp:) forControlEvents:UIControlEventTouchCancel];
}

- (void)entryTouchDown:(UIControl *)sender {
    [UIView animateWithDuration:0.12 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.98, 0.98);
        sender.alpha = 0.88;
    }];
}

- (void)entryTouchUp:(UIControl *)sender {
    [UIView animateWithDuration:0.16 animations:^{
        sender.transform = CGAffineTransformIdentity;
        sender.alpha = 1.0;
    }];
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

#pragma mark - Refresh Now

- (void)refreshNowTapped {
    self.refreshButton.enabled = NO;
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    [UIView animateWithDuration:0.2 animations:^{
        self.refreshButton.transform = CGAffineTransformMakeRotation((CGFloat)M_PI);
    } completion:^(BOOL finished) {
        self.refreshButton.transform = CGAffineTransformIdentity;
    }];

    CLAPIClient *api = [CLAPIClient shared];
    [api applyNowWithCompletion:^(NSDictionary * _Nullable resp, NSError * _Nullable err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshButton.enabled = YES;
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[CLBatteryManager shared] refreshAll];
        });
    }];
}

- (void)applicationDidBecomeActive {
    [[CLUpdateCheckManager sharedManager] performAutomaticCheck];
}

- (void)updateCheckStatusDidChange {
    [self updateSoftwareSettingsEntrySubtitle];
}

#pragma mark - Update UI

- (void)batteryInfoDidUpdate {
    CLBatteryManager *manager = [CLBatteryManager shared];
    NSString *powerStateLabel = [self powerStateLabelForManager:manager];
    [self updateSetChargeAboveCurrentButtonState];

    // 更新电池状态
    [self.batteryStatus applyBatteryManager:manager statusText:powerStateLabel];
    
    // 更新信息卡片
    CGFloat health = manager.designCapacity > 0 ? (manager.nominalCapacity * 100.0 / manager.designCapacity) : 100;
    [self updateCardValue:self.infoCard title:CLL(@"电池健康") value:[NSString stringWithFormat:@"%.0f%%", health]];
    [self updateCardValue:self.infoCard title:CLL(@"温度") value:[NSString stringWithFormat:@"%.1f°C", manager.temperature]];
    [self updateCardValue:self.infoCard title:CLL(@"高温模拟") value:[self thermalModeLabel:manager.thermalSimulateMode]];
    [self updateCardValue:self.infoCard title:CLL(@"电流") value:[NSString stringWithFormat:@"%ld mA", (long)manager.amperage]];
    [self updateCardValue:self.infoCard title:CLL(@"电压") value:[NSString stringWithFormat:@"%.2f V", manager.voltage]];
    [self updateCardValue:self.infoCard title:CLL(@"循环") value:[NSString stringWithFormat:@"%ld 次", (long)manager.cycleCount]];
    
    [self updateCardValue:self.powerPathCard title:CLL(@"供电状态") value:powerStateLabel];
    [self updateCardValue:self.powerPathCard title:CLL(@"充电命令") value:[self chargeCommandLabelForManager:manager]];
    [self updateCardValue:self.powerPathCard title:CLL(@"系统停充抑制") value:(manager.predictiveChargingInhibitActive ? CLL(@"已启用") : CLL(@"未启用"))];
    [self updateCardValue:self.powerPathCard title:CLL(@"系统优化充电") value:[self smartChargeStatusLabelForManager:manager]];
    [self updateCardValue:self.powerPathCard title:CLL(@"保持策略") value:[self holdBehaviorLabelForManager:manager]];
    [self updateCardValue:self.powerPathCard title:CLL(@"保持范围") value:[self holdRangeLabelForManager:manager]];

    // 更新适配器卡片
    BOOL hasExternalPower = CLDisplayedPowerStateUsesExternalPower(manager);
    if (hasExternalPower && manager.adapterName.length > 0) {
        [self updateCardValue:self.adapterCard title:CLL(@"适配器") value:manager.adapterName];
        [self updateCardValue:self.adapterCard title:CLL(@"输出功率") value:[NSString stringWithFormat:@"%ld W", (long)manager.adapterWatts]];
        [self updateCardValue:self.adapterCard title:CLL(@"输入电压") value:[NSString stringWithFormat:@"%.1f V", manager.adapterVoltage]];
    } else if (hasExternalPower) {
        [self updateCardValue:self.adapterCard title:CLL(@"适配器") value:CLL(@"已连接")];
        CGFloat watts = manager.adapterWatts > 0 ? manager.adapterWatts : ((manager.adapterVoltage * manager.adapterCurrent) / 1000.0);
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
        for (UIView *subview in row.subviews) {
            if (![subview isKindOfClass:[UILabel class]]) {
                continue;
            }
            UILabel *label = (UILabel *)subview;
            NSString *labelTitle = objc_getAssociatedObject(label, kCLCardValueTitleKey);
            if (labelTitle.length > 0) {
                if ([labelTitle isEqualToString:title]) {
                    label.text = value;
                    return;
                }
            } else if (label.tag == tag) {
                // Fallback for legacy labels not carrying title association.
                label.text = value;
                return;
            }
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

- (UISwitch *)switchInCard:(CLGlassCard *)card tag:(NSInteger)tag {
    for (UIView *row in card.contentStack.arrangedSubviews) {
        UISwitch *switchControl = [row viewWithTag:tag];
        if ([switchControl isKindOfClass:[UISwitch class]]) {
            return switchControl;
        }
    }
    return nil;
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

- (NSString *)powerStateLabelForManager:(CLBatteryManager *)manager {
    NSString *policyState = CLDisplayedPowerStateForManager(manager);
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
    return CLL(@"使用电池");
}

- (NSString *)chargeCommandLabelForManager:(CLBatteryManager *)manager {
    return manager.chargeCommandEnabled ? CLL(@"允许充电") : CLL(@"保持停止");
}

- (NSString *)smartChargeStatusLabelForManager:(CLBatteryManager *)manager {
    switch (manager.smartChargeStatus) {
        case 0:
            return CLL(@"已关闭");
        case 1:
            return CLL(@"已启用");
        case 2:
            return CLL(@"满充窗口");
        case 3:
            return manager.smartChargeManagedByDaemon ? CLL(@"已临时停用 · 由本工具控制") : CLL(@"已临时停用");
        default:
            return CLL(@"未知");
    }
}

- (BOOL)usesSystemCapacityControlForManager:(CLBatteryManager *)manager chargeAbove:(NSInteger)chargeAbove {
    return chargeAbove >= 100 && manager.systemCapacityControlAt100Enabled;
}

- (BOOL)isHoldSuppressedBySystemCapacityControlForManager:(CLBatteryManager *)manager {
    return [self usesSystemCapacityControlForManager:manager chargeAbove:manager.chargeAbove];
}

- (NSString *)holdRangeLabelForManager:(CLBatteryManager *)manager {
    if ([self isHoldSuppressedBySystemCapacityControlForManager:manager]) {
        return CLL(@"系统控制");
    }
    if (!manager.holdModeEnabled || manager.holdTarget <= 0) {
        return CLL(@"关闭");
    }
    NSInteger lower = MAX(manager.holdRangeLower, 0);
    return [NSString stringWithFormat:@"%ld%% - %ld%%", (long)lower, (long)manager.holdTarget];
}

- (NSString *)fixedHoldBehaviorLabel:(CLHoldModeBehavior)behavior {
    switch (behavior) {
        case CLHoldModeBehaviorAdaptive:
            return CLL(@"智能自适应");
        case CLHoldModeBehaviorPowerFirst:
            return CLL(@"偏向外接供电");
        case CLHoldModeBehaviorBatteryFirst:
            return CLL(@"偏向减少循环");
        default:
            return CLL(@"平衡");
    }
}

- (NSString *)holdBehaviorLabelForManager:(CLBatteryManager *)manager {
    if ([self isHoldSuppressedBySystemCapacityControlForManager:manager]) {
        return CLL(@"系统控制");
    }
    if (manager.holdModeBehavior == CLHoldModeBehaviorAdaptive) {
        if (!manager.holdModeEnabled) {
            return [NSString stringWithFormat:@"%@ · %@", CLL(@"智能自适应"), CLL(@"未启用")];
        }
        return [NSString stringWithFormat:CLL(@"智能自适应 · 当前%@"),
                [self fixedHoldBehaviorLabel:manager.holdRuntimeBehavior]];
    }
    return [self fixedHoldBehaviorLabel:manager.holdModeBehavior];
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
    NSInteger chargeBelow = manager.chargeBelow;
    NSInteger chargeAbove = manager.chargeAbove;
    if (self.currentChargeMode == 1) { // 边缘触发：开始充电必须小于停止充电
        if (chargeBelow >= chargeAbove) {
            chargeBelow = MAX(10, chargeAbove - 5);
            if (chargeBelow >= chargeAbove) {
                chargeAbove = MIN(100, chargeBelow + 5);
            }
            manager.chargeBelow = chargeBelow;
            manager.chargeAbove = chargeAbove;
        }
    }
    self.chargeBelow = chargeBelow;
    self.chargeAbove = chargeAbove;
    self.lastChargeAboveForHint = chargeAbove;
    self.lastSystemCapacityControlActiveForHint = [self usesSystemCapacityControlForManager:manager chargeAbove:chargeAbove];
    [self updateChargeAbovePresetButtonAppearance];
    [self updateSliderValue:self.chargeBelowRow value:chargeBelow];
    [self updateSliderValue:self.chargeAboveRow value:chargeAbove];
    [self updateSliderLabel:self.chargeBelowRow value:chargeBelow suffix:@"%"];
    [self updateSliderLabel:self.chargeAboveRow value:chargeAbove suffix:@"%"];
    self.batteryStatus.chargeBelow = chargeBelow;
    self.batteryStatus.chargeAbove = chargeAbove;
    [self updateCardValue:self.powerPathCard title:CLL(@"保持策略") value:[self holdBehaviorLabelForManager:manager]];
    [self updateCardValue:self.powerPathCard title:CLL(@"保持范围") value:[self holdRangeLabelForManager:manager]];
    
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
    
    [self updateSoftwareSettingsEntrySubtitle];
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
    [self updateSoftwareSettingsEntrySubtitle];
}

@end
