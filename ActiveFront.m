// ActiveFront.RIGHT_GROUP_UI_V1_6_LEADING_NATIVE.m
// WCRefineGroup - Native RIGHT-swipe "分组" proof
//
// Goal:
// - RIGHT swipe -> UIKit native leading swipe action: "分组"
// - LEFT swipe  -> WeChat original trailing actions remain untouched
// - No custom button under cell
// - No contentView.transform
// - No extra target attached to WeChat's pan gesture
//
// This build still DOES NOT modify real WCRefine grouping data.
// Tapping "分组" only shows a confirmation alert.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static const void *kWCRLeadingHookedKey      = &kWCRLeadingHookedKey;
static const void *kWCRLeadingOriginalIMPKey = &kWCRLeadingOriginalIMPKey;

static BOOL gReadyShown = NO;

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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.35 * NSEC_PER_SEC)),
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

static void WCRCollectTableViews(UIView *view, NSMutableArray *out) {
    if (!view || view.hidden || view.alpha <= 0.01) return;

    if ([view isKindOfClass:[UITableView class]] && view.window) {
        [out addObject:view];
    }

    for (UIView *sub in view.subviews) {
        WCRCollectTableViews(sub, out);
    }
}

static BOOL WCRIsMainFrameTable(UITableView *tableView) {
    if (!tableView) return NO;

    Class mainClass = NSClassFromString(@"MainFrameTableView");
    if (mainClass && [tableView isKindOfClass:mainClass]) {
        return YES;
    }

    return [WCRClassName(tableView) isEqualToString:@"MainFrameTableView"];
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

    // Important: never fall back to an arbitrary UITableView.
    // Hooking a random table delegate could contaminate other WeChat pages.
    return nil;
}

#pragma mark - Native leading swipe hook

typedef UISwipeActionsConfiguration *(*WCRLeadingActionsIMP)(
    id,
    SEL,
    UITableView *,
    NSIndexPath *
);

static IMP WCRStoredOriginalIMPForClass(Class cls) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        NSNumber *hooked = objc_getAssociatedObject((id)c, kWCRLeadingHookedKey);
        if (!hooked.boolValue) continue;

        NSValue *value = objc_getAssociatedObject((id)c, kWCRLeadingOriginalIMPKey);
        return value ? (IMP)[value pointerValue] : NULL;
    }
    return NULL;
}

static UISwipeActionsConfiguration *
WCRLeadingActionsHook(id self,
                      SEL _cmd,
                      UITableView *tableView,
                      NSIndexPath *indexPath) {

    UISwipeActionsConfiguration *originalConfig = nil;

    IMP originalIMP = WCRStoredOriginalIMPForClass([self class]);
    if (originalIMP && originalIMP != (IMP)WCRLeadingActionsHook) {
        originalConfig =
            ((WCRLeadingActionsIMP)originalIMP)(self, _cmd, tableView, indexPath);
    }

    // Only change WeChat's main conversation list.
    // Every other UITableView gets exactly the original delegate result.
    if (!WCRIsMainFrameTable(tableView)) {
        return originalConfig;
    }

    if (@available(iOS 11.0, *)) {
        __weak UITableView *weakTable = tableView;
        NSIndexPath *capturedIndexPath = [indexPath copy];

        UIContextualAction *groupAction =
            [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                    title:@"分组"
                                                  handler:^(
                UIContextualAction *action,
                UIView *sourceView,
                void (^completionHandler)(BOOL)) {

            // Tell UIKit the action completed so its native swipe container closes.
            if (completionHandler) {
                completionHandler(YES);
            }

            UITableView *strongTable = weakTable;
            UITableViewCell *cell =
                strongTable ? [strongTable cellForRowAtIndexPath:capturedIndexPath] : nil;

            NSString *message = [NSString stringWithFormat:
                @"原生右滑「分组」已经触发。\n\n"
                 "Table: %@\n"
                 "Cell: %@\n"
                 "Row: %ld\n\n"
                 "本版本只验证 leading swipe action。\n"
                 "尚未修改任何 WCRefine 分组数据。",
                 WCRClassName(strongTable),
                 WCRClassName(cell),
                 (long)capturedIndexPath.row];

            WCRShow(@"RIGHT_GROUP_UI_V1_6", message);
        }];

        // Approximate the blue action used by WeChat in the current UI.
        groupAction.backgroundColor =
            [UIColor colorWithRed:56.0/255.0
                            green:119.0/255.0
                             blue:198.0/255.0
                            alpha:1.0];

        NSMutableArray<UIContextualAction *> *actions =
            [NSMutableArray arrayWithObject:groupAction];

        // Preserve any leading action WeChat itself may provide on this version.
        // Our action is inserted without touching the trailing/left-swipe path.
        if (originalConfig.actions.count > 0) {
            [actions addObjectsFromArray:originalConfig.actions];
        }

        UISwipeActionsConfiguration *config =
            [UISwipeActionsConfiguration configurationWithActions:actions];

        // Prevent a long right swipe from immediately executing "分组".
        // The user must tap the revealed action.
        config.performsFirstActionWithFullSwipe = NO;

        return config;
    }

    return originalConfig;
}

