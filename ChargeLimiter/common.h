#ifndef common_h
#define common_h

#include <arpa/inet.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#if !TARGET_OS_SIMULATOR
#import <IOKit/hid/IOHIDService.h>
#else
typedef const struct __IOHIDService* IOHIDServiceRef;
typedef const struct __IOHIDEvent* IOHIDEventRef;
#endif
#import <UIKit/UIKit.h>

#define NSLog2(FORMAT, ...) os_log(OS_LOG_DEFAULT,"%{public}@", [NSString stringWithFormat:FORMAT, ##__VA_ARGS__])

#define PRODUCT         "ChargeLimiter"
#define GSERV_PORT      1230
#define FLOAT_ORIGINX   100
#define FLOAT_ORIGINY   100
#define FLOAT_WIDTH     80
#define FLOAT_HEIGHT    60
#define log_prefix      @"ChargeLimiterLogger"

#define LOG_FILENAME        "aldente.log"
#define DB_FILENAME         "aldente.db"
#define CONFIG_PLIST_FILENAME       "com.chargelimiter.mod.plist"
#define LEGACY_CONF_FILENAME        "aldente.conf"

#endif // common_h
