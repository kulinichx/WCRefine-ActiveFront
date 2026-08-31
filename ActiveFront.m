#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const kWCRAFVersion = @"1.1";

static void WCRAFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void WCRAFLog(NSString *format, ...) {
    if (format.length == 0) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[WCRefineActiveFront %@] %@", kWCRAFVersion, message);
}

#define WCRAF_LOG(...) WCRAFLog(__VA_ARGS__)

// WCRefine 2.1-2 runtime interfaces recovered from Objective-C metadata.
// This tweak adds an "active front" projection without replacing WCRefine's
// group database or WeChat's native session ordering.

@interface WCRefineConfig : NSObject
+ (instancetype)shared;
@property(nonatomic, assign) BOOL homeGroupingExcludeUnreadEnabled;
@end

@interface WCRefineGroup : NSObject
@property(nonatomic, copy) NSString *groupId;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) NSUInteger scope;
@property(nonatomic, assign) BOOL disabled;
@end

@interface WCRefineGroupManager : NSObject
+ (instancetype)shared;
- (NSArray<WCRefineGroup *> *)customGroups;
- (NSArray<NSString *> *)groupIdsContainingMember:(NSString *)member;
- (BOOL)addMember:(NSString *)member toGroup:(NSString *)groupId;
- (BOOL)removeMember:(NSString *)member fromGroup:(NSString *)groupId;
- (WCRefineGroup *)groupForId:(NSString *)groupId;
- (BOOL)updateGroup:(WCRefineGroup *)group;
@end

@interface WCRefineGroupDataProvider : NSObject
+ (instancetype)shared;
- (id)nativeSessionFromObject:(id)obj;
- (NSString *)usernameForNativeObject:(id)obj;
- (NSUInteger)groupScopeForNativeSession:(id)session;
- (BOOL)shouldExcludeNativeSessionFromGroupingForUnreadPolicy:(id)session;
@end

@interface WCRQuickChatRuntime : NSObject
- (void)noteIncomingMessageForUsername:(NSString *)username;
- (void)noteReadForUsername:(NSString *)username;
@end

@interface NewMainFrameViewController : UIViewController
- (id)wcrGrouping_logicGetSessionAtIndexPath:(NSIndexPath *)indexPath;
- (void)wcrGrouping_scheduleRefreshForTrigger:(id)trigger;
- (void)wcrGrouping_viewDidAppear:(BOOL)animated;
- (UISwipeActionsConfiguration *)wcrGrouping_tableView:(UITableView *)tableView
      trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath;
@end

static NSString * const kWCRHomeGroupsDidChangeNotification = @"WCRefineHomeGroupsDidChangeNotification";
static NSString * const kWCRAFHeldUsernamesDefaultsKey = @"com.local.wcrefine.activefront.heldUsernames.v1";
static NSString * const kWCRAFSurfacedUsernamesDefaultsKey = @"com.local.wcrefine.activefront.surfacedUsernames.v1";

// A short startup fallback catches conversations that became unread while WeChat
// was not running. After the window closes, only WCRefine's real incoming-message
// bridge may create new Active Front state, so manual "mark unread" does not
// become a long-lived false positive.
static BOOL gWCRBootstrapUnreadFallbackOpen = YES;
static const NSTimeInterval kWCRBootstrapUnreadFallbackSeconds = 12.0;

#pragma mark - Runtime helpers

static WCRefineGroupManager *WCRGroupManager(void) {
    Class cls = NSClassFromString(@"WCRefineGroupManager");
    if (!cls || ![cls respondsToSelector:@selector(shared)]) return nil;
    return [cls shared];
}

static WCRefineGroupDataProvider *WCRDataProvider(void) {
    Class cls = NSClassFromString(@"WCRefineGroupDataProvider");
    if (!cls || ![cls respondsToSelector:@selector(shared)]) return nil;
    return [cls shared];
}

static void WCRRefreshHome(id host, NSString *reason) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kWCRHomeGroupsDidChangeNotification object:nil];
    if ([host respondsToSelector:@selector(wcrGrouping_scheduleRefreshForTrigger:)]) {
        [host wcrGrouping_scheduleRefreshForTrigger:(reason ?: @"active_front")];
    }
}

// Never rebuild the projection while UIKit is still completing a swipe/action
// transition. One main-queue turn is enough to let the action sheet / swipe
// state settle before WCRefine reloads its snapshot.
static void WCRRefreshHomeDeferred(id host, NSString *reason) {
    __weak id weakHost = host;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCRRefreshHome(weakHost, reason);
    });
}

