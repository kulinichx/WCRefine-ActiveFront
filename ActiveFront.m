// ActiveFront.RIGHT_GROUP_UI_V1_5_NATIVE.m
// WCRefineGroup - Minimal RIGHT swipe "分组" proof
//
// Design goal:
// - Keep WeChat's LEFT swipe completely untouched:
//     标为已读 / 不显示 / 删除
// - Use the otherwise-unused RIGHT swipe for WCRefineGroup.
// - This proof shows ONE native-style blue "分组" button on the left side.
//
// This build DOES NOT perform real grouping yet.
// Tapping "分组" only shows a confirmation alert.
//
// Implementation strategy:
// - Reuse each NewMainFrameCell's existing UIPanGestureRecognizer.
// - Add an observer target; do not replace NewMainFrameCell.handlePan:.
// - Only react when translation.x > 0 and horizontal movement dominates.
// - Reveal a button underneath the cell's contentView.
// - Left swipe remains handled by WeChat's original code.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static const void *kWCRRightButtonKey = &kWCRRightButtonKey;
static const void *kWCRRightOpenKey     = &kWCRRightOpenKey;
static const void *kWCRRightTrackingKey = &kWCRRightTrackingKey;

static NSHashTable *gObservedRecognizers;
static id gObserver;
static __weak UITableViewCell *gOpenCell = nil;
static BOOL gReadyShown = NO;

// Native WeChat reference from the supplied left-swipe screenshot:
// - 2-character actions ("不显示"/"删除" visual slot) are ~80 pt wide.
// - The action group uses a rounded outer contour of ~16 pt.
static const CGFloat kWCRButtonWidth = 80.0;
static const CGFloat kWCROpenThreshold = 40.0;
static const CGFloat kWCRActionCornerRadius = 16.0;


#pragma mark - Helpers

static NSString *WCRClassName(id obj) {
    return obj ? NSStringFromClass([obj class]) : @"<nil>";
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WCRShow(title, message);
            });
            return;
        }

        UIAlertController *a =
            [UIAlertController alertControllerWithTitle:title
                                                message:message ?: @""
                                         preferredStyle:UIAlertControllerStyleAlert];

        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];

        [vc presentViewController:a animated:YES completion:nil];
    });
}

static void WCRCollectTableViews(UIView *view, NSMutableArray *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;

    if ([view isKindOfClass:[UITableView class]] && view.window) {
        [out addObject:view];
    }

    for (UIView *sub in view.subviews) {
        WCRCollectTableViews(sub, out);
    }
}

static UITableView *WCRMainTable(void) {
    NSMutableArray *tables = [NSMutableArray array];

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha <= 0.01) continue;
        WCRCollectTableViews(w, tables);
    }

    for (UITableView *tv in tables) {
        if ([WCRClassName(tv) isEqualToString:@"MainFrameTableView"]) {
            return tv;
        }
    }

    return tables.firstObject;
}



#pragma mark - Right action UI

@interface WCRRightGroupButtonTarget : NSObject
- (void)wcr_groupTapped:(UIButton *)sender;
@end

static WCRRightGroupButtonTarget *gButtonTarget;

