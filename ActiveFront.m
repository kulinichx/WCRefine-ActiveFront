// ActiveFront.SWIPE_DIAG5.m
// WCRefineGroup - Swipe Diagnostic 5
//
// DIAG4 result:
// - The real row is NewMainFrameCell.
// - A UIPanGestureRecognizer is installed directly on NewMainFrameCell.
// - The revealed action buttons are MenuButton instances:
//   "标为已读" / "不显示" / "删除".
//
// DIAG5 goal:
// 1) Trace the NewMainFrameCell pan recognizer.
// 2) Inspect NewMainFrameCell's swipe/menu/action-related selectors.
// 3) Inspect each visible MenuButton's target/action.
// 4) Print each button's superview chain.
// This is diagnostic only; it does not add the "分组" button.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSHashTable *gObservedRecognizers;
static id gObserver;
static BOOL gReadyShown = NO;
static BOOL gReportedThisGesture = NO;

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
            UIViewController *n = [(UINavigationController *)vc visibleViewController];
            if (n && n != vc) {
                vc = n;
                moved = YES;
                continue;
            }
        }

        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *n = [(UITabBarController *)vc selectedViewController];
            if (n && n != vc) {
                vc = n;
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
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
        if ([WCRClassName(tv) isEqualToString:@"MainFrameTableView"]) return tv;
    }

    return tables.firstObject;
}

static BOOL WCRIsDescendant(UIView *view, UIView *ancestor) {
    UIView *v = view;
    while (v) {
        if (v == ancestor) return YES;
        v = v.superview;
    }
    return NO;
}

static UITableView *WCRNearestTable(UIView *view) {
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
        v = v.superview;
    }
    return nil;
}

static NSString *WCRButtonText(UIButton *button) {
    NSString *text = [button titleForState:UIControlStateNormal];
    if (text.length) return text;

    for (UIView *sub in button.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)sub).text;
            if (t.length) return t;
        }
    }

    return @"";
}

#pragma mark - Interesting method inventory

static BOOL WCRInterestingSelector(NSString *name) {
    NSString *s = name.lowercaseString;

    return [s containsString:@"swipe"] ||
           [s containsString:@"pan"] ||
           [s containsString:@"gesture"] ||
           [s containsString:@"menu"] ||
           [s containsString:@"action"] ||
           [s containsString:@"edit"] ||
           [s containsString:@"delete"] ||
           [s containsString:@"read"] ||
           [s containsString:@"hide"] ||
           [s containsString:@"show"] ||
           [s containsString:@"button"] ||
           [s containsString:@"more"];
}

static NSArray<NSString *> *WCRMethodInventory(Class cls, NSUInteger maxCount) {
    NSMutableOrderedSet *items = [NSMutableOrderedSet orderedSet];

    Class c = cls;
    NSInteger depth = 0;

    while (c && depth < 5) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);

        for (unsigned int i = 0; i < count; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if (!WCRInterestingSelector(selName)) continue;

            [items addObject:
                [NSString stringWithFormat:@"%@.%@",
                 NSStringFromClass(c), selName]];
        }

        if (methods) free(methods);

        c = class_getSuperclass(c);
        depth++;
    }

    NSArray *all = items.array;
    if (all.count <= maxCount) return all;
    return [all subarrayWithRange:NSMakeRange(0, maxCount)];
}

#pragma mark - UIGestureRecognizer private target/action diagnostics

static id WCRObjectIvar(id obj, const char *name) {
    if (!obj || !name) return nil;

    Class c = [obj class];
    while (c) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) {
            const char *type = ivar_getTypeEncoding(iv);
            if (type && type[0] == '@') {
                return object_getIvar(obj, iv);
            }
            return nil;
        }
        c = class_getSuperclass(c);
    }

    return nil;
}

static SEL WCRSELIvar(id obj, const char *name) {
    if (!obj || !name) return NULL;

    Class c = [obj class];
    while (c) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) {
            const char *type = ivar_getTypeEncoding(iv);
            if (!type || type[0] != ':') return NULL;

            ptrdiff_t offset = ivar_getOffset(iv);
            uint8_t *bytes = (uint8_t *)(__bridge void *)obj;
            SEL value = NULL;
            memcpy(&value, bytes + offset, sizeof(SEL));
            return value;
        }
        c = class_getSuperclass(c);
    }

    return NULL;
}

