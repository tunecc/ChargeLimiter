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
void addPathEnv(NSString* path, BOOL tail);
int get_pid_of(const char* name);
int get_sys_boottime();
NSString* findAppPath(NSString* name);
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
void NSFileLog(NSString* fmt, ...);
NSString* getAppVer();
NSString* getSysVer();
NSOperatingSystemVersion getSysVerInt();
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
NSString* getPerfManState();
void DisablePerfMan();
NSString* getThermalSimulationMode();
void setThermalSimulationMode(NSString* mode);
NSString* getPPMSimulationMode();
void setPPMSimulationMode(NSString* mode);
BOOL isSmartChargeEnable(); // 系统自带电池优化
void setSmartChargeEnable(BOOL flag);

/* ---------------- App ---------------- */
id getlocalKV(NSString* key);
void setlocalKV(NSString* key, id val);
NSDictionary* getAllKV();
BOOL getLocalBool(NSString* key, BOOL defaultValue);
int getLocalInt(NSString* key, int defaultValue);
float getLocalFloat(NSString* key, float defaultValue);
double getLocalDouble(NSString* key, double defaultValue);
NSString* getLocalString(NSString* key, NSString* defaultValue);
NSArray* getLocalArray(NSString* key, NSArray* defaultValue);
NSDictionary* getLocalDict(NSString* key, NSDictionary* defaultValue);
void setLocalBool(NSString* key, BOOL value);
void setLocalInt(NSString* key, int value);
void setLocalFloat(NSString* key, float value);
void setLocalDouble(NSString* key, double value);
void setLocalString(NSString* key, NSString* value);
void setLocalArray(NSString* key, NSArray* value);
void setLocalDict(NSString* key, NSDictionary* value);
void reloadLocalKVFromDisk(void);
/* ---------------- App ---------------- */

NSString* getAppDocumentsPath();
NSString* getLogPath();
NSString* getConfPath();
NSString* getDbPath();
NSString* getConfDirPath();
extern "C" NSString* getConfPath_C(void);
extern "C" NSString* getConfDirPath_C(void);
extern "C" NSArray<NSString*>* getLegacyConfigDirsWithData_C(void);
extern "C" NSArray<NSString*>* getLegacyResidualFiles_C(void);
extern "C" NSDictionary* cleanupLegacyResidualFiles_C(void);
extern "C" NSDictionary* migrateLegacyConfigFiles_C(void);

#endif // UTILS_H
