#import <UIKit/UIKit.h>

@interface WCRAFGroupSwipeAction : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic, strong) id identity;
@end

// One right-swipe owner per verified grouping table, including iPad proxy tables.
@interface WCRAFGroupSwipe : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, copy) WCRAFGroupSwipeAction *(^resolve)(UITableViewCell *);
@property(nonatomic, copy) BOOL (^validate)(UITableViewCell *, id, BOOL);
@property(nonatomic, copy) BOOL (^nativeMenuVisible)(UITableViewCell *);
@property(nonatomic, copy) UIColor *(^rowColor)(UITableViewCell *);
@property(nonatomic, copy) void (^perform)(UITableViewCell *, WCRAFGroupSwipeAction *);
@property(nonatomic, readonly) UIPanGestureRecognizer *pan;
@property(nonatomic, weak, readonly) UITableViewCell *cell;
+ (instancetype)controllerForTable:(UITableView *)table create:(BOOL)create;
+ (void)resetAll;
+ (void)resetForCell:(UITableViewCell *)cell;
- (void)refreshActionForCell:(UITableViewCell *)cell;
- (void)reset;
@end