static NSString *WCRGestureTargets(UIGestureRecognizer *gr) {
    NSMutableArray *lines = [NSMutableArray array];

    id targets = WCRObjectIvar(gr, "_targets");
    if ([targets isKindOfClass:[NSArray class]]) {
        for (id record in (NSArray *)targets) {
            id target = WCRObjectIvar(record, "_target");
            SEL action = WCRSELIvar(record, "_action");

            [lines addObject:
                [NSString stringWithFormat:@"target=%@ action=%@",
                 WCRClassName(target),
                 action ? NSStringFromSelector(action) : @"<nil>"]];
        }
    }

    if (lines.count == 0) return @"<not resolved>";
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - UIButton target/action diagnostics

static NSString *WCRButtonActions(UIButton *button) {
    NSMutableArray *lines = [NSMutableArray array];

    NSSet *targets = [button allTargets];
    for (id target in targets) {
        NSArray *actions = [button actionsForTarget:target
                                   forControlEvent:UIControlEventTouchUpInside];

        if (actions.count == 0) {
            actions = [button actionsForTarget:target
                               forControlEvent:UIControlEventPrimaryActionTriggered];
        }

        if (actions.count == 0) {
            [lines addObject:
                [NSString stringWithFormat:@"target=%@ action=<none for TouchUpInside>",
                 WCRClassName(target)]];
        } else {
            for (NSString *action in actions) {
                [lines addObject:
                    [NSString stringWithFormat:@"target=%@ action=%@",
                     WCRClassName(target), action]];
            }
        }
    }

    if (lines.count == 0) return @"<no UIControl targets>";
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *WCRSuperviewChain(UIView *view, UIView *stop) {
    NSMutableArray *names = [NSMutableArray array];

    UIView *v = view;
    NSInteger depth = 0;

    while (v && depth < 8) {
        [names addObject:WCRClassName(v)];
        if (v == stop) break;
        v = v.superview;
        depth++;
    }

    return [names componentsJoinedByString:@" <- "];
}

#pragma mark - Find action buttons

static void WCRCollectMenuButtons(UIView *view,
                                  UITableViewCell *cell,
                                  NSMutableArray<UIButton *> *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)view;
        NSString *className = WCRClassName(b);
        NSString *text = WCRButtonText(b);

        BOOL menuClass = [className containsString:@"MenuButton"];
        BOOL knownTitle =
            [text containsString:@"已读"] ||
            [text containsString:@"不显示"] ||
            [text containsString:@"删除"];

        if (menuClass || knownTitle) {
            [out addObject:b];
        }
    }

    for (UIView *sub in view.subviews) {
        WCRCollectMenuButtons(sub, cell, out);
    }
}

static NSArray<UIButton *> *WCRActionButtonsForCell(UITableViewCell *cell) {
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];

    // Scan the cell.
    WCRCollectMenuButtons(cell, cell, buttons);

    // The action container may be inserted next to the cell.
    UIView *parent = cell.superview;
    if (parent) {
        for (UIView *sub in parent.subviews) {
            if (sub == cell) continue;
            WCRCollectMenuButtons(sub, cell, buttons);
        }
    }

    // Deduplicate.
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:buttons];
    return set.array;
}

#pragma mark - Build report after swipe

static NSString *WCRReport(UITableView *table,
                           NSIndexPath *indexPath,
                           UITableViewCell *cell,
                           UIGestureRecognizer *triggerGR) {

    NSMutableString *s = [NSMutableString string];

    [s appendFormat:
        @"Table: %@\n"
         "Delegate: %@\n"
         "IndexPath: %@\n"
         "Cell: %@\n"
         "Cell.super: %@\n\n",
         WCRClassName(table),
         WCRClassName(table.delegate),
         indexPath
            ? [NSString stringWithFormat:@"section=%ld row=%ld",
               (long)indexPath.section, (long)indexPath.row]
            : @"<nil>",
         WCRClassName(cell),
         cell ? NSStringFromClass(class_getSuperclass([cell class])) : @"<nil>"];

    [s appendFormat:
        @"TRIGGER GESTURE:\n"
         "%@ on %@\n%@\n\n",
         WCRClassName(triggerGR),
         WCRClassName(triggerGR.view),
         WCRGestureTargets(triggerGR)];

    if (cell) {
        [s appendString:@"CELL GESTURES:\n"];

        if (cell.gestureRecognizers.count == 0) {
            [s appendString:@"<none>\n"];
        } else {
            for (UIGestureRecognizer *gr in cell.gestureRecognizers) {
                [s appendFormat:
                    @"%@\n%@\n",
                     WCRClassName(gr),
                     WCRGestureTargets(gr)];
            }
        }

        [s appendString:@"\nCELL SELECTOR INVENTORY:\n"];
        NSArray *methods = WCRMethodInventory([cell class], 30);
        if (methods.count) {
            [s appendString:[methods componentsJoinedByString:@"\n"]];
        } else {
            [s appendString:@"<none>"];
        }
        [s appendString:@"\n\n"];
    }

    NSArray<UIButton *> *buttons = cell ? WCRActionButtonsForCell(cell) : @[];

    [s appendFormat:@"VISIBLE ACTION BUTTONS: %lu\n",
     (unsigned long)buttons.count];

    NSInteger idx = 0;
    for (UIButton *button in buttons) {
        idx++;
        NSString *text = WCRButtonText(button);

        [s appendFormat:
            @"\n[%ld] %@ text=\"%@\"\n"
             "frame=(%.1f %.1f %.1f %.1f)\n"
             "actions:\n%@\n"
             "chain:\n%@\n",
             (long)idx,
             WCRClassName(button),
             text,
             button.frame.origin.x,
             button.frame.origin.y,
             button.frame.size.width,
             button.frame.size.height,
             WCRButtonActions(button),
             WCRSuperviewChain(button, cell)];
    }

    return s;
}

