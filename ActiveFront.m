// ActiveFront.RIGHT_GROUP_UI_V1_7_OWN_RIGHT_PAN.m
// WCRefineGroup - RIGHT swipe proof using an independent, right-only pan.
//
// Why this version exists:
// WeChat's MainFrameTableView does not appear to enter UIKit's standard
// leadingSwipeActionsConfiguration path. v1.6 therefore left LEFT swipe clean,
// but RIGHT swipe still never opened.
//
// v1.7:
// - does NOT hook UIKit leading/trailing swipe delegate methods
// - does NOT attach another target to WeChat's own swipe recognizer
// - adds a separate UIPanGestureRecognizer only to NewMainFrameCell
// - that recognizer is allowed to begin only for horizontal RIGHT movement
// - LEFT movement immediately fails and remains WeChat's original path
// - "分组" background stays hidden unless OUR right pan is active/open
//
// This is still a UI proof. Tapping "分组" does not change real group data.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <math.h>

static const CGFloat kWCRActionWidth = 82.0;

static const void *kWCRPanKey          = &kWCRPanKey;
static const void *kWCRActionViewKey   = &kWCRActionViewKey;
static const void *kWCRButtonKey       = &kWCRButtonKey;
static const void *kWCROpenKey         = &kWCROpenKey;
static const void *kWCRTrackingKey     = &kWCRTrackingKey;
static const void *kWCRStartOffsetKey  = &kWCRStartOffsetKey;

static BOOL gWCRReadyShown = NO;

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
        if (WCRIsMainFrameTable(tableView)) {
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
    cell.contentView.transform = CGAffineTransformMakeTranslation(x, 0.0);
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
    WCRSetBool(cell, kWCROpenKey, NO);
    WCRSetBool(cell, kWCRTrackingKey, NO);
    WCRSetFloat(cell, kWCRStartOffsetKey, 0.0);

    void (^changes)(void) = ^{
        WCRSetContentOffset(cell, 0.0);
    };

    void (^finish)(BOOL) = ^(BOOL finished) {
        (void)finished;
        if (!WCRBool(cell, kWCROpenKey) &&
            !WCRBool(cell, kWCRTrackingKey)) {
            actionView.hidden = YES;
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
    if (!WCRIsMainFrameTable(tableView)) return;

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell == exceptCell) continue;
        if (!WCRBool(cell, kWCROpenKey) &&
            !WCRBool(cell, kWCRTrackingKey)) {
            continue;
        }
        WCRCloseCell(cell, YES);
    }
}

#pragma mark - Controller

@interface WCRRightSwipeController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
- (void)groupTapped:(UIButton *)sender;
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
    if (!WCRIsMainFrameTable(tableView)) return NO;

    CGPoint velocity = [pan velocityInView:cell];

    // If our action is already open, allow a horizontal drag in either
    // direction so the user can drag left to close it.
    if (WCRBool(cell, kWCROpenKey)) {
        return fabs(velocity.x) > fabs(velocity.y) * 1.05;
    }

    // Critical rule: unopened cells are claimed ONLY for horizontal RIGHT pan.
    // A LEFT pan fails here and remains WeChat's original gesture path.
    if (velocity.x <= 30.0) return NO;
    if (fabs(velocity.x) <= fabs(velocity.y) * 1.12) return NO;

    // If WeChat currently has the content shifted left, do not steal the
    // rightward gesture that the user may be using to close WeChat's own menu.
    if (cell.contentView.transform.tx < -1.0) {
        return NO;
    }

    return YES;
}

- (BOOL)       gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {

    (void)gestureRecognizer;

    // Allow WeChat/table recognizers to keep receiving events. Direction
    // gating in gestureRecognizerShouldBegin keeps our recognizer out of LEFT
    // and vertical gestures.
    if ([otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return YES;
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
            WCRCloseOtherCells(cell);
            WCRLayoutAction(cell);

            BOOL wasOpen = WCRBool(cell, kWCROpenKey);
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

- (void)groupTapped:(UIButton *)sender {
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

    UITableView *tableView = WCRTableForCell(cell);
    NSIndexPath *indexPath =
        tableView ? [tableView indexPathForCell:cell] : nil;

    WCRCloseCell(cell, YES);

    NSString *message = [NSString stringWithFormat:
        @"独立右滑手势已经触发「分组」。\n\n"
         "Table: %@\n"
         "Cell: %@\n"
         "Row: %@\n\n"
         "本版本只验证右滑 UI。\n"
         "尚未修改任何 WCRefine 分组数据。",
         WCRClassName(tableView),
         WCRClassName(cell),
         indexPath ? [NSString stringWithFormat:@"%ld",
                      (long)indexPath.row] : @"<nil>"];

    WCRShow(@"RIGHT_GROUP_UI_V1_7", message);
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
    if (!WCRIsMainFrameTable(tableView)) return;

    UIPanGestureRecognizer *pan =
        objc_getAssociatedObject(cell, kWCRPanKey);

    if (!pan) {
        UIView *actionView =
            [[UIView alloc] initWithFrame:CGRectZero];
        actionView.backgroundColor =
            [UIColor colorWithRed:56.0/255.0
                            green:119.0/255.0
                             blue:198.0/255.0
                            alpha:1.0];
        actionView.hidden = YES;
        actionView.clipsToBounds = YES;

        UIButton *button =
            [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:@"分组" forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor]
                     forState:UIControlStateNormal];
        button.titleLabel.font =
            [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        button.backgroundColor = [UIColor clearColor];

        [button addTarget:[WCRRightSwipeController shared]
                   action:@selector(groupTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        [actionView addSubview:button];

        // Keep the action behind contentView, but hidden unless OUR pan begins.
        // This is what prevents the old v1.5 "left swipe sees 分组 underneath"
        // problem.
        [cell insertSubview:actionView belowSubview:cell.contentView];

        pan =
            [[UIPanGestureRecognizer alloc]
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

    // Re-run this because WeChat may add/recreate its cell recognizers later.
    WCRWirePanPriority(cell, pan);
    WCRWirePanPriority(cell.contentView, pan);
}

#pragma mark - Scan

static void WCRScan(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *tableView = WCRMainTable();

        if (!tableView) {
            if (showReady && !gWCRReadyShown) {
                gWCRReadyShown = YES;
                WCRShow(@"RIGHT_GROUP_UI_V1_7 Ready",
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
                 "Visible attached cells: %lu\n\n"
                 "v1.7 结构：\n"
                 "右滑 = WCRefine 独立 right-only pan\n"
                 "左滑 = 微信原手势\n\n"
                 "分组底板默认 hidden，只有 WCRefine 右滑开始后才显示。\n"
                 "点击「分组」仍只弹测试框。",
                 WCRClassName(tableView),
                 (unsigned long)attached];

            WCRShow(@"RIGHT_GROUP_UI_V1_7 Ready", message);
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(3.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScan(YES);
            WCRRepeat(180);
        });
    }
}
