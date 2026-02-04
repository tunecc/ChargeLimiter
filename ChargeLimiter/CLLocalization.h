#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CLAppLanguage) {
    CLAppLanguageSystem = 0,
    CLAppLanguageEnglish = 1,
    CLAppLanguageChineseSimplified = 2
};

FOUNDATION_EXPORT NSString * const CLAppLanguageDidChangeNotification;

FOUNDATION_EXPORT NSString *CLLocalizedString(NSString *key);
FOUNDATION_EXPORT void CLApplyLanguageFromSettings(void);
FOUNDATION_EXPORT void CLSetAppLanguage(CLAppLanguage language);
FOUNDATION_EXPORT CLAppLanguage CLGetAppLanguage(void);

#define CLL(key) CLLocalizedString((key))
