#ifndef CLFileLogPolicy_h
#define CLFileLogPolicy_h

#include <stdbool.h>
#include <string.h>

typedef enum CLFileLogMode {
    CLFileLogModeNormal,
    CLFileLogModeErrorOnly,
} CLFileLogMode;

typedef enum CLFileLogSeverity {
    CLFileLogSeverityInfo,
    CLFileLogSeverityError,
} CLFileLogSeverity;

static inline CLFileLogMode CLFileLogModeFromCString(const char *s) {
    if (s == NULL) {
        return CLFileLogModeNormal;
    }
    if (strcmp(s, "error") == 0) {
        return CLFileLogModeErrorOnly;
    }
    return CLFileLogModeNormal;
}

static inline bool CLFileLogShouldWrite(CLFileLogMode mode, CLFileLogSeverity sev) {
    if (sev == CLFileLogSeverityError) {
        return true;
    }
    // sev == CLFileLogSeverityInfo
    return mode == CLFileLogModeNormal;
}

#endif /* CLFileLogPolicy_h */