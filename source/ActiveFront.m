// WCRefineGroup source repair, based on ActiveFront.RIGHT_v1_9_8.m.
// WCRefine ActiveFront - v1.9.26 bounded grouped swipe viewport.
// Friend/chat-room messages surface temporarily without changing membership.
// Unread sessions stay visible until read or explicitly returned by a long swipe.
// Read + home-visible returns immediately unless Held. No activity timers.
// v1.9.7: Held sessions return to their group automatically after N days
// without a new message (N = never/3/7/14/30, default 7). Choose N by
// long-pressing the right-swipe 保持/回组 button. No timers: expiry is
// evaluated lazily inside WCRefine's own home refresh pass.
// v1.9.7: The right-swipe title is tinted per action (分组 blue, 保持 orange,
// 回组 green) on the transparent background, so it stays readable in light
// mode (was fixed white = invisible on a white cell).
//
// v1.9.6 (WCRefine 2.1-8 compatibility, plan B):
// v1.9.6: WCRefine's own "不收纳非免打扰未读" switch is now the single source of
// truth for unread sessions. ActiveFront only projects its own Held sessions:
// - the getter is forced only while Held sessions exist, and WCRefine's settings
//   page always sees the user's real value;
// - non-Held sessions follow the real switch (switch off -> never excluded);
// - removed Surfaced state, the 12 s startup unread fallback and the
//   noteIncoming/noteRead hooks (never called by WCRefine 2.1-7 / 2.1-8);
// - Held set is cached in memory (the predicate runs once per home session).
//
// v1.9.5 RC1 built on the validated v1.9.2 state machine.
// Identity fix: rendered m_cellData stays authoritative, while WCRefine synthetic
// WCRefine_groupEntry_* rows are rejected and never fall through to indexPath.
// Release scope: ActiveFront right-swipe only. No OpenIM layout experiment,
// no diagnostic gesture, and no startup readiness alert.
//
// v1.8 keeps the v1.7 gesture path that already works on-device:
// - WCRefine owns a separate right-only UIPanGestureRecognizer on NewMainFrameCell.
// - LEFT swipe remains WeChat/WCRefine's existing native path.
// - The action area has no colored background.
//
// Real actions:
// - ungrouped -> 分组 (pick an existing WCRefine custom group)
// - grouped + !Held -> 保持
// - grouped + Held -> 回组
//
// ActiveFront never replaces WCRefine's group database. It only uses WCRefine's
// existing group manager/provider APIs and maintains independent Held projection
// state (v1.9.6: Surfaced state removed).

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "WCRAFStateStore.h"
#import <objc/runtime.h>
#import <math.h>
#import <stdarg.h>
#import <string.h>
#import <os/log.h>
#import "WCRAFGroupSwipe.h"

static const CGFloat kWCRActionWidth = 60.0;
static const CGFloat kWCRReturnActionWidth = 82.0;
static __weak id gWCRAppearedHomeController;

static const void *kWCRPanKey          = &kWCRPanKey;
static const void *kWCRActionViewKey   = &kWCRActionViewKey;
static const void *kWCRButtonKey       = &kWCRButtonKey;
static const void *kWCRMuteButtonKey   = &kWCRMuteButtonKey;
static const void *kWCROpenKey         = &kWCROpenKey;
static const void *kWCRTrackingKey     = &kWCRTrackingKey;
static const void *kWCRStartOffsetKey  = &kWCRStartOffsetKey;
static const void *kWCRBoundUsernameKey = &kWCRBoundUsernameKey;
static const void *kWCRCanonicalKnownKey = &kWCRCanonicalKnownKey;
static const void *kWCRCanonicalSessionKey = &kWCRCanonicalSessionKey;
static const void *kWCRCanonicalUsernameKey = &kWCRCanonicalUsernameKey;
static const void *kWCRCanonicalScopeKey = &kWCRCanonicalScopeKey;
static const void *kWCRNativeCloseLatchKey = &kWCRNativeCloseLatchKey;
static const void *kWCRCanonicalAccountKey = &kWCRCanonicalAccountKey;
static const void *kWCRSwipeIntentKey = &kWCRSwipeIntentKey;
static const void *kWCRSwipeForegroundKey = &kWCRSwipeForegroundKey;
static const void *kWCRSwipeHiddenViewsKey = &kWCRSwipeHiddenViewsKey;
static const void *kWCRSwipeOffsetKey = &kWCRSwipeOffsetKey;
static const void *kWCRSwipeRenderedKey = &kWCRSwipeRenderedKey;
static const void *kWCRPanConsumedKey = &kWCRPanConsumedKey;
static NSHashTable<UITableViewCell *> *gWCRSwipeCells;


static NSString * const kWCRAFVersion = @"1.9.26-source";
static NSString * const kWCRHomeGroupsDidChangeNotification = @"WCRefineHomeGroupsDidChangeNotification";
static const NSInteger kWCRAFDefaultHoldExpiryDays = 3;


#ifndef WCRAF_DIAGNOSTICS
#define WCRAF_DIAGNOSTICS 0
#endif

static void WCRAFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void WCRAFLog(NSString *format, ...) {
#if WCRAF_DIAGNOSTICS
    if (format.length == 0) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[WCRefineGroup %@] %@", kWCRAFVersion, message);
#else
    (void)format;
#endif
}
#define WCRAF_LOG(...) WCRAFLog(__VA_ARGS__)

// Opt-in, process-bounded callback tracing; never record conversation identity.
static BOOL gWCRGroupSwipeDiagnostics;
static NSUInteger gWCRGroupSwipeDiagnosticCount;
static void WCRGroupSwipeTrace(NSString *event, NSString *detail) {
    if (!gWCRGroupSwipeDiagnostics || gWCRGroupSwipeDiagnosticCount >= 48) return;
    gWCRGroupSwipeDiagnosticCount++;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
        "[WCRefineGroup swipe] %{public}s %{public}s",
        event.UTF8String, detail.UTF8String);
}

// Per-cell identity logs are useful during bring-up, but they run in table
// display/gesture paths and expose internal usernames to the unified log.
// Keep production builds quiet unless explicitly compiled for diagnostics.
#ifndef WCRAF_VERBOSE_CELL_LOGS
#define WCRAF_VERBOSE_CELL_LOGS 0
#endif

#if WCRAF_VERBOSE_CELL_LOGS
#define WCRAF_CELL_LOG(...) WCRAFLog(__VA_ARGS__)
#else
#define WCRAF_CELL_LOG(...) do { } while (0)
#endif

@interface WCRefineConfig : NSObject
+ (instancetype)shared;
@property(nonatomic, assign) BOOL homeGroupingExcludeUnreadEnabled;
@end

@interface WCRefineHelper : NSObject
+ (NSString *)wcr_resolveCurrentUserWxidUncached;
@end

@interface WCRefineGroup : NSObject
@property(nonatomic, copy) NSString *groupId;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) NSUInteger scope;
@property(nonatomic, assign) BOOL disabled;
@property(nonatomic, copy) NSSet<NSString *> *members;
@end

@interface WCRefineGroupManager : NSObject
+ (instancetype)shared;
- (NSArray<WCRefineGroup *> *)customGroups;
- (NSArray<NSString *> *)groupIdsContainingMember:(NSString *)member;
- (BOOL)addMember:(NSString *)member toGroup:(NSString *)groupId;
- (BOOL)removeMember:(NSString *)member fromGroup:(NSString *)groupId;
@end

@interface WCRefineGroupDataProvider : NSObject
+ (instancetype)shared;
- (id)nativeSessionFromObject:(id)obj;
- (NSString *)usernameForNativeObject:(id)obj;
- (NSUInteger)groupScopeForNativeSession:(id)session;
- (BOOL)shouldExcludeNativeSessionFromGroupingForUnreadPolicy:(id)session;
- (id)fulfilledSessionForUsername:(NSString *)username fallback:(id)fallback;
@end

static WCRAFStateStore *WCRAFStore(void);
static void WCRInvalidateGroupIndex(void);
static void WCRCancelReturnAnimation(void);
static void WCRInvalidateOutgoing(NSString *username, WCRAFAccountContext *context);
static void WCRInvalidateSendAcknowledgments(NSString *username, WCRAFAccountContext *context);
static void WCRRefreshHomeGlobal(NSString *reason, WCRAFAccountContext *context);
static void WCRReminderPendingNotice(void);
static UIViewController *WCRTopVC(void);


@interface NewMainFrameViewController : UIViewController
- (id)logicGetSessionAtIndexPath:(NSIndexPath *)indexPath;
- (id)wcrGrouping_logicGetSessionAtIndexPath:(NSIndexPath *)indexPath;
- (id)wcrGrouping_logicGetCellDataAtIndexPath:(NSIndexPath *)indexPath;
- (void)wcrGrouping_tableView:(UITableView *)tableView
              willDisplayCell:(UITableViewCell *)cell
            forRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)wcrGrouping_scheduleRefreshForTrigger:(id)trigger;
- (void)viewDidAppear:(BOOL)animated;
@end

@interface WCRGroupingSessionListViewController : UIViewController
@property(nonatomic, copy) NSString *groupId;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, copy) NSArray *items;
@end

// Confirmed private accessor used by WCRefine/WeChat cell code.  The runtime
// check below keeps this declaration harmless on builds where it is absent.
@interface UITableViewCell (WCRRenderedCellDataPrivate)
- (id)cellData;
@end

typedef NS_ENUM(NSInteger, WCRRightActionKind) {
    WCRRightActionNone = 0,
    WCRRightActionGroup,
    WCRRightActionKeep,
    WCRRightActionReturn,
    WCRRightActionMute,
    WCRRightActionRemind,
    WCRRightActionPending,
    WCRRightActionUnknown
};

#pragma mark - Helpers

static NSString *WCRClassName(id obj) {
    return obj ? NSStringFromClass([obj class]) : @"<nil>";
}

// WCRefine's own runtime hook code reads `m_cellData` from the rendered
// NewMainFrameCell.  Reading that confirmed object ivar is more exact than
// projecting the current indexPath back through a snapshot that may be in the
// middle of a reorder.
static id WCRObjectIvarNamed(id object, const char *ivarName) {
    if (!object || !ivarName || ivarName[0] == '\0') return nil;

    Class cls = [object class];
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, ivarName);
        if (ivar) {
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') {
                return object_getIvar(object, ivar);
            }
            return nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static id WCRRenderedCellData(UITableViewCell *cell) {
    if (!cell) return nil;

    // Prefer the real accessor when this build exposes it.  WCRefine's own
    // group-detail code calls `cellData` on NewMainFrameCell.
    if ([cell respondsToSelector:@selector(cellData)]) {
        id accessorValue = [cell cellData];
        if (accessorValue) return accessorValue;
    }

    // Fall back to the confirmed backing ivar used by the runtime hook.
    id cellData = WCRObjectIvarNamed(cell, "m_cellData");
    if (!cellData) {
        cellData = WCRObjectIvarNamed(cell, "_m_cellData");
    }
    return cellData;
}

static BOOL WCRIsMainFrameTable(UITableView *tableView) {
    if (!tableView) return NO;

    Class cls = NSClassFromString(@"MainFrameTableView");
    if (cls && [tableView isKindOfClass:cls]) {
        return YES;
    }

    return [WCRClassName(tableView) isEqualToString:@"MainFrameTableView"];
}

static BOOL WCRIsMainFrameCell(UITableViewCell *cell) {
    if (!cell) return NO;

    Class cls = NSClassFromString(@"NewMainFrameCell");
    if (cls && [cell isKindOfClass:cls]) {
        return YES;
    }

    return [WCRClassName(cell) isEqualToString:@"NewMainFrameCell"];
}

static UITableView *WCRTableForCell(UITableViewCell *cell) {
    UIView *v = cell;
    while (v) {
        if ([v isKindOfClass:[UITableView class]]) {
            return (UITableView *)v;
        }
        v = v.superview;
    }
    return nil;
}


static UIViewController *WCRViewControllerForView(UIView *view) {
    UIResponder *responder = view;

    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }

    return nil;
}

static BOOL WCRIsGroupingSessionListController(id controller) {
    if (!controller) return NO;

    Class cls = NSClassFromString(@"WCRGroupingSessionListViewController");
    if (cls && [controller isKindOfClass:cls]) {
        return YES;
    }

    return [WCRClassName(controller)
        isEqualToString:@"WCRGroupingSessionListViewController"];
}

static NSMapTable *gWCRGroupingTableOwners;

static void WCRRememberGroupingTable(UITableView *table, id controller) {
    if (!table || !WCRIsGroupingSessionListController(controller)) return;
    @synchronized([NSMapTable class]) {
        if (!gWCRGroupingTableOwners) {
            gWCRGroupingTableOwners = [NSMapTable weakToWeakObjectsMapTable];
        }
        [gWCRGroupingTableOwners setObject:controller forKey:table];
    }
}

static id WCRRememberedGroupingController(UITableView *table) {
    if (!table) return nil;
    @synchronized([NSMapTable class]) {
        id controller = [gWCRGroupingTableOwners objectForKey:table];
        return WCRIsGroupingSessionListController(controller) ? controller : nil;
    }
}

static BOOL WCRIsActiveFrontHomeTable(UITableView *tableView) {
    if (!WCRIsMainFrameTable(tableView)) return NO;

    UIViewController *owner = WCRViewControllerForView(tableView);

    // WCRefine group-detail pages (custom friend groups, custom chat-room
    // groups, and "其它"/other source lists) use their own
    // WCRGroupingSessionListViewController and their own swipe/layout state.
    // Never attach ActiveFront's independent pan there.
    if (WCRIsGroupingSessionListController(owner) ||
        WCRIsGroupingSessionListController(tableView.delegate)) {
        return NO;
    }

    Class homeClass = NSClassFromString(@"NewMainFrameViewController");

    if (homeClass && owner && [owner isKindOfClass:homeClass]) {
        return YES;
    }

    if (homeClass &&
        tableView.delegate &&
        [tableView.delegate isKindOfClass:homeClass]) {
        return YES;
    }

    // Conservative fallback: ActiveFront should not claim an unknown
    // MainFrameTableView. This prevents WCRefine's internal lists from being
    // modified if their implementation changes.
    return NO;
}

static WCRGroupingSessionListViewController *WCRGroupControllerForTable(UITableView *table) {
    if (!table) return nil;
    WCRGroupingSessionListViewController *remembered =
        WCRRememberedGroupingController(table);
    if (remembered) return remembered;

    id owner = WCRViewControllerForView(table);
    if (!WCRIsGroupingSessionListController(owner)) owner = table.delegate;
    if (!WCRIsGroupingSessionListController(owner)) return nil;
    @try {
        UITableView *declaredTable = [owner tableView];
        if (declaredTable == table) return owner;
        // iPad split-view layouts may expose a proxy or nested table while
        // retaining the same grouping controller. Accept only its descendants.
        UIView *ownerView = [owner view];
        return ownerView && [table isDescendantOfView:ownerView] ? owner : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static BOOL WCRIsSupportedSwipeTable(UITableView *table) {
    return WCRIsActiveFrontHomeTable(table) || WCRGroupControllerForTable(table) != nil;
}

static BOOL WCRIsSupportedSwipeCell(UITableViewCell *cell) {
    if (!cell) return NO;
    if (WCRIsMainFrameCell(cell)) return YES;
    // iPad grouping rows can use a different cell subclass. Their table is
    // still accepted only when it belongs to the verified grouping controller.
    return WCRGroupControllerForTable(WCRTableForCell(cell)) != nil;
}

static CGFloat WCRActionExtent(UITableViewCell *cell) {
    return kWCRActionWidth * (WCRGroupControllerForTable(WCRTableForCell(cell)) ? 1 : 2);
}

// Call only signatures checked against the currently loaded native classes.
static id WCRObjectResult(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))[receiver methodForSelector:selector])(receiver, selector);
}

static id WCRNativeContactManager(void) {
    Class serviceCenterClass = NSClassFromString(@"MMServiceCenter");
    Class contactManagerClass = NSClassFromString(@"CContactMgr");
    id serviceCenter = WCRObjectResult(serviceCenterClass, @"defaultCenter");
    SEL getService = NSSelectorFromString(@"getService:");
    NSMethodSignature *signature = [serviceCenter methodSignatureForSelector:getService];
    if (!contactManagerClass || signature.numberOfArguments != 3 ||
        signature.methodReturnType[0] != '@' ||
        [signature getArgumentTypeAtIndex:2][0] != '#') return nil;
    return ((id (*)(id, SEL, Class))[serviceCenter methodForSelector:getService])
        (serviceCenter, getService, contactManagerClass);
}

static id WCRContactForUsername(NSString *username) {
    @try {
        if (![username isKindOfClass:NSString.class] || username.length == 0) return nil;
        Class helper = NSClassFromString(@"WCRefineChatRoomMuteHelper");
        SEL lookup = NSSelectorFromString(@"wcr_contactForName:");
        NSMethodSignature *sig = [helper methodSignatureForSelector:lookup];
        if (sig.numberOfArguments == 3 && sig.methodReturnType[0] == '@' &&
            [sig getArgumentTypeAtIndex:2][0] == '@') {
            id contact = ((id (*)(id, SEL, id))[helper methodForSelector:lookup])
                (helper, lookup, username);
            if (contact) return contact;
        }

        // The host profile-card path obtains CContactMgr from MMServiceCenter
        // directly. Use that same verified service path when WCRefine's helper
        // lookup is unavailable (notably on grouped iPad rows).
        id manager = WCRNativeContactManager();
        SEL getContact = NSSelectorFromString(@"getContactByName:");
        NSMethodSignature *contactSignature = [manager methodSignatureForSelector:getContact];
        if (contactSignature.numberOfArguments != 3 || contactSignature.methodReturnType[0] != '@' ||
            [contactSignature getArgumentTypeAtIndex:2][0] != '@') return nil;
        return ((id (*)(id, SEL, id))[manager methodForSelector:getContact])
            (manager, getContact, username);
    } @catch (__unused NSException *exception) { return nil; }
}

static id WCRContactManager(void) {
    @try {
        Class helper = NSClassFromString(@"WCRefineChatRoomMuteHelper");
        id manager = WCRObjectResult(helper, @"wcr_contactMgr");
        if (manager) return manager;
        return WCRNativeContactManager();
    } @catch (__unused NSException *exception) { return nil; }
}

static NSInteger WCRContactMuted(NSString *username) {
    NSInteger open = WCRAFReadNativeNotifyOpen(WCRContactForUsername(username));
    return open < 0 ? -1 : (open == 0 ? 1 : 0);
}