#pragma mark - Independent Active Front state

// Keep and Surfaced are deliberately independent from WCRefine's own
// homeGroupingExcludeSessions. Keep is user intent; Surfaced is a real
// incoming-message event that has not yet been consumed/read.

static NSObject *WCRAFStateLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static NSSet<NSString *> *WCRStringSetForDefaultsKey(NSString *key) {
    if (key.length == 0) return [NSSet set];
    @synchronized (WCRAFStateLock()) {
        id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        if (![stored isKindOfClass:[NSArray class]]) return [NSSet set];

        NSMutableSet<NSString *> *result = [NSMutableSet set];
        for (id obj in (NSArray *)stored) {
            if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length] > 0) {
                [result addObject:obj];
            }
        }
        return [result copy];
    }
}

static BOOL WCRPersistSetMembership(NSString *key, NSString *username, BOOL enabled) {
    if (key.length == 0 || username.length == 0) return NO;

    @synchronized (WCRAFStateLock()) {
        id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        NSMutableSet<NSString *> *set = [NSMutableSet set];
        if ([stored isKindOfClass:[NSArray class]]) {
            for (id obj in (NSArray *)stored) {
                if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length] > 0) {
                    [set addObject:obj];
                }
            }
        }

        BOOL previous = [set containsObject:username];
        if (enabled) {
            [set addObject:username];
        } else {
            [set removeObject:username];
        }
        if (previous == enabled) return NO;

        NSArray<NSString *> *stable = [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
        [[NSUserDefaults standardUserDefaults] setObject:stable forKey:key];
        return YES;
    }
}

static BOOL WCRIsHeld(NSString *username) {
    return username.length > 0 &&
           [WCRStringSetForDefaultsKey(kWCRAFHeldUsernamesDefaultsKey) containsObject:username];
}

static BOOL WCRPersistHeld(NSString *username, BOOL held) {
    return WCRPersistSetMembership(kWCRAFHeldUsernamesDefaultsKey, username, held);
}

static BOOL WCRIsSurfaced(NSString *username) {
    return username.length > 0 &&
           [WCRStringSetForDefaultsKey(kWCRAFSurfacedUsernamesDefaultsKey) containsObject:username];
}

static BOOL WCRPersistSurfaced(NSString *username, BOOL surfaced) {
    return WCRPersistSetMembership(kWCRAFSurfacedUsernamesDefaultsKey, username, surfaced);
}

static BOOL WCRHasAnyActiveFrontProjection(void) {
    return WCRStringSetForDefaultsKey(kWCRAFHeldUsernamesDefaultsKey).count > 0 ||
           WCRStringSetForDefaultsKey(kWCRAFSurfacedUsernamesDefaultsKey).count > 0;
}

static void WCRRefreshHomeGlobal(__unused NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kWCRHomeGroupsDidChangeNotification
                                                            object:nil];
    });
}

static void WCRScheduleBootstrapUnreadFallbackClose(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kWCRBootstrapUnreadFallbackSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gWCRBootstrapUnreadFallbackOpen) return;
        gWCRBootstrapUnreadFallbackOpen = NO;

        // Force one clean projection after the compatibility window closes. Any
        // already-recorded Surfaced row remains native until it is actually read.
        [[NSNotificationCenter defaultCenter] postNotificationName:kWCRHomeGroupsDidChangeNotification
                                                            object:nil];
    });
}

static void WCRSetHeld(NSString *username, BOOL held, id host) {
    BOOL changed = WCRPersistHeld(username, held);
    WCRAF_LOG(@"%@ %@", held ? @"keep" : @"return-to-group", username ?: @"<nil>");

    // "回组" is an explicit user decision: clear the current transient
    // surfaced state as well. A later new incoming message can surface it again.
    if (!held) {
        changed = WCRPersistSurfaced(username, NO) || changed;
    }

    NSString *reason = nil;
    if (held) {
        reason = changed ? @"active_front_keep" : @"active_front_keep_refresh";
    } else {
        reason = changed ? @"active_front_return" : @"active_front_return_refresh";
    }
    WCRRefreshHomeDeferred(host, reason);
}

#pragma mark - Group membership helpers

static NSSet<NSString *> *WCRCustomGroupIdSet(void) {
    WCRefineGroupManager *mgr = WCRGroupManager();
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (WCRefineGroup *group in mgr.customGroups ?: @[]) {
        if (group.groupId.length > 0) [ids addObject:group.groupId];
    }
    return ids;
}

