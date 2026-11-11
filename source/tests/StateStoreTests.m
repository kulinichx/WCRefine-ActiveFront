#import <Foundation/Foundation.h>
#import <math.h>
#import <objc/runtime.h>
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

@interface NativeNotifyState : NSObject
@property(nonatomic) NSInteger value;
@property(nonatomic) BOOL throwRead;
@end
@implementation NativeNotifyState
@end

// Real typed Objective-C methods exercise NSInvocation's native result widths.
#define NATIVE_NOTIFY_READER(className, nativeType) \
@interface className : NativeNotifyState \
- (nativeType)isChatStatusNotifyOpen; \
@end \
@implementation className \
- (nativeType)isChatStatusNotifyOpen { \
    if (self.throwRead) [NSException raise:@"ReadFailure" format:@"fixture"]; \
    return (nativeType)self.value; \
} \
@end
NATIVE_NOTIFY_READER(NotifyBoolReader, BOOL)
NATIVE_NOTIFY_READER(NotifyCharReader, signed char)
NATIVE_NOTIFY_READER(NotifyUCharReader, unsigned char)
NATIVE_NOTIFY_READER(NotifyShortReader, short)
NATIVE_NOTIFY_READER(NotifyUShortReader, unsigned short)
NATIVE_NOTIFY_READER(NotifyIntReader, int)
NATIVE_NOTIFY_READER(NotifyUIntReader, unsigned int)
NATIVE_NOTIFY_READER(NotifyLongReader, long)
NATIVE_NOTIFY_READER(NotifyULongReader, unsigned long)
NATIVE_NOTIFY_READER(NotifyLongLongReader, long long)
NATIVE_NOTIFY_READER(NotifyULongLongReader, unsigned long long)
NATIVE_NOTIFY_READER(NotifyFloatReader, double)
#undef NATIVE_NOTIFY_READER

@interface NativeNotifyManager : NSObject
@property(nonatomic) NSUInteger calls;
@property(nonatomic) long long response;
@property(nonatomic) BOOL updatesState;
@property(nonatomic) BOOL throwWrite;
@property(nonatomic) BOOL notify;
@property(nonatomic) BOOL sync;
@property(nonatomic, strong) id receivedContact;
- (void)recordContact:(NativeNotifyState *)contact notify:(BOOL)notify sync:(BOOL)sync;
@end
@implementation NativeNotifyManager
- (instancetype)init {
    self = [super init];
    if (self) { _response = 1; _updatesState = YES; }
    return self;
}
- (void)recordContact:(NativeNotifyState *)contact notify:(BOOL)notify sync:(BOOL)sync {
    self.calls++;
    self.receivedContact = contact;
    self.notify = notify;
    self.sync = sync;
    if (self.throwWrite) [NSException raise:@"WriteFailure" format:@"fixture"];
    if (self.updatesState) contact.value = notify ? 1 : 0;
}
@end

#define NATIVE_NOTIFY_WRITER(className, resultType, statusType, syncType) \
@interface className : NativeNotifyManager \
- (resultType)ChangeNotifyStatus:(id)contact withStatus:(statusType)notify sync:(syncType)sync; \
@end \
@implementation className \
- (resultType)ChangeNotifyStatus:(id)contact withStatus:(statusType)notify sync:(syncType)sync { \
    [self recordContact:contact notify:notify != 0 sync:sync != 0]; \
    return (resultType)self.response; \
} \
@end
NATIVE_NOTIFY_WRITER(NotifyBoolWriter, BOOL, BOOL, BOOL)
NATIVE_NOTIFY_WRITER(NotifyCharWriter, signed char, signed char, unsigned char)
NATIVE_NOTIFY_WRITER(NotifyShortWriter, short, short, unsigned short)
NATIVE_NOTIFY_WRITER(NotifyIntWriter, int, int, unsigned int)
NATIVE_NOTIFY_WRITER(NotifyLongWriter, long, long, unsigned long)
NATIVE_NOTIFY_WRITER(NotifyLongLongWriter, long long, long long, unsigned long long)
NATIVE_NOTIFY_WRITER(NotifyUnsignedWriter, unsigned long long, unsigned char, unsigned long long)
NATIVE_NOTIFY_WRITER(NotifyFloatResultWriter, double, BOOL, BOOL)
NATIVE_NOTIFY_WRITER(NotifyFloatFlagWriter, int, double, BOOL)
#undef NATIVE_NOTIFY_WRITER

@interface NotifyVoidWriter : NativeNotifyManager
- (void)ChangeNotifyStatus:(id)contact withStatus:(int)notify sync:(long long)sync;
@end
@implementation NotifyVoidWriter
- (void)ChangeNotifyStatus:(id)contact withStatus:(int)notify sync:(long long)sync {
    [self recordContact:contact notify:notify != 0 sync:sync != 0];
}
@end

static int QualifiedNotifyRead(id self, __unused SEL cmd) {
    return (int)[(NativeNotifyState *)self value];
}
static int QualifiedNotifyWrite(id self, __unused SEL cmd, id contact, int notify, unsigned long long sync) {
    [(NativeNotifyManager *)self recordContact:contact notify:notify != 0 sync:sync != 0];
    return (int)[(NativeNotifyManager *)self response];
}

// Real defaults storage with deterministic failures/reentrant callbacks.
@interface FaultDefaults : NSUserDefaults
@property(nonatomic) BOOL failRead;
@property(nonatomic) BOOL failWrite;
@property(nonatomic) NSUInteger writeCount;
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
    self.writeCount++;
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

@interface NotifyOperationFixture : NSObject
@property(nonatomic, strong) Fixture *fixture;
@property(nonatomic, strong) WCRAFAccountContext *context;
@property(nonatomic, strong) WCRAFNotifyCoordinator *coordinator;
@property(nonatomic, strong) NotifyIntReader *contact;
@property(nonatomic, strong) NotifyIntWriter *manager;
@property(nonatomic, strong) NSMutableArray *scheduled;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *outcomes;
@property(nonatomic) NSUInteger reads;
@property(nonatomic) NSUInteger pendingCount;
@property(nonatomic) BOOL foreground;
- (instancetype)initWithFixture:(Fixture *)fixture;
- (void)request:(BOOL)notify;
- (void)runNext;
- (void)observe;
@end

@implementation NotifyOperationFixture
- (instancetype)initWithFixture:(Fixture *)fixture {
    self = [super init];
    if (self) {
        _fixture = fixture;
        _context = [fixture.store currentContext];
        _contact = [NotifyIntReader new];
        _contact.value = 1;
        _manager = [NotifyIntWriter new];
        _manager.updatesState = NO;
        _foreground = YES;
        _scheduled = [NSMutableArray array];
        _outcomes = [NSMutableArray array];
        __weak NotifyOperationFixture *weakSelf = self;
        _coordinator = [[WCRAFNotifyCoordinator alloc]
            initWithValidator:^BOOL(WCRAFAccountContext *context) {
                NotifyOperationFixture *current = weakSelf;
                return current.foreground && [current.fixture.store isCurrentContext:context];
            } clock:^NSTimeInterval {
                return weakSelf.fixture.now;
            } scheduler:^(NSTimeInterval delay, void (^confirm)(void)) {
                [weakSelf.scheduled addObject:@{@"delay": @(delay), @"confirm": [confirm copy]}];
            }];
    }
    return self;
}
- (void)request:(BOOL)notify {
    __weak NotifyOperationFixture *weakSelf = self;
    [self.coordinator changeUsername:@"room@chatroom" context:self.context notify:notify
        read:^NSInteger {
            weakSelf.reads++;
            return WCRAFReadNativeNotifyOpen(weakSelf.contact);
        } write:^WCRAFNativeNotifyResult {
            return WCRAFInvokeNativeNotify(weakSelf.manager, weakSelf.contact, notify);
        } pending:^{
            weakSelf.pendingCount++;
        } completion:^(WCRAFNotifyOutcome outcome) {
            [weakSelf.outcomes addObject:@(outcome)];
        }];
}
- (void)runNext {
    CHECK(self.scheduled.count > 0);
    NSDictionary *entry = self.scheduled.firstObject;
    void (^confirm)(void) = entry[@"confirm"];
    [self.scheduled removeObjectAtIndex:0];
    self.fixture.now += [entry[@"delay"] doubleValue];
    confirm();
}
- (void)observe {
    self.fixture.now += 0.5;
    [self.coordinator observeUsername:@"room@chatroom" context:self.context];
}
@end

static void NoAutomaticLegacyMigration(Fixture *f) {
    [f.defaults setObject:@[@"alice"] forKey:LegacyNames];
    [f.defaults setInteger:3 forKey:LegacyDays];
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK(![f.store isHeld:@"alice" context:context]);
    CHECK([f.store expiryDaysForContext:context] == 3);
    CHECK([f.defaults objectForKey:[Prefix stringByAppendingString:f.account]] == nil);
    CHECK([[f.defaults objectForKey:LegacyNames] isEqual:@[@"alice"]]);
}

