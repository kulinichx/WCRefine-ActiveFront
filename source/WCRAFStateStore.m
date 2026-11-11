#import "WCRAFStateStore.h"
#import <math.h>
#import <string.h>

static NSString * const WCRAFAccountKeyPrefix = @"com.local.wcrefine.activefront.account.v2.";
static NSInteger const WCRAFDefaultExpiryDays = 3;

static const char *WCRAFNativeType(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WCRAFNativeInteger(const char *type) {
    type = WCRAFNativeType(type);
    return *type && strchr("BcCsSiIlLqQ", *type) != NULL;
}

static uint64_t WCRAFNativeIntegerResult(NSInvocation *call) {
    switch (*WCRAFNativeType(call.methodSignature.methodReturnType)) {
#define WCRAF_READ_RESULT(code, nativeType) \
        case code: { nativeType value = 0; [call getReturnValue:&value]; return (uint64_t)value; }
        WCRAF_READ_RESULT('B', BOOL)
        WCRAF_READ_RESULT('c', signed char)
        WCRAF_READ_RESULT('C', unsigned char)
        WCRAF_READ_RESULT('s', short)
        WCRAF_READ_RESULT('S', unsigned short)
        WCRAF_READ_RESULT('i', int)
        WCRAF_READ_RESULT('I', unsigned int)
        WCRAF_READ_RESULT('l', long)
        WCRAF_READ_RESULT('L', unsigned long)
        WCRAF_READ_RESULT('q', long long)
        WCRAF_READ_RESULT('Q', unsigned long long)
#undef WCRAF_READ_RESULT
        default: return UINT64_MAX;
    }
}

static void WCRAFSetNativeFlag(NSInvocation *call, NSUInteger index, BOOL flag) {
    switch (*WCRAFNativeType([call.methodSignature getArgumentTypeAtIndex:index])) {
#define WCRAF_SET_FLAG(code, nativeType) \
        case code: { nativeType value = flag ? 1 : 0; [call setArgument:&value atIndex:index]; break; }
        WCRAF_SET_FLAG('B', BOOL)
        WCRAF_SET_FLAG('c', signed char)
        WCRAF_SET_FLAG('C', unsigned char)
        WCRAF_SET_FLAG('s', short)
        WCRAF_SET_FLAG('S', unsigned short)
        WCRAF_SET_FLAG('i', int)
        WCRAF_SET_FLAG('I', unsigned int)
        WCRAF_SET_FLAG('l', long)
        WCRAF_SET_FLAG('L', unsigned long)
        WCRAF_SET_FLAG('q', long long)
        WCRAF_SET_FLAG('Q', unsigned long long)
#undef WCRAF_SET_FLAG
    }
}

NSInteger WCRAFReadNativeNotifyOpen(id contact) {
    if (!contact) return -1;
    @try {
        SEL read = NSSelectorFromString(@"isChatStatusNotifyOpen");
        NSMethodSignature *signature = [contact methodSignatureForSelector:read];
        if (!signature || signature.numberOfArguments != 2 ||
            !WCRAFNativeInteger(signature.methodReturnType)) return -1;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = contact;
        call.selector = read;
        [call invoke];
        uint64_t value = WCRAFNativeIntegerResult(call);
        return value <= 1 ? (NSInteger)value : -1;
    } @catch (__unused NSException *exception) { return -1; }
}

WCRAFNativeNotifyResult WCRAFInvokeNativeNotify(id manager, id contact, BOOL notify) {
    if (!manager || !contact) return WCRAFNativeNotifyUnavailable;
    @try {
        SEL change = NSSelectorFromString(@"ChangeNotifyStatus:withStatus:sync:");
        NSMethodSignature *signature = [manager methodSignatureForSelector:change];
        if (!signature || signature.numberOfArguments != 5 ||
            *WCRAFNativeType([signature getArgumentTypeAtIndex:2]) != '@' ||
            !WCRAFNativeInteger([signature getArgumentTypeAtIndex:3]) ||
            !WCRAFNativeInteger([signature getArgumentTypeAtIndex:4])) return WCRAFNativeNotifyUnavailable;
        BOOL voidResult = *WCRAFNativeType(signature.methodReturnType) == 'v';
        if (!voidResult && !WCRAFNativeInteger(signature.methodReturnType)) return WCRAFNativeNotifyUnavailable;
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = manager;
        call.selector = change;
        [call setArgument:&contact atIndex:2];
        WCRAFSetNativeFlag(call, 3, notify);
        WCRAFSetNativeFlag(call, 4, YES);
        [call invoke];
        return !voidResult && WCRAFNativeIntegerResult(call) == 0 ?
            WCRAFNativeNotifyRejected : WCRAFNativeNotifyInvoked;
    } @catch (__unused NSException *exception) { return WCRAFNativeNotifyUnavailable; }
}

@interface WCRAFNotifyRequest : NSObject
@property(nonatomic, copy) NSString *username;
@property(nonatomic, strong) WCRAFAccountContext *context;
@property(nonatomic) BOOL notify;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic) NSTimeInterval lastEventRead;
@property(nonatomic) NSUInteger eventReads;
@property(nonatomic) NSUInteger scheduledReads;
@property(nonatomic, copy) NSInteger (^read)(void);
@property(nonatomic, copy) WCRAFNativeNotifyResult (^write)(void);
@property(nonatomic, copy) void (^pending)(void);
@property(nonatomic, copy) void (^completion)(WCRAFNotifyOutcome);
@property(nonatomic, strong) WCRAFNotifyRequest *next;
@end
@implementation WCRAFNotifyRequest
@end