static BOOL WCRIsInCustomGroup(NSString *username) {
    if (username.length == 0) return NO;

    WCRefineGroupManager *mgr = WCRGroupManager();
    if (!mgr) return NO;

    NSArray<NSString *> *memberGroupIds = [mgr groupIdsContainingMember:username] ?: @[];
    if (memberGroupIds.count == 0) return NO;

    NSSet<NSString *> *customIds = WCRCustomGroupIdSet();
    for (NSString *groupId in memberGroupIds) {
        if ([customIds containsObject:groupId]) return YES;
    }
    return NO;
}

// Keep/Surfaced flags are meaningful only while a session belongs to a
// custom group. Prune stale state if the user moves a conversation out of all
// groups through WCRefine's own UI.
static void WCRPruneStateKeyToGroupedMembers(NSString *key) {
    NSSet<NSString *> *stored = WCRStringSetForDefaultsKey(key);
    if (stored.count == 0) return;

    NSMutableSet<NSString *> *clean = [NSMutableSet setWithCapacity:stored.count];
    for (NSString *username in stored) {
        if (WCRIsInCustomGroup(username)) [clean addObject:username];
    }

    if ([clean isEqualToSet:stored]) return;
    @synchronized (WCRAFStateLock()) {
        NSArray<NSString *> *stable = [[clean allObjects] sortedArrayUsingSelector:@selector(compare:)];
        [[NSUserDefaults standardUserDefaults] setObject:stable forKey:key];
    }
}

static void WCRPruneStaleActiveFrontState(void) {
    WCRPruneStateKeyToGroupedMembers(kWCRAFHeldUsernamesDefaultsKey);
    WCRPruneStateKeyToGroupedMembers(kWCRAFSurfacedUsernamesDefaultsKey);
}

