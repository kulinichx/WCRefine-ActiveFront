// ActiveFront.RIGHT_v1_9_3_RELIABILITY_AND_OTHER_LAYOUT_FIX.m
// WCRefine ActiveFront - v1.9.3 reliability fix built on the v1.9.2 stable state machine.
// Fixes: late/reused home-row pan attachment, live-session fallback, and final-pass "其它" nickname layout.
// ActiveFront 分组/保持/回组 state semantics remain unchanged from v1.9.2.
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
// existing group manager/provider APIs and maintains independent Surfaced/Held
// projection state.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdarg.h>

static const CGFloat kWCRActionWidth = 82.0;

static const void *kWCRPanKey          = &kWCRPanKey;
static const void *kWCRActionViewKey   = &kWCRActionViewKey;
static const void *kWCRButtonKey       = &kWCRButtonKey;
static const void *kWCROpenKey         = &kWCROpenKey;
static const void *kWCRTrackingKey     = &kWCRTrackingKey;
static const void *kWCRStartOffsetKey  = &kWCRStartOffsetKey;
static const void *kWCRBaseTransformKey = &kWCRBaseTransformKey;
static const void *kWCRBoundUsernameKey = &kWCRBoundUsernameKey;
static const void *kWCRCanonicalKnownKey = &kWCRCanonicalKnownKey;
static const void *kWCRCanonicalSessionKey = &kWCRCanonicalSessionKey;
static const void *kWCRCanonicalUsernameKey = &kWCRCanonicalUsernameKey;
static const void *kWCRCanonicalScopeKey = &kWCRCanonicalScopeKey;
static const void *kWCRDebugLongPressKey = &kWCRDebugLongPressKey;
static const void *kWCRNativeCloseLatchKey = &kWCRNativeCloseLatchKey;

static BOOL gWCRReadyShown = NO;

static NSString * const kWCRAFVersion = @"1.9.3";
static NSString * const kWCRHomeGroupsDidChangeNotification = @"WCRefineHomeGroupsDidChangeNotification";
static NSString * const kWCRAFHeldUsernamesDefaultsKey = @"com.local.wcrefine.activefront.heldUsernames.v1";
static NSString * const kWCRAFSurfacedUsernamesDefaultsKey = @"com.local.wcrefine.activefront.surfacedUsernames.v1";

static BOOL gWCRBootstrapUnreadFallbackOpen = YES;
static const NSTimeInterval kWCRBootstrapUnreadFallbackSeconds = 12.0;

static void WCRAFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void WCRAFLog(NSString *format, ...) {
    if (format.length == 0) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[WCRefineGroup %@] %@", kWCRAFVersion, message);
}
#define WCRAF_LOG(...) WCRAFLog(__VA_ARGS__)

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
- (id)logicGetSessionAtIndexPath:(NSIndexPath *)indexPath;
- (id)wcrGrouping_logicGetSessionAtIndexPath:(NSIndexPath *)indexPath;
- (id)wcrGrouping_logicGetCellDataAtIndexPath:(NSIndexPath *)indexPath;
- (void)wcrGrouping_tableView:(UITableView *)tableView
              willDisplayCell:(UITableViewCell *)cell
            forRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)wcrGrouping_scheduleRefreshForTrigger:(id)trigger;
- (void)viewDidAppear:(BOOL)animated;
@end

// WCRefine's own group-detail list controller.  Only the special groupId
// "sys_other" is touched by the nickname overlap guard below.
@interface WCRGroupingSessionListViewController : UIViewController
@property(nonatomic, copy) NSString *groupId;
@property(nonatomic, strong) UITableView *tableView;
@end

typedef NS_ENUM(NSInteger, WCRRightActionKind) {
    WCRRightActionNone = 0,
    WCRRightActionGroup,
    WCRRightActionKeep,
    WCRRightActionReturn
};

// Forward declaration: refresh hooks schedule short post-refresh reconciliations
// so rows inserted/reused after the startup scan window still receive ActiveFront.
static void WCRScan(BOOL showReady);

#pragma mark - Helpers