#pragma mark - Observer

@interface WCRSwipeDiag5Observer : NSObject
- (void)wcr_pan:(UIGestureRecognizer *)gr;
@end

@implementation WCRSwipeDiag5Observer

- (void)wcr_pan:(UIGestureRecognizer *)gr {
    if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) return;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gr;

    UITableView *table = WCRNearestTable(gr.view);
    if (!table) {
        UITableView *candidate = WCRMainTable();
        if (candidate && WCRIsDescendant(gr.view, candidate)) {
            table = candidate;
        }
    }
    if (!table) return;

    CGPoint tr = [pan translationInView:table];

    BOOL left =
        tr.x < -12.0 &&
        fabs(tr.x) > fabs(tr.y) * 1.1;

    if ((gr.state == UIGestureRecognizerStateChanged ||
         gr.state == UIGestureRecognizerStateEnded) &&
        left &&
        !gReportedThisGesture) {

        gReportedThisGesture = YES;

        CGPoint p = [pan locationInView:table];
        NSIndexPath *ip = [table indexPathForRowAtPoint:p];
        UITableViewCell *cell = ip ? [table cellForRowAtIndexPath:ip] : nil;

        // If this recognizer is attached to the cell itself, prefer that cell.
        if ([gr.view isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell *)gr.view;
            NSIndexPath *realIP = [table indexPathForCell:cell];
            if (realIP) ip = realIP;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *report = WCRReport(table, ip, cell, gr);
            WCRShow(@"SWIPE_DIAG5 HIT", report);
        });
    }

    if (gr.state == UIGestureRecognizerStateEnded ||
        gr.state == UIGestureRecognizerStateCancelled ||
        gr.state == UIGestureRecognizerStateFailed) {

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gReportedThisGesture = NO;
        });
    }
}

@end

#pragma mark - Attach observers

static void WCRAttachRecursively(UIView *view, UITableView *table) {
    if (!view) return;

    if (view != table && !WCRIsDescendant(view, table)) return;

    for (UIGestureRecognizer *gr in view.gestureRecognizers) {
        if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) continue;

        @synchronized (gObservedRecognizers) {
            if (![gObservedRecognizers containsObject:gr]) {
                [gr addTarget:gObserver action:@selector(wcr_pan:)];
                [gObservedRecognizers addObject:gr];
            }
        }
    }

    for (UIView *sub in view.subviews) {
        WCRAttachRecursively(sub, table);
    }
}

static void WCRScan(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *table = WCRMainTable();

        if (!table) {
            if (showReady && !gReadyShown) {
                gReadyShown = YES;
                WCRShow(@"SWIPE_DIAG5 Ready",
                        @"MainFrameTableView not found.\n"
                         "Stay on the WeChat conversation home page.");
            }
            return;
        }

        WCRAttachRecursively(table, table);

        if (showReady && !gReadyShown) {
            gReadyShown = YES;

            NSMutableString *msg = [NSMutableString stringWithFormat:
                @"Table: %@\n"
                 "Delegate: %@\n"
                 "DataSource: %@\n\n"
                 "Visible cells: %lu\n\n"
                 "Tap OK, then left-swipe ONE normal ungrouped friend.\n\n"
                 "DIAG5 will report:\n"
                 "• NewMainFrameCell pan target/action\n"
                 "• Cell swipe/menu selectors\n"
                 "• MenuButton target/action\n"
                 "• MenuButton superview chain",
                 WCRClassName(table),
                 WCRClassName(table.delegate),
                 WCRClassName(table.dataSource),
                 (unsigned long)table.visibleCells.count];

            WCRShow(@"SWIPE_DIAG5 Ready", msg);
        }
    });
}

static void WCRRepeatScan(NSUInteger remaining) {
    if (remaining == 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCRScan(NO);
        WCRRepeatScan(remaining - 1);
    });
}

__attribute__((constructor))
static void WCRSwipeDiag5Init(void) {
    @autoreleasepool {
        gObservedRecognizers = [NSHashTable weakObjectsHashTable];
        gObserver = [WCRSwipeDiag5Observer new];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScan(YES);
            WCRRepeatScan(30);
        });
    }
}
