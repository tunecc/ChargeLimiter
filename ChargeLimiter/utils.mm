#include "utils.h"
#import "CLLocalization.h"
#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <stdlib.h>
#include <sys/utsname.h>
#include <sys/sysctl.h>
#include <notify.h>
#import <objc/message.h>

// REFACTOR: 使用标准 libroot API 而不是手动实现
#if !TARGET_OS_SIMULATOR
#import <libroot/libroot.h>
#endif

static NSString* g_appDocumentsPath = nil;
static NSString* g_logPath = nil;
static NSString* g_confPath = nil;
static NSString* g_dbPath = nil;
static NSString* g_appDocumentsPathOverride = nil;
static NSString* g_runtimeDataRootPath = nil;
static NSString* const kLegacyContainerCacheFileName = @"com.chargelimiter.mod.containerpath";
static NSString* const kRoothideDataRoot = @"/var/mobile/ChargeLimiter";
static NSString* const kRoothideLegacySharedDataRoot = @"/var/mobile/Library/Application Support/ChargeLimiter";
typedef const char* (*jbroot_fn_t)(const char* path);
@class CLSettingsStore;
static NSString* resolveAppBundleIdentifier(void);
static NSString* resolveExistingDataContainerRoot(NSString* bid);
static NSString* resolveJbRootFromSelfExe(void);
static NSString* resolveRoothidePathByAPI(NSString* logicalPath);
static NSString* resolveRoothidePreferencesDirByAPI(void);
static NSString* resolveRoothideDataRootByAPI(void);
static NSString* ensureValidDocumentsPath(NSString* docsPath);
static BOOL removeLegacyFilePreferRoot(NSString* path);
static BOOL isRoothidePreferencesConfigPath(NSString* path);
static NSArray<NSString*>* currentConfigCleanupPathCandidates(void);
static NSArray<NSString*>* roothideHistoricalPreferencesDirs(void);
static NSArray<NSString*>* roothideLegacySharedDataDirs(void);
static NSDate* fileModifyDate(NSString* path);

// REFACTOR: 新函数前向声明
static NSDictionary* readConfigFromDiskWithLibroot(NSString** loadedPathOut);
static BOOL writeConfigDataToDiskWithLibroot(NSData* plistData, NSString** pathOut, NSError** errorOut);
static BOOL writeMergedConfigDictionaryToDisk(NSDictionary* fallbackPreferences,
                                              NSDictionary* pendingChanges,
                                              NSSet<NSString*>* removedKeys,
                                              NSString** pathOut,
                                              NSError** errorOut,
                                              NSMutableDictionary** mergedPreferencesOut);
static void repairSharedConfigFileOwnership(NSString* confPath);
static BOOL ensureStoreConfigFileExists(CLSettingsStore* store, NSString** pathOut, NSError** errorOut);

static NSString* normalizedAbsolutePath(NSString* path) {
    if (path.length == 0) {
        return nil;
    }
    NSString* fixed = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (fixed.length == 0 || ![fixed hasPrefix:@"/"]) {
        return nil;
    }
    fixed = [fixed stringByStandardizingPath];
    while (fixed.length > 1 && [fixed hasSuffix:@"/"]) {
        fixed = [fixed substringToIndex:fixed.length - 1];
    }
    return fixed;
}

static NSArray<NSString*>* roothideAliasPathsForPath(NSString* path) {
    NSString* normalized = normalizedAbsolutePath(path);
    if (normalized.length == 0) {
        return @[];
    }

    NSRange marker = [normalized rangeOfString:@"/.jbroot-"];
    if (marker.location == NSNotFound) {
        return @[];
    }

    NSMutableArray<NSString*>* aliases = [NSMutableArray new];
    NSUInteger searchStart = marker.location + 1;
    NSArray<NSString*>* suffixes = @[
        @"/var/mobile/",
        @"/private/var/mobile/"
    ];
    for (NSString* suffix in suffixes) {
        NSRange suffixRange = [normalized rangeOfString:suffix
                                                options:0
                                                  range:NSMakeRange(searchStart, normalized.length - searchStart)];
        if (suffixRange.location == NSNotFound) {
            continue;
        }

        NSString* tail = [normalized substringFromIndex:suffixRange.location];
        [aliases addObject:tail];
        [aliases addObject:[@"/var/jb" stringByAppendingString:tail]];
        if ([tail hasPrefix:@"/private/"]) {
            [aliases addObject:[@"/var/jb" stringByAppendingString:[tail substringFromIndex:@"/private".length]]];
        }
    }
    return aliases;
}

static void appendComparisonPathVariants(NSMutableArray<NSString*>* variants, NSString* path) {
    NSString* normalized = normalizedAbsolutePath(path);
    if (normalized.length == 0) {
        return;
    }

    NSMutableSet<NSString*>* seen = [NSMutableSet setWithArray:variants];
    NSMutableArray<NSString*>* queue = [NSMutableArray arrayWithObject:normalized];
    while (queue.count > 0) {
        NSString* current = normalizedAbsolutePath(queue.firstObject);
        [queue removeObjectAtIndex:0];
        if (current.length == 0 || [seen containsObject:current]) {
            continue;
        }

        [seen addObject:current];
        [variants addObject:current];

        NSString* resolved = normalizedAbsolutePath([current stringByResolvingSymlinksInPath]);
        if (resolved.length > 0 && ![seen containsObject:resolved]) {
            [queue addObject:resolved];
        }

        if ([current hasPrefix:@"/private/"]) {
            NSString* stripped = normalizedAbsolutePath([current substringFromIndex:@"/private".length]);
            if (stripped.length > 0 && ![seen containsObject:stripped]) {
                [queue addObject:stripped];
            }
        } else if ([current hasPrefix:@"/"]) {
            NSString* prefixed = normalizedAbsolutePath([@"/private" stringByAppendingString:current]);
            if (prefixed.length > 0 && ![seen containsObject:prefixed]) {
                [queue addObject:prefixed];
            }
        }

        for (NSString* alias in roothideAliasPathsForPath(current)) {
            NSString* normalizedAlias = normalizedAbsolutePath(alias);
            if (normalizedAlias.length > 0 && ![seen containsObject:normalizedAlias]) {
                [queue addObject:normalizedAlias];
            }
        }
    }
}

static NSArray<NSString*>* comparisonPathVariantsForPath(NSString* path) {
    NSMutableArray<NSString*>* variants = [NSMutableArray new];
    appendComparisonPathVariants(variants, path);
    return variants;
}

static BOOL pathsAreEquivalentForLegacyDetection(NSString* lhs, NSString* rhs) {
    NSString* left = normalizedAbsolutePath(lhs);
    NSString* right = normalizedAbsolutePath(rhs);
    if (left.length == 0 || right.length == 0) {
        return NO;
    }

    NSArray<NSString*>* leftVariants = comparisonPathVariantsForPath(left);
    NSArray<NSString*>* rightVariants = comparisonPathVariantsForPath(right);
    for (NSString* leftVariant in leftVariants) {
        for (NSString* rightVariant in rightVariants) {
            if ([leftVariant isEqualToString:rightVariant]) {
                return YES;
            }
        }
    }
    return NO;
}

static void appendStablePathVariants(NSMutableArray<NSString*>* variants, NSString* path) {
    NSString* normalized = normalizedAbsolutePath(path);
    if (normalized.length == 0) {
        return;
    }

    NSMutableSet<NSString*>* seen = [NSMutableSet setWithArray:variants];
    NSMutableArray<NSString*>* queue = [NSMutableArray arrayWithObject:normalized];
    while (queue.count > 0) {
        NSString* current = normalizedAbsolutePath(queue.firstObject);
        [queue removeObjectAtIndex:0];
        if (current.length == 0 || [seen containsObject:current]) {
            continue;
        }

        [seen addObject:current];
        [variants addObject:current];

        // 1. 符号链接解析
        NSString* resolved = normalizedAbsolutePath([current stringByResolvingSymlinksInPath]);
        if (resolved.length > 0 && ![seen containsObject:resolved]) {
            [queue addObject:resolved];
        }

        // 2. /private/ 前缀变体
        if ([current hasPrefix:@"/private/"]) {
            NSString* stripped = normalizedAbsolutePath([current substringFromIndex:@"/private".length]);
            if (stripped.length > 0 && ![seen containsObject:stripped]) {
                [queue addObject:stripped];
            }
        } else if ([current hasPrefix:@"/"]) {
            NSString* prefixed = normalizedAbsolutePath([@"/private" stringByAppendingString:current]);
            if (prefixed.length > 0 && ![seen containsObject:prefixed]) {
                [queue addObject:prefixed];
            }
        }

        // 3. roothide 别名路径变体
        for (NSString* alias in roothideAliasPathsForPath(current)) {
            NSString* normalizedAlias = normalizedAbsolutePath(alias);
            if (normalizedAlias.length > 0 && ![seen containsObject:normalizedAlias]) {
                [queue addObject:normalizedAlias];
            }
        }
    }
}

static BOOL pathMatchesAnyStableCurrentPath(NSString* path, NSArray<NSString*>* candidates) {
    if (path.length == 0 || candidates.count == 0) {
        return NO;
    }

    NSMutableArray<NSString*>* pathVariants = [NSMutableArray new];
    appendStablePathVariants(pathVariants, path);
    NSMutableArray<NSString*>* candidateVariants = [NSMutableArray new];
    for (NSString* candidate in candidates) {
        appendStablePathVariants(candidateVariants, candidate);
    }

    for (NSString* pathVariant in pathVariants) {
        if ([candidateVariants containsObject:pathVariant]) {
            return YES;
        }
    }
    return NO;
}

static NSString* deriveJbRootFromPreferencesDir(NSString* prefsDir) {
    NSString* normalized = normalizedAbsolutePath(prefsDir);
    if (normalized.length == 0) {
        return nil;
    }

    NSArray<NSString*>* suffixes = @[
        @"/var/mobile/Library/Preferences",
        @"/private/var/mobile/Library/Preferences"
    ];
    NSString* lower = normalized.lowercaseString;
    for (NSString* suffix in suffixes) {
        NSString* lowerSuffix = suffix.lowercaseString;
        if (![lower hasSuffix:lowerSuffix]) {
            continue;
        }
        NSUInteger rootLength = normalized.length - suffix.length;
        if (rootLength == 0) {
            return @"/";
        }
        return [normalized substringToIndex:rootLength];
    }
    return nil;
}

static BOOL isRoothidePreferencesConfigPath(NSString* path) {
    NSString* normalized = normalizedAbsolutePath(path);
    if (normalized.length == 0 ||
        ![normalized.lastPathComponent isEqualToString:@CONFIG_PLIST_FILENAME] ||
        [normalized rangeOfString:@"/.jbroot-"].location == NSNotFound) {
        return NO;
    }

    NSString* lower = normalized.lowercaseString;
    NSArray<NSString*>* suffixes = @[
        @"/var/mobile/library/preferences/" @CONFIG_PLIST_FILENAME,
        @"/private/var/mobile/library/preferences/" @CONFIG_PLIST_FILENAME
    ];
    for (NSString* suffix in suffixes) {
        if ([lower hasSuffix:suffix]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString*>* appContainerBaseDirectories(void) {
    NSMutableArray<NSString*>* rawBases = [NSMutableArray arrayWithArray:@[
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/containers/data/application",
        @"/var/jb/var/mobile/Containers/Data/Application",
        @"/var/jb/var/mobile/containers/data/application",
        @"/var/jb/private/var/mobile/Containers/Data/Application",
        @"/var/jb/private/var/mobile/containers/data/application"
    ]];

    NSMutableArray<NSString*>* dynamicRoots = [NSMutableArray new];
    NSString* roothideRoot = deriveJbRootFromPreferencesDir(resolveRoothidePreferencesDirByAPI());
    if (roothideRoot.length > 0) {
        [dynamicRoots addObject:roothideRoot];
    }
    NSString* inferredJbRoot = normalizedAbsolutePath(resolveJbRootFromSelfExe());
    if (inferredJbRoot.length > 0) {
        [dynamicRoots addObject:inferredJbRoot];
    }

    for (NSString* root in dynamicRoots) {
        [rawBases addObject:[root stringByAppendingPathComponent:@"var/mobile/Containers/Data/Application"]];
        [rawBases addObject:[root stringByAppendingPathComponent:@"var/mobile/containers/data/application"]];
        [rawBases addObject:[root stringByAppendingPathComponent:@"private/var/mobile/Containers/Data/Application"]];
        [rawBases addObject:[root stringByAppendingPathComponent:@"private/var/mobile/containers/data/application"]];
    }

    NSMutableArray<NSString*>* bases = [NSMutableArray new];
    for (NSString* rawBase in rawBases) {
        appendComparisonPathVariants(bases, rawBase);
    }
    return bases;
}

// ============================================================================
// REFACTOR: 新的简化路径解析（使用 libroot API - 运行时动态加载）
// ============================================================================

/**
 * libroot API 函数指针类型
 */
typedef char* (*libroot_jbrootpath_fn_t)(const char* path, char* resolvedPath);

/**
 * 获取 libroot API 函数指针（运行时动态加载）
 */
static libroot_jbrootpath_fn_t getLibrootJbrootpathFunction(void) {
    static libroot_jbrootpath_fn_t func = NULL;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
#if !TARGET_OS_SIMULATOR
        func = libroot_dyn_jbrootpath;
        if (func) {
            NSLog2(@"[CL] libroot_dyn_jbrootpath linked from libroot");
            return;
        }
#endif

        func = (libroot_jbrootpath_fn_t)dlsym(RTLD_DEFAULT, "libroot_dyn_jbrootpath");
        if (func) {
            NSLog2(@"[CL] libroot_dyn_jbrootpath found in RTLD_DEFAULT");
            return;
        }

        NSArray<NSString*>* candidates = @[
            @"/usr/lib/libroot.dylib",
            @"/var/jb/usr/lib/libroot.dylib",
            @"/private/var/jb/usr/lib/libroot.dylib",
        ];
        for (NSString* candidate in candidates) {
            void* handle = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            func = (libroot_jbrootpath_fn_t)dlsym(handle, "libroot_dyn_jbrootpath");
            if (func) {
                NSLog2(@"[CL] libroot_dyn_jbrootpath loaded from %@", candidate);
                return;
            }
        }

        NSLog2(@"[CL] INFO: libroot_dyn_jbrootpath not available");
    });

    return func;
}

/**
 * 使用标准 libroot API 解析越狱路径（运行时动态加载版本）
 *
 * 这个函数替代了之前 500+ 行的手动实现。
 * 在 roothide 环境下使用 libroot API，其他环境使用原始路径。
 *
 * @param logicalPath 逻辑路径，如 "/var/mobile/Library/Preferences/config.plist"
 * @return 解析后的实际路径，在 roothide 下会是 "/.jbroot-XXX/..." 格式
 */
static NSString* resolveJailbreakPathWithLibroot(NSString* logicalPath) {
    if (!logicalPath || logicalPath.length == 0) {
        return nil;
    }

    // TrollStore 特殊处理：使用应用沙盒
    if (getJBType() == JBTYPE_TROLLSTORE) {
        // 将 /var/mobile/Library 映射到 Documents
        if ([logicalPath hasPrefix:@"/var/mobile/Library"]) {
            NSString* relativePath = [logicalPath substringFromIndex:[@"/var/mobile/Library" length]];
            NSString* docsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            return [docsPath stringByAppendingPathComponent:relativePath];
        }
        // 其他路径也映射到 Documents
        return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                stringByAppendingPathComponent:[logicalPath lastPathComponent]];
    }

    // 模拟器：返回原始路径
    #if TARGET_OS_SIMULATOR
        return logicalPath;
    #endif

    // 真机：尝试使用 libroot API
    libroot_jbrootpath_fn_t jbrootpathFunc = getLibrootJbrootpathFunction();

    if (jbrootpathFunc) {
        // 使用 libroot API 解析路径
        char buffer[PATH_MAX];
        const char* resolved = jbrootpathFunc(logicalPath.fileSystemRepresentation, buffer);

        if (resolved && resolved[0] != '\0') {
            NSString* resolvedPath = @(resolved);
            // 只在首次解析时打印日志，避免日志过多
            static dispatch_once_t logOnce;
            dispatch_once(&logOnce, ^{
                NSLog2(@"[CL] Using libroot API for path resolution");
            });
            return resolvedPath;
        }
    }

    if (getJBType() == JBTYPE_ROOTHIDE) {
        NSString* roothidePath = resolveRoothidePathByAPI(logicalPath);
        if (roothidePath.length > 0) {
            NSLog2(@"[CL] Using libroothide jbroot API for path resolution");
            return roothidePath;
        }

        NSLog2(@"[CL] CRITICAL: roothide path resolution failed for %@. Refusing bare rootfs fallback.",
               logicalPath);
        return nil;
    }

    // libroot 不可用（rootful/rootless 环境）或解析失败，使用原始路径
    // 这在 rootful 越狱中是正确的行为
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        NSLog2(@"[CL] libroot unavailable, using direct paths (normal for rootful/rootless)");
    });
    return logicalPath;
}

// ============================================================================
// REFACTOR: 新的简化配置路径函数（使用 libroot）
// ============================================================================

// Forward declaration
static NSString* getSharedDataRootPathWithLibroot(void);

/**
 * 获取配置文件的根目录。
 *
 * 设计原则：
 * - 越狱环境：配置/数据库/日志统一放在共享数据根目录（jbroot 或系统路径），
 *   因为 daemon 需要访问配置文件，而 daemon 无法访问 app 数据容器。
 * - TrollStore：使用 app 数据容器（没有 daemon，只有 app 访问）。
 */
static NSString* getConfigRootPathWithLibroot(void) {
    // TrollStore：使用 app 数据容器
    if (getJBType() == JBTYPE_TROLLSTORE) {
        NSString* bid = resolveAppBundleIdentifier();
        NSString* containerRoot = resolveExistingDataContainerRoot(bid);
        if (containerRoot.length == 0) {
            containerRoot = NSHomeDirectory();
        }
        if (containerRoot.length == 0) {
            return nil;
        }
        return [containerRoot stringByAppendingPathComponent:@"ChargeLimiter"];
    }

    // 越狱环境：配置文件与数据库/日志统一到共享数据根目录
    // daemon 需要访问配置，必须放在 daemon 可访问的位置（jbroot 或系统共享路径）
    return getSharedDataRootPathWithLibroot();
}

/**
 * 获取共享数据的根目录。
 * roothide 仅将日志/数据库等共享运行数据放在 jbroot:/var/mobile/ChargeLimiter。
 */
