// ActiveFront.SWIPE_DIAG6.m
// WCRefineGroup - Swipe Diagnostic 6
//
// DIAG5 established the real menu stack:
//   NewMainFrameCell -> MMMultiMenuTableViewCell -> MMBaseMultiMenuTableViewCell
//   NewMainFrameCell.handlePan:
//   MenuButton -> NewMainFrameCell.onButtonClicked:
//
// DIAG6 goal:
//   Inspect the REAL menu model objects and menu-related ivars without changing behavior.
//   We need this before inserting a native "分组" item.
//
// What DIAG6 reports after one left swipe:
//   1) menu-related ivars on NewMainFrameCell and superclasses
//   2) arrays/collections that contain menu item model objects
//   3) each menu item class + useful selector inventory
//   4) MenuButton runtime ivars and target/action
//
// Diagnostic only. It does NOT add/execute any menu action.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSHashTable *gObservedRecognizers;
static id gObserver;
static BOOL gReadyShown = NO;
static BOOL gReported = NO;

#pragma mark - Generic helpers

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

#pragma mark - Runtime reading

static id WCRReadObjectIvar(id obj, Ivar iv) {
    if (!obj || !iv) return nil;
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') return nil;

    @try {
        return object_getIvar(obj, iv);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL WCRNameLooksMenuRelated(NSString *name) {
    NSString *s = name.lowercaseString;
    return [s containsString:@"menu"] ||
           [s containsString:@"item"] ||
           [s containsString:@"button"] ||
           [s containsString:@"action"] ||
           [s containsString:@"option"] ||
           [s containsString:@"more"] ||
           [s containsString:@"edit"] ||
           [s containsString:@"delete"];
}

static NSString *WCRSafeDescription(id obj) {
    if (!obj) return @"<nil>";

    if ([obj isKindOfClass:[NSString class]] ||
        [obj isKindOfClass:[NSNumber class]]) {
        NSString *d = [obj description];
        return d.length > 120 ? [[d substringToIndex:120] stringByAppendingString:@"…"] : d;
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"NSArray count=%lu", (unsigned long)[(NSArray *)obj count]];
    }

    if ([obj isKindOfClass:[NSSet class]]) {
        return [NSString stringWithFormat:@"NSSet count=%lu", (unsigned long)[(NSSet *)obj count]];
    }

    if ([obj isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"NSDictionary count=%lu", (unsigned long)[(NSDictionary *)obj count]];
    }

    return [NSString stringWithFormat:@"<%@ %p>", WCRClassName(obj), obj];
}

static NSArray<NSString *> *WCRInterestingMethods(Class cls, NSUInteger limit) {
    NSMutableOrderedSet *items = [NSMutableOrderedSet orderedSet];

    Class c = cls;
    NSInteger depth = 0;

    while (c && depth < 4) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);

        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if (!WCRNameLooksMenuRelated(name) &&
                ![name.lowercaseString containsString:@"title"] &&
                ![name.lowercaseString containsString:@"color"] &&
                ![name.lowercaseString containsString:@"handler"] &&
                ![name.lowercaseString containsString:@"target"] &&
                ![name.lowercaseString containsString:@"selector"] &&
                ![name.lowercaseString containsString:@"block"]) {
                continue;
            }

            [items addObject:
                [NSString stringWithFormat:@"%@.%@", NSStringFromClass(c), name]];
        }

        if (methods) free(methods);
        c = class_getSuperclass(c);
        depth++;
    }

    NSArray *all = items.array;
    if (all.count <= limit) return all;
    return [all subarrayWithRange:NSMakeRange(0, limit)];
}

static NSString *WCRObjectIvarSummary(id obj, NSUInteger maxLines) {
    if (!obj) return @"<nil>";

    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    Class c = [obj class];
    NSInteger depth = 0;

    while (c && depth < 5 && lines.count < maxLines) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);

        for (unsigned int i = 0; i < count && lines.count < maxLines; i++) {
            Ivar iv = ivars[i];
            NSString *name = [NSString stringWithUTF8String:ivar_getName(iv) ?: ""];
            if (!WCRNameLooksMenuRelated(name) &&
                ![name.lowercaseString containsString:@"title"] &&
                ![name.lowercaseString containsString:@"color"] &&
                ![name.lowercaseString containsString:@"tag"] &&
                ![name.lowercaseString containsString:@"type"] &&
                ![name.lowercaseString containsString:@"block"] &&
                ![name.lowercaseString containsString:@"target"] &&
                ![name.lowercaseString containsString:@"selector"]) {
                continue;
            }

            const char *type = ivar_getTypeEncoding(iv);
            NSString *typeStr = type ? [NSString stringWithUTF8String:type] : @"?";

            if (type && type[0] == '@') {
                id value = WCRReadObjectIvar(obj, iv);
                [lines addObject:
                    [NSString stringWithFormat:@"%@.%@ (%@) = %@",
                     NSStringFromClass(c), name, typeStr, WCRSafeDescription(value)]];
            } else {
                [lines addObject:
                    [NSString stringWithFormat:@"%@.%@ (%@)",
                     NSStringFromClass(c), name, typeStr]];
            }
        }

        if (ivars) free(ivars);
        c = class_getSuperclass(c);
        depth++;
    }

    if (lines.count == 0) return @"<no matching ivars>";
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Discover menu-model collections