static NSString *WCRClassName(id obj) {
    return obj ? NSStringFromClass([obj class]) : @"<nil>";
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

static UITableViewCell *WCRCellForDescendantView(UIView *view) {
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:[UITableViewCell class]]) {
            return (UITableViewCell *)v;
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


#pragma mark - "其它" group nickname overlap guard (layout only)

static NSString * const kWCROtherGroupingId = @"sys_other";
static const void *kWCROtherNickCollapsedKey = &kWCROtherNickCollapsedKey;

static id WCRSafeValueForKey(id object, NSString *key) {
    if (!object || key.length == 0) return nil;

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIView *WCRFindSubviewByClassNames(UIView *root,
                                          NSSet<NSString *> *names) {
    if (!root || names.count == 0) return nil;

    for (UIView *subview in root.subviews) {
        if ([names containsObject:NSStringFromClass([subview class])]) {
            return subview;
        }

        UIView *nested = WCRFindSubviewByClassNames(subview, names);
        if (nested) return nested;
    }

    return nil;
}

static UIView *WCROtherItemViewForCell(UITableViewCell *cell) {
    if (!cell) return nil;

    id direct = WCRSafeValueForKey(cell, @"m_itemView");
    if ([direct isKindOfClass:[UIView class]]) {
        return (UIView *)direct;
    }

    // Mirror the fallback used by WCRefine itself when m_itemView is not
    // directly readable. This stays local to the group-detail cell.
    NSSet<NSString *> *classNames =
        [NSSet setWithObjects:@"MainFrameItemView", @"FakeMainFrameItemView", nil];

    UIView *root = cell.contentView ?: (UIView *)cell;
    return WCRFindSubviewByClassNames(root, classNames);
}

static UILabel *WCROtherLabelForKey(UIView *itemView, NSString *key) {
    id value = WCRSafeValueForKey(itemView, key);
    if ([value isKindOfClass:[UILabel class]]) {
        return (UILabel *)value;
    }
    return nil;
}

static BOOL WCRLabelHasText(UILabel *label) {
    return label.text.length > 0 || label.attributedText.length > 0;
}

static CGFloat WCRSingleLineNaturalLabelWidth(UILabel *label) {
    if (!label) return 0.0;

    CGFloat width = 0.0;
    NSAttributedString *attributed = label.attributedText;

    if (attributed.length > 0) {
        CGRect rect =
            [attributed boundingRectWithSize:CGSizeMake(CGFLOAT_MAX,
                                                         MAX(ceil(label.bounds.size.height), 64.0))
                                  options:(NSStringDrawingUsesLineFragmentOrigin |
                                           NSStringDrawingUsesFontLeading)
                                  context:nil];
        width = ceil(rect.size.width);
    } else if (label.text.length > 0) {
        UIFont *font = label.font ?: [UIFont systemFontOfSize:17.0];
        width = ceil([label.text sizeWithAttributes:@{NSFontAttributeName: font}].width);
    }

    if (!isfinite(width) || width < 0.0) return 0.0;
    return width + 1.0; // avoid a one-pixel glyph clip at fractional scales
}

static BOOL WCRIsOtherGroupingController(id controller) {
    if (!WCRIsGroupingSessionListController(controller)) return NO;

    NSString *groupId = nil;
    if ([controller respondsToSelector:@selector(groupId)]) {
        groupId = [(WCRGroupingSessionListViewController *)controller groupId];
    }
    if (![groupId isKindOfClass:[NSString class]]) {
        groupId = WCRSafeValueForKey(controller, @"groupId");
    }

    return [groupId isKindOfClass:[NSString class]] &&
           [groupId isEqualToString:kWCROtherGroupingId];
}

static BOOL WCRCellBelongsToOtherGrouping(UITableViewCell *cell) {
    if (!cell) return NO;

    UITableView *tableView = WCRTableForCell(cell);
    if (!tableView) return NO;

    UIViewController *owner = WCRViewControllerForView(tableView);
    if (WCRIsOtherGroupingController(owner)) return YES;

    return WCRIsOtherGroupingController(tableView.delegate);
}

static void WCRAdjustOtherGroupingNicknameCell(UITableViewCell *cell) {
    if (!cell) return;

    UIView *itemView = WCROtherItemViewForCell(cell);
    if (!itemView) return;

    UILabel *nameLabel = WCROtherLabelForKey(itemView, @"m_nameLabel");
    UILabel *nickLabel = WCROtherLabelForKey(itemView, @"m_nickNameLabel");
    UILabel *timeLabel = WCROtherLabelForKey(itemView, @"m_timeLabel");

    // Respect WCRefine's own display-mode / visibility decisions. This guard
    // only resolves a horizontal collision; it never turns a nickname on.
    if (!nameLabel || !nickLabel ||
        nameLabel.hidden || nickLabel.hidden ||
        nameLabel.alpha <= 0.01 || nickLabel.alpha <= 0.01 ||
        !WCRLabelHasText(nameLabel) || !WCRLabelHasText(nickLabel)) {
        return;
    }

    CGRect nameFrame = nameLabel.frame;
    CGRect nickFrame = nickLabel.frame;

    if (CGRectIsNull(nameFrame) || CGRectIsInfinite(nameFrame) ||
        CGRectIsNull(nickFrame) || CGRectIsInfinite(nickFrame) ||
        nameFrame.size.height <= 0.0 || nickFrame.size.height <= 0.0) {
        return;
    }

    // Only touch the same-line nickname mode that can overlap the primary
    // title. Vertical / below-title nickname modes are left exactly native.
    CGFloat rowDelta = fabs(CGRectGetMidY(nameFrame) - CGRectGetMidY(nickFrame));
    CGFloat sameLineTolerance = MAX(8.0,
                                    MIN(nameFrame.size.height, nickFrame.size.height) * 0.55);
    if (rowDelta > sameLineTolerance) return;

    CGFloat nameNaturalWidth = WCRSingleLineNaturalLabelWidth(nameLabel);
    CGFloat nickNaturalWidth = WCRSingleLineNaturalLabelWidth(nickLabel);
    if (nameNaturalWidth <= 0.0 || nickNaturalWidth <= 0.0) return;

    CGFloat startX = CGRectGetMinX(nameFrame);
    CGFloat rightBoundary = CGRectGetWidth(itemView.bounds) - 12.0;

    if (timeLabel && !timeLabel.hidden && timeLabel.alpha > 0.01) {
        CGRect timeFrame = timeLabel.frame;
        if (!CGRectIsNull(timeFrame) && !CGRectIsInfinite(timeFrame) &&
            timeFrame.size.width > 1.0 &&
            CGRectGetMinX(timeFrame) > startX + 24.0) {
            // The date/time label has higher priority: never move or resize it.
            rightBoundary = MIN(rightBoundary, CGRectGetMinX(timeFrame) - 6.0);
        }
    }

    CGFloat availableWidth = floor(rightBoundary - startX);
    if (!isfinite(availableWidth) || availableWidth <= 24.0) return;

    BOOL wasCollapsed =
        [objc_getAssociatedObject(nickLabel, kWCROtherNickCollapsedKey) boolValue];

    // Preserve spacing from a normal native row whenever the frame still
    // contains a sane gap. If this row is already colliding/collapsed, use a
    // conservative four-point gap rather than deriving a negative/huge gap.
    CGFloat currentGap = CGRectGetMinX(nickFrame) - (startX + nameNaturalWidth);
    CGFloat spacing = (currentGap >= 2.0 && currentGap <= 16.0) ? currentGap : 4.0;

    // Pixel-for-pixel no-op for ordinary short rows. `wasCollapsed` bypasses
    // this return once after reuse so a cell previously collapsed for a very
    // long username can self-heal for a shorter row.
    if (!wasCollapsed &&
        startX + nameNaturalWidth + spacing <= CGRectGetMinX(nickFrame)) {
        return;
    }

    nameLabel.numberOfLines = 1;
    nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    nickLabel.numberOfLines = 1;
    nickLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    CGFloat nickFontSize = nickLabel.font ? nickLabel.font.pointSize : 14.0;
    CGFloat minimumUsefulNickWidth =
        MAX(34.0, MIN(nickNaturalWidth, nickFontSize * 2.5));

    if (nameNaturalWidth + spacing + nickNaturalWidth <= availableWidth) {
        // Both fit: keep the primary title intact and place nickname after it.
        nameFrame.size.width = nameNaturalWidth;
        nickFrame.origin.x = startX + nameNaturalWidth + spacing;
        nickFrame.size.width = nickNaturalWidth;
        objc_setAssociatedObject(nickLabel,
                                 kWCROtherNickCollapsedKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (nameNaturalWidth + spacing + minimumUsefulNickWidth <= availableWidth) {
        // Mild shortage: primary title wins; orange nickname gets only the
        // remainder and truncates at its tail.
        nameFrame.size.width = nameNaturalWidth;
        nickFrame.origin.x = startX + nameNaturalWidth + spacing;
        nickFrame.size.width = MAX(0.0, rightBoundary - nickFrame.origin.x);
        objc_setAssociatedObject(nickLabel,
                                 kWCROtherNickCollapsedKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // Very long primary title: give it the whole safe title area and
        // collapse only the auxiliary nickname. Zero width is used instead of
        // changing `hidden`, avoiding a sticky hidden flag across cell reuse.
        nameFrame.size.width = availableWidth;
        nickFrame.origin.x = rightBoundary;
        nickFrame.size.width = 0.0;
        objc_setAssociatedObject(nickLabel,
                                 kWCROtherNickCollapsedKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    nameLabel.frame = CGRectIntegral(nameFrame);
    nickLabel.frame = CGRectIntegral(nickFrame);
}

static void WCRAdjustVisibleOtherGroupingNicknameCells(id controller) {
    if (!WCRIsOtherGroupingController(controller)) return;

    UITableView *tableView = nil;
    if ([controller respondsToSelector:@selector(tableView)]) {
        tableView = [(WCRGroupingSessionListViewController *)controller tableView];
    }
    if (![tableView isKindOfClass:[UITableView class]]) {
        tableView = WCRSafeValueForKey(controller, @"tableView");
    }
    if (![tableView isKindOfClass:[UITableView class]]) return;

    for (UITableViewCell *cell in tableView.visibleCells) {
        WCRAdjustOtherGroupingNicknameCell(cell);
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

static void WCRShow(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = WCRTopVC();
        if (!vc) return;

        if ([vc isKindOfClass:[UIAlertController class]] ||
            [vc.presentedViewController isKindOfClass:[UIAlertController class]]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WCRShow(title, message);
            });
            return;
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title
                                                message:message ?: @""
                                         preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];

        [vc presentViewController:alert animated:YES completion:nil];
    });
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

static BOOL WCRHasBaseTransform(UITableViewCell *cell) {
    return cell && objc_getAssociatedObject(cell, kWCRBaseTransformKey) != nil;
}

static void WCRCaptureBaseTransform(UITableViewCell *cell) {
    if (!cell) return;

    NSValue *value =
        [NSValue valueWithCGAffineTransform:cell.contentView.transform];

    objc_setAssociatedObject(cell,
                             kWCRBaseTransformKey,
                             value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGAffineTransform WCRBaseTransform(UITableViewCell *cell) {
    NSValue *value =
        cell ? objc_getAssociatedObject(cell, kWCRBaseTransformKey) : nil;

    if (value) {
        return [value CGAffineTransformValue];
    }

    return cell ? cell.contentView.transform : CGAffineTransformIdentity;
}

static void WCRSetContentOffset(UITableViewCell *cell, CGFloat x) {
    if (!cell) return;

    // Preserve WeChat's own baseline transform. v1.8 used an absolute
    // CGAffineTransformMakeTranslation(), which could erase WeChat's layout
    // transform and leave a row shifted left until the table refreshed.
    CGAffineTransform transform = WCRBaseTransform(cell);
    transform.tx += x;
    cell.contentView.transform = transform;
}

static void WCRLayoutAction(UITableViewCell *cell) {
    if (!cell) return;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button = objc_getAssociatedObject(cell, kWCRButtonKey);

    CGFloat h = CGRectGetHeight(cell.bounds);
    if (h <= 1.0) {
        h = CGRectGetHeight(cell.contentView.bounds);
    }

    actionView.frame = CGRectMake(0.0, 0.0, kWCRActionWidth, h);
    button.frame = actionView.bounds;
}

static void WCRCloseCell(UITableViewCell *cell, BOOL animated) {
    if (!cell) return;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button = objc_getAssociatedObject(cell, kWCRButtonKey);

    WCRSetBool(cell, kWCROpenKey, NO);
    WCRSetBool(cell, kWCRTrackingKey, NO);
    WCRSetFloat(cell, kWCRStartOffsetKey, 0.0);

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

        if (!WCRBool(cell, kWCROpenKey) &&
            !WCRBool(cell, kWCRTrackingKey)) {
            actionView.hidden = YES;
            [button setTitle:@"" forState:UIControlStateNormal];

            // Re-apply the exact WeChat baseline after the spring finishes.
            cell.contentView.transform = WCRBaseTransform(cell);
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

    [cell.contentView.layer removeAllAnimations];
    [actionView.layer removeAllAnimations];

    // If this cell was still carrying one of our offsets, first restore the
    // exact WeChat baseline captured before the right-swipe.
    if (WCRHasBaseTransform(cell)) {
        cell.contentView.transform = WCRBaseTransform(cell);
    }

    actionView.hidden = YES;
    [button setTitle:@"" forState:UIControlStateNormal];

    WCRSetBool(cell, kWCROpenKey, NO);
    WCRSetBool(cell, kWCRTrackingKey, NO);
    WCRSetFloat(cell, kWCRStartOffsetKey, 0.0);

    // The next row/session that occupies this reusable cell must establish a
    // fresh baseline. Keeping a transform captured for the previous row is
    // what caused occasional alignment / overlay artifacts after auto-return.
    objc_setAssociatedObject(cell,
                             kWCRBaseTransformKey,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
    WCRSetFloat(cell, kWCRStartOffsetKey, kWCRActionWidth);

    [UIView animateWithDuration:0.24
                          delay:0.0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.0
                        options:(UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        WCRSetContentOffset(cell, kWCRActionWidth);
    }
                     completion:nil];
}

static void WCRCloseOtherCells(UITableViewCell *exceptCell) {
    UITableView *tableView = WCRTableForCell(exceptCell);
    if (!WCRIsActiveFrontHomeTable(tableView)) return;

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell == exceptCell) continue;
        if (!WCRBool(cell, kWCROpenKey) &&
            !WCRBool(cell, kWCRTrackingKey)) {
            continue;
        }
        WCRCloseCell(cell, YES);
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

static NSObject *WCRAFStateLock(void) {
    static NSObject *lock = nil;
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
            if ([obj isKindOfClass:[NSString class]] &&
                [(NSString *)obj length] > 0) {
                [result addObject:obj];
            }
        }
        return [result copy];
    }
}

static BOOL WCRPersistSetMembership(NSString *key,
                                    NSString *username,
                                    BOOL enabled) {
    if (key.length == 0 || username.length == 0) return NO;

    @synchronized (WCRAFStateLock()) {
        id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
        NSMutableSet<NSString *> *set = [NSMutableSet set];

        if ([stored isKindOfClass:[NSArray class]]) {
            for (id obj in (NSArray *)stored) {
                if ([obj isKindOfClass:[NSString class]] &&
                    [(NSString *)obj length] > 0) {
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

        NSArray<NSString *> *stable =
            [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];

        [[NSUserDefaults standardUserDefaults] setObject:stable forKey:key];
        return YES;
    }
}

static BOOL WCRIsHeld(NSString *username) {
    return username.length > 0 &&
           [WCRStringSetForDefaultsKey(kWCRAFHeldUsernamesDefaultsKey)
               containsObject:username];
}

static BOOL WCRPersistHeld(NSString *username, BOOL held) {
    return WCRPersistSetMembership(kWCRAFHeldUsernamesDefaultsKey,
                                   username,
                                   held);
}

static BOOL WCRIsSurfaced(NSString *username) {
    return username.length > 0 &&
           [WCRStringSetForDefaultsKey(kWCRAFSurfacedUsernamesDefaultsKey)
               containsObject:username];
}

static BOOL WCRPersistSurfaced(NSString *username, BOOL surfaced) {
    return WCRPersistSetMembership(kWCRAFSurfacedUsernamesDefaultsKey,
                                   username,
                                   surfaced);
}

static BOOL WCRHasAnyActiveFrontProjection(void) {
    return WCRStringSetForDefaultsKey(kWCRAFHeldUsernamesDefaultsKey).count > 0 ||
           WCRStringSetForDefaultsKey(kWCRAFSurfacedUsernamesDefaultsKey).count > 0;
}

static NSSet<NSString *> *WCRCustomGroupIdSet(void) {
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

static BOOL WCRSessionUnreadState(id session, BOOL *knownOut) {
    if (knownOut) *knownOut = NO;
    if (!session) return NO;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    id native = provider ? [provider nativeSessionFromObject:session] : nil;
    if (!native) native = session;

    NSArray<NSString *> *keys =
        @[@"m_uUnReadCount", @"m_unReadCount", @"unReadCount"];

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

static void WCRScheduleVisibleHomeReconcile(void) {
    // WCRefine rebuilds its snapshot asynchronously. Reconcile a few times
    // around that mutation instead of relying on the finite startup scan.
    const NSTimeInterval delays[] = {0.05, 0.25, 0.70};
    for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScan(NO);
        });
    }
}

static void WCRRefreshHome(id host, NSString *reason) {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kWCRHomeGroupsDidChangeNotification
                      object:nil];

    if ([host respondsToSelector:@selector(wcrGrouping_scheduleRefreshForTrigger:)]) {
        [(NewMainFrameViewController *)host
            wcrGrouping_scheduleRefreshForTrigger:(reason ?: @"active_front")];
    }

    WCRScheduleVisibleHomeReconcile();
}

static void WCRRefreshHomeDeferred(id host, NSString *reason) {
    __weak id weakHost = host;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCRRefreshHome(weakHost, reason);
    });
}

static void WCRRefreshHomeGlobal(__unused NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kWCRHomeGroupsDidChangeNotification
                          object:nil];
        WCRScheduleVisibleHomeReconcile();
    });
}

static void WCRSetHeld(NSString *username, BOOL held, id host) {
    if (username.length == 0) return;

    BOOL changed = WCRPersistHeld(username, held);

    if (!held) {
        changed = WCRPersistSurfaced(username, NO) || changed;
    }

    WCRAF_LOG(@"%@ %@",
              held ? @"keep" : @"return-to-group",
              username);

    NSString *reason = nil;
    if (held) {
        reason = changed ?
            @"active_front_keep" :
            @"active_front_keep_refresh";
    } else {
        reason = changed ?
            @"active_front_return" :
            @"active_front_return_refresh";
    }

    WCRRefreshHomeDeferred(host, reason);
}

static void WCRPruneStateKeyToGroupedMembers(NSString *key) {
    NSSet<NSString *> *stored = WCRStringSetForDefaultsKey(key);
    if (stored.count == 0) return;

    NSMutableSet<NSString *> *clean =
        [NSMutableSet setWithCapacity:stored.count];

    for (NSString *username in stored) {
        if (WCRIsInCustomGroup(username)) {
            [clean addObject:username];
        }
    }

    if ([clean isEqualToSet:stored]) return;

    @synchronized (WCRAFStateLock()) {
        NSArray<NSString *> *stable =
            [[clean allObjects] sortedArrayUsingSelector:@selector(compare:)];
        [[NSUserDefaults standardUserDefaults] setObject:stable forKey:key];
    }
}

static void WCRPruneStaleActiveFrontState(void) {
    WCRPruneStateKeyToGroupedMembers(kWCRAFHeldUsernamesDefaultsKey);
    WCRPruneStateKeyToGroupedMembers(kWCRAFSurfacedUsernamesDefaultsKey);
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

static BOOL WCRCanonicalRowKnown(UITableViewCell *cell) {
    NSNumber *known =
        cell ? objc_getAssociatedObject(cell, kWCRCanonicalKnownKey) : nil;
    return known.boolValue;
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
}

static BOOL WCRCandidateIsEligibleConversation(id candidate,
                                               WCRefineGroupDataProvider *provider,
                                               id *sessionOut,
                                               NSString **usernameOut,
                                               NSUInteger *scopeOut) {
    if (!candidate || !provider) return NO;

    id native = [provider nativeSessionFromObject:candidate];
    if (!native) native = candidate;

    NSString *username = [provider usernameForNativeObject:native];
    NSUInteger scope = [provider groupScopeForNativeSession:native];

    BOOL eligible =
        [username isKindOfClass:[NSString class]] &&
        username.length > 0 &&
        (scope == 1 || scope == 2);

    if (!eligible) return NO;

    if (sessionOut) *sessionOut = native;
    if (usernameOut) *usernameOut = username;
    if (scopeOut) *scopeOut = scope;
    return YES;
}

static id WCRResolveCurrentHomeSession(NewMainFrameViewController *host,
                                       NSIndexPath *indexPath,
                                       NSString **usernameOut,
                                       NSUInteger *scopeOut,
                                       NSString **sourceOut) {
    if (!host || !indexPath) return nil;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider) return nil;

    id primaryObject = nil;
    if ([host respondsToSelector:@selector(wcrGrouping_logicGetSessionAtIndexPath:)]) {
        primaryObject = [host wcrGrouping_logicGetSessionAtIndexPath:indexPath];
    }

    id primarySession = nil;
    NSString *primaryUsername = nil;
    NSUInteger primaryScope = 0;
    BOOL primaryOK = WCRCandidateIsEligibleConversation(primaryObject,
                                                         provider,
                                                         &primarySession,
                                                         &primaryUsername,
                                                         &primaryScope);

    // WCRefine exposes a second projection-aware accessor for the exact row's
    // cell data. During snapshot rebuilds it can be current when the session
    // accessor is temporarily nil/stale. Canonicalize it through WCRefine's
    // own nativeSessionFromObject: instead of guessing by class/prefix.
    id cellData = nil;
    if ([host respondsToSelector:@selector(wcrGrouping_logicGetCellDataAtIndexPath:)]) {
        cellData = [host wcrGrouping_logicGetCellDataAtIndexPath:indexPath];
    }

    id secondarySession = nil;
    NSString *secondaryUsername = nil;
    NSUInteger secondaryScope = 0;
    BOOL secondaryOK = WCRCandidateIsEligibleConversation(cellData,
                                                           provider,
                                                           &secondarySession,
                                                           &secondaryUsername,
                                                           &secondaryScope);

    // If both are valid but disagree during a projection mutation, prefer the
    // cell-data candidate because it is bound to the row being rendered now.
    if (secondaryOK &&
        (!primaryOK || ![secondaryUsername isEqualToString:primaryUsername])) {
        if (primaryOK && ![secondaryUsername isEqualToString:primaryUsername]) {
            WCRAF_LOG(@"live resolver mismatch index=%ld/%ld session=%@ cellData=%@; prefer cellData",
                      (long)indexPath.section,
                      (long)indexPath.row,
                      primaryUsername,
                      secondaryUsername);
        }
        if (usernameOut) *usernameOut = secondaryUsername;
        if (scopeOut) *scopeOut = secondaryScope;
        if (sourceOut) *sourceOut = @"cellData";
        return secondarySession;
    }

    if (primaryOK) {
        if (usernameOut) *usernameOut = primaryUsername;
        if (scopeOut) *scopeOut = primaryScope;
        if (sourceOut) *sourceOut = @"session";
        return primarySession;
    }

    if (sourceOut) *sourceOut = @"none";
    return nil;
}

static void WCRBindCanonicalHomeRow(UITableViewCell *cell,
                                    NewMainFrameViewController *host,
                                    UITableView *tableView,
                                    NSIndexPath *indexPath) {
    if (!cell || !host || !tableView || !indexPath) return;

    // Resolve from WCRefine's current projection. v1.9.3 keeps the v1.9.2
    // friend/chatroom boundary, but adds WCRefine's exact cell-data resolver as
    // a race-safe fallback while the home snapshot is mutating.
    NSString *username = nil;
    NSUInteger scope = 0;
    NSString *resolverSource = nil;
    id resolvedSession =
        WCRResolveCurrentHomeSession(host,
                                     indexPath,
                                     &username,
                                     &scope,
                                     &resolverSource);
    BOOL eligibleConversation = resolvedSession != nil;

    NSString *oldCanonicalUsername =
        objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey);

    BOOL identityChanged =
        oldCanonicalUsername.length > 0 &&
        (!eligibleConversation ||
         ![oldCanonicalUsername isEqualToString:username]);

    if (identityChanged ||
        (!eligibleConversation &&
         (WCRBool(cell, kWCROpenKey) ||
          WCRBool(cell, kWCRTrackingKey)))) {
        WCRHardResetCellVisual(cell, YES);
    }

    // "known + nil session" means WCRefine classified this row as something
    // other than an eligible friend/chat-room conversation. Such rows fail
    // closed and can never open ActiveFront's right swipe.
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

    WCRAF_LOG(@"canonical row %@ index=%ld/%ld session=%@ user=%@ scope=%lu eligible=%d source=%@",
              WCRClassName(cell),
              (long)indexPath.section,
              (long)indexPath.row,
              WCRClassName(resolvedSession),
              username ?: @"<nil>",
              (unsigned long)scope,
              eligibleConversation,
              resolverSource ?: @"<nil>");
}

static id WCRSessionForCell(UITableViewCell *cell,
                            id *hostOut,
                            UITableView **tableOut,
                            NSIndexPath **indexPathOut) {
    UITableView *tableView = WCRTableForCell(cell);
    if (!WCRIsActiveFrontHomeTable(tableView)) return nil;

    NSIndexPath *indexPath = [tableView indexPathForCell:cell];
    if (!indexPath) return nil;

    NewMainFrameViewController *host =
        WCRHomeControllerForTable(tableView);
    if (!host) return nil;

    // IMPORTANT:
    // A home refresh / incoming unread projection can reorder rows without a
    // reliable willDisplay callback for every visible/reused cell. Resolve the
    // CURRENT row again at gesture/action time. The primary source remains
    // WCRefine's session resolver; v1.9.3 adds WCRefine's own cell-data path as
    // a fallback for snapshot-transition races.
    NSString *username = nil;
    NSUInteger scope = 0;
    NSString *resolverSource = nil;
    id session =
        WCRResolveCurrentHomeSession(host,
                                     indexPath,
                                     &username,
                                     &scope,
                                     &resolverSource);
    BOOL eligibleConversation = session != nil;

    if (!eligibleConversation) {
        // This visible row is a WCRefine group/category/service/official/other
        // row (or otherwise not an eligible friend/chatroom conversation).
        // Clear stale cached identity/action UI and fail closed.
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

        WCRAF_LOG(@"action resolve failed index=%ld/%ld cell=%@ source=%@",
                  (long)indexPath.section,
                  (long)indexPath.row,
                  WCRClassName(cell),
                  resolverSource ?: @"none");
        return nil;
    }

    // Refresh the cache so diagnostics and later reuse checks describe the row
    // that WCRefine currently considers visible here.
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

    if (hostOut) *hostOut = host;
    if (tableOut) *tableOut = tableView;
    if (indexPathOut) *indexPathOut = indexPath;

    return session;
}

static BOOL WCRResolveSessionState(id session,
                                   NSString **usernameOut,
                                   BOOL *groupedOut,
                                   BOOL *heldOut,
                                   BOOL *surfacedOut) {
    WCRefineGroupDataProvider *provider = WCRDataProvider();
    if (!provider || !session) return NO;

    NSString *username = [provider usernameForNativeObject:session];
    if (![username isKindOfClass:[NSString class]] ||
        username.length == 0) {
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
    BOOL held = grouped && WCRIsHeld(username);
    BOOL surfaced = grouped && WCRIsSurfaced(username);

    if (usernameOut) *usernameOut = username;
    if (groupedOut) *groupedOut = grouped;
    if (heldOut) *heldOut = held;
    if (surfacedOut) *surfacedOut = surfaced;

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
    BOOL surfaced = NO;

    if (!WCRResolveSessionState(session,
                                &username,
                                &grouped,
                                &held,
                                &surfaced)) {
        return WCRRightActionNone;
    }

    // Surfaced is intentionally not required for action selection in v1.9.2.
    // Keep it resolved for diagnostics and the existing projection hooks.
    (void)surfaced;

    WCRRightActionKind kind = WCRRightActionNone;

    if (!grouped) {
        NSUInteger scope =
            [WCRDataProvider() groupScopeForNativeSession:session];

        NSArray<WCRefineGroup *> *available =
            WCRAvailableGroupsForScope(scope);

        if (available.count > 0) {
            kind = WCRRightActionGroup;
        }
    } else if (held) {
        kind = WCRRightActionReturn;
    } else {
        // If a grouped friend/chatroom is currently a REAL visible row on the
        // home list, the correct action is always "保持".
        //
        // Do not gate this on our Surfaced flag. WCRefine's own unread
        // exclusion is what makes an unread grouped conversation appear on
        // home. The Surfaced flag is supplemental state and can legitimately
        // be 0 after keep -> return or on later incoming messages.
        kind = WCRRightActionKeep;
    }

    if (hostOut) *hostOut = host;
    if (tableOut) *tableOut = tableView;
    if (indexPathOut) *indexPathOut = indexPath;
    if (sessionOut) *sessionOut = session;
    if (usernameOut) *usernameOut = username;

    return kind;
}


static NSString *WCRUsernameForCell(UITableViewCell *cell) {
    NSString *username = nil;

    (void)WCRActionKindForCell(cell,
                               NULL,
                               NULL,
                               NULL,
                               NULL,
                               &username);

    return username;
}

static void WCRCloseVisibleRightSwipeForUsername(NSString *username) {
    if (username.length == 0) return;

    UITableView *tableView = WCRMainTable();
    if (!tableView) return;

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (!WCRIsMainFrameCell(cell)) continue;

        NSString *cellUsername = WCRUsernameForCell(cell);
        if (![cellUsername isEqualToString:username]) continue;

        // Hide before the provider/table refresh can remove/reuse the row.
        // This prevents a visible “保持/分组/回组” view from travelling with a
        // recycled NewMainFrameCell into another conversation.
        WCRHardResetCellVisual(cell, NO);
    }
}

static NSString *WCRTitleForActionKind(WCRRightActionKind kind) {
    switch (kind) {
        case WCRRightActionGroup:
            return @"分组";
        case WCRRightActionKeep:
            return @"保持";
        case WCRRightActionReturn:
            return @"回组";
        case WCRRightActionNone:
        default:
            return nil;
    }
}

static BOOL WCRPrepareActionForCell(UITableViewCell *cell) {
    if (!cell) return NO;

    UIView *actionView = objc_getAssociatedObject(cell, kWCRActionViewKey);
    UIButton *button = objc_getAssociatedObject(cell, kWCRButtonKey);
    if (!button) return NO;

    WCRRightActionKind kind =
        WCRActionKindForCell(cell, NULL, NULL, NULL, NULL, NULL);

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
    return YES;
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

static void WCRShowNoGroupsAlert(id host) {
    UIViewController *presenter = WCRPresenterForHost(host);
    if (!presenter) return;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"分组"
                                            message:@"当前没有适用于这个会话的分组。"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"好"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    [presenter presentViewController:alert
                            animated:YES
                          completion:nil];
}

static void WCRPresentGroupPicker(id host,
                                  NSString *username,
                                  id session,
                                  UITableView *tableView,
                                  NSIndexPath *indexPath) {
    if (username.length == 0 || !session) return;

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    WCRefineGroupManager *mgr = WCRGroupManager();
    if (!provider || !mgr) return;

    NSUInteger scope = [provider groupScopeForNativeSession:session];
    NSArray<WCRefineGroup *> *groups = WCRAvailableGroupsForScope(scope);

    if (groups.count == 0) {
        WCRShowNoGroupsAlert(host);
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
            // Add destination first. Only after success do we remove any other
            // custom-group membership, avoiding a transient "belongs nowhere"
            // state.
            BOOL ok = [mgr addMember:username toGroup:groupId];
            if (!ok) {
                WCRAF_LOG(@"assign failed %@ -> %@", username, groupId);
                return;
            }

            NSArray<NSString *> *existing =
                [mgr groupIdsContainingMember:username] ?: @[];

            NSSet<NSString *> *customIds = WCRCustomGroupIdSet();

            for (NSString *existingGroupId in existing) {
                if ([customIds containsObject:existingGroupId] &&
                    ![existingGroupId isEqualToString:groupId]) {
                    [mgr removeMember:username
                             fromGroup:existingGroupId];
                }
            }

            WCRPersistHeld(username, NO);

            BOOL unreadKnown = NO;
            BOOL hasUnread =
                WCRSessionUnreadState(session, &unreadKnown);

            WCRPersistSurfaced(username,
                               unreadKnown && hasUnread);

            WCRAF_LOG(@"assigned %@ -> %@", username, groupId);
            WCRRefreshHomeDeferred(host,
                                   @"active_front_assign_group");
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

#pragma mark - Controller


static void WCRShowCanonicalRowDebug(UITableViewCell *cell) {
    if (!cell) return;

    UITableView *tableView = WCRTableForCell(cell);
    NSIndexPath *indexPath =
        tableView ? [tableView indexPathForCell:cell] : nil;
    NewMainFrameViewController *host =
        tableView ? WCRHomeControllerForTable(tableView) : nil;

    id canonicalSession =
        objc_getAssociatedObject(cell, kWCRCanonicalSessionKey);
    NSString *canonicalUsername =
        objc_getAssociatedObject(cell, kWCRCanonicalUsernameKey);
    NSNumber *canonicalScope =
        objc_getAssociatedObject(cell, kWCRCanonicalScopeKey);

    id directSession = nil;
    id cellData = nil;

    if (host && indexPath &&
        [host respondsToSelector:
            @selector(wcrGrouping_logicGetSessionAtIndexPath:)]) {
        directSession =
            [host wcrGrouping_logicGetSessionAtIndexPath:indexPath];
    }

    if (host && indexPath &&
        [host respondsToSelector:
            @selector(wcrGrouping_logicGetCellDataAtIndexPath:)]) {
        cellData =
            [host wcrGrouping_logicGetCellDataAtIndexPath:indexPath];
    }

    WCRefineGroupDataProvider *provider = WCRDataProvider();
    NSString *directUsername =
        (provider && directSession)
            ? [provider usernameForNativeObject:directSession]
            : nil;
    NSUInteger directScope =
        (provider && directSession)
            ? [provider groupScopeForNativeSession:directSession]
            : 0;

    NSString *message =
        [NSString stringWithFormat:
            @"index=%ld/%ld\n"
             "cell=%@\n"
             "table=%@\n"
             "delegate=%@\n"
             "host=%@\n\n"
             "canonicalKnown=%d (cache only; action uses live WCRefineSession)\n"
             "canonicalSession=%@\n"
             "canonicalUser=%@\n"
             "canonicalScope=%@\n\n"
             "WCRefineSession=%@\n"
             "WCRefineUser=%@\n"
             "WCRefineScope=%lu\n"
             "cellData=%@\n\n"
             "grouped=%d held=%d surfaced=%d",
             (long)(indexPath ? indexPath.section : -1),
             (long)(indexPath ? indexPath.row : -1),
             WCRClassName(cell),
             WCRClassName(tableView),
             WCRClassName(tableView.delegate),
             WCRClassName(host),
             WCRCanonicalRowKnown(cell),
             WCRClassName(canonicalSession),
             canonicalUsername ?: @"<nil>",
             canonicalScope ?: @0,
             WCRClassName(directSession),
             directUsername ?: @"<nil>",
             (unsigned long)directScope,
             WCRClassName(cellData),
             canonicalUsername.length > 0
                ? WCRIsInCustomGroup(canonicalUsername) : 0,
             canonicalUsername.length > 0
                ? WCRIsHeld(canonicalUsername) : 0,
             canonicalUsername.length > 0
                ? WCRIsSurfaced(canonicalUsername) : 0];

    UIViewController *presenter = WCRTopVC();
    if (!presenter) return;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"ActiveFront Row Debug"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"复制"
                                 style:UIAlertActionStyleDefault
                               handler:^(__unused UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = message;
        }]];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"关闭"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

@interface WCRRowDebugController : NSObject
+ (instancetype)shared;
- (void)handleDebugTap:(UITapGestureRecognizer *)gesture;
@end

@implementation WCRRowDebugController

+ (instancetype)shared {
    static WCRRowDebugController *controller = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [WCRRowDebugController new];
    });
    return controller;
}

- (void)handleDebugTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    if (![gesture.view isKindOfClass:[UITableViewCell class]]) return;

    WCRShowCanonicalRowDebug((UITableViewCell *)gesture.view);
}

@end

static void WCRAttachDebugGesture(UITableViewCell *cell) {
    if (!cell) return;

    UITapGestureRecognizer *existing =
        objc_getAssociatedObject(cell, kWCRDebugLongPressKey);
    if (existing) return;

    UITapGestureRecognizer *debug =
        [[UITapGestureRecognizer alloc]
            initWithTarget:[WCRRowDebugController shared]
                    action:@selector(handleDebugTap:)];

    // Diagnostic gesture: two-finger double tap.
    // UITapGestureRecognizer supports required touch/tap counts directly,
    // unlike UILongPressGestureRecognizer.
    debug.numberOfTouchesRequired = 2;
    debug.numberOfTapsRequired = 2;
    debug.cancelsTouchesInView = NO;

    [cell addGestureRecognizer:debug];

    objc_setAssociatedObject(cell, kWCRDebugLongPressKey, debug,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface WCRRightSwipeController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
- (void)actionTapped:(UIButton *)sender;
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
    if (!WCRIsMainFrameCell(cell)) return NO;

    UITableView *tableView = WCRTableForCell(cell);
    if (!WCRIsActiveFrontHomeTable(tableView)) return NO;

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

    UITableViewCell *cell = (UITableViewCell *)pan.view;
    if (!WCRIsMainFrameCell(cell)) return;

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

            if (!WCRPrepareActionForCell(cell)) {
                WCRCloseCell(cell, NO);
                break;
            }

            WCRCloseOtherCells(cell);
            WCRLayoutAction(cell);

            BOOL wasOpen = WCRBool(cell, kWCROpenKey);

            // Capture WeChat's actual closed-state transform immediately
            // before our first right-swipe. Never assume identity.
            if (!wasOpen) {
                WCRCaptureBaseTransform(cell);
            }

            CGFloat startOffset = wasOpen ? kWCRActionWidth : 0.0;

            WCRSetFloat(cell, kWCRStartOffsetKey, startOffset);
            WCRSetBool(cell, kWCRTrackingKey, YES);
            actionView.hidden = NO;

            [cell.contentView.layer removeAllAnimations];
            break;
        }

        case UIGestureRecognizerStateChanged: {
            CGFloat x = WCRFloat(cell, kWCRStartOffsetKey) + translation.x;

            if (x < 0.0) {
                x = 0.0;
            }

            // Fixed-width action. Beyond the action width only a small
            // rubber-band movement is permitted.
            if (x > kWCRActionWidth) {
                CGFloat extra = (x - kWCRActionWidth) * 0.16;
                x = kWCRActionWidth + MIN(extra, 12.0);
            }

            WCRSetContentOffset(cell, x);
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGFloat currentX = cell.contentView.transform.tx;
            BOOL cancelled =
                (pan.state == UIGestureRecognizerStateCancelled ||
                 pan.state == UIGestureRecognizerStateFailed);

            BOOL shouldOpen = NO;
            if (!cancelled) {
                shouldOpen =
                    (currentX >= kWCRActionWidth * 0.52) ||
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
                                      indexPath);
            });
            break;
        }

        case WCRRightActionKeep:
            WCRSetHeld(username, YES, host);
            break;

        case WCRRightActionReturn:
            WCRSetHeld(username, NO, host);
            break;

        case WCRRightActionNone:
        default:
            break;
    }
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
    if (!WCRIsMainFrameCell(cell)) return;

    UITableView *tableView = WCRTableForCell(cell);
    if (!WCRIsActiveFrontHomeTable(tableView)) return;

    WCRAttachDebugGesture(cell);

    NSString *currentUsername = WCRUsernameForCell(cell);
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
        [button setTitleColor:[UIColor whiteColor]
                     forState:UIControlStateNormal];
        button.titleLabel.font =
            [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        button.backgroundColor = [UIColor clearColor];

        [button addTarget:[WCRRightSwipeController shared]
                   action:@selector(actionTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        [actionView addSubview:button];

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

    // Seed the baseline only when the cell is clearly not in WeChat's
    // left-swipe state. It will be refreshed again at every new WCRefine
    // right-swipe begin.
    if (!WCRHasBaseTransform(cell) &&
        !WCRBool(cell, kWCROpenKey) &&
        !WCRBool(cell, kWCRTrackingKey) &&
        cell.contentView.transform.tx >= -1.0) {
        WCRCaptureBaseTransform(cell);
    }

    WCRLayoutAction(cell);
    WCRPrepareActionForCell(cell);

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


#pragma mark - "其它" group nickname layout hooks

static UITableViewCell *(*orig_otherGroupCellForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*orig_otherGroupViewDidLayoutSubviews)(id, SEL) = NULL;
static void (*orig_otherMainItemViewLayoutSubviews)(id, SEL) = NULL;
static void (*orig_otherFakeItemViewLayoutSubviews)(id, SEL) = NULL;

static BOOL gWCRHookOtherGroupCellForRow = NO;
static BOOL gWCRHookOtherGroupLayout = NO;
static BOOL gWCRHookOtherMainItemLayout = NO;
static BOOL gWCRHookOtherFakeItemLayout = NO;

static UITableViewCell *hook_otherGroupCellForRow(id self,
                                                   SEL _cmd,
                                                   UITableView *tableView,
                                                   NSIndexPath *indexPath) {
    UITableViewCell *cell =
        orig_otherGroupCellForRow ?
            orig_otherGroupCellForRow(self, _cmd, tableView, indexPath) :
            nil;

    if (cell && WCRIsOtherGroupingController(self)) {
        WCRAdjustOtherGroupingNicknameCell(cell);
    }

    return cell;
}

static void hook_otherGroupViewDidLayoutSubviews(id self, SEL _cmd) {
    if (orig_otherGroupViewDidLayoutSubviews) {
        orig_otherGroupViewDidLayoutSubviews(self, _cmd);
    }

    // Native layout may rewrite label frames after cellForRow. Reconcile the
    // visible sys_other rows only after that pass completes.
    WCRAdjustVisibleOtherGroupingNicknameCells(self);
}

static void WCRAdjustOtherNicknameFromItemView(id itemView) {
    if (![itemView isKindOfClass:[UIView class]]) return;

    UITableViewCell *cell = WCRCellForDescendantView((UIView *)itemView);
    if (!cell || !WCRCellBelongsToOtherGrouping(cell)) return;

    // This runs after MainFrameItemView/FakeMainFrameItemView's own native
    // layout pass, so WCRefine/WeChat cannot immediately overwrite our frames.
    WCRAdjustOtherGroupingNicknameCell(cell);
}

static void hook_otherMainItemViewLayoutSubviews(id self, SEL _cmd) {
    if (orig_otherMainItemViewLayoutSubviews) {
        orig_otherMainItemViewLayoutSubviews(self, _cmd);
    }
    WCRAdjustOtherNicknameFromItemView(self);
}

static void hook_otherFakeItemViewLayoutSubviews(id self, SEL _cmd) {
    if (orig_otherFakeItemViewLayoutSubviews) {
        orig_otherFakeItemViewLayoutSubviews(self, _cmd);
    }
    WCRAdjustOtherNicknameFromItemView(self);
}

#pragma mark - ActiveFront projection runtime hooks

static BOOL (*orig_configExcludeUnread)(id, SEL) = NULL;
static BOOL (*orig_shouldExclude)(id, SEL, id) = NULL;
static void (*orig_noteIncoming)(id, SEL, NSString *) = NULL;
static void (*orig_noteRead)(id, SEL, NSString *) = NULL;
static void (*orig_activeViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*orig_groupingWillDisplay)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *) = NULL;
static void (*orig_cellPrepareForReuse)(id, SEL) = NULL;
static void (*orig_cellDidMoveToWindow)(id, SEL) = NULL;

static BOOL gWCRHookConfig = NO;
static BOOL gWCRHookProvider = NO;
static BOOL gWCRHookIncoming = NO;
static BOOL gWCRHookRead = NO;
static BOOL gWCRHookHome = NO;
static BOOL gWCRHookWillDisplay = NO;
static BOOL gWCRHookCellReuse = NO;
static BOOL gWCRHookCellDidMoveToWindow = NO;
static BOOL gWCRBootstrapCloseScheduled = NO;

static BOOL hook_configExcludeUnread(id self, SEL _cmd) {
    BOOL original =
        orig_configExcludeUnread ?
            orig_configExcludeUnread(self, _cmd) :
            NO;

    return original ||
           gWCRBootstrapUnreadFallbackOpen ||
           WCRHasAnyActiveFrontProjection();
}

static BOOL hook_shouldExclude(id self, SEL _cmd, id session) {
    BOOL originalDecision =
        orig_shouldExclude ?
            orig_shouldExclude(self, _cmd, session) :
            NO;

    NSString *username =
        [(WCRefineGroupDataProvider *)self
            usernameForNativeObject:session];

    if (username.length == 0) {
        return originalDecision;
    }

    if (WCRIsHeld(username) &&
        WCRIsInCustomGroup(username)) {
        return YES;
    }

    if (WCRIsSurfaced(username) &&
        WCRIsInCustomGroup(username)) {
        BOOL unreadKnown = NO;
        BOOL hasUnread =
            WCRSessionUnreadState(session, &unreadKnown);

        if (!unreadKnown || hasUnread) {
            return YES;
        }

        WCRPersistSurfaced(username, NO);
        return NO;
    }

    if (gWCRBootstrapUnreadFallbackOpen &&
        WCRIsInCustomGroup(username)) {
        BOOL unreadKnown = NO;
        BOOL hasUnread =
            WCRSessionUnreadState(session, &unreadKnown);

        if ((unreadKnown && hasUnread) ||
            (!unreadKnown && originalDecision)) {
            WCRPersistSurfaced(username, YES);
            return YES;
        }
    }

    return originalDecision;
}

static void hook_noteIncoming(id self,
                              SEL _cmd,
                              NSString *username) {
    BOOL valid =
        [username isKindOfClass:[NSString class]] &&
        username.length > 0;

    BOOL grouped =
        valid && WCRIsInCustomGroup(username);

    if (grouped) {
        WCRPersistSurfaced(username, YES);
        WCRAF_LOG(@"incoming surfaced: %@", username);
    }

    if (orig_noteIncoming) {
        orig_noteIncoming(self, _cmd, username);
    }

    if (grouped) {
        WCRRefreshHomeGlobal(@"active_front_incoming");
    } else if (valid) {
        // Even an ungrouped incoming row can be newly inserted/reused. It does
        // not need a projection refresh, but it still needs the ActiveFront pan.
        WCRScheduleVisibleHomeReconcile();
    }
}

static void hook_noteRead(id self,
                          SEL _cmd,
                          NSString *username) {
    BOOL valid =
        [username isKindOfClass:[NSString class]] &&
        username.length > 0;

    BOOL wasSurfaced =
        valid && WCRIsSurfaced(username);

    if (wasSurfaced) {
        // The row may disappear/reorder immediately after the read is
        // consumed. Clear its right-swipe view before that table mutation.
        WCRCloseVisibleRightSwipeForUsername(username);

        WCRPersistSurfaced(username, NO);
        WCRAF_LOG(@"read consumed surfaced: %@", username);
    }

    if (orig_noteRead) {
        orig_noteRead(self, _cmd, username);
    }

    if (wasSurfaced) {
        WCRRefreshHomeGlobal(@"active_front_read");
    }
}

static void hook_activeViewDidAppear(id self,
                                     SEL _cmd,
                                     BOOL animated) {
    if (orig_activeViewDidAppear) {
        orig_activeViewDidAppear(self, _cmd, animated);
    }

    WCRPruneStaleActiveFrontState();
    WCRRefreshHomeDeferred(self,
                           @"active_front_home_appear");
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
    if (orig_cellPrepareForReuse) {
        orig_cellPrepareForReuse(self, _cmd);
    }

    if (![self isKindOfClass:[UITableViewCell class]]) return;

    UITableViewCell *cell = (UITableViewCell *)self;
    WCRHardResetCellVisual(cell, YES);
    WCRClearCanonicalRowBinding(cell);
}

static void hook_cellDidMoveToWindow(id self, SEL _cmd) {
    if (orig_cellDidMoveToWindow) {
        orig_cellDidMoveToWindow(self, _cmd);
    }

    if (![self isKindOfClass:[UITableViewCell class]]) return;

    UITableViewCell *cell = (UITableViewCell *)self;
    if (!cell.window) return;

    // This is an independent row-lifecycle safety net. WCRefine can rebuild
    // or reinsert a home row without the custom willDisplay hook being ready
    // at that exact moment. Once the cell reaches a window, attach on the next
    // run-loop turn, then once more after the snapshot/indexPath settles.
    __weak UITableViewCell *weakCell = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableViewCell *strongCell = weakCell;
        if (strongCell.window) WCRAttachToCell(strongCell);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UITableViewCell *strongCell = weakCell;
        if (strongCell.window) WCRAttachToCell(strongCell);
    });
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

static void WCRTryInstallOtherNicknameHooks(NSUInteger attemptsRemaining) {
    Class groupList =
        NSClassFromString(@"WCRGroupingSessionListViewController");

    if (!gWCRHookOtherGroupCellForRow && groupList) {
        gWCRHookOtherGroupCellForRow =
            WCRInstallInstanceHook(
                groupList,
                @selector(tableView:cellForRowAtIndexPath:),
                (IMP)hook_otherGroupCellForRow,
                (IMP *)&orig_otherGroupCellForRow);
    }

    if (!gWCRHookOtherGroupLayout && groupList) {
        gWCRHookOtherGroupLayout =
            WCRInstallInstanceHook(
                groupList,
                @selector(viewDidLayoutSubviews),
                (IMP)hook_otherGroupViewDidLayoutSubviews,
                (IMP *)&orig_otherGroupViewDidLayoutSubviews);
    }

    Class mainItemView = NSClassFromString(@"MainFrameItemView");
    if (!gWCRHookOtherMainItemLayout && mainItemView) {
        gWCRHookOtherMainItemLayout =
            WCRInstallInstanceHook(
                mainItemView,
                @selector(layoutSubviews),
                (IMP)hook_otherMainItemViewLayoutSubviews,
                (IMP *)&orig_otherMainItemViewLayoutSubviews);
    }

    Class fakeItemView = NSClassFromString(@"FakeMainFrameItemView");
    if (!gWCRHookOtherFakeItemLayout && fakeItemView) {
        gWCRHookOtherFakeItemLayout =
            WCRInstallInstanceHook(
                fakeItemView,
                @selector(layoutSubviews),
                (IMP)hook_otherFakeItemViewLayoutSubviews,
                (IMP *)&orig_otherFakeItemViewLayoutSubviews);
    }

    BOOL hasFinalItemLayoutHook =
        gWCRHookOtherMainItemLayout || gWCRHookOtherFakeItemLayout;

    if (gWCRHookOtherGroupCellForRow &&
        gWCRHookOtherGroupLayout &&
        hasFinalItemLayoutHook) {
        WCRAF_LOG(@"other nickname layout hooks installed cell=1 controllerLayout=1 item=%d fake=%d",
                  gWCRHookOtherMainItemLayout,
                  gWCRHookOtherFakeItemLayout);
        return;
    }

    if (attemptsRemaining == 0) {
        WCRAF_LOG(@"other nickname layout hooks incomplete cell=%d controllerLayout=%d item=%d fake=%d",
                  gWCRHookOtherGroupCellForRow,
                  gWCRHookOtherGroupLayout,
                  gWCRHookOtherMainItemLayout,
                  gWCRHookOtherFakeItemLayout);
        return;
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            WCRTryInstallOtherNicknameHooks(attemptsRemaining - 1);
        });
}

