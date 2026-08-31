#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// WCRefine 2.1-2 runtime interfaces discovered from Objective-C metadata.
// This patch intentionally reuses WCRefine's existing grouping/exclusion machinery.

@interface WCRefineConfig : NSObject
+ (instancetype)shared;
@property(nonatomic, assign) BOOL homeGroupingExcludeUnreadEnabled;
@property(nonatomic, assign) BOOL homeGroupingUnreadBelowGroupsEnabled;
@property(nonatomic, assign) BOOL homeGroupingExcludeSessionsEnabled;
@property(nonatomic, copy) NSArray<NSString *> *homeGroupingExcludeSessions;
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

static NSArray<NSString *> *WCRHeldUsernames(void) {
    NSArray *items = WCRConfig().homeGroupingExcludeSessions;
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

static BOOL WCRIsHeld(NSString *username) {
    if (username.length == 0) return NO;
    return [WCRHeldUsernames() containsObject:username];
}

static void WCRSetHeld(NSString *username, BOOL held, id host) {
    if (username.length == 0) return;

    WCRefineConfig *cfg = WCRConfig();
    if (!cfg) return;

    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSetWithArray:WCRHeldUsernames()];
    if (held) {
        [set addObject:username];
    } else {
        [set removeObject:username];
    }

    cfg.homeGroupingExcludeSessionsEnabled = YES;
    cfg.homeGroupingExcludeSessions = set.array;
    WCRRefreshHome(host, held ? @"active_front_keep" : @"active_front_return");
}

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

    // 1) Grouped sessions with unread messages remain native rows on WeChat home.
    cfg.homeGroupingExcludeUnreadEnabled = YES;

    // Keep those native rows in the normal/front part of the list, not below groups.
    cfg.homeGroupingUnreadBelowGroupsEnabled = NO;

    // 2) Reuse WCRefine's existing explicit exclusion list as persistent "保持" state.
    cfg.homeGroupingExcludeSessionsEnabled = YES;

    // 3) The old unread-message group is redundant in this interaction model.
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
            // Treat "分组" as an exclusive move for home-session grouping:
            // remove the member from any existing custom groups first, then add to the chosen group.
            // This prevents one conversation from appearing in multiple custom groups.
            NSArray<NSString *> *existing = [mgr groupIdsContainingMember:username] ?: @[];
            NSSet<NSString *> *customIds = WCRCustomGroupIdSet();
            for (NSString *existingGroupId in existing) {
                if ([customIds containsObject:existingGroupId] && ![existingGroupId isEqualToString:groupId]) {
                    [mgr removeMember:username fromGroup:existingGroupId];
                }
            }

            BOOL ok = [mgr addMember:username toGroup:groupId];
            if (ok) {
                // Group assignment cancels an old explicit Keep state. If this conversation
                // is unread it still stays on home through WCRefine's unread-exclusion rule;
                // once read it will naturally return to the newly selected group.
                WCRSetHeld(username, NO, host);
                WCRRefreshHome(host, @"active_front_assign_group");
            }
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        popover.sourceView = cell ?: host.view;
        popover.sourceRect = cell ? cell.bounds : host.view.bounds;
    }

    [WCRTopPresenter(host) presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Dynamic swipe action

static UIContextualAction *WCRActionForSession(NewMainFrameViewController *host,
                                               UITableView *tableView,
                                               NSIndexPath *indexPath,
                                               id session) {
    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider || !session) return nil;

    NSString *username = [provider usernameForNativeObject:session];
    if (![username isKindOfClass:[NSString class]] || username.length == 0) return nil;

    NSUInteger scope = [provider groupScopeForNativeSession:session];
    // WCRefine metadata/disassembly identifies 1=friend and 2=chat room.
    if (scope != 1 && scope != 2) return nil;

    BOOL grouped = WCRIsInCustomGroup(username);
    BOOL held = grouped && WCRIsHeld(username);

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
    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider || !session) return nil;

    NSString *username = [provider usernameForNativeObject:session];
    if (![username isKindOfClass:[NSString class]] || username.length == 0) return nil;

    NSUInteger scope = [provider groupScopeForNativeSession:session];
    if (scope != 1 && scope != 2) return nil;

    BOOL grouped = WCRIsInCustomGroup(username);
    BOOL held = grouped && WCRIsHeld(username);

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

%hook NewMainFrameViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    WCREnsureActiveFrontDefaults();
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
