#import <Foundation/Foundation.h>

#define CLL(value) (value)
#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "%s\n", message); return 1; } \
} while (0)

typedef void (^CLAPICallback)(NSDictionary *response, NSError *error);

@interface CLAPIClient : NSObject
@property (nonatomic, copy) CLAPICallback pendingRelease;
@property (nonatomic, copy) CLAPICallback pendingBattery;
@property (nonatomic, strong) NSDictionary *battery;
@property (nonatomic) BOOL holdRelease;
@property (nonatomic) BOOL holdBattery;
@property (nonatomic) NSInteger releaseCount;
@property (nonatomic) NSInteger disableCount;
+ (instancetype)shared;
- (void)getBatteryInfoWithCompletion:(CLAPICallback)completion;
- (void)getConfigWithKey:(NSString *)key completion:(CLAPICallback)completion;
- (void)setChargeStatus:(BOOL)charging completion:(CLAPICallback)completion;
- (void)setInflowStatus:(BOOL)connected completion:(CLAPICallback)completion;
@end

@implementation CLAPIClient
+ (instancetype)shared {
    static CLAPIClient *client;
    if (!client) client = [CLAPIClient new];
    return client;
}
- (void)getBatteryInfoWithCompletion:(CLAPICallback)completion {
    if (self.holdBattery) self.pendingBattery = completion;
    else completion(@{@"status": @0, @"data": self.battery ?: @{}}, nil);
}
- (void)getConfigWithKey:(NSString *)key completion:(CLAPICallback)completion {
    completion(@{@"status": @0, @"data": @{@"enable": @NO}}, nil);
}
- (void)setChargeStatus:(BOOL)charging completion:(CLAPICallback)completion {
    if (completion) completion(@{@"status": @0}, nil);
}
- (void)setInflowStatus:(BOOL)connected completion:(CLAPICallback)completion {
    if (connected) self.releaseCount++;
    else self.disableCount++;
    if (connected && self.holdRelease) self.pendingRelease = completion;
    else if (completion) completion(@{@"status": @0}, nil);
}
@end

@interface CLBatteryManager : NSObject
+ (instancetype)shared;
- (void)saveConfigKey:(NSString *)key value:(id)value completion:(void(^)(BOOL))completion;
@end

@implementation CLBatteryManager
+ (instancetype)shared {
    static CLBatteryManager *manager;
    if (!manager) manager = [CLBatteryManager new];
    return manager;
}
- (void)saveConfigKey:(NSString *)key value:(id)value completion:(void(^)(BOOL))completion {
    if (completion) completion(YES);
}
@end

/* PRODUCTION_ENGINE */

@interface CLCompatHarness : CLBatteryCompatibilityEngine
@property (nonatomic, strong) NSMutableArray<CLCompatTestEvent *> *verdictEvents;
@property (nonatomic) NSInteger settleCount;
@property (nonatomic) NSInteger restoreCount;
@end

@implementation CLCompatHarness
- (void)acquireBaselineThenArm:(CLCompatTestKind)kind {}
- (void)emitEvent:(CLCompatTestEvent *)event {
    if (event.kind == CLCompatEventKindVerdict) [self.verdictEvents addObject:event];
}
- (void)settleAfterTest:(void(^)(BOOL))completion { self.settleCount++; }
- (void)performRestoreAndFinish { self.restoreCount++; self.running = NO; }
@end

static void DrainCallbacks(void) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static CLCompatHarness *NewEngine(CLCompatTestKind kind) {
    CLAPIClient *client = [CLAPIClient shared];
    client.pendingRelease = nil;
    client.pendingBattery = nil;
    client.battery = @{@"IsCharging": @YES, @"InstantAmperage": @500};
    client.holdRelease = NO;
    client.holdBattery = NO;
    client.releaseCount = 0;
    client.disableCount = 0;
    CLCompatHarness *engine = [CLCompatHarness new];
    engine.verdictEvents = [NSMutableArray array];
    engine.running = YES;
    engine.currentKind = kind;
    [engine beginTest:kind];
    engine.bCharging = YES;
    return engine;
}