static void WCRScheduleBootstrapUnreadFallbackClose(void) {
    if (gWCRBootstrapCloseScheduled) return;
    gWCRBootstrapCloseScheduled = YES;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(kWCRBootstrapUnreadFallbackSeconds *
                                NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (!gWCRBootstrapUnreadFallbackOpen) return;

            gWCRBootstrapUnreadFallbackOpen = NO;

            [[NSNotificationCenter defaultCenter]
                postNotificationName:kWCRHomeGroupsDidChangeNotification
                              object:nil];

            WCRAF_LOG(@"bootstrap unread fallback closed");
        });
}

static void WCRTryInstallBusinessHooks(NSUInteger attemptsRemaining) {
    Class config =
        NSClassFromString(@"WCRefineConfig");
    Class provider =
        NSClassFromString(@"WCRefineGroupDataProvider");
    Class quickRuntime =
        NSClassFromString(@"WCRQuickChatRuntime");
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

    if (!gWCRHookIncoming && quickRuntime) {
        gWCRHookIncoming =
            WCRInstallInstanceHook(
                quickRuntime,
                @selector(noteIncomingMessageForUsername:),
                (IMP)hook_noteIncoming,
                (IMP *)&orig_noteIncoming);
    }

    if (!gWCRHookRead && quickRuntime) {
        gWCRHookRead =
            WCRInstallInstanceHook(
                quickRuntime,
                @selector(noteReadForUsername:),
                (IMP)hook_noteRead,
                (IMP *)&orig_noteRead);
    }

    if (!gWCRHookHome && mainFrame) {
        gWCRHookHome =
            WCRInstallInstanceHook(
                mainFrame,
                @selector(viewDidAppear:),
                (IMP)hook_activeViewDidAppear,
                (IMP *)&orig_activeViewDidAppear);
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

    if (!gWCRHookCellDidMoveToWindow && mainFrameCell) {
        gWCRHookCellDidMoveToWindow =
            WCRInstallInstanceHook(
                mainFrameCell,
                @selector(didMoveToWindow),
                (IMP)hook_cellDidMoveToWindow,
                (IMP *)&orig_cellDidMoveToWindow);
    }

    if (gWCRHookProvider) {
        WCRScheduleBootstrapUnreadFallbackClose();
    }

    // v1.9.2 accidentally stopped retrying once the five projection hooks
    // were installed, even if willDisplay/prepareForReuse were still missing.
    // That left newly inserted/reused rows without our pan after the finite
    // startup scan ended. Treat row lifecycle hooks as mandatory too.
    BOOL allInstalled =
        gWCRHookConfig &&
        gWCRHookProvider &&
        gWCRHookIncoming &&
        gWCRHookRead &&
        gWCRHookHome &&
        gWCRHookWillDisplay &&
        gWCRHookCellReuse &&
        gWCRHookCellDidMoveToWindow;

    if (allInstalled) {
        WCRAF_LOG(@"business hooks installed config=1 provider=1 incoming=1 read=1 home=1 willDisplay=1 reuse=1 didMove=1");
        WCRPruneStaleActiveFrontState();
        WCRRefreshHomeGlobal(@"active_front_hooks_installed");
        return;
    }

    if (attemptsRemaining == 0) {
        WCRAF_LOG(@"business hooks incomplete config=%d provider=%d incoming=%d read=%d home=%d willDisplay=%d reuse=%d didMove=%d",
                  gWCRHookConfig,
                  gWCRHookProvider,
                  gWCRHookIncoming,
                  gWCRHookRead,
                  gWCRHookHome,
                  gWCRHookWillDisplay,
                  gWCRHookCellReuse,
                  gWCRHookCellDidMoveToWindow);
        return;
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            WCRTryInstallBusinessHooks(attemptsRemaining - 1);
        });
}