static void WCRAppendCollectionDetails(NSMutableString *out,
                                       NSString *ownerClass,
                                       NSString *ivarName,
                                       id collection) {
    NSArray *array = nil;

    if ([collection isKindOfClass:[NSArray class]]) {
        array = collection;
    } else if ([collection isKindOfClass:[NSSet class]]) {
        array = [(NSSet *)collection allObjects];
    } else {
        return;
    }

    if (array.count == 0) return;

    [out appendFormat:@"\nCOLLECTION %@.%@ count=%lu\n",
     ownerClass, ivarName, (unsigned long)array.count];

    NSUInteger limit = MIN((NSUInteger)8, array.count);

    for (NSUInteger i = 0; i < limit; i++) {
        id item = array[i];

        [out appendFormat:
            @"\n  [%lu] class=%@\n"
             "  ivars:\n%@\n"
             "  selectors:\n%@\n",
             (unsigned long)i,
             WCRClassName(item),
             WCRObjectIvarSummary(item, 18),
             ([WCRInterestingMethods([item class], 18)
               componentsJoinedByString:@"\n"] ?: @"<none>")];
    }
}

static NSString *WCRCellMenuModelReport(id cell) {
    NSMutableString *out = [NSMutableString string];

    [out appendString:@"CELL MENU IVARS:\n"];
    [out appendString:WCRObjectIvarSummary(cell, 60)];
    [out appendString:@"\n"];

    Class c = [cell class];
    NSInteger depth = 0;

    while (c && depth < 6) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);

        for (unsigned int i = 0; i < count; i++) {
            Ivar iv = ivars[i];
            NSString *name = [NSString stringWithUTF8String:ivar_getName(iv) ?: ""];
            if (!WCRNameLooksMenuRelated(name)) continue;

            id value = WCRReadObjectIvar(cell, iv);
            if (!value) continue;

            WCRAppendCollectionDetails(out, NSStringFromClass(c), name, value);
        }

        if (ivars) free(ivars);
        c = class_getSuperclass(c);
        depth++;
    }

    return out;
}

#pragma mark - Visible buttons

static void WCRCollectMenuButtons(UIView *view, NSMutableArray<UIButton *> *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)view;
        NSString *cls = WCRClassName(b);
        NSString *text = WCRButtonText(b);

        if ([cls containsString:@"MenuButton"] ||
            [text containsString:@"已读"] ||
            [text containsString:@"不显示"] ||
            [text containsString:@"删除"]) {
            [out addObject:b];
        }
    }

    for (UIView *sub in view.subviews) {
        WCRCollectMenuButtons(sub, out);
    }
}

static NSArray<UIButton *> *WCRButtonsForCell(UITableViewCell *cell) {
    NSMutableArray<UIButton *> *arr = [NSMutableArray array];

    WCRCollectMenuButtons(cell, arr);

    if (cell.superview) {
        for (UIView *sub in cell.superview.subviews) {
            if (sub == cell) continue;
            WCRCollectMenuButtons(sub, arr);
        }
    }

    return [NSMutableOrderedSet orderedSetWithArray:arr].array;
}

static NSString *WCRButtonTargets(UIButton *button) {
    NSMutableArray *lines = [NSMutableArray array];

    for (id target in button.allTargets) {
        NSArray *actions = [button actionsForTarget:target
                                   forControlEvent:UIControlEventTouchUpInside];

        if (actions.count == 0) {
            [lines addObject:
                [NSString stringWithFormat:@"target=%@ action=<none>",
                 WCRClassName(target)]];
        } else {
            for (NSString *action in actions) {
                [lines addObject:
                    [NSString stringWithFormat:@"target=%@ action=%@",
                     WCRClassName(target), action]];
            }
        }
    }

    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"<none>";
}