static NSMutableDictionary<NSString *, NSDictionary *> *gWCRReminderChanges;

static void WCRRememberReminder(NSString *username, BOOL muted, WCRAFAccountContext *context) {
    @synchronized (WCRAFStore()) {
        if (![WCRAFStore() isCurrentContext:context]) return;
        if (!gWCRReminderChanges) gWCRReminderChanges = [NSMutableDictionary dictionary];
        if (gWCRReminderChanges.count >= 128) [gWCRReminderChanges removeAllObjects];
        gWCRReminderChanges[username] = @{@"context": context, @"muted": @(muted)};
    }
}

static WCRAFNotifyCoordinator *WCRReminderCoordinator(void) {
    static WCRAFNotifyCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        coordinator = [[WCRAFNotifyCoordinator alloc]
            initWithValidator:^BOOL(WCRAFAccountContext *context) {
                return [NSThread isMainThread] &&
                    UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                    [WCRAFStore() isCurrentContext:context];
            } clock:^NSTimeInterval {
                return NSProcessInfo.processInfo.systemUptime;
            } scheduler:^(void (^confirm)(void)) {
                // One confirmation for a pending operation; never a recurring timer.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), confirm);
            }];
    });
    return coordinator;
}

// Defer until after native row rendering; coalesce each username per queue turn.
static void WCRQueueReminderObservation(NSString *username, WCRAFAccountContext *context) {
    if (![NSThread isMainThread] || ![username isKindOfClass:NSString.class] ||
        username.length == 0 || !context ||
        [WCRReminderCoordinator() pendingNotifyForUsername:username context:context] < 0) return;
    static NSMutableDictionary<NSString *, WCRAFAccountContext *> *queued;
    static BOOL scheduled;
    if (!queued) queued = [NSMutableDictionary dictionary];
    if (queued.count >= 128 && !queued[username]) return;
    queued[username] = context;
    if (scheduled) return;
    scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary<NSString *, WCRAFAccountContext *> *batch = [queued copy];
        [queued removeAllObjects];
        scheduled = NO;
        for (NSString *name in batch) {
            [WCRReminderCoordinator() observeUsername:name context:batch[name]];
        }
    });
}

static void WCRSetNativeMuted(NSString *username, BOOL muted, WCRAFAccountContext *context,
                              void (^completion)(BOOL, NSString *)) {
    if (username.length == 0 || ![WCRAFStore() isCurrentContext:context]) return;
    __block NSString *writeFailure = @"当前微信版本的提醒接口不可用（N04）";
    __block id contact = nil;
    __block BOOL contactResolved = NO;
    id (^resolvedContact)(void) = ^id{
        if (!contactResolved) {
            contact = WCRContactForUsername(username);
            contactResolved = YES;
        }
        return contact;
    };
    [WCRReminderCoordinator() changeUsername:username context:context notify:!muted
        read:^NSInteger {
            return WCRAFReadNativeNotifyOpen(resolvedContact());
        } write:^WCRAFNativeNotifyResult {
            @try {
                id manager = WCRContactManager();
                if (!manager) {
                    writeFailure = @"微信联系人管理器不可用（N03-M）";
                    return WCRAFNativeNotifyUnavailable;
                }
                id targetContact = resolvedContact();
                if (!targetContact) {
                    writeFailure = @"未能找到该微信联系人（N03-C）";
                    return WCRAFNativeNotifyUnavailable;
                }
                return WCRAFInvokeNativeNotify(manager, targetContact, !muted);
            } @catch (__unused NSException *exception) { return WCRAFNativeNotifyUnavailable; }
        } pending:^{} completion:^(WCRAFNotifyOutcome outcome) {
            if (outcome == WCRAFNotifyConfirmed) {
                WCRRememberReminder(username, muted, context);
                completion(YES, nil);
                return;
            }
            if (outcome == WCRAFNotifyUnconfirmed) {
                WCRReminderPendingNotice();
                completion(NO, nil);
                return;
            }
            NSString *failure = writeFailure;
            switch (outcome) {
                case WCRAFNotifyReadUnavailable:
                    failure = @"未能读取微信消息提醒状态（N02）"; break;
                case WCRAFNotifyRejected:
                    failure = @"微信接口返回失败，尚未确认提醒状态变化（N05）"; break;
                case WCRAFNotifyBusy:
                    failure = @"待确认操作较多，请稍后重试（N07）"; break;
                default: break;
            }
            completion(NO, failure);
        }];
}

static void WCRReminderFailure(NSString *reason) {
    NSString *message = [NSString stringWithFormat:@"%@\n请在微信聊天设置中确认消息免打扰状态。",
        reason ?: @"未能确认设置结果"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未能修改消息提醒"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = WCRTopVC();
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void WCRReminderPendingNotice(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提醒状态待确认"
        message:@"暂未确认微信中的开关状态，请在聊天设置中核实后重试。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [WCRTopVC() presentViewController:alert animated:YES completion:nil];
}

static UIViewController *WCRTopVC(void) {
    UIWindow *window = nil;

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha <= 0.01) continue;
        if (w.windowLevel != UIWindowLevelNormal) continue;

        if (w.isKeyWindow) {
            window = w;
            break;
        }
        if (!window) window = w;
    }

    UIViewController *vc = window.rootViewController;
    if (!vc) return nil;

    BOOL moved = YES;
    while (moved) {
        moved = NO;

        if (vc.presentedViewController &&
            ![vc.presentedViewController isKindOfClass:[UIAlertController class]] &&
            !vc.presentedViewController.isBeingDismissed) {
            vc = vc.presentedViewController;
            moved = YES;
            continue;
        }

        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *next =
                [(UINavigationController *)vc visibleViewController];
            if (next && next != vc) {
                vc = next;
                moved = YES;
                continue;
            }
        }

        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *next =
                [(UITabBarController *)vc selectedViewController];
            if (next && next != vc) {
                vc = next;
                moved = YES;
                continue;
            }
        }
    }

    return vc;
}

static void WCRCollectTableViews(UIView *view, NSMutableArray *tables) {
    if (!view || view.hidden || view.alpha <= 0.01) return;

    if ([view isKindOfClass:[UITableView class]] && view.window) {
        [tables addObject:view];
    }

    for (UIView *sub in view.subviews) {
        WCRCollectTableViews(sub, tables);
    }
}

static UITableView *WCRMainTable(void) {
    NSMutableArray *tables = [NSMutableArray array];

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha <= 0.01) continue;
        WCRCollectTableViews(w, tables);
    }

    for (UITableView *tableView in tables) {
        if (WCRIsActiveFrontHomeTable(tableView)) {
            return tableView;
        }
    }

    return nil;
}

static BOOL WCRBool(id obj, const void *key) {
    NSNumber *n = objc_getAssociatedObject(obj, key);
    return n.boolValue;
}

static CGFloat WCRFloat(id obj, const void *key) {
    NSNumber *n = objc_getAssociatedObject(obj, key);
    return n ? (CGFloat)n.doubleValue : 0.0;
}

static void WCRSetBool(id obj, const void *key, BOOL value) {
    objc_setAssociatedObject(obj,
                             key,
                             @(value),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WCRSetFloat(id obj, const void *key, CGFloat value) {
    objc_setAssociatedObject(obj,
                             key,
                             @(value),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WCRSetContentOffset(UITableViewCell *cell, CGFloat x) {
    if (!cell) return;

    UIView *foreground = objc_getAssociatedObject(cell, kWCRSwipeForegroundKey);
    if (!foreground) return;
    CGRect frame = cell.bounds;
    frame.origin.x += x;
    foreground.frame = frame;
    WCRSetFloat(cell, kWCRSwipeOffsetKey, x);
}

static void WCRRestoreSwipeVisual(UITableViewCell *cell) {
    UIView *foreground = objc_getAssociatedObject(cell, kWCRSwipeForegroundKey);
    [foreground.layer removeAllAnimations];
    [foreground removeFromSuperview];
    NSArray *savedViews = objc_getAssociatedObject(cell, kWCRSwipeHiddenViewsKey);
    for (NSDictionary *saved in savedViews) {
        UIView *view = saved[@"view"];
        if (view.superview == cell) view.alpha = [saved[@"alpha"] doubleValue];
    }
    objc_setAssociatedObject(cell, kWCRSwipeForegroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRSwipeHiddenViewsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCRSetFloat(cell, kWCRSwipeOffsetKey, 0);
    [gWCRSwipeCells removeObject:cell];
}

static UIColor *WCRSwipeBackground(UITableViewCell *cell) {
    for (id color in @[cell.backgroundView.backgroundColor ?: [NSNull null],
                       cell.contentView.backgroundColor ?: [NSNull null],
                       cell.backgroundColor ?: [NSNull null],
                       WCRTableForCell(cell).backgroundColor ?: [NSNull null]]) {
        if ([color isKindOfClass:[UIColor class]] &&
            CGColorGetAlpha([[color resolvedColorWithTraitCollection:cell.traitCollection] CGColor]) > 0.99) {
            return color;
        }
    }
    return [UIColor secondarySystemGroupedBackgroundColor];
}

static BOOL WCRBeginSwipeVisual(UITableViewCell *cell) {
    UIView *foreground = objc_getAssociatedObject(cell, kWCRSwipeForegroundKey);
    if (foreground) {
        CALayer *presentation = foreground.layer.presentationLayer;
        CGFloat offset = presentation ? CGRectGetMinX(presentation.frame) - CGRectGetMinX(cell.bounds) :
            WCRFloat(cell, kWCRSwipeOffsetKey);
        [foreground.layer removeAllAnimations];
        WCRSetContentOffset(cell, offset);
        return YES;
    }
    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    actionView.hidden = YES;
    // Capture the cell, including avatars rendered outside contentView.
    foreground = [cell snapshotViewAfterScreenUpdates:NO];
    if (!foreground) return NO;
    foreground.frame = cell.bounds;
    foreground.userInteractionEnabled = NO;
    NSMutableArray *savedViews = [NSMutableArray array];
    for (UIView *view in cell.subviews) {
        if (view == actionView) continue;
        [savedViews addObject:@{@"view": view, @"alpha": @(view.alpha)}];
        view.alpha = 0;
    }
    objc_setAssociatedObject(cell, kWCRSwipeHiddenViewsKey, savedViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRSwipeForegroundKey, foreground, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gWCRSwipeCells) gWCRSwipeCells = [NSHashTable weakObjectsHashTable];
    [gWCRSwipeCells addObject:cell];
    WCRSetFloat(cell, kWCRSwipeOffsetKey, 0);
    [cell addSubview:foreground];
    return YES;
}

static void WCRLayoutAction(UITableViewCell *cell) {
    if (!cell) return;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button = objc_getAssociatedObject(cell, kWCRButtonKey);

    CGFloat h = CGRectGetHeight(cell.bounds);
    if (h <= 1.0) {
        h = CGRectGetHeight(cell.contentView.bounds);
    }

    CGFloat offset = MAX(0, WCRFloat(cell, kWCRSwipeOffsetKey));
    // The action can occupy only the revealed gap, never the avatar's area.
    actionView.frame = CGRectMake(CGRectGetMinX(cell.bounds), CGRectGetMinY(cell.bounds), offset, h);
    button.frame = CGRectMake(0, 0, kWCRActionWidth, h);
    UIButton *mute = objc_getAssociatedObject(cell, kWCRMuteButtonKey);
    mute.frame = CGRectMake(kWCRActionWidth, 0, kWCRActionWidth, h);
}

static void WCRCloseCell(UITableViewCell *cell, BOOL animated) {
    if (!cell) return;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button = objc_getAssociatedObject(cell, kWCRButtonKey);

    WCRSetBool(cell, kWCROpenKey, NO);
    WCRSetBool(cell, kWCRTrackingKey, NO);
    WCRSetFloat(cell, kWCRStartOffsetKey, 0.0);
    objc_setAssociatedObject(cell, kWCRSwipeIntentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRSwipeRenderedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *foreground = objc_getAssociatedObject(cell, kWCRSwipeForegroundKey);

    // Hide the action immediately instead of waiting for the spring
    // completion. The old completion could be interrupted by a new gesture /
    // table refresh, leaving stale “保持/回组/分组” text visible.
    actionView.hidden = YES;
    [button setTitle:@"" forState:UIControlStateNormal];

    void (^changes)(void) = ^{
        WCRSetContentOffset(cell, 0.0);
    };

    void (^finish)(BOOL) = ^(BOOL finished) {
        (void)finished;

        if (finished && objc_getAssociatedObject(cell, kWCRSwipeForegroundKey) == foreground &&
            !WCRBool(cell, kWCROpenKey) &&
            !WCRBool(cell, kWCRTrackingKey)) {
            WCRRestoreSwipeVisual(cell);
            actionView.hidden = YES;
            [button setTitle:@"" forState:UIControlStateNormal];

            [cell setNeedsLayout];
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0.0
             usingSpringWithDamping:0.92
              initialSpringVelocity:0.0
                            options:(UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:changes
                         completion:finish];
    } else {
        changes();
        finish(YES);
    }
}


static void WCRHardResetCellVisual(UITableViewCell *cell,
                                   BOOL clearBinding) {
    if (!cell) return;

    UIView *actionView =
        objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button =
        objc_getAssociatedObject(cell, kWCRButtonKey);

    [actionView.layer removeAllAnimations];
    WCRRestoreSwipeVisual(cell);

    actionView.hidden = YES;
    [button setTitle:@"" forState:UIControlStateNormal];

    WCRSetBool(cell, kWCROpenKey, NO);
    WCRSetBool(cell, kWCRTrackingKey, NO);
    WCRSetFloat(cell, kWCRStartOffsetKey, 0.0);
    objc_setAssociatedObject(cell, kWCRSwipeIntentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRSwipeRenderedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    actionView.backgroundColor = [UIColor clearColor];

    if (clearBinding) {
        objc_setAssociatedObject(cell,
                                 kWCRBoundUsernameKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [cell setNeedsLayout];
}

static void WCROpenCell(UITableViewCell *cell) {
    if (!cell) return;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    actionView.hidden = NO;

    WCRSetBool(cell, kWCROpenKey, YES);
    WCRSetBool(cell, kWCRTrackingKey, NO);
    WCRSetFloat(cell, kWCRStartOffsetKey, WCRActionExtent(cell));

    [UIView animateWithDuration:0.24
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.0
                        options:(UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        WCRSetContentOffset(cell, WCRActionExtent(cell));
        WCRLayoutAction(cell);
    }
                     completion:nil];
}

static void WCRCloseOtherCells(UITableViewCell *exceptCell) {
    UITableView *tableView = WCRTableForCell(exceptCell);
    if (!WCRIsSupportedSwipeTable(tableView)) return;

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell == exceptCell) continue;
        if (!WCRBool(cell, kWCROpenKey) &&
            !WCRBool(cell, kWCRTrackingKey)) {
            continue;
        }
        WCRCloseCell(cell, YES);
    }
}

static void WCRResetVisibleSwipeVisuals(void) {
    for (UITableViewCell *cell in gWCRSwipeCells.allObjects) {
        WCRHardResetCellVisual(cell, NO);
    }
}


#pragma mark - WCRefine business helpers

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

static WCRAFStateStore *WCRAFStore(void) {
    static WCRAFStateStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[WCRAFStateStore alloc]
            initWithDefaults:[NSUserDefaults standardUserDefaults]
            accountResolver:^NSString *{
                Class helper = NSClassFromString(@"WCRefineHelper");
                SEL selector = @selector(wcr_resolveCurrentUserWxidUncached);
                if (!helper || ![helper respondsToSelector:selector]) return nil;
                // Verified in the supplied 2.1-9. The cached getter can lag an account switch.
                return [helper wcr_resolveCurrentUserWxidUncached];
            }
            clock:^NSTimeInterval{
                return [[NSDate date] timeIntervalSince1970];
            }];
    });
    return store;
}

static BOOL WCRIsHeld(NSString *username) {
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    return context && username.length > 0 && [WCRAFStore() isHeld:username context:context];
}

static BOOL WCRHasAnyHeld(void) {
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    return context && [WCRAFStore() hasAnyHeldForContext:context];
}

// Main-queue-turn cache only. No timer, no cache of an empty/loading snapshot.
static NSSet<NSString *> *gWCRGroupIndexIds;
static NSSet<NSString *> *gWCRGroupIndexMembers;
static WCRAFAccountContext *gWCRGroupIndexContext;
static uint64_t gWCRGroupIndexGeneration;

static void WCRInvalidateGroupIndex(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ WCRInvalidateGroupIndex(); });
        return;
    }
    gWCRGroupIndexGeneration++;
    gWCRGroupIndexIds = nil;
    gWCRGroupIndexMembers = nil;
    gWCRGroupIndexContext = nil;
}

static BOOL WCRBuildGroupIndex(WCRAFAccountContext *context) {
    if (![NSThread isMainThread] || !context) return NO;
    if (gWCRGroupIndexMembers &&
        gWCRGroupIndexContext.epoch == context.epoch &&
        [gWCRGroupIndexContext.account isEqualToString:context.account]) return YES;

    @try {
        id groups = [WCRGroupManager() customGroups];
        if (![groups isKindOfClass:[NSArray class]] || [groups count] == 0) return NO;
        NSMutableSet<NSString *> *ids = [NSMutableSet set];
        NSMutableSet<NSString *> *members = [NSMutableSet set];
        for (id group in groups) {
            if (![group respondsToSelector:@selector(groupId)] ||
                ![group respondsToSelector:@selector(members)]) return NO;
            id groupId = [group groupId];
            if (![groupId isKindOfClass:[NSString class]] || [groupId length] == 0) continue;
            id names = [group members];
            if (![names isKindOfClass:[NSSet class]] &&
                ![names isKindOfClass:[NSArray class]]) return NO;
            [ids addObject:groupId];
            for (id name in names) {
                if (![name isKindOfClass:[NSString class]]) return NO;
                [members addObject:name];
            }
        }
        // Disabled custom groups still count, matching the original predicate.
        if (ids.count == 0 || ![WCRAFStore() isCurrentContext:context]) return NO;
        gWCRGroupIndexIds = [ids copy];
        gWCRGroupIndexMembers = [members copy];
        gWCRGroupIndexContext = context;
        uint64_t generation = ++gWCRGroupIndexGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == gWCRGroupIndexGeneration) WCRInvalidateGroupIndex();
        });
        return YES;
    } @catch (__unused NSException *exception) {
        WCRInvalidateGroupIndex();
        return NO;
    }
}

