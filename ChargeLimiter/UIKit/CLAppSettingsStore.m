#import "CLAppSettingsStore.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>

#ifdef __cplusplus
extern "C" NSUserDefaults* getAppUserDefaults(void);
#else
extern NSUserDefaults* getAppUserDefaults(void);
#endif

static NSString* const CLMigrationMarkerKey = @"CLAppSettingsMigrationVersion";

static NSSet<NSString*>* CLAppSettingsKnownKeys(void) {
    static dispatch_once_t once;
    static NSSet* keys;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:
                @"AppLanguage",
                @"AppAppearance",
                @"SliderHapticStyle",
                @"StopChargePresetValue",
                CLMigrationMarkerKey,
                nil];
    });
    return keys;
}

@implementation CLAppSettingsStore

+ (instancetype)shared {
    static CLAppSettingsStore* store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [CLAppSettingsStore new];
    });
    return store;
}

- (NSUserDefaults*)_suite {
    return getAppUserDefaults();
}

- (NSInteger)_normalizeValue:(NSInteger)v forKey:(NSString*)key fallback:(NSInteger)def {
    if ([key isEqualToString:@"AppLanguage"] || [key isEqualToString:@"AppAppearance"]) {
        if (v < 0 || v > 2) return def;
        return v;
    }
    if ([key isEqualToString:@"SliderHapticStyle"]) {
        if (v < 0 || v > 3) return def;
        return v;
    }
    if ([key isEqualToString:@"StopChargePresetValue"]) {
        if (v == 0) return 0;
        if (v < 15 || v > 100) return def;
        return v;
    }
    return v;
}

- (NSInteger)integerForKey:(NSString*)key defaultValue:(NSInteger)def {
    if (![CLAppSettingsKnownKeys() containsObject:key]) {
        return def;
    }
    NSUserDefaults* suite = [self _suite];
    id val = [suite objectForKey:key];
    if (![val isKindOfClass:[NSNumber class]]) {
        return def;
    }
    return [self _normalizeValue:[val integerValue] forKey:key fallback:def];
}

- (BOOL)setIntegerForKey:(NSString*)key value:(NSInteger)value error:(NSError**)error {
    if (![CLAppSettingsKnownKeys() containsObject:key]) {
        if (error) {
            *error = [NSError errorWithDomain:@"CLAppSettings"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unknown setting key"}];
        }
        return NO;
    }
    NSInteger normalized = [self _normalizeValue:value forKey:key fallback:value];
    return [self _transactionalSet:key value:normalized error:error];
}

- (BOOL)_transactionalSet:(NSString*)key value:(NSInteger)value error:(NSError**)error {
    NSUserDefaults* suite = [self _suite];
    id previous = [suite objectForKey:key];
    [suite setInteger:value forKey:key];
    if (![suite synchronize]) {
        [self _restoreObject:previous forKey:key inSuite:suite];
        if (error) {
            *error = [NSError errorWithDomain:@"CLAppSettings"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Synchronize failed"}];
        }
        return NO;
    }
    id readback = [suite objectForKey:key];
    if (![readback isKindOfClass:[NSNumber class]] || [readback integerValue] != value) {
        [self _restoreObject:previous forKey:key inSuite:suite];
        if (error) {
            *error = [NSError errorWithDomain:@"CLAppSettings"
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Readback mismatch"}];
        }
        return NO;
    }
    return YES;
}

- (void)_restoreObject:(id)obj forKey:(NSString*)key inSuite:(NSUserDefaults*)suite {
    if (obj) {
        [suite setObject:obj forKey:key];
    } else {
        [suite removeObjectForKey:key];
    }
    [suite synchronize];
}

- (BOOL)migrateIfNeeded:(NSError**)error {
    NSUserDefaults* suite = [self _suite];

    // Skip if already migrated this launch
    if ([suite boolForKey:CLMigrationMarkerKey]) {
        return YES;
    }

    NSArray<NSString*>* keys = @[
        @"AppLanguage",
        @"AppAppearance",
        @"SliderHapticStyle",
        @"StopChargePresetValue"
    ];

    NSDictionary* sharedPlist = nil;
    {
        NSString* confPath = nil;
        if (const char* (*jbptr)(const char*) = (const char* (*)(const char*))dlsym(RTLD_DEFAULT, "jbroot")) {
            const char* rooted = jbptr("/var/mobile/ChargeLimiter");
            if (rooted) {
                confPath = [NSString stringWithFormat:@"%s/com.chargelimiter.mod.plist", rooted];
            }
        }
        // Rootless fallback path; shared read uses known preference path
        NSArray* readPaths = nil;
        {
            id (*getReadPaths)(void) = (id (*)(void))dlsym(RTLD_DEFAULT, "getConfigReadPathsWithLibroot");
            if (getReadPaths) {
                readPaths = getReadPaths();
            }
        }
        if (!readPaths && confPath) {
            readPaths = @[confPath];
        }
        for (NSString* p in readPaths) {
            NSDictionary* d = [NSDictionary dictionaryWithContentsOfFile:p];
            if (d && [d isKindOfClass:[NSDictionary class]] && d.count > 0) {
                sharedPlist = d;
                break;
            }
        }
    }

    NSUserDefaults* stdDefaults = nil;
    {
        stdDefaults = [NSUserDefaults standardUserDefaults];
    }

    BOOL anySuccess = NO;
    for (NSString* key in keys) {
        // Skip if appdata suite already has a valid value here
        NSNumber* existing = [suite objectForKey:key];
        if ([existing isKindOfClass:[NSNumber class]]) {
            anySuccess = YES;
            continue;
        }

        NSInteger val = 0;
        BOOL found = NO;

        // Priority 1: shared plist
        id shared = sharedPlist[key];
        if ([shared isKindOfClass:[NSNumber class]]) {
            val = [shared integerValue];
            found = YES;
        }

        // Priority 2: standardUserDefaults
        if (!found) {
            id std = [stdDefaults objectForKey:key];
            if ([std isKindOfClass:[NSNumber class]]) {
                val = [std integerValue];
                found = YES;
            }
        }

        // Priority 3: default (0) — always valid for these keys
        if (!found) {
            val = 0;
        }

        // Normalize and store
        val = [self _normalizeValue:val forKey:key fallback:0];

        [suite setInteger:val forKey:key];
        if ([suite synchronize]) {
            id readback = [suite objectForKey:key];
            if ([readback isKindOfClass:[NSNumber class]] && [readback integerValue] == val) {
                anySuccess = YES;
            }
        }
    }

    // Set migration marker if at least one key succeeded
    if (anySuccess) {
        [suite setBool:YES forKey:CLMigrationMarkerKey];
        [suite synchronize];
    }

    return anySuccess;
}

@end