static NSString* getSharedDataRootPathWithLibroot(void) {
    if (getJBType() == JBTYPE_ROOTHIDE) {
        return resolveRoothideDataRootByAPI();
    }
    return resolveJailbreakPathWithLibroot(@"/var/mobile/ChargeLimiter");
}

/**
 * 获取配置文件的完整路径（新实现）
 */
static NSString* appContainerRootForPathVariant(NSString* pathVariant, NSString* basePath, BOOL requireContainerRootOnly) {
    NSString* candidate = normalizedAbsolutePath(pathVariant);
    NSString* base = normalizedAbsolutePath(basePath);
    if (candidate.length == 0 || base.length == 0) {
        return nil;
    }

    NSString* lowerCandidate = candidate.lowercaseString;
    NSString* lowerBase = base.lowercaseString;
    if (![lowerCandidate hasPrefix:lowerBase]) {
        return nil;
    }

    if (candidate.length <= base.length || [lowerCandidate characterAtIndex:base.length] != '/') {
        return nil;
    }

    NSString* remainder = [candidate substringFromIndex:base.length + 1];
    NSArray<NSString*>* components = [remainder pathComponents];
    NSString* containerName = components.firstObject;
    if (containerName.length == 0 || [containerName isEqualToString:@"."] || [containerName isEqualToString:@".."]) {
        return nil;
    }
    if (requireContainerRootOnly && components.count != 1) {
        return nil;
    }

    return [base stringByAppendingPathComponent:containerName];
}

static NSString* validateAppContainerPath(NSString* path, BOOL requireContainerRootOnly, NSString** reasonOut) {
    NSString* normalized = normalizedAbsolutePath(path);
    if (normalized.length == 0) {
        if (reasonOut) {
            *reasonOut = @"path is empty or not absolute";
        }
        return nil;
    }

    NSArray<NSString*>* bases = appContainerBaseDirectories();
    if (bases.count == 0) {
        if (reasonOut) {
            *reasonOut = @"no app data container bases available";
        }
        return nil;
    }

    for (NSString* variant in comparisonPathVariantsForPath(normalized)) {
        for (NSString* base in bases) {
            if (appContainerRootForPathVariant(variant, base, requireContainerRootOnly).length > 0) {
                return normalized;
            }
        }
    }

    if (reasonOut) {
        *reasonOut = [NSString stringWithFormat:@"unsupported app data container path: %@", normalized];
    }
    return nil;
}

static NSString* validatedDocumentsPath(NSString* path, NSString** reasonOut) {
    return validateAppContainerPath(path, NO, reasonOut);
}

static NSString* validatedContainerRoot(NSString* path, NSString** reasonOut) {
    return validateAppContainerPath(path, YES, reasonOut);
}

static NSURL* getContainerURLFromMCM(id container) {
    if (!container) {
        return nil;
    }
    if ([container respondsToSelector:@selector(url)]) {
        return ((NSURL*(*)(id, SEL))objc_msgSend)(container, @selector(url));
    }
    if ([container respondsToSelector:@selector(containerURL)]) {
        return ((NSURL*(*)(id, SEL))objc_msgSend)(container, @selector(containerURL));
    }
    return nil;
}

static NSURL* resolveMCMContainerURL(NSString* bid, BOOL allowCreate) {
    if (bid.length == 0) {
        return nil;
    }
    Class dataCls = objc_getClass("MCMAppDataContainer");
    if (!dataCls) {
        return nil;
    }

    SEL selGet = @selector(containerWithIdentifier:error:);
    if ([dataCls respondsToSelector:selGet]) {
        NSError* err = nil;
        id container = ((id(*)(id, SEL, NSString*, NSError**))objc_msgSend)(dataCls, selGet, bid, &err);
        NSURL* url = getContainerURLFromMCM(container);
        if (url.path.length > 0) {
            return url;
        }
    }

    if (allowCreate) {
        SEL selCreate = @selector(containerWithIdentifier:createIfNecessary:error:);
        if ([dataCls respondsToSelector:selCreate]) {
            NSError* err = nil;
            id container = ((id(*)(id, SEL, NSString*, BOOL, NSError**))objc_msgSend)(dataCls, selCreate, bid, YES, &err);
            NSURL* url = getContainerURLFromMCM(container);
            if (url.path.length > 0) {
                return url;
            }
        }
    }
    return nil;
}

static NSString* resolveContainerRootByScanning(NSString* bid) {
    if (bid.length == 0) {
        return nil;
    }
    NSArray<NSString*>* bases = appContainerBaseDirectories();
    for (NSString* base in bases) {
        NSError* error = nil;
        NSArray* containers = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:&error];
        if (!containers) {
            continue;
        }
        for (NSString* container in containers) {
            NSString* containerPath = [base stringByAppendingPathComponent:container];
            NSString* metaPath = [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary* meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
            if (![meta isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString* idA = meta[@"MCMMetadataIdentifier"];
            NSString* idB = meta[@"MCMMetadataBundleIdentifier"];
            NSString* idC = meta[@"MCMMetadataBundleID"];
            if ([idA isEqualToString:bid] || [idB isEqualToString:bid] || [idC isEqualToString:bid]) {
                return containerPath;
            }
        }
    }
    return nil;
}

static NSString* resolveAppBundleIdentifier() {
    NSString* bid = NSBundle.mainBundle.bundleIdentifier;
    if (bid.length == 0) {
        return @"com.chargelimiter.mod";
    }
    if ([bid containsString:@"ChargeLimiterDaemon"]) {
        NSString* fixed = [bid stringByReplacingOccurrencesOfString:@"ChargeLimiterDaemon" withString:@"ChargeLimiter"];
        if (fixed.length > 0) {
            return fixed;
        }
    }
    return bid;
}

static NSString* ensureValidDocumentsPath(NSString* docsPath) {
    NSString* fixed = validatedDocumentsPath(docsPath, nil);
    if (fixed.length == 0) {
        return nil;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:fixed withIntermediateDirectories:YES attributes:nil error:nil];
    return fixed;
}

static NSString* resolveExistingDataContainerRoot(NSString* bid) {
    if (bid.length == 0) {
        return nil;
    }

    Class proxyCls = objc_getClass("LSApplicationProxy");
    if (proxyCls && [proxyCls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id proxy = [proxyCls performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
#pragma clang diagnostic pop
        if (proxy && [proxy respondsToSelector:@selector(dataContainerURL)]) {
            NSURL* url = ((LSApplicationProxy*)proxy).dataContainerURL;
            NSString* reason = nil;
            NSString* root = validatedContainerRoot(url.path, &reason);
            if (root.length > 0) {
                NSLog2(@"[CL] resolveExistingDataContainerRoot source=ls path=%@", root);
                return root;
            }
            if (url.path.length > 0) {
                NSLog2(@"[CL] resolveExistingDataContainerRoot rejected source=ls path=%@ reason=%@", url.path, reason ?: @"invalid");
            }
        }
    }

    NSURL* mcmURL = resolveMCMContainerURL(bid, NO);
    NSString* reason = nil;
    NSString* root = validatedContainerRoot(mcmURL.path, &reason);
    if (root.length > 0) {
        NSLog2(@"[CL] resolveExistingDataContainerRoot source=mcm path=%@", root);
        return root;
    }
    if (mcmURL.path.length > 0) {
        NSLog2(@"[CL] resolveExistingDataContainerRoot rejected source=mcm path=%@ reason=%@", mcmURL.path, reason ?: @"invalid");
    }

    NSString* scannedRoot = resolveContainerRootByScanning(bid);
    root = validatedContainerRoot(scannedRoot, &reason);
    if (root.length > 0) {
        NSLog2(@"[CL] resolveExistingDataContainerRoot source=scan path=%@", root);
        return root;
    }
    if (scannedRoot.length > 0) {
        NSLog2(@"[CL] resolveExistingDataContainerRoot rejected source=scan path=%@ reason=%@", scannedRoot, reason ?: @"invalid");
    }
    return nil;
}

static NSString* resolveAppDocumentsPath() {
    if (getJBType() != JBTYPE_TROLLSTORE) {
        NSString* sharedRoot = getSharedDataRootPathWithLibroot();
        if (sharedRoot.length > 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:sharedRoot withIntermediateDirectories:YES attributes:nil error:nil];
            NSLog2(@"[CL] resolveAppDocumentsPath source=jailbreak-shared path=%@", sharedRoot);
            return sharedRoot;
        }
        if (getJBType() == JBTYPE_ROOTHIDE) {
            NSLog2(@"[CL] resolveAppDocumentsPath failed in roothide: shared data root unavailable");
            return nil;
        }
    }

    NSString* docPath = nil;
    NSString* reason = nil;

    if (g_appDocumentsPathOverride.length > 0) {
        docPath = validatedDocumentsPath(g_appDocumentsPathOverride, &reason);
        if (docPath.length > 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:docPath withIntermediateDirectories:YES attributes:nil error:nil];
            NSLog2(@"[CL] resolveAppDocumentsPath source=override path=%@", docPath);
            return docPath;
        }
        NSLog2(@"[CL] resolveAppDocumentsPath rejected source=override path=%@ reason=%@", g_appDocumentsPathOverride, reason ?: @"invalid");
    }

    NSString* homeDocs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    docPath = validatedDocumentsPath(homeDocs, &reason);
    if (docPath.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:docPath withIntermediateDirectories:YES attributes:nil error:nil];
        NSLog2(@"[CL] resolveAppDocumentsPath source=home path=%@", docPath);
        return docPath;
    }
    if (homeDocs.length > 0) {
        NSLog2(@"[CL] resolveAppDocumentsPath rejected source=home path=%@ reason=%@", homeDocs, reason ?: @"invalid");
    }

    NSString* bid = resolveAppBundleIdentifier();
    NSString* containerRoot = resolveExistingDataContainerRoot(bid);
    if (containerRoot.length > 0) {
        NSString* containerDocs = [containerRoot stringByAppendingPathComponent:@"Documents"];
        docPath = validatedDocumentsPath(containerDocs, &reason);
        if (docPath.length > 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:docPath withIntermediateDirectories:YES attributes:nil error:nil];
            NSLog2(@"[CL] resolveAppDocumentsPath source=existing-container path=%@", docPath);
            return docPath;
        }
        NSLog2(@"[CL] resolveAppDocumentsPath rejected source=existing-container path=%@ reason=%@", containerDocs, reason ?: @"invalid");
    }

    NSURL* mcmURL = resolveMCMContainerURL(bid, YES);
    if (mcmURL.path.length > 0) {
        NSString* createdDocs = [mcmURL.path stringByAppendingPathComponent:@"Documents"];
        docPath = validatedDocumentsPath(createdDocs, &reason);
        if (docPath.length > 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:docPath withIntermediateDirectories:YES attributes:nil error:nil];
            NSLog2(@"[CL] resolveAppDocumentsPath source=mcm-create path=%@", docPath);
            return docPath;
        }
        NSLog2(@"[CL] resolveAppDocumentsPath rejected source=mcm-create path=%@ reason=%@", createdDocs, reason ?: @"invalid");
    }

    NSString* fallbackCandidate = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString* fallback = validatedDocumentsPath(fallbackCandidate, &reason);
    if (fallback.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil];
        NSLog2(@"[CL] resolveAppDocumentsPath source=search path=%@", fallback);
        return fallback;
    }
    if (fallbackCandidate.length > 0) {
        NSLog2(@"[CL] resolveAppDocumentsPath rejected source=search path=%@ reason=%@", fallbackCandidate, reason ?: @"invalid");
    }
    NSLog2(@"[CL] resolveAppDocumentsPath failed. bid=%@ home=%@ bases=%@", bid, NSHomeDirectory(), appContainerBaseDirectories());
    return nil;
}

void setAppDocumentsPathOverride(NSString* docsPath) {
    if (docsPath.length == 0) {
        return;
    }
    NSString* reason = nil;
    NSString* fixed = ensureValidDocumentsPath(docsPath);
    if (fixed.length == 0) {
        validatedDocumentsPath(docsPath, &reason);
        NSLog2(@"[CL] setAppDocumentsPathOverride rejected invalid path: %@ reason=%@", docsPath, reason ?: @"invalid");
        return;
    }
    @synchronized(NSFileManager.defaultManager) {
        g_appDocumentsPathOverride = fixed;
        g_appDocumentsPath = nil;
        g_logPath = nil;
        g_confPath = nil;
        g_dbPath = nil;
    }
    NSLog2(@"[CL] app documents override set: %@", fixed);
}

static NSString* resolveJbRootFromSelfExe() {
    NSString* exe = getSelfExePath();
    if (exe.length == 0) {
        return nil;
    }
    NSRange marker = [exe rangeOfString:@"/.jbroot-"];
    if (marker.location == NSNotFound) {
        return nil;
    }
    NSUInteger start = marker.location + 1;
    NSRange tail = [exe rangeOfString:@"/" options:0 range:NSMakeRange(start, exe.length - start)];
    if (tail.location == NSNotFound) {
        return nil;
    }
    return [exe substringToIndex:tail.location];
}

static NSString* resolveRoothidePathByAPI(NSString* logicalPath) {
    NSString* normalized = normalizedAbsolutePath(logicalPath);
    if (normalized.length == 0) {
        return nil;
    }

    static jbroot_fn_t jbrootPtr = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        jbrootPtr = (jbroot_fn_t)dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootPtr) {
            NSLog2(@"[CL] jbroot API resolved from RTLD_DEFAULT");
            return;
        }

        NSMutableArray<NSString*>* candidates = [NSMutableArray new];
        NSMutableSet<NSString*>* seen = [NSMutableSet new];
        void (^appendCandidate)(NSString*) = ^(NSString* candidate) {
            NSString* fixed = normalizedAbsolutePath(candidate);
            if (fixed.length == 0 || [seen containsObject:fixed]) {
                return;
            }
            [seen addObject:fixed];
            [candidates addObject:fixed];
        };

        NSString* exeDir = [getSelfExePath() stringByDeletingLastPathComponent];
        if (exeDir.length > 0) {
            appendCandidate([exeDir stringByAppendingPathComponent:@".jbroot/usr/lib/libroothide.dylib"]);
        }

        char resolvedJb[PATH_MAX] = {0};
        if (realpath("/var/jb", resolvedJb) != NULL) {
            appendCandidate([@(resolvedJb) stringByAppendingPathComponent:@"usr/lib/libroothide.dylib"]);
        }

        appendCandidate(@"/usr/lib/libroothide.dylib");
        appendCandidate(@"/var/jb/usr/lib/libroothide.dylib");
        appendCandidate(@"/private/var/jb/usr/lib/libroothide.dylib");

        for (NSString* candidate in candidates) {
            void* h = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY);
            if (!h) {
                continue;
            }
            jbrootPtr = (jbroot_fn_t)dlsym(h, "jbroot");
            if (jbrootPtr) {
                NSLog2(@"[CL] jbroot API loaded from %@", candidate);
                break;
            }
        }
    });

    // 如果初始化失败，尝试轻量级重试
    if (!jbrootPtr) {
        jbrootPtr = (jbroot_fn_t)dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootPtr) {
            NSLog2(@"[CL] jbroot API resolved on retry");
        }
    }

    if (!jbrootPtr) {
        return nil;
    }

    const char* rooted = jbrootPtr(normalized.fileSystemRepresentation);
    if (!rooted || rooted[0] != '/' || strlen(rooted) == 0) {
        NSLog2(@"[CL] jbroot API returned invalid path for %@: %s", normalized, rooted ?: "(null)");
        return nil;
    }

    NSString* rootedStr = normalizedAbsolutePath(@(rooted));
    if (rootedStr.length == 0 || [rootedStr rangeOfString:@"/.jbroot-"].location == NSNotFound) {
        NSLog2(@"[CL] jbroot API returned non-roothide path for %@: %@", normalized, rootedStr ?: @"(null)");
        return nil;
    }

    return rootedStr;
}

static NSString* resolveRoothidePreferencesDirByAPI() {
    NSString* rooted = resolveRoothidePathByAPI(@"/var/mobile/Library/Preferences");
    if (rooted.length == 0 || [rooted rangeOfString:@"/.jbroot-"].location == NSNotFound) {
        return nil;
    }
    return rooted;
}

static NSString* resolveRoothideDataRootByAPI() {
    NSString* rooted = resolveRoothidePathByAPI(kRoothideDataRoot);
    if (rooted.length == 0 || [rooted rangeOfString:@"/.jbroot-"].location == NSNotFound) {
        return nil;
    }
    return rooted;
}

static NSArray<NSString*>* legacyContainerCachePaths() {
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithObjects:
                                        [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:kLegacyContainerCacheFileName],
                                        [@"/private/var/mobile/Library/Preferences" stringByAppendingPathComponent:kLegacyContainerCacheFileName],
                                        [@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:kLegacyContainerCacheFileName],
                                        [@"/private/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:kLegacyContainerCacheFileName],
                                        [@"/var/jb/private/var/mobile/Library/Preferences" stringByAppendingPathComponent:kLegacyContainerCacheFileName],
                                        nil];

    NSString* roothidePrefsDir = resolveRoothidePreferencesDirByAPI();
    if (roothidePrefsDir.length > 0) {
        [paths addObject:[roothidePrefsDir stringByAppendingPathComponent:kLegacyContainerCacheFileName]];
    }

    NSString* jbroot = resolveJbRootFromSelfExe();
    if (jbroot.length > 0) {
        [paths addObject:[[jbroot stringByAppendingPathComponent:@"var/mobile/Library/Preferences"] stringByAppendingPathComponent:kLegacyContainerCacheFileName]];
    }

    NSMutableArray<NSString*>* dedup = [NSMutableArray new];
    NSMutableSet<NSString*>* seen = [NSMutableSet new];
    for (NSString* path in paths) {
        if (path.length == 0 || [seen containsObject:path]) {
            continue;
        }
        [seen addObject:path];
        [dedup addObject:path];
    }
    return dedup;
}

static void cleanupLegacyContainerCacheFilesIfNeeded() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager* fm = [NSFileManager defaultManager];
        for (NSString* cachePath in legacyContainerCachePaths()) {
            BOOL isDirectory = NO;
            if (![fm fileExistsAtPath:cachePath isDirectory:&isDirectory] || isDirectory) {
                continue;
            }

            NSError* removeError = nil;
            if ([fm removeItemAtPath:cachePath error:&removeError]) {
                NSLog2(@"[CL] removed legacy container cache %@", cachePath);
                continue;
            }

            int rc = 0;
            if (getJBType() != JBTYPE_TROLLSTORE) {
                rc = spawn(@[@"/bin/rm", @"-f", cachePath], nil, nil, nil, SPAWN_FLAG_ROOT, nil);
            } else {
                rc = spawn(@[@"/bin/rm", @"-f", cachePath], nil, nil, nil, 0, nil);
            }
            if (rc == 0 && ![fm fileExistsAtPath:cachePath]) {
                NSLog2(@"[CL] removed legacy container cache via rm %@", cachePath);
                continue;
            }

            NSLog2(@"[CL] failed to remove legacy container cache %@ err=%@ rc=%d", cachePath, removeError, rc);
        }
    });
}