static void AccountIsolation(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"same-contact"];
    CHECK([f.store setExpiryDays:3 context:a]);
    f.account = @"account-B";
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK(![f.store isHeld:@"same-contact" context:b]);
    CHECK([f.store expiryDaysForContext:b] == 3);
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
    CHECK([f.store hasTrackedMessageActivity:@"sent-to-friend" context:context]);
}

static void ActivityQueriesDoNotRenewOrWrite(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 1, YES, YES));
    NSDictionary *before = [f.defaults persistentDomainForName:f.suite];
    NSUInteger writes = f.defaults.writeCount;
    f.now += 59;
    for (int i = 0; i < 1000; i++) {
        CHECK([f.store enableMessageActivityForContext:context]);
        CHECK(Activity(f, @"alice", context, message, 1, YES));
        CHECK(![f.store needsMessageActivityObservation:@"alice" context:context
            lastMessageTime:message unreadCount:1 grouped:YES homeVisible:YES]);
        CHECK(!Observe(f, @"alice", context, message, 1, YES, YES));
    }
    CHECK([[f.defaults persistentDomainForName:f.suite] isEqual:before]);
    CHECK(f.defaults.writeCount == writes);
    f.now++;
    CHECK(Activity(f, @"alice", context, message, 1, YES));
}

static void ActivityPersistsAcrossRestart(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, NO));
    f.now += 20;
    f.store = [f newStore];
    context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK([f.store hasTrackedMessageActivity:@"alice" context:context]);
    CHECK(!Activity(f, @"bob", context, message - 1, 0, YES));
    f.now = message + 60;
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
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

static void ReadReturnsImmediatelyAfterReturningHome(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, NO));
    f.now += Day;
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK([f.store hasTrackedMessageActivity:@"alice" context:context]);
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
    CHECK(![f.store hasTrackedMessageActivity:@"alice" context:context]);
}

static void UnreadStaysUntilConfirmedRead(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now - Day;
    CHECK(Activity(f, @"room", context, message, 3, YES));
    CHECK(Observe(f, @"room", context, message, 3, YES, YES));
    f.now += 100 * Day;
    CHECK(Activity(f, @"room", context, message, 3, YES));
    CHECK(!Observe(f, @"room", context, message, 3, YES, YES));
    CHECK(Observe(f, @"room", context, message, 0, YES, YES));
    CHECK(!Activity(f, @"room", context, message, 0, YES));
}

static void NewMessageAfterReadReturnsToHome(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval first = f.now;
    CHECK(Observe(f, @"room", context, first, 0, YES, YES));
    f.now += 59;
    NSTimeInterval second = f.now;
    CHECK(Activity(f, @"room", context, second, 1, YES));
    CHECK(Observe(f, @"room", context, second, 1, YES, YES));
    CHECK(![f.store isMessageReturnSuppressed:@"room" context:context lastMessageTime:second]);
    f.now += 1000;
    CHECK(Activity(f, @"room", context, second, 1, YES));
    CHECK(Observe(f, @"room", context, second, 0, YES, NO) == NO);
    CHECK(Observe(f, @"room", context, second, 0, YES, YES));
    CHECK(!Activity(f, @"room", context, second, 0, YES));
}

static void UnknownReadCountPreservesActivity(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, -1, YES, YES));
    f.now += 60;
    CHECK(Activity(f, @"alice", context, message, -1, YES));
    CHECK(!Observe(f, @"alice", context, message, -1, YES, YES));
    f.now += 1000;
    CHECK(Activity(f, @"alice", context, message, 0, YES));
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void UngroupedConversationsNeverAutoReturn(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, NO, YES));
    f.now += 100 * Day;
    CHECK(Activity(f, @"alice", context, message, 0, NO));
    CHECK(!Observe(f, @"alice", context, message, 0, NO, YES));
    // Explicit assignment/return may still collect it into the selected group.
    CHECK([f.store setHeld:NO username:@"alice" context:context]);
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void ManualHoldSurvivesConfirmedRead(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 1, YES, YES));
    CHECK([f.store setHeld:YES username:@"alice" context:context]);
    CHECK(!Observe(f, @"alice", context, message, 0, YES, YES));
    f.now += 60;
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

static void ReturnedMessageSuppressionSurvivesRestart(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK([f.store setExpiryDays:14 context:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 7, YES, YES));
    CHECK([f.store setHeld:NO username:@"alice" context:context]);
    f.store = [f newStore];
    context = [f.store currentContext];
    CHECK([f.store expiryDaysForContext:context] == 14);
    CHECK([f.store isMessageReturnSuppressed:@"alice" context:context lastMessageTime:message]);
    CHECK(!Activity(f, @"alice", context, message, 7, YES));
    CHECK(!Observe(f, @"alice", context, message, 7, YES, YES));
    f.now++;
    CHECK(![f.store isMessageReturnSuppressed:@"alice" context:context lastMessageTime:f.now]);
    CHECK(Activity(f, @"alice", context, f.now, 8, YES));
}

static void ReadReturnDoesNotChangeOtherConversation(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Observe(f, @"alice", context, f.now, 1, YES, YES));
    NSTimeInterval first = f.now;
    f.now += 10;
    CHECK(Observe(f, @"bob", context, f.now, 1, YES, YES));
    CHECK(Observe(f, @"alice", context, first, 0, YES, YES));
    CHECK(!Activity(f, @"alice", context, first, 0, YES));
    CHECK(Activity(f, @"bob", context, f.now, 1, YES));
    CHECK([f.store setHeld:YES username:@"bob" context:context]);
    CHECK(!Observe(f, @"bob", context, f.now, 0, YES, YES));
    CHECK([f.store isHeld:@"bob" context:context]);
}

static void ReadActivityDoesNotResurfaceOldMessage(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 1, YES, YES));
    f.now += 60;
    CHECK(Activity(f, @"alice", context, message, 0, YES));
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
    CHECK(Observe(f, @"alice", context, first, 0, YES, NO));
    f.now += 10;
    CHECK(Observe(f, @"alice", context, f.now, 1, YES, YES));
    CHECK(!Observe(f, @"alice", context, first, 0, YES, YES));
    CHECK(Activity(f, @"alice", context, f.now, 1, YES));
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
    CHECK(![f.store isMessageReturnSuppressed:@"alice" context:a lastMessageTime:message]);
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

static void UnreadTransitionCannotReturnWithoutHome(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK(Observe(f, @"alice", context, message, 0, YES, NO));
    f.now += 20;
    CHECK(!Observe(f, @"alice", context, message, 1, YES, YES));
    f.now += 200;
    CHECK(Activity(f, @"alice", context, message, 1, YES));
    CHECK(Observe(f, @"alice", context, message, 0, YES, YES));
    CHECK(!Activity(f, @"alice", context, message, 0, YES));
}

static void AutomaticActivityPolicyHonorsMuteAndFold(Fixture *f) {
    (void)f;
    CHECK(WCRAFAllowsAutomaticActivity(1, -1, 0));
    CHECK(!WCRAFAllowsAutomaticActivity(1, 1, -1));
    CHECK(WCRAFAllowsAutomaticActivity(2, 0, 0));
    CHECK(!WCRAFAllowsAutomaticActivity(2, 1, 0));
    CHECK(!WCRAFAllowsAutomaticActivity(2, -1, 0));
    CHECK(!WCRAFAllowsAutomaticActivity(2, 0, 1));
    CHECK(!WCRAFAllowsAutomaticActivity(1, 0, 1));
    CHECK(!WCRAFAllowsAutomaticActivity(0, 0, 0));
    CHECK(!WCRAFAllowsAutomaticActivity(3, 0, 0));
}

static void DirtyObservationTracksOnlyTransitions(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK([f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:message unreadCount:1 grouped:YES homeVisible:YES]);
    CHECK(Observe(f, @"room", context, message, 1, YES, YES));
    CHECK(![f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:message unreadCount:2 grouped:YES homeVisible:YES]);
    CHECK(![f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:message unreadCount:0 grouped:YES homeVisible:NO]);
    CHECK([f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:message unreadCount:0 grouped:YES homeVisible:YES]);
    CHECK(Observe(f, @"room", context, message, 0, YES, YES));
    f.now += 60;
    CHECK(!Observe(f, @"room", context, message, 0, YES, YES));
    CHECK(![f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:message unreadCount:0 grouped:YES homeVisible:YES]);
}

