#import "CLLocalization.h"
#import "UIKit/CLAppSettingsStore.h"

#import <Foundation/Foundation.h>

extern "C" NSUserDefaults* getAppUserDefaults(void);

#pragma mark - Localization

NSString * const CLAppLanguageDidChangeNotification = @"CLAppLanguageDidChangeNotification";

static NSBundle *gLocalizationBundle = nil;

static NSBundle *CLLocalizationBundle(void) {
    if (!gLocalizationBundle) {
        gLocalizationBundle = [NSBundle mainBundle];
    }
    return gLocalizationBundle;
}

static void CLSetLocalizationBundle(NSString *languageCode) {
    if (!languageCode || languageCode.length == 0) {
        gLocalizationBundle = [NSBundle mainBundle];
        return;
    }
    NSString *path = [[NSBundle mainBundle] pathForResource:languageCode ofType:@"lproj"];
    if (path.length > 0) {
        gLocalizationBundle = [NSBundle bundleWithPath:path];
    } else {
        gLocalizationBundle = [NSBundle mainBundle];
    }
}

static void CLSetAppleLanguages(NSArray<NSString *> *languages) {
    NSUserDefaults *defaults = getAppUserDefaults();
    if (languages.count > 0) {
        [defaults setObject:languages forKey:@"AppleLanguages"];
    } else {
        [defaults removeObjectForKey:@"AppleLanguages"];
    }
    [defaults synchronize];
}

NSString *CLLocalizedString(NSString *key) {
    return [CLLocalizationBundle() localizedStringForKey:key value:key table:nil];
}

CLAppLanguage CLGetAppLanguage(void) {
    NSInteger val = [[CLAppSettingsStore shared] integerForKey:@"AppLanguage" defaultValue:0];
    switch (val) {
        case 1: return CLAppLanguageEnglish;
        case 2: return CLAppLanguageChineseSimplified;
        default: return CLAppLanguageSystem;
    }
}

void CLApplyLanguageFromSettings(void) {
    CLAppLanguage lang = CLGetAppLanguage();
    switch (lang) {
        case CLAppLanguageEnglish:
            CLSetLocalizationBundle(@"en");
            CLSetAppleLanguages(@[@"en"]);
            break;
        case CLAppLanguageChineseSimplified:
            CLSetLocalizationBundle(@"zh-Hans");
            CLSetAppleLanguages(@[@"zh-Hans"]);
            break;
        case CLAppLanguageSystem:
        default:
            CLSetLocalizationBundle(nil);
            CLSetAppleLanguages(@[]);
            break;
    }
}

BOOL CLSetAppLanguage(CLAppLanguage language, NSError **error) {
    if (language < CLAppLanguageSystem || language > CLAppLanguageChineseSimplified) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLAppSettings"
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid language value"}];
        }
        return NO;
    }
    if (![[CLAppSettingsStore shared] setIntegerForKey:@"AppLanguage" value:(NSInteger)language error:error]) {
        return NO;
    }
    CLApplyLanguageFromSettings();
    [[NSNotificationCenter defaultCenter] postNotificationName:CLAppLanguageDidChangeNotification object:nil];
    return YES;
}