// WCRefine's original unread policy intentionally excludes muted/red-dot
// sessions. Active Front needs the raw unread count only to know when a
// genuinely surfaced conversation has been consumed and may return to group.
static BOOL WCRSessionUnreadState(id session, BOOL *knownOut) {
    if (knownOut) *knownOut = NO;
    if (!session) return NO;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    id native = provider ? [provider nativeSessionFromObject:session] : nil;
    if (!native) native = session;

    NSArray<NSString *> *keys = @[@"m_uUnReadCount", @"m_unReadCount", @"unReadCount"];
    for (NSString *key in keys) {
        @try {
            id value = [native valueForKey:key];
            if ([value respondsToSelector:@selector(unsignedIntegerValue)]) {
                if (knownOut) *knownOut = YES;
                return [value unsignedIntegerValue] > 0;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    return NO;
}

static NSArray<WCRefineGroup *> *WCRAvailableGroupsForScope(NSUInteger scope) {
    WCRefineGroupManager *mgr = WCRGroupManager();
    NSMutableArray<WCRefineGroup *> *groups = [NSMutableArray array];
    for (WCRefineGroup *group in mgr.customGroups ?: @[]) {
        if (group.disabled) continue;
        if (group.scope != scope) continue;
        if (group.groupId.length == 0) continue;
        [groups addObject:group];
    }
    return groups;
}

#pragma mark - Group picker

static UIViewController *WCRTopPresenter(UIViewController *fallback) {
    UIViewController *vc = fallback;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void WCRShowNoGroupsAlert(UIViewController *host) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"分组"
                                                                   message:@"当前没有适用于这个会话的分组。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [WCRTopPresenter(host) presentViewController:alert animated:YES completion:nil];
}

static void WCRPresentGroupPicker(NewMainFrameViewController *host,
                                  NSString *username,
                                  id session,
                                  UITableView *tableView,
                                  NSIndexPath *indexPath) {
    if (!host || username.length == 0 || !session) return;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    WCRefineGroupManager *mgr = WCRGroupManager();
    if (!provider || !mgr) return;

    NSUInteger scope = [provider groupScopeForNativeSession:session];
    NSArray<WCRefineGroup *> *groups = WCRAvailableGroupsForScope(scope);
    if (groups.count == 0) {
        WCRShowNoGroupsAlert(host);
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"分配到分组"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

    for (WCRefineGroup *group in groups) {
        NSString *title = group.name.length ? group.name : @"未命名分组";
        NSString *groupId = [group.groupId copy];

        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            // "分组" means MOVE for this feature: remove the conversation from
            // other custom groups first, then add it to the selected group.
            NSArray<NSString *> *existing = [mgr groupIdsContainingMember:username] ?: @[];
            NSSet<NSString *> *customIds = WCRCustomGroupIdSet();
            for (NSString *existingGroupId in existing) {
                if ([customIds containsObject:existingGroupId] &&
                    ![existingGroupId isEqualToString:groupId]) {
                    [mgr removeMember:username fromGroup:existingGroupId];
                }
            }

            BOOL ok = [mgr addMember:username toGroup:groupId];
            if (ok) {
                WCRAF_LOG(@"assigned %@ -> %@", username, groupId);
                // Assignment itself never implies Keep. If this native row is
                // currently unread, preserve it as a transient surfaced row so
                // grouping an active conversation does not make it vanish before
                // the user reads it.
                WCRPersistHeld(username, NO);
                BOOL unreadKnown = NO;
                BOOL hasUnread = WCRSessionUnreadState(session, &unreadKnown);
                WCRPersistSurfaced(username, unreadKnown && hasUnread);
                WCRRefreshHomeDeferred(host, @"active_front_assign_group");
            }
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        popover.sourceView = cell ?: host.view;
        popover.sourceRect = cell ? cell.bounds : host.view.bounds;
    }

    [WCRTopPresenter(host) presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Dynamic swipe actions

static BOOL WCRResolveSessionState(id session,
                                   NSString **usernameOut,
                                   BOOL *groupedOut,
                                   BOOL *heldOut,
                                   BOOL *surfacedOut) {
    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider || !session) return NO;

    NSString *username = [provider usernameForNativeObject:session];
    if (![username isKindOfClass:[NSString class]] || username.length == 0) return NO;

    NSUInteger scope = [provider groupScopeForNativeSession:session];
    // Recovered from WCRefine 2.1-2: 1 = friend, 2 = chat room.
    if (scope != 1 && scope != 2) return NO;

    BOOL grouped = WCRIsInCustomGroup(username);
    BOOL held = grouped && WCRIsHeld(username);
    BOOL surfaced = grouped && WCRIsSurfaced(username);

    if (usernameOut) *usernameOut = username;
    if (groupedOut) *groupedOut = grouped;
    if (heldOut) *heldOut = held;
    if (surfacedOut) *surfacedOut = surfaced;
    return YES;
}

static UIContextualAction *WCRActionForSession(NewMainFrameViewController *host,
                                               UITableView *tableView,
                                               NSIndexPath *indexPath,
                                               id session) {
    NSString *username = nil;
    BOOL grouped = NO;
    BOOL held = NO;
    BOOL surfaced = NO;
    if (!WCRResolveSessionState(session, &username, &grouped, &held, &surfaced)) return nil;

    if (!grouped) {
        return [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                       title:@"分组"
                                                     handler:^(__unused UIContextualAction *action,
                                                               __unused UIView *sourceView,
                                                               void (^completionHandler)(BOOL)) {
            if (completionHandler) completionHandler(YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                WCRPresentGroupPicker(host, username, session, tableView, indexPath);
            });
        }];
    }

    if (held) {
        return [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                       title:@"回组"
                                                     handler:^(__unused UIContextualAction *action,
                                                               __unused UIView *sourceView,
                                                               void (^completionHandler)(BOOL)) {
            WCRSetHeld(username, NO, host);
            if (completionHandler) completionHandler(YES);
        }];
    }

    // Only a genuinely surfaced grouped row should offer Keep. If WCRefine is
    // showing this grouped native row for some unrelated feature, leave its
    // swipe menu untouched.
    if (!surfaced) return nil;

    return [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                   title:@"保持"
                                                 handler:^(__unused UIContextualAction *action,
                                                           __unused UIView *sourceView,
                                                           void (^completionHandler)(BOOL)) {
        WCRSetHeld(username, YES, host);
        if (completionHandler) completionHandler(YES);
    }];
}


#pragma mark - Manual Substrate hooks for TrollStore injection

typedef void (*WCRMSHookMessageExFn)(Class cls, SEL sel, IMP replacement, IMP *result);
static WCRMSHookMessageExFn gMSHookMessageEx = NULL;

static BOOL WCRResolveSubstrateHookAPI(void) {
    if (gMSHookMessageEx) return YES;
    gMSHookMessageEx = (WCRMSHookMessageExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (gMSHookMessageEx) {
        WCRAF_LOG(@"resolved MSHookMessageEx");
    }
    return gMSHookMessageEx != NULL;
}

static BOOL (*orig_configExcludeUnread)(id, SEL) = NULL;
static BOOL hook_configExcludeUnread(id self, SEL _cmd) {
    BOOL original = orig_configExcludeUnread ? orig_configExcludeUnread(self, _cmd) : NO;

    // WCRefine guards its per-session unread-policy predicate behind this
    // getter. Temporarily ensure that predicate runs only while ActiveFront
    // actually needs projection work (or during the short startup recovery
    // window). Outside those cases the user's WCRefine setting is untouched.
    return original || gWCRBootstrapUnreadFallbackOpen || WCRHasAnyActiveFrontProjection();
}

static BOOL (*orig_shouldExclude)(id, SEL, id) = NULL;
static BOOL hook_shouldExclude(id self, SEL _cmd, id session) {
    BOOL originalDecision = orig_shouldExclude ? orig_shouldExclude(self, _cmd, session) : NO;
    NSString *username = [self usernameForNativeObject:session];
    if (username.length == 0) return originalDecision;
    if (WCRIsHeld(username) && WCRIsInCustomGroup(username)) return YES;
    if (WCRIsSurfaced(username) && WCRIsInCustomGroup(username)) {
        BOOL unreadKnown = NO;
        BOOL hasUnread = WCRSessionUnreadState(session, &unreadKnown);
        if (!unreadKnown || hasUnread) return YES;
        WCRPersistSurfaced(username, NO);
        return NO;
    }
    if (gWCRBootstrapUnreadFallbackOpen && WCRIsInCustomGroup(username)) {
        BOOL unreadKnown = NO;
        BOOL hasUnread = WCRSessionUnreadState(session, &unreadKnown);
        if ((unreadKnown && hasUnread) || (!unreadKnown && originalDecision)) {
            WCRPersistSurfaced(username, YES);
            return YES;
        }
    }

    // Do not replace WCRefine's own unread behavior. Its unread-message
    // feature remains entirely user-controlled; ActiveFront adds only the
    // Held/Surfaced cases above and otherwise preserves WCRefine's decision.
    return originalDecision;
}

static void (*orig_noteIncoming)(id, SEL, NSString *) = NULL;
static void hook_noteIncoming(id self, SEL _cmd, NSString *username) {
    BOOL valid = [username isKindOfClass:[NSString class]] && username.length > 0;
    BOOL grouped = valid && WCRIsInCustomGroup(username);
    if (grouped) {
        WCRPersistSurfaced(username, YES);
        WCRAF_LOG(@"incoming surfaced: %@", username);
    }
    if (orig_noteIncoming) orig_noteIncoming(self, _cmd, username);
    if (grouped) WCRRefreshHomeGlobal(@"active_front_incoming");
}

static void (*orig_noteRead)(id, SEL, NSString *) = NULL;
static void hook_noteRead(id self, SEL _cmd, NSString *username) {
    BOOL valid = [username isKindOfClass:[NSString class]] && username.length > 0;
    BOOL wasSurfaced = valid && WCRIsSurfaced(username);
    if (wasSurfaced) {
        WCRPersistSurfaced(username, NO);
        WCRAF_LOG(@"read consumed surfaced: %@", username);
    }
    if (orig_noteRead) orig_noteRead(self, _cmd, username);
    if (wasSurfaced) WCRRefreshHomeGlobal(@"active_front_read");
}

static void (*orig_groupingViewDidAppear)(id, SEL, BOOL) = NULL;
static void hook_groupingViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_groupingViewDidAppear) orig_groupingViewDidAppear(self, _cmd, animated);
    WCRPruneStaleActiveFrontState();
    WCRRefreshHomeDeferred(self, @"active_front_home_appear");
}


static UISwipeActionsConfiguration *(*orig_trailingActions)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static UISwipeActionsConfiguration *hook_trailingActions(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) API_AVAILABLE(ios(11.0)) {
    UISwipeActionsConfiguration *original = orig_trailingActions ? orig_trailingActions(self, _cmd, tableView, indexPath) : nil;
    id session = [self respondsToSelector:@selector(wcrGrouping_logicGetSessionAtIndexPath:)] ? [self wcrGrouping_logicGetSessionAtIndexPath:indexPath] : nil;
    UIContextualAction *ours = WCRActionForSession(self, tableView, indexPath, session);
    if (!ours) return original;
    NSMutableArray *actions = [NSMutableArray arrayWithObject:ours];
    if ([original.actions isKindOfClass:[NSArray class]]) [actions addObjectsFromArray:original.actions];
    UISwipeActionsConfiguration *result = [UISwipeActionsConfiguration configurationWithActions:actions];
    result.performsFirstActionWithFullSwipe = NO;
    return result;
}

static BOOL gWCRAFHooksInstalled = NO;

static BOOL WCRRuntimeReadyForHooks(void) {
    if (!WCRResolveSubstrateHookAPI()) return NO;
    Class config = NSClassFromString(@"WCRefineConfig");
    Class manager = NSClassFromString(@"WCRefineGroupManager");
    Class provider = NSClassFromString(@"WCRefineGroupDataProvider");
    Class quickRuntime = NSClassFromString(@"WCRQuickChatRuntime");
    Class mainFrame = NSClassFromString(@"NewMainFrameViewController");
    if (!config || !manager || !provider || !quickRuntime || !mainFrame) return NO;
    return [provider instancesRespondToSelector:@selector(shouldExcludeNativeSessionFromGroupingForUnreadPolicy:)] &&
           [quickRuntime instancesRespondToSelector:@selector(noteIncomingMessageForUsername:)] &&
           [quickRuntime instancesRespondToSelector:@selector(noteReadForUsername:)] &&
           [mainFrame instancesRespondToSelector:@selector(wcrGrouping_viewDidAppear:)] &&
           [mainFrame instancesRespondToSelector:@selector(wcrGrouping_scheduleRefreshForTrigger:)] &&
           [mainFrame instancesRespondToSelector:@selector(wcrGrouping_logicGetSessionAtIndexPath:)] &&
           [mainFrame instancesRespondToSelector:@selector(wcrGrouping_tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:)];
}

static void WCRInstallHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (cls && [cls instancesRespondToSelector:sel] && gMSHookMessageEx) {
        gMSHookMessageEx(cls, sel, replacement, original);
    }
}

static void WCRInstallHooks(void) {
    WCRAF_LOG(@"installing runtime hooks");
    Class config = NSClassFromString(@"WCRefineConfig");
    Class provider = NSClassFromString(@"WCRefineGroupDataProvider");
    Class quickRuntime = NSClassFromString(@"WCRQuickChatRuntime");
    Class mainFrame = NSClassFromString(@"NewMainFrameViewController");

    WCRInstallHook(config, @selector(homeGroupingExcludeUnreadEnabled), (IMP)hook_configExcludeUnread, (IMP *)&orig_configExcludeUnread);
    WCRInstallHook(provider, @selector(shouldExcludeNativeSessionFromGroupingForUnreadPolicy:), (IMP)hook_shouldExclude, (IMP *)&orig_shouldExclude);
    WCRInstallHook(quickRuntime, @selector(noteIncomingMessageForUsername:), (IMP)hook_noteIncoming, (IMP *)&orig_noteIncoming);
    WCRInstallHook(quickRuntime, @selector(noteReadForUsername:), (IMP)hook_noteRead, (IMP *)&orig_noteRead);
    WCRInstallHook(mainFrame, @selector(wcrGrouping_viewDidAppear:), (IMP)hook_groupingViewDidAppear, (IMP *)&orig_groupingViewDidAppear);
    WCRInstallHook(mainFrame, @selector(wcrGrouping_tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:), (IMP)hook_trailingActions, (IMP *)&orig_trailingActions);
}

static void WCRTryInstallHooks(NSUInteger attemptsRemaining) {
    if (gWCRAFHooksInstalled) return;
    if (WCRRuntimeReadyForHooks()) {
        WCRInstallHooks();
        gWCRAFHooksInstalled = YES;
        WCRAF_LOG(@"hooks installed successfully");
        WCRPruneStaleActiveFrontState();
        WCRScheduleBootstrapUnreadFallbackClose();
        return;
    }
    if (attemptsRemaining == 0) {
        WCRAF_LOG(@"hook installation timed out; WCRefine/Substrate runtime not ready");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WCRTryInstallHooks(attemptsRemaining - 1);
    });
}

__attribute__((constructor)) static void WCRActiveFrontEntry(void) {
    @autoreleasepool {
        WCRAF_LOG(@"dylib loaded; waiting for WCRefine runtime");
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRTryInstallHooks(40); // allow up to ~10s for injected WCRefine/Substrate startup
        });
    }
}