// ============================================================================
// REFACTOR: 新的简化路径初始化（使用 libroot）
// ============================================================================

/**
 * 简化的路径初始化 - 使用 libroot API
 *
 * 不再需要复杂的错误处理和降级逻辑，因为 libroot API 是可靠的。
 */

static void ensureAppPathsWithLibroot() {
    static NSObject* lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });

    @synchronized(lock) {
        // 如果已初始化，直接返回
        if (g_appDocumentsPath.length > 0 && g_runtimeDataRootPath.length > 0 &&
            g_logPath.length > 0 && g_confPath.length > 0 && g_dbPath.length > 0) {
            return;
        }

        // 使用新的 libroot 函数获取路径
        NSString* appDoc = resolveAppDocumentsPath();  // db/log 用 jbroot
        NSString* sharedDataRoot = getSharedDataRootPathWithLibroot();
        NSString* configRoot = getConfigRootPathWithLibroot();  // config 用 app 数据容器（不依赖 jbroot）

        if (!appDoc || !sharedDataRoot || !configRoot) {
            NSLog2(@"[CL] CRITICAL: Path resolution failed. appDoc=%@ sharedDataRoot=%@ configRoot=%@",
                   appDoc, sharedDataRoot, configRoot);
            if (getJBType() == JBTYPE_ROOTHIDE) {
                return;
            }
            // 降级到应用沙盒（仅在极端情况）
            NSString* fallback = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            appDoc = appDoc ?: fallback;
            sharedDataRoot = sharedDataRoot ?: fallback;
            configRoot = configRoot ?: fallback;
        }

        // 创建目录
        NSFileManager* fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:appDoc withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:sharedDataRoot withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:configRoot withIntermediateDirectories:YES attributes:nil error:nil];

        // 设置全局变量
        g_appDocumentsPath = appDoc;
        g_runtimeDataRootPath = sharedDataRoot;
        g_logPath = [sharedDataRoot stringByAppendingPathComponent:@LOG_FILENAME];
        g_confPath = [configRoot stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME];
        g_dbPath = [sharedDataRoot stringByAppendingPathComponent:@DB_FILENAME];

        NSLog2(@"[CL] Paths initialized (libroot):");
        NSLog2(@"  Config: %@", g_confPath);
        NSLog2(@"  Log: %@", g_logPath);
        NSLog2(@"  DB: %@", g_dbPath);

        cleanupLegacyContainerCacheFilesIfNeeded();
    }
}

NSString* getAppDocumentsPath() {
    ensureAppPathsWithLibroot();
    return g_appDocumentsPath;
}

extern "C" NSString* getAppDocumentsPath_C(void) {
    return getAppDocumentsPath();
}

NSString* getRuntimeDataRootPath(void) {
    ensureAppPathsWithLibroot();
    return g_runtimeDataRootPath;
}

extern "C" NSString* getRuntimeDataRootPath_C(void) {
    return getRuntimeDataRootPath();
}

extern "C" NSString* getLogPath_C(void) {
    return getLogPath();
}

NSString* getLogPath() {
    ensureAppPathsWithLibroot();
    return g_logPath;
}

NSString* getConfPath() {
    ensureAppPathsWithLibroot();
    return g_confPath;
}

extern "C" NSString* getConfPath_C(void) {
    return getConfPath();
}

NSString* getDbPath() {
    ensureAppPathsWithLibroot();
    return g_dbPath;
}

NSString* getConfDirPath() {
    ensureAppPathsWithLibroot();
    if (g_confPath.length == 0) {
        return nil;
    }
    return [g_confPath stringByDeletingLastPathComponent];
}

extern "C" NSString* getConfDirPath_C(void) {
    return getConfDirPath();
}

static void appendUniqueNormalizedPath(NSMutableArray<NSString*>* paths, NSString* path) {
    NSString* normalized = normalizedAbsolutePath(path);
    if (normalized.length == 0) {
        return;
    }
    if (![paths containsObject:normalized]) {
        [paths addObject:normalized];
    }
}

static void appendRoothidePreferencesDirForRoot(NSMutableArray<NSString*>* dirs, NSString* jbrootPath) {
    NSString* root = normalizedAbsolutePath(jbrootPath);
    if (root.length == 0 || ![root.lastPathComponent hasPrefix:@".jbroot-"]) {
        return;
    }
    appendUniqueNormalizedPath(dirs, [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]);
    appendUniqueNormalizedPath(dirs, [root stringByAppendingPathComponent:@"private/var/mobile/Library/Preferences"]);
}

static NSArray<NSString*>* roothideHistoricalPreferencesDirs(void) {
    if (getJBType() != JBTYPE_ROOTHIDE) {
        return @[];
    }

    NSMutableArray<NSString*>* dirs = [NSMutableArray new];
    NSString* roothidePrefsDir = resolveRoothidePreferencesDirByAPI();
    if (roothidePrefsDir.length > 0) {
        appendUniqueNormalizedPath(dirs, roothidePrefsDir);
    }

    NSString* inferredJbRoot = resolveJbRootFromSelfExe();
    if (inferredJbRoot.length > 0) {
        appendRoothidePreferencesDirForRoot(dirs, inferredJbRoot);
    }

    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* appBundleContainerRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString*>* topItems = [fm contentsOfDirectoryAtPath:appBundleContainerRoot error:nil];
    for (NSString* topItem in topItems) {
        NSString* topPath = [appBundleContainerRoot stringByAppendingPathComponent:topItem];
        BOOL topIsDir = NO;
        if (![fm fileExistsAtPath:topPath isDirectory:&topIsDir] || !topIsDir) {
            continue;
        }

        appendRoothidePreferencesDirForRoot(dirs, topPath);

        NSArray<NSString*>* childItems = [fm contentsOfDirectoryAtPath:topPath error:nil];
        for (NSString* childItem in childItems) {
            if (![childItem hasPrefix:@".jbroot-"]) {
                continue;
            }
            appendRoothidePreferencesDirForRoot(dirs, [topPath stringByAppendingPathComponent:childItem]);
        }
    }
    return dirs;
}

static void appendRoothideLegacySharedDataDirForRoot(NSMutableArray<NSString*>* dirs, NSString* jbrootPath) {
    NSString* root = normalizedAbsolutePath(jbrootPath);
    if (root.length == 0 || ![root.lastPathComponent hasPrefix:@".jbroot-"]) {
        return;
    }
    appendUniqueNormalizedPath(dirs, [root stringByAppendingPathComponent:@"var/mobile/Library/Application Support/ChargeLimiter"]);
    appendUniqueNormalizedPath(dirs, [root stringByAppendingPathComponent:@"private/var/mobile/Library/Application Support/ChargeLimiter"]);
}

static NSArray<NSString*>* roothideLegacySharedDataDirs(void) {
    if (getJBType() != JBTYPE_ROOTHIDE) {
        return @[];
    }

    NSMutableArray<NSString*>* dirs = [NSMutableArray new];
    NSString* resolved = resolveRoothidePathByAPI(kRoothideLegacySharedDataRoot);
    if (resolved.length > 0) {
        appendUniqueNormalizedPath(dirs, resolved);
    }

    NSString* inferredJbRoot = resolveJbRootFromSelfExe();
    if (inferredJbRoot.length > 0) {
        appendRoothideLegacySharedDataDirForRoot(dirs, inferredJbRoot);
    }

    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* appBundleContainerRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString*>* topItems = [fm contentsOfDirectoryAtPath:appBundleContainerRoot error:nil];
    for (NSString* topItem in topItems) {
        NSString* topPath = [appBundleContainerRoot stringByAppendingPathComponent:topItem];
        BOOL topIsDir = NO;
        if (![fm fileExistsAtPath:topPath isDirectory:&topIsDir] || !topIsDir) {
            continue;
        }

        appendRoothideLegacySharedDataDirForRoot(dirs, topPath);

        NSArray<NSString*>* childItems = [fm contentsOfDirectoryAtPath:topPath error:nil];
        for (NSString* childItem in childItems) {
            if (![childItem hasPrefix:@".jbroot-"]) {
                continue;
            }
            appendRoothideLegacySharedDataDirForRoot(dirs, [topPath stringByAppendingPathComponent:childItem]);
        }
    }

    return dirs;
}

static NSArray<NSString*>* configFilePathCandidates(BOOL includeHistoricalRoothidePaths) {
    ensureAppPathsWithLibroot();

    NSMutableArray<NSString*>* paths = [NSMutableArray new];

    // 1. 主路径：通过 libroot 解析的当前正确路径
    if (g_confPath.length > 0) {
        [paths addObject:g_confPath];
    }

    // 2. 历史路径：仅用于读取旧配置（迁移用）
    if (includeHistoricalRoothidePaths && getJBType() == JBTYPE_ROOTHIDE) {
        // 只在需要迁移时包含历史路径
        // 这些路径仅用于读取，不用于判断"当前正确路径"
        for (NSString* dir in roothideHistoricalPreferencesDirs()) {
            NSString* historicalPath = [dir stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME];
            if (historicalPath.length > 0 && ![paths containsObject:historicalPath]) {
                [paths addObject:historicalPath];
            }
        }
    }

    return paths;
}

static NSDictionary* readConfigDictionaryFromDisk(NSString** pathOut) {
    // REFACTOR: 使用新的简化实现
    return readConfigFromDiskWithLibroot(pathOut);
}

// ============================================================================
// REFACTOR: 简化的配置路径函数（使用 libroot）
// ============================================================================

/**
 * 获取配置文件写入路径（新实现 - 单一路径）
 *
 * 不再需要多个写入候选路径；roothide 使用 jbroot:/var/mobile/Library/Preferences。
 */
static NSString* getConfigWritePathWithLibroot(void) {
    ensureAppPathsWithLibroot();
    return g_confPath;  // 已经由 libroot 解析过的正确路径
}

/**
 * 获取配置文件读取路径列表（新实现）
 *
 * 返回主路径 + 可能的旧路径（用于迁移）
 */
static NSArray<NSString*>* getConfigReadPathsWithLibroot(void) {
    ensureAppPathsWithLibroot();

    NSMutableArray<NSString*>* paths = [NSMutableArray new];
    NSFileManager* fm = [NSFileManager defaultManager];

    // 1. 当前正确路径（libroot 解析的）
    if (g_confPath.length > 0) {
        [paths addObject:g_confPath];
    }

    BOOL primaryIsDir = NO;
    if (g_confPath.length > 0 &&
        [fm fileExistsAtPath:g_confPath isDirectory:&primaryIsDir] &&
        !primaryIsDir) {
        return paths;
    }

    // 2. roothide 旧路径：仅迁移历史 Preferences/Application Support，不迁移 /var/mobile/ChargeLimiter
    if (getJBType() == JBTYPE_ROOTHIDE) {
        for (NSString* dir in roothideLegacySharedDataDirs()) {
            NSString* oldSharedPath = [dir stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME];
            if ([fm fileExistsAtPath:oldSharedPath] && ![paths containsObject:oldSharedPath]) {
                [paths addObject:oldSharedPath];
            }
        }

        for (NSString* dir in roothideHistoricalPreferencesDirs()) {
            NSString* oldRoothidePath = [dir stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME];
            if ([fm fileExistsAtPath:oldRoothidePath] && ![paths containsObject:oldRoothidePath]) {
                [paths addObject:oldRoothidePath];
            }
        }
    }

    // TrollStore 旧位置
    NSString* oldTrollStore = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                               stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME];
    if ([fm fileExistsAtPath:oldTrollStore]) {
        [paths addObject:oldTrollStore];
    }

    // rootless 裸路径（不应该存在，但以防万一）
    NSString* barePath = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME];
    if ([fm fileExistsAtPath:barePath]) {
        [paths addObject:barePath];
    }

    return paths;
}

// ============================================================================
// REFACTOR: 简化的配置读写函数（使用 libroot）
// ============================================================================

/**
 * 写入配置数据到磁盘（新实现 - 单一路径）
 *
 * 简化逻辑：只写入一个正确的位置，不再尝试多个候选路径。
 * 当前路径初始化已按越狱类型解析，所以不需要多次写入尝试。
 */
static BOOL writeConfigDataToDiskWithLibroot(NSData* plistData, NSString** pathOut, NSError** errorOut) {
    if (!plistData || plistData.length == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ChargeLimiter"
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey: @"Empty plist data"}];
        }
        return NO;
    }

    NSString* confPath = getConfigWritePathWithLibroot();
    if (!confPath || confPath.length == 0) {
        NSLog2(@"[CL] ERROR: Failed to get config write path");
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ChargeLimiter"
                                            code:-2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Invalid config path"}];
        }
        return NO;
    }

    // 确保父目录存在
    NSString* parent = [confPath stringByDeletingLastPathComponent];
    NSFileManager* fm = [NSFileManager defaultManager];
    NSError* mkdirError = nil;

    if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
        NSLog2(@"[CL] ERROR: Failed to create directory %@: %@", parent, mkdirError);
        if (errorOut) {
            *errorOut = mkdirError;
        }
        return NO;
    }

    // 原子写入
    NSError* writeError = nil;
    if ([plistData writeToFile:confPath options:NSDataWritingAtomic error:&writeError]) {
        NSLog2(@"[CL] Config written successfully: %@ (%lu bytes)", confPath, (unsigned long)plistData.length);
        if (pathOut) {
            *pathOut = confPath;
        }
        return YES;
    }

    // 写入失败
    NSLog2(@"[CL] ERROR: Failed to write config to %@: %@", confPath, writeError);
    if (pathOut) {
        *pathOut = nil;
    }
    if (errorOut) {
        *errorOut = writeError;
    }
    return NO;
}

/**
 * 从磁盘读取配置（新实现）
 *
 * 优先读取主路径，如果不存在则尝试旧路径（用于迁移）
 */
static NSDictionary* readConfigFromDiskWithLibroot(NSString** loadedPathOut) {
    NSArray<NSString*>* paths = getConfigReadPathsWithLibroot();

    for (NSString* path in paths) {
        NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict && [dict isKindOfClass:[NSDictionary class]]) {
            NSLog2(@"[CL] Config loaded from: %@", path);
            if (loadedPathOut) {
                *loadedPathOut = path;
            }
            return dict;
        }
    }

    NSLog2(@"[CL] No config file found at any location");
    if (loadedPathOut) {
        *loadedPathOut = nil;
    }
    return nil;
}

static BOOL writeMergedConfigDictionaryToDisk(NSDictionary* fallbackPreferences,
                                              NSDictionary* pendingChanges,
                                              NSSet<NSString*>* removedKeys,
                                              NSString** pathOut,
                                              NSError** errorOut,
                                              NSMutableDictionary** mergedPreferencesOut) {
    NSMutableDictionary* mergedPreferences = nil;
    NSString* loadedPath = nil;
    NSDictionary* fileDict = readConfigDictionaryFromDisk(&loadedPath);
    if ([fileDict isKindOfClass:[NSDictionary class]]) {
        mergedPreferences = [fileDict mutableCopy];
    } else if ([fallbackPreferences isKindOfClass:[NSDictionary class]]) {
        mergedPreferences = [fallbackPreferences mutableCopy];
    } else {
        mergedPreferences = [NSMutableDictionary new];
    }

    for (NSString* key in removedKeys) {
        [mergedPreferences removeObjectForKey:key];
    }
    if ([pendingChanges isKindOfClass:[NSDictionary class]] && pendingChanges.count > 0) {
        [mergedPreferences addEntriesFromDictionary:pendingChanges];
    }

    NSError* plistError = nil;
    NSData* plistData = [NSPropertyListSerialization dataWithPropertyList:mergedPreferences
                                                                    format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0
                                                                     error:&plistError];
    if (!plistData) {
        if (pathOut) {
            *pathOut = nil;
        }
        if (errorOut) {
            *errorOut = plistError;
        }
        return NO;
    }

    NSError* writeError = nil;
    NSString* writtenPath = nil;
    if (!writeConfigDataToDiskWithLibroot(plistData, &writtenPath, &writeError)) {
        if (pathOut) {
            *pathOut = nil;
        }
        if (errorOut) {
            *errorOut = writeError;
        }
        return NO;
    }

    if (pathOut) {
        *pathOut = writtenPath;
    }
    if (errorOut) {
        *errorOut = nil;
    }
    if (mergedPreferencesOut) {
        *mergedPreferencesOut = mergedPreferences;
    }
    // root 写盘成功后交还 mobile 所有权，避免 App 原子替换失败
    repairSharedConfigFileOwnership(writtenPath);
    return YES;
}

/**
 * 若当前 euid==0，将共享配置文件与其目录交还 mobile:mobile。
 * 文件 0640，目录 0750。单点失败只打日志，不反向影响写成功结果。
 */
static void repairSharedConfigFileOwnership(NSString* confPath) {
    if (confPath.length == 0 || geteuid() != 0) {
        return;
    }

    struct passwd* pw = getpwnam("mobile");
    if (pw == NULL) {
        NSLog2(@"[CL] repairSharedConfigFileOwnership: getpwnam(mobile) failed path=%@", confPath);
        return;
    }

    uid_t uid = pw->pw_uid;
    gid_t gid = pw->pw_gid;
    NSString* dir = [confPath stringByDeletingLastPathComponent];
    const char* filePathC = confPath.fileSystemRepresentation;
    const char* dirPathC = dir.length > 0 ? dir.fileSystemRepresentation : NULL;

    if (dirPathC != NULL) {
        if (chown(dirPathC, uid, gid) != 0) {
            NSLog2(@"[CL] repairSharedConfigFileOwnership: chown dir failed path=%@ errno=%d", dir, errno);
        }
        if (chmod(dirPathC, 0750) != 0) {
            NSLog2(@"[CL] repairSharedConfigFileOwnership: chmod dir 0750 failed path=%@ errno=%d", dir, errno);
        }
    }

    if (chown(filePathC, uid, gid) != 0) {
        NSLog2(@"[CL] repairSharedConfigFileOwnership: chown file failed path=%@ errno=%d", confPath, errno);
    }
    if (chmod(filePathC, 0640) != 0) {
        NSLog2(@"[CL] repairSharedConfigFileOwnership: chmod file 0640 failed path=%@ errno=%d", confPath, errno);
    }
}

