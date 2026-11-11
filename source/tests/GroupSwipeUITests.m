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

static BOOL HasRenderedContent(UIImage *image) {
    CGImageRef pixels = image.CGImage;
    if (!pixels) return NO;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(pixels));
    if (!data) return NO;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    size_t stride = CGImageGetBitsPerPixel(pixels) / 8;
    BOOL varied = NO;
    if (stride >= 3 && length > (CFIndex)stride) {
        for (CFIndex offset = (CFIndex)stride; offset + 2 < length; offset += (CFIndex)stride * 7) {
            if (abs((int)bytes[offset] - bytes[0]) > 24 ||
                abs((int)bytes[offset + 1] - bytes[1]) > 24 ||
                abs((int)bytes[offset + 2] - bytes[2]) > 24) {
                varied = YES;
                break;
            }
        }
    }
    CFRelease(data);
    return varied;
}

@interface ReminderTestData : NSObject
@property(nonatomic) BOOL actualMuted;
@property(nonatomic) BOOL cachedMuted;
@property(nonatomic) NSUInteger refreshes;
@end
@implementation ReminderTestData
- (void)updateDataFieldForUI {
    self.refreshes++;
    self.cachedMuted = self.actualMuted;
}
@end

@interface ReminderTestCell : UITableViewCell
@property(nonatomic, strong) ReminderTestData *cellData;
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic) BOOL failUpdate;
@end
@implementation ReminderTestCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        _cellData = [ReminderTestData new];
        _statusIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 24, 20, 20)];
        _statusIcon.image = [UIImage systemImageNamed:@"bell.fill"];
        _statusIcon.tintColor = UIColor.systemGreenColor;
        [self.contentView addSubview:_statusIcon];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.statusIcon.frame = CGRectMake(self.contentView.bounds.size.width - 32, 24, 20, 20);
}
- (void)updateContentView:(ReminderTestData *)data tableViewFrame:(CGRect)tableFrame {
    (void)tableFrame;
    self.cellData = data;
    self.statusIcon.image = [UIImage systemImageNamed:data.cachedMuted ? @"bell.slash.fill" : @"bell.fill"];
    self.statusIcon.tintColor = data.cachedMuted ? UIColor.systemRedColor : UIColor.systemGreenColor;
    // Exercise native code laying out at the outer table width.
    self.contentView.frame = CGRectInset(self.contentView.frame, -20, 0);
    if (self.failUpdate) @throw [NSException exceptionWithName:@"NativeRowFailure" reason:@"test" userInfo:nil];
}
@end

@interface ExtendedReminderTestCell : UITableViewCell
@property(nonatomic) BOOL updated;
@end
@implementation ExtendedReminderTestCell
- (void)updateContentView:(ReminderTestData *)data tableViewFrame:(CGRect)frame
             isSearching:(BOOL)searching isSearchTableView:(BOOL)searchTable searchBarText:(id)text {
    self.updated = data.refreshes > 0 && !searching && !searchTable && text == nil && frame.size.width == 768;
}
@end

@interface InvalidReminderTestCell : UITableViewCell
@end
@implementation InvalidReminderTestCell
- (id)updateContentView:(id)data tableViewFrame:(CGRect)frame {
    (void)data; (void)frame;
    @throw [NSException exceptionWithName:@"BadABICalled" reason:@"test" userInfo:nil];
}
@end

