// ActiveFront.MIN_GROUP_UI_V1.m
// WCRefineGroup - Minimal native "分组" button proof
//
// Based on DIAG6:
// - NewMainFrameCell inherits MMMultiMenuTableViewCell / MMBaseMultiMenuTableViewCell.
// - Real menu model = MMMultiMenuItem.
// - _arrMenuItems and _currentMenuItems contain 3 native items.
// - Visible buttons all call NewMainFrameCell.onButtonClicked:.
//
// Goal of this build:
// - Keep the three native actions unchanged.
// - Append ONE native MMMultiMenuItem titled "分组" before "删除".
// - Intercept only taps on "分组" and show a diagnostic alert.
// - Do NOT perform real grouping yet.
//
// Important:
// This is still a minimal UI proof. It intentionally does not yet filter
// grouped vs. ungrouped sessions and does not modify WCRefine group data.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP gOrigSetArrMenuItems = NULL;
static IMP gOrigSetMenuItemsNoDelete = NULL;
static IMP gOrigSetMenuItemsDefaultDelete = NULL;
static IMP gOrigOnButtonClicked = NULL;

static BOOL gHookSetArr = NO;
static BOOL gHookNoDelete = NO;
static BOOL gHookDefaultDelete = NO;
static BOOL gHookButton = NO;

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

static NSString *WCRMenuItemTitle(id item) {
    if (!item) return nil;

    SEL getter = NSSelectorFromString(@"nsTitle");
    if ([item respondsToSelector:getter]) {
        NSString *(*fn)(id, SEL) = (NSString *(*)(id, SEL))objc_msgSend;
        id value = fn(item, getter);
        if ([value isKindOfClass:[NSString class]]) return value;
    }

    Ivar iv = class_getInstanceVariable([item class], "_nsTitle");
    if (iv) {
        id value = object_getIvar(item, iv);
        if ([value isKindOfClass:[NSString class]]) return value;
    }

    return nil;
}

static BOOL WCRArrayHasGroupItem(NSArray *items) {
    for (id item in items) {
        if ([[WCRMenuItemTitle(item) ?: @""] isEqualToString:@"分组"]) {
            return YES;
        }
    }
    return NO;
}

static void WCRSendObjectSetter(id obj, NSString *selectorName, id value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return;

    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    fn(obj, sel, value);
}

static void WCRSendDoubleSetter(id obj, NSString *selectorName, double value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return;

    void (*fn)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
    fn(obj, sel, value);
}

static void WCRSendBoolSetter(id obj, NSString *selectorName, BOOL value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return;

    void (*fn)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    fn(obj, sel, value);
}

static id WCRCreateGroupMenuItem(void) {
    Class itemClass = NSClassFromString(@"MMMultiMenuItem");
    if (!itemClass) return nil;

    id item = [[itemClass alloc] init];
    if (!item) return nil;

    WCRSendObjectSetter(item, @"setNsTitle:", @"分组");

    // DIAG5 showed the normal buttons are around 88–99 pt wide.
    WCRSendDoubleSetter(item, @"setMenuItemWidth:", 88.0);

    // Use a distinct color only for this proof build.
    UIColor *background = nil;
    if (@available(iOS 13.0, *)) {
        background = [UIColor systemGreenColor];
    } else {
        background = [UIColor colorWithRed:0.20 green:0.65 blue:0.35 alpha:1.0];
    }

    WCRSendObjectSetter(item, @"setBackgroundColor:", background);
    WCRSendObjectSetter(item, @"setTitleColor:", [UIColor whiteColor]);
    WCRSendDoubleSetter(item, @"setTitleFontSize:", 17.0);
    WCRSendBoolSetter(item, @"setBothShowIconAndTitle:", NO);

    return item;
}

static NSArray *WCRArrayByAddingGroupItem(id receiver, NSArray *items) {
    if (![items isKindOfClass:[NSArray class]]) return items;
    if (WCRArrayHasGroupItem(items)) return items;

    Class newMainFrameCell = NSClassFromString(@"NewMainFrameCell");
    if (!newMainFrameCell || ![receiver isKindOfClass:newMainFrameCell]) {
        return items;
    }

    id groupItem = WCRCreateGroupMenuItem();
    if (!groupItem) return items;

    NSMutableArray *result = [items mutableCopy];

    // Preserve Delete as the right-most / final action where possible.
    NSUInteger deleteIndex = NSNotFound;
    for (NSUInteger i = 0; i < result.count; i++) {
        NSString *title = WCRMenuItemTitle(result[i]) ?: @"";
        if ([title isEqualToString:@"删除"]) {
            deleteIndex = i;
            break;
        }
    }

    if (deleteIndex != NSNotFound) {
        [result insertObject:groupItem atIndex:deleteIndex];
    } else {
        [result addObject:groupItem];
    }

    return result;
}

#pragma mark - Menu array hooks