static NSArray<NSString*>* currentConfigCleanupPathCandidates(void) {
    // 现在只返回当前的主路径（通过 libroot 解析的）
    // configFilePathCandidates(NO) 已经简化为只返回 g_confPath
    NSMutableArray<NSString*>* paths = [NSMutableArray new];

    for (NSString* confPath in configFilePathCandidates(NO)) {
        NSString* normalized = normalizedAbsolutePath(confPath);
        if (normalized.length > 0) {
            [paths addObject:normalized];
        }
    }

    return paths;
}

static void migrateLoadedConfigToPreferredPathIfNeeded(NSDictionary* preferences, NSString* loadedPath) {
    NSString* primaryPath = normalizedAbsolutePath(getConfPath());
    NSString* sourcePath = normalizedAbsolutePath(loadedPath);
    if (preferences.count == 0 || primaryPath.length == 0 || sourcePath.length == 0 ||
        [sourcePath isEqualToString:primaryPath]) {
        return;
    }

    NSFileManager* fm = [NSFileManager defaultManager];
    BOOL isDir = NO;

    // 如果目标路径已存在，只清理旧路径
    if ([fm fileExistsAtPath:primaryPath isDirectory:&isDir] && !isDir) {
        if (!isRoothidePreferencesConfigPath(sourcePath) &&
            !pathMatchesAnyStableCurrentPath(sourcePath, currentConfigCleanupPathCandidates())) {
            // 不删除旧配置源：路径解析漂移时可能误判当前配置为旧配置并删除，导致配置丢失。
            // 主配置已存在，旧源残留不影响读取，保留由用户手动清理。
            NSLog2(@"[CL] preserved stale conf source (not auto-deleting) source=%@ target=%@",
                   sourcePath, primaryPath);
        }
        return;
    }

    NSError* writeError = nil;
    NSString* writtenPath = nil;
    if (!writeMergedConfigDictionaryToDisk(preferences, preferences, nil, &writtenPath, &writeError, nil)) {
        NSLog2(@"[CL] conf migration write failed: source=%@ target=%@ err=%@", sourcePath, primaryPath, writeError);
        return;
    }

    // 验证新文件可读取（防止权限问题）
    NSDictionary* verifyDict = [NSDictionary dictionaryWithContentsOfFile:writtenPath];
    if (![verifyDict isKindOfClass:[NSDictionary class]] || verifyDict.count == 0) {
        NSLog2(@"[CL] conf migration write succeeded but verify failed: written=%@", writtenPath);
        // 不删除旧配置，保留作为备份
        return;
    }

    // 验证成功，安全删除旧配置
    if (!isRoothidePreferencesConfigPath(sourcePath) &&
        !pathMatchesAnyStableCurrentPath(sourcePath, currentConfigCleanupPathCandidates())) {
        // 不删除旧配置源：避免路径漂移时误删当前配置。配置已写入新路径，旧源残留无害，保留由用户手动清理。
        NSLog2(@"[CL] conf migrated, old source preserved (not auto-deleting) source=%@ written=%@",
               sourcePath, writtenPath);
    } else {
        NSLog2(@"[CL] conf migrated (source preserved): source=%@ written=%@", sourcePath, writtenPath);
    }
}

extern "C" int cleanupAppDataContainer_C(void) {
    if (getJBType() != JBTYPE_TROLLSTORE) {
        NSString* sharedRoot = getRuntimeDataRootPath();
        NSString* confPath = getConfPath();
        NSArray<NSString*>* configCleanupPaths = currentConfigCleanupPathCandidates();
        NSFileManager* fm = [NSFileManager defaultManager];
        NSError* removeError = nil;
        if (sharedRoot.length > 0 && [fm fileExistsAtPath:sharedRoot]) {
            if (![fm removeItemAtPath:sharedRoot error:&removeError]) {
                NSLog2(@"[CL] cleanup_data_container failed sharedRoot=%@ err=%@", sharedRoot, removeError);
                return -1;
            }
        }
        for (NSString* configPath in configCleanupPaths) {
            removeError = nil;
            BOOL isDirectory = NO;
            if (![fm fileExistsAtPath:configPath isDirectory:&isDirectory] || isDirectory) {
                continue;
            }
            if (![fm removeItemAtPath:configPath error:&removeError]) {
                NSLog2(@"[CL] cleanup_data_container failed confPath=%@ err=%@", configPath, removeError);
                return -1;
            }
        }
        NSLog2(@"[CL] cleanup_data_container removed jailbreak shared data root=%@ conf=%@ candidates=%@",
               sharedRoot ?: @"", confPath ?: @"", configCleanupPaths);
        return 0;
    }

    NSString* bid = resolveAppBundleIdentifier();
    NSString* containerRoot = resolveExistingDataContainerRoot(bid);
    if (containerRoot.length == 0) {
        NSLog2(@"[CL] cleanup_data_container skipped: no container found for %@", bid ?: @"");
        return 0;
    }

    NSFileManager* fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:containerRoot isDirectory:&isDirectory]) {
        NSLog2(@"[CL] cleanup_data_container skipped: missing %@", containerRoot);
        return 0;
    }
    if (!isDirectory) {
        NSLog2(@"[CL] cleanup_data_container invalid target: %@", containerRoot);
        return -1;
    }

    NSError* removeError = nil;
    if ([fm removeItemAtPath:containerRoot error:&removeError]) {
        NSLog2(@"[CL] cleanup_data_container removed %@", containerRoot);
        return 0;
    }

    NSLog2(@"[CL] cleanup_data_container failed: %@ err=%@", containerRoot, removeError);
    return -1;
}

static NSArray<NSString*>* legacyMigratableFileNames() {
    return @[@CONFIG_PLIST_FILENAME, @DB_FILENAME];
}

static NSArray<NSString*>* legacyResidualFileNames() {
    return @[@CONFIG_PLIST_FILENAME, @DB_FILENAME, @LOG_FILENAME];
}

static NSString* latestLegacySourceForFile(NSString* file, NSString* legacyDir);

static BOOL legacyDirHasAllMigratableFiles(NSString* dir) {
    if (dir.length == 0) {
        return NO;
    }
    for (NSString* file in legacyMigratableFileNames()) {
        if (latestLegacySourceForFile(file, dir).length == 0) {
            return NO;
        }
    }
    return YES;
}

static NSArray<NSString*>* legacySourceFileNamesForTargetFile(NSString* targetFile) {
    if ([targetFile isEqualToString:@CONFIG_PLIST_FILENAME]) {
        return @[@CONFIG_PLIST_FILENAME, @LEGACY_CONF_FILENAME];
    }
    return targetFile.length > 0 ? @[targetFile] : @[];
}

static BOOL removeLegacyFilePreferRoot(NSString* path) {
    if (path.length == 0) {
        return NO;
    }
    NSFileManager* fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
        return YES;
    }

    NSError* removeError = nil;
    if ([fm removeItemAtPath:path error:&removeError]) {
        return YES;
    }

    // Fallback with root persona for paths like /var/root.
    int rc = spawn(@[@"/bin/rm", @"-f", path], nil, nil, nil, SPAWN_FLAG_ROOT, nil);
    if (rc == 0 && ![fm fileExistsAtPath:path]) {
        return YES;
    }
    return NO;
}

static BOOL removeEmptyDirectoryIfChargeLimiterRelated(NSString* dirPath) {
    if (dirPath.length == 0) {
        return NO;
    }

    // 只清理 ChargeLimiter 相关的目录
    NSString* lastComponent = [dirPath lastPathComponent];
    if (![lastComponent isEqualToString:@"ChargeLimiter"]) {
        return NO;
    }

    NSFileManager* fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) {
        return NO;
    }

    // 检查目录是否为空
    NSError* error = nil;
    NSArray<NSString*>* contents = [fm contentsOfDirectoryAtPath:dirPath error:&error];
    if (error || contents.count > 0) {
        return NO;
    }

    // 目录为空，尝试删除
    NSError* removeError = nil;
    if ([fm removeItemAtPath:dirPath error:&removeError]) {
        NSLog2(@"[CL] Removed empty ChargeLimiter directory: %@", dirPath);
        return YES;
    }

    // 使用 root 权限删除
    int rc = spawn(@[@"/bin/rmdir", dirPath], nil, nil, nil, SPAWN_FLAG_ROOT, nil);
    if (rc == 0 && ![fm fileExistsAtPath:dirPath]) {
        NSLog2(@"[CL] Removed empty ChargeLimiter directory (with root): %@", dirPath);
        return YES;
    }

    NSLog2(@"[CL] Failed to remove empty directory: %@ (error: %@)", dirPath, removeError);
    return NO;
}

static NSArray<NSString*>* legacyConfigCandidateDirs() {
    NSMutableArray<NSString*>* dirs = [NSMutableArray new];

    // Version 1 legacy path.
    [dirs addObject:@"/var/root"];

    // Version 2 legacy path (jailbreak prefs directory family).
    [dirs addObject:@"/var/mobile/Library/Preferences"];
    [dirs addObject:@"/var/jb/var/mobile/Library/Preferences"];

    NSString* roothidePrefsDir = resolveRoothidePreferencesDirByAPI();
    if (roothidePrefsDir.length > 0) {
        [dirs addObject:roothidePrefsDir];
    }

    NSString* inferredJbRoot = resolveJbRootFromSelfExe();
    if (inferredJbRoot.length > 0) {
        [dirs addObject:[inferredJbRoot stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]];
        [dirs addObject:[inferredJbRoot stringByAppendingPathComponent:@"private/var/mobile/Library/Preferences"]];
    }

    if (getJBType() == JBTYPE_ROOTHIDE) {
        [dirs addObjectsFromArray:roothideHistoricalPreferencesDirs()];
        [dirs addObjectsFromArray:roothideLegacySharedDataDirs()];
    }

    NSString* currentDir = getConfDirPath();
    NSString* currentDataRoot = getRuntimeDataRootPath();
    NSMutableArray<NSString*>* dedup = [NSMutableArray new];
    NSMutableSet<NSString*>* seen = [NSMutableSet new];
    for (NSString* dir in dirs) {
        if (dir.length == 0 || [seen containsObject:dir]) {
            continue;
        }
        if (currentDir.length > 0 && pathMatchesAnyStableCurrentPath(dir, @[currentDir])) {
            continue;
        }
        if (currentDataRoot.length > 0 && pathMatchesAnyStableCurrentPath(dir, @[currentDataRoot])) {
            continue;
        }
        [seen addObject:dir];
        [dedup addObject:dir];
    }
    return dedup;
}

static NSArray<NSString*>* currentRuntimePathsForLegacyDetection(void) {
    NSMutableArray<NSString*>* paths = [NSMutableArray new];
    NSMutableArray<NSString*>* candidates = [NSMutableArray arrayWithArray:@[
        getConfPath() ?: @"",
        getConfDirPath() ?: @"",
        getDbPath() ?: @"",
        getLogPath() ?: @"",
        getRuntimeDataRootPath() ?: @""
    ]];
    [candidates addObjectsFromArray:currentConfigCleanupPathCandidates()];
    for (NSString* path in candidates) {
        if (path.length == 0) {
            continue;
        }
        BOOL duplicate = NO;
        for (NSString* existing in paths) {
            if (pathsAreEquivalentForLegacyDetection(path, existing)) {
                duplicate = YES;
                break;
            }
        }
        if (!duplicate) {
            [paths addObject:path];
        }
    }
    return paths;
}

static BOOL isNSUserDefaultsOnlyPlist(NSString* path) {
    // 检查 plist 文件是否只包含 NSUserDefaults 写入的辅助键（非配置数据）
    // 如果是，则不应将其视为"残留配置文件"
    //
    // 注意：从本版本开始，NSUserDefaults 数据已改为存储在 com.chargelimiter.mod.appdata.plist，
    // 这个函数主要用于兼容旧版本遗留的 com.chargelimiter.mod.plist 文件。
    NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![dict isKindOfClass:[NSDictionary class]] || dict.count == 0) {
        return NO;
    }

    // 旧版本 NSUserDefaults 辅助键列表（迁移检查、版本更新检查等）
    // 这些键在旧版本中会被写入 standardUserDefaults，即 com.chargelimiter.mod.plist
    NSSet* userDefaultsOnlyKeys = [NSSet setWithArray:@[
        @"LegacyMigrationCheckedToken",
        @"CLUpdateCheckLastDate",
        @"CLUpdateCheckLatestVersion",
        @"CLUpdateCheckLatestURL",
        @"CLUpdateCheckLatestNotes",
        @"CLUpdateCheckLastError",
        @"CLUpdateCheckLastAlertedVersion",
        @"AppleLanguages",  // 语言设置
    ]];

    // 检查是否所有的键都是 NSUserDefaults 辅助键
    for (NSString* key in dict.allKeys) {
        if (![userDefaultsOnlyKeys containsObject:key]) {
            return NO;  // 发现非辅助键，说明包含真实配置数据
        }
    }

    return YES;  // 所有键都是辅助键
}

static NSArray<NSString*>* legacyResidualFilesInDir(NSString* dir) {
    NSMutableArray<NSString*>* files = [NSMutableArray new];
    if (dir.length == 0) {
        return files;
    }

    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSString*>* currentRuntimePaths = currentRuntimePathsForLegacyDetection();

    // 调试日志：输出当前运行时路径
    NSLog2(@"[CL] legacyResidualFilesInDir: checking dir=%@", dir);
    NSLog2(@"[CL] legacyResidualFilesInDir: currentRuntimePaths=%@", currentRuntimePaths);

    for (NSString* file in legacyResidualFileNames()) {
        for (NSString* sourceFile in legacySourceFileNamesForTargetFile(file)) {
            NSString* path = [dir stringByAppendingPathComponent:sourceFile];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
                continue;
            }

            BOOL isCurrentPath = pathMatchesAnyStableCurrentPath(path, currentRuntimePaths);

            // 调试日志：输出匹配结果
            NSLog2(@"[CL] legacyResidualFilesInDir: path=%@ isCurrentPath=%d", path, isCurrentPath);

            if (isCurrentPath) {
                continue;
            }

            // 如果是配置文件，检查是否只包含 NSUserDefaults 辅助键
            if ([sourceFile isEqualToString:@CONFIG_PLIST_FILENAME] ||
                [sourceFile isEqualToString:@LEGACY_CONF_FILENAME]) {
                if (isNSUserDefaultsOnlyPlist(path)) {
                    // 只包含辅助键，不视为残留配置文件
                    NSLog2(@"[CL] Skipping NSUserDefaults-only plist: %@", path);
                    continue;
                }
            }

            if (![files containsObject:path]) {
                [files addObject:path];
                NSLog2(@"[CL] legacyResidualFilesInDir: added residual file=%@", path);
            }
        }
    }
    return files;
}

static BOOL hasCompleteLegacyRuntimeFilesInDir(NSString* dir) {
    return legacyDirHasAllMigratableFiles(dir);
}

static NSArray<NSString*>* legacyConfigDirsWithData() {
    NSMutableArray<NSString*>* found = [NSMutableArray new];
    for (NSString* dir in legacyConfigCandidateDirs()) {
        if (hasCompleteLegacyRuntimeFilesInDir(dir)) {
            [found addObject:dir];
        }
    }
    return found;
}

extern "C" NSArray<NSString*>* getLegacyConfigDirsWithData_C(void) {
    return legacyConfigDirsWithData();
}

static NSArray<NSString*>* legacyResidualFiles(void) {
    NSMutableArray<NSString*>* files = [NSMutableArray new];
    NSInteger fullCount = (NSInteger)legacyResidualFileNames().count;
    for (NSString* dir in legacyConfigCandidateDirs()) {
        if (legacyDirHasAllMigratableFiles(dir)) {
            continue;
        }
        NSArray<NSString*>* residualFiles = legacyResidualFilesInDir(dir);
        NSInteger count = residualFiles.count;
        if (count <= 0 || count >= fullCount) {
            continue;
        }
        for (NSString* path in residualFiles) {
            if (![files containsObject:path]) {
                [files addObject:path];
            }
        }
    }
    return files;
}

extern "C" NSArray<NSString*>* getLegacyResidualFiles_C(void) {
    return legacyResidualFiles();
}

extern "C" NSDictionary* cleanupLegacyResidualFiles_C(void) {
    NSArray<NSString*>* files = legacyResidualFiles();
    NSMutableArray<NSString*>* errors = [NSMutableArray new];
    NSMutableSet<NSString*>* parentDirsToCheck = [NSMutableSet new];
    NSInteger removed = 0;
    NSInteger failed = 0;
    for (NSString* path in files) {
        if (removeLegacyFilePreferRoot(path)) {
            removed++;
            // 记录父目录，稍后检查是否为空
            NSString* parentDir = [path stringByDeletingLastPathComponent];
            if (parentDir.length > 0) {
                [parentDirsToCheck addObject:parentDir];
            }
        } else {
            failed++;
            [errors addObject:[NSString stringWithFormat:@"%@ remove failed", path]];
        }
    }

    // 清理空的 ChargeLimiter 目录
    for (NSString* parentDir in parentDirsToCheck) {
        removeEmptyDirectoryIfChargeLimiterRelated(parentDir);
    }

    return @{
        @"removed": @(removed),
        @"failed": @(failed),
        @"errors": errors,
        @"files": files
    };
}

static NSDate* fileModifyDate(NSString* path) {
    NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate* modified = attr[NSFileModificationDate];
    if ([modified isKindOfClass:[NSDate class]]) {
        return modified;
    }
    NSDate* created = attr[NSFileCreationDate];
    if ([created isKindOfClass:[NSDate class]]) {
        return created;
    }
    return [NSDate distantPast];
}

static NSDate* legacyDirLatestDate(NSString* dir) {
    NSDate* latest = [NSDate distantPast];
    for (NSString* file in legacyMigratableFileNames()) {
        for (NSString* sourceFile in legacySourceFileNamesForTargetFile(file)) {
            NSString* src = [dir stringByAppendingPathComponent:sourceFile];
            NSDate* d = fileModifyDate(src);
            if ([d compare:latest] == NSOrderedDescending) {
                latest = d;
            }
        }
    }
    return latest;
}

static NSString* latestLegacySourceForFile(NSString* file, NSString* legacyDir) {
    if (file.length == 0 || legacyDir.length == 0) {
        return nil;
    }
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* sourceFile in legacySourceFileNamesForTargetFile(file)) {
        NSString* candidate = [legacyDir stringByAppendingPathComponent:sourceFile];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && !isDir) {
            return candidate;
        }
    }
    return nil;
}