static UIButton *WCRRightButtonForCell(UITableViewCell *cell, BOOL create) {
    if (!cell) return nil;

    UIButton *button = objc_getAssociatedObject(cell, kWCRRightButtonKey);
    if (button || !create) return button;

    button = [UIButton buttonWithType:UIButtonTypeCustom];
    // Keep the action at its final native-like width from the start.
    // The translated contentView acts as the reveal mask, just like WeChat's
    // own trailing menu, so the button itself never stretches while dragging.
    button.frame = CGRectMake(0, 0, kWCRButtonWidth, CGRectGetHeight(cell.bounds));
    button.autoresizingMask = UIViewAutoresizingFlexibleHeight;

    // Match the native WeChat blue action in the supplied left-swipe capture.
    // The JPEG sample is approximately RGB(56,119,198).
    button.backgroundColor = [UIColor colorWithRed:56.0/255.0
                                             green:119.0/255.0
                                              blue:198.0/255.0
                                             alpha:1.0];

    [button setTitle:@"分组" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.85;

    // A single right-side WCRefine action should look like a one-item version
    // of WeChat's native rounded action group. While partially revealed, the
    // moving contentView naturally masks the right-side corners.
    button.layer.cornerRadius = kWCRActionCornerRadius;
    button.layer.masksToBounds = YES;
    button.hidden = YES;
    button.alpha = 1.0;

    [button addTarget:gButtonTarget
               action:@selector(wcr_groupTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    // Keep the action underneath contentView. Sliding contentView to the right
    // reveals a fixed-width action strip instead of a floating/stretching card.
    if (cell.contentView.superview == cell) {
        [cell insertSubview:button belowSubview:cell.contentView];
    } else {
        [cell addSubview:button];
        [cell sendSubviewToBack:button];
    }

    objc_setAssociatedObject(cell,
                             kWCRRightButtonKey,
                             button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return button;
}

static BOOL WCRCellIsRightOpen(UITableViewCell *cell) {
    NSNumber *value = objc_getAssociatedObject(cell, kWCRRightOpenKey);
    return value.boolValue;
}

static void WCRSetCellRightOpen(UITableViewCell *cell, BOOL open) {
    if (!cell) return;
    objc_setAssociatedObject(cell,
                             kWCRRightOpenKey,
                             @(open),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL WCRCellIsRightTracking(UITableViewCell *cell) {
    NSNumber *value = objc_getAssociatedObject(cell, kWCRRightTrackingKey);
    return value.boolValue;
}

static void WCRSetCellRightTracking(UITableViewCell *cell, BOOL tracking) {
    if (!cell) return;
    objc_setAssociatedObject(cell,
                             kWCRRightTrackingKey,
                             @(tracking),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WCRApplyRightOffset(UITableViewCell *cell, CGFloat x) {
    if (!cell) return;

    UIButton *button = WCRRightButtonForCell(cell, YES);

    // Cap the reveal. The action stays fixed at its final width; contentView
    // is the moving foreground that progressively exposes it.
    x = MAX(0.0, MIN(kWCRButtonWidth, x));

    button.hidden = (x <= 0.5);
    button.frame = CGRectMake(0, 0, kWCRButtonWidth, CGRectGetHeight(cell.bounds));
    button.alpha = 1.0;

    CGAffineTransform t = CGAffineTransformMakeTranslation(x, 0);
    cell.contentView.transform = t;
}

static void WCRCloseCell(UITableViewCell *cell, BOOL animated) {
    if (!cell) return;

    UIButton *button = WCRRightButtonForCell(cell, NO);

    void (^changes)(void) = ^{
        cell.contentView.transform = CGAffineTransformIdentity;
        if (button) {
            button.frame = CGRectMake(0, 0, kWCRButtonWidth, CGRectGetHeight(cell.bounds));
            button.alpha = 1.0;
        }
    };

    void (^finish)(void) = ^{
        if (button) button.hidden = YES;
    };

    if (animated) {
        [UIView animateWithDuration:0.20
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:^(__unused BOOL finished) {
            finish();
        }];
    } else {
        changes();
        finish();
    }

    WCRSetCellRightOpen(cell, NO);
    WCRSetCellRightTracking(cell, NO);
    if (gOpenCell == cell) gOpenCell = nil;
}

static void WCROpenCell(UITableViewCell *cell, BOOL animated) {
    if (!cell) return;

    if (gOpenCell && gOpenCell != cell) {
        WCRCloseCell(gOpenCell, YES);
    }

    UIButton *button = WCRRightButtonForCell(cell, YES);
    button.hidden = NO;

    void (^changes)(void) = ^{
        button.frame = CGRectMake(0, 0, kWCRButtonWidth, CGRectGetHeight(cell.bounds));
        button.alpha = 1.0;
        cell.contentView.transform = CGAffineTransformMakeTranslation(kWCRButtonWidth, 0);
    };

    if (animated) {
        [UIView animateWithDuration:0.20
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }

    WCRSetCellRightOpen(cell, YES);
    gOpenCell = cell;
}

@implementation WCRRightGroupButtonTarget

- (void)wcr_groupTapped:(UIButton *)sender {
    UITableViewCell *cell = nil;
    UIView *v = sender.superview;

    while (v) {
        if ([v isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell *)v;
            break;
        }
        v = v.superview;
    }

    NSString *msg = [NSString stringWithFormat:
        @"右滑「分组」按钮已经工作。\n\n"
         "Cell: %@\n\n"
         "本版本只验证右滑交互和按钮点击。\n"
         "尚未修改任何 WCRefine 分组数据。",
         WCRClassName(cell)];

    WCRCloseCell(cell, YES);
    WCRShow(@"RIGHT_GROUP_UI_V1_5_NATIVE", msg);
}

@end

#pragma mark - Existing cell pan observer

@interface WCRRightGroupPanObserver : NSObject
- (void)wcr_handleCellPan:(UIPanGestureRecognizer *)pan;
@end

@implementation WCRRightGroupPanObserver

- (void)wcr_handleCellPan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    if (![view isKindOfClass:NSClassFromString(@"NewMainFrameCell")]) return;

    UITableViewCell *cell = (UITableViewCell *)view;

    CGPoint tr = [pan translationInView:cell];
    CGPoint vel = [pan velocityInView:cell];

    BOOL horizontal = fabs(tr.x) > fabs(tr.y) * 1.15;
    BOOL isOpen = WCRCellIsRightOpen(cell);
    BOOL tracking = WCRCellIsRightTracking(cell);

    if (pan.state == UIGestureRecognizerStateBegan) {
        // If another WCRefine right action is open, collapse it first.
        if (gOpenCell && gOpenCell != cell) {
            WCRCloseCell(gOpenCell, YES);
        }

        // An already-open cell owns the next horizontal gesture so it can be
        // closed by swiping back left. A closed cell does NOT own anything yet.
        WCRSetCellRightTracking(cell, isOpen);
        return;
    }

    if (pan.state == UIGestureRecognizerStateChanged) {
        tracking = WCRCellIsRightTracking(cell);

        if (!tracking) {
            // Critical compatibility gate: an unopened cell only becomes ours
            // after the gesture is clearly horizontal AND points to the right.
            // A normal WeChat left swipe never reaches WCRApplyRightOffset().
            if (!horizontal || tr.x <= 0.0) return;
            WCRSetCellRightTracking(cell, YES);
            tracking = YES;
        }

        if (!horizontal) return;

        CGFloat base = isOpen ? kWCRButtonWidth : 0.0;
        CGFloat x = base + tr.x;

        // Run after WeChat's own handlePan: for the same event. On versions of
        // WeChat where right swipe is a no-op, this prevents its handler from
        // immediately overwriting our transform.
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRApplyRightOffset(cell, x);
        });
        return;
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {

        tracking = WCRCellIsRightTracking(cell);

        // If this was never a WCRefine right swipe, do absolutely nothing.
        // In particular, do NOT reset contentView.transform: WeChat may be
        // keeping its native left-swipe actions open.
        if (!tracking) return;

        WCRSetCellRightTracking(cell, NO);

        BOOL shouldOpen = NO;

        if (pan.state == UIGestureRecognizerStateCancelled ||
            pan.state == UIGestureRecognizerStateFailed) {
            // Cancellation restores the state that existed when the gesture
            // began: an open action re-opens; a new partial reveal disappears.
            shouldOpen = isOpen;
        } else {
            CGFloat projected = tr.x + vel.x * 0.08;

            if (isOpen) {
                shouldOpen = projected > -kWCROpenThreshold;
            } else {
                shouldOpen = projected > kWCROpenThreshold;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (shouldOpen) {
                WCROpenCell(cell, YES);
            } else {
                WCRCloseCell(cell, YES);
            }
        });
    }
}

@end

#pragma mark - Attach to NewMainFrameCell pan recognizers

static void WCRPrepareCell(UITableViewCell *cell) {
    Class targetClass = NSClassFromString(@"NewMainFrameCell");
    if (!targetClass || ![cell isKindOfClass:targetClass]) return;

    // Do not pre-create/reveal a button for every visible row.
    // Create it lazily only when the user actually starts a right swipe.
    if (!WCRCellIsRightOpen(cell) && gOpenCell != cell) {
        // Do not force contentView.transform back to identity here. WeChat may
        // currently be using that transform for its native left-swipe menu.
        UIButton *existing = WCRRightButtonForCell(cell, NO);
        if (existing) {
            existing.hidden = YES;
            existing.alpha = 1.0;
            existing.frame = CGRectMake(0, 0, kWCRButtonWidth, CGRectGetHeight(cell.bounds));
        }
    }

    for (UIGestureRecognizer *gr in cell.gestureRecognizers) {
        if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) continue;

        @synchronized (gObservedRecognizers) {
            if (![gObservedRecognizers containsObject:gr]) {
                [gr addTarget:gObserver
                       action:@selector(wcr_handleCellPan:)];
                [gObservedRecognizers addObject:gr];
            }
        }
    }
}

static void WCRScan(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *table = WCRMainTable();

        if (!table) {
            if (showReady && !gReadyShown) {
                gReadyShown = YES;
                WCRShow(@"RIGHT_GROUP_UI_V1_5_NATIVE Ready",
                        @"MainFrameTableView not found.");
            }
            return;
        }

        for (UITableViewCell *cell in table.visibleCells) {
            WCRPrepareCell(cell);
        }

        if (showReady && !gReadyShown) {
            gReadyShown = YES;

            NSString *msg = [NSString stringWithFormat:
                @"Table: %@\n"
                 "Visible cells: %lu\n\n"
                 "本版交互：\n"
                 "左滑 = 微信原生，不修改\n"
                 "右滑 = 显示一个「分组」按钮\n"
                 "样式 = 80pt 原生宽度、16pt 圆角、微信蓝、整行高度\n"
                 "兼容 = 未进入右滑时绝不重置微信左滑 transform\n\n"
                 "测试一个普通未分组好友即可。\n"
                 "点击「分组」只弹确认框，不会真的改分组。",
                 WCRClassName(table),
                 (unsigned long)table.visibleCells.count];

            WCRShow(@"RIGHT_GROUP_UI_V1_5_NATIVE Ready", msg);
        }
    });
}

static void WCRRepeat(NSUInteger remaining) {
    if (remaining == 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCRScan(NO);
        WCRRepeat(remaining - 1);
    });
}

__attribute__((constructor))
static void WCRRightGroupUIInit(void) {
    @autoreleasepool {
        gObservedRecognizers = [NSHashTable weakObjectsHashTable];
        gObserver = [WCRRightGroupPanObserver new];
        gButtonTarget = [WCRRightGroupButtonTarget new];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScan(YES);
            WCRRepeat(45);
        });
    }
}
