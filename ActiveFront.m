// ActiveFront.SWIPE_DIAG3.m
// WCRefineGroup - Swipe Diagnostic 3
//
// Purpose:
// 1) Find the actual visible UITableView(s) on WeChat home.
// 2) Inspect their real delegate / dataSource classes.
// 3) Determine who implements the modern/legacy swipe selectors.
// 4) Dynamically hook the REAL delegate class, not NewMainFrameViewController by assumption.
// 5) On a left swipe, show which path/receiver actually executed.
//
// This is diagnostic-only. It does NOT add "分组 / 保持 / 回组".

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static SEL kModernSEL;
static SEL kLegacySEL;

static NSMutableDictionary<NSString *, NSValue *> *gOriginalIMPs;
static NSMutableSet<NSString *> *gHookedKeys;
static BOOL gReadyShown = NO;
static NSInteger gSwipeHitCount = 0;

#pragma mark - Utilities

static NSString *WCRClassName(id obj) {
    return obj ? NSStringFromClass([obj class]) : @"<nil>";
}

static NSString *WCRKeyForClassAndSEL(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static void WCRStoreOriginalIMP(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    @synchronized (gOriginalIMPs) {
        gOriginalIMPs[WCRKeyForClassAndSEL(cls, sel)] = [NSValue valueWithPointer:imp];
    }
}

static IMP WCRFindOriginalIMP(Class cls, SEL sel) {
    Class c = cls;
    @synchronized (gOriginalIMPs) {
        while (c) {
            NSValue *v = gOriginalIMPs[WCRKeyForClassAndSEL(c, sel)];
            if (v) return [v pointerValue];
            c = class_getSuperclass(c);
        }
    }
    return NULL;
}

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

static UIViewController *WCRTopViewController(void) {
    UIWindow *target = nil;

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.hidden && w.alpha > 0.01 && w.windowLevel == UIWindowLevelNormal) {
            if (w.isKeyWindow) {
                target = w;
                break;
            }
            if (!target) target = w;
        }
    }

    UIViewController *vc = target.rootViewController;
    if (!vc) return nil;

    BOOL changed = YES;
    while (changed) {
        changed = NO;

        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
            vc = vc.presentedViewController;
            changed = YES;
            continue;
        }

        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *next = [(UINavigationController *)vc visibleViewController];
            if (next && next != vc) {
                vc = next;
                changed = YES;
                continue;
            }
        }

        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *next = [(UITabBarController *)vc selectedViewController];
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

        // Avoid trying to present on top of one of our own alerts.
        if ([vc isKindOfClass:[UIAlertController class]]) return;

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

#pragma mark - Swipe replacement

static id WCRSwipeReplacement(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    IMP orig = WCRFindOriginalIMP(object_getClass(self), _cmd);
    id result = nil;

    if (orig) {
        id (*fn)(id, SEL, UITableView *, NSIndexPath *) =
            (id (*)(id, SEL, UITableView *, NSIndexPath *))orig;
        result = fn(self, _cmd, tableView, indexPath);
    }

    NSInteger hit = ++gSwipeHitCount;
    if (hit <= 8) {
        NSString *path = (_cmd == kModernSEL) ? @"MODERN" :
                         (_cmd == kLegacySEL) ? @"LEGACY" : @"UNKNOWN";

        id delegate = tableView.delegate;

        NSString *msg = [NSString stringWithFormat:
            @"PATH: %@\n\n"
             "Receiver: %@\n"
             "Receiver.super: %@\n\n"
             "Table: %@\n"
             "Delegate now: %@\n"
             "DataSource: %@\n\n"
             "IndexPath: section=%ld row=%ld\n\n"
             "Selector owner (runtime): %@\n"
             "Hit: %ld",
             path,
             WCRClassName(self),
             NSStringFromClass(class_getSuperclass([self class])) ?: @"<nil>",
             WCRClassName(tableView),
             WCRClassName(delegate),
             WCRClassName(tableView.dataSource),
             (long)indexPath.section,
             (long)indexPath.row,
             WCRMethodOwner([self class], _cmd),
             (long)hit];

        WCRShowAlert(@"SWIPE_DIAG3 HIT", msg);
    }

    return result;
}

#pragma mark - Hook actual delegate class

static BOOL WCRHookSelectorOnClass(Class cls, SEL sel) {
    if (!cls || !sel) return NO;

    NSString *key = WCRKeyForClassAndSEL(cls, sel);

    @synchronized (gHookedKeys) {
        if ([gHookedKeys containsObject:key]) return YES;
    }

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP oldIMP = method_getImplementation(method);
    IMP newIMP = (IMP)WCRSwipeReplacement;

    // If the effective method is already our replacement (for example because
    // a hooked superclass supplies it), do not hook again.
    if (oldIMP == newIMP) {
        @synchronized (gHookedKeys) {
            [gHookedKeys addObject:key];
        }
        return YES;
    }

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    WCRStoreOriginalIMP(cls, sel, oldIMP);

    // If the selector is inherited, add an override to THIS concrete delegate
    // class. If it is implemented directly, replace that implementation.
    BOOL added = class_addMethod(cls, sel, newIMP, types);
    if (!added) {
        class_replaceMethod(cls, sel, newIMP, types);
    }

    IMP effective = class_getMethodImplementation(cls, sel);
    BOOL ok = (effective == newIMP);

    if (ok) {
        @synchronized (gHookedKeys) {
            [gHookedKeys addObject:key];
        }
    }

    return ok;
}