static NSString* latestLegacyDir(NSArray<NSString*>* legacyDirs) {
    NSString* latestDir = nil;
    NSDate* latestDate = [NSDate distantPast];
    for (NSString* dir in legacyDirs) {
        BOOL hasAll = YES;
        for (NSString* file in legacyMigratableFileNames()) {
            if (latestLegacySourceForFile(file, dir).length == 0) {
                hasAll = NO;
                break;
            }
        }
        if (!hasAll) {
            continue;
        }
        NSDate* modified = legacyDirLatestDate(dir);
        if (!latestDir || [modified compare:latestDate] == NSOrderedDescending) {
            latestDir = dir;
            latestDate = modified;
        }
    }
    return latestDir;
}

extern "C" NSDictionary* migrateLegacyConfigFiles_C(void) {
    ensureAppPathsWithLibroot();
    NSString* targetConfPath = getConfPath();
    NSString* targetDbPath = getDbPath();
    if (targetConfPath.length == 0 || targetDbPath.length == 0) {
        return @{
            @"migrated": @0,
            @"replaced": @0,
            @"missing": @0,
            @"failed": @1,
            @"errors": @[@"Target runtime path is unavailable."]
        };
    }

    NSArray<NSString*>* legacyDirs = legacyConfigDirsWithData();
    NSString* sourceDir = latestLegacyDir(legacyDirs);
    NSFileManager* fm = [NSFileManager defaultManager];
    NSMutableArray<NSString*>* errors = [NSMutableArray new];
    NSInteger migrated = 0;
    NSInteger replaced = 0;
    NSInteger missing = 0;
    NSInteger failed = 0;

    for (NSString* file in legacyMigratableFileNames()) {
        NSString* dst = nil;
        if ([file isEqualToString:@CONFIG_PLIST_FILENAME]) {
            dst = targetConfPath;
        } else if ([file isEqualToString:@DB_FILENAME]) {
            dst = targetDbPath;
        }
        if (dst.length == 0) {
            failed++;
            [errors addObject:[NSString stringWithFormat:@"%@ target path missing", file]];
            continue;
        }

        NSString* dstParent = [dst stringByDeletingLastPathComponent];
        if (dstParent.length > 0) {
            [fm createDirectoryAtPath:dstParent withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString* chosenSrc = latestLegacySourceForFile(file, sourceDir);

        if (chosenSrc.length == 0) {
            missing++;
            continue;
        }

        BOOL dstExists = [fm fileExistsAtPath:dst];
        if (dstExists) {
            NSError* removeError = nil;
            if (![fm removeItemAtPath:dst error:&removeError]) {
                failed++;
                [errors addObject:[NSString stringWithFormat:@"%@ remove failed (%@)", dst, removeError.localizedDescription ?: @"remove failed"]];
                continue;
            }
        }

        NSError* copyError = nil;
        BOOL ok = [fm copyItemAtPath:chosenSrc toPath:dst error:&copyError];
        if (ok) {
            // Cleanup all legacy duplicates of this file after successful migration.
            NSMutableSet<NSString*>* parentDirsToCheck = [NSMutableSet new];
            for (NSString* dir in legacyDirs) {
                for (NSString* sourceFile in legacySourceFileNamesForTargetFile(file)) {
                    NSString* src = [dir stringByAppendingPathComponent:sourceFile];
                    BOOL srcIsDir = NO;
                    if (![fm fileExistsAtPath:src isDirectory:&srcIsDir] || srcIsDir) {
                        continue;
                    }
                    if (!removeLegacyFilePreferRoot(src)) {
                        failed++;
                        [errors addObject:[NSString stringWithFormat:@"%@ remove failed", src]];
                    } else {
                        // 记录父目录，稍后检查是否为空
                        NSString* parentDir = [src stringByDeletingLastPathComponent];
                        if (parentDir.length > 0) {
                            [parentDirsToCheck addObject:parentDir];
                        }
                    }
                }
            }
            if (dstExists) {
                replaced++;
            } else {
                migrated++;
            }
            NSString* legacyLog = [sourceDir stringByAppendingPathComponent:@LOG_FILENAME];
            if ([fm fileExistsAtPath:legacyLog]) {
                if (removeLegacyFilePreferRoot(legacyLog)) {
                    NSString* logParent = [legacyLog stringByDeletingLastPathComponent];
                    if (logParent.length > 0) {
                        [parentDirsToCheck addObject:logParent];
                    }
                }
            }

            // 清理空的 ChargeLimiter 目录
            for (NSString* parentDir in parentDirsToCheck) {
                removeEmptyDirectoryIfChargeLimiterRelated(parentDir);
            }

            continue;
        }

        failed++;
        [errors addObject:[NSString stringWithFormat:@"%@ <- %@ (%@)", dst, chosenSrc, copyError.localizedDescription ?: @"copy failed"]];
    }

    NSLog2(@"[CL] legacy migration result: migrated=%ld replaced=%ld missing=%ld failed=%ld legacyDirs=%@ target_conf=%@ target_db=%@",
           (long)migrated, (long)replaced, (long)missing, (long)failed, legacyDirs, targetConfPath, targetDbPath);

    return @{
        @"migrated": @(migrated),
        @"replaced": @(replaced),
        @"missing": @(missing),
        @"failed": @(failed),
        @"errors": errors,
        @"legacyDirs": legacyDirs,
        @"targetDir": getRuntimeDataRootPath() ?: @"",
        @"targetConfPath": targetConfPath ?: @"",
        @"targetDbPath": targetDbPath ?: @""
    };
}

extern "C" {
CFTypeRef MGCopyAnswer(CFStringRef str);
}

int platformize_me() {
    int ret = 0;
    #define FLAG_PLATFORMIZE (1 << 1)
    void* h_jailbreak = dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY);
    if (h_jailbreak) {
        const char* dlsym_error = 0;
        dlerror();
        typedef void (*fix_entitle_prt_t)(pid_t pid, uint32_t what);
        fix_entitle_prt_t jb_oneshot_entitle_now = (fix_entitle_prt_t)dlsym(h_jailbreak, "jb_oneshot_entitle_now");
        dlsym_error = dlerror();
        if (jb_oneshot_entitle_now && !dlsym_error) {
            jb_oneshot_entitle_now(getpid(), FLAG_PLATFORMIZE);
        }
        dlerror();
        typedef void (*fix_setuid_prt_t)(pid_t pid);
        fix_setuid_prt_t jb_oneshot_fix_setuid_now = (fix_setuid_prt_t)dlsym(h_jailbreak, "jb_oneshot_fix_setuid_now");
        dlsym_error = dlerror();
        if (jb_oneshot_fix_setuid_now && !dlsym_error) {
            jb_oneshot_fix_setuid_now(getpid());
        }
    }
    ret += setuid(0);
    ret += setgid(0);
    return ret;
}

#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST            1
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK   5
typedef struct memorystatus_priority_entry {
    pid_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit;
    uint32_t state;
} memorystatus_priority_entry_t;
extern "C" {
int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void* buffer, size_t buffersize);
}
int32_t get_mem_limit(int pid) {
    int rc = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, 0, 0);
    if (rc < 1) {
        return -1;
    }
    struct memorystatus_priority_entry* buf = (struct memorystatus_priority_entry*)malloc(rc);
    rc = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, buf, rc);
    int32_t limit = -1;
    for (int i = 0 ; i < rc; i++) {
        if (buf[i].pid == pid) {
            limit = buf[i].limit;
            break;
        }
    }
    free((void*)buf);
    return limit;
}

int set_mem_limit(int pid, int mb) {
    if (get_mem_limit(pid) < mb) { // 单位MB
        return memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, pid, mb, 0, 0);
    }
    return 0;
}


#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" {
int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);
}

int fd_is_valid(int fd) {
    return fcntl(fd, F_GETFD) != -1 || errno != EBADF;
}

NSString* getNSStringFromFile(int fd) {
    NSMutableString* ms = [NSMutableString new];
    ssize_t num_read;
    char c;
    if (!fd_is_valid(fd)) {
        return @"";
    }
    while ((num_read = read(fd, &c, sizeof(c)))) {
        [ms appendString:[NSString stringWithFormat:@"%c", c]];
        //if(c == '\n') {
        //    break;
        //}
    }
    return ms.copy;
}

extern char** environ;
int spawn(NSArray* args, NSString** stdOut, NSString** stdErr, pid_t* pidPtr, int flag, NSDictionary* param) {
    NSString* file = args.firstObject;
    NSUInteger argCount = [args count];
    char **argsC = (char **)malloc((argCount + 1) * sizeof(char*));
    for (NSUInteger i = 0; i < argCount; i++) {
        argsC[i] = strdup([[args objectAtIndex:i] UTF8String]);
    }
    argsC[argCount] = NULL;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    if ((flag & SPAWN_FLAG_ROOT) != 0) {
        posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);
    }
    if ((flag & SPAWN_FLAG_SUSPEND) != 0) {
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED);
    }
    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);
    if (param != nil) {
        if (param[@"cwd"] != nil) {
            NSString* path = param[@"cwd"];
            // posix_spawn_file_actions_addchdir_np 在 iOS 上不可用，使用 chdir 替代
            // 注意：这会改变整个进程的工作目录，但在 spawn 后会恢复
            // posix_spawn_file_actions_addchdir_np(&action, path.UTF8String);
            chdir(path.UTF8String);
        }
        if (param[@"close"] != nil) {
            NSArray* closes_fds = param[@"close"];
            for (NSNumber* nfd in closes_fds) {
                posix_spawn_file_actions_addclose(&action, nfd.intValue);
            }
        }
    }
    int outErr[2];
    if(stdErr) {
        pipe(outErr);
        posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&action, outErr[0]);
    }
    int out[2];
    if(stdOut) {
        pipe(out);
        posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&action, out[0]);
    }
    pid_t task_pid = -1;
    pid_t* task_pid_ptr = &task_pid;
    if (pidPtr != 0) {
        *pidPtr = -1;
        task_pid_ptr = pidPtr;
    }
    int status = -200;
    int spawnError = posix_spawnp(task_pid_ptr, [file UTF8String], &action, &attr, (char* const*)argsC, environ);
    NSLog2(@"%@ posix_spawn %@ ret=%d -> %d", log_prefix, args.firstObject, spawnError, *task_pid_ptr);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&action);
    for (NSUInteger i = 0; i < argCount; i++) {
        free(argsC[i]);
    }
    free(argsC);
    if(spawnError != 0) {
        NSLog2(@"%@ posix_spawn error %d\n", log_prefix, spawnError);
        return spawnError;
    }
    if ((flag & SPAWN_FLAG_NOWAIT) != 0) {
        return 0;
    }
    __block volatile BOOL _isRunning = YES;
    NSMutableString* outString = [NSMutableString new];
    NSMutableString* errString = [NSMutableString new];
    dispatch_semaphore_t sema = 0;
    dispatch_queue_t logQueue;
    if(stdOut || stdErr) {
        logQueue = dispatch_queue_create("com.opa334.TrollStore.LogCollector", NULL);
        sema = dispatch_semaphore_create(0);
        int outPipe = out[0];
        int outErrPipe = outErr[0];
        __block BOOL outEnabled = stdOut != nil;
        __block BOOL errEnabled = stdErr != nil;
        dispatch_async(logQueue, ^{
            while(_isRunning) {
                @autoreleasepool {
                    if(outEnabled) {
                        [outString appendString:getNSStringFromFile(outPipe)];
                    }
                    if(errEnabled) {
                        [errString appendString:getNSStringFromFile(outErrPipe)];
                    }
                }
            }
            dispatch_semaphore_signal(sema);
        });
    }
    do {
        if (waitpid(task_pid, &status, 0) != -1) {
            NSLog2(@"%@ Child status %d", log_prefix, WEXITSTATUS(status));
        } else {
            perror("waitpid");
            _isRunning = NO;
            return -222;
        }
    } while (!WIFEXITED(status) && !WIFSIGNALED(status));
    _isRunning = NO;
    if (stdOut || stdErr) {
        if(stdOut) {
            close(out[1]);
        }
        if(stdErr) {
            close(outErr[1]);
        }
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        if(stdOut) {
            *stdOut = outString.copy;
        }
        if(stdErr) {
            *stdErr = errString.copy;
        }
    }
    return WEXITSTATUS(status);
}

void addPathEnv(NSString* path, BOOL tail) {
    const char* c_path_env = getenv("PATH");
    NSMutableArray* path_arr = [NSMutableArray new];
    if (c_path_env != 0) {
        path_arr = [[@(c_path_env) componentsSeparatedByString:@":"] mutableCopy];
    }
    if (tail) {
        [path_arr addObject:path];
    } else {
        [path_arr insertObject:path atIndex:0];
    }
    NSString* path_env = [path_arr componentsJoinedByString:@":"];
    setenv("PATH", path_env.UTF8String, 1);
}

int get_pid_of(const char* name) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    sysctl(mib, 3, 0, &length, 0, 0);
    length += sizeof(kinfo_proc) * 3;
    kinfo_proc* proc_list = (kinfo_proc*)malloc(length);
    int result = -1;
    if (0 == sysctl(mib, 3, proc_list, &length, 0, 0)) {
        for (int i = 0; i < length / sizeof(kinfo_proc); i++) {
            int pid = proc_list[i].kp_proc.p_pid;
            if (0 == strncmp(proc_list[i].kp_proc.p_comm, name, MAXCOMLEN)) {
                result = pid;
                break;
            }
        }
    }
    free((void*)proc_list);
    return result;
}

int get_sys_boottime() {
    static int ts = 0;
    if (ts == 0) {
        int mib[] = {CTL_KERN, KERN_BOOTTIME};
        struct timeval boottime;
        size_t sz = sizeof(boottime);
        sysctl(mib, 2, &boottime, &sz, 0, 0);
        ts = (int)boottime.tv_sec;
    }
    return ts;
}

extern "C" int get_sys_boottime_C(void) {
    return get_sys_boottime();
}

NSString* findAppPath(NSString* name) {
    if (name == nil) {
        return nil;
    }
    NSString* appContainersPath = @"/var/containers/Bundle/Application";
    NSError* error = nil;
    NSArray* containers = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appContainersPath error:&error];
    if (!containers) {
        return nil;
    }
    for (NSString* container in containers) {
        NSString* containerPath = [appContainersPath stringByAppendingPathComponent:container];
        BOOL isDirectory = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:containerPath isDirectory:&isDirectory];
        if (exists && isDirectory) {
            NSString* path = [containerPath stringByAppendingFormat:@"/%@.app", name];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return path;
            }
        }
    }
    return nil;
}

NSString* getLocalIP() { // 获取wifi ipv4
    NSString* result = nil;
    struct ifaddrs* interfaces = 0;
    struct ifaddrs* temp_addr = 0;
    if (0 == getifaddrs(&interfaces)) {
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                if(!strcmp(temp_addr->ifa_name, "en0")) {
                    char* ip = inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr);
                    result = @(ip);
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return result;
}

BOOL localPortOpen(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in ip4;
    memset(&ip4, 0, sizeof(struct sockaddr_in));
    ip4.sin_len = sizeof(ip4);
    ip4.sin_family = AF_INET;
    ip4.sin_port = htons(port);
    inet_aton("127.0.0.1", &ip4.sin_addr);
    int so_error = -1;
    struct timeval tv;
    fd_set fdset;
    fcntl(sock, F_SETFL, O_NONBLOCK);
    connect(sock, (struct sockaddr*)&ip4, sizeof(ip4));
    FD_ZERO(&fdset);
    FD_SET(sock, &fdset);
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    if (select(sock + 1, NULL, &fdset, NULL, &tv) == 1) {
        socklen_t len = sizeof(so_error);
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
    }
    close(sock);
    return 0 == so_error;
}

extern "C" int _NSGetExecutablePath(char* buf, uint32_t* bufsize);
NSString* getSelfExePath() {
    uint32_t bufsize = 0;
    _NSGetExecutablePath(NULL, &bufsize);
    if (bufsize == 0) {
        return @"";
    }

    char* exe = (char*)calloc(bufsize + 1, sizeof(char));
    if (!exe) {
        return @"";
    }
    int rc = _NSGetExecutablePath(exe, &bufsize);
    NSString* path = @"";
    if (rc == 0 && exe[0] != '\0') {
        path = @(exe);
    }
    free(exe);
    return path;
}

extern "C" NSString* getSelfExePath_C(void) {
    return getSelfExePath();
}

int getJBType() {
    /*  EXE和DAEMON路径可能不同,需要综合判断
        注意本函数里不能直接从特殊路径存在直接判断,因为可能有巨魔/越狱混合环境
        有根越狱: /Applications/ChargeLimiter.app/ChargeLimiter (也可能是roothide)
        无根越狱: /var/jb/Applications/ChargeLimiter.app/ChargeLimiter
                [/private]/preboot/[UUID]/jb-[UUID]/procursus/Applications/ChargeLimiter.app/ChargeLimiter
                [/private]/preboot/[UUID]/dopamine-[UUID]/procursus/Applications/ChargeLimiter.app/ChargeLimiter
        roothide:/var/containers/Bundle/Application/.jbroot-[UUID]/Applications/ChargeLimiter.app/ChargeLimiter
        TrollStore/AppStore: [/private]/var/containers/Bundle/Application/[UUID]/ChargeLimiter.app/ChargeLimiter
     */
    Dl_info di;
    dladdr((void*)getJBType, &di);
    NSString* path = @(di.dli_fname);
    if (resolveRoothidePreferencesDirByAPI().length > 0) {
        return JBTYPE_ROOTHIDE;
    }
    if ([path hasPrefix:@"/Applications"]) {
        return JBTYPE_ROOT; // may be roothide for daemon
    }
    if ([path hasPrefix:@"/private"]) {
        path = [path substringFromIndex:8];
    }
    if ([path hasPrefix:@"/var/jb"] || [path hasPrefix:@"/preboot"]) {
        return JBTYPE_ROOTLESS;
    }
    if ([path containsString:@".app/"]) { // for App
        NSArray* parts = [path componentsSeparatedByString:@"/"];
        if (parts.count < 4) {
            return JBTYPE_UNKNOWN;
        }
        NSString* path_3 = parts[parts.count - 3];
        if (path_3.length == 36) { // UUID
            return JBTYPE_TROLLSTORE;
        }
        NSString* path_4 = parts[parts.count - 4];
        if ([path_4 hasPrefix:@".jbroot-"]) {
            return JBTYPE_ROOTHIDE;
        }
        return JBTYPE_UNKNOWN;
    } else if ([path containsString:@"LaunchDaemons/"]) { // for Daemon
        char resolved[PATH_MAX] = {0};
        if (realpath("/var/jb", resolved) != NULL) {
            NSString* realJb = @(resolved);
            if ([realJb containsString:@"/.jbroot-"]) {
                return JBTYPE_ROOTHIDE;
            }
            if ([realJb containsString:@"/preboot/"]) {
                return JBTYPE_ROOTLESS;
            }
        }
        return JBTYPE_ROOT;
    }
    return JBTYPE_ROOT;
    // todo
}

extern "C" int getJBType_C(void) {
    return getJBType();
}

extern "C" int restartDaemonForApp_C(NSString* appDocs) {
    NSString* bundlePath = [getSelfExePath() stringByDeletingLastPathComponent];
    NSString* daemonPath = [bundlePath stringByAppendingPathComponent:@"ChargeLimiterDaemon"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:daemonPath]) {
        NSLog2(@"[CL] restartDaemonForApp_C daemon missing: %@", daemonPath);
        return -3;
    }

    NSMutableArray* argv = [NSMutableArray arrayWithObject:daemonPath];
    if ([appDocs isKindOfClass:[NSString class]] && appDocs.length > 0) {
        [argv addObject:@"--app-docs"];
        [argv addObject:appDocs];
    }

    int jbType = getJBType();
    int spawnFlags = SPAWN_FLAG_NOWAIT;
    BOOL triedRoot = NO;
    if (jbType != JBTYPE_TROLLSTORE) {
        spawnFlags |= SPAWN_FLAG_ROOT;
        triedRoot = YES;
    }
    int rc = spawn(argv, nil, nil, nil, spawnFlags, nil);
    NSLog2(@"[CL] restartDaemonForApp_C spawn rc=%d jbType=%d flags=%d argv=%@", rc, jbType, spawnFlags, argv);

    // Some environments report non-TrollStore jbType in app process and root persona spawn fails with EPERM.
    // Retry once without root to keep daemon reachable for config/API path.
    if (rc != 0 && triedRoot) {
        int retryFlags = SPAWN_FLAG_NOWAIT;
        int rc2 = spawn(argv, nil, nil, nil, retryFlags, nil);
        NSLog2(@"[CL] restartDaemonForApp_C retry-nonroot rc=%d flags=%d argv=%@", rc2, retryFlags, argv);
        if (rc2 == 0) {
            return 0;
        }
    }
    return rc;
}

