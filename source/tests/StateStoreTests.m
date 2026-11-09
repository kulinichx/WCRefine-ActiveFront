#import <Foundation/Foundation.h>
#import <math.h>
#import "../WCRAFStateStore.h"

static NSString * const Prefix = @"com.local.wcrefine.activefront.account.v2.";
static NSString * const LegacyNames = @"com.local.wcrefine.activefront.heldUsernames.v1";
static NSString * const LegacyDays = @"com.local.wcrefine.activefront.holdExpiryDays.v1";
static NSTimeInterval const Day = 86400.0;

static void Require(BOOL condition, const char *expression, int line) {
    if (!condition) {
        [NSException raise:@"TestFailure" format:@"line %d: %s", line, expression];
    }
}
#define CHECK(condition) Require((condition), #condition, __LINE__)

// Real defaults storage with deterministic failures/reentrant callbacks.
@interface FaultDefaults : NSUserDefaults
@property(nonatomic) BOOL failRead;
@property(nonatomic) BOOL failWrite;
@property(nonatomic, copy) void (^afterWrite)(void);
@end

@implementation FaultDefaults
- (id)objectForKey:(NSString *)key {
    if (self.failRead) [NSException raise:@"ReadFailure" format:@"test"];
    return [super objectForKey:key];
}
- (void)setObject:(id)value forKey:(NSString *)key {
    if (self.failWrite) [NSException raise:@"WriteFailure" format:@"test"];
    [super setObject:value forKey:key];
    void (^callback)(void) = self.afterWrite;
    self.afterWrite = nil;
    if (callback) callback();
}
@end

@interface Fixture : NSObject
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *suite;
@property(nonatomic) NSTimeInterval now;
@property(nonatomic) BOOL resolverThrows;
@property(nonatomic) BOOL clockThrows;
@property(nonatomic, strong) FaultDefaults *defaults;
@property(nonatomic, strong) WCRAFStateStore *store;
- (WCRAFStateStore *)newStore;
- (WCRAFAccountContext *)keep:(NSString *)username;
- (WCRAFExpiryCandidate *)expiredTicket:(NSString *)username;
- (void)clean;
@end

@implementation Fixture
- (instancetype)init {
    self = [super init];
    if (self) {
        _account = @"account-A";
        _now = 2000000000.0;
        _suite = [@"WCRefineGroup.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        _defaults = [[FaultDefaults alloc] initWithSuiteName:_suite];
        _store = [self newStore];
    }
    return self;
}
- (WCRAFStateStore *)newStore {
    __weak Fixture *weakSelf = self;
    return [[WCRAFStateStore alloc] initWithDefaults:self.defaults
        accountResolver:^NSString *{
            if (weakSelf.resolverThrows) [NSException raise:@"UnavailableAccount" format:@"test"];
            return weakSelf.account;
        } clock:^NSTimeInterval{
            if (weakSelf.clockThrows) [NSException raise:@"ClockFailure" format:@"test"];
            return weakSelf.now;
        }];
}
- (WCRAFAccountContext *)keep:(NSString *)username {
    WCRAFAccountContext *context = [self.store currentContext];
    CHECK(context != nil);
    CHECK([self.store setHeld:YES username:username context:context]);
    return context;
}
- (WCRAFExpiryCandidate *)expiredTicket:(NSString *)username {
    WCRAFAccountContext *context = [self keep:username];
    NSTimeInterval heldAt = self.now;
    self.now += 8 * Day;
    WCRAFExpiryCandidate *ticket = [self.store enqueueExpiry:username context:context
        lastMessageTime:heldAt - Day];
    CHECK(ticket != nil);
    return ticket;
}
- (void)clean {
    self.defaults.failRead = NO;
    self.defaults.failWrite = NO;
    self.defaults.afterWrite = nil;
    [self.defaults removePersistentDomainForName:self.suite];
}
@end

static void NoAutomaticLegacyMigration(Fixture *f) {
    [f.defaults setObject:@[@"alice"] forKey:LegacyNames];
    [f.defaults setInteger:3 forKey:LegacyDays];
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK(![f.store isHeld:@"alice" context:context]);
    CHECK([f.store expiryDaysForContext:context] == 7);
    CHECK([f.defaults objectForKey:[Prefix stringByAppendingString:f.account]] == nil);
    CHECK([[f.defaults objectForKey:LegacyNames] isEqual:@[@"alice"]]);
}

static void AccountIsolation(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"same-contact"];
    CHECK([f.store setExpiryDays:3 context:a]);
    f.account = @"account-B";
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK(![f.store isHeld:@"same-contact" context:b]);
    CHECK([f.store expiryDaysForContext:b] == 7);
    CHECK(![f.store setHeld:NO username:@"same-contact" context:a]);
    [f keep:@"bob"];
    f.account = @"account-A";
    WCRAFAccountContext *again = [f.store currentContext];
    CHECK([f.store isHeld:@"same-contact" context:again]);
    CHECK(![f.store isHeld:@"bob" context:again]);
    CHECK([f.store expiryDaysForContext:again] == 3);
    CHECK(![f.store isCurrentContext:a]);
    CHECK(a.epoch != again.epoch);
}

