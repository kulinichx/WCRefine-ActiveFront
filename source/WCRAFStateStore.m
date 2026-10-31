#import "WCRAFStateStore.h"
#import <math.h>

static NSString * const WCRAFAccountKeyPrefix = @"com.local.wcrefine.activefront.account.v2.";
static NSInteger const WCRAFDefaultExpiryDays = 7;

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
        context:(WCRAFAccountContext *)context {
    if (_saving || ![self isCurrentContext:context]) return NO;
    NSDictionary *record = @{
        @"schema": @2,
        @"held": [[held allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"since": [since copy],
        @"days": @(days)
    };
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
    _days = days;
    _recordExists = YES;
    _timestampsNeedReconcile = NO;
    return YES;
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
        if (held) {
            NSTimeInterval now = [self readClock];
            if (!isfinite(now) || now <= 0) return NO;
            [names addObject:username];
            times[username] = @(now);
        } else {
            [names removeObject:username];
            [times removeObjectForKey:username];
        }
        [self cancelPendingForContext:context];
        return [self saveHeld:names since:times days:_days context:context];
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