static void Sample(CLCompatHarness *engine, BOOL charging, NSInteger current) {
    [engine handleSample:@{@"IsCharging": @(charging), @"InstantAmperage": @(current),
                          @"ExternalConnected": @NO}];
}

static void EnterRelease(CLCompatHarness *engine) {
    for (NSInteger i = 0; i < 11; i++) Sample(engine, NO, 900);
    DrainCallbacks();
}

static void CompleteRelease(BOOL success) {
    CLAPIClient *client = [CLAPIClient shared];
    CLAPICallback completion = client.pendingRelease;
    client.pendingRelease = nil;
    if (completion) completion(@{@"status": success ? @0 : @-2}, nil);
    DrainCallbacks();
}

static int RunScenario(NSString *name) {
    CLCompatHarness *engine = NewEngine(CLCompatTestKindInflow);
    CLAPIClient *client = [CLAPIClient shared];
    if ([name isEqualToString:@"cycle"]) {
        for (NSNumber *value in @[@-500, @0, @5, @500, @2000]) {
            engine = NewEngine(CLCompatTestKindInflow);
            Sample(engine, YES, 500);
            Sample(engine, NO, value.integerValue);
            CHECK(engine.verdictEvents.count == 0, "An exit alone is not a complete cycle");
            Sample(engine, YES, value.integerValue);
            CHECK(engine.verdictEvents.count == 1, "A complete cycle must produce one verdict");
            CLCompatTestEvent *event = engine.verdictEvents.lastObject;
            CHECK(event.verdict == CLCompatTestVerdictSupported, "Current must not veto a charging cycle");
            CHECK(event.exitElapsed == 2 && event.returnElapsed == 3, "Both charging edges must be recorded");
            CHECK(event.restoreMode == CLCompatInflowRestoreSystem, "Automatic return must be recorded");
            CHECK(client.disableCount == 0, "Automatic return must not trigger an inflow retry");
        }
    } else if ([name isEqualToString:@"no_exit"]) {
        for (NSInteger i = 0; i < 120; i++) Sample(engine, YES, -500);
        CHECK(engine.verdictEvents.count == 1, "No exit must eventually terminate");
        CHECK(engine.verdictEvents.lastObject.verdict == CLCompatTestVerdictUnsupported, "Current or cable flags cannot substitute for IsCharging");
        CHECK(client.releaseCount == 0, "No observed exit needs no test release");
    } else if ([name isEqualToString:@"deadline_exit"]) {
        for (NSInteger i = 0; i < 119; i++) Sample(engine, YES, 500);
        Sample(engine, NO, 500);
        Sample(engine, YES, 500);
        CHECK(engine.verdictEvents.lastObject.verdict == CLCompatTestVerdictSupported, "An exit at the deadline can complete");
    } else if ([name isEqualToString:@"release"]) {
        EnterRelease(engine);
        CHECK(client.releaseCount == 1, "Release must be sent once after the observation window");
        CHECK(engine.verdictEvents.count == 0, "A write acknowledgement alone cannot prove restoration");
        Sample(engine, YES, 900);
        CHECK(engine.verdictEvents.lastObject.verdict == CLCompatTestVerdictSupported, "Release followed by charging completes the cycle");
        CHECK(engine.verdictEvents.lastObject.restoreMode == CLCompatInflowRestoreAfterRelease, "Record explicit restoration");
    } else if ([name isEqualToString:@"release_pending"]) {
        client.holdRelease = YES;
        EnterRelease(engine);
        Sample(engine, YES, 900);
        CHECK(engine.verdictEvents.count == 0, "Do not settle while the release write is still pending");
        CompleteRelease(YES);
        CHECK(engine.verdictEvents.count == 1 && engine.verdictEvents.lastObject.verdict == CLCompatTestVerdictSupported, "Keep the observed return until the successful acknowledgement");
        CHECK(engine.settleCount == 1 && engine.inFlightWrites == 0, "Settle once after the write drains");
    } else if ([name isEqualToString:@"release_error"]) {
        client.holdRelease = YES;
        EnterRelease(engine);
        Sample(engine, YES, 900);
        CompleteRelease(NO);
        CHECK(engine.verdictEvents.count == 1, "Failed release must not overwrite an earlier success verdict");
        CHECK(engine.verdictEvents.lastObject.verdict == CLCompatTestVerdictError, "Rejected release is an error, not unsupported");
        CHECK(engine.settleCount == 1, "Rejected release must settle only once");
    } else if ([name isEqualToString:@"release_timeout"]) {
        EnterRelease(engine);
        for (NSInteger i = 0; i < 20; i++) Sample(engine, NO, -500);
        CHECK(engine.verdictEvents.count == 1 && engine.verdictEvents.lastObject.verdict == CLCompatTestVerdictUnsupported, "No return after release is an incomplete cycle");
    } else if ([name isEqualToString:@"late_release"]) {
        client.holdRelease = YES;
        EnterRelease(engine);
        [engine finishTestWithVerdict:CLCompatTestVerdictError message:@"Interrupted acquisition"];
        CompleteRelease(NO);
        CHECK(engine.verdictEvents.count == 1 && engine.settleCount == 1, "Late release callback must not finish the same test twice");
    } else if ([name isEqualToString:@"late_sample"]) {
        Sample(engine, NO, 500);
        Sample(engine, YES, 500);
        Sample(engine, YES, 500);
        CHECK(engine.verdictEvents.count == 1 && engine.settleCount == 1, "A late sample must not duplicate the verdict");
    } else if ([name isEqualToString:@"stale_poll"]) {
        client.holdBattery = YES;
        [engine pollTick];
        CLAPICallback oldPoll = client.pendingBattery;
        [engine finishTestWithVerdict:CLCompatTestVerdictError message:@"Interrupted acquisition"];
        [engine beginTest:CLCompatTestKindInflow];
        engine.pollInFlight = YES;
        oldPoll(@{@"status": @0, @"data": @{@"IsCharging": @NO}}, nil);
        DrainCallbacks();
        CHECK(engine.elapsed == 0 && engine.exitElapsed == -1, "A previous test's sample cannot enter the next test");
        CHECK(engine.pollInFlight, "Old callback cannot clear a newer poll's in-flight flag");
    } else if ([name isEqualToString:@"invalid_state"]) {
        for (id value in @[[NSNull null], @"false", @{}]) {
            client.battery = [value isKindOfClass:[NSDictionary class]] ? @{} : @{@"IsCharging": value};
            __block BOOL completed = NO;
            __block NSDictionary *sample = nil;
            [engine fetchBatteryData:^(NSDictionary *data) { completed = YES; sample = data; }];
            DrainCallbacks();
            CHECK(completed && sample == nil, "Missing or malformed IsCharging must be rejected, never treated as NO");
        }
    } else if ([name isEqualToString:@"cancel"]) {
        client.holdRelease = YES;
        EnterRelease(engine);
        [engine cancel];
        CHECK(engine.restoreCount == 0, "Cancellation must drain pending release first");
        CompleteRelease(NO);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        CHECK(engine.verdictEvents.count == 0, "Canceled release cannot publish a verdict");
        CHECK(engine.restoreCount == 1 && engine.inFlightWrites == 0, "Cancel must complete restoration after the write drains");
    } else if ([name isEqualToString:@"stop_charge"]) {
        for (NSNumber *kind in @[@(CLCompatTestKindStopCharge), @(CLCompatTestKindSmartStopCharge)]) {
            for (NSNumber *current in @[@-100, @900]) {
                engine = NewEngine(kind.integerValue);
                for (NSInteger i = 0; i < 10; i++) Sample(engine, NO, current.integerValue);
                CLCompatTestVerdict expected = current.integerValue < 5 ? CLCompatTestVerdictSupported : CLCompatTestVerdictUnsupported;
                CHECK(engine.verdictEvents.count == 1 && engine.verdictEvents.lastObject.verdict == expected, "Stop-charge tests must retain their current criterion");
            }
        }
    } else {
        CHECK(NO, "Unknown scenario");
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        return RunScenario([NSString stringWithUTF8String:argv[1]]);
    }
}