@implementation WCRAFNotifyCoordinator {
    NSMutableDictionary<NSString *, WCRAFNotifyRequest *> *_requests;
    WCRAFAccountContext *_context;
    BOOL (^_validator)(WCRAFAccountContext *);
    NSTimeInterval (^_clock)(void);
    void (^_scheduler)(NSTimeInterval, void (^)(void));
}
- (instancetype)initWithValidator:(BOOL (^)(WCRAFAccountContext *))validator
                           clock:(NSTimeInterval (^)(void))clock
                       scheduler:(void (^)(NSTimeInterval, void (^)(void)))scheduler {
    self = [super init];
    if (self) {
        _requests = [NSMutableDictionary dictionary];
        _validator = [validator copy];
        _clock = [clock copy];
        _scheduler = [scheduler copy];
    }
    return self;
}
- (BOOL)isCurrent:(WCRAFNotifyRequest *)request {
    if (_requests[request.username] != request) return NO;
    if (_validator(request.context) && _requests[request.username] == request) return YES;
    if (_requests[request.username] == request) [_requests removeObjectForKey:request.username];
    return NO;
}
- (NSInteger)read:(WCRAFNotifyRequest *)request {
    @try { return request.read(); }
    @catch (__unused NSException *exception) { return -1; }
}
- (void)finish:(WCRAFNotifyRequest *)request outcome:(WCRAFNotifyOutcome)outcome {
    if (![self isCurrent:request]) return;
    [_requests removeObjectForKey:request.username];
    if (request.next) {
        if (outcome == WCRAFNotifyConfirmed) {
            WCRAFNotifyRequest *next = request.next;
            [self changeUsername:next.username context:next.context notify:next.notify
                read:next.read write:next.write pending:next.pending completion:next.completion];
        } else {
            // An unconfirmed older write must not race a new opposite write.
            request.next.completion(WCRAFNotifyUnconfirmed);
        }
        return;
    }
    request.completion(outcome);
}
- (BOOL)expired:(WCRAFNotifyRequest *)request {
    NSTimeInterval now = _clock();
    return !isfinite(now) || now < request.started || now - request.started >= 30.0;
}
- (NSInteger)pendingNotifyForUsername:(NSString *)username context:(WCRAFAccountContext *)context {
    WCRAFNotifyRequest *request = _requests[username];
    if (!request || request.context != context) return -1;
    return (request.next ?: request).notify ? 1 : 0;
}
- (void)observeUsername:(NSString *)username context:(WCRAFAccountContext *)context {
    WCRAFNotifyRequest *request = _requests[username];
    if (!request || request.context != context || ![self isCurrent:request]) return;
    BOOL expired = [self expired:request];
    NSTimeInterval now = _clock();
    if (!expired && (request.eventReads >= 16 || now - request.lastEventRead < 0.5)) return;
    request.eventReads++;
    request.lastEventRead = now;
    NSInteger current = [self read:request];
    if (![self isCurrent:request]) return;
    if (current == (request.notify ? 1 : 0)) {
        [self finish:request outcome:WCRAFNotifyConfirmed];
    } else if (expired) {
        [self finish:request outcome:WCRAFNotifyUnconfirmed];
    }
}
- (void)scheduleReadback:(WCRAFNotifyRequest *)request {
    static const NSTimeInterval delays[] = {0.2, 0.8, 2.0, 5.0};
    if (![self isCurrent:request]) return;
    NSTimeInterval delay = delays[request.scheduledReads++];
    __weak WCRAFNotifyCoordinator *weakSelf = self;
    _scheduler(delay, ^{
        WCRAFNotifyCoordinator *coordinator = weakSelf;
        if (!coordinator || ![coordinator isCurrent:request]) return;
        NSInteger latest = [coordinator read:request];
        if (![coordinator isCurrent:request]) return;
        request.lastEventRead = coordinator->_clock();
        if (latest == (request.notify ? 1 : 0)) {
            [coordinator finish:request outcome:WCRAFNotifyConfirmed];
        } else if (request.scheduledReads >= 4 || [coordinator expired:request]) {
            [coordinator finish:request outcome:WCRAFNotifyUnconfirmed];
        } else {
            [coordinator scheduleReadback:request];
        }
    });
}
- (void)changeUsername:(NSString *)username context:(WCRAFAccountContext *)context
                notify:(BOOL)notify read:(NSInteger (^)(void))read
                 write:(WCRAFNativeNotifyResult (^)(void))write
               pending:(void (^)(void))pending
            completion:(void (^)(WCRAFNotifyOutcome))completion {
    if (username.length == 0 || !_validator(context)) return;
    if (_context != context) {
        [_requests removeAllObjects];
        _context = context;
    }
    WCRAFNotifyRequest *previous = _requests[username];
    if (previous && previous.context == context && [self expired:previous]) {
        [self observeUsername:username context:context];
        previous = _requests[username];
    }
    if (!previous && _requests.count >= 128) {
        completion(WCRAFNotifyBusy);
        return;
    }
    WCRAFNotifyRequest *request = [WCRAFNotifyRequest new];
    request.username = username;
    request.context = context;
    request.notify = notify;
    request.read = read;
    request.write = write;
    request.pending = pending;
    request.completion = completion;
    if (previous && previous.context == context) {
        if (previous.notify == notify) {
            previous.next = nil;
            previous.read = read;
            previous.pending = pending;
            previous.completion = completion;
        } else {
            previous.next = request;
        }
        return;
    }
    request.started = _clock();
    request.lastEventRead = request.started;
    if (!isfinite(request.started)) {
        completion(WCRAFNotifyUnconfirmed);
        return;
    }
    _requests[username] = request;
    NSInteger before = [self read:request];
    if (![self isCurrent:request]) return;
    if (before == (notify ? 1 : 0)) {
        [self finish:request outcome:WCRAFNotifyConfirmed];
        return;
    }
    // A user's explicit target remains actionable if the initial native read
    // is temporarily unavailable. Submit once, then require a confirmed read.
    WCRAFNativeNotifyResult result = WCRAFNativeNotifyUnavailable;
    @try { result = write(); }
    @catch (__unused NSException *exception) { }
    if (![self isCurrent:request]) return;
    if (result == WCRAFNativeNotifyUnavailable) {
        [self finish:request outcome:WCRAFNotifyWriteUnavailable];
        return;
    }
    NSInteger after = [self read:request];
    if (![self isCurrent:request]) return;
    if (after == (notify ? 1 : 0)) {
        [self finish:request outcome:WCRAFNotifyConfirmed];
        return;
    }
    pending();
    if (![self isCurrent:request]) return;
    [self scheduleReadback:request];
}
- (void)invalidateUsername:(NSString *)username {
    [_requests removeObjectForKey:username];
}
- (void)cancelAll {
    [_requests removeAllObjects];
}
@end