static void LegacyGraceRecordsReturnWithoutCountdown(Fixture *f) {
    NSString *key = [Prefix stringByAppendingString:f.account];
    for (NSNumber *minutes in @[@1, @3, @5, @15, @30]) {
        NSDictionary *record = @{@"schema": @2, @"held": @[@"alice"],
            @"since": @{@"alice": @(f.now)}, @"days": @14,
            @"graceMinutes": minutes, @"activitySince": @(f.now - 50),
            @"returned": @{}, @"activity": @{
                @"room": @{@"message": @(f.now - 40), @"readAt": @(f.now - 30)}}};
        [f.defaults setObject:record forKey:key];
        f.store = [f newStore];
        WCRAFAccountContext *context = [f.store currentContext];
        CHECK(context != nil);
        CHECK([f.store isHeld:@"alice" context:context]);
        CHECK([f.store expiryDaysForContext:context] == 14);
        CHECK(Activity(f, @"room", context, f.now - 40, 0, YES));
        CHECK([[f.defaults objectForKey:key] isEqual:record]); // Load is read-only.
        CHECK([f.store enableMessageActivityForContext:context]);
        CHECK(Observe(f, @"room", context, f.now - 40, 0, YES, YES));
        CHECK(!Activity(f, @"room", context, f.now - 40, 0, YES));
        CHECK([f.defaults objectForKey:key][@"graceMinutes"] == nil);
        f.store = [f newStore];
        context = [f.store currentContext];
        CHECK([f.store isHeld:@"alice" context:context]);
        CHECK([f.store expiryDaysForContext:context] == 14);
        CHECK(!Activity(f, @"room", context, f.now - 40, 0, YES));
    }
}

static void StableReturnedQueriesDoNotWrite(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSTimeInterval message = f.now;
    CHECK([f.store setHeld:NO username:@"room" context:context]);
    NSUInteger writes = f.defaults.writeCount;
    f.now += Day;
    for (int i = 0; i < 1000; i++) {
        CHECK([f.store isMessageReturnSuppressed:@"room" context:context lastMessageTime:message]);
        CHECK(!Activity(f, @"room", context, message, 3, YES));
        CHECK(![f.store needsMessageActivityObservation:@"room" context:context
            lastMessageTime:message unreadCount:3 grouped:YES homeVisible:YES]);
        CHECK(!Observe(f, @"room", context, message, 3, YES, YES));
    }
    CHECK(f.defaults.writeCount == writes);
}

static void DiscardActivityPreservesHoldAndAllowsFutureMessages(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Observe(f, @"room", context, f.now, 1, YES, YES));
    CHECK([f.store setHeld:YES username:@"room" context:context]);
    CHECK([f.store discardMessageActivity:@"room" context:context]);
    CHECK(![f.store hasTrackedMessageActivity:@"room" context:context]);
    CHECK([f.store isHeld:@"room" context:context]);
    CHECK(!Observe(f, @"room", context, f.now, 0, YES, YES));
    NSUInteger writes = f.defaults.writeCount;
    CHECK(![f.store discardMessageActivity:@"room" context:context]);
    CHECK(f.defaults.writeCount == writes);
    CHECK(!Activity(f, @"room", context, f.now, 1, YES));
    CHECK([f.store setHeld:NO username:@"room" context:context]);
    f.now++;
    CHECK(Activity(f, @"room", context, f.now, 1, YES));
}

static void DiscardRejectsStaleAccount(Fixture *f) {
    WCRAFAccountContext *a = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:a]);
    CHECK(Observe(f, @"room", a, f.now, 1, YES, YES));
    f.account = @"account-B";
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:b]);
    CHECK(Observe(f, @"room", b, f.now, 1, YES, YES));
    CHECK(![f.store discardMessageActivity:@"room" context:a]);
    CHECK([f.store hasTrackedMessageActivity:@"room" context:b]);
    CHECK([f.store trackedMessageActivityUsernamesForContext:a].count == 0);
}

static void DirtyObservationRejectsStaleAndInvalidInput(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Observe(f, @"room", context, f.now, 1, YES, YES));
    for (NSNumber *message in @[@0, @(-1), @(NAN), @(INFINITY), @(f.now + 1), @(f.now - 1)]) {
        CHECK(![f.store needsMessageActivityObservation:@"room" context:context
            lastMessageTime:message.doubleValue unreadCount:1 grouped:YES homeVisible:YES]);
    }
    CHECK(![f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:f.now unreadCount:-1 grouped:YES homeVisible:YES]);
    CHECK(!Observe(f, @"room", context, f.now, -1, YES, YES));
    CHECK(![f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:f.now unreadCount:-1 grouped:YES homeVisible:YES]);
    f.clockThrows = YES;
    CHECK(![f.store needsMessageActivityObservation:@"room" context:context
        lastMessageTime:f.now unreadCount:0 grouped:YES homeVisible:YES]);
}

static void TrackedEnumerationOmitsHeldAndDiscarded(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Observe(f, @"alice", context, f.now, 0, YES, NO));
    CHECK(Observe(f, @"bob", context, f.now, 1, YES, YES));
    CHECK([f.store setHeld:YES username:@"bob" context:context]);
    NSArray *names = [f.store trackedMessageActivityUsernamesForContext:context];
    CHECK(names.count == 1 && [names containsObject:@"alice"]);
    CHECK([f.store discardMessageActivity:@"alice" context:context]);
    CHECK([f.store trackedMessageActivityUsernamesForContext:context].count == 0);
}

static void SwipeDistanceBoundary(Fixture *f) {
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"room"
        context:[f.store currentContext] grouped:YES held:NO];
    double threshold = WCRAFSwipeReturnThreshold(390, 82);
    CHECK(threshold > 82 * 2);
    CHECK(![intent consumeReturnAtDistance:threshold - 0.01 rowWidth:390 actionWidth:82 cancelled:NO]);
    CHECK([intent consumeReturnAtDistance:threshold rowWidth:390 actionWidth:82 cancelled:NO]);
    CHECK(![intent consumeReturnAtDistance:390 rowWidth:390 actionWidth:82 cancelled:NO]);
}

static void SwipePullbackBeforeThreshold(Fixture *f) {
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"room"
        context:[f.store currentContext] grouped:YES held:YES];
    CHECK(![intent consumeReturnAtDistance:210 rowWidth:390 actionWidth:82 cancelled:NO]);
    CHECK(![intent consumeReturnAtDistance:120 rowWidth:390 actionWidth:82 cancelled:NO]);
    CHECK(![f.store isMessageReturnSuppressed:@"room" context:intent.context lastMessageTime:f.now]);
}

static void SwipeCancellationNeverReturns(Fixture *f) {
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"room"
        context:[f.store currentContext] grouped:YES held:NO];
    CHECK(![intent consumeReturnAtDistance:390 rowWidth:390 actionWidth:82 cancelled:YES]);
    CHECK([f.defaults persistentDomainForName:f.suite].count == 0);
}

static void SwipeThresholdCommitsDuringDrag(Fixture *f) {
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"room"
        context:[f.store currentContext] grouped:YES held:NO];
    NSUInteger commits = 0;
    for (NSNumber *sample in @[@20, @81, @82, @83, @160, @210, @220, @250]) {
        if ([intent consumeReturnAtDistance:sample.doubleValue rowWidth:390 actionWidth:82 cancelled:NO]) {
            CHECK(sample.doubleValue == 250);
            commits++;
        }
    }
    CHECK(commits == 1);
}

static void SwipeCommitIsConsumedAcrossLaterEvents(Fixture *f) {
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"room"
        context:[f.store currentContext] grouped:YES held:YES];
    CHECK([intent consumeReturnAtDistance:250 rowWidth:390 actionWidth:82 cancelled:NO]);
    CHECK(![intent consumeReturnAtDistance:82 rowWidth:390 actionWidth:82 cancelled:NO]);
    CHECK(![intent consumeReturnAtDistance:390 rowWidth:390 actionWidth:82 cancelled:NO]);
    CHECK(![intent consumeReturnAtDistance:390 rowWidth:390 actionWidth:82 cancelled:YES]);
}

static void UngroupedSwipeNeverReturns(Fixture *f) {
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"alice"
        context:[f.store currentContext] grouped:NO held:NO];
    CHECK(![intent consumeReturnAtDistance:10000 rowWidth:390 actionWidth:82 cancelled:NO]);
}

static void SwipeRejectsInvalidGeometry(Fixture *f) {
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"room"
        context:[f.store currentContext] grouped:YES held:NO];
    for (NSNumber *value in @[@(-1), @0, @(NAN), @(INFINITY)]) {
        CHECK(![intent consumeReturnAtDistance:value.doubleValue rowWidth:390 actionWidth:82 cancelled:NO]);
        CHECK(![intent consumeReturnAtDistance:390 rowWidth:value.doubleValue actionWidth:82 cancelled:NO]);
        CHECK(![intent consumeReturnAtDistance:390 rowWidth:390 actionWidth:value.doubleValue cancelled:NO]);
    }
    CHECK(![intent consumeReturnAtDistance:200 rowWidth:160 actionWidth:82 cancelled:NO]);
    CHECK(WCRAFSwipeReturnThreshold(320, 82) > 82);
    CHECK(WCRAFSwipeReturnThreshold(1024, 82) < 1024);
    CHECK(WCRAFSwipeReturnThreshold(1024, 82) <= 82 * 3.5);
}