static NSData *IconPixels(UIImage *image, ReminderTestCell *cell) {
    CGRect rect = [cell.statusIcon convertRect:cell.statusIcon.bounds toView:cell];
    rect = CGRectApplyAffineTransform(rect, CGAffineTransformMakeScale(image.scale, image.scale));
    CGImageRef crop = CGImageCreateWithImageInRect(image.CGImage, rect);
    if (!crop) return nil;
    NSData *pixels = UIImagePNGRepresentation([UIImage imageWithCGImage:crop]);
    CGImageRelease(crop);
    return pixels;
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
    UITableViewCell *cell = [[ReminderTestCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
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
        CGRect sampleFrame = CGRectMake(0, 0, 768, 84);
        ReminderTestData *sampleData = [ReminderTestData new];
        ExtendedReminderTestCell *extended = [[ExtendedReminderTestCell alloc] initWithFrame:sampleFrame];
        Check(WCRAFRefreshNativeRow(extended, sampleData, sampleFrame) && extended.updated,
              @"Verified extended native signature must repaint with non-search arguments");
        UITableViewCell *unsupported = [[UITableViewCell alloc] initWithFrame:sampleFrame];
        NSUInteger before = sampleData.refreshes;
        Check(!WCRAFRefreshNativeRow(unsupported, sampleData, sampleFrame) && sampleData.refreshes == before,
              @"Unsupported native rows must not mutate UI data");
        InvalidReminderTestCell *invalid = [[InvalidReminderTestCell alloc] initWithFrame:sampleFrame];
        Check(!WCRAFRefreshNativeRow(invalid, sampleData, sampleFrame),
              @"Incompatible native method ABI must be rejected");
        ReminderTestCell *failing = [[ReminderTestCell alloc] initWithFrame:sampleFrame];
        [failing layoutIfNeeded];
        CGRect failureFrame = failing.contentView.frame;
        failing.failUpdate = YES;
        Check(!WCRAFRefreshNativeRow(failing, sampleData, sampleFrame) &&
              CGRectEqualToRect(failing.contentView.frame, failureFrame),
              @"Native exceptions must still restore container bounds");
        SwipeTestController *controller = (SwipeTestController *)self.window.rootViewController;
        for (NSNumber *width in @[@360, @768]) {
            for (NSNumber *style in @[@(UIUserInterfaceStyleLight), @(UIUserInterfaceStyleDark)]) {
                UITableView *table = controller.table;
                [UIView performWithoutAnimation:^{
                    self.window.overrideUserInterfaceStyle = style.integerValue;
                    table.frame = CGRectMake(0, 0, width.doubleValue, 700);
                    [table reloadData];
                    [self.window layoutIfNeeded];
                    [table layoutIfNeeded];
                }];
                // Let UIKit commit the appearance change before comparing
                // snapshots; otherwise the first dark icon can use light tint.
                [CATransaction flush];
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]];
                ReminderTestCell *cell = (ReminderTestCell *)[table cellForRowAtIndexPath:
                    [NSIndexPath indexPathForRow:2 inSection:0]];
                Check(cell.window != nil, @"Native row must be visible");
                [cell layoutIfNeeded];
                NSArray *nativeSubviews = [cell.subviews copy];
                CGRect nativeFrame = cell.frame, contentFrame = cell.contentView.frame;
                __block NSString *title = @"Mute";
                __block NSUInteger performed = 0;
                __block BOOL bindingCurrent = YES;
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
                    return bindingCurrent && row == cell && [identity isEqual:@"same-account-and-conversation"];
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
                    UIImageView *foreground = [surface valueForKey:@"foreground"];
                    Check(HasRenderedContent(foreground.image), @"Rendered swipe row must contain visible pixels");
                    NSData *beforeIcon = IconPixels(foreground.image, cell);
                    Check(beforeIcon.length > 0, @"Trailing native status icon pixels must be available");
                    [swipe setOffset:1000];
                    UIView *viewport = [surface valueForKey:@"viewport"];
                    UIView *actions = [surface valueForKey:@"actions"];
                    Check(surface.clipsToBounds && viewport.clipsToBounds, @"Both overlay boundaries must clip");
                    Check(actions.frame.size.width == 60, @"Long drags must keep the action width bounded");
                    title = @"Updating";
                    [swipe refreshActionForCell:cell];
                    UIButton *button = [surface valueForKey:@"button"];
                    Check([button.currentTitle isEqual:title], @"Pending action must update in place");
                    Check([beforeIcon isEqual:IconPixels(foreground.image, cell)],
                          [NSString stringWithFormat:
                              @"Pending icon changed without native state change (width=%@ style=%@ cycle=%lu)",
                              width, style, (unsigned long)cycle]);
                    ReminderTestData *data = cell.cellData;
                    data.actualMuted = !data.actualMuted;
                    NSUInteger refreshes = data.refreshes;
                    Check(WCRAFRefreshNativeRow(cell, data, table.frame) &&
                          data.refreshes == refreshes + 1 && data.cachedMuted == data.actualMuted,
                          @"Native cached UI data must be recomputed before repainting");
                    CGRect pictureFrame = foreground.frame;
                    title = data.actualMuted ? @"Remind" : @"Mute";
                    [swipe refreshActionForCell:cell];
                    Check([button.currentTitle isEqual:title], @"Confirmed action must update without row reload");
                    Check(![beforeIcon isEqual:IconPixels(foreground.image, cell)],
                          @"Confirmed native icon must replace stale swipe snapshot pixels in both directions");
                    Check(CGRectEqualToRect(pictureFrame, foreground.frame) &&
                          actions.frame.size.width == 60 && !surface.hidden,
                          @"Refreshing an open menu must preserve offset, bounds and visibility");
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
                cell.cellData.actualMuted = !cell.cellData.actualMuted;
                Check(WCRAFRefreshNativeRow(cell, cell.cellData, table.frame) &&
                      [swipe valueForKey:@"surface"] == nil,
                      @"Closed visible rows must repaint without reopening or reloading the menu");
                [swipe setValue:cell forKey:@"cell"];
                [swipe setValue:swipe.resolve(cell) forKey:@"action"];
                Check([swipe beginSurface], @"Overlay before identity invalidation");
                UIView *staleSurface = [swipe valueForKey:@"surface"];
                bindingCurrent = NO;
                [swipe refreshActionForCell:cell];
                Check(staleSurface.superview == nil && swipe.cell == nil,
                      @"Old account or reused-row binding must discard its snapshot");
                bindingCurrent = YES;
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
    // Keep the app alive until the runner collects the report and shuts down
    // the device. Exiting during simctl's launch handshake can stall its CLI.
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SwipeTestApp.class));
    }
}
