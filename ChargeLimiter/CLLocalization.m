#import "CLLocalization.h"

#import <Foundation/Foundation.h>

extern "C" NSUserDefaults* getAppUserDefaults(void);

// 共享 plist KV（utils.mm；本文件按 ObjC++ 编译，可直接链接非 extern "C" 符号，
// 也可用 _C 包装。AppLanguage 权威源 = 共享 store，不是 appdata suite。）
id getlocalKV(NSString* key);
BOOL setlocalKVChecked(NSString* key, id val);

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
    id val = getlocalKV(@"AppLanguage");
    NSInteger n = [val isKindOfClass:[NSNumber class]] ? [val integerValue] : 0;
    switch (n) {
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
    if (!setlocalKVChecked(@"AppLanguage", @((NSInteger)language))) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLAppSettings"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Shared config write failed"}];
        }
        return NO;
    }
    CLApplyLanguageFromSettings();
    [[NSNotificationCenter defaultCenter] postNotificationName:CLAppLanguageDidChangeNotification object:nil];
    return YES;
}
