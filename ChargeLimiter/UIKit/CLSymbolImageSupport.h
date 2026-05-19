#import <UIKit/UIKit.h>

NS_INLINE void CLAppendSymbolCandidate(NSMutableArray<NSString *> *candidates, NSString *candidate) {
    if (candidate.length == 0) {
        return;
    }
    if (![candidates containsObject:candidate]) {
        [candidates addObject:candidate];
    }
}

NS_INLINE NSDictionary<NSString *, NSArray<NSString *> *> *CLSymbolFallbackMap(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *fallbacks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fallbacks = @{
            @"battery.100.circle": @[@"battery.100"],
            @"bolt.batteryblock": @[@"battery.100.bolt", @"bolt.fill"],
            @"bolt.shield": @[@"bolt.fill", @"bolt.circle"],
            @"chart.line.uptrend.xyaxis": @[@"chart.xyaxis.line", @"chart.bar"],
            @"clock.badge.checkmark": @[@"clock"],
            @"folder.badge.gearshape": @[@"folder"],
            @"point.topleft.down.curvedto.point.bottomright.up": @[@"arrow.left.arrow.right"],
            @"powerplug.fill": @[@"powerplug", @"bolt.fill"],
            @"thermometer.medium": @[@"thermometer"],
            @"thermometer.sun.fill": @[@"thermometer", @"thermometer.medium"],
            @"thermometer.sun": @[@"thermometer", @"thermometer.medium"],
            @"waveform.path.ecg": @[@"wave.3.right", @"chart.bar"]
        };
    });
    return fallbacks;
}

NS_INLINE NSArray<NSString *> *CLSymbolCandidates(NSString *name) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    CLAppendSymbolCandidate(candidates, name);

    for (NSString *fallback in CLSymbolFallbackMap()[name]) {
        CLAppendSymbolCandidate(candidates, fallback);
    }

    if ([name hasPrefix:@"battery."]) {
        CLAppendSymbolCandidate(candidates, @"battery.100");
    } else if ([name hasPrefix:@"bolt."]) {
        CLAppendSymbolCandidate(candidates, @"bolt.fill");
        CLAppendSymbolCandidate(candidates, @"bolt.circle");
    } else if ([name hasPrefix:@"chart."]) {
        CLAppendSymbolCandidate(candidates, @"chart.bar");
    } else if ([name hasPrefix:@"clock."]) {
        CLAppendSymbolCandidate(candidates, @"clock");
    } else if ([name hasPrefix:@"powerplug"]) {
        CLAppendSymbolCandidate(candidates, @"powerplug");
        CLAppendSymbolCandidate(candidates, @"bolt.fill");
    } else if ([name hasPrefix:@"thermometer."]) {
        CLAppendSymbolCandidate(candidates, @"thermometer");
    } else if ([name hasPrefix:@"waveform."]) {
        CLAppendSymbolCandidate(candidates, @"wave.3.right");
        CLAppendSymbolCandidate(candidates, @"chart.bar");
    }

    CLAppendSymbolCandidate(candidates, @"questionmark.circle");
    return candidates;
}

NS_INLINE UIImage *CLSymbolImage(NSString *name, UIImageSymbolConfiguration *config) {
    if (name.length == 0) {
        return nil;
    }

    for (NSString *candidate in CLSymbolCandidates(name)) {
        UIImage *image = [UIImage systemImageNamed:candidate withConfiguration:config];
        if (image) {
            return image;
        }
    }
    return nil;
}
