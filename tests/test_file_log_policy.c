#include <assert.h>
#include <stdbool.h>
#include <string.h>

#include "../ChargeLimiter/CLFileLogPolicy.h"

int main(void) {
    // CLFileLogModeFromCString tests
    assert(CLFileLogModeFromCString(NULL) == CLFileLogModeNormal);
    assert(CLFileLogModeFromCString("") == CLFileLogModeNormal);
    assert(CLFileLogModeFromCString("normal") == CLFileLogModeNormal);
    assert(CLFileLogModeFromCString("error") == CLFileLogModeErrorOnly);
    assert(CLFileLogModeFromCString("verbose") == CLFileLogModeNormal);

    // CLFileLogShouldWrite tests
    assert(CLFileLogShouldWrite(CLFileLogModeNormal, CLFileLogSeverityInfo) == true);
    assert(CLFileLogShouldWrite(CLFileLogModeNormal, CLFileLogSeverityError) == true);
    assert(CLFileLogShouldWrite(CLFileLogModeErrorOnly, CLFileLogSeverityInfo) == false);
    assert(CLFileLogShouldWrite(CLFileLogModeErrorOnly, CLFileLogSeverityError) == true);

    return 0;
}