static void SwipeRejectsReusedRow(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"alice"
        context:context grouped:YES held:NO];
    CHECK([intent matchesUsername:@"alice" context:context grouped:YES held:NO]);
    CHECK(![intent matchesUsername:@"bob" context:context grouped:YES held:NO]);
    CHECK(![intent matchesUsername:@"" context:context grouped:YES held:NO]);
}

static void SwipeRejectsChangedGroupingOrHold(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"alice"
        context:context grouped:YES held:NO];
    CHECK(![intent matchesUsername:@"alice" context:context grouped:NO held:NO]);
    CHECK(![intent matchesUsername:@"alice" context:context grouped:YES held:YES]);
}

static void SwipeRejectsAccountSwitch(Fixture *f) {
    WCRAFAccountContext *a = [f.store currentContext];
    WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:@"alice"
        context:a grouped:YES held:NO];
    f.account = @"account-B";
    CHECK(![intent matchesUsername:@"alice" context:[f.store currentContext] grouped:YES held:NO]);
    f.account = @"account-A";
    WCRAFAccountContext *again = [f.store currentContext];
    CHECK(![intent matchesUsername:@"alice" context:again grouped:YES held:NO]);
    CHECK(![f.store isCurrentContext:a]);
}

static void ReturnSuppressionUnknownTimeIsNotNewMessage(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK([f.store setHeld:NO username:@"room" context:context]);
    for (NSNumber *time in @[@0, @(-1), @(NAN), @(INFINITY), @(f.now + 60)]) {
        CHECK([f.store isMessageReturnSuppressed:@"room" context:context lastMessageTime:time.doubleValue]);
    }
    CHECK(![f.store isMessageReturnSuppressed:@"other" context:context lastMessageTime:0]);
    f.account = @"account-B";
    CHECK(![f.store isMessageReturnSuppressed:@"room" context:context lastMessageTime:0]);
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK(![f.store isMessageReturnSuppressed:@"room" context:b lastMessageTime:0]);
}

static void ManualReturnFailureDoesNotSuppressOnRestart(Fixture *f) {
    WCRAFAccountContext *context = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:context]);
    CHECK(Observe(f, @"room", context, f.now, 2, YES, YES));
    f.defaults.failWrite = YES;
    CHECK(![f.store setHeld:NO username:@"room" context:context]);
    f.defaults.failWrite = NO;
    f.store = [f newStore];
    context = [f.store currentContext];
    CHECK(![f.store isMessageReturnSuppressed:@"room" context:context lastMessageTime:f.now]);
    CHECK(Activity(f, @"room", context, f.now, 2, YES));
}

static void ReadObservationAccountSwitchCannotInstallOldState(Fixture *f) {
    WCRAFAccountContext *a = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:a]);
    CHECK(Observe(f, @"room", a, f.now, 1, YES, YES));
    __weak Fixture *weak = f;
    f.defaults.afterWrite = ^{
        weak.account = @"account-B";
        CHECK([weak.store currentContext] != nil);
    };
    CHECK(!Observe(f, @"room", a, f.now, 0, YES, YES));
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK(![f.store isMessageReturnSuppressed:@"room" context:b lastMessageTime:f.now]);
    CHECK(![f.store setHeld:NO username:@"room" context:a]);
}

static void HeldSkipsReadObservationAndWrites(Fixture *f) {
    WCRAFAccountContext *context = [f keep:@"alice"];
    CHECK([f.store enableMessageActivityForContext:context]);
    NSUInteger writes = f.defaults.writeCount;
    CHECK(![f.store needsMessageActivityObservation:@"alice" context:context
        lastMessageTime:f.now unreadCount:0 grouped:YES homeVisible:YES]);
    CHECK(!Observe(f, @"alice", context, f.now, 0, YES, YES));
    CHECK([f.store isHeld:@"alice" context:context]);
    CHECK(f.defaults.writeCount == writes);
}

static void OutgoingWaitsForHomeVisit(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    CHECK(Activity(f, @"alice", c, f.now, 0, YES));
    CHECK(!Observe(f, @"alice", c, f.now, 0, YES, YES));
    CHECK([f.store markHomeConversationOpened:@"alice" context:c]);
    CHECK(!Observe(f, @"alice", c, f.now, 0, YES, NO));
    CHECK(Observe(f, @"alice", c, f.now, 0, YES, YES));
    CHECK(!Activity(f, @"alice", c, f.now, 0, YES));
}

static void OutgoingVisitSurvivesRestart(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    CHECK([f.store noteOutgoingMessage:@"room" context:c lastMessageTime:f.now]);
    f.store = [f newStore];
    c = [f.store currentContext];
    CHECK(![f.store needsMessageActivityObservation:@"room" context:c
        lastMessageTime:f.now unreadCount:0 grouped:YES homeVisible:YES]);
    CHECK(Activity(f, @"room", c, f.now, 0, YES));
    CHECK([f.store markHomeConversationOpened:@"room" context:c]);
    CHECK(Observe(f, @"room", c, f.now, 0, YES, YES));
}

static void OutgoingStableQueriesDoNotWrite(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    NSUInteger writes = f.defaults.writeCount;
    for (NSUInteger i = 0; i < 1000; i++) {
        CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
        CHECK(![f.store needsMessageActivityObservation:@"alice" context:c
            lastMessageTime:f.now unreadCount:0 grouped:YES homeVisible:YES]);
        CHECK(!Observe(f, @"alice", c, f.now, 0, YES, YES));
    }
    CHECK(f.defaults.writeCount == writes);
}

static void OutgoingNewMessagePreservesAwaitingVisit(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    f.now++;
    CHECK(Observe(f, @"alice", c, f.now, 1, YES, YES));
    CHECK(!Observe(f, @"alice", c, f.now, 0, YES, YES));
    CHECK([f.store markHomeConversationOpened:@"alice" context:c]);
    CHECK(Observe(f, @"alice", c, f.now, 0, YES, YES));
}

static void OutgoingManualReturnAndNewSend(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    CHECK([f.store setHeld:NO username:@"alice" context:c]);
    CHECK(!Activity(f, @"alice", c, f.now, 3, YES));
    CHECK(![f.store markHomeConversationOpened:@"alice" context:c]);
    // A separately proven local send can re-open even in the same second.
    CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    CHECK(Activity(f, @"alice", c, f.now, 0, YES));
}

static void OutgoingRejectsStaleAndInvalid(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    for (NSNumber *time in @[@0, @(-1), @(NAN), @(INFINITY), @(f.now + 1), @(f.now - 1)]) {
        CHECK(![f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:time.doubleValue]);
    }
    CHECK(![f.store noteOutgoingMessage:@"" context:c lastMessageTime:f.now]);
    CHECK(![f.store markHomeConversationOpened:@"" context:c]);
    CHECK([f.store setHeld:NO username:@"alice" context:c]);
    CHECK(![f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now - 1]);
}

