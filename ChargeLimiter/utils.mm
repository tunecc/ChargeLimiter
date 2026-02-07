#include "utils.h"
#import "CLLocalization.h"
#include <limits.h>
#include <stdlib.h>
#include <sys/utsname.h>
#include <sys/sysctl.h>
#include <notify.h>
#import <objc/message.h>

static NSString* g_appDocumentsPath = nil;
static NSString* g_logPath = nil;
static NSString* g_confPath = nil;
static NSString* g_dbPath = nil;
static NSString* const kContainerCacheFileName = @"com.chargelimiter.mod.containerpath";
typedef const char* (*jbroot_fn_t)(const char* path);

static BOOL isValidAppDocumentsPath(NSString* path) {
    if (path.length == 0) {
        return NO;
    }
    if ([path hasPrefix:@"/var/mobile/Containers/Data/Application/"]) {
        return YES;
    }
    if ([path hasPrefix:@"/private/var/mobile/Containers/Data/Application/"]) {
        return YES;
    }
    if ([path hasPrefix:@"/var/jb/var/mobile/Containers/Data/Application/"]) {
        return YES;
    }
    if ([path hasPrefix:@"/private/var/jb/var/mobile/Containers/Data/Application/"]) {
        return YES;
    }
    if ([path hasPrefix:@"/var/jb/private/var/mobile/Containers/Data/Application/"]) {
        return YES;
    }
    return NO;
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

static NSURL* resolveMCMContainerURL(NSString* bid) {
    if (bid.length == 0) {
        return nil;
    }
    Class dataCls = objc_getClass("MCMAppDataContainer");
    if (dataCls) {
        SEL selCreate = @selector(containerWithIdentifier:createIfNecessary:error:);
        if ([dataCls respondsToSelector:selCreate]) {
            NSError* err = nil;
            id container = ((id(*)(id, SEL, NSString*, BOOL, NSError**))objc_msgSend)(dataCls, selCreate, bid, YES, &err);
            NSURL* url = getContainerURLFromMCM(container);
            if (url.path.length > 0) {
                return url;
            }
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
    }
    return nil;
}

static NSString* resolveDocumentsByScanning(NSString* bid) {
    if (bid.length == 0) {
        return nil;
    }
    NSArray<NSString*>* bases = @[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application",
        @"/var/jb/var/mobile/Containers/Data/Application",
        @"/private/var/jb/var/mobile/Containers/Data/Application",
        @"/var/jb/private/var/mobile/Containers/Data/Application"
    ];
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
                return [containerPath stringByAppendingPathComponent:@"Documents"];
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

static NSString* resolveAppDocumentsPath() {
    NSString* docPath = nil;
    NSString* bid = resolveAppBundleIdentifier();
    if (bid.length > 0) {
        Class proxyCls = objc_getClass("LSApplicationProxy");
        if (proxyCls && [proxyCls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id proxy = [proxyCls performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
#pragma clang diagnostic pop
            if (proxy && [proxy respondsToSelector:@selector(dataContainerURL)]) {
                NSURL* url = ((LSApplicationProxy*)proxy).dataContainerURL;
                if (url.path.length > 0) {
                    docPath = [url.path stringByAppendingPathComponent:@"Documents"];
                }
            }
        }
    }
    if (isValidAppDocumentsPath(docPath)) {
        return docPath;
    }
    NSURL* mcmURL = resolveMCMContainerURL(bid);
    if (mcmURL.path.length > 0) {
        docPath = [mcmURL.path stringByAppendingPathComponent:@"Documents"];
        if (isValidAppDocumentsPath(docPath)) {
            [[NSFileManager defaultManager] createDirectoryAtPath:docPath withIntermediateDirectories:YES attributes:nil error:nil];
            return docPath;
        }
    }
    NSString* scanPath = resolveDocumentsByScanning(bid);
    if (isValidAppDocumentsPath(scanPath)) {
        return scanPath;
    }
    NSString* fallback = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (isValidAppDocumentsPath(fallback)) {
        return fallback;
    }
    return nil;
}

static NSString* containerRootFromDocuments(NSString* documentsPath) {
    if (documentsPath.length == 0) {
        return nil;
    }
    NSString* last = documentsPath.lastPathComponent;
    if ([last isEqualToString:@"Documents"]) {
        return [documentsPath stringByDeletingLastPathComponent];
    }
    return nil;
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

static NSString* resolveRoothideCachePathByAPI() {
    if (getJBType() != JBTYPE_ROOTHIDE) {
        return nil;
    }

    static jbroot_fn_t jbrootPtr = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        jbrootPtr = (jbroot_fn_t)dlsym(RTLD_DEFAULT, "jbroot");
        if (jbrootPtr) {
            return;
        }
        const char* candidates[] = {
            "/usr/lib/libroothide.dylib",
            "/var/jb/usr/lib/libroothide.dylib",
        };
        for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
            void* h = dlopen(candidates[i], RTLD_LAZY);
            if (!h) {
                continue;
            }
            jbrootPtr = (jbroot_fn_t)dlsym(h, "jbroot");
            if (jbrootPtr) {
                break;
            }
        }
    });

    if (!jbrootPtr) {
        return nil;
    }

    NSString* virtualPath = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:kContainerCacheFileName];
    const char* rooted = jbrootPtr(virtualPath.UTF8String);
    if (!rooted || rooted[0] != '/') {
        return nil;
    }
    return @(rooted);
}

static NSArray<NSString*>* availableContainerCachePaths() {
    NSMutableArray<NSString*>* paths = [NSMutableArray new];
    int jbType = getJBType();

    // roothide preferred: use official jbroot() API first.
    if (jbType == JBTYPE_ROOTHIDE) {
        NSString* roothidePath = resolveRoothideCachePathByAPI();
        if (roothidePath.length > 0) {
            [paths addObject:roothidePath];
        } else {
            // fallback: infer jbroot from executable path.
            NSString* jbroot = resolveJbRootFromSelfExe();
            if (jbroot.length > 0) {
                NSString* fallbackRoothidePath = [[jbroot stringByAppendingPathComponent:@"var/mobile/Library/Preferences"] stringByAppendingPathComponent:kContainerCacheFileName];
                if (fallbackRoothidePath.length > 0) {
                    [paths addObject:fallbackRoothidePath];
                }
            }
        }
        // Do not fallback to /var/jb path for roothide. If both jbroot methods fail,
        // keep empty and let caller warn user.
    } else if (jbType == JBTYPE_ROOTLESS) {
        // No hardcoded /var/jb write path.
        // Use mobile preferences path as stable write location.
        NSString* rootfulPath = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:kContainerCacheFileName];
        if (rootfulPath.length > 0) {
            [paths addObject:rootfulPath];
        }
    } else {
        // Rootful/default fallback path.
        NSString* rootfulPath = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:kContainerCacheFileName];
        if (rootfulPath.length > 0) {
            [paths addObject:rootfulPath];
        }
    }

    // Dedupe while preserving order.
    NSMutableArray<NSString*>* dedup = [NSMutableArray new];
    NSMutableSet<NSString*>* seen = [NSMutableSet new];
    for (NSString* p in paths) {
        if (p.length == 0 || [seen containsObject:p]) {
            continue;
        }
        [seen addObject:p];
        [dedup addObject:p];
    }

    return dedup;
}