static void NilAccount(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"alice"];
    NSDictionary *before = [f.defaults persistentDomainForName:f.suite];
    f.account = nil;
    CHECK([f.store currentContext] == nil);
    CHECK([f.store currentContext] == nil);
    CHECK(![f.store setHeld:NO username:@"alice" context:a]);
    CHECK(![f.store setExpiryDays:0 context:a]);
    CHECK(![f.store importLegacyForContext:a]);
    CHECK([[f.defaults persistentDomainForName:f.suite] isEqual:before]);
    f.account = @"account-A";
    CHECK(![f.store isCurrentContext:a]);
    CHECK([f.store isHeld:@"alice" context:[f.store currentContext]]);
}

static void ResolverFailure(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"alice"];
    f.resolverThrows = YES;
    CHECK([f.store currentContext] == nil);
    CHECK(![f.store setHeld:NO username:@"alice" context:a]);
    f.resolverThrows = NO;
    CHECK(![f.store isCurrentContext:a]);
    CHECK([f.store isHeld:@"alice" context:[f.store currentContext]]);
}

static void ExpiryBoundaries(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"alice"];
    NSTimeInterval since = f.now;
    CHECK([f.store setExpiryDays:3 context:a]);
    f.now = since + 3 * Day - 1;
    CHECK(![f.store isExpired:@"alice" context:a lastMessageTime:since - Day]);
    f.now += 1;
    CHECK([f.store isExpired:@"alice" context:a lastMessageTime:since - Day]);
    CHECK(![f.store isExpired:@"alice" context:a lastMessageTime:f.now]);
    CHECK(![f.store isExpired:@"alice" context:a lastMessageTime:f.now + Day]);
    CHECK([f.store setExpiryDays:0 context:a]);
    f.now += 100 * Day;
    CHECK(![f.store isExpired:@"alice" context:a lastMessageTime:since]);
}

static void UnknownTimes(Fixture *f) {
    WCRAFExpiryCandidate *ticket = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:ticket];
    CHECK(batch.count == 1);
    for (NSNumber *time in @[@0, @(-1), @(NAN), @(INFINITY)]) {
        CHECK(![f.store commitExpiry:batch[0] lastMessageTime:time.doubleValue]);
        CHECK([f.store enqueueExpiry:@"alice" context:ticket.context
            lastMessageTime:time.doubleValue] == nil);
    }
    CHECK([f.store isHeld:@"alice" context:ticket.context]);
}

static void MultiCandidateBatch(Fixture *f) {
    WCRAFAccountContext *context = [f keep:@"alice"];
    [f keep:@"bob"];
    NSTimeInterval last = f.now - Day;
    f.now += 8 * Day;
    WCRAFExpiryCandidate *ticket = [f.store enqueueExpiry:@"alice" context:context lastMessageTime:last];
    CHECK(ticket != nil);
    CHECK([f.store enqueueExpiry:@"bob" context:context lastMessageTime:last] == nil);
    CHECK([f.store enqueueExpiry:@"alice" context:context lastMessageTime:last] == nil);
    NSArray *batch = [f.store takeBatch:ticket];
    CHECK(batch.count == 2);
    for (WCRAFExpiryCandidate *candidate in batch) {
        CHECK([f.store commitExpiry:candidate lastMessageTime:last]);
    }
    CHECK(![f.store hasAnyHeldForContext:context]);
    CHECK(![f.store commitExpiry:ticket lastMessageTime:last]);
}

static void RenewRevokesDetachedBatch(Fixture *f) {
    WCRAFExpiryCandidate *ticket = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:ticket];
    CHECK([f.store setHeld:YES username:@"alice" context:ticket.context]);
    f.now += 8 * Day;
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:1900000000.0]);
    CHECK([f.store isHeld:@"alice" context:ticket.context]);
}

static void SettingRoundtripRevokesBatch(Fixture *f) {
    WCRAFExpiryCandidate *ticket = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:ticket];
    CHECK([f.store setExpiryDays:0 context:ticket.context]);
    CHECK([f.store setExpiryDays:7 context:ticket.context]);
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:1900000000.0]);
}

static void CancelAllRevokesBatch(Fixture *f) {
    WCRAFExpiryCandidate *ticket = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:ticket];
    [f.store cancelPendingForContext:ticket.context];
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:1900000000.0]);
}

static void CancelOnePreservesOtherCandidate(Fixture *f) {
    WCRAFAccountContext *context = [f keep:@"alice"];
    [f keep:@"bob"];
    f.now += 8 * Day;
    WCRAFExpiryCandidate *ticket = [f.store enqueueExpiry:@"alice" context:context
        lastMessageTime:1900000000.0];
    [f.store enqueueExpiry:@"bob" context:context lastMessageTime:1900000000.0];
    NSArray *batch = [f.store takeBatch:ticket];
    CHECK(batch.count == 2);
    [f.store cancelExpiry:@"alice" context:context];
    for (WCRAFExpiryCandidate *candidate in batch) {
        BOOL committed = [f.store commitExpiry:candidate lastMessageTime:1900000000.0];
        CHECK(committed == [candidate.username isEqualToString:@"bob"]);
    }
    CHECK([f.store isHeld:@"alice" context:context]);
    CHECK(![f.store isHeld:@"bob" context:context]);
}