static void OutgoingPreservesHold(Fixture *f) {
    WCRAFAccountContext *c = [f keep:@"alice"];
    CHECK([f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    CHECK([f.store markHomeConversationOpened:@"alice" context:c]);
    CHECK(!Observe(f, @"alice", c, f.now, 0, YES, YES));
    CHECK([f.store isHeld:@"alice" context:c]);
}

static void OutgoingWriteFailureDoesNotInstall(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    CHECK([f.store enableMessageActivityForContext:c]);
    NSDictionary *before = [f.defaults persistentDomainForName:f.suite];
    f.defaults.failWrite = YES;
    CHECK(![f.store noteOutgoingMessage:@"alice" context:c lastMessageTime:f.now]);
    f.defaults.failWrite = NO;
    CHECK([[f.defaults persistentDomainForName:f.suite] isEqual:before]);
    f.store = [f newStore];
    CHECK(![f.store hasTrackedMessageActivity:@"alice" context:[f.store currentContext]]);
}

static void OutgoingSwitchDuringWrite(Fixture *f) {
    WCRAFAccountContext *a = [f.store currentContext];
    __weak Fixture *weak = f;
    f.defaults.afterWrite = ^{
        weak.account = @"account-B";
        CHECK([weak.store currentContext] != nil);
    };
    CHECK(![f.store noteOutgoingMessage:@"alice" context:a lastMessageTime:f.now]);
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK(![f.store hasTrackedMessageActivity:@"alice" context:b]);
    CHECK(![f.store markHomeConversationOpened:@"alice" context:a]);
}

static void PerConversationExpiryBoundaries(Fixture *f) {
    WCRAFAccountContext *c = [f keep:@"one"];
    [f keep:@"three"]; [f keep:@"five"]; [f keep:@"forever"];
    NSTimeInterval start = f.now;
    CHECK([f.store setExpiryDays:1 username:@"one" context:c]);
    CHECK([f.store setExpiryDays:3 username:@"three" context:c]);
    CHECK([f.store setExpiryDays:5 username:@"five" context:c]);
    CHECK([f.store setExpiryDays:0 username:@"forever" context:c]);
    for (NSInteger day = 0; day <= 6; day++) {
        f.now = start + day * Day;
        CHECK([f.store isExpired:@"one" context:c lastMessageTime:start] == (day >= 1));
        CHECK([f.store isExpired:@"three" context:c lastMessageTime:start] == (day >= 3));
        CHECK([f.store isExpired:@"five" context:c lastMessageTime:start] == (day >= 5));
        CHECK(![f.store isExpired:@"forever" context:c lastMessageTime:start]);
    }
    CHECK([f.store expiryDaysForUsername:@"unknown" context:c] == 3);
}

static void PerConversationExpiryPersistsAndIsolates(Fixture *f) {
    WCRAFAccountContext *a = [f keep:@"alice"];
    CHECK([f.store setExpiryDays:14 context:a]); // Preserve an existing account choice.
    CHECK([f.store setExpiryDays:1 username:@"alice" context:a]);
    f.store = [f newStore];
    a = [f.store currentContext];
    CHECK([f.store expiryDaysForUsername:@"alice" context:a] == 1);
    CHECK([f.store expiryDaysForUsername:@"bob" context:a] == 14);
    f.account = @"account-B";
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK([f.store expiryDaysForUsername:@"alice" context:b] == 3);
    CHECK(![f.store setExpiryDays:5 username:@"alice" context:a]);
    CHECK([f.store setExpiryDays:5 username:@"alice" context:b]);
    f.account = @"account-A";
    CHECK([f.store expiryDaysForUsername:@"alice" context:[f.store currentContext]] == 1);
}

static void PerConversationSettingRevokesDetachedExpiry(Fixture *f) {
    WCRAFExpiryCandidate *ticket = [f expiredTicket:@"alice"];
    NSArray *batch = [f.store takeBatch:ticket];
    CHECK([f.store setExpiryDays:0 username:@"alice" context:ticket.context]);
    CHECK(![f.store commitExpiry:batch[0] lastMessageTime:f.now - 10 * Day]);
    CHECK([f.store isHeld:@"alice" context:ticket.context]);
}

static void PerConversationSettingsRejectInvalidAndFailedWrites(Fixture *f) {
    WCRAFAccountContext *c = [f.store currentContext];
    for (NSNumber *days in @[@(-1), @2, @7, @14]) {
        CHECK(![f.store setExpiryDays:days.integerValue username:@"alice" context:c]);
    }
    CHECK(![f.store setExpiryDays:1 username:@"" context:c]);
    CHECK([f.store setExpiryDays:5 username:@"alice" context:c]);
    f.defaults.failWrite = YES;
    CHECK(![f.store setExpiryDays:1 username:@"alice" context:c]);
    f.defaults.failWrite = NO;
    f.store = [f newStore];
    CHECK([f.store expiryDaysForUsername:@"alice" context:[f.store currentContext]] == 5);
}

static void NewFieldsMalformedRemainUntouched(Fixture *f) {
    NSString *key = [Prefix stringByAppendingString:f.account];
    for (id days in @[@[], @{@"alice": @(-1)}, @{@"alice": @"1"}, @{@"": @1}]) {
        NSDictionary *record = @{@"schema": @2, @"held": @[], @"since": @{}, @"days": @3, @"holdDays": days};
        [f.defaults setObject:record forKey:key];
        f.store = [f newStore];
        CHECK([f.store currentContext] == nil);
        CHECK([[f.defaults objectForKey:key] isEqual:record]);
    }
    for (id flag in @[@"YES", @2, @[]]) {
        NSDictionary *record = @{@"schema": @2, @"held": @[], @"since": @{}, @"days": @3,
            @"activitySince": @(f.now), @"returned": @{}, @"activity":
                @{@"alice": @{@"message": @(f.now), @"readAt": @0, @"awaitingVisit": flag}}};
        [f.defaults setObject:record forKey:key];
        f.store = [f newStore];
        CHECK([f.store currentContext] == nil);
        CHECK([[f.defaults objectForKey:key] isEqual:record]);
    }
}

static void LedgerRequiresAcknowledgedLocalProvenance(Fixture *f) {
    WCRAFOutgoingLedger *ledger = [WCRAFOutgoingLedger new];
    WCRAFAccountContext *c = [f.store currentContext];
    NSObject *token = [NSObject new];
    CHECK(![ledger acknowledgeUsername:@"alice" context:c token:token localID:1 serverID:9 messageTime:f.now]);
    CHECK([ledger stageUsername:@"alice" context:c token:token messageTime:f.now]);
    CHECK(![ledger acknowledgeUsername:@"alice" context:c token:token localID:1 serverID:0 messageTime:f.now]);
    CHECK([ledger acknowledgeUsername:@"alice" context:c token:token localID:1 serverID:9 messageTime:f.now]);
    CHECK(![ledger acknowledgeUsername:@"alice" context:c token:token localID:1 serverID:9 messageTime:f.now]);
}

static void LedgerMatchesClonedAcknowledgment(Fixture *f) {
    WCRAFOutgoingLedger *ledger = [WCRAFOutgoingLedger new];
    WCRAFAccountContext *c = [f.store currentContext];
    WCRAFOutgoingTicket *ticket = [ledger stageUsername:@"alice" context:c token:[NSObject new] messageTime:f.now];
    [ledger bindLocalID:42 ticket:ticket];
    CHECK(![ledger acknowledgeUsername:@"bob" context:c token:[NSObject new] localID:42 serverID:9 messageTime:f.now]);
    CHECK(![ledger acknowledgeUsername:@"alice" context:c token:[NSObject new] localID:42 serverID:9 messageTime:f.now - 1]);
    CHECK(![ledger acknowledgeUsername:@"alice" context:c token:[NSObject new] localID:41 serverID:9 messageTime:f.now]);
    CHECK([ledger acknowledgeUsername:@"alice" context:c token:[NSObject new] localID:42 serverID:9 messageTime:f.now] == ticket);
}

static void LedgerManualActionCancelsLateAck(Fixture *f) {
    WCRAFOutgoingLedger *ledger = [WCRAFOutgoingLedger new];
    WCRAFAccountContext *c = [f.store currentContext];
    NSObject *a = [NSObject new], *b = [NSObject new];
    CHECK([ledger stageUsername:@"alice" context:c token:a messageTime:f.now]);
    CHECK([ledger stageUsername:@"bob" context:c token:b messageTime:f.now]);
    [ledger invalidateUsername:@"alice" context:c];
    CHECK(![ledger acknowledgeUsername:@"alice" context:c token:a localID:1 serverID:9 messageTime:f.now]);
    CHECK([ledger acknowledgeUsername:@"bob" context:c token:b localID:1 serverID:9 messageTime:f.now]);
    CHECK([ledger stageUsername:@"alice" context:c token:a messageTime:f.now]);
    CHECK([ledger acknowledgeUsername:@"alice" context:c token:a localID:1 serverID:10 messageTime:f.now]);
}

static void LedgerAccountEpochIsolatesAcknowledgments(Fixture *f) {
    WCRAFOutgoingLedger *ledger = [WCRAFOutgoingLedger new];
    WCRAFAccountContext *a = [f.store currentContext];
    NSObject *token = [NSObject new];
    CHECK([ledger stageUsername:@"alice" context:a token:token messageTime:f.now]);
    f.account = @"account-B";
    WCRAFAccountContext *b = [f.store currentContext];
    CHECK(![ledger acknowledgeUsername:@"alice" context:b token:token localID:1 serverID:9 messageTime:f.now]);
    CHECK([ledger stageUsername:@"bob" context:b token:[NSObject new] messageTime:f.now]);
    f.account = @"account-A";
    WCRAFAccountContext *again = [f.store currentContext];
    CHECK(![ledger acknowledgeUsername:@"alice" context:again token:token localID:1 serverID:9 messageTime:f.now]);
    CHECK(![ledger acknowledgeUsername:@"alice" context:a token:token localID:1 serverID:9 messageTime:f.now]);
}

static void LedgerBoundsPendingFailures(Fixture *f) {
    WCRAFOutgoingLedger *ledger = [WCRAFOutgoingLedger new];
    WCRAFAccountContext *c = [f.store currentContext];
    NSObject *first = [NSObject new], *last = nil;
    CHECK([ledger stageUsername:@"alice" context:c token:first messageTime:f.now]);
    for (NSUInteger i = 0; i < 128; i++) {
        last = [NSObject new];
        CHECK([ledger stageUsername:@"alice" context:c token:last messageTime:f.now]);
    }
    CHECK(![ledger acknowledgeUsername:@"alice" context:c token:first localID:0 serverID:9 messageTime:f.now]);
    CHECK([ledger acknowledgeUsername:@"alice" context:c token:last localID:0 serverID:10 messageTime:f.now]);
}

static void TwoActionsFitBeforeReturnThreshold(Fixture *f) {
    (void)f;
    for (NSNumber *width in @[@280, @320, @375, @390, @430, @768, @1024]) {
        double threshold = WCRAFSwipeReturnThreshold(width.doubleValue, 82);
        CHECK(threshold > 164 + 20);
        CHECK(threshold < width.doubleValue);
    }
    CHECK(WCRAFSwipeReturnThreshold(1024, 82) <= 82 * 3.5);
}

static void NativeNotifyReadsBooleanAndIntegerStates(Fixture *f) {
    (void)f;
    NSArray<NativeNotifyState *> *contacts = @[
        [NotifyBoolReader new], [NotifyCharReader new], [NotifyUCharReader new],
        [NotifyShortReader new], [NotifyUShortReader new], [NotifyIntReader new],
        [NotifyUIntReader new], [NotifyLongReader new], [NotifyULongReader new],
        [NotifyLongLongReader new], [NotifyULongLongReader new]];
    for (NativeNotifyState *contact in contacts) {
        contact.value = 0;
        CHECK(WCRAFReadNativeNotifyOpen(contact) == 0);
        contact.value = 1;
        CHECK(WCRAFReadNativeNotifyOpen(contact) == 1);
    }
}

static void NativeNotifyRejectsUnknownReadStates(Fixture *f) {
    (void)f;
    CHECK(WCRAFReadNativeNotifyOpen(nil) == -1);
    CHECK(WCRAFReadNativeNotifyOpen([NSObject new]) == -1);
    CHECK(WCRAFReadNativeNotifyOpen([NotifyFloatReader new]) == -1);
    NotifyIntReader *contact = [NotifyIntReader new];
    for (NSNumber *value in @[@(-1), @2, @255, @(NSIntegerMax)]) {
        contact.value = value.integerValue;
        CHECK(WCRAFReadNativeNotifyOpen(contact) == -1);
    }
    contact.throwRead = YES;
    CHECK(WCRAFReadNativeNotifyOpen(contact) == -1);
}

static void NativeNotifyWritesIntegerReturnAndFlagWidths(Fixture *f) {
    (void)f;
    NSArray<NativeNotifyManager *> *managers = @[
        [NotifyBoolWriter new], [NotifyCharWriter new], [NotifyShortWriter new],
        [NotifyIntWriter new], [NotifyLongWriter new], [NotifyLongLongWriter new],
        [NotifyUnsignedWriter new], [NotifyVoidWriter new]];
    NotifyIntReader *contact = [NotifyIntReader new];
    for (NativeNotifyManager *manager in managers) {
        contact.value = 1;
        CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyInvoked);
        CHECK(manager.calls == 1 && manager.receivedContact == contact);
        CHECK(!manager.notify && manager.sync);
        CHECK(WCRAFReadNativeNotifyOpen(contact) == 0);
        CHECK(WCRAFInvokeNativeNotify(manager, contact, YES) == WCRAFNativeNotifyInvoked);
        CHECK(manager.calls == 2 && manager.notify && manager.sync);
        CHECK(WCRAFReadNativeNotifyOpen(contact) == 1);
    }
}

static void NativeNotifyPreservesWideReturnValues(Fixture *f) {
    (void)f;
    NotifyLongLongWriter *manager = [NotifyLongLongWriter new];
    NotifyIntReader *contact = [NotifyIntReader new];
    manager.response = 1LL << 40; // Low byte is zero; reading BOOL would misreport rejection.
    CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyInvoked);
    CHECK(manager.calls == 1);
}