BOOL WCRAFAllowsAutomaticActivity(NSUInteger scope, NSInteger muted, NSInteger folded) {
    if (folded == 1) return NO;
    return (scope == 1 && muted != 1) || (scope == 2 && muted == 0);
}

static BOOL WCRAFValidTime(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
           isfinite([value doubleValue]) && [value doubleValue] > 0;
}

static BOOL WCRAFValidDays(id value, NSInteger *result) {
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    double days = [value doubleValue];
    if (!isfinite(days) || days < 0 || floor(days) != days ||
        days >= (double)NSIntegerMax) return NO;
    if (result) *result = [value integerValue];
    return YES;
}

@interface WCRAFAccountContext ()
@property(nonatomic, copy, readwrite) NSString *account;
@property(nonatomic, assign, readwrite) uint64_t epoch;
@end
@implementation WCRAFAccountContext
@end

@interface WCRAFOutgoingTicket ()
@property(nonatomic, strong, readwrite) WCRAFAccountContext *context;
@property(nonatomic, copy, readwrite) NSString *username;
@property(nonatomic, assign, readwrite) NSTimeInterval messageTime;
@property(nonatomic, weak) id token;
@property(nonatomic, assign) uint64_t localID;
@end
@implementation WCRAFOutgoingTicket
@end

@implementation WCRAFOutgoingLedger {
    NSMutableArray<WCRAFOutgoingTicket *> *_pendingSends;
}
- (instancetype)init {
    self = [super init];
    if (self) _pendingSends = [NSMutableArray array];
    return self;
}
- (WCRAFOutgoingTicket *)stageUsername:(NSString *)username
    context:(WCRAFAccountContext *)context token:(id)token messageTime:(NSTimeInterval)time {
    if (username.length == 0 || !context || !token || !isfinite(time) || time <= 0) return nil;
    NSIndexSet *obsolete = [_pendingSends indexesOfObjectsPassingTest:
        ^BOOL(WCRAFOutgoingTicket *entry, __unused NSUInteger index, __unused BOOL *stop) {
            return entry.context != context || entry.token == token;
        }];
    [_pendingSends removeObjectsAtIndexes:obsolete];
    if (_pendingSends.count >= 128) [_pendingSends removeObjectAtIndex:0];
    WCRAFOutgoingTicket *ticket = [WCRAFOutgoingTicket new];
    ticket.username = username;
    ticket.context = context;
    ticket.token = token;
    ticket.messageTime = time;
    [_pendingSends addObject:ticket];
    return ticket;
}
- (void)bindLocalID:(uint64_t)localID ticket:(WCRAFOutgoingTicket *)ticket {
    if (ticket && [_pendingSends containsObject:ticket]) ticket.localID = localID;
}
- (WCRAFOutgoingTicket *)acknowledgeUsername:(NSString *)username
    context:(WCRAFAccountContext *)context token:(id)token localID:(uint64_t)localID
    serverID:(uint64_t)serverID messageTime:(NSTimeInterval)time {
    if (serverID == 0 || !context || username.length == 0 || !isfinite(time) || time <= 0) return nil;
    for (WCRAFOutgoingTicket *ticket in [_pendingSends copy]) {
        if (ticket.context != context || ![ticket.username isEqualToString:username] ||
            ticket.messageTime != time) continue;
        if ((token && ticket.token == token) || (localID != 0 && ticket.localID == localID)) {
            [_pendingSends removeObject:ticket];
            return ticket;
        }
    }
    return nil;
}
- (void)invalidateUsername:(NSString *)username context:(WCRAFAccountContext *)context {
    NSIndexSet *obsolete = [_pendingSends indexesOfObjectsPassingTest:
        ^BOOL(WCRAFOutgoingTicket *entry, __unused NSUInteger index, __unused BOOL *stop) {
            return entry.context != context || [entry.username isEqualToString:username];
        }];
    [_pendingSends removeObjectsAtIndexes:obsolete];
}
@end