static void OldCallbackCannotDrainNewBatch(Fixture *f) {
    WCRAFExpiryCandidate *old = [f expiredTicket:@"alice"];
    [f.store cancelExpiry:@"alice" context:old.context];
    WCRAFExpiryCandidate *fresh = [f.store enqueueExpiry:@"alice" context:old.context
        lastMessageTime:1900000000.0];
    CHECK(fresh != nil);
    CHECK([f.store takeBatch:old].count == 0);
    CHECK([f.store takeBatch:fresh].count == 1);
}

static void SwitchingRevokesQueuedAndDetached(Fixture *f) {
    WCRAFExpiryCandidate *old = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:old];
    f.account = @"account-B";
    [f keep:@"alice"];
    CHECK([f.store takeBatch:old].count == 0);
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:1900000000.0]);
    f.account = @"account-A";
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:1900000000.0]);
    CHECK([f.store isHeld:@"alice" context:[f.store currentContext]]);
}

static void FreshMessagePreventsCommit(Fixture *f) {
    WCRAFExpiryCandidate *ticket = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:ticket];
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:f.now]);
    CHECK([f.store isHeld:@"alice" context:ticket.context]);
}

static void PersistenceRoundtrip(Fixture *f) {
    WCRAFAccountContext *old = [f keep:@"alice"];
    CHECK([f.store setExpiryDays:14 context:old]);
    WCRAFStateStore *reloaded = [f newStore];
    WCRAFAccountContext *current = [reloaded currentContext];
    CHECK([reloaded isHeld:@"alice" context:current]);
    CHECK([reloaded expiryDaysForContext:current] == 14);
    CHECK(![reloaded isCurrentContext:old]);
    CHECK([reloaded setHeld:NO username:@"alice" context:current]);
    NSDictionary *record = [f.defaults objectForKey:[Prefix stringByAppendingString:f.account]];
    CHECK([record[@"held"] count] == 0);
    CHECK([record[@"since"] count] == 0);
}

static void InvalidRecordsRemainUntouched(Fixture *f) {
    NSString *key = [Prefix stringByAppendingString:f.account];
    NSArray *invalid = @[
        @"broken",
        @{@"schema": @3, @"held": @[@"alice"], @"since": @{}, @"days": @7},
        @{@"schema": @2.5, @"held": @[], @"since": @{}, @"days": @7},
        @{@"schema": @2, @"held": @"alice", @"since": @{}, @"days": @7},
        @{@"schema": @2, @"held": @[@1], @"since": @{}, @"days": @7},
        @{@"schema": @2, @"held": @[], @"since": @[], @"days": @7},
        @{@"schema": @2, @"held": @[@"alice"], @"since": @{@"alice": @"yesterday"}, @"days": @7},
        @{@"schema": @2, @"held": @[], @"since": @{}, @"days": @(-1)},
        @{@"schema": @2, @"held": @[], @"since": @{}, @"days": @1.5}
    ];
    for (id record in invalid) {
        [f.defaults setObject:record forKey:key];
        WCRAFStateStore *store = [f newStore];
        CHECK([store currentContext] == nil);
        CHECK(![store setHeld:YES username:@"alice" context:[store currentContext]]);
        CHECK([[f.defaults objectForKey:key] isEqual:record]);
    }
}

static void MissingTimestampRepairedConservatively(Fixture *f) {
    NSString *key = [Prefix stringByAppendingString:f.account];
    [f.defaults setObject:@{@"schema": @2, @"held": @[@"alice"],
        @"since": @{@"orphan": @1000}, @"days": @7} forKey:key];
    WCRAFAccountContext *context = [f.store currentContext];
    [f.store reconcileTimestampsForContext:context];
    NSDictionary *record = [f.defaults objectForKey:key];
    CHECK([record[@"held"] isEqual:@[@"alice"]]);
    CHECK([record[@"since"][@"alice"] doubleValue] == f.now);
    CHECK(record[@"since"][@"orphan"] == nil);
    CHECK(![f.store isExpired:@"alice" context:context lastMessageTime:1000]);
}