static void updateContainerPathCache(NSString* documentsPath) {
    NSString* containerRoot = containerRootFromDocuments(documentsPath);
    if (containerRoot.length == 0) {
        return;
    }
    NSArray<NSString*>* cachePaths = availableContainerCachePaths();
    NSString* cacheContent = [NSString stringWithFormat:
                              @"# ChargeLimiter container path cache\n"
                              "# 用途(中文): 记录当前应用数据容器根目录，供卸载脚本快速删除数据目录。\n"
                              "# Purpose(English): Stores current app data container root path for fast uninstall cleanup.\n"
                              "CONTAINER_PATH=%@\n", containerRoot];
    BOOL wroteAny = NO;
    for (NSString* cachePath in cachePaths) {
        NSError* mkdirError = nil;
        NSString* parent = [cachePath stringByDeletingLastPathComponent];
        if (parent.length > 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&mkdirError];
        }

        NSError* writeError = nil;
        BOOL ok = [cacheContent writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (ok) {
            wroteAny = YES;
            NSLog2(@"[CL] container cache written: %@", cachePath);
        } else {
            NSLog2(@"[CL] container cache write failed: %@ mkdirErr=%@ writeErr=%@", cachePath, mkdirError, writeError);
        }
    }

    if (!wroteAny) {
        NSLog2(@"[CL] container cache not written. jbType=%d, docs=%@, candidates=%@", getJBType(), documentsPath, cachePaths);
    }
}