double WCRAFSwipeReturnThreshold(double rowWidth, double actionWidth) {
    if (!isfinite(rowWidth) || !isfinite(actionWidth) || actionWidth <= 0 ||
        rowWidth <= actionWidth * 2.0) return INFINITY;
    double comfortable = actionWidth * 2.35;
    double proportional = rowWidth * 0.64;
    double largeScreenCap = actionWidth * 3.5;
    return MIN(rowWidth - 16.0, MAX(comfortable, MIN(proportional, largeScreenCap)));
}

@implementation WCRAFSwipeIntent {
    BOOL _returnConsumed;
}
- (instancetype)initWithUsername:(NSString *)username context:(WCRAFAccountContext *)context
                         grouped:(BOOL)grouped held:(BOOL)held {
    self = [super init];
    if (self) {
        _username = [username copy];
        _context = context;
        _grouped = grouped;
        _held = held;
    }
    return self;
}
- (BOOL)matchesUsername:(NSString *)username context:(WCRAFAccountContext *)context
               grouped:(BOOL)grouped held:(BOOL)held {
    return _username.length > 0 && [_username isEqualToString:username] &&
        _context && _context == context && _context.epoch == context.epoch &&
        grouped == _grouped && held == _held;
}
- (BOOL)consumeReturnAtDistance:(double)distance rowWidth:(double)width
                   actionWidth:(double)actionWidth cancelled:(BOOL)cancelled {
    if (_returnConsumed || cancelled || !_grouped || !isfinite(distance) ||
        distance < WCRAFSwipeReturnThreshold(width, actionWidth)) return NO;
    _returnConsumed = YES;
    return YES;
}
@end

@interface WCRAFExpiryCandidate ()
@property(nonatomic, strong, readwrite) WCRAFAccountContext *context;
@property(nonatomic, copy, readwrite) NSString *username;
@property(nonatomic, assign) uint64_t revision;
@property(nonatomic, assign) uint64_t usernameRevision;
@property(nonatomic, assign) uint64_t batch;
@property(nonatomic, assign) NSTimeInterval since;
@property(nonatomic, assign) NSInteger days;
@end
@implementation WCRAFExpiryCandidate
@end