// === daemon 链路修复工具（App 侧）===
// 定位逻辑与 restartDaemonForApp_C 相同：App 自身 bundle 目录下的 ChargeLimiterDaemon
static NSString* CLDaemonPathForApp(void) {
    NSString* bundlePath = [getSelfExePath() stringByDeletingLastPathComponent];
    if (bundlePath.length == 0) {
        return @"";
    }
    return [bundlePath stringByAppendingPathComponent:@"ChargeLimiterDaemon"];
}

// 从自身 exe 截取 .jbroot-XXX 前缀（launchctl plist 候选路径推导用）
static NSString* CLDaemonJbRootPath(void) {
    NSString* exe = getSelfExePath();
    NSArray* parts = [exe componentsSeparatedByString:@"/"];
    NSMutableArray* kept = [NSMutableArray array];
    for (NSString* p in parts) {
        [kept addObject:p];
        if ([p hasPrefix:@".jbroot-"]) {
            break;
        }
    }
    NSString* root = [kept componentsJoinedByString:@"/"];
    return (root.length > 1) ? root : @"";
}

// aldente.log 尾部（daemon 离线时的“尸检报告”）
static NSString* CLReadDaemonLogTail(NSInteger maxLines) {
    if (maxLines <= 0) {
        maxLines = 1;
    }
    NSString* logPath = getLogPath();
    if (logPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        return @"";
    }
    NSString* content = [NSString stringWithContentsOfFile:logPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (content.length == 0) {
        return @"";
    }
    NSArray<NSString*>* lines = [content componentsSeparatedByString:@"\n"];
    NSInteger count = (NSInteger)lines.count;
    NSInteger keep = MIN(count, maxLines);
    NSArray<NSString*>* tail = [lines subarrayWithRange:NSMakeRange((NSUInteger)(count - keep),
                                                                   (NSUInteger)keep)];
    return [tail componentsJoinedByString:@"\n"];
}

static void NSFileLogWithArguments(NSString* fmt, va_list va) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString* dateStr = [formatter stringFromDate:NSDate.date];
    NSString* content = [[NSString alloc] initWithFormat:fmt arguments:va];
    content = [NSString stringWithFormat:@"%@ %@\n", dateStr, content];
    NSString* logPath = getLogPath();
    if (logPath.length == 0) {
        return;
    }
    static const unsigned long long kMaxFileLogBytes = 256 * 1024;
    NSFileManager* fm = [NSFileManager defaultManager];
    unsigned long long fileSize = [[fm attributesOfItemAtPath:logPath error:nil][NSFileSize] unsignedLongLongValue];
    if (fileSize > kMaxFileLogBytes) {
        [fm createFileAtPath:logPath contents:nil attributes:nil];
    }
    NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (handle == nil) {
        [fm createFileAtPath:logPath contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [handle seekToEndOfFile];
    [handle writeData:[content dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

void NSFileErrorLog(NSString* fmt, ...) {
    va_list va;
    va_start(va, fmt);
    NSFileLogWithArguments(fmt, va);
    va_end(va);
}

NSString* getAppVer() {
    static NSString* ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return ver;
}

NSString* getSysVer() {
    CFTypeRef val = MGCopyAnswer(CFSTR("ProductVersion"));
    return (__bridge_transfer NSString*)val;
}

NSOperatingSystemVersion getSysVerInt() {
    static NSOperatingSystemVersion ver = NSProcessInfo.processInfo.operatingSystemVersion;
    return ver;
}

NSString* getDevMdoel() {
    static NSString* model = nil;
    if (model == nil) {
        struct utsname name;
        uname(&name);
        model = @(name.machine);
    }
    return model;
}

CGFloat getOrientAngle(UIDeviceOrientation orientation) {
    switch (orientation) {
        case UIDeviceOrientationPortraitUpsideDown:
            return M_PI;
        case UIDeviceOrientationLandscapeLeft:
            return M_PI_2;
        case UIDeviceOrientationLandscapeRight:
            return -M_PI_2;
        default:
            return 0;
    }
}

NSArray* getUnusedFds() { // posix_spawn会将socket等fd继承给子进程
    NSMutableArray* result = [NSMutableArray new];
    for (int fd = 0; fd < 100; fd++) {
        struct stat st;
        if (0 == fstat(fd, &st)) {
            if (S_ISSOCK(st.st_mode)) { // 避免子进程端口占用造成不必要的麻烦
                [result addObject:@(fd)];
            }
        }
    }
    return result;
}


#define PROC_PIDPATHINFO                11
#define PROC_PIDPATHINFO_SIZE           (MAXPATHLEN)

// 只读探针：不做任何副作用，供诊断报告离线段使用
extern "C" NSDictionary* clDaemonLaunchProbe_C(void) {
    NSString* daemonPath = CLDaemonPathForApp();
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    out[@"daemon_path"] = daemonPath ?: @"";
    out[@"daemon_exists"] = @([[NSFileManager defaultManager] fileExistsAtPath:daemonPath]);
    out[@"initial_port_open"] = @(localPortOpen(GSERV_PORT));
    out[@"log_tail"] = CLReadDaemonLogTail(20);
    return out;
}

extern "C" NSDictionary* clRepairDaemonForApp_C(void) {
    // 自愈 + 报告：用户显式触发。kill 残留 → spawn(root→非root) → 等端口 → launchctl 尽力而为。
    // nonroot_spawn_rc：根/便携回退失败时的 rc；仅在 root 失败且非 TrollStore 环境时尝试，否则 -999。
    NSString* daemonPath = CLDaemonPathForApp();
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    out[@"daemon_path"] = daemonPath ?: @"";
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:daemonPath];
    out[@"daemon_exists"] = @(exists);

    BOOL alreadyOpen = localPortOpen(GSERV_PORT);
    out[@"initial_port_open"] = @(alreadyOpen);
    if (alreadyOpen) {
        out[@"repair_result"] = @"already_up";
        out[@"final_port_open"] = @YES;
        out[@"log_tail"] = CLReadDaemonLogTail(20);
        return out;
    }
    if (!exists) {
        out[@"repair_result"] = @"path_missing";
        out[@"final_port_open"] = @NO;
        out[@"log_tail"] = CLReadDaemonLogTail(20);
        return out;
    }

    int jbType = getJBType();
    int rootFlags = (jbType != JBTYPE_TROLLSTORE) ? SPAWN_FLAG_ROOT : 0;

    // 1) 杀残留 daemon（best-effort；EPERM/ENOENT 属预期，rc 记录）
    out[@"kill_rc"] = @(spawn(@[@"/usr/bin/killall", @"-9", @"ChargeLimiterDaemon"],
                              nil, nil, nil, SPAWN_FLAG_NOWAIT | rootFlags, nil));

    // 2) spawn daemon：root 优先，EPERM 时 nonroot（口径与 restartDaemonForApp_C 一致）
    NSMutableArray* argv = [NSMutableArray arrayWithObject:daemonPath];
    NSString* appDocs = getAppDocumentsPath();
    if (appDocs.length > 0) {
        [argv addObject:@"--app-docs"];
        [argv addObject:appDocs];
    }
    int rootRc = spawn(argv, nil, nil, nil, SPAWN_FLAG_NOWAIT | rootFlags, nil);
    out[@"root_spawn_rc"] = @(rootRc);
    int nonrootRc = -999;
    if (rootRc != 0 && rootFlags) {
        nonrootRc = spawn(argv, nil, nil, nil, SPAWN_FLAG_NOWAIT, nil);
    }
    out[@"nonroot_spawn_rc"] = @(nonrootRc);

    // 3) 轮询 1230 至多 ~5s（300ms × 17）
    BOOL afterSpawn = NO;
    for (int i = 0; i < 17; i++) {
        if (localPortOpen(GSERV_PORT)) {
            afterSpawn = YES;
            break;
        }
        usleep(300 * 1000);
    }
    out[@"port_after_spawn"] = @(afterSpawn);

    // 4) launchctl 尽力而为（relaxin App sandbox 下常 EPERM；只留证，不重试）
    NSInteger lrc = -1;
    NSString* lout = @"";
    BOOL attempted = NO;
    if (!afterSpawn) {
        NSMutableArray* candidates = [NSMutableArray arrayWithObject:
            @"/Library/LaunchDaemons/com.chargelimiter.mod.plist"];
        NSString* jbRoot = CLDaemonJbRootPath();
        if (jbRoot.length > 0) {
            [candidates addObject:
                [jbRoot stringByAppendingPathComponent:@"Library/LaunchDaemons/com.chargelimiter.mod.plist"]];
        }
        for (NSString* plist in candidates) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:plist]) {
                continue;
            }
            NSString* bootOut = nil;
            NSString* bootErr = nil;
            spawn(@[@"/bin/launchctl", @"bootout", @"system/com.chargelimiter.mod"],
                  &bootOut, &bootErr, nil, rootFlags, nil);
            NSString* splash = bootErr ?: (bootOut ?: @"");
            NSString* bOut = nil;
            NSString* bErr = nil;
            lrc = spawn(@[@"/bin/launchctl", @"bootstrap", @"system", plist],
                        &bOut, &bErr, nil, rootFlags, nil);
            attempted = YES;
            lout = bErr.length ? bErr : (bOut.length ? bOut : splash);
            for (int i = 0; i < 10; i++) {
                if (localPortOpen(GSERV_PORT)) {
                    break;
                }
                usleep(300 * 1000);
            }
            break;
        }
    }
    out[@"launchctl_attempted"] = @(attempted);
    out[@"launchctl_rc"] = @((int)lrc);
    out[@"launchctl_out"] = lout ?: @"";

    BOOL finalOpen = localPortOpen(GSERV_PORT);
    out[@"final_port_open"] = @(finalOpen);
    out[@"repair_result"] = finalOpen ? @"recovered" : @"still_down";
    out[@"log_tail"] = CLReadDaemonLogTail(20);
    return out;
}

extern "C" {
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
}

@interface BKSApplicationStateMonitor: NSObject
- (NSDictionary*)applicationInfoForApplication:(NSString*)bid;
- (NSDictionary*)applicationInfoForPID:(int)pid;
@end

static NSArray* getAllAppProcs() {
    NSMutableArray* result = [NSMutableArray array];
    size_t length = 0;
    int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    if (0 != sysctl(name, 3, 0, &length, 0, 0)) {
        return nil;
    }
    length += 3 * sizeof(struct kinfo_proc);
    struct kinfo_proc* proc_list = (struct kinfo_proc*)malloc(length);
    if (0 != sysctl(name, 3, proc_list, &length, 0, 0)) {
        free((void*)proc_list);
        return nil;
    }
    int proc_count = int(length / sizeof(struct kinfo_proc));
    if (proc_count > 4096) {
        proc_count = 4096;
    }
    for (int i = 0; i < proc_count; i++) {
        char path[PROC_PIDPATHINFO_SIZE];
        pid_t pid = proc_list[i].kp_proc.p_pid;
        int ret = proc_pidinfo(pid, PROC_PIDPATHINFO, 0, path, sizeof(path));
        if (ret == 0) {
            if (strstr(path, ".app/") != 0) {
                [result addObject:@(pid)];
            }
        }
    }
    free((void*)proc_list);
    return result;
}

NSArray* getFrontMostBid() {
    if (false) { // for iOS<=13 || 注入SpringBoard || 二进制在系统分区
        static mach_port_t (*SBSSpringBoardServerPort_)() = (__typeof(SBSSpringBoardServerPort_))dlsym(RTLD_DEFAULT, "SBSSpringBoardServerPort");
        static void (*SBFrontmostApplicationDisplayIdentifier_)(mach_port_t port, char *result) = (__typeof(SBFrontmostApplicationDisplayIdentifier_))dlsym(RTLD_DEFAULT, "SBFrontmostApplicationDisplayIdentifier");
        static mach_port_t sb_port = SBSSpringBoardServerPort_();
        char buf[PATH_MAX];
        memset(buf, 0, sizeof(buf));
        SBFrontmostApplicationDisplayIdentifier_(sb_port, buf);
        NSMutableArray* allFrontMostBid = [NSMutableArray array];
        if (buf[0] < 'A' || buf[0] > 'z') { // 缓冲区有乱码
        } else {
            [allFrontMostBid addObject:@(buf)];
        }
        return allFrontMostBid;
    }
    NSArray* allAppPids = getAllAppProcs();
    BKSApplicationStateMonitor* monitor = [objc_getClass("BKSApplicationStateMonitor") new];
    NSMutableArray* allFrontMostBid = [NSMutableArray new]; // 最前App不止一个
    for (NSNumber* pid in allAppPids) {
        NSDictionary* appInfo = [monitor applicationInfoForPID:pid.intValue];
        if (appInfo != nil) {
            NSNumber* isFrontMost = appInfo[@"BKSApplicationStateAppIsFrontmost"];
            if (isFrontMost.boolValue) {
                NSString* bid = appInfo[@"SBApplicationStateDisplayIDKey"];
                // 以下bid会被认为是frontmost:
                //  com.apple.springboard                   always
                //  com.apple.AccessibilityUIServer
                //  com.apple.CarPlayApp
                //  com.apple.CarPlaySplashScreen
                //  com.apple.CarPlayTemplateUIHost
                //  com.apple.ScreenshotServicesService??
                if (bid != nil && ![bid isEqualToString:@"com.apple.springboard"] && ![bid hasPrefix:@"com.apple.Accessibility"] &&
                    ![bid hasPrefix:@"com.apple.CarPlay"]) {
                    [allFrontMostBid addObject:bid];
                }
            }
        }
    }
    if (allFrontMostBid.count > 0) {
        if (allFrontMostBid.count > 1) {
            NSFileErrorLog(@"floatwnd unexpected frontmost bid %@", allFrontMostBid);
        }
    }
    return allFrontMostBid;
}


@interface RadiosPreferences : NSObject
- (BOOL)airplaneMode;
- (void)setAirplaneMode:(BOOL)flag;
- (void)setAirplaneModeWithoutMirroring:(BOOL)flag;
@end

static RadiosPreferences* getAirMan() {
    static RadiosPreferences* radio = [objc_getClass("RadiosPreferences") new];
    return radio;
}

BOOL isAirEnable() {
    RadiosPreferences* radio = getAirMan();
    return radio.airplaneMode;
}

void setAirEnable(BOOL flag) {
    RadiosPreferences* radio = getAirMan();
    if (radio.airplaneMode != flag) {
        [radio setAirplaneMode:flag];
    }
}

typedef struct __WiFiManagerClient* WiFiManagerClientRef;
static int (*WiFiManagerClientSetPower_)(WiFiManagerClientRef manager, BOOL on);
static BOOL (*WiFiManagerClientGetPower_)(WiFiManagerClientRef manager);
static WiFiManagerClientRef (*WiFiManagerClientCreate_)(CFAllocatorRef allocator, int type);

static WiFiManagerClientRef getWiFiMan() {
    static WiFiManagerClientRef man = nil;
    if (man == nil) {
        NSBundle* b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MobileWiFi.framework"];
        [b load];
        WiFiManagerClientSetPower_ = (__typeof(WiFiManagerClientSetPower_))dlsym(RTLD_DEFAULT, "WiFiManagerClientSetPower");
        WiFiManagerClientGetPower_ = (__typeof(WiFiManagerClientGetPower_))dlsym(RTLD_DEFAULT, "WiFiManagerClientGetPower");
        WiFiManagerClientCreate_ = (__typeof(WiFiManagerClientCreate_))dlsym(RTLD_DEFAULT, "WiFiManagerClientCreate");
        if (WiFiManagerClientCreate_ && WiFiManagerClientGetPower_ && WiFiManagerClientSetPower_) {
            man = WiFiManagerClientCreate_(kCFAllocatorDefault, 0);
        } else {
            NSLog2(@"[CL] MobileWiFi symbols unavailable, WiFi control disabled.");
        }
    }
    return man;
}

BOOL isWiFiEnable() {
    WiFiManagerClientRef man = getWiFiMan();
    if (!man || !WiFiManagerClientGetPower_) {
        return NO;
    }
    return WiFiManagerClientGetPower_(man);
}

void setWiFiEnable(BOOL flag) {
    WiFiManagerClientRef man = getWiFiMan();
    if (!man || !WiFiManagerClientGetPower_ || !WiFiManagerClientSetPower_) {
        return;
    }
    BOOL status = WiFiManagerClientGetPower_(man);
    if (status != flag) {
        WiFiManagerClientSetPower_(man, flag);
    }
}

@interface BluetoothManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)enabled;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)connected;
- (BOOL)available;
- (BOOL)powered;
- (BOOL)setPowered:(BOOL)powered;
- (BOOL)connectable;
- (void)setConnectable:(BOOL)connectable;
- (BOOL)isDiscoverable;
- (void)setDiscoverable:(BOOL)discoverable;
@end