static NSSet<NSString *> *WCRCustomGroupIdSet(void) {
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (WCRBuildGroupIndex(context)) return gWCRGroupIndexIds;
    WCRefineGroupManager *mgr = WCRGroupManager();
    NSMutableSet<NSString *> *ids = [NSMutableSet set];

    for (WCRefineGroup *group in mgr.customGroups ?: @[]) {
        if (group.groupId.length > 0) {
            [ids addObject:group.groupId];
        }
    }
    return ids;
}

static BOOL WCRIsInCustomGroup(NSString *username) {
    if (username.length == 0) return NO;

    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (WCRBuildGroupIndex(context)) return [gWCRGroupIndexMembers containsObject:username];

    WCRefineGroupManager *mgr = WCRGroupManager();
    if (!mgr) return NO;

    NSArray<NSString *> *memberGroupIds =
        [mgr groupIdsContainingMember:username] ?: @[];

    if (memberGroupIds.count == 0) return NO;

    NSSet<NSString *> *customIds = WCRCustomGroupIdSet();
    for (NSString *groupId in memberGroupIds) {
        if ([customIds containsObject:groupId]) {
            return YES;
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

static void WCRRefreshHome(__unused id host, __unused NSString *reason, WCRAFAccountContext *context) {
    if (![WCRAFStore() isCurrentContext:context]) return;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kWCRHomeGroupsDidChangeNotification
                      object:nil];

    // The host notification already schedules a refresh. Do not request it twice.
}

static void WCRRefreshHomeDeferred(id host, NSString *reason, WCRAFAccountContext *context) {
    __weak id weakHost = host;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCRRefreshHome(weakHost, reason, context);
    });
}

static void WCRRefreshHomeGlobal(__unused NSString *reason, WCRAFAccountContext *context) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (context && ![WCRAFStore() isCurrentContext:context]) return;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kWCRHomeGroupsDidChangeNotification
                          object:nil];
    });
}

#pragma mark - Hold expiry (v1.9.7)

// Hold expiry never uses timers. It is evaluated lazily for Held sessions
// inside WCRefine's own refresh pass.

// Time of the session's latest message (seconds since 1970), 0 if unknown.
static NSTimeInterval WCRSessionLastMessageTime(id session) {
    if (!session) return 0;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    id native = provider ? [provider nativeSessionFromObject:session] : nil;
    if (!native) native = session;

    NSArray<NSString *> *paths =
        @[@"m_uLastTime", @"m_msgWrap.m_uiCreateTime"];

    for (NSString *path in paths) {
        @try {
            id value = [native valueForKeyPath:path];
            if ([value respondsToSelector:@selector(doubleValue)]) {
                double t = [value doubleValue];
                if (t > 1e12) t /= 1000.0; // milliseconds safeguard
                if (isfinite(t) && t > 0) return t;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return 0;
}

static NSInteger WCRSessionUnreadCount(id native) {
    @try {
        // Confirmed KVC key in the supplied WCRefine host. Do not interpret a
        // missing key or an unsupported value as zero/unread cleared.
        id value = [native valueForKey:@"m_uUnReadCount"];
        if (![value isKindOfClass:[NSNumber class]]) return -1;
        double count = [value doubleValue];
        if (!isfinite(count) || count < 0 || floor(count) != count ||
            count >= (double)NSIntegerMax) return -1;
        return [value integerValue];
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

static NSInteger WCRSessionBooleanFlag(id native, NSString *key) {
    @try {
        id value = [native valueForKey:key];
        if (![value isKindOfClass:[NSNumber class]]) return -1;
        double flag = [value doubleValue];
        return flag == 0 ? 0 : (flag == 1 ? 1 : -1);
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

static NSInteger WCREffectiveMuted(id native, NSString *username, WCRAFAccountContext *context) {
    NSInteger flag = WCRSessionBooleanFlag(native, @"m_bShowUnReadAsRedDot");
    @synchronized (WCRAFStore()) {
        NSDictionary *change = username.length > 0 ? gWCRReminderChanges[username] : nil;
        if (!change) return flag;
        if (change[@"context"] != context || ![WCRAFStore() isCurrentContext:context]) {
            [gWCRReminderChanges removeObjectForKey:username];
            return flag;
        }
        NSInteger expected = [change[@"muted"] boolValue] ? 1 : 0;
        if (flag == expected) {
            [gWCRReminderChanges removeObjectForKey:username];
            return flag;
        }
        // A just-modified contact may precede the native session cache.
        // Recheck only this contact until the session catches up, never the list.
        NSInteger actual = WCRContactMuted(username);
        if (actual != expected) [gWCRReminderChanges removeObjectForKey:username];
        return actual < 0 ? flag : actual;
    }
}

static BOOL WCRSessionAllowsAutomaticActivity(id native, NSUInteger scope,
                                              NSString *username, WCRAFAccountContext *context) {
    // These are the supplied host's own unread-policy/folded-session flags.
    // Do not fetch every room's contact or maintain a stale mute cache.
    return WCRAFAllowsAutomaticActivity(scope,
        WCREffectiveMuted(native, username, context),
        WCRSessionBooleanFlag(native, @"m_isFolding"));
}

// Expired = no new message for N days since max(保持 time, last message).
// Called from the predicate; the actual state write + refresh is deferred so
// the predicate itself never mutates state during WCRefine's pass.
static void WCRScheduleHoldExpiry(NSString *username,
                                   WCRAFAccountContext *context,
                                   NSTimeInterval lastMessageTime) {
    WCRAFExpiryCandidate *ticket =
        [WCRAFStore() enqueueExpiry:username context:context lastMessageTime:lastMessageTime];
    if (!ticket) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<WCRAFExpiryCandidate *> *expired = [WCRAFStore() takeBatch:ticket];
        if (expired.count == 0) return;
        WCRInvalidateGroupIndex();
        BOOL changed = NO;
        for (WCRAFExpiryCandidate *candidate in expired) {
            if (![WCRAFStore() isCurrentContext:candidate.context]) break;
            @try {
                WCRefineGroupDataProvider *provider = WCRDataProvider();
                if (![provider respondsToSelector:@selector(fulfilledSessionForUsername:fallback:)]) continue;
                // nil fallback is deliberate: never substitute the stale queued object.
                id latest = [provider fulfilledSessionForUsername:candidate.username fallback:nil];
                NSString *resolved = [provider usernameForNativeObject:latest];
                if (!latest || ![resolved isEqualToString:candidate.username] ||
                    !WCRIsInCustomGroup(candidate.username)) continue;
                if ([WCRAFStore() commitExpiry:candidate
                            lastMessageTime:WCRSessionLastMessageTime(latest)]) changed = YES;
            } @catch (__unused NSException *exception) {
                // Missing or changed private APIs must preserve Held state.
            }
        }
        if (changed) {
            WCRRefreshHomeGlobal(@"active_front_hold_expired", ticket.context);
        }
    });
}

static void WCRSetHeld(NSString *username, BOOL held, id host,
                        WCRAFAccountContext *context) {
    if (username.length == 0) return;
    WCRInvalidateOutgoing(username, context);
    if (![WCRAFStore() setHeld:held username:username context:context]) return;

    WCRAF_LOG(@"%@ %@",
              held ? @"keep" : @"return-to-group",
              username);

    NSString *reason = held ? @"active_front_keep" : @"active_front_return";
    WCRRefreshHomeDeferred(host, reason, context);
}

static BOOL WCRPruneStaleActiveFrontState(void) {
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (context) [WCRAFStore() reconcileTimestampsForContext:context];
    // An empty/loading grouping snapshot never deletes persisted Held state.
    return NO;
}

static NewMainFrameViewController *WCRHomeControllerForTable(
    UITableView *tableView) {

    if (!tableView) return nil;

    Class homeClass = NSClassFromString(@"NewMainFrameViewController");

    UIViewController *owner = WCRViewControllerForView(tableView);
    if (homeClass && owner && [owner isKindOfClass:homeClass]) {
        return (NewMainFrameViewController *)owner;
    }

    id delegate = tableView.delegate;
    if (homeClass && delegate && [delegate isKindOfClass:homeClass]) {
        return (NewMainFrameViewController *)delegate;
    }

    return nil;
}

static void WCRClearCanonicalRowBinding(UITableViewCell *cell) {
    if (!cell) return;

    objc_setAssociatedObject(cell, kWCRCanonicalKnownKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalSessionKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalUsernameKey, nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalScopeKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalAccountKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL WCRIsSyntheticGroupEntryUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]] || username.length == 0) {
        return NO;
    }

    // Confirmed in WCRefine.dylib: virtual home entries are emitted as either
    // WCRefine_groupEntry or WCRefine_groupEntry_<groupId>.  Scope-2 entries
    // may additionally end in @chatroom, so scope alone cannot identify them.
    return [username isEqualToString:@"WCRefine_groupEntry"] ||
           [username hasPrefix:@"WCRefine_groupEntry_"];
}

static NewMainFrameViewController *WCRActivityHomeController(void) {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return nil;
    UIViewController *top = WCRTopVC();
    Class homeClass = NSClassFromString(@"NewMainFrameViewController");
    if (homeClass && [top isKindOfClass:homeClass]) return (id)top;

    // iPad split-view containers can keep the visible home controller below
    // WCRTopVC(), so also consult the controller observed in viewDidAppear.
    id appeared = gWCRAppearedHomeController;
    if (homeClass && [appeared isKindOfClass:homeClass] &&
        [(UIViewController *)appeared isViewLoaded] &&
        [(UIViewController *)appeared view].window) return appeared;
    return nil;
}

// Coalesce a complete grouping pass, then resolve the latest session again.
// The predicate must not persist state or recurse into a home refresh.
static NSMutableDictionary<NSString *, NSDictionary *> *gWCRActivityObservations;
static BOOL gWCRActivityObservationScheduled;

static void WCRScheduleActivityObservation(NSString *username, WCRAFAccountContext *context,
                                           BOOL projectedActive) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRScheduleActivityObservation(username, context, projectedActive);
        });
        return;
    }
    if (username.length == 0 || ![WCRAFStore() isCurrentContext:context]) return;
    if (!gWCRActivityObservations) gWCRActivityObservations = [NSMutableDictionary dictionary];
    gWCRActivityObservations[username] = @{@"context": context, @"active": @(projectedActive)};
    if (gWCRActivityObservationScheduled) return;
    gWCRActivityObservationScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *observations = [gWCRActivityObservations copy];
        [gWCRActivityObservations removeAllObjects];
        gWCRActivityObservationScheduled = NO;
        BOOL projectionChanged = NO;
        WCRAFAccountContext *current = [WCRAFStore() currentContext];
        for (NSString *name in observations) {
            NSDictionary *observation = observations[name];
            WCRAFAccountContext *captured = observation[@"context"];
            if (![WCRAFStore() isCurrentContext:captured]) continue;
            @try {
                WCRefineGroupDataProvider *provider = WCRDataProvider();
                if (![provider respondsToSelector:@selector(fulfilledSessionForUsername:fallback:)]) continue;
                id latest = [provider fulfilledSessionForUsername:name fallback:nil];
                id native = [provider nativeSessionFromObject:latest] ?: latest;
                if (!native || ![[provider usernameForNativeObject:native] isEqualToString:name]) continue;
                NSUInteger scope = [provider groupScopeForNativeSession:native];
                BOOL grouped = WCRIsInCustomGroup(name);
                BOOL held = [WCRAFStore() isHeld:name context:captured];
                BOOL allowed = WCRSessionAllowsAutomaticActivity(native, scope, name, captured);
                NSTimeInterval message = WCRSessionLastMessageTime(native);
                NSInteger unread = WCRSessionUnreadCount(native);
                if (!allowed || !grouped || held) {
                    [WCRAFStore() discardMessageActivity:name context:captured];
                } else {
                    [WCRAFStore() observeMessageActivity:name context:captured
                        lastMessageTime:message unreadCount:unread grouped:grouped
                        homeVisible:WCRActivityHomeController() != nil];
                }
                BOOL active = allowed && grouped &&
                    [WCRAFStore() isMessageActive:name context:captured
                        lastMessageTime:message unreadCount:unread grouped:grouped];
                if (!held && grouped && active != [observation[@"active"] boolValue]) {
                    projectionChanged = YES;
                }
            } @catch (__unused NSException *exception) {
                // Unknown session/read state never initiates a return.
            }
        }
        // Persisting new-message state alone does not change the projection.
        // Only a visibility transition requests the host's structural refresh.
        NewMainFrameViewController *home = WCRActivityHomeController();
        if (projectionChanged && home && [WCRAFStore() isCurrentContext:current] &&
            [home respondsToSelector:@selector(wcrGrouping_scheduleRefreshForTrigger:)]) {
            [home wcrGrouping_scheduleRefreshForTrigger:@"groupsChanged"];
        }
    });
}

static void WCRReconcileTrackedActivity(WCRAFAccountContext *context) {
    // Home return/foreground events inspect only tracked conversations, not history.
    for (NSString *name in [WCRAFStore() trackedMessageActivityUsernamesForContext:context]) {
        WCRScheduleActivityObservation(name, context, YES);
    }
}

static BOOL WCRIsMessageActiveSession(id session, NSString *username,
                                      WCRAFAccountContext *context) {
    if (!session || !context || username.length == 0 ||
        WCRIsSyntheticGroupEntryUsername(username)) return NO;
    @try {
        WCRefineGroupDataProvider *provider = WCRDataProvider();
        id native = [provider nativeSessionFromObject:session] ?: session;
        if (!provider) return NO;
        NSUInteger scope = [provider groupScopeForNativeSession:native];
        if (scope != 1 && scope != 2) return NO;
        BOOL grouped = WCRIsInCustomGroup(username);
        BOOL tracked = [WCRAFStore() hasTrackedMessageActivity:username context:context];
        if (!WCRSessionAllowsAutomaticActivity(native, scope, username, context) || !grouped ||
            [WCRAFStore() isHeld:username context:context]) {
            if (tracked) WCRScheduleActivityObservation(username, context, NO);
            return NO;
        }
        NSTimeInterval message = WCRSessionLastMessageTime(native);
        NSInteger unread = WCRSessionUnreadCount(native);
        BOOL active = [WCRAFStore() isMessageActive:username context:context
                            lastMessageTime:message unreadCount:unread grouped:grouped];
        if ([WCRAFStore() needsMessageActivityObservation:username context:context
                lastMessageTime:message unreadCount:unread grouped:grouped
                homeVisible:WCRActivityHomeController() != nil]) {
            WCRScheduleActivityObservation(username, context, active);
        }
        return active;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL WCRIdentityFromCandidate(id candidate,
                                     id *sessionOut,
                                     NSString **usernameOut,
                                     NSUInteger *scopeOut) {
    if (!candidate) return NO;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider) return NO;

    id canonical = [provider nativeSessionFromObject:candidate];
    if (!canonical) canonical = candidate;

    NSString *username = [provider usernameForNativeObject:canonical];
    if ([username isKindOfClass:[NSString class]] && username.length > 0) {
        if (sessionOut) *sessionOut = canonical;
        if (usernameOut) *usernameOut = username;
        if (scopeOut) *scopeOut = [provider groupScopeForNativeSession:canonical];
        return YES;
    }

    if (canonical != candidate) {
        username = [provider usernameForNativeObject:candidate];
        if ([username isKindOfClass:[NSString class]] && username.length > 0) {
            if (sessionOut) *sessionOut = candidate;
            if (usernameOut) *usernameOut = username;
            if (scopeOut) *scopeOut = [provider groupScopeForNativeSession:candidate];
            return YES;
        }
    }

    return NO;
}

static BOOL WCRConversationFromCandidate(id candidate,
                                         id *sessionOut,
                                         NSString **usernameOut,
                                         NSUInteger *scopeOut) {
    id session = nil;
    NSString *username = nil;
    NSUInteger scope = 0;

    if (!WCRIdentityFromCandidate(candidate, &session, &username, &scope)) {
        return NO;
    }

    if (WCRIsSyntheticGroupEntryUsername(username)) {
        return NO;
    }

    if (scope != 1 && scope != 2) {
        return NO;
    }

    if (sessionOut) *sessionOut = session;
    if (usernameOut) *usernameOut = username;
    if (scopeOut) *scopeOut = scope;
    return YES;
}

static id WCRResolveRenderedConversationForCell(
    UITableViewCell *cell,
    id host,
    NSIndexPath *indexPath,
    NSString **usernameOut,
    NSUInteger *scopeOut,
    NSString **sourceOut) {

    // PRIMARY: visible m_cellData is authoritative.  If it exposes a concrete
    // identity that is not an eligible real friend/chatroom, fail closed here.
    // Do NOT fall through to the same indexPath: WCRefine's projected backing
    // row can be a different real conversation underneath a virtual group row.
    id renderedCellData = WCRRenderedCellData(cell);
    id renderedSession = nil;
    NSString *renderedUsername = nil;
    NSUInteger renderedScope = 0;

    BOOL renderedHasIdentity =
        WCRIdentityFromCandidate(renderedCellData,
                                 &renderedSession,
                                 &renderedUsername,
                                 &renderedScope);

    if (renderedHasIdentity) {
        if (!WCRIsSyntheticGroupEntryUsername(renderedUsername) &&
            (renderedScope == 1 || renderedScope == 2)) {
            if (usernameOut) *usernameOut = renderedUsername;
            if (scopeOut) *scopeOut = renderedScope;
            if (sourceOut) *sourceOut = @"m_cellData";
            return renderedSession;
        }

        if (sourceOut) {
            *sourceOut = WCRIsSyntheticGroupEntryUsername(renderedUsername) ?
                @"m_cellData-groupEntry" : @"m_cellData-nonConversation";
        }
        return nil;
    }

    // FALLBACK is allowed only when the rendered cellData genuinely has no
    // usable identity.  This preserves v1.9.4's fix for late/reused real rows.
    if (WCRIsGroupingSessionListController(host)) {
        @try {
            NSArray *items = [(WCRGroupingSessionListViewController *)host items];
            if (indexPath.section != 0 || indexPath.row < 0 ||
                (NSUInteger)indexPath.row >= items.count) return nil;
            id item = items[indexPath.row];
            id session = WCRObjectResult(item, @"session");
            if (!WCRConversationFromCandidate(session, &renderedSession,
                    &renderedUsername, &renderedScope)) return nil;
            if (usernameOut) *usernameOut = renderedUsername;
            if (scopeOut) *scopeOut = renderedScope;
            if (sourceOut) *sourceOut = @"group-item";
            return renderedSession;
        } @catch (__unused NSException *exception) { return nil; }
    }
    id liveSession = nil;
    if (host && indexPath &&
        [host respondsToSelector:
            @selector(wcrGrouping_logicGetSessionAtIndexPath:)]) {
        liveSession =
            [host wcrGrouping_logicGetSessionAtIndexPath:indexPath];
    }

    id canonicalLiveSession = nil;
    NSString *liveUsername = nil;
    NSUInteger liveScope = 0;
    if (WCRConversationFromCandidate(liveSession,
                                     &canonicalLiveSession,
                                     &liveUsername,
                                     &liveScope)) {
        if (usernameOut) *usernameOut = liveUsername;
        if (scopeOut) *scopeOut = liveScope;
        if (sourceOut) *sourceOut = @"indexPath-session";
        return canonicalLiveSession;
    }

    id projectedCellData = nil;
    if (host && indexPath &&
        [host respondsToSelector:
            @selector(wcrGrouping_logicGetCellDataAtIndexPath:)]) {
        projectedCellData =
            [host wcrGrouping_logicGetCellDataAtIndexPath:indexPath];
    }

    id projectedSession = nil;
    NSString *projectedUsername = nil;
    NSUInteger projectedScope = 0;
    if (WCRConversationFromCandidate(projectedCellData,
                                     &projectedSession,
                                     &projectedUsername,
                                     &projectedScope)) {
        if (usernameOut) *usernameOut = projectedUsername;
        if (scopeOut) *scopeOut = projectedScope;
        if (sourceOut) *sourceOut = @"indexPath-cellData";
        return projectedSession;
    }

    if (sourceOut) *sourceOut = @"none";
    return nil;
}

static void WCRBindCanonicalHomeRow(UITableViewCell *cell,
                                    id host,
                                    UITableView *tableView,
                                    NSIndexPath *indexPath) {
    if (!cell || !host || !tableView || !indexPath) return;

    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (!context) {
        WCRHardResetCellVisual(cell, YES);
        WCRClearCanonicalRowBinding(cell);
        return;
    }

    NSString *username = nil;
    NSUInteger scope = 0;
    NSString *source = nil;
    id resolvedSession =
        WCRResolveRenderedConversationForCell(cell,
                                              host,
                                              indexPath,
                                              &username,
                                              &scope,
                                              &source);
    if (![WCRAFStore() isCurrentContext:context]) {
        WCRHardResetCellVisual(cell, YES);
        WCRClearCanonicalRowBinding(cell);
        return;
    }
    BOOL eligibleConversation = resolvedSession != nil;

    NSString *oldCanonicalUsername =
        objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey);
    WCRAFAccountContext *oldContext =
        objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);

    BOOL identityChanged =
        (oldContext && (oldContext.epoch != context.epoch ||
                       ![oldContext.account isEqualToString:context.account])) ||
        (oldCanonicalUsername.length > 0 &&
        (!eligibleConversation ||
         ![oldCanonicalUsername isEqualToString:username]));

    if (identityChanged ||
        (!eligibleConversation &&
         (WCRBool(cell, kWCROpenKey) ||
          WCRBool(cell, kWCRTrackingKey)))) {
        WCRHardResetCellVisual(cell, YES);
    }

    objc_setAssociatedObject(cell, kWCRCanonicalKnownKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalSessionKey,
                             eligibleConversation ? resolvedSession : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalUsernameKey,
                             eligibleConversation ? username : nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalScopeKey,
                             @(eligibleConversation ? scope : 0),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalAccountKey, context,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    WCRAF_CELL_LOG(@"canonical row %@ index=%ld/%ld source=%@ session=%@ user=%@ scope=%lu eligible=%d",
                   WCRClassName(cell),
                   (long)indexPath.section,
                   (long)indexPath.row,
                   source ?: @"<none>",
                   WCRClassName(resolvedSession),
                   username ?: @"<nil>",
                   (unsigned long)scope,
                   eligibleConversation);
}