static void WCRSetArrMenuItemsHook(id self, SEL _cmd, id items) {
    NSArray *modified = WCRArrayByAddingGroupItem(self, items);

    if (gOrigSetArrMenuItems) {
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))gOrigSetArrMenuItems;
        fn(self, _cmd, modified);
    }
}

static void WCRSetMenuItemsNoDeleteHook(id self, SEL _cmd, id items) {
    NSArray *modified = WCRArrayByAddingGroupItem(self, items);

    if (gOrigSetMenuItemsNoDelete) {
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))gOrigSetMenuItemsNoDelete;
        fn(self, _cmd, modified);
    }
}

static void WCRSetMenuItemsDefaultDeleteHook(id self, SEL _cmd, id items) {
    NSArray *modified = WCRArrayByAddingGroupItem(self, items);

    if (gOrigSetMenuItemsDefaultDelete) {
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))gOrigSetMenuItemsDefaultDelete;
        fn(self, _cmd, modified);
    }
}

#pragma mark - Button click hook

static NSString *WCRButtonTitle(id button) {
    if (![button isKindOfClass:[UIButton class]]) return nil;

    UIButton *b = (UIButton *)button;
    NSString *title = [b titleForState:UIControlStateNormal];
    if (title.length) return title;

    for (UIView *sub in b.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            NSString *text = ((UILabel *)sub).text;
            if (text.length) return text;
        }
    }

    return nil;
}

static void WCROnButtonClickedHook(id self, SEL _cmd, id sender) {
    NSString *title = WCRButtonTitle(sender) ?: @"";

    if ([title isEqualToString:@"分组"]) {
        WCRShow(@"MIN_GROUP_UI_V1",
                [NSString stringWithFormat:
                    @"「分组」按钮已经进入微信原生左滑菜单。\n\n"
                     "Cell: %@\n"
                     "Button: %@\n\n"
                     "本版本只证明按钮插入与点击链路。\n"
                     "尚未执行真实分组操作。",
                     WCRClassName(self),
                     WCRClassName(sender)]);
        return;
    }

    // All original actions must remain native and untouched.
    if (gOrigOnButtonClicked) {
        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))gOrigOnButtonClicked;
        fn(self, _cmd, sender);
    }
}

#pragma mark - Hook installer

static BOOL WCRHookMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement || !originalOut) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP original = method_getImplementation(method);
    if (!original) return NO;

    *originalOut = original;
    method_setImplementation(method, replacement);

    return method_getImplementation(method) == replacement;
}

static void WCRInstallHooks(void) {
    Class base = NSClassFromString(@"MMBaseMultiMenuTableViewCell");
    Class cell = NSClassFromString(@"NewMainFrameCell");

    if (base) {
        gHookSetArr =
            WCRHookMethod(base,
                          NSSelectorFromString(@"setArrMenuItems:"),
                          (IMP)WCRSetArrMenuItemsHook,
                          &gOrigSetArrMenuItems);

        gHookNoDelete =
            WCRHookMethod(base,
                          NSSelectorFromString(@"setMenuItemsWithNoDeleteBtn:"),
                          (IMP)WCRSetMenuItemsNoDeleteHook,
                          &gOrigSetMenuItemsNoDelete);

        gHookDefaultDelete =
            WCRHookMethod(base,
                          NSSelectorFromString(@"setMenuItemsWithDefaultDeleteBtn:"),
                          (IMP)WCRSetMenuItemsDefaultDeleteHook,
                          &gOrigSetMenuItemsDefaultDelete);
    }

    if (cell) {
        gHookButton =
            WCRHookMethod(cell,
                          NSSelectorFromString(@"onButtonClicked:"),
                          (IMP)WCROnButtonClickedHook,
                          &gOrigOnButtonClicked);
    }

    NSString *msg = [NSString stringWithFormat:
        @"MMMultiMenuItem: %@\n"
         "NewMainFrameCell: %@\n\n"
         "setArrMenuItems hook: %@\n"
         "setMenuItemsWithNoDeleteBtn hook: %@\n"
         "setMenuItemsWithDefaultDeleteBtn hook: %@\n"
         "onButtonClicked hook: %@\n\n"
         "测试：找一个未分类普通好友左滑。\n"
         "预期看到：标为已读 / 不显示 / 分组 / 删除",
         NSClassFromString(@"MMMultiMenuItem") ? @"YES" : @"NO",
         cell ? @"YES" : @"NO",
         gHookSetArr ? @"YES" : @"NO",
         gHookNoDelete ? @"YES" : @"NO",
         gHookDefaultDelete ? @"YES" : @"NO",
         gHookButton ? @"YES" : @"NO"];

    WCRShow(@"MIN_GROUP_UI_V1 Ready", msg);
}

__attribute__((constructor))
static void WCRMinGroupUIInit(void) {
    @autoreleasepool {
        // Delay until WeChat/WCRefine classes are loaded.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRInstallHooks();
        });
    }
}