static BOOL WCRInstallLeadingHookForDelegate(id delegate) {
    if (!delegate) return NO;

    Class cls = [delegate class];
    if (!cls) return NO;

    NSNumber *alreadyHooked =
        objc_getAssociatedObject((id)cls, kWCRLeadingHookedKey);
    if (alreadyHooked.boolValue) {
        return YES;
    }

    SEL sel =
        @selector(tableView:leadingSwipeActionsConfigurationForRowAtIndexPath:);

    Method resolvedMethod = class_getInstanceMethod(cls, sel);
    IMP originalIMP =
        resolvedMethod ? method_getImplementation(resolvedMethod) : NULL;

    // If the class inherits our hook from a delegate superclass that was already
    // patched, use that superclass's saved pre-hook implementation instead of
    // saving our hook as "original" and recursing.
    if (originalIMP == (IMP)WCRLeadingActionsHook) {
        originalIMP = WCRStoredOriginalIMPForClass(class_getSuperclass(cls));
    }

    const char *types =
        resolvedMethod ? method_getTypeEncoding(resolvedMethod) : "@@:@@";

    BOOL added =
        class_addMethod(cls, sel, (IMP)WCRLeadingActionsHook, types);

    if (!added) {
        // The delegate class already owns this method. Replace only this class's
        // implementation and preserve the exact previous IMP.
        IMP replaced =
            class_replaceMethod(cls, sel, (IMP)WCRLeadingActionsHook, types);

        if (replaced && replaced != (IMP)WCRLeadingActionsHook) {
            originalIMP = replaced;
        }
    }

    if (originalIMP && originalIMP != (IMP)WCRLeadingActionsHook) {
        objc_setAssociatedObject((id)cls,
                                 kWCRLeadingOriginalIMPKey,
                                 [NSValue valueWithPointer:originalIMP],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject((id)cls,
                                 kWCRLeadingOriginalIMPKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject((id)cls,
                             kWCRLeadingHookedKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return YES;
}

#pragma mark - Scan / attach

static void WCRScan(BOOL showReady) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *tableView = WCRMainTable();

        if (!tableView) {
            if (showReady && !gReadyShown) {
                gReadyShown = YES;
                WCRShow(@"RIGHT_GROUP_UI_V1_6 Ready",
                        @"MainFrameTableView not found.\n"
                         "没有修改任何其他 UITableView。");
            }
            return;
        }

        id delegate = tableView.delegate;
        Class delegateClass = delegate ? [delegate class] : Nil;
        BOOL wasAlreadyHooked = delegateClass
            ? [objc_getAssociatedObject((id)delegateClass,
                                        kWCRLeadingHookedKey) boolValue]
            : NO;

        BOOL hooked = WCRInstallLeadingHookForDelegate(delegate);

        if (hooked && !wasAlreadyHooked && tableView.delegate == delegate) {
            // UITableView caches which optional delegate methods are available
            // when setDelegate: runs. The leading-swipe method was added after
            // WeChat had already assigned its delegate, so refresh that cache
            // once without changing the actual delegate object.
            tableView.delegate = nil;
            tableView.delegate = delegate;
        }

        if (hooked) {
            [tableView setNeedsLayout];
            [tableView layoutIfNeeded];
        }

        if (showReady && !gReadyShown) {
            gReadyShown = YES;

            NSString *message = [NSString stringWithFormat:
                @"Table: %@\n"
                 "Delegate: %@\n"
                 "Hook: %@\n\n"
                 "本版结构：\n"
                 "右滑 = UIKit leadingSwipeActionsConfiguration\n"
                 "左滑 = 微信原生 trailing actions\n\n"
                 "已删除 v1.5 的：\n"
                 "• 自定义底层 UIButton\n"
                 "• contentView.transform\n"
                 "• 微信 pan gesture observer\n\n"
                 "点击「分组」仍只弹测试框，不改真实分组数据。",
                 WCRClassName(tableView),
                 WCRClassName(delegate),
                 hooked ? @"OK" : @"FAILED"];

            WCRShow(@"RIGHT_GROUP_UI_V1_6 Ready", message);
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRScan(YES);
            WCRRepeat(75);
        });
    }
}
