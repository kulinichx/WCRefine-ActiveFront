#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

static NSString * const kDiagVersion = @"swipe-diag-2";

static void DLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void DLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[WCRefineGroup DIAG %@] %@", kDiagVersion, msg);
}

typedef id (*ObjcIdMsgSend0)(id, SEL);
typedef id (*ObjcIdMsgSend1)(id, SEL, id);
typedef id (*SwipeIMP)(id, SEL, id, id);

static SwipeIMP gOrigModern = NULL;
static SwipeIMP gOrigLegacy = NULL;
static BOOL gModernInstalled = NO;
static BOOL gLegacyInstalled = NO;
static BOOL gAlertShown = NO;

static UIViewController *TopViewController(void) {
    UIWindow *window = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
            if (window) break;
        }
    }

    if (!window) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        window = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }

    UIViewController *vc = window.rootViewController;
    if (!vc) return nil;

    BOOL changed = YES;
    while (changed) {
        changed = NO;
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
            changed = YES;
            continue;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *next = ((UINavigationController *)vc).visibleViewController;
            if (next && next != vc) {
                vc = next;
                changed = YES;
                continue;
            }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *next = ((UITabBarController *)vc).selectedViewController;
            if (next && next != vc) {
                vc = next;
                changed = YES;
                continue;
            }
        }
    }
    return vc;
}

static id Call0(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((ObjcIdMsgSend0)objc_msgSend)(obj, sel);
}

static id Call1(id obj, SEL sel, id arg) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((ObjcIdMsgSend1)objc_msgSend)(obj, sel, arg);
}

static id SessionAtIndexPath(id host, NSIndexPath *indexPath, NSString **usedSelector) {
    SEL nativeSel = NSSelectorFromString(@"logicGetSessionAtIndexPath:");
    if ([host respondsToSelector:nativeSel]) {
        if (usedSelector) *usedSelector = NSStringFromSelector(nativeSel);
        return Call1(host, nativeSel, indexPath);
    }

    SEL aliasSel = NSSelectorFromString(@"wcrGrouping_logicGetSessionAtIndexPath:");
    if ([host respondsToSelector:aliasSel]) {
        if (usedSelector) *usedSelector = NSStringFromSelector(aliasSel);
        return Call1(host, aliasSel, indexPath);
    }

    if (usedSelector) *usedSelector = @"<none>";
    return nil;
}

static NSString *UsernameForSession(id session) {
    if (!session) return nil;

    Class providerClass = NSClassFromString(@"WCRefineGroupDataProvider");
    if (providerClass) {
        id provider = Call0(providerClass, NSSelectorFromString(@"shared"));
        NSString *username = Call1(provider,
                                   NSSelectorFromString(@"usernameForNativeObject:"),
                                   session);
        if ([username isKindOfClass:[NSString class]] && username.length > 0) {
            return username;
        }
    }

    // Diagnostic fallbacks only; no business logic depends on these.
    NSArray<NSString *> *selectors = @[
        @"username", @"userName", @"m_nsUsrName", @"m_nsUserName",
        @"sessionUserName", @"contactUserName"
    ];

    for (NSString *name in selectors) {
        id value = Call0(session, NSSelectorFromString(name));
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }

    return nil;
}