static void ensureAppPaths() {
    static NSObject* lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    @synchronized(lock) {
        if (g_appDocumentsPath.length > 0 && g_logPath.length > 0 && g_confPath.length > 0 && g_dbPath.length > 0) {
            return;
        }
        NSString* appDoc = resolveAppDocumentsPath();
        // Unified behavior for TrollStore + jailbreak:
        // all runtime files live directly under the app container Documents dir.
        NSString* targetDir = appDoc;
        if (targetDir.length == 0) {
            NSLog(@"[CL] Failed to resolve config dir.");
            return;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:nil];
        g_appDocumentsPath = targetDir;
        g_logPath = [targetDir stringByAppendingPathComponent:@LOG_FILENAME];
        g_confPath = [targetDir stringByAppendingPathComponent:@CONF_FILENAME];
        g_dbPath = [targetDir stringByAppendingPathComponent:@DB_FILENAME];
        updateContainerPathCache(targetDir);
    }
}

NSString* getAppDocumentsPath() {
    ensureAppPaths();
    return g_appDocumentsPath;
}

extern "C" NSString* getAppDocumentsPath_C(void) {
    return getAppDocumentsPath();
}

NSString* getLogPath() {
    ensureAppPaths();
    return g_logPath;
}

NSString* getConfPath() {
    ensureAppPaths();
    return g_confPath;
}

extern "C" NSString* getConfPath_C(void) {
    return getConfPath();
}

NSString* getDbPath() {
    ensureAppPaths();
    return g_dbPath;
}

NSString* getConfDirPath() {
    ensureAppPaths();
    if (g_confPath.length == 0) {
        return nil;
    }
    return [g_confPath stringByDeletingLastPathComponent];
}

extern "C" NSString* getConfDirPath_C(void) {
    return getConfDirPath();
}