static NSString *WCRButtonsReport(UITableViewCell *cell) {
    NSArray<UIButton *> *buttons = WCRButtonsForCell(cell);
    NSMutableString *out =
        [NSMutableString stringWithFormat:@"VISIBLE BUTTONS: %lu\n",
         (unsigned long)buttons.count];

    NSUInteger index = 0;
    for (UIButton *b in buttons) {
        index++;

        [out appendFormat:
            @"\n[%lu] %@ text=\"%@\"\n"
             "targets:\n%@\n"
             "button ivars:\n%@\n",
             (unsigned long)index,
             WCRClassName(b),
             WCRButtonText(b),
             WCRButtonTargets(b),
             WCRObjectIvarSummary(b, 24)];
    }

    return out;
}

#pragma mark - Observer

@interface WCRSwipeDiag6Observer : NSObject
- (void)wcr_pan:(UIPanGestureRecognizer *)pan;
@end

@implementation WCRSwipeDiag6Observer

- (void)wcr_pan:(UIPanGestureRecognizer *)pan {
    UITableView *table = WCRNearestTable(pan.view);

    if (!table) {
        UITableView *main = WCRMainTable();
        if (main && WCRIsDescendant(pan.view, main)) table = main;
    }

    if (!table) return;

    CGPoint tr = [pan translationInView:table];

    BOOL left = tr.x < -15.0 && fabs(tr.x) > fabs(tr.y) * 1.1;

    if ((pan.state == UIGestureRecognizerStateChanged ||
         pan.state == UIGestureRecognizerStateEnded) &&
        left &&
        !gReported) {

        gReported = YES;

        CGPoint point = [pan locationInView:table];
        NSIndexPath *ip = [table indexPathForRowAtPoint:point];
        UITableViewCell *cell = ip ? [table cellForRowAtIndexPath:ip] : nil;

        if ([pan.view isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell *)pan.view;
            NSIndexPath *real = [table indexPathForCell:cell];
            if (real) ip = real;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.38 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSMutableString *report = [NSMutableString stringWithFormat:
                @"Table: %@\n"
                 "IndexPath: %@\n"
                 "Cell: %@\n"
                 "Cell.super: %@\n\n",
                 WCRClassName(table),
                 ip ? [NSString stringWithFormat:@"section=%ld row=%ld",
                       (long)ip.section, (long)ip.row] : @"<nil>",
                 WCRClassName(cell),
                 cell ? NSStringFromClass(class_getSuperclass([cell class])) : @"<nil>"];

            if (cell) {
                [report appendString:WCRCellMenuModelReport(cell)];
                [report appendString:@"\n\n"];
                [report appendString:WCRButtonsReport(cell)];
            }

            WCRShow(@"SWIPE_DIAG6 HIT", report);
        });
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gReported = NO;
        });
    }
}

@end

#pragma mark - Attach to real cell pan recognizers

static void WCRAttachToView(UIView *view, UITableView *table) {
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
        WCRAttachToView(sub, table);
    }
}

static void WCRScan(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *table = WCRMainTable();

        if (!table) {
            if (showReady && !gReadyShown) {
                gReadyShown = YES;
                WCRShow(@"SWIPE_DIAG6 Ready",
                        @"MainFrameTableView not found.");
            }
            return;
        }

        WCRAttachToView(table, table);

        if (showReady && !gReadyShown) {
            gReadyShown = YES;

            NSString *msg = [NSString stringWithFormat:
                @"Table: %@\n"
                 "Delegate: %@\n"
                 "Visible cells: %lu\n\n"
                 "DIAG5 confirmed:\n"
                 "NewMainFrameCell.handlePan:\n"
                 "MenuButton -> NewMainFrameCell.onButtonClicked:\n\n"
                 "DIAG6 now inspects the menu MODEL objects.\n\n"
                 "Tap OK, then left-swipe ONE normal ungrouped friend.\n"
                 "Do NOT tap any existing action button.",
                 WCRClassName(table),
                 WCRClassName(table.delegate),
                 (unsigned long)table.visibleCells.count];

            WCRShow(@"SWIPE_DIAG6 Ready", msg);
        }
    });
}

static void WCRRepeat(NSUInteger remaining) {
    if (remaining == 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCRScan(NO);
        WCRRepeat(remaining - 1);
    });
}

__attribute__((constructor))
static void WCRSwipeDiag6Init(void) {
    @autoreleasepool {
        gObservedRecognizers = [NSHashTable weakObjectsHashTable];
        gObserver = [WCRSwipeDiag6Observer new];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScan(YES);
            WCRRepeat(30);
        });
    }
}