static id WCRSessionForCell(UITableViewCell *cell,
                            id *hostOut,
                            UITableView **tableOut,
                            NSIndexPath **indexPathOut) {
    // Only display/initial-scan paths may bind a row to an account. A gesture
    // must not attach an old cell to a new account after a switch.
    WCRAFAccountContext *context =
        objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
    if (![WCRAFStore() isCurrentContext:context]) {
        WCRHardResetCellVisual(cell, YES);
        WCRClearCanonicalRowBinding(cell);
        return nil;
    }

    UITableView *tableView = WCRTableForCell(cell);
    if (!WCRIsSupportedSwipeTable(tableView)) return nil;

    NSIndexPath *indexPath = [tableView indexPathForCell:cell];
    if (!indexPath) return nil;

    id host = WCRGroupControllerForTable(tableView) ?: (id)WCRHomeControllerForTable(tableView);
    if (!host) return nil;

    NSString *username = nil;
    NSUInteger scope = 0;
    NSString *source = nil;
    id session =
        WCRResolveRenderedConversationForCell(cell,
                                              host,
                                              indexPath,
                                              &username,
                                              &scope,
                                              &source);

    if (![WCRAFStore() isCurrentContext:context]) {
        WCRHardResetCellVisual(cell, YES);
        WCRClearCanonicalRowBinding(cell);
        return nil;
    }

    if (!session) {
        NSString *oldUsername =
            objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey);

        if (oldUsername.length > 0 ||
            WCRBool(cell, kWCROpenKey) ||
            WCRBool(cell, kWCRTrackingKey)) {
            WCRHardResetCellVisual(cell, YES);
        }

        objc_setAssociatedObject(cell, kWCRCanonicalKnownKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, kWCRCanonicalSessionKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, kWCRCanonicalUsernameKey, nil,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cell, kWCRCanonicalScopeKey, @0,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }

    NSString *oldUsername =
        objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey);

    if (oldUsername.length > 0 &&
        ![oldUsername isEqualToString:username]) {
        WCRHardResetCellVisual(cell, YES);
    }

    objc_setAssociatedObject(cell, kWCRCanonicalKnownKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalSessionKey, session,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalUsernameKey, username,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRCanonicalScopeKey, @(scope),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    WCRAF_CELL_LOG(@"action row index=%ld/%ld source=%@ user=%@ scope=%lu",
                   (long)indexPath.section,
                   (long)indexPath.row,
                   source ?: @"<none>",
                   username ?: @"<nil>",
                   (unsigned long)scope);

    if (hostOut) *hostOut = host;
    if (tableOut) *tableOut = tableView;
    if (indexPathOut) *indexPathOut = indexPath;

    return session;
}

static BOOL WCRResolveSessionState(id session,
                                   NSString **usernameOut,
                                   BOOL *groupedOut,
                                   BOOL *heldOut) {
    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider || !session) return NO;

    NSString *username = [provider usernameForNativeObject:session];
    if (![username isKindOfClass:[NSString class]] ||
        username.length == 0) {
        return NO;
    }

    if (WCRIsSyntheticGroupEntryUsername(username)) {
        return NO;
    }

    // Match the original ActiveFront business boundary recovered in Tweak.xm:
    // 1 = friend, 2 = chat room. Official accounts / service accounts /
    // other WCRefine scopes are outside this feature and must never receive
    // our right-swipe recognizer/action.
    NSUInteger scope = [provider groupScopeForNativeSession:session];
    if (scope != 1 && scope != 2) {
        return NO;
    }

    BOOL grouped = WCRIsInCustomGroup(username);
    // Temporary activity must still offer "保持", not pretend it is already Held.
    BOOL held = grouped && WCRIsHeld(username);

    if (usernameOut) *usernameOut = username;
    if (groupedOut) *groupedOut = grouped;
    if (heldOut) *heldOut = held;

    return YES;
}

static WCRRightActionKind WCRActionKindForCell(UITableViewCell *cell,
                                                id *hostOut,
                                                UITableView **tableOut,
                                                NSIndexPath **indexPathOut,
                                                id *sessionOut,
                                                NSString **usernameOut) {
    id host = nil;
    UITableView *tableView = nil;
    NSIndexPath *indexPath = nil;

    id session =
        WCRSessionForCell(cell, &host, &tableView, &indexPath);

    if (!session) return WCRRightActionNone;

    NSString *username = nil;
    BOOL grouped = NO;
    BOOL held = NO;

    if (!WCRResolveSessionState(session,
                                &username,
                                &grouped,
                                &held)) {
        return WCRRightActionNone;
    }

    WCRRightActionKind kind = WCRRightActionNone;
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    NSInteger pending = context ?
        [WCRReminderCoordinator() pendingNotifyForUsername:username context:context] : -1;
    if (pending >= 0) WCRQueueReminderObservation(username, context);

    if (WCRGroupControllerForTable(tableView)) {
        NSInteger muted = pending >= 0 ? -1 : WCRContactMuted(username);
        if (pending < 0 && muted < 0) {
            muted = WCREffectiveMuted(session, username, context);
        }
        kind = pending >= 0 ? WCRRightActionPending :
            (muted == 1 ? WCRRightActionRemind :
            (muted == 0 ? WCRRightActionMute : WCRRightActionUnknown));
    } else if (!grouped) {
        kind = WCRRightActionGroup;
    } else if (held) {
        kind = WCRRightActionReturn;
    } else {
        // If a grouped friend/chatroom is currently a REAL visible row on the
        // home list, the correct action is always "保持".
        //
        // WCRefine's own exclusion (unread switch, @me, pinned exclusions...)
        // is what makes a grouped conversation appear on home; ActiveFront
        // has no active friend message for this row.
        kind = WCRRightActionKeep;
    }

    if (hostOut) *hostOut = host;
    if (tableOut) *tableOut = tableView;
    if (indexPathOut) *indexPathOut = indexPath;
    if (sessionOut) *sessionOut = session;
    if (usernameOut) *usernameOut = username;

    return kind;
}


static NSString *WCRTitleForActionKind(WCRRightActionKind kind) {
    switch (kind) {
        case WCRRightActionGroup:
            return @"分组";
        case WCRRightActionKeep:
            return @"保持";
        case WCRRightActionReturn:
            return @"回组";
        case WCRRightActionMute:
            return @"免扰";
        case WCRRightActionRemind:
            return @"提醒";
        case WCRRightActionPending:
            return @"同步中";
        case WCRRightActionUnknown:
            return @"设置";
        case WCRRightActionNone:
        default:
            return nil;
    }
}

// Per-action title colour on the transparent action area. System colours are
// dynamic (light/dark variants), so the title is readable on white, pinned
// grey and dark cells alike.
static UIColor *WCRColorForActionKind(WCRRightActionKind kind) {
    switch (kind) {
        case WCRRightActionGroup:
            return [UIColor systemBlueColor];
        case WCRRightActionKeep:
            return [UIColor systemOrangeColor];
        case WCRRightActionReturn:
            return [UIColor systemGreenColor];
        case WCRRightActionMute:
        case WCRRightActionRemind:
        case WCRRightActionPending:
        case WCRRightActionUnknown:
            return [UIColor secondaryLabelColor];
        case WCRRightActionNone:
        default:
            return [UIColor systemGrayColor];
    }
}

static BOOL WCRApplyActionKindToCell(UITableViewCell *cell,
                                     WCRRightActionKind kind) {
    if (!cell) return NO;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button = objc_getAssociatedObject(cell, kWCRButtonKey);
    if (!button) return NO;

    NSString *title = WCRTitleForActionKind(kind);
    if (title.length == 0) {
        // Always clear stale UI even when the bookkeeping flags already say
        // “closed”. This makes cell reuse / interrupted animation self-heal.
        actionView.hidden = YES;
        [button setTitle:@"" forState:UIControlStateNormal];

        if (WCRBool(cell, kWCROpenKey) ||
            WCRBool(cell, kWCRTrackingKey)) {
            WCRCloseCell(cell, NO);
        }
        return NO;
    }

    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:WCRColorForActionKind(kind)
                 forState:UIControlStateNormal];
    UIButton *mute = objc_getAssociatedObject(cell, kWCRMuteButtonKey);
    mute.hidden = WCRGroupControllerForTable(WCRTableForCell(cell)) != nil;
    NSString *username = objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey);
    WCRAFAccountContext *context = objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
    BOOL pending = username.length > 0 && context &&
        [WCRReminderCoordinator() pendingNotifyForUsername:username context:context] >= 0;
    [mute setTitle:pending ? @"同步中" : @"免扰" forState:UIControlStateNormal];
    return YES;
}

static BOOL WCRPrepareActionForCell(UITableViewCell *cell) {
    WCRRightActionKind kind =
        WCRActionKindForCell(cell, NULL, NULL, NULL, NULL, NULL);
    return WCRApplyActionKindToCell(cell, kind);
}

static UIViewController *WCRPresenterForHost(id host) {
    UIViewController *vc = nil;

    if ([host isKindOfClass:[UIViewController class]]) {
        vc = (UIViewController *)host;
    }

    if (!vc) {
        vc = WCRTopVC();
    }

    while (vc.presentedViewController &&
           !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }

    return vc;
}