static id getBTMan() { // 注意: BluetoothManager必须在RunLoop中使用,初始化必须用主线程
    static BluetoothManager* man = nil;
    if (man == nil) {
        NSBundle* b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/BluetoothManager.framework"];
        [b load];
        man = [objc_getClass("BluetoothManager") sharedInstance];
    }
    return man;
}

BOOL isBlueEnable() {
    BluetoothManager* man = getBTMan();
    return man.enabled;
}
void setBlueEnable(BOOL flag) {
    BluetoothManager* man = getBTMan();
    if (man.enabled != flag) {
        [man setEnabled:flag];
        [man setDiscoverable:flag];
        [man setConnectable:flag];
        [man setPowered:flag];
    }
}

@interface LPMManager : NSObject
- (void)setPowerMode:(int64_t)mode fromSource:(NSString*)src withCompletion:(void(^)())block;
- (BOOL)setPowerMode:(int64_t)mode fromSource:(NSString*)src;
//- (void)setPowerMode:(int64_t)mode withCompletion:(void(^)(int,NSError*))block;   // _CDBatterySaver
// - (BOOL)setPowerMode:(int64_t)mode error:(NSError**)err; // _CDBatterySaver
// setPowerMode:fromSource:withParams:; // _PMLowPowerMode
// setPowerMode:fromSource:withParams:withCompletion:; // _PMLowPowerMode
- (int64_t)getPowerMode;
- (int64_t)setMode:(int64_t)mode;
@end

static id getLPMMan() {
    static LPMManager* saver = nil;
    if (saver == nil) {
        NSBundle* b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/LowPowerMode.framework"];
        [b load];
        Class cls_LPMManager = objc_getClass("_PMLowPowerMode");
        if (cls_LPMManager == nil) {
            NSBundle* b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreDuet.framework"];
            [b load];
            cls_LPMManager = objc_getClass("_CDBatterySaver");
        }
        saver = [cls_LPMManager sharedInstance];
    }
    return saver;
}

BOOL isLPMEnable() {
    LPMManager* saver = getLPMMan();
    return saver.getPowerMode != 0;
}
void setLPMEnable(BOOL flag) {
    LPMManager* saver = getLPMMan();
    BOOL enable = saver.getPowerMode != 0;
    if (enable != flag) {
        [saver setPowerMode:flag?1:0 fromSource:@"Settings"];
    }
}

@interface CLLocationManager
+ (void)setLocationServicesEnabled:(BOOL)flag;
- (BOOL)locationServicesEnabled;
@end

static id getLocMan() {
    static Class man = nil;
    if (man == nil) {
        NSBundle* b = [NSBundle bundleWithPath:@"/System/Library/Frameworks/CoreLocation.framework"];
        [b load];
        man = objc_getClass("CLLocationManager");
    }
    return man;
}

BOOL isLocEnable() {
    id locman = getLocMan();
    return [locman locationServicesEnabled];
}

void setLocEnable(BOOL flag) {
    id locman = getLocMan();
    BOOL enable = [locman locationServicesEnabled];
    if (enable != flag) {
        [locman setLocationServicesEnabled:flag];
    }
}

static float (*BrightnessGet)();
static CFTypeRef (*BrightnessCreate)(CFAllocatorRef allocator);
static void (*BrightnessSet)(float brightness, NSInteger unknown);
extern "C" {
void BKSDisplayBrightnessSetAutoBrightnessEnabled(Boolean enabled);
}

void initBrightness() {
    static bool inited = false;
    if (!inited) {
        BrightnessGet = (__typeof(BrightnessGet))dlsym(RTLD_DEFAULT, "BKSDisplayBrightnessGetCurrent");
        BrightnessCreate = (__typeof(BrightnessCreate))dlsym(RTLD_DEFAULT, "BKSDisplayBrightnessTransactionCreate");
        BrightnessSet = (__typeof(BrightnessSet))dlsym(RTLD_DEFAULT, "BKSDisplayBrightnessSet");
        inited = true;
    }
}

float getBrightness() {
    initBrightness();
    if (!BrightnessGet) {
        return 0.5f;
    }
    return BrightnessGet();
}

void setBrightness(float val) {
    initBrightness();
    if (!BrightnessSet) {
        return;
    }
    if (BrightnessCreate) {
        BrightnessCreate(kCFAllocatorDefault);
    }
    BrightnessSet(val, 1);
}

BOOL isAutoBrightEnable() {
    // This seems not work: CFPreferencesGetAppBooleanValue(CFSTR("BKEnableALS"), CFSTR("com.apple.backboardd"), &val);
    NSDictionary* backboardPref = [NSDictionary dictionaryWithContentsOfFile:@"/private/var/mobile/Library/Preferences/com.apple.backboardd.plist"];
    NSNumber* nsVal = backboardPref[@"BKEnableALS"];
    return nsVal != nil && nsVal.boolValue;
}

void setAutoBrightEnable(BOOL flag) {
    BKSDisplayBrightnessSetAutoBrightnessEnabled(flag);
}

NSDictionary* getThermalData() {
    if (@available(iOS 11.0, *)) {
        int mib[2] = {CTL_HW, HW_MODEL};
        char buf[256];
        size_t sz = sizeof(buf);
        sysctl(mib, 2, buf, &sz, 0, 0);
        NSString* path = [NSString stringWithFormat:@"/System/Library/Watchdog/ThermalMonitor.bundle/%s.bundle/Info.plist", buf];
        if (@available(iOS 13.0, *)) {
            path = [NSString stringWithFormat:@"/System/Library/ThermalMonitor/%s-Info.plist", buf];
        }
        return [NSDictionary dictionaryWithContentsOfFile:path];
    }
    return nil;
}

NSString* getPerfManState() {
    if (@available(iOS 11.0, *)) {
        static int token = 0;
        if (token == 0) {
            notify_register_check("com.apple.thermalmonitor.ageAwareMitigationState", &token);
        }
        if (token != 0) {
            uint64_t state = 0;
            notify_get_state(token, &state);
            if (state == 1) { // PPC_PERFMGMT_ENABLED
                return @"enable";
            } else if (state == 2) { // PPC_PERFMGMT_DISABLED
                return @"disable";
            } else if (state == 3) { // PPC_PERFMGMT_USER_DISABLED
                return @"user_disable";
            } else {
                return @"unknown";
            }
        }
    }
    return @"off";
}

void DisablePerfMan() {
    notify_post("com.apple.thermalmonitor.ageAwareMitigationsDisabled");
}

NSString* getThermalSimulationMode() {
    if (@available(iOS 11.0, *)) {
        switch (NSProcessInfo.processInfo.thermalState) {
            case NSProcessInfoThermalStateNominal:
                return @"nominal";
            case NSProcessInfoThermalStateFair:
                return @"light";
            case NSProcessInfoThermalStateSerious:
                return @"moderate";
            case NSProcessInfoThermalStateCritical:
                return @"heavy";
        }
    }
    return @"off";
}

void setThermalSimulationMode(NSString* mode) {
    if (@available(iOS 11.0, *)) {
        NSUserDefaults* defs = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.cltm"];
        [defs setObject:mode forKey:@"thermalSimulationMode"]; // off/nominal/light/moderate/heavy
        [defs synchronize];
    }
}

static NSString* ppm_mode = nil;
NSString* getPPMSimulationMode() {
    if (@available(iOS 11.0, *)) {
        if (ppm_mode == nil) {
            NSUserDefaults* defs = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.cltm"];
            ppm_mode = [defs objectForKey:@"ppmSimulationMode"];
            if (ppm_mode == nil) {
                ppm_mode = @"off";
            }
        }
        return ppm_mode;
    }
    return @"off";
}

void setPPMSimulationMode(NSString* mode) {
    if (@available(iOS 11.0, *)) {
        NSUserDefaults* defs = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.cltm"];
        [defs setObject:mode forKey:@"ppmSimulationMode"]; // off/nominal/light/moderate/heavy
        [defs synchronize];
        ppm_mode = mode;
    }
}

@interface PowerUISmartChargeClient
- (instancetype)initWithClientName:(NSString*)name;
- (int)isSmartChargingCurrentlyEnabled:(NSError**)err;
- (BOOL)disableSmartCharging:(NSError**)err;
- (BOOL)enableSmartCharging:(NSError**)err;
- (BOOL)temporarilyDisableSmartCharging:(NSError**)err;
@end

static PowerUISmartChargeClient* getSmartChargeClient() {
    static PowerUISmartChargeClient* client = nil;
    if (client == nil) {
        NSBundle* b = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PowerUI.framework"];
        [b load];
        client = [[objc_getClass("PowerUISmartChargeClient") alloc] initWithClientName:@"Settings"];
    }
    return client;
}

int getSmartChargeStatus() {
    PowerUISmartChargeClient* client = getSmartChargeClient();
    NSError* err = nil;
    int status = [client isSmartChargingCurrentlyEnabled:&err];
    NSLog(@"status=%d %@", status, client);
    if (err != nil) {
        NSLog(@"err=%@", err);
        return -1;
    }
    return status; // 0:disable 1:enable 2:fullcharge 3:temporarily_disable
}

BOOL isSmartChargeEnable() {
    return getSmartChargeStatus() > 0;
}

BOOL temporarilyDisableSmartCharge() {
    PowerUISmartChargeClient* client = getSmartChargeClient();
    NSError* err = nil;
    BOOL ok = [client temporarilyDisableSmartCharging:&err];
    if (err != nil) {
        NSLog(@"tempDisable err=%@", err);
        return NO;
    }
    return ok;
}

void setSmartChargeEnable(BOOL flag) {
    PowerUISmartChargeClient* client = getSmartChargeClient();
    int currentStatus = getSmartChargeStatus();
    if (currentStatus < 0) {
        return;
    }
    if (flag) {
        if (currentStatus == 1 || currentStatus == 2) {
            return;
        }
    } else if (currentStatus == 0) {
        return;
    }
    NSError* err = nil;
    if (flag) {
        [client enableSmartCharging:&err];
    } else {
        [client disableSmartCharging:&err];
    }
    if (err != nil) {
        NSLog(@"setSmartChargeEnable(%d) err=%@", flag, err);
    }
}

/* ---------------- App ---------------- */

/**
 * 获取使用 app 数据容器路径的 NSUserDefaults
 *
 * 替代 [NSUserDefaults standardUserDefaults]，避免在 rootless 环境下
 * 写入到 /var/jb/var/mobile/Library/Preferences/ 造成配置文件分散。
 *
 * 使用 suite name 方式，plist 文件会存储在 app 数据容器的 Library/Preferences/ 下。
 */
extern "C" NSUserDefaults* getAppUserDefaults(void) {
    static NSUserDefaults* appDefaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 使用自定义 suite name，确保数据存储在 app 容器而不是系统 Preferences
        // 注意：这会在 app 容器的 Library/Preferences/ 下创建 com.chargelimiter.mod.appdata.plist
        appDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.chargelimiter.mod.appdata"];
        if (appDefaults == nil) {
            NSLog2(@"[CL] WARNING: Failed to create app suite NSUserDefaults, falling back to standard");
            appDefaults = [NSUserDefaults standardUserDefaults];
        }
    });
    return appDefaults;
}

// 旧版本把以下设置写入 NSUserDefaults standardUserDefaults，在 roothide 下该路径
// 无法随 jbroot 持久化，重启/重新越狱后会丢失。这里在首次加载配置时把它们一次性
// 迁移进 CLSettingsStore（com.chargelimiter.mod.plist），迁移后清理旧值避免回写。
// 直接操作传入的 preferences 字典，不调用 setlocalKV/[CLSettingsStore shared]，
// 以免在 store 初始化期间重入造成死锁。返回是否发生了迁移。
static BOOL migrateLegacyUserDefaultsIntoPreferences(NSMutableDictionary* preferences) {
    if (preferences == nil) {
        return NO;
    }
    NSArray<NSString*>* legacyKeys = @[
        @"AppLanguage",
        @"SliderHapticStyle",
        @"StopChargePresetValue",
        @"AppAppearance",
    ];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];  // 读取旧数据

    BOOL migrated = NO;
    for (NSString* key in legacyKeys) {
        id legacyValue = [defaults objectForKey:key];
        if (legacyValue == nil) {
            continue;
        }
        if (preferences[key] == nil) {
            preferences[key] = legacyValue;
            migrated = YES;
        }
        // 不删除 UserDefaults 中的旧值：roothide 下 UserDefaults 持久化不可靠，但保留作为备份，
        // 避免迁移后 apply 写盘失败/残缺时这些设置（语言/震动/深色/停充预设）永久丢失。
        // preferences[key] 已有则不会被覆盖，重复迁移无害。
    }
    if (migrated) {
        NSLog2(@"[CL] migrated legacy NSUserDefaults settings into local KV");
    }
    return migrated;
}

// 配置写入失败通知
NSString* const CLConfigWriteFailedNotification = @"CLConfigWriteFailedNotification";

// 启动迁移期间抑制写失败通知（仅 NSLog；避免 save-failed alert）。
// apply 在决定是否 post 时捕获本标志当前值，避免 async 主线程 block 跑时标志已清。
static BOOL CLSuppressConfigWriteFailedNotification = NO;

@interface CLSettingsStore : NSObject
@property (nonatomic, strong) NSMutableDictionary* preferences;
@property (nonatomic, strong) NSMutableDictionary* cachedChanges;
@property (nonatomic, strong) NSMutableSet<NSString*>* removedKeys;
@property (nonatomic, assign) BOOL isDirty;
+ (instancetype)shared;
- (id)readValueForKey:(NSString*)key defaultValue:(id)defaultValue;
- (void)setValue:(id)value forKey:(NSString*)key;
- (BOOL)apply;
- (void)reloadFromDisk;
@end

static BOOL ensureStoreConfigFileExists(CLSettingsStore* store, NSString** pathOut, NSError** errorOut) {
    if (store == nil) {
        if (pathOut) {
            *pathOut = nil;
        }
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ChargeLimiter"
                                            code:-3
                                        userInfo:@{NSLocalizedDescriptionKey: @"Missing settings store"}];
        }
        return NO;
    }

    @synchronized (store) {
        NSString* existingPath = getConfigWritePathWithLibroot();
        BOOL isDir = NO;
        if (existingPath.length > 0 &&
            [[NSFileManager defaultManager] fileExistsAtPath:existingPath isDirectory:&isDir] &&
            !isDir) {
            if (pathOut) {
                *pathOut = existingPath;
            }
            if (errorOut) {
                *errorOut = nil;
            }
            return YES;
        }

        NSMutableDictionary* mergedPreferences = nil;
        NSString* writtenPath = nil;
        NSError* writeError = nil;
        if (!writeMergedConfigDictionaryToDisk(store.preferences, nil, nil, &writtenPath, &writeError, &mergedPreferences)) {
            if (pathOut) {
                *pathOut = nil;
            }
            if (errorOut) {
                *errorOut = writeError;
            }
            return NO;
        }

        [store.preferences removeAllObjects];
        [store.preferences addEntriesFromDictionary:mergedPreferences];
        if (pathOut) {
            *pathOut = writtenPath;
        }
        if (errorOut) {
            *errorOut = nil;
        }
        return YES;
    }
}

@implementation CLSettingsStore
+ (instancetype)shared {
    static CLSettingsStore* inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [CLSettingsStore new];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _preferences = [NSMutableDictionary new];
        _cachedChanges = [NSMutableDictionary new];
        _removedKeys = [NSMutableSet new];
        _isDirty = NO;
        NSString* loadedPath = nil;
        NSDictionary* fileDict = readConfigDictionaryFromDisk(&loadedPath);
        if ([fileDict isKindOfClass:[NSDictionary class]]) {
            [_preferences addEntriesFromDictionary:fileDict];
            if (loadedPath.length > 0) {
                NSLog2(@"[CL] conf loaded path=%@", loadedPath);
            }
            migrateLoadedConfigToPreferredPathIfNeeded(_preferences, loadedPath);
        }
        if (migrateLegacyUserDefaultsIntoPreferences(_preferences)) {
            // 从 NSUserDefaults 迁移到配置文件后立即 apply 写入磁盘
            // 这样确保首次安装或配置文件丢失后，用户设置的配置能够持久化
            [_cachedChanges addEntriesFromDictionary:_preferences];
            _isDirty = YES;
            [self apply];
        }
    }
    return self;
}

- (id)readValueForKey:(NSString*)key defaultValue:(id)defaultValue {
    if (key.length == 0) {
        return defaultValue;
    }
    @synchronized (self) {
        id val = self.preferences[key];
        return val ?: defaultValue;
    }
}

- (BOOL)readBoolForKey:(NSString*)key defaultValue:(BOOL)defaultValue {
    id val = [self readValueForKey:key defaultValue:nil];
    if ([val isKindOfClass:[NSNumber class]]) {
        return [val boolValue];
    }
    if ([val isKindOfClass:[NSString class]]) {
        return [val boolValue];
    }
    return defaultValue;
}

- (int)readIntForKey:(NSString*)key defaultValue:(int)defaultValue {
    id val = [self readValueForKey:key defaultValue:nil];
    if ([val isKindOfClass:[NSNumber class]]) {
        return [val intValue];
    }
    if ([val isKindOfClass:[NSString class]]) {
        return [val intValue];
    }
    return defaultValue;
}

- (float)readFloatForKey:(NSString*)key defaultValue:(float)defaultValue {
    id val = [self readValueForKey:key defaultValue:nil];
    if ([val isKindOfClass:[NSNumber class]]) {
        return [val floatValue];
    }
    if ([val isKindOfClass:[NSString class]]) {
        return [val floatValue];
    }
    return defaultValue;
}

- (double)readDoubleForKey:(NSString*)key defaultValue:(double)defaultValue {
    id val = [self readValueForKey:key defaultValue:nil];
    if ([val isKindOfClass:[NSNumber class]]) {
        return [val doubleValue];
    }
    if ([val isKindOfClass:[NSString class]]) {
        return [val doubleValue];
    }
    return defaultValue;
}