static void LegacyImportRequiresCurrentAccount(Fixture *f) {
    [f.defaults setObject:@[@"alice", @"bob", @1, @""] forKey:LegacyNames];
    [f.defaults setInteger:3 forKey:LegacyDays];
    NSDictionary *before = [f.defaults persistentDomainForName:f.suite];
    WCRAFAccountContext *a = [f.store currentContext];
    CHECK([f.store importLegacyForContext:a]);
    CHECK([f.store isHeld:@"alice" context:a]);
    CHECK([f.store isHeld:@"bob" context:a]);
    CHECK([f.store expiryDaysForContext:a] == 3);
    CHECK(![f.store isExpired:@"alice" context:a lastMessageTime:1000]);
    CHECK([[f.defaults objectForKey:LegacyNames] isEqual:before[LegacyNames]]);
    CHECK([[f.defaults objectForKey:LegacyDays] isEqual:before[LegacyDays]]);
    f.account = @"account-B";
    CHECK(![f.store importLegacyForContext:a]);
    CHECK(![f.store hasAnyHeldForContext:[f.store currentContext]]);
}

static void ImportDoesNotRenewExistingHoldOrChangeSettings(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"alice"];
    NSTimeInterval since = f.now;
    CHECK([f.store setExpiryDays:14 context:a]);
    [f.defaults setObject:@[@"alice", @"bob"] forKey:LegacyNames];
    [f.defaults setInteger:3 forKey:LegacyDays];
    f.now += Day;
    CHECK([f.store importLegacyForContext:a]);
    NSDictionary *record = [f.defaults objectForKey:[Prefix stringByAppendingString:f.account]];
    CHECK([record[@"since"][@"alice"] doubleValue] == since);
    CHECK([record[@"since"][@"bob"] doubleValue] == f.now);
    CHECK([f.store expiryDaysForContext:a] == 14);
}

static void InvalidClockDoesNotWrite(Fixture *f) {
    WCRAFAccountContext *a = [f.store currentContext];
    for (NSNumber *time in @[@0, @(-1), @(NAN), @(INFINITY)]) {
        f.now = time.doubleValue;
        CHECK(![f.store setHeld:YES username:@"alice" context:a]);
    }
    CHECK([f.defaults objectForKey:[Prefix stringByAppendingString:f.account]] == nil);
}

static void ReadFailureDoesNotReplaceRecord(Fixture *f) {
    WCRAFAccountContext *old = [f keep:@"alice"];
    NSString *key = [Prefix stringByAppendingString:f.account];
    NSDictionary *before = [f.defaults objectForKey:key];
    WCRAFStateStore *reloaded = [f newStore];
    f.defaults.failRead = YES;
    CHECK([reloaded currentContext] == nil);
    CHECK(![reloaded setHeld:YES username:@"bob" context:old]);
    f.defaults.failRead = NO;
    CHECK([[f.defaults objectForKey:key] isEqual:before]);
}

static void WriteFailureQuarantinesCache(Fixture *f) {
    WCRAFAccountContext *context = [f keep:@"alice"];
    NSString *key = [Prefix stringByAppendingString:f.account];
    NSDictionary *before = [f.defaults objectForKey:key];
    f.defaults.failWrite = YES;
    CHECK(![f.store setHeld:YES username:@"bob" context:context]);
    CHECK([f.store currentContext] == nil);
    f.defaults.failWrite = NO;
    CHECK([[f.defaults objectForKey:key] isEqual:before]);
    WCRAFStateStore *reloaded = [f newStore];
    WCRAFAccountContext *fresh = [reloaded currentContext];
    CHECK([reloaded isHeld:@"alice" context:fresh]);
    CHECK(![reloaded isHeld:@"bob" context:fresh]);
}

static void SwitchInsideSaveDoesNotInstallOldCache(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"alice"];
    NSString *bKey = [Prefix stringByAppendingString:@"account-B"];
    NSDictionary *bRecord = @{@"schema": @2, @"held": @[@"bob"],
        @"since": @{@"bob": @(f.now)}, @"days": @14};
    [f.defaults setObject:bRecord forKey:bKey];
    __weak Fixture *weak = f;
    __block WCRAFAccountContext *b = nil;
    f.defaults.afterWrite = ^{
        weak.account = @"account-B";
        b = [weak.store currentContext];
    };
    CHECK(![f.store setHeld:YES username:@"carol" context:a]);
    CHECK(b != nil);
    CHECK([f.store isHeld:@"bob" context:b]);
    CHECK(![f.store isHeld:@"carol" context:b]);
    CHECK([f.store expiryDaysForContext:b] == 14);
    CHECK([[f.defaults objectForKey:bKey] isEqual:bRecord]);
    f.account = @"account-A";
    WCRAFAccountContext *again = [f.store currentContext];
    CHECK([f.store isHeld:@"carol" context:again]);
}

static void NestedWriteCannotSplitCacheAndDefaults(Fixture *f) {
    WCRAFAccountContext *context = [f keep:@"alice"];
    __weak Fixture *weak = f;
    __block BOOL nestedSucceeded = YES;
    f.defaults.afterWrite = ^{
        nestedSucceeded = [weak.store setHeld:YES username:@"bob" context:context];
    };
    CHECK([f.store setHeld:YES username:@"carol" context:context]);
    CHECK(!nestedSucceeded);
    CHECK(![f.store isHeld:@"bob" context:context]);
    CHECK([f.store isHeld:@"alice" context:context]);
    CHECK([f.store isHeld:@"carol" context:context]);
    NSDictionary *record = [f.defaults objectForKey:[Prefix stringByAppendingString:f.account]];
    NSSet *names = [NSSet setWithArray:record[@"held"]];
    CHECK([names isEqualToSet:([NSSet setWithArray:@[@"alice", @"carol"]])]);
}

