#import "WCRAFStateStore.h"
#import <math.h>

static NSString * const WCRAFAccountKeyPrefix = @"com.local.wcrefine.activefront.account.v2.";
static NSInteger const WCRAFDefaultExpiryDays = 7;

BOOL WCRAFAllowsAutomaticActivity(NSUInteger scope, NSInteger muted, NSInteger folded) {
    if (folded == 1) return NO;
    return scope == 1 || (scope == 2 && muted == 0);
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

double WCRAFSwipeReturnThreshold(double rowWidth, double actionWidth) {
    if (!isfinite(rowWidth) || !isfinite(actionWidth) || actionWidth <= 0 ||
        rowWidth <= actionWidth * 2.0) return INFINITY;
    return MAX(actionWidth * 2.0, rowWidth * 0.56);
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
    NSMutableDictionary<NSString *, NSDictionary *> *_activity;
    NSInteger _days;
    BOOL _recordExists;
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
            _activity = [NSMutableDictionary dictionary];
            _days = WCRAFDefaultExpiryDays;
            _writable = YES;
            _recordExists = NO;
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
                        _recordExists = YES;
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
                                        [entry[@"readAt"] doubleValue] < 0) {
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
        context:(WCRAFAccountContext *)context {
    if (_saving || ![self isCurrentContext:context]) return NO;
    NSMutableDictionary *record = [@{
        @"schema": @2,
        @"held": [[held allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"since": [since copy],
        @"days": @(days)
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
    _activity = [activity mutableCopy];
    _days = days;
    _recordExists = YES;
    _timestampsNeedReconcile = NO;
    return YES;
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
        BOOL returnNow = grouped && unreadCount == 0 && homeVisible;
        // Keep schema-2 records readable by older builds; readAt is retired.
        NSDictionary *updated = @{@"message": @(lastMessageTime), @"readAt": @0};
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
        return (grouped && unreadCount == 0 && homeVisible) ||
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
            _days <= 0 || !isfinite(lastMessageTime) || lastMessageTime <= 0) return NO;
        NSTimeInterval since = [_since[username] doubleValue];
        NSTimeInterval now = [self readClock];
        return isfinite(since) && since > 0 && isfinite(now) && now > 0 &&
               now - MAX(since, lastMessageTime) >= (NSTimeInterval)_days * 86400.0;
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
        candidate.days = _days;
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
            candidate.days != _days || candidate.since != [_since[candidate.username] doubleValue] ||
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

- (BOOL)importLegacyForContext:(WCRAFAccountContext *)context {
    @synchronized (self) {
        if (_saving || ![self isCurrentContext:context]) return NO;
        id legacy = nil;
        id oldDays = nil;
        @try {
            legacy = [_defaults objectForKey:@"com.local.wcrefine.activefront.heldUsernames.v1"];
            if (!_recordExists) {
                oldDays = [_defaults objectForKey:@"com.local.wcrefine.activefront.holdExpiryDays.v1"];
            }
        } @catch (__unused NSException *exception) {
            return NO;
        }
        if (![legacy isKindOfClass:[NSArray class]]) return NO;
        NSTimeInterval now = [self readClock];
        if (!isfinite(now) || now <= 0) return NO;
        NSMutableSet *names = [_held mutableCopy];
        NSMutableDictionary *times = [_since mutableCopy];
        for (id name in legacy) {
            if ([name isKindOfClass:[NSString class]] && [name length] > 0 &&
                ![names containsObject:name]) {
                [names addObject:name];
                times[name] = @(now);
            }
        }
        NSInteger days = _days;
        if (!_recordExists) {
            WCRAFValidDays(oldDays, &days);
        }
        [self cancelPendingForContext:context];
        // The shared legacy keys are intentionally left untouched.
        return [self saveHeld:names since:times days:days context:context];
    }
}
@end