static void WCRPresentGroupPicker(id host,
                                  NSString *username,
                                  id session,
                                  UITableView *tableView,
                                  NSIndexPath *indexPath,
                                  WCRAFAccountContext *context) {
    if (username.length == 0 || !session ||
        ![WCRAFStore() isCurrentContext:context]) return;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    WCRefineGroupManager *mgr = WCRGroupManager();
    if (!provider || !mgr) return;

    NSUInteger scope = [provider groupScopeForNativeSession:session];
    NSArray<WCRefineGroup *> *groups = WCRAvailableGroupsForScope(scope);

    if (groups.count == 0) {
        UIViewController *presenter = WCRPresenterForHost(host);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无可用分组"
            message:@"请先在分组设置中创建对应的好友或群聊分组。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIViewController *presenter = WCRPresenterForHost(host);
    if (!presenter) return;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"分配到分组"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    for (WCRefineGroup *group in groups) {
        NSString *title =
            group.name.length > 0 ? group.name : @"未命名分组";
        NSString *groupId = [group.groupId copy];

        [sheet addAction:
            [UIAlertAction actionWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^(__unused UIAlertAction *action) {
            if (![WCRAFStore() isCurrentContext:context]) return;
            // Revalidate the destination; it may have changed while the sheet
            // was open, even without an account switch.
            BOOL destinationValid = NO;
            for (WCRefineGroup *current in WCRAvailableGroupsForScope(scope)) {
                if ([current.groupId isEqualToString:groupId]) {
                    destinationValid = YES;
                    break;
                }
            }
            if (!destinationValid || ![WCRAFStore() isCurrentContext:context]) return;
            // Add destination first. Only after success do we remove any other
            // custom-group membership, avoiding a transient "belongs nowhere"
            // state.
            BOOL ok = [mgr addMember:username toGroup:groupId];
            WCRInvalidateGroupIndex();
            if (!ok) {
                WCRAF_LOG(@"assign failed %@ -> %@", username, groupId);
                return;
            }

            NSArray<NSString *> *existing =
                [mgr groupIdsContainingMember:username] ?: @[];

            NSSet<NSString *> *customIds = WCRCustomGroupIdSet();

            for (NSString *existingGroupId in existing) {
                if (![WCRAFStore() isCurrentContext:context]) return;
                if ([customIds containsObject:existingGroupId] &&
                    ![existingGroupId isEqualToString:groupId]) {
                    [mgr removeMember:username
                             fromGroup:existingGroupId];
                    WCRInvalidateGroupIndex();
                }
            }

            if (![WCRAFStore() isCurrentContext:context]) return;
            [WCRAFStore() setHeld:NO username:username context:context];
            WCRInvalidateGroupIndex();

            WCRAF_LOG(@"assigned %@ -> %@", username, groupId);
            WCRRefreshHomeDeferred(host,
                                   @"active_front_assign_group", context);
        }]];
    }

    [sheet addAction:
        [UIAlertAction actionWithTitle:@"取消"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    UIPopoverPresentationController *popover =
        sheet.popoverPresentationController;

    if (popover) {
        UITableViewCell *cell =
            [tableView cellForRowAtIndexPath:indexPath];

        popover.sourceView = cell ?: presenter.view;
        popover.sourceRect =
            cell ? cell.bounds : presenter.view.bounds;
    }

    if (![WCRAFStore() isCurrentContext:context]) return;
    [presenter presentViewController:sheet
                            animated:YES
                          completion:nil];
}


#pragma mark - WeChat left-swipe menu guard

static BOOL WCRSwipeActionViewVisibleRecursive(UIView *view,
                                               UIView *ourActionView) {
    if (!view) return NO;

    // Never identify WCRefine's own left-side action view as a WeChat menu.
    if (view == ourActionView) return NO;

    if (!view.hidden &&
        view.alpha > 0.01 &&
        CGRectGetWidth(view.bounds) > 1.0 &&
        CGRectGetHeight(view.bounds) > 1.0) {

        NSString *className =
            [NSStringFromClass([view class]) lowercaseString];

        // Covers the UIKit swipe-action containers used across iOS versions.
        // Examples include:
        // _UISwipeActionPullView
        // UISwipeActionStandardButton
        // UITableViewCellSwipeContainerView
        // UITableViewCellDeleteConfirmationView
        if ([className containsString:@"swipeaction"] ||
            [className containsString:@"swipecontainer"] ||
            [className containsString:@"deleteconfirmation"]) {
            return YES;
        }
    }

    for (UIView *subview in view.subviews) {
        if (WCRSwipeActionViewVisibleRecursive(subview, ourActionView)) {
            return YES;
        }
    }

    return NO;
}


static BOOL WCRViewContainsControlRecursive(UIView *view) {
    if (!view || view.hidden || view.alpha <= 0.01) return NO;

    if ([view isKindOfClass:[UIControl class]]) {
        return YES;
    }

    for (UIView *subview in view.subviews) {
        if (WCRViewContainsControlRecursive(subview)) {
            return YES;
        }
    }

    return NO;
}

static BOOL WCRLargeRightEdgeActionSiblingVisible(UITableViewCell *cell,
                                                   UIView *ourActionView) {
    if (!cell) return NO;

    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat cellHeight = CGRectGetHeight(cell.bounds);
    if (cellWidth <= 1.0 || cellHeight <= 1.0) return NO;

    for (UIView *subview in cell.subviews) {
        if (subview == cell.contentView ||
            subview == ourActionView ||
            subview.hidden ||
            subview.alpha <= 0.01) {
            continue;
        }

        CGRect rect = [subview convertRect:subview.bounds toView:cell];

        BOOL occupiesRightEdge =
            CGRectGetWidth(rect) >= 44.0 &&
            CGRectGetHeight(rect) >= cellHeight * 0.55 &&
            CGRectGetMaxX(rect) >= cellWidth - 3.0 &&
            CGRectGetMinX(rect) >= cellWidth * 0.20;

        if (!occupiesRightEdge) continue;

        NSString *className =
            [NSStringFromClass([subview class]) lowercaseString];

        // First use private-class hints when available.
        if ([className containsString:@"swipe"] ||
            [className containsString:@"action"] ||
            [className containsString:@"delete"] ||
            [className containsString:@"confirmation"] ||
            [className containsString:@"pull"]) {
            return YES;
        }

        // Fallback for WeChat/iOS versions whose private class names changed:
        // a large direct sibling occupying the cell's right edge and
        // containing controls is characteristic of the native left-swipe menu.
        if (WCRViewContainsControlRecursive(subview)) {
            return YES;
        }
    }

    return NO;
}

static BOOL WCRWeChatLeftSwipeMenuVisible(UITableViewCell *cell) {
    if (!cell) return NO;

    UIView *ourActionView =
        objc_getAssociatedObject(cell, kWCRActionViewKey);

    // Older / simpler implementations move contentView itself.
    CGAffineTransform t = cell.contentView.transform;
    if (t.tx < -1.0) {
        return YES;
    }

    if (CGRectGetMinX(cell.contentView.frame) < -1.0) {
        return YES;
    }

    // During an animation the model-layer transform may already be reset while
    // the presentation layer is still visibly shifted.
    CALayer *presentation = cell.contentView.layer.presentationLayer;
    if (presentation) {
        CATransform3D pt = presentation.transform;
        if (pt.m41 < -1.0) {
            return YES;
        }
    }

    // Modern UITableView swipe actions usually live in private sibling
    // containers, so contentView itself can remain at tx == 0.
    if (WCRSwipeActionViewVisibleRecursive(cell, ourActionView)) {
        return YES;
    }

    // Geometry fallback for private class-name changes.
    if (WCRLargeRightEdgeActionSiblingVisible(cell, ourActionView)) {
        return YES;
    }

    return NO;
}

static void WCRSuppressOurActionForLeftMenu(UITableViewCell *cell) {
    if (!cell) return;

    UIView *actionView =
        objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button =
        objc_getAssociatedObject(cell, kWCRButtonKey);

    actionView.hidden = YES;
    [button setTitle:@"" forState:UIControlStateNormal];

    // Do not touch WeChat's transform here. The whole point is to let
    // WeChat's own rightward close gesture finish normally.
    WCRSetBool(cell, kWCROpenKey, NO);
    WCRSetBool(cell, kWCRTrackingKey, NO);
    WCRSetFloat(cell, kWCRStartOffsetKey, 0.0);
    objc_setAssociatedObject(cell, kWCRSwipeIntentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kWCRSwipeRenderedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCRRestoreSwipeVisual(cell);
    actionView.backgroundColor = [UIColor clearColor];
}


#pragma mark - Touch-down latch

@interface WCRRightPanGestureRecognizer : UIPanGestureRecognizer
@end

@implementation WCRRightPanGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event {
    BOOL nativeMenuWasVisible = NO;

    if ([self.view isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)self.view;
        nativeMenuWasVisible = WCRWeChatLeftSwipeMenuVisible(cell);

        if (nativeMenuWasVisible) {
            WCRSuppressOurActionForLeftMenu(cell);
        }
    }

    // Latch the state from the FIRST touch-down. Even if WeChat's menu starts
    // disappearing before gestureRecognizerShouldBegin: is queried, this
    // gesture remains reserved exclusively for closing the native menu.
    objc_setAssociatedObject(self,
                             kWCRNativeCloseLatchKey,
                             @(nativeMenuWasVisible),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [super touchesBegan:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];

    objc_setAssociatedObject(self,
                             kWCRNativeCloseLatchKey,
                             @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];

    objc_setAssociatedObject(self,
                             kWCRNativeCloseLatchKey,
                             @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

static BOOL WCRPanLatchedForNativeClose(UIGestureRecognizer *gestureRecognizer) {
    NSNumber *value =
        objc_getAssociatedObject(gestureRecognizer,
                                 kWCRNativeCloseLatchKey);
    return value.boolValue;
}

#pragma mark - Hold expiry picker (v1.9.7)

// Each conversation owns its chosen period; existing account defaults still load.
static void WCRPresentHoldExpiryPicker(id host,
                                       NSString *keepUsername,
                                       UITableView *tableView,
                                       NSIndexPath *indexPath,
                                       WCRAFAccountContext *context) {
    if (keepUsername.length == 0 || ![WCRAFStore() isCurrentContext:context]) return;
    UIViewController *presenter = WCRPresenterForHost(host);
    if (!presenter) return;

    NSString *message = @"此会话在所选天数内没有新消息后自动回组。选择后保持此会话。";

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"保持期限"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    NSInteger current = [WCRAFStore() expiryDaysForUsername:keepUsername context:context];
    NSMutableArray<NSNumber *> *options = [@[@1, @3, @5, @0] mutableCopy];
    if (![options containsObject:@(current)]) [options addObject:@(current)];
    NSString *keep = [keepUsername copy];
    __weak id weakHost = host;

    for (NSNumber *option in options) {
        NSInteger days = option.integerValue;
        NSString *label = days == 0 ?
            @"永不过期" :
            [NSString stringWithFormat:@"%ld 天", (long)days];
        if (days == kWCRAFDefaultHoldExpiryDays) {
            label = [label stringByAppendingString:@"（默认）"];
        }
        if (days == current) {
            label = [@"✓ " stringByAppendingString:label];
        }

        [sheet addAction:
            [UIAlertAction actionWithTitle:label
                                     style:UIAlertActionStyleDefault
                                   handler:^(__unused UIAlertAction *action) {
            if (![WCRAFStore() isCurrentContext:context] || !WCRIsInCustomGroup(keep)) return;
            if (days != current &&
                ![WCRAFStore() setExpiryDays:days username:keep context:context]) return;
            WCRSetHeld(keep, YES, weakHost, context);
        }]];
    }

    [sheet addAction:
        [UIAlertAction actionWithTitle:@"取消"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    UIPopoverPresentationController *popover =
        sheet.popoverPresentationController;
    if (popover) {
        UITableViewCell *cell =
            indexPath ? [tableView cellForRowAtIndexPath:indexPath] : nil;
        popover.sourceView = cell ?: presenter.view;
        popover.sourceRect = cell ? cell.bounds : presenter.view.bounds;
    }

    if (![WCRAFStore() isCurrentContext:context]) return;
    [presenter presentViewController:sheet
                            animated:YES
                          completion:nil];
}

#pragma mark - Controller

// Animate disposable pictures, never change WeChat's row counts or row heights.
// The host may reuse/reorder real cells while this short visual transition runs.
static UIView *gWCRReturnOverlay;
static WCRAFAccountContext *gWCRReturnAnimationContext;

static void WCRCancelReturnAnimation(void) {
    UIView *overlay = gWCRReturnOverlay;
    gWCRReturnOverlay = nil;
    gWCRReturnAnimationContext = nil;
    [overlay.layer removeAllAnimations];
    [overlay removeFromSuperview];
}

static BOOL WCRSwipeStillMatches(UITableViewCell *cell, WCRAFSwipeIntent *intent) {
    if (!intent || ![WCRAFStore() isCurrentContext:intent.context]) return NO;
    NSString *username = nil;
    WCRRightActionKind kind = WCRActionKindForCell(cell, NULL, NULL, NULL, NULL, &username);
    WCRAFAccountContext *context = objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
    return kind != WCRRightActionNone &&
        [intent matchesUsername:username context:context
            grouped:kind != WCRRightActionGroup held:kind == WCRRightActionReturn] &&
        [WCRAFStore() isCurrentContext:context];
}

// A cheap binding check for each display frame. Full business resolution runs
// at begin/commit, not on every change event.
static BOOL WCRSwipeBindingMatches(UITableViewCell *cell, WCRAFSwipeIntent *intent) {
    return intent &&
        objc_getAssociatedObject(cell, kWCRCanonicalAccountKey) == intent.context &&
        [objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey) isEqualToString:intent.username] &&
        objc_getAssociatedObject(cell, kWCRSwipeRenderedKey) == WCRRenderedCellData(cell);
}

static void WCRAnimateReturn(UITableViewCell *cell, WCRAFSwipeIntent *intent) {
    if (!WCRIsActiveFrontHomeTable(WCRTableForCell(cell)) ||
        !WCRSwipeStillMatches(cell, intent) || !intent.grouped) {
        WCRCloseCell(cell, YES);
        return;
    }
    UITableView *table = WCRTableForCell(cell);
    UIView *container = table.superview;
    id host = WCRHomeControllerForTable(table);
    if (!container || !cell.window || !WCRActivityHomeController()) {
        WCRCloseCell(cell, YES);
        return;
    }
    // Re-fetch native data before mutation; a captured row alone is not authority.
    WCRefineGroupDataProvider *provider = WCRDataProvider();
    id latest = nil;
    @try {
        latest = [provider fulfilledSessionForUsername:intent.username fallback:nil];
        latest = [provider nativeSessionFromObject:latest] ?: latest;
        NSString *name = nil;
        BOOL grouped = NO, held = NO;
        if (!WCRResolveSessionState(latest, &name, &grouped, &held) ||
            ![intent matchesUsername:name context:[WCRAFStore() currentContext]
                grouped:grouped held:held] || !WCRSwipeStillMatches(cell, intent)) {
            WCRCloseCell(cell, YES);
            return;
        }
    } @catch (__unused NSException *exception) {
        WCRCloseCell(cell, YES);
        return;
    }

    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    UIView *overlay = nil, *upper = nil, *lower = nil, *moving = nil, *band = nil;
    CGRect visible = table.bounds;
    CGRect row = [cell convertRect:cell.bounds toView:table];
    CGFloat cutTop = MAX(CGRectGetMinY(visible), CGRectGetMinY(row));
    CGFloat cutBottom = MIN(CGRectGetMaxY(visible), CGRectGetMaxY(row));
    CGFloat removedHeight = cutBottom - cutTop;
    CGFloat rowY = cutTop - CGRectGetMinY(visible);
    if (!reduceMotion && removedHeight > 1.0) {
        overlay = [[UIView alloc] initWithFrame:[table convertRect:visible toView:container]];
        overlay.clipsToBounds = YES;
        overlay.backgroundColor = table.backgroundColor ?: [UIColor systemBackgroundColor];
        // Keep this brief transition stationary and avoid touches on stale pictures.
        overlay.userInteractionEnabled = YES;
        CGRect upperRect = CGRectMake(CGRectGetMinX(visible), CGRectGetMinY(visible),
            CGRectGetWidth(visible), rowY);
        CGRect lowerRect = CGRectMake(CGRectGetMinX(visible), cutBottom,
            CGRectGetWidth(visible), CGRectGetMaxY(visible) - cutBottom);
        if (upperRect.size.height > 0) {
            upper = [table resizableSnapshotViewFromRect:upperRect afterScreenUpdates:NO
                withCapInsets:UIEdgeInsetsZero];
            upper.frame = CGRectMake(0, 0, upperRect.size.width, upperRect.size.height);
            if (upper) [overlay addSubview:upper];
        }
        if (lowerRect.size.height > 0) {
            lower = [table resizableSnapshotViewFromRect:lowerRect afterScreenUpdates:NO
                withCapInsets:UIEdgeInsetsZero];
            lower.frame = CGRectMake(0, rowY + removedHeight,
                lowerRect.size.width, lowerRect.size.height);
            if (lower) [overlay addSubview:lower];
        }
        band = [[UIView alloc] initWithFrame:CGRectMake(0, rowY,
            CGRectGetWidth(visible), removedHeight)];
        band.backgroundColor = WCRSwipeBackground(cell);
        [overlay addSubview:band];
        moving = objc_getAssociatedObject(cell, kWCRSwipeForegroundKey);
        CGRect movingFrame = [cell convertRect:moving.frame toView:table];
        movingFrame.origin.x -= visible.origin.x;
        movingFrame.origin.y -= visible.origin.y;
        // Transfer the existing foreground only after persistence succeeds.
        objc_setAssociatedObject(overlay, kWCRSwipeOffsetKey,
            [NSValue valueWithCGRect:movingFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Missing pictures should degrade to the normal host refresh.
        if (!moving || (upperRect.size.height > 0 && !upper) ||
            (lowerRect.size.height > 0 && !lower)) overlay = nil;
    }
    WCRCancelReturnAnimation();
    // Commit once at the threshold. No animation callback changes state.
    WCRInvalidateOutgoing(intent.username, intent.context);
    if (![WCRAFStore() setHeld:NO username:intent.username context:intent.context]) {
        WCRCloseCell(cell, YES);
        return;
    }
    if (overlay) {
        objc_setAssociatedObject(cell, kWCRSwipeForegroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [moving removeFromSuperview];
        moving.frame = [objc_getAssociatedObject(overlay, kWCRSwipeOffsetKey) CGRectValue];
        [overlay addSubview:moving];
        gWCRReturnOverlay = overlay;
        gWCRReturnAnimationContext = intent.context;
        [container addSubview:overlay];
    }
    WCRCloseCell(cell, NO);
    WCRRefreshHome(host, @"active_front_swipe_return", intent.context);
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    if (!overlay || gWCRReturnOverlay != overlay) return;
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseOut
        animations:^{
        CGRect frame = moving.frame;
        frame.origin.x = CGRectGetWidth(overlay.bounds);
        moving.frame = frame;
    } completion:^(BOOL finished) {
        if (gWCRReturnOverlay != overlay) return;
        if (!finished || ![WCRAFStore() isCurrentContext:intent.context] ||
            !WCRActivityHomeController()) {
            WCRCancelReturnAnimation();
            return;
        }
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseInOut
            animations:^{
            CGRect frame = lower.frame;
            frame.origin.y -= removedHeight;
            lower.frame = frame;
            CGRect bandFrame = band.frame;
            bandFrame.size.height = 0;
            band.frame = bandFrame;
        } completion:^(__unused BOOL collapsed) {
            if (gWCRReturnOverlay == overlay) WCRCancelReturnAnimation();
        }];
    }];
}



@interface WCRRightSwipeController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
- (void)actionTapped:(UIButton *)sender;
- (void)actionLongPressed:(UILongPressGestureRecognizer *)gesture;
@end

@implementation WCRRightSwipeController

+ (instancetype)shared {
    static WCRRightSwipeController *obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        obj = [WCRRightSwipeController new];
    });
    return obj;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return YES;
    }

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    if (![pan.view isKindOfClass:[UITableViewCell class]]) {
        return NO;
    }

    UITableViewCell *cell = (UITableViewCell *)pan.view;
    UITableView *tableView = WCRTableForCell(cell);
    if (!WCRIsSupportedSwipeCell(cell) || !WCRIsSupportedSwipeTable(tableView)) return NO;
    if (gWCRReturnOverlay) return NO;

    CGPoint velocity = [pan velocityInView:cell];

    // Absolute highest-priority guard: this touch began while WeChat's
    // left-swipe menu was already open. The entire gesture belongs to WeChat
    // even if that menu visually disappears before shouldBegin is evaluated.
    if (WCRPanLatchedForNativeClose(gestureRecognizer)) {
        WCRSuppressOurActionForLeftMenu(cell);
        return NO;
    }

    // Highest-priority live-state guard:
    // if WeChat's native LEFT-swipe menu is already visible, a rightward pan
    // means "close WeChat's menu", not "open WCRefine's right-swipe menu".
    //
    // Our recognizer must fail before it claims the gesture, allowing the
    // original WeChat recognizer (which waits for ours to fail) to proceed.
    if (WCRWeChatLeftSwipeMenuVisible(cell)) {
        WCRSuppressOurActionForLeftMenu(cell);
        return NO;
    }

    // If our action is already open, allow a horizontal drag in either
    // direction so the user can drag left to close it.
    if (WCRBool(cell, kWCROpenKey)) {
        return fabs(velocity.x) > fabs(velocity.y) * 1.05;
    }

    // Only rows with a real ActiveFront action may claim RIGHT swipe.
    // This also refreshes 分组 / 保持 / 回组 immediately before the gesture.
    if (!WCRPrepareActionForCell(cell)) return NO;

    // Critical rule: unopened cells are claimed ONLY for horizontal RIGHT pan.
    // A LEFT pan fails here and remains WeChat's original gesture path.
    if (velocity.x <= 30.0) return NO;
    if (fabs(velocity.x) <= fabs(velocity.y) * 1.12) return NO;

    // Secondary safeguard for versions where the native menu starts
    // shifting after shouldBegin was queried.
    if (WCRWeChatLeftSwipeMenuVisible(cell)) {
        WCRSuppressOurActionForLeftMenu(cell);
        return NO;
    }

    return YES;
}

- (BOOL)       gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {

    (void)gestureRecognizer;

    // Horizontal ownership must be exclusive. Allowing simultaneous pan
    // recognition is what made the native left menu and WCRefine menu appear
    // together intermittently.
    //
    // Vertical scrolling is unaffected because our right-only recognizer fails
    // its shouldBegin direction test before the table's vertical pan proceeds.
    if ([otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return NO;
    }
    return NO;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (![pan.view isKindOfClass:[UITableViewCell class]]) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        WCRSetBool(pan, kWCRPanConsumedKey, NO);
    } else if (WCRBool(pan, kWCRPanConsumedKey)) {
        // The touch may still be down while the original cell is reused.
        return;
    }

    UITableViewCell *cell = (UITableViewCell *)pan.view;
    if (!WCRIsSupportedSwipeCell(cell)) return;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    if (!actionView) return;

    CGPoint translation = [pan translationInView:cell];
    CGPoint velocity = [pan velocityInView:cell];

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            if (WCRPanLatchedForNativeClose(pan) ||
                WCRWeChatLeftSwipeMenuVisible(cell)) {
                WCRSuppressOurActionForLeftMenu(cell);

                // Cancel only our recognizer. Do not touch WeChat's views or
                // transforms; its recognizer remains responsible for closing
                // the native left-swipe menu.
                pan.enabled = NO;
                pan.enabled = YES;
                break;
            }

            NSString *username = nil;
            WCRRightActionKind kind = WCRActionKindForCell(cell, NULL, NULL, NULL, NULL, &username);
            WCRAFAccountContext *context = objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
            if (kind == WCRRightActionNone || ![WCRAFStore() isCurrentContext:context] ||
                !WCRApplyActionKindToCell(cell, kind)) {
                WCRCloseCell(cell, NO);
                break;
            }
            WCRAFSwipeIntent *intent = [[WCRAFSwipeIntent alloc] initWithUsername:username
                context:context grouped:kind != WCRRightActionGroup held:kind == WCRRightActionReturn];
            objc_setAssociatedObject(cell, kWCRSwipeIntentKey, intent, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            WCRCloseOtherCells(cell);
            if (!WCRBeginSwipeVisual(cell)) {
                WCRCloseCell(cell, NO);
                pan.enabled = NO;
                pan.enabled = YES;
                break;
            }
            objc_setAssociatedObject(cell, kWCRSwipeRenderedKey, WCRRenderedCellData(cell),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGFloat startOffset = WCRFloat(cell, kWCRSwipeOffsetKey);

            WCRSetFloat(cell, kWCRStartOffsetKey, startOffset);
            WCRSetBool(cell, kWCRTrackingKey, YES);
            actionView.backgroundColor = WCRSwipeBackground(cell);
            actionView.hidden = NO;
            WCRLayoutAction(cell);
            break;
        }

        case UIGestureRecognizerStateChanged: {
            WCRAFSwipeIntent *intent = objc_getAssociatedObject(cell, kWCRSwipeIntentKey);
            if (!WCRBool(cell, kWCRTrackingKey) || !WCRSwipeBindingMatches(cell, intent)) {
                WCRCloseCell(cell, NO);
                break;
            }
            CGFloat x = WCRFloat(cell, kWCRStartOffsetKey) + translation.x;

            if (x < 0.0) {
                x = 0.0;
            }

            BOOL home = WCRIsActiveFrontHomeTable(WCRTableForCell(cell));
            x = MIN(x, home && intent.grouped ? CGRectGetWidth(cell.bounds) : WCRActionExtent(cell));

            WCRSetContentOffset(cell, x);
            WCRLayoutAction(cell);
            if (home && [intent consumeReturnAtDistance:x rowWidth:CGRectGetWidth(cell.bounds)
                    actionWidth:kWCRReturnActionWidth cancelled:NO]) {
                WCRSetBool(pan, kWCRPanConsumedKey, YES);
                WCRAnimateReturn(cell, intent);
            }
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            // A final sample can cross the threshold even if UIKit coalesced
            // the last Changed event. Use the same once-only distance policy.
            WCRAFSwipeIntent *intent = objc_getAssociatedObject(cell, kWCRSwipeIntentKey);
            CGFloat currentX = MAX(0, WCRFloat(cell, kWCRStartOffsetKey) + translation.x);
            BOOL cancelled =
                (pan.state == UIGestureRecognizerStateCancelled ||
                 pan.state == UIGestureRecognizerStateFailed);

            if (!WCRBool(cell, kWCRTrackingKey) || !WCRSwipeStillMatches(cell, intent)) {
                WCRCloseCell(cell, NO);
                break;
            }
            if (WCRIsActiveFrontHomeTable(WCRTableForCell(cell)) &&
                [intent consumeReturnAtDistance:currentX rowWidth:CGRectGetWidth(cell.bounds)
                    actionWidth:kWCRReturnActionWidth cancelled:cancelled]) {
                WCRSetBool(pan, kWCRPanConsumedKey, YES);
                WCRAnimateReturn(cell, intent);
                break;
            }
            objc_setAssociatedObject(cell, kWCRSwipeIntentKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WCRPrepareActionForCell(cell);
            BOOL shouldOpen = NO;
            if (!cancelled) {
                shouldOpen =
                    (currentX >= WCRActionExtent(cell) * 0.42) ||
                    (velocity.x >= 520.0);
            }

            if (velocity.x <= -420.0) {
                shouldOpen = NO;
            }

            if (shouldOpen) {
                WCROpenCell(cell);
            } else {
                WCRCloseCell(cell, YES);
            }
            break;
        }

        default:
            break;
    }
}

- (void)actionTapped:(UIButton *)sender {
    UIView *v = sender;
    UITableViewCell *cell = nil;

    while (v) {
        if ([v isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell *)v;
            break;
        }
        v = v.superview;
    }

    if (!cell) return;

    id host = nil;
    UITableView *tableView = nil;
    NSIndexPath *indexPath = nil;
    id session = nil;
    NSString *username = nil;

    WCRRightActionKind kind =
        WCRActionKindForCell(cell,
                             &host,
                             &tableView,
                             &indexPath,
                             &session,
                             &username);

    if (kind == WCRRightActionNone) {
        WCRCloseCell(cell, YES);
        return;
    }

    WCRAFAccountContext *context =
        objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
    if (![WCRAFStore() isCurrentContext:context]) {
        WCRCloseCell(cell, YES);
        return;
    }
    if (sender == objc_getAssociatedObject(cell, kWCRMuteButtonKey)) {
        kind = [WCRReminderCoordinator() pendingNotifyForUsername:username context:context] >= 0 ?
            WCRRightActionPending : WCRRightActionMute;
    } else if (![sender.currentTitle isEqualToString:WCRTitleForActionKind(kind)]) {
        WCRCloseCell(cell, YES);
        return;
    }
    WCRCloseCell(cell, YES);

    switch (kind) {
        case WCRRightActionGroup: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.18 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WCRPresentGroupPicker(host,
                                      username,
                                      session,
                                      tableView,
                                      indexPath,
                                      context);
            });
            break;
        }

        case WCRRightActionKeep:
            WCRSetHeld(username, YES, host, context);
            break;

        case WCRRightActionReturn:
            WCRSetHeld(username, NO, host, context);
            break;

        case WCRRightActionMute:
        case WCRRightActionRemind: {
            WCRInvalidateSendAcknowledgments(username, context);
            __weak id weakHost = host;
            WCRSetNativeMuted(username, kind == WCRRightActionMute, context, ^(BOOL success, NSString *failure) {
                if (!success) {
                    if (failure.length > 0) WCRReminderFailure(failure);
                    return;
                }
                if (kind == WCRRightActionMute && WCRIsInCustomGroup(username)) {
                    if (![WCRAFStore() setHeld:NO username:username context:context]) {
                        WCRReminderFailure(@"消息免打扰已开启，但回组状态保存失败（S01）");
                    }
                }
                WCRRefreshHomeDeferred(weakHost, @"active_front_reminder_changed", context);
            });
            break;
        }
        case WCRRightActionPending:
            WCRQueueReminderObservation(username, context);
            break;
        case WCRRightActionNone:
        default:
            break;
    }
}

- (void)actionLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    UIView *v = gesture.view;
    UITableViewCell *cell = nil;
    while (v) {
        if ([v isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell *)v;
            break;
        }
        v = v.superview;
    }
    if (!cell) return;

    id host = nil;
    UITableView *tableView = nil;
    NSIndexPath *indexPath = nil;
    id session = nil;
    NSString *username = nil;

    WCRRightActionKind kind =
        WCRActionKindForCell(cell,
                             &host,
                             &tableView,
                             &indexPath,
                             &session,
                             &username);

    if (kind != WCRRightActionKeep && kind != WCRRightActionReturn) return;

    WCRAFAccountContext *context =
        objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
    if (![WCRAFStore() isCurrentContext:context]) return;

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];

    WCRCloseCell(cell, YES);

    NSString *keep = username;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCRPresentHoldExpiryPicker(host, keep, tableView, indexPath, context);
    });
}

