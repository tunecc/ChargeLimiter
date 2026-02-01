//
//  CLTheme.h
//  ChargeLimiter
//
//  主题管理 - 颜色、字体、尺寸定义
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLTheme : NSObject

#pragma mark - 颜色

// 主色调
+ (UIColor *)primaryColor; // 蓝色 #409EFF
+ (UIColor *)successColor; // 绿色 #34C759
+ (UIColor *)warningColor; // 橙色 #F8801B
+ (UIColor *)dangerColor;  // 红色 #FF3B30
+ (UIColor *)infoColor;    // 蓝色 #4D7FFC

// 背景色
+ (UIColor *)backgroundColor;     // 页面背景
+ (UIColor *)cardBackgroundColor; // 卡片背景
+ (UIColor *)separatorColor;      // 分割线

// 文字颜色
+ (UIColor *)primaryTextColor;   // 主要文字
+ (UIColor *)secondaryTextColor; // 次要文字（灰色）
+ (UIColor *)tertiaryTextColor;  // 第三级文字

#pragma mark - 尺寸

// 圆角
+ (CGFloat)cardCornerRadius;   // 卡片圆角 15
+ (CGFloat)buttonCornerRadius; // 按钮圆角 8

// 间距
+ (CGFloat)marginSmall;  // 小间距 8
+ (CGFloat)marginMedium; // 中间距 16
+ (CGFloat)marginLarge;  // 大间距 24

// 字体大小
+ (UIFont *)titleFont;   // 标题 20
+ (UIFont *)bodyFont;    // 正文 17
+ (UIFont *)captionFont; // 说明 13
+ (UIFont *)smallFont;   // 小字 10

#pragma mark - 工具方法

// 创建带圆角阴影的卡片效果
+ (void)applyCardStyleToView:(UIView *)view;

// 深色模式检测
+ (BOOL)isDarkMode;

@end

NS_ASSUME_NONNULL_END