static void ClockExceptionFailsClosed(Fixture *f) {
    WCRAFExpiryCandidate *ticket = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:ticket];
    NSDictionary *before = [f.defaults objectForKey:[Prefix stringByAppendingString:f.account]];
    f.clockThrows = YES;
    CHECK(![f.store setHeld:YES username:@"bob" context:ticket.context]);
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:1900000000.0]);
    [f.store reconcileTimestampsForContext:ticket.context];
    CHECK([[f.defaults objectForKey:[Prefix stringByAppendingString:f.account]] isEqual:before]);
}

static void OrphanOnlyTimestampIsReconciled(Fixture *f) {
    NSString *key = [Prefix stringByAppendingString:f.account];
    [f.defaults setObject:@{@"schema": @2, @"held": @[@"alice"],
        @"since": @{@"alice": @(f.now), @"orphan": @1000}, @"days": @7} forKey:key];
    WCRAFAccountContext *context = [f.store currentContext];
    [f.store reconcileTimestampsForContext:context];
    NSDictionary *record = [f.defaults objectForKey:key];
    CHECK([record[@"since"][@"alice"] doubleValue] == f.now);
    CHECK(record[@"since"][@"orphan"] == nil);
    CHECK([f.store isHeld:@"alice" context:context]);
}

static BOOL Activity(Fixture *f, NSString *name, WCRAFAccountContext *context,
                     NSTimeInterval message, NSInteger unread, BOOL grouped) {
    return [f.store isMessageActive:name context:context lastMessageTime:message
                       unreadCount:unread grouped:grouped];
}

static BOOL Observe(Fixture *f, NSString *name, WCRAFAccountContext *context,
                    NSTimeInterval message, NSInteger unread, BOOL grouped, BOOL home) {
    return [f.store observeMessageActivity:name context:context lastMessageTime:message
                            unreadCount:unread grouped:grouped homeVisible:home];
}

static void ActivityDoesNotSurfaceOldHistory(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK(!Activity(f, @"alice", context, f.now, 0, YES));
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(!Activity(f, @"alice", context, f.now - 1, 0, YES));
    CHECK(!Observe(f, @"alice", context, f.now - 1, 0, YES, YES));
    CHECK(Activity(f, @"alice", context, f.now, 0, YES));
    CHECK(![f.store isHeld:@"alice" context:context]);
}

static void ActivityCoversFirstAndSubsequentMessages(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    // The core is direction-neutral; the runtime accepts both scope 1 and 2.
    f.now += 10;
    CHECK(Activity(f, @"sent-to-friend", context, f.now, 0, YES));
    CHECK(Activity(f, @"received-from-room", context, f.now, 1, YES));
    CHECK(Observe(f, @"sent-to-friend", context, f.now, 0, YES, NO));
    CHECK(Observe(f, @"received-from-room", context, f.now, 1, YES, YES));
    CHECK(![f.store hasAnyHeldForContext:context]);
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
}

