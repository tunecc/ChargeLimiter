//
//  CLTheme.m
//  ChargeLimiter
//

#import "CLTheme.h"

@implementation CLTheme

#pragma mark - 颜色

+ (UIColor *)primaryColor {
    return [UIColor colorWithRed:64/255.0 green:158/255.0 blue:255/255.0 alpha:1.0]; // #409EFF
}

+ (UIColor *)successColor {
    return [UIColor colorWithRed:52/255.0 green:199/255.0 blue:89/255.0 alpha:1.0]; // #34C759
}

+ (UIColor *)warningColor {
    return [UIColor colorWithRed:248/255.0 green:128/255.0 blue:27/255.0 alpha:1.0]; // #F8801B
}

+ (UIColor *)dangerColor {
    return [UIColor colorWithRed:255/255.0 green:59/255.0 blue:48/255.0 alpha:1.0]; // #FF3B30
}

+ (UIColor *)infoColor {
    return [UIColor colorWithRed:77/255.0 green:127/255.0 blue:252/255.0 alpha:1.0]; // #4D7FFC
}

+ (UIColor *)backgroundColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
            if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:0 green:0 blue:0 alpha:1.0];
            } else {
                return [UIColor colorWithRed:239/255.0 green:239/255.0 blue:244/255.0 alpha:1.0];
            }
        }];
    }
    return [UIColor colorWithRed:239/255.0 green:239/255.0 blue:244/255.0 alpha:1.0];
}

+ (UIColor *)cardBackgroundColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
            if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:28/255.0 green:28/255.0 blue:30/255.0 alpha:1.0];
            } else {
                return [UIColor whiteColor];
            }
        }];
    }
    return [UIColor whiteColor];
}

+ (UIColor *)separatorColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor separatorColor];
    }
    return [UIColor colorWithRed:200/255.0 green:200/255.0 blue:200/255.0 alpha:1.0];
}

+ (UIColor *)primaryTextColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor labelColor];
    }
    return [UIColor blackColor];
}

+ (UIColor *)secondaryTextColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor secondaryLabelColor];
    }
    return [UIColor grayColor];
}

+ (UIColor *)tertiaryTextColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor tertiaryLabelColor];
    }
    return [UIColor lightGrayColor];
}

#pragma mark - 尺寸

+ (CGFloat)cardCornerRadius {
    return 15.0;
}

+ (CGFloat)buttonCornerRadius {
    return 8.0;
}

+ (CGFloat)marginSmall {
    return 8.0;
}

+ (CGFloat)marginMedium {
    return 16.0;
}

+ (CGFloat)marginLarge {
    return 24.0;
}

+ (UIFont *)titleFont {
    return [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
}

+ (UIFont *)bodyFont {
    return [UIFont systemFontOfSize:17];
}

+ (UIFont *)captionFont {
    return [UIFont systemFontOfSize:13];
}

+ (UIFont *)smallFont {
    return [UIFont systemFontOfSize:10];
}

#pragma mark - 工具方法

+ (void)applyCardStyleToView:(UIView *)view {
    view.backgroundColor = [self cardBackgroundColor];
    view.layer.cornerRadius = [self cardCornerRadius];
    view.layer.masksToBounds = NO;
    
    // 阴影效果（仅亮色模式）
    if (![self isDarkMode]) {
        view.layer.shadowColor = [UIColor blackColor].CGColor;
        view.layer.shadowOffset = CGSizeMake(0, 2);
        view.layer.shadowOpacity = 0.1;
        view.layer.shadowRadius = 4;
    }
}

+ (BOOL)isDarkMode {
    if (@available(iOS 13.0, *)) {
        return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

@end