@implementation WCRAFStateStore {
    NSUserDefaults *_defaults;
    NSString *(^_accountResolver)(void);
    NSTimeInterval (^_clock)(void);
    WCRAFAccountContext *_context;
    uint64_t _epoch;
    uint64_t _revision;
    uint64_t _batch;
    NSMutableSet<NSString *> *_held;
    NSMutableDictionary<NSString *, NSNumber *> *_since;
    NSTimeInterval _activitySince;
    NSMutableDictionary<NSString *, NSNumber *> *_returned;
    NSMutableDictionary<NSString *, NSNumber *> *_holdDays;
    NSMutableDictionary<NSString *, NSDictionary *> *_activity;
    NSInteger _days;
    BOOL _writable;
    BOOL _saving;
    BOOL _timestampsNeedReconcile;
    NSMutableDictionary<NSString *, WCRAFExpiryCandidate *> *_pending;
    NSMutableDictionary<NSString *, NSNumber *> *_usernameRevisions;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                accountResolver:(NSString * _Nullable (^)(void))accountResolver
                          clock:(NSTimeInterval (^)(void))clock {
    self = [super init];
    if (self) {
        _defaults = defaults;
        _accountResolver = [accountResolver copy];
        _clock = [clock copy];
        _pending = [NSMutableDictionary dictionary];
        _usernameRevisions = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)keyForContext:(WCRAFAccountContext *)context {
    return [WCRAFAccountKeyPrefix stringByAppendingString:context.account];
}

- (NSTimeInterval)readClock {
    @try {
        NSTimeInterval now = _clock();
        return isfinite(now) && now > 0 ? now : 0;
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

- (nullable WCRAFAccountContext *)currentContext {
    @synchronized (self) {
        NSString *account = nil;
        @try {
            id resolved = _accountResolver();
            if ([resolved isKindOfClass:[NSString class]]) {
                account = [resolved stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        } @catch (__unused NSException *exception) {
            account = nil;
        }
        if (account.length == 0) account = nil;
        BOOL sameAccount = (!_context && !account) ||
                           [_context.account isEqualToString:account];
        if (!sameAccount) {
            _epoch++;
            _revision++;
            [_pending removeAllObjects];
            [_usernameRevisions removeAllObjects];
            _context = nil;
            _held = [NSMutableSet set];
            _since = [NSMutableDictionary dictionary];
            _activitySince = 0;
            _returned = [NSMutableDictionary dictionary];
            _holdDays = [NSMutableDictionary dictionary];
            _activity = [NSMutableDictionary dictionary];
            _days = WCRAFDefaultExpiryDays;
            _writable = YES;
            _timestampsNeedReconcile = NO;
            if (account) {
                _context = [WCRAFAccountContext new];
                _context.account = account;
                _context.epoch = _epoch;
                id raw = nil;
                @try {
                    raw = [_defaults objectForKey:[self keyForContext:_context]];
                } @catch (__unused NSException *exception) {
                    _writable = NO;
                    return nil;
                }
                if (raw) {
                    if (![raw isKindOfClass:[NSDictionary class]] ||
                        ![raw[@"schema"] isKindOfClass:[NSNumber class]] ||
                        ![raw[@"schema"] isEqualToNumber:@2] ||
                        ![raw[@"held"] isKindOfClass:[NSArray class]] ||
                        ![raw[@"since"] isKindOfClass:[NSDictionary class]] ||
                        !WCRAFValidDays(raw[@"days"], NULL)) {
                        _writable = NO;
                    } else {
                        id names = raw[@"held"];
                        for (id name in names) {
                            if (![name isKindOfClass:[NSString class]] || [name length] == 0) {
                                _writable = NO;
                                break;
                            }
                            [_held addObject:name];
                        }
                        id times = raw[@"since"];
                        for (id name in times) {
                            id time = times[name];
                            if (![name isKindOfClass:[NSString class]] || [name length] == 0 ||
                                ![time isKindOfClass:[NSNumber class]] ||
                                !isfinite([time doubleValue]) || [time doubleValue] <= 0) {
                                _writable = NO;
                                break;
                            }
                            if ([_held containsObject:name]) {
                                _since[name] = time;
                            } else {
                                _timestampsNeedReconcile = YES;
                            }
                        }
                        WCRAFValidDays(raw[@"days"], &_days);
                        if (raw[@"holdDays"]) {
                            if (![raw[@"holdDays"] isKindOfClass:[NSDictionary class]]) {
                                _writable = NO;
                            } else {
                                for (id name in raw[@"holdDays"]) {
                                    if (![name isKindOfClass:[NSString class]] || [name length] == 0 ||
                                        !WCRAFValidDays(raw[@"holdDays"][name], NULL)) {
                                        _writable = NO;
                                        break;
                                    }
                                    _holdDays[name] = raw[@"holdDays"][name];
                                }
                            }
                        }
                        if (raw[@"activitySince"] || raw[@"returned"]) {
                            if (!WCRAFValidTime(raw[@"activitySince"]) ||
                                ![raw[@"returned"] isKindOfClass:[NSDictionary class]]) {
                                _writable = NO;
                            } else {
                                _activitySince = [raw[@"activitySince"] doubleValue];
                                for (id name in raw[@"returned"]) {
                                    id time = raw[@"returned"][name];
                                    if (![name isKindOfClass:[NSString class]] || [name length] == 0 ||
                                        !WCRAFValidTime(time)) {
                                        _writable = NO;
                                        break;
                                    }
                                    _returned[name] = time;
                                }
                            }
                        }
                        if (raw[@"activity"]) {
                            if (_activitySince <= 0 ||
                                ![raw[@"activity"] isKindOfClass:[NSDictionary class]]) {
                                _writable = NO;
                            } else {
                                for (id name in raw[@"activity"]) {
                                    id entry = raw[@"activity"][name];
                                    if (![name isKindOfClass:[NSString class]] || [name length] == 0 ||
                                        ![entry isKindOfClass:[NSDictionary class]] ||
                                        !WCRAFValidTime(entry[@"message"]) ||
                                        ![entry[@"readAt"] isKindOfClass:[NSNumber class]] ||
                                        !isfinite([entry[@"readAt"] doubleValue]) ||
                                        [entry[@"readAt"] doubleValue] < 0 ||
                                        (entry[@"awaitingVisit"] &&
                                         (![entry[@"awaitingVisit"] isKindOfClass:[NSNumber class]] ||
                                          ![@[@0, @1] containsObject:entry[@"awaitingVisit"]]))) {
                                        _writable = NO;
                                        break;
                                    }
                                    _activity[name] = [entry copy];
                                }
                            }
                        }
                        if (raw[@"graceMinutes"]) {
                            id minutes = raw[@"graceMinutes"];
                            if (![minutes isKindOfClass:[NSNumber class]] ||
                                ![@[@1, @3, @5, @15, @30] containsObject:minutes]) {
                                _writable = NO;
                            } else {
                                // Accept the retired setting without reviving its timer.
                            }
                        }
                    }
                }
            }
        }
        return _writable ? _context : nil;
    }
}

- (BOOL)isCurrentContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        WCRAFAccountContext *current = [self currentContext];
        return context && current == context && context.epoch == current.epoch &&
               [context.account isEqualToString:current.account];
    }
}

// The key is always derived from the captured context, never a later account.
- (BOOL)saveHeld:(NSSet<NSString *> *)held
          since:(NSDictionary<NSString *, NSNumber *> *)since
           days:(NSInteger)days
  activitySince:(NSTimeInterval)activitySince
       returned:(NSDictionary<NSString *, NSNumber *> *)returned
       activity:(NSDictionary<NSString *, NSDictionary *> *)activity
       holdDays:(NSDictionary<NSString *, NSNumber *> *)holdDays
        context:(WCRAFAccountContext *)context {
    if (_saving || ![self isCurrentContext:context]) return NO;
    NSMutableDictionary *record = [@{
        @"schema": @2,
        @"held": [[held allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"since": [since copy],
        @"days": @(days), @"holdDays": [holdDays copy]
    } mutableCopy];
    if (activitySince > 0) {
        record[@"activitySince"] = @(activitySince);
        record[@"returned"] = [returned copy];
        record[@"activity"] = [activity copy];
    }
    // Defaults can invoke observers synchronously. Refuse nested writes and
    // never install this snapshot if an observer has switched accounts.
    _saving = YES;
    @try {
        [_defaults setObject:record forKey:[self keyForContext:context]];
    } @catch (__unused NSException *exception) {
        if (_context == context) {
            _writable = NO;
            _revision++;
            [_pending removeAllObjects];
        }
        return NO;
    } @finally {
        _saving = NO;
    }
    if (![self isCurrentContext:context]) return NO;
    _held = [held mutableCopy];
    _since = [since mutableCopy];
    _activitySince = activitySince;
    _returned = [returned mutableCopy];
    _holdDays = [holdDays mutableCopy];
    _activity = [activity mutableCopy];
    _days = days;
    _timestampsNeedReconcile = NO;
    return YES;
}

- (BOOL)saveHeld:(NSSet<NSString *> *)held since:(NSDictionary *)since days:(NSInteger)days
  activitySince:(NSTimeInterval)activitySince returned:(NSDictionary *)returned
       activity:(NSDictionary *)activity context:(WCRAFAccountContext *)context {
    return [self saveHeld:held since:since days:days activitySince:activitySince
        returned:returned activity:activity holdDays:_holdDays context:context];
}

- (BOOL)saveHeld:(NSSet<NSString *> *)held
          since:(NSDictionary<NSString *, NSNumber *> *)since
           days:(NSInteger)days
        context:(WCRAFAccountContext *)context {
    return [self saveHeld:held since:since days:days activitySince:_activitySince
                returned:_returned activity:_activity context:context];
}

- (BOOL)enableMessageActivityForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (_saving || ![self isCurrentContext:context]) return NO;
        if (_activitySince > 0) return YES;
        NSTimeInterval now = [self readClock];
        if (now < 1) return NO;
        // Session timestamps have second precision. Include messages in this startup second.
        return [self saveHeld:_held since:_since days:_days activitySince:floor(now)
                    returned:_returned activity:_activity context:context];
    }
}

- (BOOL)isMessageActive:(NSString *)username
                context:(WCRAFAccountContext *)context
        lastMessageTime:(NSTimeInterval)lastMessageTime
            unreadCount:(NSInteger)unreadCount
                grouped:(BOOL)grouped {
    if (username.length == 0) return NO;
    @synchronized (self) {
        if (![self isCurrentContext:context] || _activitySince <= 0 ||
            [_held containsObject:username]) return NO;
        NSTimeInterval now = [self readClock];
        if (now <= 0) return NO;
        NSDictionary *entry = _activity[username];
        NSTimeInterval recorded = [entry[@"message"] doubleValue];
        BOOL validTime = isfinite(lastMessageTime) && lastMessageTime > 0 && lastMessageTime <= now;
        NSTimeInterval message = validTime ? MAX(recorded, lastMessageTime) : recorded;
        if (message <= 0 || message <= [_returned[username] doubleValue] ||
            (message < _activitySince && recorded <= 0 && unreadCount <= 0)) return NO;
        // Queries never mark read or expire state. A fresh, foreground observation
        // performs the return; unknown unread/time data must not hide a session.
        (void)grouped;
        return YES;
    }
}

- (BOOL)observeMessageActivity:(NSString *)username
                       context:(WCRAFAccountContext *)context
               lastMessageTime:(NSTimeInterval)lastMessageTime
                   unreadCount:(NSInteger)unreadCount
                       grouped:(BOOL)grouped
                   homeVisible:(BOOL)homeVisible {
    if (username.length == 0) return NO;
    @synchronized (self) {
        if (_saving || ![self isCurrentContext:context] || _activitySince <= 0 ||
            [_held containsObject:username]) return NO;
        NSTimeInterval now = [self readClock];
        if (now <= 0 || !isfinite(lastMessageTime) || lastMessageTime <= 0 ||
            lastMessageTime > now ||
            lastMessageTime <= [_returned[username] doubleValue]) return NO;
        NSDictionary *entry = _activity[username];
        // Preserve already-unread conversations on upgrade as well. Only read
        // historical conversations require a post-enable message to surface.
        if (lastMessageTime < _activitySince && !entry && unreadCount <= 0) return NO;
        NSTimeInterval recorded = [entry[@"message"] doubleValue];
        if (lastMessageTime < recorded) return NO;
        BOOL awaitingVisit = [entry[@"awaitingVisit"] boolValue];
        BOOL returnNow = grouped && unreadCount == 0 && homeVisible && !awaitingVisit;
        // Keep schema-2 records readable by older builds; readAt is retired.
        NSDictionary *updated = awaitingVisit ?
            @{@"message": @(lastMessageTime), @"readAt": @0, @"awaitingVisit": @YES} :
            @{@"message": @(lastMessageTime), @"readAt": @0};
        if (!returnNow && [entry isEqual:updated]) return NO;
        NSMutableDictionary *activity = [_activity mutableCopy];
        NSMutableDictionary *returned = [_returned mutableCopy];
        if (returnNow) {
            [activity removeObjectForKey:username];
            returned[username] = @(lastMessageTime);
        } else {
            activity[username] = updated;
        }
        return [self saveHeld:_held since:_since days:_days activitySince:_activitySince
                    returned:returned activity:activity context:context];
    }
}

- (BOOL)hasMessageActivityForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        return [self isCurrentContext:context] && _activity.count > 0;
    }
}

- (BOOL)hasTrackedMessageActivity:(NSString *)username context:(WCRAFAccountContext *)context {
    @synchronized (self) {
        return [self isCurrentContext:context] && _activity[username] != nil;
    }
}

- (NSArray<NSString *> *)trackedMessageActivityUsernamesForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (![self isCurrentContext:context]) return @[];
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *name in _activity) {
            if (![_held containsObject:name]) [names addObject:name];
        }
        return names;
    }
}