#pragma mark - Find visible UITableViews

static void WCRCollectTableViews(UIView *view, NSMutableArray<UITableView *> *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;

    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)view;
        if (tv.window) {
            [out addObject:tv];
        }
    }

    for (UIView *sub in view.subviews) {
        WCRCollectTableViews(sub, out);
    }
}

static NSArray<UITableView *> *WCRVisibleTableViews(void) {
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha <= 0.01) continue;
        WCRCollectTableViews(w, tables);
    }

    return tables;
}

static NSString *WCRYESNO(BOOL value) {
    return value ? @"YES" : @"NO";
}

static void WCRScanAndHook(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UITableView *> *tables = WCRVisibleTableViews();

        NSMutableArray<NSString *> *blocks = [NSMutableArray array];
        NSMutableSet<NSString *> *seenDelegateClasses = [NSMutableSet set];

        for (UITableView *tv in tables) {
            id delegate = tv.delegate;
            if (!delegate) continue;

            Class dcls = [delegate class];
            NSString *dname = NSStringFromClass(dcls);
            if ([seenDelegateClasses containsObject:dname]) continue;
            [seenDelegateClasses addObject:dname];

            BOOL modernResponds = [delegate respondsToSelector:kModernSEL];
            BOOL legacyResponds = [delegate respondsToSelector:kLegacySEL];

            NSString *modernOwnerBefore = modernResponds ? WCRMethodOwner(dcls, kModernSEL) : @"<none>";
            NSString *legacyOwnerBefore = legacyResponds ? WCRMethodOwner(dcls, kLegacySEL) : @"<none>";

            BOOL modernHook = modernResponds ? WCRHookSelectorOnClass(dcls, kModernSEL) : NO;
            BOOL legacyHook = legacyResponds ? WCRHookSelectorOnClass(dcls, kLegacySEL) : NO;

            NSString *block = [NSString stringWithFormat:
                @"Table: %@\n"
                 "delegate: %@\n"
                 "dataSource: %@\n"
                 "modern: %@  owner=%@  hook=%@\n"
                 "legacy: %@  owner=%@  hook=%@",
                 WCRClassName(tv),
                 dname,
                 WCRClassName(tv.dataSource),
                 WCRYESNO(modernResponds),
                 modernOwnerBefore,
                 WCRYESNO(modernHook),
                 WCRYESNO(legacyResponds),
                 legacyOwnerBefore,
                 WCRYESNO(legacyHook)];

            [blocks addObject:block];
        }

        if (showReady && !gReadyShown) {
            gReadyShown = YES;

            NSString *body = nil;
            if (blocks.count == 0) {
                body = [NSString stringWithFormat:
                    @"Visible UITableViews: %lu\n\n"
                     "No visible table delegate was found.\n"
                     "Keep WeChat on the conversation home page and reopen it.",
                     (unsigned long)tables.count];
            } else {
                // Keep the alert readable. First 6 unique delegate classes are enough.
                NSUInteger limit = MIN((NSUInteger)6, blocks.count);
                NSArray *shown = [blocks subarrayWithRange:NSMakeRange(0, limit)];
                body = [NSString stringWithFormat:
                    @"Visible UITableViews: %lu\n"
                     "Unique delegates: %lu\n\n%@\n\n"
                     "Tap OK, then left-swipe ONE normal ungrouped friend.",
                     (unsigned long)tables.count,
                     (unsigned long)blocks.count,
                     [shown componentsJoinedByString:@"\n\n---\n\n"]];
            }

            WCRShowAlert(@"SWIPE_DIAG3 Ready", body);
        }
    });
}

#pragma mark - Periodic scan

static void WCRScheduleScan(NSUInteger remaining) {
    if (remaining == 0) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCRScanAndHook(NO);
        WCRScheduleScan(remaining - 1);
    });
}

__attribute__((constructor))
static void WCRSwipeDiag3Init(void) {
    @autoreleasepool {
        kModernSEL = NSSelectorFromString(@"tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:");
        kLegacySEL = NSSelectorFromString(@"tableView:editActionsForRowAtIndexPath:");

        gOriginalIMPs = [NSMutableDictionary dictionary];
        gHookedKeys = [NSMutableSet set];

        // Give WeChat/WCRefine enough time to finish constructing the home UI.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScanAndHook(YES);

            // Continue scanning for ~30 seconds so a delegate created slightly
            // later is still discovered and hooked.
            WCRScheduleScan(20);
        });
    }
}