#pragma mark - Scan

static void WCRScan(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *tableView = WCRMainTable();

        if (!tableView) {
            if (showReady && !gWCRReadyShown) {
                gWCRReadyShown = YES;
                WCRShow(@"RIGHT_GROUP_UI_V1_9_3 Ready",
                        @"MainFrameTableView not found.");
            }
            return;
        }

        NSUInteger attached = 0;

        for (UITableViewCell *cell in tableView.visibleCells) {
            if (!WCRIsMainFrameCell(cell)) continue;
            WCRAttachToCell(cell);
            if (objc_getAssociatedObject(cell, kWCRPanKey)) {
                attached++;
            }
        }

        if (showReady && !gWCRReadyShown) {
            gWCRReadyShown = YES;

            NSString *message = [NSString stringWithFormat:
                @"Table: %@\n"
                 "Visible attached cells: %lu\n"
                 "Hooks: C%d P%d I%d R%d H%d W%d U%d M%d\n\n"
                 "v1.9.3：右滑 = 分组 / 保持 / 回组\n"
                 "行身份直接绑定 WCRefine 自己的 session resolver。\n"
                 "WCRefine 组内列表不挂独立右滑手势。\n"
                 "左滑继续使用微信原生菜单。\n"
                 "右滑区域保持透明底色。",
                 WCRClassName(tableView),
                 (unsigned long)attached,
                 gWCRHookConfig,
                 gWCRHookProvider,
                 gWCRHookIncoming,
                 gWCRHookRead,
                 gWCRHookHome,
                 gWCRHookWillDisplay,
                 gWCRHookCellReuse,
                 gWCRHookCellDidMoveToWindow];

            WCRShow(@"RIGHT_GROUP_UI_V1_9_3 Ready", message);
        }
    });
}

static void WCRRepeat(NSUInteger remaining) {
    if (remaining == 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCRScan(NO);
        WCRRepeat(remaining - 1);
    });
}

__attribute__((constructor))
static void WCRRightGroupUIInit(void) {
    @autoreleasepool {
        WCRAF_LOG(@"dylib loaded; starting v1.9.3");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(3.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                WCRScan(NO);
                WCRRepeat(180);
            });

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(4.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                WCRTryInstallBusinessHooks(80);
            });

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(4.2 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                WCRTryInstallOtherNicknameHooks(80);
            });

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(5.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                WCRScan(YES);
            });
    }
}