@end

#pragma mark - Attach / priority

static void WCRWirePanPriority(UIView *view,
                               UIPanGestureRecognizer *ourPan) {
    if (!view || !ourPan) return;

    for (UIGestureRecognizer *gr in view.gestureRecognizers) {
        if (gr == ourPan) continue;
        if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) continue;

        // If WeChat has its own horizontal cell pan on the cell/contentView,
        // make it wait for our right-only recognizer.
        //
        // RIGHT: our recognizer begins -> WeChat cell pan does not win.
        // LEFT : our shouldBegin returns NO -> WeChat pan proceeds normally.
        [(UIPanGestureRecognizer *)gr requireGestureRecognizerToFail:ourPan];
    }
}

static void WCRAttachToCell(UITableViewCell *cell) {
    UITableView *tableView = WCRTableForCell(cell);
    // All entry points, including didMoveToWindow, must leave grouping rows
    // to UIKit. A cell pan would otherwise compete with the native action.
    if (!WCRIsActiveFrontHomeTable(tableView) ||
        !WCRIsMainFrameCell(cell)) return;

    NSString *currentUsername = nil;
    WCRRightActionKind currentKind =
        WCRActionKindForCell(cell,
                             NULL,
                             NULL,
                             NULL,
                             NULL,
                             &currentUsername);
    NSString *boundUsername =
        objc_getAssociatedObject(cell, kWCRBoundUsernameKey);

    // UITableView recycles NewMainFrameCell objects. If the same cell object
    // now represents another session, no swipe UI state may survive the old
    // session. Auto-return after reading is a common path that causes exactly
    // this reuse.
    if (boundUsername.length > 0 &&
        currentUsername.length > 0 &&
        ![boundUsername isEqualToString:currentUsername]) {
        WCRHardResetCellVisual(cell, YES);
        boundUsername = nil;
    }

    if (currentUsername.length > 0 &&
        ![boundUsername isEqualToString:currentUsername]) {
        objc_setAssociatedObject(cell,
                                 kWCRBoundUsernameKey,
                                 [currentUsername copy],
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    UIPanGestureRecognizer *pan =
        objc_getAssociatedObject(cell, kWCRPanKey);

    if (!pan) {
        UIView *actionView =
            [[UIView alloc] initWithFrame:CGRectZero];
        // User-tested v1.7 visual: keep the revealed action area transparent.
        actionView.backgroundColor = [UIColor clearColor];
        actionView.hidden = YES;
        actionView.clipsToBounds = YES;

        UIButton *button =
            [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:@"" forState:UIControlStateNormal];
        // Real colour is set per action in WCRPrepareActionForCell.
        [button setTitleColor:WCRColorForActionKind(WCRRightActionNone)
                     forState:UIControlStateNormal];
        button.titleLabel.font =
            [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        button.backgroundColor = [UIColor clearColor];

        [button addTarget:[WCRRightSwipeController shared]
                   action:@selector(actionTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        // v1.9.7: long-press 保持 / 回组 -> hold expiry picker. The recognizer
        // cancels the button's touches, so a long-press never also taps.
        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc]
                initWithTarget:[WCRRightSwipeController shared]
                        action:@selector(actionLongPressed:)];
        longPress.minimumPressDuration = 0.45;
        [button addGestureRecognizer:longPress];

        [actionView addSubview:button];
        UIButton *mute = [UIButton buttonWithType:UIButtonTypeSystem];
        mute.titleLabel.font = button.titleLabel.font;
        [mute setTitle:@"免扰" forState:UIControlStateNormal];
        [mute setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
        [mute addTarget:[WCRRightSwipeController shared] action:@selector(actionTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [actionView addSubview:mute];
        objc_setAssociatedObject(cell, kWCRMuteButtonKey, mute, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Keep the action behind contentView, but hidden unless OUR pan begins.
        // This is what prevents the old v1.5 "left swipe sees 分组 underneath"
        // problem.
        [cell insertSubview:actionView belowSubview:cell.contentView];

        pan =
            [[WCRRightPanGestureRecognizer alloc]
                initWithTarget:[WCRRightSwipeController shared]
                        action:@selector(handlePan:)];

        pan.delegate = [WCRRightSwipeController shared];
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = YES;
        pan.delaysTouchesBegan = NO;
        pan.delaysTouchesEnded = NO;

        [cell addGestureRecognizer:pan];

        objc_setAssociatedObject(cell,
                                 kWCRPanKey,
                                 pan,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell,
                                 kWCRActionViewKey,
                                 actionView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell,
                                 kWCRButtonKey,
                                 button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        WCRSetBool(cell, kWCROpenKey, NO);
        WCRSetBool(cell, kWCRTrackingKey, NO);
        WCRSetFloat(cell, kWCRStartOffsetKey, 0.0);
    }

    WCRLayoutAction(cell);
    WCRAFSwipeIntent *intent = objc_getAssociatedObject(cell, kWCRSwipeIntentKey);
    if (WCRBool(cell, kWCRTrackingKey) &&
        (!WCRSwipeBindingMatches(cell, intent) || !WCRSwipeStillMatches(cell, intent))) {
        WCRCloseCell(cell, NO);
    }
    if (!WCRBool(cell, kWCRTrackingKey)) {
        WCRApplyActionKindToCell(cell, currentKind);
    }

    // Reconcile the visual state on every scan. A valid action title does not
    // mean its view should be visible: closed rows must always keep the action
    // layer hidden behind the cell. This also self-heals interrupted animations.
    if (!WCRBool(cell, kWCROpenKey) &&
        !WCRBool(cell, kWCRTrackingKey)) {
        UIView *actionView =
            objc_getAssociatedObject(cell, kWCRActionViewKey);
        actionView.hidden = YES;
    }

    // Re-run this because WeChat may add/recreate its cell recognizers later.
    WCRWirePanPriority(cell, pan);
    WCRWirePanPriority(cell.contentView, pan);
}


#pragma mark - ActiveFront projection runtime hooks

static WCRAFOutgoingLedger *WCROutgoingLedger(void) {
    static WCRAFOutgoingLedger *ledger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ledger = [WCRAFOutgoingLedger new]; });
    return ledger;
}

static void WCRInvalidateSendAcknowledgments(NSString *username, WCRAFAccountContext *context) {
    if (![NSThread isMainThread] || ![WCRAFStore() isCurrentContext:context]) return;
    [WCROutgoingLedger() invalidateUsername:username context:context];
}

static void WCRInvalidateOutgoing(NSString *username, WCRAFAccountContext *context) {
    if (![NSThread isMainThread] || ![WCRAFStore() isCurrentContext:context]) return;
    WCRInvalidateSendAcknowledgments(username, context);
    [WCRReminderCoordinator() invalidateUsername:username];
}

static id WCRMessageValue(id wrap, NSString *key) {
    @try { return [wrap valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static NSString *WCRCurrentChatUsername(void) {
    @try {
        id contact = WCRObjectResult(NSClassFromString(@"WCRefineHelper"),
            @"currentChatContactFromTopViewController");
        id username = WCRMessageValue(contact, @"m_nsUsrName");
        return [username isKindOfClass:NSString.class] ? username : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static uint64_t WCRMessageID(id wrap, NSString *key) {
    id number = WCRMessageValue(wrap, key);
    return [number isKindOfClass:NSNumber.class] ? [number unsignedLongLongValue] : 0;
}

static NSTimeInterval WCRMessageTime(id wrap) {
    id number = WCRMessageValue(wrap, @"m_uiCreateTime");
    double value = [number isKindOfClass:NSNumber.class] ? [number doubleValue] : 0;
    return isfinite(value) && value > 0 ? value : 0;
}

static WCRAFOutgoingTicket *WCRStageLocalSend(NSString *username, id wrap) {
    if (![NSThread isMainThread] || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        ![username isKindOfClass:NSString.class] || WCRMessageID(wrap, @"m_n64MesSvrID") != 0 ||
        ![WCRCurrentChatUsername() isEqualToString:username]) return nil;
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (!context || ![WCRMessageValue(wrap, @"m_nsFromUsr") isEqual:context.account] ||
        ![WCRMessageValue(wrap, @"m_nsToUsr") isEqual:username] ||
        !WCRIsInCustomGroup(username)) return nil;
    NSTimeInterval time = WCRMessageTime(wrap), now = NSDate.date.timeIntervalSince1970;
    if (time <= 0 || time > now || now - time > 60) return nil;
    if (![WCRAFStore() isCurrentContext:context]) return nil;
    return [WCROutgoingLedger() stageUsername:username context:context token:wrap messageTime:time];
}

static void WCRQueueSendAcknowledgment(NSString *username, id wrap) {
    uint64_t serverID = WCRMessageID(wrap, @"m_n64MesSvrID");
    if (!serverID || ![username isKindOfClass:NSString.class]) return;
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (!context || ![WCRMessageValue(wrap, @"m_nsFromUsr") isEqual:context.account] ||
        ![WCRMessageValue(wrap, @"m_nsToUsr") isEqual:username]) return;
    NSString *name = [username copy];
    NSTimeInterval time = WCRMessageTime(wrap);
    uint64_t localID = WCRMessageID(wrap, @"m_uiMesLocalID");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![WCRAFStore() isCurrentContext:context]) return;
        WCRAFOutgoingTicket *ticket = [WCROutgoingLedger() acknowledgeUsername:name context:context
            token:wrap localID:localID serverID:serverID messageTime:time];
        if (!ticket || !WCRIsInCustomGroup(name)) return;
        @try {
            id latest = [WCRDataProvider() fulfilledSessionForUsername:name fallback:nil];
            NSString *canonicalName = nil;
            if (!WCRConversationFromCandidate(latest, NULL, &canonicalName, NULL) ||
                ![canonicalName isEqualToString:name] || ![WCRAFStore() isCurrentContext:context]) return;
            WCRSetNativeMuted(name, NO, context, ^(BOOL success, NSString *failure) {
                if (!success) {
                    if (failure.length > 0) WCRReminderFailure(failure);
                    return;
                }
                @try {
                    if (!WCRIsInCustomGroup(name) || ![WCRAFStore() isCurrentContext:context]) return;
                    id current = [WCRDataProvider() fulfilledSessionForUsername:name fallback:nil];
                    NSString *currentName = nil;
                    if (!WCRConversationFromCandidate(current, NULL, &currentName, NULL) ||
                        ![currentName isEqualToString:name]) return;
                    NSTimeInterval latestTime = MAX(ticket.messageTime, WCRSessionLastMessageTime(current));
                    if ([WCRAFStore() noteOutgoingMessage:name context:context lastMessageTime:latestTime]) {
                        WCRRefreshHomeGlobal(@"active_front_outgoing_acknowledged", context);
                    }
                } @catch (__unused NSException *exception) { }
            });
        } @catch (__unused NSException *exception) { }
    });
}

static void (*orig_addMsg)(id, SEL, id, id);
static void (*orig_sessionAddMsg)(id, SEL, id, id);
static void (*orig_sessionModMsg)(id, SEL, id, id);
static UITableViewCell *(*orig_groupCell)(id, SEL, UITableView *, NSIndexPath *);
static NSMutableDictionary *gWCRGroupLeadingSwipeOriginals;
static NSMutableDictionary *gWCRGroupCanEditOriginals;
static BOOL (*orig_groupCellPanShouldBegin)(id, SEL, UIGestureRecognizer *);
static void (*orig_homeSelection)(id, SEL, UITableView *, NSIndexPath *);
static void (*orig_groupDisappear)(id, SEL, BOOL);
static void (*orig_groupAppear)(id, SEL, BOOL);
static BOOL gWCRHookGroupLeadingSwipe;
static BOOL gWCRHookGroupCanEdit;
static const void *kWCRGroupSwipeDelegatesKey = &kWCRGroupSwipeDelegatesKey;

static UISwipeActionsConfiguration *hook_groupLeadingSwipe(
    id self, SEL cmd, UITableView *table, NSIndexPath *path);
static BOOL hook_groupCanEdit(id self, SEL cmd, UITableView *table, NSIndexPath *path);

static NSValue *WCRClassKey(Class cls) {
    return [NSValue valueWithPointer:(__bridge const void *)cls];
}

static void WCRRememberGroupRowOriginal(NSMutableDictionary *__strong *originals, Class cls, IMP original) {
    if (!*originals) {
        *originals = [NSMutableDictionary dictionary];
    }
    if (original) {
        (*originals)[WCRClassKey(cls)] =
            [NSValue valueWithBytes:&original objCType:@encode(IMP)];
    } else {
        (*originals)[WCRClassKey(cls)] = [NSNull null];
    }
}

static IMP WCRGroupRowOriginal(NSMutableDictionary *originals, id receiver) {
    for (Class cls = object_getClass(receiver); cls; cls = class_getSuperclass(cls)) {
        NSValue *key = WCRClassKey(cls);
        id value = originals[key];
        if (!value) continue;
        if (![value isKindOfClass:[NSValue class]]) return NULL;
        IMP original = NULL;
        [value getValue:&original];
        return original;
    }
    return NULL;
}

static BOOL WCRInstallGroupRowMethod(Class cls, SEL selector, IMP replacement,
                                     char result, NSMutableDictionary *__strong *originals) {
    if (!cls) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        const char *types = result == '@' ? "@@:@@" : "B@:@@";
        if (!class_addMethod(cls, selector, replacement, types)) {
            return NO;
        }
        WCRRememberGroupRowOriginal(originals, cls, NULL);
        return YES;
    }

    const char *types = method_getTypeEncoding(method);
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
    if (signature.numberOfArguments != 4 ||
        (signature.methodReturnType[0] != result &&
         !(result == 'B' && signature.methodReturnType[0] == 'c')) ||
        [signature getArgumentTypeAtIndex:2][0] != '@' ||
        [signature getArgumentTypeAtIndex:3][0] != '@') {
        return NO;
    }

    IMP current = method_getImplementation(method);
    if (current == replacement) return YES;
    BOOL added = class_addMethod(cls, selector, replacement, types);
    if (!added) {
        current = class_replaceMethod(cls, selector, replacement, types);
    }
    WCRRememberGroupRowOriginal(originals, cls, current);
    return YES;
}

static BOOL WCRInstallGroupLeadingSwipeForClass(Class cls) {
    return WCRInstallGroupRowMethod(cls, NSSelectorFromString(
        @"tableView:leadingSwipeActionsConfigurationForRowAtIndexPath:"),
        (IMP)hook_groupLeadingSwipe, '@', &gWCRGroupLeadingSwipeOriginals);
}

static BOOL WCRInstallGroupCanEditForClass(Class cls) {
    return WCRInstallGroupRowMethod(cls, NSSelectorFromString(
        @"tableView:canEditRowAtIndexPath:"), (IMP)hook_groupCanEdit,
        'B', &gWCRGroupCanEditOriginals);
}

static WCRRightActionKind WCRGroupActionAtPath(UITableView *table,
                                                NSIndexPath *path,
                                                NSString **usernameOut) {
    WCRGroupingSessionListViewController *controller = WCRGroupControllerForTable(table);
    if (!controller || !path || path.section != 0 || path.row < 0) return WCRRightActionNone;
    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    if (!cell) return WCRRightActionNone;
    WCRBindCanonicalHomeRow(cell, controller, table, path);
    return WCRActionKindForCell(cell, NULL, NULL, NULL, NULL, usernameOut);
}

static BOOL hook_groupCanEdit(id self, SEL cmd, UITableView *table, NSIndexPath *path) {
    WCRGroupingSessionListViewController *controller =
        WCRGroupControllerForTable(table);
    if (controller && path && path.section == 0 && path.row >= 0) {
        NSArray *items = nil;
        @try { items = [controller items]; }
        @catch (__unused NSException *exception) { items = nil; }
        // UIKit may ask whether a row is editable before its cell exists,
        // especially while the grouped list is being laid out on iPad.
        // The list contains only real conversation rows; defer action-state
        // resolution until the native leading-action callback has a cell.
        if (path.row < (NSInteger)items.count) {
            WCRGroupSwipeTrace(@"canEdit", @"known-group-row=YES");
            return YES;
        }
    }
    WCRRightActionKind kind = WCRGroupActionAtPath(table, path, NULL);
    if (kind == WCRRightActionMute || kind == WCRRightActionRemind ||
        kind == WCRRightActionPending) return YES;
    IMP original = WCRGroupRowOriginal(gWCRGroupCanEditOriginals, self);
    return original ? ((BOOL (*)(id, SEL, UITableView *, NSIndexPath *))original)(
        self, cmd, table, path) : NO;
}

static BOOL hook_groupCellPanShouldBegin(id self, SEL cmd, UIGestureRecognizer *gesture) {
    // WCRefine configures WeChat's MMBaseMultiMenuTableViewCell for LEFT
    // menus. Yield only a closed, eligible grouped row's RIGHT pan to UIKit.
    if ([self isKindOfClass:UITableViewCell.class] &&
        [gesture isKindOfClass:UIPanGestureRecognizer.class]) {
        UITableViewCell *cell = self;
        UITableView *table = WCRTableForCell(cell);
        if (WCRGroupControllerForTable(table) && !WCRWeChatLeftSwipeMenuVisible(cell)) {
            CGPoint velocity = [(UIPanGestureRecognizer *)gesture velocityInView:cell];
            if (velocity.x > 0 && velocity.x > fabs(velocity.y) * 1.12) {
                NSString *username = nil;
                WCRGroupActionAtPath(table, [table indexPathForCell:cell], &username);
                if (username.length > 0) return NO;
            }
        }
    }
    return orig_groupCellPanShouldBegin ?
        orig_groupCellPanShouldBegin(self, cmd, gesture) : YES;
}

static void WCRConfigureGroupingSwipe(UITableView *table, id controller) {
    if (!table || !WCRIsGroupingSessionListController(controller)) return;
    WCRRememberGroupingTable(table, controller);
    WCRAFGroupSwipe *rightSwipe = [WCRAFGroupSwipe controllerForTable:table create:YES];
    __weak UITableView *weakSwipeTable = table;
    rightSwipe.resolve = ^WCRAFGroupSwipeAction *(UITableViewCell *cell) {
        UITableView *table = weakSwipeTable;
        WCRGroupingSessionListViewController *owner = WCRGroupControllerForTable(table);
        NSIndexPath *path = [table indexPathForCell:cell];
        if (!owner || !path) return nil;
        WCRBindCanonicalHomeRow(cell, owner, table, path);
        NSString *username = nil;
        WCRRightActionKind kind = WCRActionKindForCell(cell, NULL, NULL, NULL, NULL, &username);
        if (username.length == 0 || !WCRIsInCustomGroup(username) ||
            (kind != WCRRightActionMute && kind != WCRRightActionRemind &&
             kind != WCRRightActionPending && kind != WCRRightActionUnknown)) return nil;
        WCRAFAccountContext *context = objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
        if (![WCRAFStore() isCurrentContext:context]) return nil;
        WCRAFGroupSwipeAction *action = [WCRAFGroupSwipeAction new];
        action.title = WCRTitleForActionKind(kind);
        action.color = WCRColorForActionKind(kind);
        action.identity = @{@"username": username, @"context": context, @"kind": @(kind)};
        return action;
    };
    rightSwipe.validate = ^BOOL(UITableViewCell *cell, id identity, BOOL resolveAgain) {
        if (![identity isKindOfClass:NSDictionary.class]) return NO;
        NSString *username = identity[@"username"];
        WCRAFAccountContext *context = identity[@"context"];
        WCRRightActionKind expected = [identity[@"kind"] integerValue];
        if (username.length == 0 || ![WCRAFStore() isCurrentContext:context] ||
            !WCRIsInCustomGroup(username)) return NO;
        if (!resolveAgain) {
            return objc_getAssociatedObject(cell, kWCRCanonicalAccountKey) == context &&
                [objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey) isEqualToString:username];
        }
        UITableView *table = WCRTableForCell(cell);
        WCRGroupingSessionListViewController *owner = WCRGroupControllerForTable(table);
        NSIndexPath *path = [table indexPathForCell:cell];
        if (!owner || !path) return NO;
        WCRBindCanonicalHomeRow(cell, owner, table, path);
        NSString *currentName = nil;
        WCRRightActionKind current = WCRActionKindForCell(cell, NULL, NULL, NULL, NULL, &currentName);
        return [currentName isEqualToString:username] && current == expected &&
            objc_getAssociatedObject(cell, kWCRCanonicalAccountKey) == context;
    };
    rightSwipe.nativeMenuVisible = ^BOOL(UITableViewCell *cell) {
        return WCRWeChatLeftSwipeMenuVisible(cell);
    };
    rightSwipe.rowColor = ^UIColor *(UITableViewCell *cell) {
        return WCRSwipeBackground(cell);
    };
    rightSwipe.perform = ^(UITableViewCell *cell, WCRAFGroupSwipeAction *action) {
        NSDictionary *identity = action.identity;
        NSString *username = identity[@"username"];
        WCRAFAccountContext *context = identity[@"context"];
        WCRRightActionKind kind = [identity[@"kind"] integerValue];
        if (![WCRAFStore() isCurrentContext:context] || !WCRIsInCustomGroup(username)) return;
        if (kind == WCRRightActionUnknown) {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"消息提醒"
                message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSNumber *target in @[@NO, @YES]) {
                BOOL muted = target.boolValue;
                [sheet addAction:[UIAlertAction actionWithTitle:muted ? @"开启免打扰" : @"开启提醒"
                    style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *selected) {
                    if (![WCRAFStore() isCurrentContext:context]) return;
                    WCRInvalidateSendAcknowledgments(username, context);
                    WCRSetNativeMuted(username, muted, context, ^(__unused BOOL success, NSString *failure) {
                        if (failure.length) WCRReminderFailure(failure);
                    });
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            UIPopoverPresentationController *popover = sheet.popoverPresentationController;
            popover.sourceView = cell;
            popover.sourceRect = cell.bounds;
            [WCRPresenterForHost(WCRGroupControllerForTable(WCRTableForCell(cell)))
                presentViewController:sheet animated:YES completion:nil];
            return;
        }
        if (kind != WCRRightActionMute && kind != WCRRightActionRemind) return;
        WCRInvalidateSendAcknowledgments(username, context);
        WCRSetNativeMuted(username, kind == WCRRightActionMute, context,
            ^(__unused BOOL success, NSString *failure) {
            if (failure.length) WCRReminderFailure(failure);
        });
    };
    id delegate = table.delegate;
    id dataSource = table.dataSource;
    BOOL leading = WCRInstallGroupLeadingSwipeForClass(object_getClass(controller));
    if (delegate != controller) {
        leading = WCRInstallGroupLeadingSwipeForClass(object_getClass(delegate)) && leading;
    }
    BOOL canEdit = WCRInstallGroupCanEditForClass(object_getClass(dataSource));
    if (gWCRGroupSwipeDiagnostics && gWCRGroupSwipeDiagnosticCount < 48) {
        WCRGroupSwipeTrace(@"configure", [NSString stringWithFormat:
            @"table=%@ delegate=%@ source=%@ leading=%d canEdit=%d",
            WCRClassName(table), WCRClassName(delegate), WCRClassName(dataSource),
            leading, canEdit]);
    }
    if (!leading || !canEdit || !delegate || !dataSource) return;

    // UITableView caches optional callbacks when its delegates are assigned.
    // Reassign once per delegate pair after installing the missing selectors.
    NSArray *pair = @[[NSValue valueWithNonretainedObject:delegate],
                     [NSValue valueWithNonretainedObject:dataSource]];
    if ([objc_getAssociatedObject(table, kWCRGroupSwipeDelegatesKey) isEqual:pair]) return;
    objc_setAssociatedObject(table, kWCRGroupSwipeDelegatesKey, pair, OBJC_ASSOCIATION_COPY_NONATOMIC);
    __weak UITableView *weakTable = table;
    __weak id weakDelegate = delegate;
    __weak id weakDataSource = dataSource;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *liveTable = weakTable;
        id liveDelegate = weakDelegate;
        id liveDataSource = weakDataSource;
        if (!liveTable || liveTable.delegate != liveDelegate ||
            liveTable.dataSource != liveDataSource ||
            ![objc_getAssociatedObject(liveTable, kWCRGroupSwipeDelegatesKey) isEqual:pair]) return;
        liveTable.delegate = nil;
        liveTable.dataSource = nil;
        liveTable.dataSource = liveDataSource;
        liveTable.delegate = liveDelegate;
    });
}

static void hook_addMsg(id self, SEL cmd, id username, id wrap) {
    WCRAFOutgoingTicket *ticket = nil;
    @try { ticket = WCRStageLocalSend(username, wrap); }
    @catch (__unused NSException *exception) { }
    if (orig_addMsg) orig_addMsg(self, cmd, username, wrap);
    @try {
        if (ticket) {
            [WCROutgoingLedger() bindLocalID:WCRMessageID(wrap, @"m_uiMesLocalID") ticket:ticket];
            WCRQueueSendAcknowledgment(username, wrap);
        }
    } @catch (__unused NSException *exception) { }
}

static void hook_sessionAddMsg(id self, SEL cmd, id username, id wrap) {
    if (orig_sessionAddMsg) orig_sessionAddMsg(self, cmd, username, wrap);
    @try {
        WCRQueueSendAcknowledgment(username, wrap);
        WCRQueueReminderObservation(username, [WCRAFStore() currentContext]);
    }
    @catch (__unused NSException *exception) { }
}

static void hook_sessionModMsg(id self, SEL cmd, id username, id wrap) {
    if (orig_sessionModMsg) orig_sessionModMsg(self, cmd, username, wrap);
    @try {
        WCRQueueSendAcknowledgment(username, wrap);
        WCRQueueReminderObservation(username, [WCRAFStore() currentContext]);
    }
    @catch (__unused NSException *exception) { }
}

static UITableViewCell *hook_groupCell(id self, SEL cmd, UITableView *table, NSIndexPath *path) {
    UITableViewCell *cell = orig_groupCell ? orig_groupCell(self, cmd, table, path) : nil;
    @try {
        if (WCRIsGroupingSessionListController(self) && table) {
            WCRAFGroupSwipe *rightSwipe = [WCRAFGroupSwipe controllerForTable:table create:NO];
            if (rightSwipe.cell == cell) [rightSwipe reset];
            WCRConfigureGroupingSwipe(table, self);
            if (cell) WCRBindCanonicalHomeRow(cell, self, table, path);
        }
    } @catch (__unused NSException *exception) {
        WCRHardResetCellVisual(cell, YES);
        WCRClearCanonicalRowBinding(cell);
    }
    return cell;
}

static UISwipeActionsConfiguration *hook_groupLeadingSwipe(
    id self, SEL cmd, UITableView *table, NSIndexPath *path) {
    IMP original = WCRGroupRowOriginal(gWCRGroupLeadingSwipeOriginals, self);
    WCRGroupingSessionListViewController *controller =
        WCRGroupControllerForTable(table);
    WCRGroupSwipeTrace(@"leading", controller ? @"known-group=YES" : @"known-group=NO");
    if (!controller) {
        return original ?
            ((UISwipeActionsConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *))original)(
                self, cmd, table, path) : nil;
    }
    // Recognized grouped rows use WCRAFGroupSwipe's bounded transparent
    // viewport. Do not let UIKit create its rounded gray action container.
    WCRConfigureGroupingSwipe(table, controller);
    return nil;
}

static void hook_groupDisappear(id self, SEL cmd, BOOL animated) {
    [WCRAFGroupSwipe resetAll];
    WCRResetVisibleSwipeVisuals();
    if (orig_groupDisappear) orig_groupDisappear(self, cmd, animated);
}

static void hook_groupAppear(id self, SEL cmd, BOOL animated) {
    if (orig_groupAppear) orig_groupAppear(self, cmd, animated);
    @try {
        gWCRGroupSwipeDiagnostics = [NSUserDefaults.standardUserDefaults
            boolForKey:@"WCRAFGroupSwipeDiagnostics"];
        WCRGroupSwipeTrace(@"appear", kWCRAFVersion);
        WCRConfigureGroupingSwipe([(WCRGroupingSessionListViewController *)self tableView], self);
    } @catch (__unused NSException *exception) { }
}

static void hook_homeSelection(id self, SEL cmd, UITableView *table, NSIndexPath *path) {
    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    WCRAFAccountContext *context = objc_getAssociatedObject(cell, kWCRCanonicalAccountKey);
    NSString *username = nil;
    @try {
        if (WCRIsActiveFrontHomeTable(table) && !WCRBool(cell, kWCROpenKey) &&
            !WCRBool(cell, kWCRTrackingKey)) {
            id session = WCRSessionForCell(cell, NULL, NULL, NULL);
            WCRConversationFromCandidate(session, NULL, &username, NULL);
        }
    } @catch (__unused NSException *exception) { username = nil; }
    if (orig_homeSelection) orig_homeSelection(self, cmd, table, path);
    if (username.length == 0 || !context) return;
    NSString *name = [username copy];
    void (^opened)(void) = ^{
        if ([WCRAFStore() isCurrentContext:context] &&
            [WCRCurrentChatUsername() isEqualToString:name]) {
            [WCRAFStore() markHomeConversationOpened:name context:context];
        }
    };
    id<UIViewControllerTransitionCoordinator> transition = WCRTopVC().transitionCoordinator;
    if (transition) {
        [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> result) {
            if (!result.isCancelled) opened();
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), opened);
    }
}

static BOOL (*orig_configExcludeUnread)(id, SEL) = NULL;
static BOOL (*orig_shouldExclude)(id, SEL, id) = NULL;
static void (*orig_settingsBuildBasicSection)(id, SEL) = NULL;
static void (*orig_activeViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*orig_activeViewWillDisappear)(id, SEL, BOOL) = NULL;
static void (*orig_groupingWillDisplay)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *) = NULL;
static void (*orig_cellPrepareForReuse)(id, SEL) = NULL;
static void (*orig_cellDidMoveToWindow)(id, SEL) = NULL;

static BOOL gWCRHookConfig = NO;
static BOOL gWCRHookProvider = NO;
static BOOL gWCRHookHome = NO;
static BOOL gWCRHookHomeDisappear = NO;
static BOOL gWCRHookWillDisplay = NO;
static BOOL gWCRHookCellReuse = NO;
static BOOL gWCRHookCellDidMove = NO;
static BOOL gWCRHookSettings = NO; // optional, not required for allInstalled

// > 0 while WCRefine's group-management page builds its basic section. The
// config getter then returns the user's real value so the switch UI is honest.
static NSInteger gWCRSettingsRealValueDepth = 0;

// The user's real "不收纳非免打扰未读" value, bypassing our getter override.
static BOOL WCRRealExcludeUnreadEnabled(void) {
    Class configClass = NSClassFromString(@"WCRefineConfig");
    if (!configClass ||
        ![configClass respondsToSelector:@selector(shared)]) {
        return NO;
    }

    WCRefineConfig *config = [configClass shared];
    if (!config) return NO;

    SEL getter = @selector(homeGroupingExcludeUnreadEnabled);

    if (orig_configExcludeUnread) {
        return orig_configExcludeUnread(config, getter);
    }

    // Config hook not installed: the getter is still WCRefine's own.
    if ([config respondsToSelector:getter]) {
        return config.homeGroupingExcludeUnreadEnabled;
    }
    return NO;
}

// The real switch still controls WCRefine's unread policy.
// - Real value ON  -> return ON (WCRefine behaves exactly as configured).
// - Real value OFF -> enable the predicate for message activity as well as Held
//   sessions, including the first new message when there are no Held entries.
// - While WCRefine's settings page is building, always return the real value.
static BOOL hook_configExcludeUnread(id self, SEL _cmd) {
    BOOL real =
        orig_configExcludeUnread ?
            orig_configExcludeUnread(self, _cmd) :
            NO;

    if (gWCRSettingsRealValueDepth > 0) return real;
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    BOOL activityEnabled = context && [WCRAFStore() enableMessageActivityForContext:context];
    return real || activityEnabled || WCRHasAnyHeld();
}

// Query only (state writes are deferred via WCRScheduleHoldExpiry):
// - Unread/temporary friend or chat-room message -> keep on home.
// - Held + still in a custom group + not expired -> keep on home.
// - Everything else -> WCRefine's own decision, but only when the user's real
//   switch is ON. With the real switch OFF nothing else is ever excluded,
//   even though the getter is temporarily ON for Held sessions.
static BOOL hook_shouldExclude(id self, SEL _cmd, id session) {
    NSString *username =
        [(WCRefineGroupDataProvider *)self
            usernameForNativeObject:session];

    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (WCRIsMessageActiveSession(session, username, context)) {
        [WCRAFStore() cancelExpiry:username context:context];
        if ([WCRAFStore() isCurrentContext:context]) return YES;
    }
    if (context && username.length > 0 && !WCRIsSyntheticGroupEntryUsername(username) &&
        WCRIsInCustomGroup(username)) {
        id native = [(WCRefineGroupDataProvider *)self nativeSessionFromObject:session] ?: session;
        NSUInteger scope = [(WCRefineGroupDataProvider *)self groupScopeForNativeSession:native];
        if ((scope == 1 || scope == 2) && WCREffectiveMuted(native, username, context) == 1) return NO;
    }
    if (username.length > 0 && context &&
        [WCRAFStore() isHeld:username context:context] &&
        WCRIsInCustomGroup(username)) {
        NSTimeInterval lastMessageTime = WCRSessionLastMessageTime(session);
        if (![WCRAFStore() isExpired:username context:context lastMessageTime:lastMessageTime]) {
            [WCRAFStore() cancelExpiry:username context:context];
            if ([WCRAFStore() isCurrentContext:context]) return YES;
        } else {
            WCRScheduleHoldExpiry(username, context, lastMessageTime);
        }
    }

    // Explicit return must override the host's old unread fallback too.
    // It changes only projection, never the unread count or group membership.
    if (username.length > 0 && !WCRIsSyntheticGroupEntryUsername(username) &&
        WCRIsInCustomGroup(username) &&
        [WCRAFStore() isMessageReturnSuppressed:username context:context
            lastMessageTime:WCRSessionLastMessageTime(session)]) return NO;

    if (!WCRRealExcludeUnreadEnabled()) {
        return NO;
    }

    return orig_shouldExclude ?
        orig_shouldExclude(self, _cmd, session) :
        NO;
}

static void hook_settingsBuildBasicSection(id self, SEL _cmd) {
    gWCRSettingsRealValueDepth++;
    @try {
        if (orig_settingsBuildBasicSection) {
            orig_settingsBuildBasicSection(self, _cmd);
        }
    } @finally {
        gWCRSettingsRealValueDepth--;
    }
}

static void hook_activeViewDidAppear(id self,
                                     SEL _cmd,
                                     BOOL animated) {
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    if (context) [WCRAFStore() enableMessageActivityForContext:context];
    if (orig_activeViewDidAppear) {
        orig_activeViewDidAppear(self, _cmd, animated);
    }
    if ([self isKindOfClass:NSClassFromString(@"NewMainFrameViewController")] &&
        [self isViewLoaded] && [self view].window) {
        gWCRAppearedHomeController = self;
    }

    WCRPruneStaleActiveFrontState();
    // The original host owns discovery/refresh. Only reconcile tracked rows
    // here so a fresh cached host snapshot cannot delay an observed read return.
    WCRReconcileTrackedActivity([WCRAFStore() currentContext]);
}

static void hook_activeViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    WCRCancelReturnAnimation();
    WCRResetVisibleSwipeVisuals();
    if (gWCRAppearedHomeController == self) gWCRAppearedHomeController = nil;
    if (orig_activeViewWillDisappear) orig_activeViewWillDisappear(self, _cmd, animated);
}

static void hook_groupingWillDisplay(
    id self,
    SEL _cmd,
    UITableView *tableView,
    UITableViewCell *cell,
    NSIndexPath *indexPath) {

    if (orig_groupingWillDisplay) {
        orig_groupingWillDisplay(self, _cmd, tableView, cell, indexPath);
    }

    Class homeClass = NSClassFromString(@"NewMainFrameViewController");
    if (!homeClass || ![self isKindOfClass:homeClass]) return;
    if (!WCRIsActiveFrontHomeTable(tableView)) return;

    WCRBindCanonicalHomeRow(cell,
                            (NewMainFrameViewController *)self,
                            tableView,
                            indexPath);

    // Attach/reconcile only after WCRefine has given us the canonical identity.
    WCRAttachToCell(cell);
}

static void hook_cellPrepareForReuse(id self, SEL _cmd) {
    if ([self isKindOfClass:[UITableViewCell class]]) {
        // Restore before native reuse configures its own subview visibility.
        WCRHardResetCellVisual((UITableViewCell *)self, YES);
        WCRClearCanonicalRowBinding((UITableViewCell *)self);
    }
    if (orig_cellPrepareForReuse) {
        orig_cellPrepareForReuse(self, _cmd);
    }
}

static void hook_cellDidMoveToWindow(id self, SEL _cmd) {
    if (orig_cellDidMoveToWindow) {
        orig_cellDidMoveToWindow(self, _cmd);
    }

    if (![self isKindOfClass:[UITableViewCell class]]) return;
    UITableViewCell *cell = (UITableViewCell *)self;
    if (!cell.window) {
        WCRHardResetCellVisual(cell, NO);
        return;
    }

    // UIKit invokes didMoveToWindow on the main thread. Avoid scheduling a
    // second main-queue block for every visible/reused cell.
    WCRAttachToCell(cell);
}

static BOOL WCRInstallInstanceHook(Class cls,
                                   SEL sel,
                                   IMP replacement,
                                   IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method resolved = class_getInstanceMethod(cls, sel);
    if (!resolved) return NO;

    IMP current = method_getImplementation(resolved);
    if (current == replacement) {
        return YES;
    }

    const char *types = method_getTypeEncoding(resolved);

    // If the method is inherited, add an override to this exact class rather
    // than mutating the superclass implementation globally.
    BOOL added =
        class_addMethod(cls, sel, replacement, types);

    if (added) {
        if (originalOut && !*originalOut) {
            *originalOut = current;
        }
        return YES;
    }

    IMP previous =
        class_replaceMethod(cls,
                            sel,
                            replacement,
                            types);

    if (originalOut && !*originalOut) {
        *originalOut = previous ? previous : current;
    }

    return YES;
}

static BOOL WCRInstallCheckedHook(Class cls, NSString *name, char result, const char *arguments,
                                  IMP replacement, IMP *original) {
    SEL selector = NSSelectorFromString(name);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    NSUInteger count = strlen(arguments);
    if (signature.numberOfArguments != count + 2 || signature.methodReturnType[0] != result) return NO;
    for (NSUInteger i = 0; i < count; i++) {
        char actual = [signature getArgumentTypeAtIndex:i + 2][0];
        if (actual != arguments[i] && !(arguments[i] == 'B' && actual == 'c')) return NO;
    }
    return WCRInstallInstanceHook(cls, selector, replacement, original);
}

static void WCRTryInstallBusinessHooks(NSUInteger attemptsRemaining) {
    Class config =
        NSClassFromString(@"WCRefineConfig");
    Class provider =
        NSClassFromString(@"WCRefineGroupDataProvider");
    Class settingsController =
        NSClassFromString(@"WCRefineGroupManagementViewController");
    Class mainFrame =
        NSClassFromString(@"NewMainFrameViewController");
    Class mainFrameCell =
        NSClassFromString(@"NewMainFrameCell");

    if (!gWCRHookConfig && config) {
        gWCRHookConfig =
            WCRInstallInstanceHook(
                config,
                @selector(homeGroupingExcludeUnreadEnabled),
                (IMP)hook_configExcludeUnread,
                (IMP *)&orig_configExcludeUnread);
    }

    if (!gWCRHookProvider && provider) {
        gWCRHookProvider =
            WCRInstallInstanceHook(
                provider,
                @selector(shouldExcludeNativeSessionFromGroupingForUnreadPolicy:),
                (IMP)hook_shouldExclude,
                (IMP *)&orig_shouldExclude);
    }

    // Optional: only makes WCRefine's settings switch show the real value.
    if (!gWCRHookSettings && settingsController) {
        gWCRHookSettings =
            WCRInstallInstanceHook(
                settingsController,
                @selector(buildBasicSection),
                (IMP)hook_settingsBuildBasicSection,
                (IMP *)&orig_settingsBuildBasicSection);
    }

    if (!gWCRHookHome && mainFrame) {
        gWCRHookHome =
            WCRInstallInstanceHook(
                mainFrame,
                @selector(viewDidAppear:),
                (IMP)hook_activeViewDidAppear,
                (IMP *)&orig_activeViewDidAppear);
    }

    if (!gWCRHookHomeDisappear && mainFrame) {
        gWCRHookHomeDisappear = WCRInstallInstanceHook(mainFrame,
            @selector(viewWillDisappear:), (IMP)hook_activeViewWillDisappear,
            (IMP *)&orig_activeViewWillDisappear);
    }

    if (!gWCRHookWillDisplay && mainFrame) {
        gWCRHookWillDisplay =
            WCRInstallInstanceHook(
                mainFrame,
                @selector(wcrGrouping_tableView:willDisplayCell:forRowAtIndexPath:),
                (IMP)hook_groupingWillDisplay,
                (IMP *)&orig_groupingWillDisplay);
    }

    if (!gWCRHookCellReuse && mainFrameCell) {
        gWCRHookCellReuse =
            WCRInstallInstanceHook(
                mainFrameCell,
                @selector(prepareForReuse),
                (IMP)hook_cellPrepareForReuse,
                (IMP *)&orig_cellPrepareForReuse);
    }

    if (!gWCRHookCellDidMove && mainFrameCell) {
        gWCRHookCellDidMove =
            WCRInstallInstanceHook(
                mainFrameCell,
                @selector(didMoveToWindow),
                (IMP)hook_cellDidMoveToWindow,
                (IMP *)&orig_cellDidMoveToWindow);
    }

    if (!orig_addMsg) WCRInstallCheckedHook(NSClassFromString(@"CMessageMgr"),
        @"AddMsg:MsgWrap:", 'v', "@@", (IMP)hook_addMsg, (IMP *)&orig_addMsg);
    Class sessionManager = NSClassFromString(@"MMNewSessionMgr");
    if (!orig_sessionAddMsg) WCRInstallCheckedHook(sessionManager,
        @"OnAddMsg:MsgWrap:", 'v', "@@", (IMP)hook_sessionAddMsg, (IMP *)&orig_sessionAddMsg);
    if (!orig_sessionModMsg) WCRInstallCheckedHook(sessionManager,
        @"OnModMsg:MsgWrap:", 'v', "@@", (IMP)hook_sessionModMsg, (IMP *)&orig_sessionModMsg);
    Class groupList = NSClassFromString(@"WCRGroupingSessionListViewController");
    if (!orig_groupCell) WCRInstallCheckedHook(groupList,
        @"tableView:cellForRowAtIndexPath:", '@', "@@", (IMP)hook_groupCell, (IMP *)&orig_groupCell);
    if (!gWCRHookGroupLeadingSwipe && groupList) {
        gWCRHookGroupLeadingSwipe =
            WCRInstallGroupLeadingSwipeForClass(groupList);
    }
    if (!gWCRHookGroupCanEdit && groupList) {
        gWCRHookGroupCanEdit = WCRInstallGroupCanEditForClass(groupList);
    }
    if (!orig_groupCellPanShouldBegin) WCRInstallCheckedHook(
        NSClassFromString(@"MMBaseMultiMenuTableViewCell"),
        @"gestureRecognizerShouldBegin:", 'B', "@",
        (IMP)hook_groupCellPanShouldBegin, (IMP *)&orig_groupCellPanShouldBegin);
    if (!orig_groupAppear) WCRInstallCheckedHook(groupList,
        @"viewDidAppear:", 'v', "B", (IMP)hook_groupAppear, (IMP *)&orig_groupAppear);
    if (!orig_groupDisappear) WCRInstallCheckedHook(groupList,
        @"viewWillDisappear:", 'v', "B", (IMP)hook_groupDisappear, (IMP *)&orig_groupDisappear);
    if (!orig_homeSelection) WCRInstallCheckedHook(mainFrame,
        @"wcrGrouping_tableView:didSelectRowAtIndexPath:", 'v', "@@",
        (IMP)hook_homeSelection, (IMP *)&orig_homeSelection);

    BOOL allInstalled =
        gWCRHookConfig &&
        gWCRHookProvider &&
        gWCRHookHome &&
        gWCRHookHomeDisappear &&
        gWCRHookWillDisplay &&
        gWCRHookCellReuse &&
        gWCRHookCellDidMove && orig_addMsg && orig_sessionAddMsg && orig_sessionModMsg &&
        orig_groupCell && gWCRHookGroupLeadingSwipe && gWCRHookGroupCanEdit &&
        orig_groupCellPanShouldBegin && orig_groupAppear && orig_groupDisappear &&
        orig_homeSelection;

    if (allInstalled) {
        WCRAF_LOG(@"business hooks installed config=1 provider=1 home=1 disappear=1 willDisplay=1 reuse=1 didMove=1 settings=%d",
                  gWCRHookSettings);
        WCRAFAccountContext *context = [WCRAFStore() currentContext];
        if (context) [WCRAFStore() enableMessageActivityForContext:context];
        WCRPruneStaleActiveFrontState();
        WCRRefreshHomeGlobal(@"active_front_hooks_installed", [WCRAFStore() currentContext]);
        return;
    }

    if (attemptsRemaining == 0) {
        WCRAF_LOG(@"business hooks incomplete config=%d provider=%d home=%d disappear=%d willDisplay=%d reuse=%d didMove=%d settings=%d",
                  gWCRHookConfig,
                  gWCRHookProvider,
                  gWCRHookHome,
                  gWCRHookHomeDisappear,
                  gWCRHookWillDisplay,
                  gWCRHookCellReuse,
                  gWCRHookCellDidMove,
                  gWCRHookSettings);
        return;
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.50 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            WCRTryInstallBusinessHooks(attemptsRemaining - 1);
        });
}

#pragma mark - Scan

static BOOL WCRScan(void) {
    UITableView *tableView = WCRMainTable();
    if (!tableView) return NO;

    NewMainFrameViewController *host = WCRHomeControllerForTable(tableView);
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (!WCRIsMainFrameCell(cell)) continue;
        // Initial visible rows may predate installation of willDisplay hooks.
        NSIndexPath *indexPath = [tableView indexPathForCell:cell];
        WCRBindCanonicalHomeRow(cell, host, tableView, indexPath);
        WCRAttachToCell(cell);
    }
    return YES;
}

