#ifndef UTILS_H
#define UTILS_H

#include "common.h"

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString*)identifier;
@property (nonatomic, readonly) NSString* bundleIdentifier;
@property (nonatomic, readonly) NSURL* dataContainerURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;
@end

enum {
    SPAWN_FLAG_ROOT     = 1,
    SPAWN_FLAG_NOWAIT   = 2,
    SPAWN_FLAG_SUSPEND  = 4,
};
int spawn(NSArray* args, NSString** stdOut, NSString** stdErr, pid_t* pidPtr, int flag, NSDictionary* param=nil);
int get_pid_of(const char* name);
int get_sys_boottime();
int platformize_me();
int32_t get_mem_limit(int pid);
int set_mem_limit(int pid, int mb);
BOOL localPortOpen(int port);
NSString* getSelfExePath();
NSArray* getUnusedFds();
NSArray* getFrontMostBid();

#define STR(X) #X

#ifdef THEOS_PACKAGE_INSTALL_PREFIX
#define ROOTDIR STR(THEOS_PACKAGE_INSTALL_PREFIX)
#else
#define ROOTDIR
#endif
enum {
    JBTYPE_UNKNOWN      = -1,
    JBTYPE_ROOTLESS     = 0,
    JBTYPE_ROOT         = 1,
    JBTYPE_ROOTHIDE     = 2,
    JBTYPE_TROLLSTORE   = 8, // TrollStore/AppStore
};
int getJBType();
// 1=updated, 0=unchanged/not applicable, -1=failed.
int CLRepairRoothideLaunchDaemonPlist(void);
void NSFileErrorLog(NSString* fmt, ...);
void NSFileInfoLog(NSString* fmt, ...);
NSString* getAppVer();
NSString* getSysVer();
NSString* getDevMdoel();
CGFloat getOrientAngle(UIDeviceOrientation orientation);

BOOL isAirEnable();
void setAirEnable(BOOL flag);
BOOL isWiFiEnable();
void setWiFiEnable(BOOL flag);
BOOL isBlueEnable();
void setBlueEnable(BOOL flag);
BOOL isLPMEnable();
void setLPMEnable(BOOL flag);
BOOL isLocEnable();
void setLocEnable(BOOL flag);
float getBrightness();
void setBrightness(float val);
BOOL isAutoBrightEnable();
void setAutoBrightEnable(BOOL flag);

NSDictionary* getThermalData();
NSString* getThermalSimulationMode();
NSString* getThermalSimulationModePref();
void setThermalSimulationMode(NSString* mode);
NSString* getPPMSimulationMode();
void setPPMSimulationMode(NSString* mode);
BOOL isSmartChargeEnable(); // 系统自带电池优化
int getSmartChargeStatus(); // 0:disable 1:enable 2:fullcharge 3:temporarily_disable
BOOL temporarilyDisableSmartCharge();
void setSmartChargeEnable(BOOL flag);

/* ---------------- App ---------------- */
id getlocalKV(NSString* key);
void setlocalKV(NSString* key, id val);
BOOL setlocalKVChecked(NSString* key, id val); // YES=写盘成功
// 启动时把 App 四键从 appdata suite / standardUserDefaults 迁入共享 plist。
// YES=迁移逻辑完成（含无数据可迁）；NO=需要写入共享却写失败。
BOOL CLMigrateAppSettingsToSharedStoreIfNeeded(void);
NSDictionary* getAllKV();
BOOL getLocalBool(NSString* key, BOOL defaultValue);
int getLocalInt(NSString* key, int defaultValue);
float getLocalFloat(NSString* key, float defaultValue);
NSString* getLocalString(NSString* key, NSString* defaultValue);
NSArray* getLocalArray(NSString* key, NSArray* defaultValue);
NSDictionary* getLocalDict(NSString* key, NSDictionary* defaultValue);
void setLocalBool(NSString* key, BOOL value);
void setLocalInt(NSString* key, int value);
void setLocalFloat(NSString* key, float value);
void setLocalString(NSString* key, NSString* value);
void setLocalArray(NSString* key, NSArray* value);
void setLocalDict(NSString* key, NSDictionary* value);
void reloadLocalKVFromDisk(void);

// 配置写入失败通知
extern NSString* const CLConfigWriteFailedNotification;

/* ---------------- App ---------------- */

NSString* getAppDocumentsPath();
NSString* getLogPath();
NSString* getConfPath();
NSString* getDbPath();
NSString* getConfDirPath();
NSString* getRuntimeDataRootPath(void);
void setAppDocumentsPathOverride(NSString* docsPath);
extern "C" NSUserDefaults* getAppUserDefaults(void);  // 获取使用 app 数据容器的 NSUserDefaults
extern "C" int cleanupAppDataContainer_C(void);
extern "C" NSString* getConfPath_C(void);
extern "C" NSString* getRuntimeDataRootPath_C(void);
extern "C" NSDictionary* getConfigPersistenceDiagnostics_C(void);
// Thin C-linkage wrappers for App-side dlsym (utils.mm symbols are C++ mangled).
extern "C" int getJBType_C(void);
extern "C" NSString* getSelfExePath_C(void);
extern "C" int get_sys_boottime_C(void);
extern "C" void setlocalKV_C(NSString* key, id val);
extern "C" id getlocalKV_C(NSString* key);
extern "C" void reloadLocalKVFromDisk_C(void);
extern "C" NSDictionary* getAllKV_C(void);
extern "C" BOOL ensureLocalConfigFileExists_C(NSString** pathOut, NSError** errorOut);
extern "C" BOOL localPortOpen_C(int port);
extern "C" int restartDaemonForApp_C(NSString* appDocs);
extern "C" NSArray<NSString*>* getLegacyConfigDirsWithData_C(void);
extern "C" NSArray<NSString*>* getLegacyResidualFiles_C(void);
extern "C" NSDictionary* cleanupLegacyResidualFiles_C(void);
extern "C" NSDictionary* migrateLegacyConfigFiles_C(void);

#endif // UTILS_H
