#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WCRAFAccountContext : NSObject
@property(nonatomic, copy, readonly) NSString *account;
@property(nonatomic, assign, readonly) uint64_t epoch;
@end

@interface WCRAFExpiryCandidate : NSObject
@property(nonatomic, strong, readonly) WCRAFAccountContext *context;
@property(nonatomic, copy, readonly) NSString *username;
@end

// Foundation-only state logic so it can be tested without UIKit or WeChat.
@interface WCRAFStateStore : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                accountResolver:(NSString * _Nullable (^)(void))accountResolver
                          clock:(NSTimeInterval (^)(void))clock;
- (nullable WCRAFAccountContext *)currentContext;
- (BOOL)isCurrentContext:(nullable WCRAFAccountContext *)context;
- (BOOL)isHeld:(NSString *)username context:(WCRAFAccountContext *)context;
- (BOOL)hasAnyHeldForContext:(WCRAFAccountContext *)context;
- (BOOL)setHeld:(BOOL)held username:(NSString *)username context:(WCRAFAccountContext *)context;
- (NSInteger)expiryDaysForContext:(WCRAFAccountContext *)context;
- (BOOL)setExpiryDays:(NSInteger)days context:(WCRAFAccountContext *)context;
- (BOOL)isExpired:(NSString *)username
          context:(WCRAFAccountContext *)context
  lastMessageTime:(NSTimeInterval)lastMessageTime;
- (void)cancelPendingForContext:(WCRAFAccountContext *)context;
- (void)cancelExpiry:(NSString *)username context:(WCRAFAccountContext *)context;
// Returns a scheduling ticket only for the first candidate of a new batch.
- (nullable WCRAFExpiryCandidate *)enqueueExpiry:(NSString *)username
                                        context:(WCRAFAccountContext *)context
                                lastMessageTime:(NSTimeInterval)lastMessageTime;
- (NSArray<WCRAFExpiryCandidate *> *)takeBatch:(WCRAFExpiryCandidate *)ticket;
- (BOOL)commitExpiry:(WCRAFExpiryCandidate *)candidate
    lastMessageTime:(NSTimeInterval)lastMessageTime;
- (void)reconcileTimestampsForContext:(WCRAFAccountContext *)context;
// Legacy shared keys have no owner; only an explicit, account-bound UI action imports them.
- (BOOL)importLegacyForContext:(WCRAFAccountContext *)context;
@end

NS_ASSUME_NONNULL_END