static void WCRTryInitialScan(NSUInteger remaining) {
    if (remaining == 0) return;

    if (WCRScan()) return;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.50 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            WCRTryInitialScan(remaining - 1);
        });
}

__attribute__((constructor))
static void WCRRightGroupUIInit(void) {
    @autoreleasepool {
        WCRAF_LOG(@"dylib loaded; starting v%@", kWCRAFVersion);

        static id groupChangeObserver __attribute__((unused));
        groupChangeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:kWCRHomeGroupsDidChangeNotification object:nil queue:nil
            usingBlock:^(__unused NSNotification *notification) {
            WCRInvalidateGroupIndex();
            WCRAFAccountContext *context = [WCRAFStore() currentContext];
            if (context) [WCRAFStore() cancelPendingForContext:context];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gWCRReturnAnimationContext &&
                    ![WCRAFStore() isCurrentContext:gWCRReturnAnimationContext]) {
                    WCRCancelReturnAnimation();
                }
            });
        }];

        static id resignObserver __attribute__((unused));
        resignObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillResignActiveNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *notification) {
            [WCRReminderCoordinator() cancelAll];
            WCRCancelReturnAnimation();
            WCRResetVisibleSwipeVisuals();
            [WCRAFGroupSwipe resetAll];
        }];
        static id activeObserver __attribute__((unused));
        activeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *notification) {
            NewMainFrameViewController *home = WCRActivityHomeController();
            WCRAFAccountContext *context = [WCRAFStore() currentContext];
            if (home && context) {
                [WCRAFStore() enableMessageActivityForContext:context];
                WCRReconcileTrackedActivity(context);
            }
        }];

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(3.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                // Readiness probe only: stop as soon as the home table exists.
                // Runtime hooks cover cells created after startup.
                WCRTryInitialScan(10);
            });

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(4.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                // Preserve the original ~20 second compatibility window while
                // halving the retry frequency.
                WCRTryInstallBusinessHooks(40);
            });

    }
}