static void NativeNotifyRejectsUnsupportedSignaturesBeforeWrite(Fixture *f) {
    (void)f;
    NotifyIntReader *contact = [NotifyIntReader new];
    for (NativeNotifyManager *manager in @[[NotifyFloatResultWriter new], [NotifyFloatFlagWriter new]]) {
        CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyUnavailable);
        CHECK(manager.calls == 0);
    }
    CHECK(WCRAFInvokeNativeNotify([NSObject new], contact, NO) == WCRAFNativeNotifyUnavailable);
    CHECK(WCRAFInvokeNativeNotify(nil, contact, NO) == WCRAFNativeNotifyUnavailable);
    CHECK(WCRAFInvokeNativeNotify([NotifyIntWriter new], nil, NO) == WCRAFNativeNotifyUnavailable);
}

static void NativeNotifyRejectedCallDoesNotClaimSuccess(Fixture *f) {
    (void)f;
    NotifyIntWriter *manager = [NotifyIntWriter new];
    NotifyIntReader *contact = [NotifyIntReader new];
    manager.response = 0;
    manager.updatesState = NO;
    contact.value = 1;
    CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyRejected);
    CHECK(manager.calls == 1 && manager.sync);
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 1);
}

static void NativeNotifySubmissionStillRequiresStateConfirmation(Fixture *f) {
    (void)f;
    NotifyIntWriter *manager = [NotifyIntWriter new];
    NotifyIntReader *contact = [NotifyIntReader new];
    manager.updatesState = NO;
    contact.value = 1;
    CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyInvoked);
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 1);
    contact.value = 0; // A later native event, without a plugin timer.
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 0);
}

static void NativeNotifyExceptionsPreserveNativeState(Fixture *f) {
    (void)f;
    NotifyIntWriter *manager = [NotifyIntWriter new];
    NotifyIntReader *contact = [NotifyIntReader new];
    manager.throwWrite = YES;
    contact.value = 1;
    CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyUnavailable);
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 1);
}

static void NativeNotifySupportsQualifiedIntegerEncodings(Fixture *f) {
    (void)f;
    Class reader = objc_allocateClassPair(NativeNotifyState.class, "WCRTestQualifiedNotifyReader", 0);
    CHECK(reader != Nil);
    CHECK(class_addMethod(reader, NSSelectorFromString(@"isChatStatusNotifyOpen"),
        (IMP)QualifiedNotifyRead, "ri@:"));
    objc_registerClassPair(reader);
    NativeNotifyState *contact = [reader new];
    contact.value = 1;
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 1);
    Class writer = objc_allocateClassPair(NativeNotifyManager.class, "WCRTestQualifiedNotifyWriter", 0);
    CHECK(writer != Nil);
    CHECK(class_addMethod(writer, NSSelectorFromString(@"ChangeNotifyStatus:withStatus:sync:"),
        (IMP)QualifiedNotifyWrite, "ri@:@rirQ"));
    objc_registerClassPair(writer);
    NativeNotifyManager *manager = [writer new];
    CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyInvoked);
    CHECK(manager.calls == 1 && !manager.notify && manager.sync);
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 0);
}

static void NativeNotifyVoidReturnStillRequiresReadback(Fixture *f) {
    (void)f;
    NotifyVoidWriter *manager = [NotifyVoidWriter new];
    NotifyBoolReader *contact = [NotifyBoolReader new];
    manager.updatesState = NO;
    contact.value = 1;
    CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyInvoked);
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 1);
    manager.updatesState = YES;
    CHECK(WCRAFInvokeNativeNotify(manager, contact, NO) == WCRAFNativeNotifyInvoked);
    CHECK(WCRAFReadNativeNotifyOpen(contact) == 0);
}

static void NotifyDeferredStateConfirmsOnce(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    CHECK(op.manager.calls == 1 && op.reads == 2);
    CHECK(op.outcomes.count == 0 && op.scheduled.count == 1);
    op.contact.value = 0; // Simulate the host updating after the setter returns.
    [op runNext];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    CHECK(op.manager.calls == 1 && op.reads == 3 && op.scheduled.count == 0);
}

static void NotifyUnchangedStateStaysPendingAfterOneRead(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op runNext];
    CHECK(op.outcomes.count == 0 && op.pendingCount == 1);
    CHECK([op.coordinator pendingNotifyForUsername:@"room@chatroom" context:op.context] == 0);
    CHECK(op.manager.calls == 1 && op.reads == 3 && op.scheduled.count == 1);
}

static void NotifyAlreadyDesiredDoesNotSchedule(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:YES];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    CHECK(op.manager.calls == 0 && op.reads == 1 && op.scheduled.count == 0);
}

static void NotifyImmediateWriteDoesNotSchedule(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    op.manager.updatesState = YES;
    [op request:NO];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    CHECK(op.manager.calls == 1 && op.reads == 2 && op.scheduled.count == 0);
}

static void NotifyDuplicateRequestsShareConfirmation(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op request:NO];
    [op request:NO];
    CHECK(op.manager.calls == 1 && op.reads == 2 && op.scheduled.count == 1);
    op.contact.value = 0;
    [op runNext];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
}

