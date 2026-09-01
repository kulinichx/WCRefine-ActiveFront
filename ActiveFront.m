// ActiveFront.SWIPE_DIAG4.m
// WCRefineGroup - Swipe Diagnostic 4
//
// Diagnostic goal:
// DIAG3 proved that MainFrameTableView.delegate really is
// NewMainFrameViewController, and that the two public swipe selectors exist,
// but the real left swipe did not enter either hook.
//
// DIAG4 therefore stops guessing the delegate callback.
// It observes the ACTUAL horizontal gesture and inspects the view hierarchy
// after the native swipe buttons are revealed.
//
// It does NOT add "分组 / 保持 / 回组".

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSHashTable *gObservedRecognizers;
static BOOL gReadyShown = NO;
static BOOL gGestureReported = NO;

#pragma mark - Basic helpers

static NSString *WCRClassName(id obj) {
    return obj ? NSStringFromClass([obj class]) : @"<nil>";
}

static UIViewController *WCRTopViewController(void) {
    UIWindow *target = nil;

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha <= 0.01) continue;
        if (w.windowLevel != UIWindowLevelNormal) continue;

        if (w.isKeyWindow) {
            target = w;
            break;
        }
        if (!target) target = w;
    }

    UIViewController *vc = target.rootViewController;
    if (!vc) return nil;

    BOOL changed = YES;
    while (changed) {
        changed = NO;

        if (vc.presentedViewController &&
            ![vc.presentedViewController isKindOfClass:[UIAlertController class]] &&
            !vc.presentedViewController.isBeingDismissed) {
            vc = vc.presentedViewController;
            changed = YES;
            continue;
        }

        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *next =
                [(UINavigationController *)vc visibleViewController];
            if (next && next != vc) {
                vc = next;
                changed = YES;
                continue;
            }
        }

        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *next =
                [(UITabBarController *)vc selectedViewController];
            if (next && next != vc) {
                vc = next;
                changed = YES;
                continue;
            }
        }
    }

    return vc;
}

static void WCRShowAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = WCRTopViewController();
        if (!vc) return;

        // If one of our diagnostic alerts is still up, wait a little.
        if ([vc.presentedViewController isKindOfClass:[UIAlertController class]] ||
            [vc isKindOfClass:[UIAlertController class]]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WCRShowAlert(title, message);
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

static NSArray *WCRVisibleTableViews(void) {
    NSMutableArray *tables = [NSMutableArray array];

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha <= 0.01) continue;
        WCRCollectTableViews(w, tables);
    }

    return tables;
}

static UITableView *WCRNearestTableView(UIView *view) {
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:[UITableView class]]) {
            return (UITableView *)v;
        }
        v = v.superview;
    }
    return nil;
}

static BOOL WCRViewIsDescendantOfView(UIView *view, UIView *ancestor) {
    if (!view || !ancestor) return NO;
    UIView *v = view;
    while (v) {
        if (v == ancestor) return YES;
        v = v.superview;
    }
    return NO;
}

#pragma mark - Runtime inventory helpers

static BOOL WCRClassDirectlyImplementsSelector(Class cls, SEL sel) {
    if (!cls || !sel) return NO;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;

    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }

    if (methods) free(methods);
    return found;
}

static NSString *WCRMethodOwner(Class cls, SEL sel) {
    Class c = cls;
    while (c) {
        if (WCRClassDirectlyImplementsSelector(c, sel)) {
            return NSStringFromClass(c);
        }
        c = class_getSuperclass(c);
    }
    return @"<none>";
}

static NSArray *WCRInterestingSelectorNames(Class cls) {
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];

    Class c = cls;
    NSInteger depth = 0;

    while (c && depth < 6) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);

        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;

            if ([lower containsString:@"swipe"] ||
                [lower containsString:@"editaction"] ||
                [lower containsString:@"editaction"] ||
                [lower containsString:@"contextual"] ||
                [lower containsString:@"delete"] ||
                [lower containsString:@"commitediting"] ||
                [lower containsString:@"editingstyle"]) {
                [names addObject:[NSString stringWithFormat:@"%@.%@",
                                  NSStringFromClass(c), name]];
            }
        }

        if (methods) free(methods);
        c = class_getSuperclass(c);
        depth++;
    }

    NSArray *all = names.array;
    if (all.count <= 12) return all;
    return [all subarrayWithRange:NSMakeRange(0, 12)];
}

#pragma mark - View hierarchy inspection

static BOOL WCRInterestingClassName(NSString *name) {
    NSString *s = name.lowercaseString;
    return ([s containsString:@"swipe"] ||
            [s containsString:@"action"] ||
            [s containsString:@"edit"] ||
            [s containsString:@"delete"] ||
            [s containsString:@"context"] ||
            [s containsString:@"button"]);
}

