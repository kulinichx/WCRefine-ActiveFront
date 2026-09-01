#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSString * const kProbeVersion = @"integration-probe-1";

static void ProbeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void ProbeLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[WCRefineGroup PROBE %@] %@", kProbeVersion, msg);
}

static NSString *FindLoadedImage(NSString *needle) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cname = _dyld_get_image_name(i);
        if (!cname) continue;
        NSString *name = [NSString stringWithUTF8String:cname];
        if ([name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return name;
        }
    }
    return nil;
}

static BOOL ClassExists(NSString *name) {
    return NSClassFromString(name) != Nil;
}

static BOOL InstanceSelectorExists(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    return cls && class_getInstanceMethod(cls, sel) != NULL;
}

static NSString *MethodInfo(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls) return [NSString stringWithFormat:@"%@: class missing", selectorName];

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return [NSString stringWithFormat:@"%@: selector missing", selectorName];

    IMP imp = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    return [NSString stringWithFormat:@"%@: YES imp=%p types=%s",
            selectorName, imp, types ?: "<nil>"];
}

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
    while (vc.presentedViewController) vc = vc.presentedViewController;

    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).visibleViewController ?: vc;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = ((UITabBarController *)vc).selectedViewController ?: vc;
    }
    return vc;
}

static void ShowProbeAlert(NSString *message) {
    UIViewController *vc = TopViewController();
    if (!vc) {
        ProbeLog(@"cannot show alert: no foreground root view controller");
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"WCRefineGroup Integration Probe"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void RunProbe(void) {
    NSString *selfImage = FindLoadedImage(@"WCRefineGroup");
    NSString *wcrImage = FindLoadedImage(@"WCRefine.dylib");

    BOOL manager = ClassExists(@"WCRefineGroupManager");
    BOOL provider = ClassExists(@"WCRefineGroupDataProvider");
    BOOL quick = ClassExists(@"WCRQuickChatRuntime");
    BOOL main = ClassExists(@"NewMainFrameViewController");

    BOOL logic = InstanceSelectorExists(@"NewMainFrameViewController",
                                        @"logicGetSessionAtIndexPath:");
    BOOL logicAlias = InstanceSelectorExists(@"NewMainFrameViewController",
                                             @"wcrGrouping_logicGetSessionAtIndexPath:");
    BOOL modern = InstanceSelectorExists(@"NewMainFrameViewController",
                                         @"tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:");
    BOOL modernAlias = InstanceSelectorExists(@"NewMainFrameViewController",
                                              @"wcrGrouping_tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:");
    BOOL legacy = InstanceSelectorExists(@"NewMainFrameViewController",
                                         @"tableView:editActionsForRowAtIndexPath:");
    BOOL legacyAlias = InstanceSelectorExists(@"NewMainFrameViewController",
                                              @"wcrGrouping_tableView:editActionsForRowAtIndexPath:");

    ProbeLog(@"SELF IMAGE = %@", selfImage ?: @"NOT FOUND");
    ProbeLog(@"WCREFINE IMAGE = %@", wcrImage ?: @"NOT FOUND");
    ProbeLog(@"classes manager=%d provider=%d quick=%d main=%d",
             manager, provider, quick, main);
    ProbeLog(@"selectors logic=%d logicAlias=%d modern=%d modernAlias=%d legacy=%d legacyAlias=%d",
             logic, logicAlias, modern, modernAlias, legacy, legacyAlias);

    ProbeLog(@"%@", MethodInfo(@"NewMainFrameViewController",
                              @"logicGetSessionAtIndexPath:"));
    ProbeLog(@"%@", MethodInfo(@"NewMainFrameViewController",
                              @"wcrGrouping_logicGetSessionAtIndexPath:"));
    ProbeLog(@"%@", MethodInfo(@"NewMainFrameViewController",
                              @"tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:"));
    ProbeLog(@"%@", MethodInfo(@"NewMainFrameViewController",
                              @"wcrGrouping_tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:"));
    ProbeLog(@"%@", MethodInfo(@"NewMainFrameViewController",
                              @"tableView:editActionsForRowAtIndexPath:"));
    ProbeLog(@"%@", MethodInfo(@"NewMainFrameViewController",
                              @"wcrGrouping_tableView:editActionsForRowAtIndexPath:"));

    BOOL integrated =
        selfImage.length > 0 &&
        wcrImage.length > 0 &&
        manager && provider && main &&
        (logic || logicAlias) &&
        (modern || legacy);

    NSString *message = [NSString stringWithFormat:
        @"Result: %@\n\n"
         "WCRefineGroup loaded: %@\n"
         "WCRefine loaded: %@\n\n"
         "Manager: %@\nProvider: %@\nQuickRuntime: %@\nMainFrame: %@\n\n"
         "logic/native: %@\nlogic/alias: %@\n"
         "modern/native: %@\nmodern/alias: %@\n"
         "legacy/native: %@\nlegacy/alias: %@",
         integrated ? @"PASS" : @"FAIL",
         selfImage ? @"YES" : @"NO",
         wcrImage ? @"YES" : @"NO",
         manager ? @"YES" : @"NO",
         provider ? @"YES" : @"NO",
         quick ? @"YES" : @"NO",
         main ? @"YES" : @"NO",
         logic ? @"YES" : @"NO",
         logicAlias ? @"YES" : @"NO",
         modern ? @"YES" : @"NO",
         modernAlias ? @"YES" : @"NO",
         legacy ? @"YES" : @"NO",
         legacyAlias ? @"YES" : @"NO"];

    ProbeLog(@"FINAL RESULT = %@", integrated ? @"PASS" : @"FAIL");
    ShowProbeAlert(message);
}

__attribute__((constructor))
static void WCRefineGroupProbeEntry(void) {
    @autoreleasepool {
        ProbeLog(@"constructor entered");

        // First delayed check: enough time for WeChat/WCRefine startup and swizzling.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RunProbe();
        });
    }
}