- (BOOL)needsMessageActivityObservation:(NSString *)username
                               context:(WCRAFAccountContext *)context
                       lastMessageTime:(NSTimeInterval)lastMessageTime
                           unreadCount:(NSInteger)unreadCount
                               grouped:(BOOL)grouped
                           homeVisible:(BOOL)homeVisible {
    if (username.length == 0) return NO;
    @synchronized (self) {
        if (![self isCurrentContext:context] || _activitySince <= 0 ||
            [_held containsObject:username]) return NO;
        NSTimeInterval now = [self readClock];
        if (now <= 0 || !isfinite(lastMessageTime) || lastMessageTime <= 0 ||
            lastMessageTime > now || lastMessageTime <= [_returned[username] doubleValue]) return NO;
        NSDictionary *entry = _activity[username];
        if (lastMessageTime < _activitySince && !entry && unreadCount <= 0) return NO;
        NSTimeInterval recorded = [entry[@"message"] doubleValue];
        if (lastMessageTime < recorded) return NO;
        if (!entry || lastMessageTime > recorded) return YES;
        return (grouped && unreadCount == 0 && homeVisible && ![entry[@"awaitingVisit"] boolValue]) ||
            [entry[@"readAt"] doubleValue] != 0;
    }
}

- (BOOL)discardMessageActivity:(NSString *)username context:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (_saving || ![self isCurrentContext:context] || !_activity[username]) return NO;
        NSMutableDictionary *activity = [_activity mutableCopy];
        [activity removeObjectForKey:username];
        return [self saveHeld:_held since:_since days:_days activitySince:_activitySince
                    returned:_returned activity:activity context:context];
    }
}