static void ShowSwipeDiagnostic(NSString *path,
                                id host,
                                UITableView *tableView,
                                NSIndexPath *indexPath,
                                id session,
                                NSString *lookupSel,
                                id originalResult) {
    NSString *sessionClass = session ? NSStringFromClass([session class]) : @"<nil>";
    NSString *username = UsernameForSession(session) ?: @"<nil>";
    NSString *hostClass = host ? NSStringFromClass([host class]) : @"<nil>";
    NSString *tableClass = tableView ? NSStringFromClass([tableView class]) : @"<nil>";
    NSString *resultClass = originalResult ? NSStringFromClass([originalResult class]) : @"<nil>";

    DLog(@"SWIPE ENTERED path=%@ host=%@ table=%@ section=%ld row=%ld lookup=%@ session=%p sessionClass=%@ username=%@ originalClass=%@",
         path,
         hostClass,
         tableClass,
         (long)indexPath.section,
         (long)indexPath.row,
         lookupSel ?: @"<nil>",
         session,
         sessionClass,
         username,
         resultClass);

    if (gAlertShown) return;
    gAlertShown = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *message = [NSString stringWithFormat:
            @"PATH: %@\n\n"
             "Host: %@\n"
             "Table: %@\n"
             "IndexPath: section=%ld row=%ld\n\n"
             "Session lookup: %@\n"
             "Session: %@\n"
             "Session class: %@\n"
             "Username: %@\n\n"
             "Original result: %@\n\n"
             "modern hook: %@\n"
             "legacy hook: %@",
             path,
             hostClass,
             tableClass,
             (long)indexPath.section,
             (long)indexPath.row,
             lookupSel ?: @"<nil>",
             session ? @"YES" : @"NO",
             sessionClass,
             username,
             resultClass,
             gModernInstalled ? @"YES" : @"NO",
             gLegacyInstalled ? @"YES" : @"NO"];

        UIViewController *vc = TopViewController();
        if (!vc) {
            DLog(@"cannot display swipe diagnostic alert: top VC missing");
            return;
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"WCRefineGroup Swipe Diagnostic"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static id HookModern(id self, SEL _cmd, id tableViewObj, id indexPathObj) {
    id original = gOrigModern ? gOrigModern(self, _cmd, tableViewObj, indexPathObj) : nil;

    UITableView *tableView =
        [tableViewObj isKindOfClass:[UITableView class]] ? tableViewObj : nil;
    NSIndexPath *indexPath =
        [indexPathObj isKindOfClass:[NSIndexPath class]] ? indexPathObj : nil;

    NSString *lookup = nil;
    id session = indexPath ? SessionAtIndexPath(self, indexPath, &lookup) : nil;

    ShowSwipeDiagnostic(@"MODERN",
                        self,
                        tableView,
                        indexPath ?: [NSIndexPath indexPathForRow:0 inSection:0],
                        session,
                        lookup,
                        original);

    // Do not modify WCRefine/WeChat actions in this diagnostic build.
    return original;
}

static id HookLegacy(id self, SEL _cmd, id tableViewObj, id indexPathObj) {
    id original = gOrigLegacy ? gOrigLegacy(self, _cmd, tableViewObj, indexPathObj) : nil;

    UITableView *tableView =
        [tableViewObj isKindOfClass:[UITableView class]] ? tableViewObj : nil;
    NSIndexPath *indexPath =
        [indexPathObj isKindOfClass:[NSIndexPath class]] ? indexPathObj : nil;

    NSString *lookup = nil;
    id session = indexPath ? SessionAtIndexPath(self, indexPath, &lookup) : nil;

    ShowSwipeDiagnostic(@"LEGACY",
                        self,
                        tableView,
                        indexPath ?: [NSIndexPath indexPathForRow:0 inSection:0],
                        session,
                        lookup,
                        original);

    // Do not modify WCRefine/WeChat actions in this diagnostic build.
    return original;
}

static BOOL InstallHook(Class cls,
                        SEL sel,
                        IMP replacement,
                        SwipeIMP *origOut,
                        BOOL *flag,
                        NSString *label) {
    if (*flag) return YES;
    if (!cls) {
        DLog(@"install %@ failed: class missing", label);
        return NO;
    }

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        DLog(@"install %@ failed: selector missing", label);
        return NO;
    }

    IMP current = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);

    if (!current || !types) {
        DLog(@"install %@ failed: invalid IMP/types", label);
        return NO;
    }

    *origOut = (SwipeIMP)current;
    class_replaceMethod(cls, sel, replacement, types);

    Method verify = class_getInstanceMethod(cls, sel);
    BOOL ok = verify && method_getImplementation(verify) == replacement;

    if (ok) {
        *flag = YES;
        DLog(@"installed %@ selector=%@ oldIMP=%p newIMP=%p types=%s",
             label, NSStringFromSelector(sel), current, replacement, types);
    } else {
        DLog(@"install %@ verification FAILED", label);
    }

    return ok;
}

static void InstallSwipeDiagnostics(void) {
    Class mainFrame = NSClassFromString(@"NewMainFrameViewController");
    if (!mainFrame) {
        DLog(@"NewMainFrameViewController missing");
        return;
    }

    BOOL modern = InstallHook(
        mainFrame,
        NSSelectorFromString(@"tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:"),
        (IMP)HookModern,
        &gOrigModern,
        &gModernInstalled,
        @"modern/native");

    BOOL legacy = InstallHook(
        mainFrame,
        NSSelectorFromString(@"tableView:editActionsForRowAtIndexPath:"),
        (IMP)HookLegacy,
        &gOrigLegacy,
        &gLegacyInstalled,
        @"legacy/native");

    DLog(@"INSTALL RESULT modern=%d legacy=%d logicNative=%d logicAlias=%d",
         modern,
         legacy,
         [mainFrame instancesRespondToSelector:NSSelectorFromString(@"logicGetSessionAtIndexPath:")],
         [mainFrame instancesRespondToSelector:NSSelectorFromString(@"wcrGrouping_logicGetSessionAtIndexPath:")]);

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = TopViewController();
        if (!vc) return;

        NSString *message = [NSString stringWithFormat:
            @"modern/native hook: %@\n"
             "legacy/native hook: %@\n\n"
             "Now tap OK and left-swipe ONE normal ungrouped friend.",
             modern ? @"YES" : @"NO",
             legacy ? @"YES" : @"NO"];

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Swipe Diagnostic Ready"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

__attribute__((constructor))
static void WCRefineGroupDiagEntry(void) {
    @autoreleasepool {
        DLog(@"constructor entered");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            InstallSwipeDiagnostics();
        });
    }
}
