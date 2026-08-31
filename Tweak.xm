#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// WCRefine 2.1-2 runtime interfaces recovered from Objective-C metadata.
// This tweak adds an "active front" projection without replacing WCRefine's
// group database or WeChat's native session ordering.

@interface WCRefineConfig : NSObject
+ (instancetype)shared;
@property(nonatomic, assign) BOOL homeGroupingExcludeUnreadEnabled;
@property(nonatomic, assign) BOOL homeGroupingUnreadBelowGroupsEnabled;
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
- (NSString *)usernameForNativeObject:(id)obj;
- (NSUInteger)groupScopeForNativeSession:(id)session;
- (BOOL)shouldExcludeNativeSessionFromGroupingForUnreadPolicy:(id)session;
@end

@interface NewMainFrameViewController : UIViewController
- (id)wcrGrouping_logicGetSessionAtIndexPath:(NSIndexPath *)indexPath;
- (void)wcrGrouping_scheduleRefreshForTrigger:(id)trigger;
- (NSArray *)wcrGrouping_tableView:(UITableView *)tableView
      editActionsForRowAtIndexPath:(NSIndexPath *)indexPath;
- (UISwipeActionsConfiguration *)wcrGrouping_tableView:(UITableView *)tableView
      trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath;
@end

static NSString * const kWCRHomeGroupsDidChangeNotification = @"WCRefineHomeGroupsDidChangeNotification";
static NSString * const kWCRUnreadQuickGroupId = @"wcrefine_quick_unread";
static NSString * const kWCRAFHeldUsernamesDefaultsKey = @"com.local.wcrefine.activefront.heldUsernames.v1";

#pragma mark - Runtime helpers

static WCRefineConfig *WCRConfig(void) {
    Class cls = NSClassFromString(@"WCRefineConfig");
    if (!cls || ![cls respondsToSelector:@selector(shared)]) return nil;
    return [cls shared];
}

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

#pragma mark - Independent Keep state

// Do NOT reuse WCRefine's homeGroupingExcludeSessions here. Users may already
// use that setting for a different purpose. Keeping our own set prevents a
// "回组" operation from deleting the user's existing WCRefine exclusions.

static NSSet<NSString *> *WCRHeldUsernameSet(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kWCRAFHeldUsernamesDefaultsKey];
    if (![stored isKindOfClass:[NSArray class]]) return [NSSet set];

    NSMutableSet<NSString *> *result = [NSMutableSet set];
    for (id obj in (NSArray *)stored) {
        if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length] > 0) {
            [result addObject:obj];
        }
    }
    return [result copy];
}

static BOOL WCRIsHeld(NSString *username) {
    if (username.length == 0) return NO;
    return [WCRHeldUsernameSet() containsObject:username];
}

static BOOL WCRPersistHeld(NSString *username, BOOL held) {
    if (username.length == 0) return NO;

    NSMutableSet<NSString *> *set = [WCRHeldUsernameSet() mutableCopy];
    BOOL wasHeld = [set containsObject:username];
    if (held) {
        [set addObject:username];
    } else {
        [set removeObject:username];
    }

    if (wasHeld == held) return NO;

    NSArray<NSString *> *stable = [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [[NSUserDefaults standardUserDefaults] setObject:stable forKey:kWCRAFHeldUsernamesDefaultsKey];
    return YES;
}

static void WCRSetHeld(NSString *username, BOOL held, id host) {
    if (WCRPersistHeld(username, held)) {
        WCRRefreshHome(host, held ? @"active_front_keep" : @"active_front_return");
    } else {
        // Still request a projection refresh: WCRefine/WeChat state may have
        // changed even when the persistent flag was already in this state.
        WCRRefreshHome(host, held ? @"active_front_keep_refresh" : @"active_front_return_refresh");
    }
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

#pragma mark - Feature defaults

static void WCREnsureActiveFrontDefaults(void) {
    WCRefineConfig *cfg = WCRConfig();
    WCRefineGroupManager *mgr = WCRGroupManager();
    if (!cfg || !mgr) return;

    // Grouped sessions with unread messages must remain native rows on home.
    cfg.homeGroupingExcludeUnreadEnabled = YES;

    // Native unread/held rows stay in WeChat's normal/front session area,
    // rather than being projected below WCRefine group rows.
    cfg.homeGroupingUnreadBelowGroupsEnabled = NO;

    // The old unread-message group is redundant in this interaction model.
    WCRefineGroup *unreadGroup = [mgr groupForId:kWCRUnreadQuickGroupId];
    if (unreadGroup && !unreadGroup.disabled) {
        unreadGroup.disabled = YES;
        [mgr updateGroup:unreadGroup];
    }
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
                // A newly assigned group starts in normal grouped state.
                // If it still has unread messages, WCRefine's unread rule keeps
                // it temporarily visible until those messages are read.
                WCRPersistHeld(username, NO);
                WCRRefreshHome(host, @"active_front_assign_group");
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
                                   BOOL *heldOut) {
    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider || !session) return NO;

    NSString *username = [provider usernameForNativeObject:session];
    if (![username isKindOfClass:[NSString class]] || username.length == 0) return NO;

    NSUInteger scope = [provider groupScopeForNativeSession:session];
    // Recovered from WCRefine 2.1-2: 1 = friend, 2 = chat room.
    if (scope != 1 && scope != 2) return NO;

    BOOL grouped = WCRIsInCustomGroup(username);
    BOOL held = grouped && WCRIsHeld(username);

    if (usernameOut) *usernameOut = username;
    if (groupedOut) *groupedOut = grouped;
    if (heldOut) *heldOut = held;
    return YES;
}

static UIContextualAction *WCRActionForSession(NewMainFrameViewController *host,
                                               UITableView *tableView,
                                               NSIndexPath *indexPath,
                                               id session) {
    NSString *username = nil;
    BOOL grouped = NO;
    BOOL held = NO;
    if (!WCRResolveSessionState(session, &username, &grouped, &held)) return nil;

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

    return [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                   title:@"保持"
                                                 handler:^(__unused UIContextualAction *action,
                                                           __unused UIView *sourceView,
                                                           void (^completionHandler)(BOOL)) {
        WCRSetHeld(username, YES, host);
        if (completionHandler) completionHandler(YES);
    }];
}

static UITableViewRowAction *WCROldStyleActionForSession(NewMainFrameViewController *host,
                                                         UITableView *tableView,
                                                         NSIndexPath *indexPath,
                                                         id session) {
    NSString *username = nil;
    BOOL grouped = NO;
    BOOL held = NO;
    if (!WCRResolveSessionState(session, &username, &grouped, &held)) return nil;

    if (!grouped) {
        return [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal
                                                   title:@"分组"
                                                 handler:^(__unused UITableViewRowAction *action,
                                                           __unused NSIndexPath *path) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WCRPresentGroupPicker(host, username, session, tableView, indexPath);
            });
        }];
    }

    if (held) {
        return [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal
                                                   title:@"回组"
                                                 handler:^(__unused UITableViewRowAction *action,
                                                           __unused NSIndexPath *path) {
            WCRSetHeld(username, NO, host);
        }];
    }

    return [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal
                                               title:@"保持"
                                             handler:^(__unused UITableViewRowAction *action,
                                                       __unused NSIndexPath *path) {
        WCRSetHeld(username, YES, host);
    }];
}