- (BOOL)isMessageReturnSuppressed:(NSString *)username context:(WCRAFAccountContext *)context
                 lastMessageTime:(NSTimeInterval)lastMessageTime {
    @synchronized (self) {
        if (username.length == 0 || ![self isCurrentContext:context]) return NO;
        NSTimeInterval returned = [_returned[username] doubleValue];
        if (returned <= 0) return NO;
        NSTimeInterval now = [self readClock];
        if (now <= 0) return NO;
        // Missing/future timestamps are not evidence of a newer message.
        if (!isfinite(lastMessageTime) || lastMessageTime <= 0 || lastMessageTime > now) return YES;
        return lastMessageTime <= returned;
    }
}

- (BOOL)isHeld:(NSString *)username context:(WCRAFAccountContext *)context {
    @synchronized (self) {
        return [self isCurrentContext:context] && [_held containsObject:username];
    }
}

- (BOOL)hasAnyHeldForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        return [self isCurrentContext:context] && _held.count > 0;
    }
}

- (void)cancelPendingForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (![self isCurrentContext:context]) return;
        _revision++;
        [_pending removeAllObjects];
        [_usernameRevisions removeAllObjects];
    }
}

- (void)cancelExpiry:(NSString *)username context:(WCRAFAccountContext *)context {
    if (username.length == 0) return;
    @synchronized (self) {
        if (![self isCurrentContext:context] || ![_held containsObject:username]) return;
        // A live row must revoke its own detached snapshot, not an unrelated
        // contact's expiry in the same home refresh pass.
        _usernameRevisions[username] = @([_usernameRevisions[username] unsignedLongLongValue] + 1);
        [_pending removeObjectForKey:username];
    }
}

- (BOOL)setHeld:(BOOL)held username:(NSString *)username context:(WCRAFAccountContext *)context {
    if (username.length == 0) return NO;
    @synchronized (self) {
        if (_saving || ![self isCurrentContext:context]) return NO;
        NSMutableSet *names = [_held mutableCopy];
        NSMutableDictionary *times = [_since mutableCopy];
        NSMutableDictionary *returned = [_returned mutableCopy];
        NSMutableDictionary *activity = [_activity mutableCopy];
        if (held) {
            NSTimeInterval now = [self readClock];
            if (!isfinite(now) || now <= 0) return NO;
            [names addObject:username];
            times[username] = @(now);
        } else {
            [names removeObject:username];
            [times removeObjectForKey:username];
            if (_activitySince > 0) {
                NSTimeInterval now = [self readClock];
                if (now < 1) return NO;
                // Do not immediately surface the same message after an explicit return.
                returned[username] = @(MAX(floor(now), [returned[username] doubleValue]));
                [activity removeObjectForKey:username];
            }
        }
        [self cancelPendingForContext:context];
        return [self saveHeld:names since:times days:_days activitySince:_activitySince
                    returned:returned activity:activity context:context];
    }
}

- (NSInteger)expiryDaysForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        return [self isCurrentContext:context] ? _days : WCRAFDefaultExpiryDays;
    }
}

- (NSInteger)expiryDaysForUsername:(NSString *)username context:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (![self isCurrentContext:context]) return WCRAFDefaultExpiryDays;
        return username.length > 0 && _holdDays[username] ? [_holdDays[username] integerValue] : _days;
    }
}

- (BOOL)setExpiryDays:(NSInteger)days username:(NSString *)username
             context:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (_saving || username.length == 0 || ![@[@0, @1, @3, @5] containsObject:@(days)] ||
            ![self isCurrentContext:context]) return NO;
        NSMutableDictionary *holdDays = [_holdDays mutableCopy];
        holdDays[username] = @(days);
        [self cancelPendingForContext:context];
        return [self saveHeld:_held since:_since days:_days activitySince:_activitySince
            returned:_returned activity:_activity holdDays:holdDays context:context];
    }
}