static void WCRCollectInterestingViews(UIView *view,
                                       UITableView *table,
                                       NSMutableOrderedSet *out,
                                       NSInteger depth) {
    if (!view || depth > 12) return;
    if (view.hidden || view.alpha <= 0.01) return;

    if (table && !WCRViewIsDescendantOfView(view, table) &&
        !WCRViewIsDescendantOfView(table, view)) {
        // Keep scanning only objects related to this table.
        return;
    }

    NSString *cls = WCRClassName(view);

    NSString *text = nil;
    if ([view isKindOfClass:[UILabel class]]) {
        text = ((UILabel *)view).text;
    } else if ([view isKindOfClass:[UIButton class]]) {
        text = [((UIButton *)view) titleForState:UIControlStateNormal];
    }

    BOOL usefulText =
        (text.length > 0 &&
         ([text containsString:@"已读"] ||
          [text containsString:@"不显示"] ||
          [text containsString:@"删除"] ||
          [text containsString:@"分组"] ||
          [text containsString:@"保持"] ||
          [text containsString:@"回组"]));

    if (WCRInterestingClassName(cls) || usefulText) {
        NSString *item = text.length > 0
            ? [NSString stringWithFormat:@"%@  text=\"%@\"", cls, text]
            : cls;
        [out addObject:item];
    }

    for (UIGestureRecognizer *gr in view.gestureRecognizers) {
        NSString *gname = WCRClassName(gr);
        if (WCRInterestingClassName(gname) ||
            [gr isKindOfClass:[UIPanGestureRecognizer class]]) {
            [out addObject:[NSString stringWithFormat:@"GR:%@ on %@",
                            gname, cls]];
        }
    }

    for (UIView *sub in view.subviews) {
        WCRCollectInterestingViews(sub, table, out, depth + 1);
    }
}

static NSString *WCRHierarchyReport(UITableView *table) {
    if (!table) return @"<no table>";

    NSMutableOrderedSet *items = [NSMutableOrderedSet orderedSet];
    WCRCollectInterestingViews(table, table, items, 0);

    // Also inspect the table's direct superview because UIKit swipe containers
    // may be inserted next to / above the cell rather than beneath it.
    if (table.superview) {
        for (UIView *sub in table.superview.subviews) {
            if (sub == table) continue;
            WCRCollectInterestingViews(sub, nil, items, 0);
        }
    }

    NSArray *all = items.array;
    if (all.count == 0) return @"<none found>";

    NSUInteger limit = MIN((NSUInteger)18, all.count);
    return [[all subarrayWithRange:NSMakeRange(0, limit)]
            componentsJoinedByString:@"\n"];
}

#pragma mark - Gesture observer

@interface WCRSwipeDiag4Observer : NSObject
- (void)wcr_handleGesture:(UIGestureRecognizer *)gr;
@end

@implementation WCRSwipeDiag4Observer

- (void)wcr_handleGesture:(UIGestureRecognizer *)gr {
    if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) return;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gr;
    UIView *grView = gr.view;
    UITableView *table = WCRNearestTableView(grView);

    // Sometimes the recognizer is installed on an internal sibling/subview.
    if (!table) {
        CGPoint wp = [pan locationInView:nil];
        for (UITableView *candidate in WCRVisibleTableViews()) {
            CGRect rect = [candidate convertRect:candidate.bounds toView:nil];
            if (CGRectContainsPoint(rect, wp)) {
                table = candidate;
                break;
            }
        }
    }

    if (!table) return;

    CGPoint tr = [pan translationInView:table];
    CGPoint vel = [pan velocityInView:table];

    BOOL horizontalLeft =
        (tr.x < -12.0 &&
         fabs(tr.x) > fabs(tr.y) * 1.15);

    if ((gr.state == UIGestureRecognizerStateChanged ||
         gr.state == UIGestureRecognizerStateEnded) &&
        horizontalLeft &&
        !gGestureReported) {

        gGestureReported = YES;

        CGPoint p = [pan locationInView:table];
        NSIndexPath *ip = [table indexPathForRowAtPoint:p];
        UITableViewCell *cell = ip ? [table cellForRowAtIndexPath:ip] : nil;

        NSString *gestureClass = WCRClassName(gr);
        NSString *gestureViewClass = WCRClassName(grView);
        NSString *tableClass = WCRClassName(table);
        NSString *delegateClass = WCRClassName(table.delegate);
        NSString *dataSourceClass = WCRClassName(table.dataSource);
        NSString *cellClass = WCRClassName(cell);

        // Wait for the native action buttons to finish opening, then inspect.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.28 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *hier = WCRHierarchyReport(table);

            NSString *msg = [NSString stringWithFormat:
                @"Recognizer: %@\n"
                 "Recognizer.view: %@\n\n"
                 "Table: %@\n"
                 "Delegate: %@\n"
                 "DataSource: %@\n\n"
                 "IndexPath: %@\n"
                 "Cell: %@\n\n"
                 "translation=(%.1f, %.1f)\n"
                 "velocity=(%.1f, %.1f)\n\n"
                 "VISIBLE SWIPE/ACTION CLASSES:\n%@",
                 gestureClass,
                 gestureViewClass,
                 tableClass,
                 delegateClass,
                 dataSourceClass,
                 ip ? [NSString stringWithFormat:@"section=%ld row=%ld",
                       (long)ip.section, (long)ip.row] : @"<nil>",
                 cellClass,
                 tr.x, tr.y,
                 vel.x, vel.y,
                 hier];

            WCRShowAlert(@"SWIPE_DIAG4 Gesture HIT", msg);
        });
    }

    if (gr.state == UIGestureRecognizerStateEnded ||
        gr.state == UIGestureRecognizerStateCancelled ||
        gr.state == UIGestureRecognizerStateFailed) {

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gGestureReported = NO;
        });
    }
}