#pragma mark - Hooks

%group WCRActiveFrontHooks

// This is the key projection hook. WCRefine already calls this while building
// its home snapshot whenever unread-exclusion is enabled. Returning YES means
// "do not collect this native session into a group right now".
%hook WCRefineGroupDataProvider

- (BOOL)shouldExcludeNativeSessionFromGroupingForUnreadPolicy:(id)session {
    BOOL originalDecision = %orig;
    if (originalDecision) return YES; // native unread behavior from WCRefine

    NSString *username = [self usernameForNativeObject:session];
    if (username.length == 0) return NO;

    // A Keep flag only has meaning while the conversation still belongs to a
    // WCRefine custom group. Stale flags therefore cannot pin ungrouped rows.
    return WCRIsHeld(username) && WCRIsInCustomGroup(username);
}

%end

%hook NewMainFrameViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    WCREnsureActiveFrontDefaults();
    // Rebuild after returning from a chat. If the chat was not kept and its
    // unread count is now zero, WCRefine naturally collects it back to group.
    WCRRefreshHome(self, @"active_front_home_appear");
}

- (NSArray *)wcrGrouping_tableView:(UITableView *)tableView
       editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *original = %orig;

    id session = nil;
    if ([self respondsToSelector:@selector(wcrGrouping_logicGetSessionAtIndexPath:)]) {
        session = [self wcrGrouping_logicGetSessionAtIndexPath:indexPath];
    }

    UITableViewRowAction *ours = WCROldStyleActionForSession(self, tableView, indexPath, session);
    if (!ours) return original;

    NSMutableArray *actions = [NSMutableArray array];
    if ([original isKindOfClass:[NSArray class]]) {
        [actions addObjectsFromArray:original];
    }
    [actions addObject:ours];
    return actions;
}

- (UISwipeActionsConfiguration *)wcrGrouping_tableView:(UITableView *)tableView
       trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UISwipeActionsConfiguration *original = %orig;

    id session = nil;
    if ([self respondsToSelector:@selector(wcrGrouping_logicGetSessionAtIndexPath:)]) {
        session = [self wcrGrouping_logicGetSessionAtIndexPath:indexPath];
    }

    UIContextualAction *ours = WCRActionForSession(self, tableView, indexPath, session);
    if (!ours) return original;

    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray array];
    if ([original.actions isKindOfClass:[NSArray class]]) {
        [actions addObjectsFromArray:original.actions];
    }
    [actions addObject:ours];

    UISwipeActionsConfiguration *result = [UISwipeActionsConfiguration configurationWithActions:actions];
    result.performsFirstActionWithFullSwipe = original ? original.performsFirstActionWithFullSwipe : NO;
    return result;
}

%end

%end // WCRActiveFrontHooks

%ctor {
    @autoreleasepool {
        // Schedule initialization onto the main queue so other injected tweaks
        // (notably WCRefine itself) finish registering their classes/methods
        // before we attach to WCRefine's runtime-added hook methods.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (NSClassFromString(@"WCRefineConfig") &&
                NSClassFromString(@"WCRefineGroupManager") &&
                NSClassFromString(@"WCRefineGroupDataProvider") &&
                NSClassFromString(@"NewMainFrameViewController")) {
                %init(WCRActiveFrontHooks);
                WCREnsureActiveFrontDefaults();
            }
        });
    }
}