- (BOOL)noteOutgoingMessage:(NSString *)username context:(WCRAFAccountContext *)context
           lastMessageTime:(NSTimeInterval)lastMessageTime {
    @synchronized (self) {
        if (_saving || username.length == 0 || ![self isCurrentContext:context]) return NO;
        NSTimeInterval now = [self readClock];
        if (now <= 0 || !isfinite(lastMessageTime) || lastMessageTime <= 0 ||
            lastMessageTime > now || lastMessageTime < [_returned[username] doubleValue] ||
            lastMessageTime < [_activity[username][@"message"] doubleValue]) return NO;
        NSMutableDictionary *activity = [_activity mutableCopy];
        NSMutableDictionary *returned = [_returned mutableCopy];
        NSDictionary *entry = @{@"message": @(lastMessageTime), @"readAt": @0, @"awaitingVisit": @YES};
        if ([_activity[username] isEqual:entry] && !returned[username]) return YES;
        activity[username] = entry;
        [returned removeObjectForKey:username];
        return [self saveHeld:_held since:_since days:_days
            activitySince:_activitySince > 0 ? _activitySince : floor(now)
            returned:returned activity:activity context:context];
    }
}

- (BOOL)markHomeConversationOpened:(NSString *)username context:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (_saving || username.length == 0 || ![self isCurrentContext:context] ||
            ![_activity[username][@"awaitingVisit"] boolValue]) return NO;
        NSMutableDictionary *activity = [_activity mutableCopy];
        activity[username] = @{@"message": _activity[username][@"message"], @"readAt": @0};
        return [self saveHeld:_held since:_since days:_days activitySince:_activitySince
            returned:_returned activity:activity context:context];
    }
}

- (BOOL)setExpiryDays:(NSInteger)days context:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (_saving || ![self isCurrentContext:context]) return NO;
        [self cancelPendingForContext:context];
        return [self saveHeld:_held since:_since days:MAX(0, days) context:context];
    }
}

- (BOOL)isExpired:(NSString *)username
          context:(WCRAFAccountContext *)context
  lastMessageTime:(NSTimeInterval)lastMessageTime {
    @synchronized (self) {
        if (![self isCurrentContext:context] || ![_held containsObject:username] ||
            !isfinite(lastMessageTime) || lastMessageTime <= 0) return NO;
        NSInteger days = [self expiryDaysForUsername:username context:context];
        if (days <= 0) return NO;
        NSTimeInterval since = [_since[username] doubleValue];
        NSTimeInterval now = [self readClock];
        return isfinite(since) && since > 0 && isfinite(now) && now > 0 &&
               now - MAX(since, lastMessageTime) >= (NSTimeInterval)days * 86400.0;
    }
}

- (WCRAFExpiryCandidate *)enqueueExpiry:(NSString *)username
                               context:(WCRAFAccountContext *)context
                       lastMessageTime:(NSTimeInterval)lastMessageTime {
    @synchronized (self) {
        if (_saving || ![self isExpired:username context:context lastMessageTime:lastMessageTime]) return nil;
        BOOL first = _pending.count == 0;
        if (first) _batch++;
        WCRAFExpiryCandidate *candidate = [WCRAFExpiryCandidate new];
        candidate.context = context;
        candidate.username = username;
        candidate.revision = _revision;
        candidate.usernameRevision = [_usernameRevisions[username] unsignedLongLongValue];
        candidate.batch = _batch;
        candidate.since = [_since[username] doubleValue];
        candidate.days = [self expiryDaysForUsername:username context:context];
        _pending[username] = candidate;
        return first ? candidate : nil;
    }
}

- (NSArray<WCRAFExpiryCandidate *> *)takeBatch:(WCRAFExpiryCandidate *)ticket {
    @synchronized (self) {
        if (![self isCurrentContext:ticket.context] ||
            ticket.revision != _revision || ticket.batch != _batch) return @[];
        NSArray *candidates = [_pending allValues];
        [_pending removeAllObjects];
        return candidates;
    }
}

- (BOOL)commitExpiry:(WCRAFExpiryCandidate *)candidate
    lastMessageTime:(NSTimeInterval)lastMessageTime {
    @synchronized (self) {
        if (![self isCurrentContext:candidate.context] || candidate.revision != _revision ||
            candidate.usernameRevision != [_usernameRevisions[candidate.username] unsignedLongLongValue] ||
            candidate.days != [self expiryDaysForUsername:candidate.username context:candidate.context] ||
            candidate.since != [_since[candidate.username] doubleValue] ||
            ![self isExpired:candidate.username context:candidate.context
                lastMessageTime:lastMessageTime]) return NO;
        NSMutableSet *names = [_held mutableCopy];
        NSMutableDictionary *times = [_since mutableCopy];
        [names removeObject:candidate.username];
        [times removeObjectForKey:candidate.username];
        // An expiry commit must not invalidate the other candidates in this batch.
        return [self saveHeld:names since:times days:_days context:candidate.context];
    }
}

- (void)reconcileTimestampsForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (_saving || ![self isCurrentContext:context]) return;
        NSTimeInterval now = [self readClock];
        if (!isfinite(now) || now <= 0) return;
        NSMutableDictionary *times = [NSMutableDictionary dictionaryWithCapacity:_held.count];
        for (NSString *name in _held) times[name] = _since[name] ?: @(now);
        if (_timestampsNeedReconcile || ![times isEqualToDictionary:_since]) {
            [self cancelPendingForContext:context];
            [self saveHeld:_held since:times days:_days context:context];
        }
    }
}

@end