static NSArray<NSString*>* legacyConfigFileNames() {
    return @[@CONF_FILENAME, @DB_FILENAME, @LOG_FILENAME];
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

static NSArray<NSString*>* legacyConfigCandidateDirs() {
    NSMutableArray<NSString*>* dirs = [NSMutableArray new];

    // Version 1 legacy path.
    [dirs addObject:@"/var/root"];

    // Version 2 legacy path (jailbreak prefs directory family).
    [dirs addObject:@"/var/mobile/Library/Preferences"];
    [dirs addObject:@"/var/jb/var/mobile/Library/Preferences"];

    NSString* roothideCachePath = resolveRoothideCachePathByAPI();
    if (roothideCachePath.length > 0) {
        [dirs addObject:[roothideCachePath stringByDeletingLastPathComponent]];
    }

    NSString* inferredJbRoot = resolveJbRootFromSelfExe();
    if (inferredJbRoot.length > 0) {
        [dirs addObject:[inferredJbRoot stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]];
    }

    NSString* currentDir = getConfDirPath();
    NSMutableArray<NSString*>* dedup = [NSMutableArray new];
    NSMutableSet<NSString*>* seen = [NSMutableSet new];
    for (NSString* dir in dirs) {
        if (dir.length == 0 || [seen containsObject:dir]) {
            continue;
        }
        if (currentDir.length > 0 && [dir isEqualToString:currentDir]) {
            continue;
        }
        [seen addObject:dir];
        [dedup addObject:dir];
    }
    return dedup;
}

static NSInteger legacyRuntimeFileCountInDir(NSString* dir) {
    if (dir.length == 0) {
        return 0;
    }
    NSFileManager* fm = [NSFileManager defaultManager];
    NSInteger count = 0;
    for (NSString* file in legacyConfigFileNames()) {
        NSString* path = [dir stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
            count++;
        }
    }
    return count;
}

static BOOL hasCompleteLegacyRuntimeFilesInDir(NSString* dir) {
    return legacyRuntimeFileCountInDir(dir) == (NSInteger)legacyConfigFileNames().count;
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
    NSFileManager* fm = [NSFileManager defaultManager];
    NSInteger fullCount = (NSInteger)legacyConfigFileNames().count;
    for (NSString* dir in legacyConfigCandidateDirs()) {
        NSInteger count = legacyRuntimeFileCountInDir(dir);
        if (count <= 0 || count >= fullCount) {
            continue;
        }
        for (NSString* file in legacyConfigFileNames()) {
            NSString* path = [dir stringByAppendingPathComponent:file];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
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
    NSInteger removed = 0;
    NSInteger failed = 0;
    for (NSString* path in files) {
        if (removeLegacyFilePreferRoot(path)) {
            removed++;
        } else {
            failed++;
            [errors addObject:[NSString stringWithFormat:@"%@ remove failed", path]];
        }
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
    for (NSString* file in legacyConfigFileNames()) {
        NSString* src = [dir stringByAppendingPathComponent:file];
        NSDate* d = fileModifyDate(src);
        if ([d compare:latest] == NSOrderedDescending) {
            latest = d;
        }
    }
    return latest;
}

static NSString* latestLegacySourceForFile(NSString* file, NSString* legacyDir) {
    if (file.length == 0 || legacyDir.length == 0) {
        return nil;
    }
    return [legacyDir stringByAppendingPathComponent:file];
}

static NSString* latestLegacyDir(NSArray<NSString*>* legacyDirs) {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* latestDir = nil;
    NSDate* latestDate = [NSDate distantPast];
    for (NSString* dir in legacyDirs) {
        BOOL hasAll = YES;
        for (NSString* file in legacyConfigFileNames()) {
            NSString* p = [dir stringByAppendingPathComponent:file];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:p isDirectory:&isDir] || isDir) {
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
    ensureAppPaths();
    NSString* targetDir = getConfDirPath();
    if (targetDir.length == 0) {
        return @{
            @"migrated": @0,
            @"replaced": @0,
            @"missing": @0,
            @"failed": @1,
            @"errors": @[@"Target documents path is unavailable."]
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

    for (NSString* file in legacyConfigFileNames()) {
        NSString* dst = [targetDir stringByAppendingPathComponent:file];
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
            for (NSString* dir in legacyDirs) {
                NSString* src = [dir stringByAppendingPathComponent:file];
                BOOL srcIsDir = NO;
                if (![fm fileExistsAtPath:src isDirectory:&srcIsDir] || srcIsDir) {
                    continue;
                }
                if (!removeLegacyFilePreferRoot(src)) {
                    failed++;
                    [errors addObject:[NSString stringWithFormat:@"%@ remove failed", src]];
                }
            }
            if (dstExists) {
                replaced++;
            } else {
                migrated++;
            }
            continue;
        }

        failed++;
        [errors addObject:[NSString stringWithFormat:@"%@ <- %@ (%@)", dst, chosenSrc, copyError.localizedDescription ?: @"copy failed"]];
    }

    NSLog2(@"[CL] legacy migration result: migrated=%ld replaced=%ld missing=%ld failed=%ld legacyDirs=%@ target=%@",
           (long)migrated, (long)replaced, (long)missing, (long)failed, legacyDirs, targetDir);

    return @{
        @"migrated": @(migrated),
        @"replaced": @(replaced),
        @"missing": @(missing),
        @"failed": @(failed),
        @"errors": errors,
        @"legacyDirs": legacyDirs,
        @"targetDir": targetDir
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

void NSFileLog(NSString* fmt, ...) {
    va_list va;
    va_start(va, fmt);
    NSDateFormatter* formatter = [NSDateFormatter new];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString* dateStr = [formatter stringFromDate:NSDate.date];
    NSString* content = [[NSString alloc] initWithFormat:fmt arguments:va];
    content = [NSString stringWithFormat:@"%@ %@\n", dateStr, content];
    NSString* logPath = getLogPath();
    if (logPath.length == 0) {
        return;
    }
    NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (handle == nil) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [handle seekToEndOfFile];
    [handle writeData:[content dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
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
            NSFileLog(@"floatwnd unexpected frontmost bid %@", allFrontMostBid);
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

BOOL isSmartChargeEnable() {
    PowerUISmartChargeClient* client = getSmartChargeClient();
    NSError* err = nil;
    int status = [client isSmartChargingCurrentlyEnabled:&err];
    NSLog(@"status=%d %@", status, client);
    if (err != nil) {
        NSLog(@"err=%@", err);
        return NO;
    }
    return status != 0; // 0:disable 1:enable 2:fullcharge 3:temporarily_disable
}

void setSmartChargeEnable(BOOL flag) {
    PowerUISmartChargeClient* client = getSmartChargeClient();
    BOOL status = isSmartChargeEnable();
    if (status == flag) {
        return;
    }
    NSError* err = nil;
    if (flag) {
        [client enableSmartCharging:&err];
    } else {
        [client disableSmartCharging:&err];
    }
}

/* ---------------- App ---------------- */
@interface CLSettingsStore : NSObject
@property (nonatomic, strong) NSMutableDictionary* preferences;
@property (nonatomic, strong) NSMutableDictionary* cachedChanges;
@property (nonatomic, assign) BOOL isDirty;
+ (instancetype)shared;
- (id)readValueForKey:(NSString*)key defaultValue:(id)defaultValue;
- (void)setValue:(id)value forKey:(NSString*)key;
- (void)apply;
- (void)reloadFromDisk;
@end

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
        _isDirty = NO;
        NSString* confPath = getConfPath();
        if (confPath.length > 0) {
            NSDictionary* fileDict = [NSDictionary dictionaryWithContentsOfFile:confPath];
            if ([fileDict isKindOfClass:[NSDictionary class]]) {
                [_preferences addEntriesFromDictionary:fileDict];
            }
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
        } else {
            [self.cachedChanges removeObjectForKey:key];
            [self.preferences removeObjectForKey:key];
        }
        self.isDirty = YES;
    }
}

- (void)apply {
    @synchronized (self) {
        if (!self.isDirty) {
            return;
        }
        NSString* confPath = getConfPath();
        if (confPath.length == 0) {
            return;
        }
        [self.preferences writeToFile:confPath atomically:YES];
        [self.cachedChanges removeAllObjects];
        self.isDirty = NO;
    }
}

- (void)reloadFromDisk {
    @synchronized (self) {
        [self.preferences removeAllObjects];
        [self.cachedChanges removeAllObjects];
        self.isDirty = NO;
        NSString* confPath = getConfPath();
        if (confPath.length == 0) {
            return;
        }
        NSDictionary* fileDict = [NSDictionary dictionaryWithContentsOfFile:confPath];
        if ([fileDict isKindOfClass:[NSDictionary class]]) {
            [self.preferences addEntriesFromDictionary:fileDict];
        }
    }
}
@end

id getlocalKV(NSString* key) {
    return [[CLSettingsStore shared] readValueForKey:key defaultValue:nil];
}

void setlocalKV(NSString* key, id val) {
    CLSettingsStore* store = [CLSettingsStore shared];
    [store setValue:val forKey:key];
    [store apply];
}

void reloadLocalKVFromDisk(void) {
    [[CLSettingsStore shared] reloadFromDisk];
}

NSDictionary* getAllKV() {
    CLSettingsStore* store = [CLSettingsStore shared];
    @synchronized (store) {
        return [store.preferences copy];
    }
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
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
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
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppLanguage"];
    if ([raw isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)raw;
        if ([str isEqualToString:@"en"]) return CLAppLanguageEnglish;
        if ([str isEqualToString:@"zh-Hans"]) return CLAppLanguageChineseSimplified;
        return CLAppLanguageSystem;
    }
    NSInteger val = [[NSUserDefaults standardUserDefaults] integerForKey:@"AppLanguage"];
    if (val < CLAppLanguageSystem || val > CLAppLanguageChineseSimplified) {
        return CLAppLanguageSystem;
    }
    return (CLAppLanguage)val;
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

void CLSetAppLanguage(CLAppLanguage language) {
    [[NSUserDefaults standardUserDefaults] setInteger:language forKey:@"AppLanguage"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    CLApplyLanguageFromSettings();
    [[NSNotificationCenter defaultCenter] postNotificationName:CLAppLanguageDidChangeNotification object:nil];
}
