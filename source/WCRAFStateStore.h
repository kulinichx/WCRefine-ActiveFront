#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// -1 means an unavailable native flag; rooms require a known unmuted state.
FOUNDATION_EXPORT BOOL WCRAFAllowsAutomaticActivity(NSUInteger scope, NSInteger muted, NSInteger folded);

@interface WCRAFAccountContext : NSObject
@property(nonatomic, copy, readonly) NSString *account;
@property(nonatomic, assign, readonly) uint64_t epoch;
@end

// A release belongs to the account/row/state captured at gesture begin.
@interface WCRAFSwipeIntent : NSObject
@property(nonatomic, strong, readonly) WCRAFAccountContext *context;
@property(nonatomic, copy, readonly) NSString *username;
@property(nonatomic, assign, readonly) BOOL grouped;
@property(nonatomic, assign, readonly) BOOL held;
- (instancetype)initWithUsername:(NSString *)username context:(WCRAFAccountContext *)context
                         grouped:(BOOL)grouped held:(BOOL)held;
- (BOOL)matchesUsername:(NSString *)username context:(WCRAFAccountContext *)context
               grouped:(BOOL)grouped held:(BOOL)held;
- (BOOL)shouldReturnAtDistance:(double)distance rowWidth:(double)width
                  actionWidth:(double)actionWidth ended:(BOOL)ended;
@end
FOUNDATION_EXPORT double WCRAFSwipeReturnThreshold(double rowWidth, double actionWidth);

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
// Initialize once per account; old conversations must not all reappear on upgrade.
- (BOOL)enableMessageActivityForContext:(WCRAFAccountContext *)context;
- (BOOL)isMessageActive:(NSString *)username
                context:(WCRAFAccountContext *)context
        lastMessageTime:(NSTimeInterval)lastMessageTime
            unreadCount:(NSInteger)unreadCount
                grouped:(BOOL)grouped;
// Unknown unread counts use -1 and never trigger an automatic return.
- (BOOL)observeMessageActivity:(NSString *)username
                       context:(WCRAFAccountContext *)context
               lastMessageTime:(NSTimeInterval)lastMessageTime
                   unreadCount:(NSInteger)unreadCount
                       grouped:(BOOL)grouped
                   homeVisible:(BOOL)homeVisible;
- (BOOL)hasMessageActivityForContext:(WCRAFAccountContext *)context;
- (BOOL)hasTrackedMessageActivity:(NSString *)username context:(WCRAFAccountContext *)context;
- (NSArray<NSString *> *)trackedMessageActivityUsernamesForContext:(WCRAFAccountContext *)context;
- (BOOL)needsMessageActivityObservation:(NSString *)username
                               context:(WCRAFAccountContext *)context
                       lastMessageTime:(NSTimeInterval)lastMessageTime
                           unreadCount:(NSInteger)unreadCount
                               grouped:(BOOL)grouped
                           homeVisible:(BOOL)homeVisible;
// Stop temporary tracking without modifying Held state or the return watermark.
- (BOOL)discardMessageActivity:(NSString *)username context:(WCRAFAccountContext *)context;
// Checked before the host's unread-policy fallback; never marks a message read.
- (BOOL)isMessageReturnSuppressed:(NSString *)username context:(WCRAFAccountContext *)context
                 lastMessageTime:(NSTimeInterval)lastMessageTime;
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