static void ActivityQueriesDoNotRenewOrWrite(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    NSDictionary *before = [f.defaults persistentDomainForName:f.suite];
    f.now += 899;
    for (int i = 0; i < 50; i++) {
        CHECK([f.store enableMessageActivityForContext:context]);
        CHECK(Activity(f, @"alice", context, message, 0, YES));
        CHECK(!Observe(f, @"alice", context, message, 0, YES, YES));
    }
    CHECK([[f.defaults persistentDomainForName:f.suite] isEqual:before]);
    f.now++;
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void ActivityPersistsAcrossRestart(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    f.now += 100;
    f.store = [f newStore];
    context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == message + 900);
    CHECK(!Activity(f, @"bob", context, message - 1, 0, YES));
    f.now = message + 900;
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void ActivityReturnWaitsForNewMessage(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    f.now += 10.75;
    NSTimeInterval message = floor(f.now);
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK([f.store setHeld:NO username:@"alice" context:context]);
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
    CHECK(![f.store hasTrackedMessageActivity:@"alice" context:context]);
    CHECK(Activity(f, @"bob", context, message, 0, YES));
    f.store = [f newStore];
    context = [f.store currentContext];
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
    f.now += 1;
    CHECK(Activity(f, @"alice", context, floor(f.now), 0, YES));
}

static void ReadGraceStartsAfterReturningHome(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, NO));
    f.now += Day;
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == f.now + 900);
    f.now += 899;
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    f.now++;
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void UnreadNeverStartsReturnCountdown(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now - Day;
    CHECK(Activity(f, @"room", context, message, 3, YES));
    CHECK(Observe(f, @"room", context, message, 3, YES, YES));
    f.now += 100 * Day;
    CHECK(Activity(f, @"room", context, message, 3, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
    CHECK(Observe(f, @"room", context, message, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == f.now + 900);
}

static void NewMessageResetsReadGrace(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval first = f.now;
    CHECK(Observe(f, @"room", context, first, 0, YES, YES));
    f.now += 899;
    NSTimeInterval second = f.now;
    CHECK(Activity(f, @"room", context, second, 1, YES));
    CHECK(Observe(f, @"room", context, second, 1, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
    f.now += 1000;
    CHECK(Activity(f, @"room", context, second, 1, YES));
    CHECK(Observe(f, @"room", context, second, 0, YES, NO) == NO);
    CHECK(Observe(f, @"room", context, second, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == f.now + 900);
}

static void UnknownReadCountPreservesActivity(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    f.now += 900;
    CHECK(Activity(f, @"alice", context, message, -1, YES));
    CHECK(Observe(f, @"alice", context, message, -1, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
    f.now += 1000;
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == f.now + 900);
}

static void UngroupedConversationsNeverAutoReturn(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, NO, YES));
    f.now += 100 * Day;
    CHECK(Activity(f, @"alice", context, message, 0, NO));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
    // Explicit assignment/return may still collect it into the selected group.
    CHECK([f.store setHeld:NO username:@"alice" context:context]);
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void ManualHoldIsIndependentOfReadGrace(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK([f.store setHeld:YES username:@"alice" context:context]);
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
    f.now += 900;
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
    CHECK([f.store isHeld:@"alice" context:context]);
    CHECK(![f.store isExpired:@"alice" context:context lastMessageTime:message]);
    CHECK([f.store setExpiryDays:0 context:context]);
    f.now += 100 * Day;
    CHECK(![f.store isExpired:@"alice" context:context lastMessageTime:message]);
    CHECK([f.store setHeld:NO username:@"alice" context:context]);
    CHECK(![f.store isHeld:@"alice" context:context]);
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void GraceSettingsPersistAndDoNotChangeHoldDays(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK([f.store readGraceMinutesForContext:context] == 15);
    CHECK([f.store setExpiryDays:14 context:context]);
    CHECK([f.store setReadGraceMinutes:5 context:context]);
    CHECK(Observe(f, @"alice", context, f.now, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == f.now + 300);
    CHECK([f.store expiryDaysForContext:context] == 14);
    for (NSNumber *minutes in @[@(-1), @0, @1, @10, @60]) {
        CHECK(![f.store setReadGraceMinutes:minutes.integerValue context:context]);
    }
    f.store = [f newStore];
    context = [f.store currentContext];
    CHECK([f.store readGraceMinutesForContext:context] == 5);
    CHECK([f.store setReadGraceMinutes:30 context:context]);
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == f.now + 1800);
}

static void DeadlineSelectsNearestNonHeldConversation(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Observe(f, @"alice", context, f.now, 0, YES, YES));
    NSTimeInterval firstDeadline = f.now + 900;
    f.now += 10;
    CHECK(Observe(f, @"bob", context, f.now, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == firstDeadline);
    CHECK([f.store setHeld:YES username:@"alice" context:context]);
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == firstDeadline + 10);
    CHECK([f.store setHeld:YES username:@"bob" context:context]);
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
}

static void ExpiredActivityDoesNotResurfaceOldMessage(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    f.now += 900;
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK(![f.store hasMessageActivityForContext:context]);
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
    CHECK(!Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK(Activity(f, @"alice", context, f.now, 1, YES));
}

static void StaleObservationCannotEraseNewerActivity(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval first = f.now;
    CHECK(Observe(f, @"alice", context, first, 0, YES, YES));
    f.now += 10;
    CHECK(Observe(f, @"alice", context, f.now, 1, YES, YES));
    CHECK(!Observe(f, @"alice", context, first, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
}

static void ReturnRejectsQueuedOldObservation(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK([f.store setHeld:NO username:@"alice" context:context]);
    CHECK(!Observe(f, @"alice", context, message, 1, YES, YES));
    CHECK(![f.store hasMessageActivityForContext:context]);
}

static void ActivityAccountIsolation(Fixture *f) {
    WCRAFAccountContext *a = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:a]);
    NSTimeInterval message = f.now;
    CHECK([f.store setHeld:NO username:@"alice" context:a]);
    f.account = @"account-B";
    f.now += Day;
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:b]);
    CHECK(!Activity(f, @"alice", b, message, 0, YES));
    CHECK(Activity(f, @"alice", b, f.now, 0, YES));
    CHECK(![f.store enableMessageActivityForContext:a]);
    CHECK(!Activity(f, @"alice", a, f.now, 0, YES));
    CHECK(!Observe(f, @"alice", a, f.now, 0, YES, YES));
    CHECK(![f.store setReadGraceMinutes:5 context:a]);
    CHECK(![f.store setHeld:NO username:@"alice" context:a]);
    f.account = @"account-A";
    WCRAFAccountContext *again = [f.store currentContext];
    CHECK(!Activity(f, @"alice", again, message, 0, YES));
    CHECK(Activity(f, @"alice", again, f.now, 0, YES));
}

static void ActivityRejectsUnknownFutureAndInvalidClock(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    for (NSNumber *time in @[@0, @(-1), @(NAN), @(INFINITY), @(message + 1)]) {
        CHECK(!Activity(f, @"alice", context, time.doubleValue, 0, YES));
        CHECK(!Observe(f, @"alice", context, time.doubleValue, 0, YES, YES));
    }
    CHECK(!Activity(f, @"", context, message, 0, YES));
    NSDictionary *before = [f.defaults persistentDomainForName:f.suite];
    f.clockThrows = YES;
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
    CHECK(!Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK(![f.store setHeld:NO username:@"alice" context:context]);
    CHECK([[f.defaults persistentDomainForName:f.suite] isEqual:before]);
}

static void ActivityEnableFailurePreservesDefaults(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    NSTimeInterval now = f.now;
    for (NSNumber *time in @[@0, @(NAN), @(INFINITY)]) {
        f.now = time.doubleValue;
        CHECK(![f.store enableMessageActivityForContext:context]);
    }
    CHECK([f.defaults persistentDomainForName:f.suite].count == 0);
    f.now = now;
    f.defaults.failWrite = YES;
    CHECK(![f.store enableMessageActivityForContext:context]);
    CHECK([f.store currentContext] == nil);
    f.defaults.failWrite = NO;
    CHECK([f.defaults persistentDomainForName:f.suite].count == 0);
}

static void ActivityEnableDoesNotLoseManualState(Fixture *f) {
    WCRAFAccountContext *context = [f keep:@"alice"];
    CHECK([f.store setExpiryDays:14 context:context]);
    NSDictionary *before = [f.defaults objectForKey:[Prefix stringByAppendingString:f.account]];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSDictionary *after = [f.defaults objectForKey:[Prefix stringByAppendingString:f.account]];
    CHECK([after[@"held"] isEqual:before[@"held"]]);
    CHECK([after[@"since"] isEqual:before[@"since"]]);
    CHECK([after[@"days"] isEqual:before[@"days"]]);
    CHECK([f.store isHeld:@"alice" context:context]);
}

static void ActivityInvalidRecordsRemainUntouched(Fixture *f) {
    NSString *key = [Prefix stringByAppendingString:f.account];
    WCRAFAccountContext *old = [f.store currentContext];
    NSArray *invalid = @[
        @{@"activitySince": @0, @"returned": @{}},
        @{@"activitySince": @"NaN", @"returned": @{}},
        @{@"activitySince": @(f.now), @"returned": @[]},
        @{@"activitySince": @(f.now), @"returned": @{@"alice": @(-1)}},
        @{@"activitySince": @(f.now), @"returned": @{@"": @(f.now)}},
        @{@"returned": @{}},
        @{@"activitySince": @(f.now), @"returned": @{}, @"activity": @[]},
        @{@"activitySince": @(f.now), @"returned": @{}, @"activity": @{@"alice": @1}},
        @{@"activitySince": @(f.now), @"returned": @{}, @"activity":
            @{@"alice": @{@"message": @0, @"readAt": @0}}},
        @{@"activitySince": @(f.now), @"returned": @{}, @"activity":
            @{@"alice": @{@"message": @(f.now), @"readAt": @(-1)}}},
        @{@"graceMinutes": @0}, @{@"graceMinutes": @1.5}, @{@"graceMinutes": @"15"}
    ];
    for (NSDictionary *fields in invalid) {
        NSMutableDictionary *record = [@{@"schema": @2, @"held": @[],
            @"since": @{}, @"days": @7} mutableCopy];
        [record addEntriesFromDictionary:fields];
        [f.defaults setObject:record forKey:key];
        f.store = [f newStore];
        CHECK([f.store currentContext] == nil);
        CHECK(![f.store enableMessageActivityForContext:old]);
        CHECK([[f.defaults objectForKey:key] isEqual:record]);
    }
}

static void ActivityEnableSwitchAndNestedWrite(Fixture *f) {
    WCRAFAccountContext *a = [f.store currentContext];
    __weak Fixture *weak = f;
    __block BOOL nestedSucceeded = YES;
    f.defaults.afterWrite = ^{
        nestedSucceeded = [weak.store enableMessageActivityForContext:a];
        weak.account = @"account-B";
        CHECK([weak.store currentContext] != nil);
    };
    CHECK(![f.store enableMessageActivityForContext:a]);
    CHECK(!nestedSucceeded);
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK(!Activity(f, @"alice", b, f.now, 0, YES));
    CHECK([f.store enableMessageActivityForContext:b]);
    f.account = @"account-A";
    CHECK(Activity(f, @"alice", [f.store currentContext], f.now, 0, YES));
}

static void ActivityObservationFailureQuarantinesCache(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSDictionary *before = [f.defaults persistentDomainForName:f.suite];
    f.defaults.failWrite = YES;
    CHECK(!Observe(f, @"alice", context, f.now, 0, YES, YES));
    CHECK([f.store currentContext] == nil);
    f.defaults.failWrite = NO;
    CHECK([[f.defaults persistentDomainForName:f.suite] isEqual:before]);
}

static void ActivitySameMessageUnreadResetsCountdown(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    f.now += 800;
    CHECK(Observe(f, @"alice", context, message, 1, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == 0);
    f.now += 200;
    CHECK(Activity(f, @"alice", context, message, 1, YES));
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK([f.store nextMessageActivityDeadlineForContext:context] == f.now + 900);
}

int main(int argc, const char *argv[]) {
    if (argc > 2) return 2;
    struct Test { const char *name; void (*run)(Fixture *); } tests[] = {
#define TEST(name) {#name, name}
        TEST(NoAutomaticLegacyMigration), TEST(AccountIsolation), TEST(NilAccount),
        TEST(ResolverFailure), TEST(ExpiryBoundaries), TEST(UnknownTimes),
        TEST(MultiCandidateBatch), TEST(RenewRevokesDetachedBatch),
        TEST(SettingRoundtripRevokesBatch), TEST(CancelAllRevokesBatch),
        TEST(CancelOnePreservesOtherCandidate), TEST(OldCallbackCannotDrainNewBatch),
        TEST(SwitchingRevokesQueuedAndDetached), TEST(FreshMessagePreventsCommit),
        TEST(PersistenceRoundtrip), TEST(InvalidRecordsRemainUntouched),
        TEST(MissingTimestampRepairedConservatively), TEST(LegacyImportRequiresCurrentAccount),
        TEST(ImportDoesNotRenewExistingHoldOrChangeSettings), TEST(InvalidClockDoesNotWrite),
        TEST(ReadFailureDoesNotReplaceRecord), TEST(WriteFailureQuarantinesCache),
        TEST(SwitchInsideSaveDoesNotInstallOldCache), TEST(NestedWriteCannotSplitCacheAndDefaults),
        TEST(ClockExceptionFailsClosed), TEST(OrphanOnlyTimestampIsReconciled),
        TEST(ActivityDoesNotSurfaceOldHistory), TEST(ActivityCoversFirstAndSubsequentMessages),
        TEST(ActivityQueriesDoNotRenewOrWrite), TEST(ActivityPersistsAcrossRestart),
        TEST(ActivityReturnWaitsForNewMessage), TEST(ReadGraceStartsAfterReturningHome),
        TEST(UnreadNeverStartsReturnCountdown), TEST(NewMessageResetsReadGrace),
        TEST(UnknownReadCountPreservesActivity), TEST(UngroupedConversationsNeverAutoReturn),
        TEST(ManualHoldIsIndependentOfReadGrace), TEST(GraceSettingsPersistAndDoNotChangeHoldDays),
        TEST(DeadlineSelectsNearestNonHeldConversation), TEST(ExpiredActivityDoesNotResurfaceOldMessage),
        TEST(StaleObservationCannotEraseNewerActivity), TEST(ReturnRejectsQueuedOldObservation),
        TEST(ActivityAccountIsolation), TEST(ActivityRejectsUnknownFutureAndInvalidClock),
        TEST(ActivityEnableFailurePreservesDefaults), TEST(ActivityEnableDoesNotLoseManualState),
        TEST(ActivityInvalidRecordsRemainUntouched), TEST(ActivityEnableSwitchAndNestedWrite),
        TEST(ActivityObservationFailureQuarantinesCache), TEST(ActivitySameMessageUnreadResetsCountdown)
#undef TEST
    };
    int failed = 0;
    size_t count = sizeof(tests) / sizeof(tests[0]);
    for (size_t i = 0; i < count; i++) {
        @autoreleasepool {
            Fixture *fixture = [Fixture new];
            @try {
                tests[i].run(fixture);
                printf("PASS %s\n", tests[i].name);
            } @catch (NSException *exception) {
                failed++;
                fprintf(stderr, "FAIL %s: %s\n", tests[i].name, exception.reason.UTF8String);
            } @finally {
                [fixture clean];
            }
        }
    }
    printf("%zu tests, %d failures (native Foundation; not UIKit/device tests)\n", count, failed);
    if (argc == 2) {
        @autoreleasepool {
            NSError *error = nil;
            NSDictionary *report = @{
                @"passed": (failed == 0 ? @YES : @NO), @"tests_run": @(count), @"failures": @(failed),
                @"scope": @"Native Foundation tests of WCRAFStateStore; not UIKit/device tests",
                @"ios_runtime_tested": @NO
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:report
                options:NSJSONWritingPrettyPrinted error:&error];
            NSString *path = [NSString stringWithUTF8String:argv[1]];
            if (!json || ![json writeToFile:path options:NSDataWritingAtomic error:&error]) {
                fprintf(stderr, "Cannot write native test report: %s\n", error.description.UTF8String);
                return 1;
            }
        }
    }
    return failed ? 1 : 0;
}
