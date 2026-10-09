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
NSString* getThermalSimulationMode(); // 实时系统热状态（生效探针）
NSString* getThermalConfigMode(); // com.apple.cltm 中已配置的模拟档位
void setThermalSimulationMode(NSString* mode);

// 仅限流会话（limit-only daemon-free）：com.apple.cltm 域的会话键与 thermal 镜像。
// 以下读写在调用进程的 CFPreferences 域生效——仅限 root（daemon/CLI 动词）；
// App（mobile）必须经 spawnDaemonCLIVerb_C 走 root 一次性进程，不得直写。
#ifdef __cplusplus
extern "C" {
#endif
BOOL getLimitOnlySessionEnabled(void);      // clLimitSessionEnabled
NSString* getLimitOnlyLevel(void);          // clLimitMode（充电时档位；非法/缺省按 off）
NSString* getLimitOnlyIdleLevel(void);      // clLimitIdleMode（平时档位；缺键/非法按 off）
void setLimitOnlySession(BOOL enabled, NSString* chargeMode, NSString* idleMode, BOOL chargingActive); // 会话键 + thermal 镜像 + 通知
void clearLimitOnlySessionKeys(void);       // 清会话键并把 thermal 镜像归零 + 通知
BOOL isCLPowerConnected(void);              // AppleSmartBattery 插电判定（ExternalChargeCapable 优先）
int spawnDaemonCLIVerb_C(NSArray<NSString*>* verbArgs); // App 侧阻塞式 spawn daemon CLI 动词
// 内核态通道只读辅助（fix-thermal-limit-live-loop）：App（mobile）与 daemon 共用。
BOOL CLThermalReadApplyChannel(uint64_t *mode);                  // 档位通道：0=off/1-4 档位
// 会话通道：enabled(bit0)|充电时档位(bit8-15)|平时档位(bit16-23)。两个档位出参均可为 NULL。
BOOL CLThermalReadSessionChannel(BOOL *enabled, uint64_t *chargeMode, uint64_t *idleMode);
NSString* CLThermalModeName(uint64_t mode);                      // 0-4 → off/nominal/light/moderate/heavy
NSString* CLThermalExternalSimulationSource(void);               // 外部模拟源在场（powercuff），无则 nil
void CLThermalPushApplyChannel(NSString *mode);                  // 档位通道写+广播（复用既有唯一写实现；selftest 用）
#ifdef __cplusplus
}
#endif
BOOL isSmartChargeEnable(); // 系统自带电池优化
int getSmartChargeStatus(); // 0:disable 1:enable 2:fullcharge 3:temporarily_disable
BOOL temporarilyDisableSmartCharge();
void setSmartChargeEnable(BOOL flag);
// iOS 17+ MCL（Manual Charge Limit，"充电优化"三选项的 80% 限制开关）。
// MCL selector 仅 iOS 17+ 存在：探测内含 @available + respondsToSelector 门控，
// 旧系统探测恒 NO，get 恒 NO、set 恒 NO（无效），行为与 iOS 16 一致。
BOOL isSmartChargeMCLSupported(void);
BOOL getSmartChargeMCLEnabled(void);
BOOL setSmartChargeMCLEnabled(BOOL flag);

// iOS 17+ MCL 诊断读取层（Design Doc 3.1）。层1 = /var/mobile 域偏好直读；
// 层2 = agent 内存层（XPC 读回的真实语义，F1），非执行层证据。
typedef NS_ENUM(int, CLMCLPrefReadState) {
    CLMCLPrefMissing = 0,    // 键不存在（域内无此键）
    CLMCLPrefFound = 1,      // 读到值
    CLMCLPrefReadFailed = 2, // 域存在但读取异常（区分于缺失）
};
NSArray<NSString*>* CLMCLPrefKeys(void);
// 层1 快照：outPrefs[@"domain"]/@"plist_path"/@"values"/@"states"（states 值为 CLMCLPrefReadState）。
// 返回 YES=主域已命中；NO=unresolved（两候选域均无白名单键且无读取异常域）。
BOOL CLMCLReadPrefs(NSMutableDictionary* outPrefs);
// 层1 活通道（v1.17.1 修复轮 1 回灌）：磁盘直读对 cfprefsd 缓冲态全盲——poweruiagent
// 以 mobile 用户经 cfprefsd 写偏好，plist 可能长期不落盘甚至从不存在；"文件读不到"
// ≠"偏好为空"≠"服务端没写"。本通道 fork 后降权为 mobile 用户执行
// `defaults read <domain>` 读 cfprefsd 服务端真相；defaults 二进制按序探测
// （v1.17.2 域定案回灌，re-notes §7）：libroothide jbroot 解析路径（运行时 dlsym
// 弱依赖）→ /var/jb/usr/bin/defaults → /usr/bin/defaults，全部缺失才降级。
// outLive[@"channel"]=@"ok"|@"unavailable"、@"channel_reason"（仅不可用时）、
// @"pref_files"（Preferences 目录下 powerui|smartcharg 命中文件名字面值）、
// @"domain"/@"values"/@"states"（语义同 CLMCLReadPrefs）、@"raw"（defaults 原始输出，截断 8KB）。
// v1.17.1 修复轮 2：结果按域做 15s TTL 缓存（raw+解析结果），常规轮询路径命中即复用；
// forceRefresh=YES 绕过缓存强制活读（修复复核专用——必须看到 enableMCL 刚写入的
// live 值，归因守卫依赖），fresh 结果仍回填缓存。
// 返回 YES=活通道命中任一白名单键；NO=通道不可用或两候选域均未命中。
BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh);
// 层2：OBC 状态 + MCL 支持性/读回。返回 YES=MCL 受支持。
BOOL CLMCLReadAgentState(int* obcStatus, BOOL* mclSupported, BOOL* mclEnabled);

// MCL 强制入口：无读回短路，无条件下发（修复编排专用；常规联动仍走 setSmartChargeMCLEnabled）。
BOOL CLMCLForceEnable(void);
BOOL CLMCLForceDisable(void);
// 从自身 exe 截取 .jbroot-XXX 前缀（roothide launchd plist 候选路径推导用；非 roothide 返回 @""）
NSString* CLDaemonJbRootPath(void);

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
extern "C" BOOL setlocalKVBatch_C(NSDictionary* keyValues);
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