static void NotifyOppositeRequestSupersedesPending(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    // Do not confuse the stale ON read with confirmation of a queued ON write.
    [op request:YES];
    CHECK(op.manager.calls == 1 && !op.manager.notify);
    CHECK(op.outcomes.count == 0);
    CHECK([op.coordinator pendingNotifyForUsername:@"room@chatroom" context:op.context] == 1);
    [op runNext];
    CHECK(op.manager.calls == 1 && op.outcomes.count == 0);
    op.contact.value = 0;
    [op observe];
    CHECK(op.manager.calls == 2 && op.manager.notify && op.outcomes.count == 0);
    op.contact.value = 1;
    while (op.scheduled.count) [op runNext];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    CHECK(op.scheduled.count == 0);
}

static void NotifyExplicitCancellationPreventsLateCompletion(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op.coordinator invalidateUsername:@"room@chatroom"];
    op.contact.value = 0;
    [op runNext];
    CHECK(op.outcomes.count == 0 && op.reads == 2 && op.manager.calls == 1);
}

static void NotifyAccountSwitchDropsConfirmation(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    f.account = @"account-B";
    op.contact.value = 0;
    [op runNext];
    CHECK(op.outcomes.count == 0 && op.reads == 2);
}

static void NotifyBackgroundCancellationDropsAll(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    op.foreground = NO;
    [op.coordinator cancelAll];
    [op runNext];
    CHECK(op.outcomes.count == 0 && op.reads == 2);
    [op request:NO];
    CHECK(op.manager.calls == 1 && op.scheduled.count == 0);
}

static void NotifyRejectStillAcceptsConfirmedState(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    op.manager.response = 0;
    [op request:NO];
    op.contact.value = 0;
    [op runNext];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    op.contact.value = 1;
    [op request:NO];
    [op runNext];
    CHECK(op.outcomes.count == 1);
    f.now += 30;
    [op observe];
    CHECK(op.outcomes.lastObject.integerValue == WCRAFNotifyUnconfirmed);
}

static void NotifyUnavailableReadAndWriteFailWithoutSchedule(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    op.contact.throwRead = YES;
    [op request:NO];
    CHECK(op.outcomes.count == 0 && op.manager.calls == 1);
    CHECK(op.reads == 2 && op.scheduled.count == 1);
    op.contact.throwRead = NO;
    op.contact.value = 0;
    [op runNext];
    CHECK(op.outcomes.lastObject.integerValue == WCRAFNotifyConfirmed);
    CHECK(op.manager.calls == 1);

    op.contact.value = 1;
    op.manager.throwWrite = YES;
    [op request:NO];
    CHECK(op.outcomes.lastObject.integerValue == WCRAFNotifyWriteUnavailable);
    CHECK(op.scheduled.count == 0);
}

static void NotifyPendingRequestsAreBounded(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    for (NSUInteger index = 0; index < 129; index++) {
        [op.coordinator changeUsername:[NSString stringWithFormat:@"room-%lu", (unsigned long)index]
            context:op.context notify:NO read:^NSInteger { return 1; }
            write:^WCRAFNativeNotifyResult { return WCRAFNativeNotifyInvoked; }
            pending:^{}
            completion:^(WCRAFNotifyOutcome outcome) { [op.outcomes addObject:@(outcome)]; }];
    }
    CHECK(op.scheduled.count == 128);
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyBusy)]]);
    [op.coordinator cancelAll];
    while (op.scheduled.count) [op runNext];
    CHECK(op.outcomes.count == 1);
}

static void NotifyReentrantCancellationStopsReadback(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op.coordinator changeUsername:@"room" context:op.context notify:NO
        read:^NSInteger { op.reads++; return 1; }
        write:^WCRAFNativeNotifyResult {
            [op.coordinator invalidateUsername:@"room"];
            return WCRAFNativeNotifyInvoked;
        } pending:^{} completion:^(__unused WCRAFNotifyOutcome outcome) { op.foreground = NO; }];
    CHECK(op.reads == 1 && op.scheduled.count == 0 && op.foreground);
}

static void NotifyLateHostEventConfirmsWithoutNewWrite(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    op.contact.value = 0;
    [op request:YES];
    [op runNext];
    CHECK(op.outcomes.count == 0);
    f.now += 5;
    op.contact.value = 1;
    [op observe];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    while (op.scheduled.count) [op runNext];
    CHECK(op.manager.calls == 1 && op.scheduled.count == 0);
    NSUInteger reads = op.reads;
    [op observe];
    CHECK(op.outcomes.count == 1 && op.reads == reads);
}

static void NotifyHostEventsHaveReadBudget(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op runNext];
    for (NSUInteger index = 0; index < 1000; index++) {
        [op.coordinator observeUsername:@"room@chatroom" context:op.context];
    }
    CHECK(op.reads == 3);
    for (NSUInteger index = 0; index < 20; index++) [op observe];
    CHECK(op.reads == 19 && op.manager.calls == 1 && op.outcomes.count == 0);
    f.now += 20;
    op.contact.value = 0; // Final event still gets a fresh read despite the budget.
    [op.coordinator observeUsername:@"room@chatroom" context:op.context];
    CHECK(op.reads == 20 && op.outcomes.lastObject.integerValue == WCRAFNotifyConfirmed);
}

static void NotifyUnconfirmedExpiresLazily(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op runNext];
    f.now += 29;
    [op.coordinator observeUsername:@"room@chatroom" context:op.context];
    CHECK(op.outcomes.count == 0);
    f.now += 1;
    [op.coordinator observeUsername:@"room@chatroom" context:op.context];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyUnconfirmed)]]);
    CHECK([op.coordinator pendingNotifyForUsername:@"room@chatroom" context:op.context] == -1);
    while (op.scheduled.count) [op runNext];
    CHECK(op.manager.calls == 1 && op.scheduled.count == 0);
}

static void NotifyQueuedReverseCannotConfirmFromStaleState(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op request:YES];
    [op request:YES];
    [op observe];
    [op runNext];
    CHECK(op.manager.calls == 1 && op.outcomes.count == 0);
    f.now += 30;
    [op observe];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyUnconfirmed)]]);
    CHECK(op.manager.calls == 1);
}

static void NotifyLatestIntentCanCancelQueuedReverse(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op request:YES];
    [op request:NO];
    CHECK([op.coordinator pendingNotifyForUsername:@"room@chatroom" context:op.context] == 0);
    op.contact.value = 0;
    while (op.scheduled.count) [op runNext];
    CHECK(op.manager.calls == 1);
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
}

static void NotifyCancelledPendingCannotCompleteOnHostEvent(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op request:YES];
    [op.coordinator invalidateUsername:@"room@chatroom"];
    op.contact.value = 0;
    [op observe];
    [op runNext];
    CHECK(op.outcomes.count == 0 && op.manager.calls == 1);
}

static void NotifyPendingIsScopedToAccountAndUsername(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op.coordinator observeUsername:@"other-room" context:op.context];
    CHECK(op.reads == 2);
    CHECK([op.coordinator pendingNotifyForUsername:@"other-room" context:op.context] == -1);
    f.account = @"account-B";
    WCRAFAccountContext *other = [f.store currentContext];
    CHECK([op.coordinator pendingNotifyForUsername:@"room@chatroom" context:other] == -1);
    [op observe];
    [op runNext];
    CHECK(op.reads == 2 && op.outcomes.count == 0);
}

static void NotifyLateUnknownReadNeverClaimsSuccess(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op runNext];
    op.contact.throwRead = YES;
    [op observe];
    CHECK(op.outcomes.count == 0);
    f.now += 30;
    [op observe];
    CHECK(op.outcomes.lastObject.integerValue == WCRAFNotifyUnconfirmed);
}

static void NotifyReverseWaitsForActualFirstWrite(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    op.contact.value = 0;
    [op request:YES];
    [op request:NO];
    CHECK(op.manager.calls == 1 && op.manager.notify);
    [op runNext];
    op.contact.value = 1; // Original server update arrives first.
    [op observe];
    CHECK(op.manager.calls == 2 && !op.manager.notify);
    op.contact.value = 0;
    while (op.scheduled.count) [op runNext];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
}

static void NotifyAccountSwitchClearsOldCapacity(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    for (NSUInteger index = 0; index < 128; index++) {
        [op.coordinator changeUsername:[NSString stringWithFormat:@"old-%lu", (unsigned long)index]
            context:op.context notify:NO read:^NSInteger { return 1; }
            write:^WCRAFNativeNotifyResult { return WCRAFNativeNotifyInvoked; }
            pending:^{} completion:^(WCRAFNotifyOutcome outcome) { [op.outcomes addObject:@(outcome)]; }];
    }
    f.account = @"account-B";
    WCRAFAccountContext *other = [f.store currentContext];
    [op.coordinator changeUsername:@"new-room" context:other notify:YES
        read:^NSInteger { return 1; }
        write:^WCRAFNativeNotifyResult { return WCRAFNativeNotifyInvoked; }
        pending:^{} completion:^(WCRAFNotifyOutcome outcome) { [op.outcomes addObject:@(outcome)]; }];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    while (op.scheduled.count) [op runNext];
    CHECK(op.outcomes.count == 1);
}