@end

static WCRSwipeDiag4Observer *gObserver;

#pragma mark - Install observer on pan recognizers

static void WCRAttachToRecognizersRecursively(UIView *view,
                                               UITableView *targetTable) {
    if (!view) return;

    // Restrict to the target table's subtree.
    if (targetTable && view != targetTable &&
        !WCRViewIsDescendantOfView(view, targetTable)) {
        return;
    }

    for (UIGestureRecognizer *gr in view.gestureRecognizers) {
        if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) continue;

        @synchronized (gObservedRecognizers) {
            if (![gObservedRecognizers containsObject:gr]) {
                [gr addTarget:gObserver action:@selector(wcr_handleGesture:)];
                [gObservedRecognizers addObject:gr];
            }
        }
    }

    for (UIView *sub in view.subviews) {
        WCRAttachToRecognizersRecursively(sub, targetTable);
    }
}

static UITableView *WCRMainFrameTableView(void) {
    NSArray *tables = WCRVisibleTableViews();

    for (UITableView *tv in tables) {
        if ([WCRClassName(tv) isEqualToString:@"MainFrameTableView"]) {
            return tv;
        }
    }

    return tables.firstObject;
}

static NSString *WCRRecognizerInventory(UITableView *table) {
    if (!table) return @"<no table>";

    NSMutableOrderedSet *items = [NSMutableOrderedSet orderedSet];

    NSMutableArray *stack = [NSMutableArray arrayWithObject:table];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            [items addObject:
                [NSString stringWithFormat:@"%@ on %@",
                 WCRClassName(gr), WCRClassName(v)]];
        }

        for (UIView *sub in v.subviews) {
            [stack addObject:sub];
        }
    }

    NSArray *all = items.array;
    if (all.count == 0) return @"<none>";

    NSUInteger limit = MIN((NSUInteger)12, all.count);
    return [[all subarrayWithRange:NSMakeRange(0, limit)]
            componentsJoinedByString:@"\n"];
}

static void WCRScanAndAttach(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *table = WCRMainFrameTableView();
        if (!table) {
            if (showReady && !gReadyShown) {
                gReadyShown = YES;
                WCRShowAlert(@"SWIPE_DIAG4 Ready",
                             @"MainFrameTableView not found.\n"
                              "Stay on WeChat conversation home and reopen.");
            }
            return;
        }

        WCRAttachToRecognizersRecursively(table, table);

        if (showReady && !gReadyShown) {
            gReadyShown = YES;

            SEL modern =
                NSSelectorFromString(@"tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:");
            SEL legacy =
                NSSelectorFromString(@"tableView:editActionsForRowAtIndexPath:");

            Class dcls = [table.delegate class];

            NSArray *selectors = WCRInterestingSelectorNames(dcls);
            NSString *selectorText =
                selectors.count > 0
                ? [selectors componentsJoinedByString:@"\n"]
                : @"<no matching selector names>";

            NSString *msg = [NSString stringWithFormat:
                @"Table: %@\n"
                 "Delegate: %@\n"
                 "DataSource: %@\n\n"
                 "modern owner: %@\n"
                 "legacy owner: %@\n\n"
                 "GESTURE RECOGNIZERS:\n%@\n\n"
                 "SWIPE/EDIT SELECTOR INVENTORY:\n%@\n\n"
                 "Tap OK, then left-swipe ONE normal ungrouped friend.",
                 WCRClassName(table),
                 WCRClassName(table.delegate),
                 WCRClassName(table.dataSource),
                 WCRMethodOwner(dcls, modern),
                 WCRMethodOwner(dcls, legacy),
                 WCRRecognizerInventory(table),
                 selectorText];

            WCRShowAlert(@"SWIPE_DIAG4 Ready", msg);
        }
    });
}

static void WCRScheduleScan(NSUInteger remaining) {
    if (remaining == 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCRScanAndAttach(NO);
        WCRScheduleScan(remaining - 1);
    });
}

__attribute__((constructor))
static void WCRSwipeDiag4Init(void) {
    @autoreleasepool {
        gObservedRecognizers = [NSHashTable weakObjectsHashTable];
        gObserver = [WCRSwipeDiag4Observer new];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScanAndAttach(YES);

            // Keep attaching for a while because UIKit may create a private
            // swipe recognizer lazily after the first interaction.
            WCRScheduleScan(30);
        });
    }
}