- (NSString*)readStringForKey:(NSString*)key defaultValue:(NSString*)defaultValue {
    id val = [self readValueForKey:key defaultValue:nil];
    if ([val isKindOfClass:[NSString class]]) {
        return (NSString*)val;
    }
    if ([val isKindOfClass:[NSNumber class]]) {
        return [(NSNumber*)val stringValue];
    }
    return defaultValue;
}

- (NSArray*)readArrayForKey:(NSString*)key defaultValue:(NSArray*)defaultValue {
    id val = [self readValueForKey:key defaultValue:nil];
    if ([val isKindOfClass:[NSArray class]]) {
        return (NSArray*)val;
    }
    return defaultValue;
}

- (NSDictionary*)readDictForKey:(NSString*)key defaultValue:(NSDictionary*)defaultValue {
    id val = [self readValueForKey:key defaultValue:nil];
    if ([val isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary*)val;
    }
    return defaultValue;
}

- (void)setValue:(id)value forKey:(NSString*)key {
    if (key.length == 0) {
        return;
    }
    @synchronized (self) {
        if (value) {
            self.cachedChanges[key] = value;
            self.preferences[key] = value;
            [self.removedKeys removeObject:key];
        } else {
            [self.preferences removeObjectForKey:key];
            [self.cachedChanges removeObjectForKey:key];
            [self.removedKeys addObject:key];
        }
        self.isDirty = YES;
    }
}

- (BOOL)apply {
    @synchronized (self) {
        if (!self.isDirty) {
            return YES;
        }
        NSMutableDictionary* mergedPreferences = nil;
        NSError* writeError = nil;
        NSString* writtenPath = nil;
        if (!writeMergedConfigDictionaryToDisk(self.preferences,
                                               self.cachedChanges,
                                               self.removedKeys,
                                               &writtenPath,
                                               &writeError,
                                               &mergedPreferences)) {
            NSString* attemptedPath = getConfigWritePathWithLibroot() ?: @"";
            NSArray<NSString*>* attemptedPaths = attemptedPath.length > 0 ? @[attemptedPath] : @[];
            NSLog2(@"[CL] conf write failed: attemptedPath=%@ err=%@", attemptedPath, writeError);
            // 捕获当前 suppress 值：async block 可能在迁移清标志之后才跑。
            BOOL suppressNotification = CLSuppressConfigWriteFailedNotification;
            if (!suppressNotification) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSMutableDictionary* userInfo = [NSMutableDictionary dictionary];
                    if (writeError) {
                        userInfo[@"error"] = writeError;
                    }
                    if (attemptedPaths.count > 0) {
                        userInfo[@"attemptedPaths"] = attemptedPaths;
                    } else {
                        userInfo[@"reason"] = @"No valid write paths available";
                    }
                    userInfo[@"jbType"] = @(getJBType());

                    [[NSNotificationCenter defaultCenter] postNotificationName:CLConfigWriteFailedNotification
                                                                        object:nil
                                                                      userInfo:userInfo];
                });
            }
            // setValue 已先改 preferences；写盘失败必须回滚，保证 setlocalKVChecked
            // 返回 NO 时内存与磁盘一致（UI 读到的不是未落盘脏值）。
            // 失败路径允许空字典替换（与常规 reloadFromDisk 保护不同）。
            NSString* rollbackPath = nil;
            NSDictionary* diskDict = readConfigDictionaryFromDisk(&rollbackPath);
            [self.preferences removeAllObjects];
            if ([diskDict isKindOfClass:[NSDictionary class]]) {
                [self.preferences addEntriesFromDictionary:diskDict];
                if (rollbackPath.length > 0) {
                    NSLog2(@"[CL] conf rolled back from disk path=%@", rollbackPath);
                }
            } else {
                NSLog2(@"[CL] conf rollback: disk unreadable, cleared dirty in-memory state");
            }
            [self.cachedChanges removeAllObjects];
            [self.removedKeys removeAllObjects];
            self.isDirty = NO;
            return NO;
        }
        [self.preferences removeAllObjects];
        [self.preferences addEntriesFromDictionary:mergedPreferences];
        NSLog2(@"[CL] conf written path=%@", writtenPath ?: @"");
        [self.cachedChanges removeAllObjects];
        [self.removedKeys removeAllObjects];
        self.isDirty = NO;
        return YES;
    }
}

- (void)reloadFromDisk {
    @synchronized (self) {
        NSString* loadedPath = nil;
        NSDictionary* fileDict = readConfigDictionaryFromDisk(&loadedPath);
        // 仅在读到非空配置时才替换内存副本；读不到时保留旧 preferences，
        // 避免 daemon reload 读不到（g_confPath 漂移/未就绪）后用空副本 apply 覆盖盘上配置导致清空。
        if ([fileDict isKindOfClass:[NSDictionary class]] && fileDict.count > 0) {
            [self.preferences removeAllObjects];
            [self.preferences addEntriesFromDictionary:fileDict];
            if (loadedPath.length > 0) {
                NSLog2(@"[CL] conf reloaded path=%@", loadedPath);
            }
            migrateLoadedConfigToPreferredPathIfNeeded(self.preferences, loadedPath);
        } else {
            NSLog2(@"[CL] conf reload skipped (unreadable/empty), keep in-memory preferences");
        }
        [self.cachedChanges removeAllObjects];
        [self.removedKeys removeAllObjects];
        self.isDirty = NO;
    }
}
@end

#if TARGET_OS_SIMULATOR || defined(CL_TEST_MODE)
static void CLAssignSelfTestStoragePaths(NSString *rootPath) {
    g_appDocumentsPath = [rootPath copy];
    g_runtimeDataRootPath = [rootPath copy];
    g_logPath = [[rootPath stringByAppendingPathComponent:@LOG_FILENAME] copy];
    g_confPath = [[rootPath stringByAppendingPathComponent:@CONFIG_PLIST_FILENAME] copy];
    g_dbPath = [[rootPath stringByAppendingPathComponent:@DB_FILENAME] copy];
}

extern "C" BOOL CLRunLocalizationPersistenceSelfTest(NSString **failureReason) {
    NSArray<NSString *> *legacyKeys = @[
        @"AppLanguage",
        @"SliderHapticStyle",
        @"StopChargePresetValue",
        @"AppAppearance",
    ];
    NSUserDefaults *legacyDefaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary<NSString *, id> *legacyBackup = [NSMutableDictionary dictionary];
    for (NSString *key in legacyKeys) {
        id value = [legacyDefaults objectForKey:key];
        if (value != nil) {
            legacyBackup[key] = value;
            [legacyDefaults removeObjectForKey:key];
        }
    }
    [legacyDefaults synchronize];

    NSString *originalAppDocumentsPath = g_appDocumentsPath;
    NSString *originalRuntimeDataRootPath = g_runtimeDataRootPath;
    NSString *originalLogPath = g_logPath;
    NSString *originalConfPath = g_confPath;
    NSString *originalDbPath = g_dbPath;
    NSString *originalAppDocumentsPathOverride = g_appDocumentsPathOverride;

    NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"chargelimiter-selftest-%@", NSUUID.UUID.UUIDString]];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:tempRoot withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        if (failureReason) {
            *failureReason = [NSString stringWithFormat:@"failed to create temp dir: %@", dirError];
        }
        return NO;
    }

    BOOL passed = NO;
    @try {
        g_appDocumentsPathOverride = nil;
        CLAssignSelfTestStoragePaths(tempRoot);

        CLSettingsStore *appStore = [CLSettingsStore new];
        CLSettingsStore *daemonStore = [CLSettingsStore new];

        [appStore setValue:@(CLAppLanguageEnglish) forKey:@"AppLanguage"];
        [appStore apply];

        NSDictionary *afterAppWrite = [NSDictionary dictionaryWithContentsOfFile:g_confPath];
        if (![afterAppWrite[@"AppLanguage"] isEqual:@(CLAppLanguageEnglish)]) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"app write missing AppLanguage: %@", afterAppWrite ?: @{}];
            }
            return NO;
        }

        [daemonStore setValue:@"en" forKey:@"lang"];
        [daemonStore apply];

        NSDictionary *afterDaemonWrite = [NSDictionary dictionaryWithContentsOfFile:g_confPath];
        if (![afterDaemonWrite[@"lang"] isEqual:@"en"]) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"daemon write missing lang: %@", afterDaemonWrite ?: @{}];
            }
            return NO;
        }
        if (![afterDaemonWrite[@"AppLanguage"] isEqual:@(CLAppLanguageEnglish)]) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"daemon write overwrote AppLanguage: %@", afterDaemonWrite ?: @{}];
            }
            return NO;
        }

        CLSettingsStore *fileBootstrapStore = [CLSettingsStore new];
        [fileBootstrapStore setValue:@(CLAppLanguageChineseSimplified) forKey:@"AppLanguage"];
        [fileBootstrapStore apply];
        [fm removeItemAtPath:g_confPath error:nil];

        NSError *ensureError = nil;
        NSString *ensuredPath = nil;
        if (!ensureStoreConfigFileExists(fileBootstrapStore, &ensuredPath, &ensureError)) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"ensure config bootstrap failed: %@", ensureError];
            }
            return NO;
        }

        NSDictionary *afterBootstrapWrite = [NSDictionary dictionaryWithContentsOfFile:g_confPath];
        if (![afterBootstrapWrite[@"AppLanguage"] isEqual:@(CLAppLanguageChineseSimplified)]) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"ensure config bootstrap lost AppLanguage: %@", afterBootstrapWrite ?: @{}];
            }
            return NO;
        }

        NSDictionary *seedPrimary = @{@"lang": @"en"};
        NSError *seedSerializeError = nil;
        NSData *seedPrimaryData = [NSPropertyListSerialization dataWithPropertyList:seedPrimary
                                                                             format:NSPropertyListBinaryFormat_v1_0
                                                                            options:0
                                                                              error:&seedSerializeError];
        if (!seedPrimaryData) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"failed to serialize merge seed: %@", seedSerializeError];
            }
            return NO;
        }
        NSError *seedWriteError = nil;
        NSString *seedWritePath = nil;
        if (!writeConfigDataToDiskWithLibroot(seedPrimaryData, &seedWritePath, &seedWriteError)) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"failed to write merge seed: %@", seedWriteError];
            }
            return NO;
        }

        NSError *mergeError = nil;
        NSString *mergePath = nil;
        NSDictionary *migrationBackfill = @{@"AppLanguage": @(CLAppLanguageEnglish)};
        if (!writeMergedConfigDictionaryToDisk(migrationBackfill, migrationBackfill, nil, &mergePath, &mergeError, nil)) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"merged write failed: %@", mergeError];
            }
            return NO;
        }

        NSDictionary *afterMergedWrite = [NSDictionary dictionaryWithContentsOfFile:g_confPath];
        if (![afterMergedWrite[@"lang"] isEqual:@"en"]) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"merged write lost existing lang: %@", afterMergedWrite ?: @{}];
            }
            return NO;
        }
        if (![afterMergedWrite[@"AppLanguage"] isEqual:@(CLAppLanguageEnglish)]) {
            if (failureReason) {
                *failureReason = [NSString stringWithFormat:@"merged write missing AppLanguage: %@", afterMergedWrite ?: @{}];
            }
            return NO;
        }

        passed = YES;
        return YES;
    } @finally {
        g_appDocumentsPathOverride = originalAppDocumentsPathOverride;
        g_appDocumentsPath = originalAppDocumentsPath;
        g_runtimeDataRootPath = originalRuntimeDataRootPath;
        g_logPath = originalLogPath;
        g_confPath = originalConfPath;
        g_dbPath = originalDbPath;

        [fm removeItemAtPath:tempRoot error:nil];

        for (NSString *key in legacyKeys) {
            [legacyDefaults removeObjectForKey:key];
        }
        [legacyBackup enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            [legacyDefaults setObject:value forKey:key];
        }];
        [legacyDefaults synchronize];
    }

    return passed;
}
#endif

id getlocalKV(NSString* key) {
    return [[CLSettingsStore shared] readValueForKey:key defaultValue:nil];
}

void setlocalKV(NSString* key, id val) {
    (void)setlocalKVChecked(key, val);
}

BOOL setlocalKVChecked(NSString* key, id val) {
    CLSettingsStore* store = [CLSettingsStore shared];
    [store setValue:val forKey:key];
    return [store apply];
}

// 把 App 四键从 appdata suite / standardUserDefaults 迁入共享 plist。
// 权威源 = 共享 store；旧 suite 仅作迁移源。成功后写标记并 best-effort 清理 suite 四键。
// 返回 NO 仅当「需要写入共享却写失败」；无数据可迁也返回 YES。
// 写失败只打日志：期间设置 CLSuppressConfigWriteFailedNotification，避免 save-failed UI。
BOOL CLMigrateAppSettingsToSharedStoreIfNeeded(void) {
    // 必须在任何 getlocalKV / CLSettingsStore 访问之前置位：
    // getlocalKV 会构造 shared store，init 里 legacy UserDefaults 迁移可能 apply，
    // 而 ui 已在 migrate 前注册 save-failed observer。
    CLSuppressConfigWriteFailedNotification = YES;
    @try {
        static NSString* const kMarkerKey = @"CLAppSettingsMigratedToShared";
        static NSArray<NSString*>* keys = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            keys = @[
                @"AppLanguage",
                @"AppAppearance",
                @"SliderHapticStyle",
                @"StopChargePresetValue",
            ];
        });

        id marker = getlocalKV(kMarkerKey);
        if ([marker isKindOfClass:[NSNumber class]] && [marker boolValue]) {
            return YES;
        }

        // 直接读旧 appdata suite（不再经过独立 App store）。
        NSUserDefaults* suite = [[NSUserDefaults alloc] initWithSuiteName:@"com.chargelimiter.mod.appdata"];
        if (suite == nil) {
            suite = getAppUserDefaults();
        }
        NSUserDefaults* stdDefaults = [NSUserDefaults standardUserDefaults];

        BOOL writeFailed = NO;
        for (NSString* key in keys) {
            id sharedVal = getlocalKV(key);
            if ([sharedVal isKindOfClass:[NSNumber class]]) {
                // 共享已有合法值，跳过该键
                continue;
            }

            NSInteger val = 0;

            // Priority 1: appdata suite
            id suiteVal = [suite objectForKey:key];
            if ([suiteVal isKindOfClass:[NSNumber class]]) {
                val = [suiteVal integerValue];
            } else {
                // Priority 2: standardUserDefaults；再否则 default 0
                id stdVal = [stdDefaults objectForKey:key];
                if ([stdVal isKindOfClass:[NSNumber class]]) {
                    val = [stdVal integerValue];
                }
            }

            // 共享缺失则写入（含 default 0），保证四键在共享侧补齐
            if (!setlocalKVChecked(key, @(val))) {
                writeFailed = YES;
                NSLog2(@"[CL] migrate app setting to shared failed key=%@ val=%ld", key, (long)val);
            }
        }

        if (writeFailed) {
            // 不写标记，下次启动可重试
            return NO;
        }

        // 成功路径：写标记（空迁移也写，避免每启重复扫）
        if (!setlocalKVChecked(kMarkerKey, @1)) {
            NSLog2(@"[CL] migrate marker write failed key=%@", kMarkerKey);
            return NO;
        }

        // best-effort 清理旧 suite 四键
        for (NSString* key in keys) {
            [suite removeObjectForKey:key];
        }
        [suite synchronize];

        NSLog2(@"[CL] migrated app settings into shared plist (marker set)");
        return YES;
    } @finally {
        CLSuppressConfigWriteFailedNotification = NO;
    }
}

extern "C" void setlocalKV_C(NSString* key, id val) {
    setlocalKV(key, val);
}

extern "C" id getlocalKV_C(NSString* key) {
    return getlocalKV(key);
}

void reloadLocalKVFromDisk(void) {
    [[CLSettingsStore shared] reloadFromDisk];
}

extern "C" void reloadLocalKVFromDisk_C(void) {
    reloadLocalKVFromDisk();
}

BOOL hasUnsavedConfigChanges(void) {
    CLSettingsStore* store = [CLSettingsStore shared];
    @synchronized (store) {
        return store.isDirty;
    }
}

NSDictionary* getAllKV() {
    CLSettingsStore* store = [CLSettingsStore shared];
    @synchronized (store) {
        return [store.preferences copy];
    }
}

extern "C" NSDictionary* getAllKV_C(void) {
    return getAllKV();
}

extern "C" BOOL ensureLocalConfigFileExists_C(NSString** pathOut, NSError** errorOut) {
    return ensureStoreConfigFileExists([CLSettingsStore shared], pathOut, errorOut);
}

extern "C" BOOL localPortOpen_C(int port) {
    return localPortOpen(port);
}
/* ---------------- App ---------------- */

BOOL getLocalBool(NSString* key, BOOL defaultValue) {
    return [[CLSettingsStore shared] readBoolForKey:key defaultValue:defaultValue];
}

int getLocalInt(NSString* key, int defaultValue) {
    return [[CLSettingsStore shared] readIntForKey:key defaultValue:defaultValue];
}

float getLocalFloat(NSString* key, float defaultValue) {
    return [[CLSettingsStore shared] readFloatForKey:key defaultValue:defaultValue];
}

double getLocalDouble(NSString* key, double defaultValue) {
    return [[CLSettingsStore shared] readDoubleForKey:key defaultValue:defaultValue];
}

NSString* getLocalString(NSString* key, NSString* defaultValue) {
    return [[CLSettingsStore shared] readStringForKey:key defaultValue:defaultValue];
}

NSArray* getLocalArray(NSString* key, NSArray* defaultValue) {
    return [[CLSettingsStore shared] readArrayForKey:key defaultValue:defaultValue];
}

NSDictionary* getLocalDict(NSString* key, NSDictionary* defaultValue) {
    return [[CLSettingsStore shared] readDictForKey:key defaultValue:defaultValue];
}

void setLocalBool(NSString* key, BOOL value) {
    setlocalKV(key, @(value));
}

void setLocalInt(NSString* key, int value) {
    setlocalKV(key, @(value));
}

void setLocalFloat(NSString* key, float value) {
    setlocalKV(key, @(value));
}

void setLocalDouble(NSString* key, double value) {
    setlocalKV(key, @(value));
}

void setLocalString(NSString* key, NSString* value) {
    setlocalKV(key, value);
}

void setLocalArray(NSString* key, NSArray* value) {
    setlocalKV(key, value);
}

void setLocalDict(NSString* key, NSDictionary* value) {
    setlocalKV(key, value);
}

#pragma mark - (moved to CLLocalization.m)
