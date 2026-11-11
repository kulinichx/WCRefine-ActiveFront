#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>
#import <stdlib.h>
#import "../WCRAFGroupSwipe.h"

@interface WCRAFGroupSwipe (Tests)
- (BOOL)beginSurface;
- (void)setOffset:(CGFloat)offset;
- (void)tapped:(UIButton *)button;
@end

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) @throw [NSException exceptionWithName:@"UITestFailure" reason:message userInfo:nil];
}

@interface SwipeTestController : UIViewController <UITableViewDataSource>
@property(nonatomic, strong) UITableView *table;
@end
@implementation SwipeTestController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.rowHeight = 84;
    [self.view addSubview:self.table];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table; (void)section;
    return 5;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = [NSString stringWithFormat:@"Conversation %ld", (long)path.row];
    cell.detailTextLabel.text = @"Native content must survive swipe and reuse";
    cell.imageView.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    cell.imageView.tintColor = UIColor.systemRedColor;
    return cell;
}
@end

@interface SwipeTestApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
- (void)runTests;
@end
@implementation SwipeTestApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [SwipeTestController new];
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self runTests]; });
    return YES;
}
- (void)runTests {
    BOOL passed = YES;
    NSString *failure = @"";
    NSString *folder = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    @try {
        SwipeTestController *controller = (SwipeTestController *)self.window.rootViewController;
        for (NSNumber *width in @[@360, @768]) {
            for (NSNumber *style in @[@(UIUserInterfaceStyleLight), @(UIUserInterfaceStyleDark)]) {
                self.window.overrideUserInterfaceStyle = style.integerValue;
                UITableView *table = controller.table;
                table.frame = CGRectMake(0, 0, width.doubleValue, 700);
                [table reloadData];
                [table layoutIfNeeded];
                UITableViewCell *cell = [table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
                Check(cell.window != nil, @"Native row must be visible");
                [cell layoutIfNeeded];
                NSArray *nativeSubviews = [cell.subviews copy];
                CGRect nativeFrame = cell.frame, contentFrame = cell.contentView.frame;
                __block NSString *title = @"Mute";
                __block NSUInteger performed = 0;
                WCRAFGroupSwipe *swipe = [WCRAFGroupSwipe controllerForTable:table create:YES];
                __weak WCRAFGroupSwipe *weakSwipe = swipe;
                swipe.resolve = ^WCRAFGroupSwipeAction *(__unused UITableViewCell *row) {
                    WCRAFGroupSwipeAction *action = [WCRAFGroupSwipeAction new];
                    action.title = title;
                    action.color = UIColor.labelColor;
                    action.identity = @"same-account-and-conversation";
                    return action;
                };
                swipe.validate = ^BOOL(UITableViewCell *row, id identity, __unused BOOL again) {
                    return row == cell && [identity isEqual:@"same-account-and-conversation"];
                };
                swipe.rowColor = ^UIColor *(__unused UITableViewCell *row) {
                    return UIColor.secondarySystemGroupedBackgroundColor;
                };
                swipe.perform = ^(UITableViewCell *row, __unused WCRAFGroupSwipeAction *action) {
                    Check(row == cell && [weakSwipe valueForKey:@"surface"] == nil,
                          @"Overlay must be removed before calling the native write");
                    performed++;
                };
                for (NSUInteger cycle = 0; cycle < 20; cycle++) {
                    [swipe setValue:cell forKey:@"cell"];
                    [swipe setValue:swipe.resolve(cell) forKey:@"action"];
                    Check([swipe beginSurface], @"Snapshot must be created");
                    UIView *surface = [swipe valueForKey:@"surface"];
                    Check(surface.superview == cell, @"Overlay must stay aligned to its native row");
                    [swipe setOffset:1000];
                    UIView *viewport = [surface valueForKey:@"viewport"];
                    UIView *actions = [surface valueForKey:@"actions"];
                    Check(surface.clipsToBounds && viewport.clipsToBounds, @"Both overlay boundaries must clip");
                    Check(actions.frame.size.width == 60, @"Long drags must keep the action width bounded");
                    title = @"Updating";
                    [swipe refreshActionForCell:cell];
                    UIButton *button = [surface valueForKey:@"button"];
                    Check([button.currentTitle isEqual:title], @"Pending action must update in place");
                    title = @"Remind";
                    [swipe refreshActionForCell:cell];
                    Check([button.currentTitle isEqual:title], @"Confirmed action must update without row reload");
                    [swipe tapped:button];
                    Check(surface.superview == nil, @"Tap must remove overlay");
                    Check([cell.subviews isEqual:nativeSubviews], @"Swipe must preserve all native subviews");
                    Check(CGRectEqualToRect(cell.frame, nativeFrame) &&
                          CGRectEqualToRect(cell.contentView.frame, contentFrame),
                          @"Swipe must not expand the native row or its content");
                    Check(!cell.hidden && cell.alpha == 1 && !cell.contentView.hidden && cell.contentView.alpha == 1,
                          @"Native content must remain visible after tap");
                }
                Check(performed == 20, @"Each tap must submit exactly one action");
                [swipe setValue:cell forKey:@"cell"];
                [swipe setValue:swipe.resolve(cell) forKey:@"action"];
                Check([swipe beginSurface], @"Overlay before reuse");
                UIView *reuseSurface = [swipe valueForKey:@"surface"];
                [WCRAFGroupSwipe resetForCell:cell];
                [cell prepareForReuse];
                Check(reuseSurface.superview == nil && swipe.cell == nil, @"Reuse must discard the old overlay");
                [swipe setValue:cell forKey:@"cell"];
                [swipe setValue:swipe.resolve(cell) forKey:@"action"];
                Check([swipe beginSurface], @"Overlay before resize");
                UIView *resizeSurface = [swipe valueForKey:@"surface"];
                resizeSurface.bounds = CGRectMake(0, 0, 120, 84);
                [resizeSurface setNeedsLayout];
                [resizeSurface layoutIfNeeded];
                Check(resizeSurface.superview == nil, @"Resize must invalidate rather than stretch the snapshot");
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:table.bounds];
                UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                    [table drawViewHierarchyInRect:table.bounds afterScreenUpdates:YES];
                }];
                NSString *name = [NSString stringWithFormat:@"rows-%@-%@.png", width, style];
                [UIImagePNGRepresentation(image) writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES];
                swipe.perform = nil;
            }
        }
    } @catch (NSException *exception) {
        passed = NO;
        failure = exception.reason ?: @"Unknown UIKit test failure";
    }
    NSDictionary *report = @{@"passed": @(passed), @"checks_run": @(checks), @"failure": failure,
        @"scope": @"UIKit simulator overlay and native-row invariants; no WeChat host or physical device"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[folder stringByAppendingPathComponent:@"ui-tests.json"] atomically:YES];
    printf("%s\n", passed ? "WCR_UI_TESTS_PASS" : failure.UTF8String);
    fflush(stdout);
    exit(passed ? 0 : 1);
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SwipeTestApp.class));
    }
}