static void NotifyReadbackFinishesWithoutHostEvents(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op runNext];
    CHECK(op.scheduled.count == 1 && op.outcomes.count == 0);
    op.contact.value = 0;
    [op runNext];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    CHECK(op.scheduled.count == 0 && op.manager.calls == 1 && op.reads == 4);
}

static void NotifyReadbackBudgetEndsWithoutHostEvents(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    NSTimeInterval started = f.now;
    [op request:NO];
    for (NSUInteger index = 0; index < 4; index++) {
        CHECK(op.scheduled.count == 1);
        [op runNext];
    }
    CHECK(op.scheduled.count == 0 && op.reads == 6 && op.manager.calls == 1);
    CHECK(fabs(f.now - started - 8.0) < 0.001);
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyUnconfirmed)]]);
    CHECK([op.coordinator pendingNotifyForUsername:@"room@chatroom" context:op.context] == -1);
}

static void NotifyReadbackUsesReplacementContact(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    NotifyIntReader *old = op.contact;
    op.contact = [NotifyIntReader new];
    op.contact.value = 0;
    CHECK(old.value == 1);
    [op runNext];
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyConfirmed)]]);
    CHECK(op.manager.calls == 1 && op.scheduled.count == 0);
}

static void NotifyCancellationStopsFurtherScheduledReads(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    [op runNext];
    [op.coordinator invalidateUsername:@"room@chatroom"];
    [op runNext];
    CHECK(op.reads == 3 && op.outcomes.count == 0 && op.scheduled.count == 0);
}

static void NotifyUnknownReadbackEndsWithoutSuccess(Fixture *f) {
    NotifyOperationFixture *op = [[NotifyOperationFixture alloc] initWithFixture:f];
    [op request:NO];
    op.contact.throwRead = YES;
    while (op.scheduled.count) [op runNext];
    CHECK(op.reads == 6 && op.manager.calls == 1);
    CHECK([op.outcomes isEqual:@[@(WCRAFNotifyUnconfirmed)]]);
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
        TEST(MissingTimestampRepairedConservatively), TEST(InvalidClockDoesNotWrite),
        TEST(ReadFailureDoesNotReplaceRecord), TEST(WriteFailureQuarantinesCache),
        TEST(SwitchInsideSaveDoesNotInstallOldCache), TEST(NestedWriteCannotSplitCacheAndDefaults),
        TEST(ClockExceptionFailsClosed), TEST(OrphanOnlyTimestampIsReconciled),
        TEST(ActivityDoesNotSurfaceOldHistory), TEST(ActivityCoversFirstAndSubsequentMessages),
        TEST(ActivityQueriesDoNotRenewOrWrite), TEST(ActivityPersistsAcrossRestart),
        TEST(ActivityReturnWaitsForNewMessage), TEST(ReadReturnsImmediatelyAfterReturningHome),
        TEST(UnreadStaysUntilConfirmedRead), TEST(NewMessageAfterReadReturnsToHome),
        TEST(UnknownReadCountPreservesActivity), TEST(UngroupedConversationsNeverAutoReturn),
        TEST(ManualHoldSurvivesConfirmedRead), TEST(ReturnedMessageSuppressionSurvivesRestart),
        TEST(ReadReturnDoesNotChangeOtherConversation), TEST(ReadActivityDoesNotResurfaceOldMessage),
        TEST(StaleObservationCannotEraseNewerActivity), TEST(ReturnRejectsQueuedOldObservation),
        TEST(ActivityAccountIsolation), TEST(ActivityRejectsUnknownFutureAndInvalidClock),
        TEST(ActivityEnableFailurePreservesDefaults), TEST(ActivityEnableDoesNotLoseManualState),
        TEST(ActivityInvalidRecordsRemainUntouched), TEST(ActivityEnableSwitchAndNestedWrite),
        TEST(ActivityObservationFailureQuarantinesCache), TEST(UnreadTransitionCannotReturnWithoutHome),
        TEST(AutomaticActivityPolicyHonorsMuteAndFold), TEST(DirtyObservationTracksOnlyTransitions),
        TEST(LegacyGraceRecordsReturnWithoutCountdown), TEST(StableReturnedQueriesDoNotWrite),
        TEST(DiscardActivityPreservesHoldAndAllowsFutureMessages), TEST(DiscardRejectsStaleAccount),
        TEST(DirtyObservationRejectsStaleAndInvalidInput), TEST(TrackedEnumerationOmitsHeldAndDiscarded),
        TEST(SwipeDistanceBoundary), TEST(SwipePullbackBeforeThreshold), TEST(SwipeCancellationNeverReturns),
        TEST(SwipeThresholdCommitsDuringDrag), TEST(SwipeCommitIsConsumedAcrossLaterEvents),
        TEST(UngroupedSwipeNeverReturns), TEST(SwipeRejectsInvalidGeometry), TEST(SwipeRejectsReusedRow),
        TEST(SwipeRejectsChangedGroupingOrHold), TEST(SwipeRejectsAccountSwitch),
        TEST(ReturnSuppressionUnknownTimeIsNotNewMessage), TEST(ManualReturnFailureDoesNotSuppressOnRestart),
        TEST(ReadObservationAccountSwitchCannotInstallOldState), TEST(HeldSkipsReadObservationAndWrites),
        TEST(OutgoingWaitsForHomeVisit), TEST(OutgoingVisitSurvivesRestart),
        TEST(OutgoingStableQueriesDoNotWrite), TEST(OutgoingNewMessagePreservesAwaitingVisit),
        TEST(OutgoingManualReturnAndNewSend), TEST(OutgoingRejectsStaleAndInvalid),
        TEST(OutgoingPreservesHold), TEST(OutgoingWriteFailureDoesNotInstall),
        TEST(OutgoingSwitchDuringWrite), TEST(PerConversationExpiryBoundaries),
        TEST(PerConversationExpiryPersistsAndIsolates), TEST(PerConversationSettingRevokesDetachedExpiry),
        TEST(PerConversationSettingsRejectInvalidAndFailedWrites), TEST(NewFieldsMalformedRemainUntouched),
        TEST(LedgerRequiresAcknowledgedLocalProvenance), TEST(LedgerMatchesClonedAcknowledgment),
        TEST(LedgerManualActionCancelsLateAck), TEST(LedgerAccountEpochIsolatesAcknowledgments),
        TEST(LedgerBoundsPendingFailures), TEST(TwoActionsFitBeforeReturnThreshold),
        TEST(NativeNotifyReadsBooleanAndIntegerStates), TEST(NativeNotifyRejectsUnknownReadStates),
        TEST(NativeNotifyWritesIntegerReturnAndFlagWidths), TEST(NativeNotifyPreservesWideReturnValues),
        TEST(NativeNotifyRejectsUnsupportedSignaturesBeforeWrite), TEST(NativeNotifyRejectedCallDoesNotClaimSuccess),
        TEST(NativeNotifySubmissionStillRequiresStateConfirmation), TEST(NativeNotifyExceptionsPreserveNativeState),
        TEST(NativeNotifySupportsQualifiedIntegerEncodings), TEST(NativeNotifyVoidReturnStillRequiresReadback),
        TEST(NotifyDeferredStateConfirmsOnce), TEST(NotifyUnchangedStateStaysPendingAfterOneRead),
        TEST(NotifyAlreadyDesiredDoesNotSchedule), TEST(NotifyImmediateWriteDoesNotSchedule),
        TEST(NotifyDuplicateRequestsShareConfirmation), TEST(NotifyOppositeRequestSupersedesPending),
        TEST(NotifyExplicitCancellationPreventsLateCompletion), TEST(NotifyAccountSwitchDropsConfirmation),
        TEST(NotifyBackgroundCancellationDropsAll), TEST(NotifyRejectStillAcceptsConfirmedState),
        TEST(NotifyUnavailableReadAndWriteFailWithoutSchedule), TEST(NotifyPendingRequestsAreBounded),
        TEST(NotifyReentrantCancellationStopsReadback),
        TEST(NotifyLateHostEventConfirmsWithoutNewWrite), TEST(NotifyHostEventsHaveReadBudget),
        TEST(NotifyUnconfirmedExpiresLazily), TEST(NotifyQueuedReverseCannotConfirmFromStaleState),
        TEST(NotifyLatestIntentCanCancelQueuedReverse), TEST(NotifyCancelledPendingCannotCompleteOnHostEvent),
        TEST(NotifyPendingIsScopedToAccountAndUsername), TEST(NotifyLateUnknownReadNeverClaimsSuccess),
        TEST(NotifyReverseWaitsForActualFirstWrite), TEST(NotifyAccountSwitchClearsOldCapacity),
        TEST(NotifyReadbackFinishesWithoutHostEvents), TEST(NotifyReadbackBudgetEndsWithoutHostEvents),
        TEST(NotifyReadbackUsesReplacementContact), TEST(NotifyCancellationStopsFurtherScheduledReads),
        TEST(NotifyUnknownReadbackEndsWithoutSuccess)
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
