#import "WCRAFGroupSwipe.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>
#import <math.h>

@implementation WCRAFGroupSwipeAction
@end

@interface WCRAFGroupSwipeSurface : UIView
@property(nonatomic, strong) UIView *viewport;
@property(nonatomic, strong) UIView *foreground;
@property(nonatomic, strong) UIView *actions;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, copy) void (^invalidated)(void);
@property(nonatomic) CGRect originalBounds;
@end

@implementation WCRAFGroupSwipeSurface
- (void)layoutSubviews {
    [super layoutSubviews];
    // A rotation/split resize invalidates the snapshot instead of stretching it.
    if (!CGRectEqualToRect(self.bounds, self.originalBounds)) {
        if (self.invalidated) self.invalidated();
    }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window && self.invalidated) self.invalidated();
}
@end

@interface WCRAFGroupPan : UIPanGestureRecognizer
@property(nonatomic, copy) void (^touchDown)(CGPoint);
@end

@implementation WCRAFGroupPan
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible && self.touchDown) {
        self.touchDown([touches.anyObject locationInView:self.view]);
    }
    [super touchesBegan:touches withEvent:event];
}
@end

@interface WCRAFGroupSwipe ()
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, strong) WCRAFGroupPan *pan;
@property(nonatomic, strong) UITapGestureRecognizer *dismissTap;
@property(nonatomic, weak) UITableViewCell *cell;
@property(nonatomic, weak) UITableViewCell *touchedCell;
@property(nonatomic, strong) WCRAFGroupSwipeSurface *surface;
@property(nonatomic, strong) WCRAFGroupSwipeAction *action;
@property(nonatomic) BOOL nativeClose;
@property(nonatomic) BOOL open;
@property(nonatomic) CGFloat start;
@property(nonatomic) CGFloat offset;
@property(nonatomic) NSUInteger generation;
@end

static char kWCRAFGroupSwipeOwner;
static NSHashTable<WCRAFGroupSwipe *> *controllers;
static const CGFloat actionWidth = 60;

@implementation WCRAFGroupSwipe

+ (instancetype)controllerForTable:(UITableView *)table create:(BOOL)create {
    if (!table) return nil;
    WCRAFGroupSwipe *owner = objc_getAssociatedObject(table, &kWCRAFGroupSwipeOwner);
    if (!owner && create) {
        owner = [self new];
        owner.table = table;
        owner.pan = [[WCRAFGroupPan alloc] initWithTarget:owner action:@selector(handlePan:)];
        owner.pan.delegate = owner;
        owner.pan.maximumNumberOfTouches = 1;
        owner.pan.cancelsTouchesInView = YES;
        owner.pan.delaysTouchesBegan = NO;
        __weak WCRAFGroupSwipe *weakOwner = owner;
        owner.pan.touchDown = ^(CGPoint point) { [weakOwner captureTouch:point]; };
        [table addGestureRecognizer:owner.pan];
        owner.dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:owner action:@selector(dismiss:)];
        owner.dismissTap.delegate = owner;
        owner.dismissTap.cancelsTouchesInView = NO;
        owner.dismissTap.delaysTouchesBegan = NO;
        owner.dismissTap.enabled = NO;
        [table addGestureRecognizer:owner.dismissTap];
        [table.panGestureRecognizer addTarget:owner action:@selector(scrolled:)];
        objc_setAssociatedObject(table, &kWCRAFGroupSwipeOwner, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!controllers) controllers = [NSHashTable weakObjectsHashTable];
        [controllers addObject:owner];
    }
    return owner;
}

+ (void)resetAll {
    for (WCRAFGroupSwipe *owner in controllers.allObjects) [owner reset];
}

- (void)reset {
    self.generation++;
    WCRAFGroupSwipeSurface *old = self.surface;
    self.surface = nil;
    old.invalidated = nil;
    [old.foreground.layer removeAllAnimations];
    [old removeFromSuperview];
    self.cell = nil;
    self.action = nil;
    self.open = NO;
    self.offset = 0;
    self.start = 0;
    self.dismissTap.enabled = NO;
    // Native row frames, masks, transforms, visibility and alpha were never changed.
}

- (void)captureTouch:(CGPoint)point {
    NSIndexPath *path = [self.table indexPathForRowAtPoint:point];
    self.touchedCell = path ? [self.table cellForRowAtIndexPath:path] : nil;
    self.nativeClose = NO;
    for (UITableViewCell *row in self.table.visibleCells) {
        if (self.nativeMenuVisible && self.nativeMenuVisible(row)) {
            self.nativeClose = YES;
            break;
        }
    }
    // Leave the navigation edge gesture to the host.
    if (point.x - CGRectGetMinX(self.table.bounds) < 28) self.touchedCell = nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.dismissTap) return self.surface != nil;
    if (gesture != self.pan || self.nativeClose || !self.touchedCell) return NO;
    CGPoint velocity = [self.pan velocityInView:self.table];
    if (fabs(velocity.x) <= fabs(velocity.y) * 1.12) return NO;
    if (self.cell == self.touchedCell && self.surface) {
        return self.validate && self.validate(self.cell, self.action.identity, YES);
    }
    if (velocity.x <= 30 || !self.resolve) return NO;
    WCRAFGroupSwipeAction *action = self.resolve(self.touchedCell);
    if (!action || !self.validate || !self.validate(self.touchedCell, action.identity, YES)) return NO;
    [self reset];
    self.cell = self.touchedCell;
    self.action = action;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (gesture != self.pan || ![other isKindOfClass:UIPanGestureRecognizer.class]) return NO;
    // Resolve direction once, before a native cell/table pan can move the row.
    return other.view == self.table || [other.view isDescendantOfView:self.table];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gesture; (void)other;
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture != self.dismissTap) return YES;
    for (UIView *view = touch.view; view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class]) return NO;
    }
    return self.surface != nil;
}

- (BOOL)beginSurface {
    if (self.surface) {
        self.generation++;
        CALayer *presentation = self.surface.foreground.layer.presentationLayer;
        CGFloat x = presentation ? presentation.frame.origin.x + self.surface.viewport.frame.origin.x :
            self.offset;
        [self.surface.foreground.layer removeAllAnimations];
        [self setOffset:x];
        return YES;
    }
    UITableViewCell *cell = self.cell;
    if (!cell.window || CGRectIsEmpty(cell.bounds)) return NO;
    UIView *picture = [cell snapshotViewAfterScreenUpdates:NO];
    if (!picture) return NO;
    WCRAFGroupSwipeSurface *surface = [[WCRAFGroupSwipeSurface alloc] initWithFrame:cell.bounds];
    surface.originalBounds = surface.bounds;
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.backgroundColor = UIColor.clearColor;
    surface.clipsToBounds = YES;
    CGRect area = surface.bounds;
    UIView *background = cell.backgroundView;
    if (background && !background.hidden && background.alpha > 0.99 && !CGRectIsEmpty(background.bounds)) {
        CGRect candidate = CGRectIntersection(cell.bounds, [background convertRect:background.bounds toView:cell]);
        if (!CGRectIsNull(candidate) && candidate.size.width > actionWidth * 2 && candidate.size.height > 1) {
            area = CGRectOffset(candidate, -cell.bounds.origin.x, -cell.bounds.origin.y);
        }
    }
    surface.viewport = [[UIView alloc] initWithFrame:area];
    surface.viewport.clipsToBounds = YES;
    surface.viewport.backgroundColor = self.rowColor ? self.rowColor(cell) : UIColor.secondarySystemGroupedBackgroundColor;
    // Preserve the original first/last-row corner treatment in the fixed viewport.
    surface.viewport.layer.cornerRadius = background.layer.cornerRadius;
    surface.viewport.layer.maskedCorners = background.layer.maskedCorners;
    if ([background.layer.mask isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *mask = (CAShapeLayer *)background.layer.mask;
        CAShapeLayer *copy = [CAShapeLayer layer];
        copy.frame = mask.frame;
        copy.path = mask.path;
        copy.fillRule = mask.fillRule;
        surface.viewport.layer.mask = copy;
    }
    [surface addSubview:surface.viewport];
    surface.actions = [[UIView alloc] initWithFrame:CGRectZero];
    surface.actions.clipsToBounds = YES;
    surface.actions.backgroundColor = UIColor.clearColor;
    surface.button = [UIButton buttonWithType:UIButtonTypeSystem];
    surface.button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    surface.button.backgroundColor = UIColor.clearColor;
    [surface.button setTitle:self.action.title forState:UIControlStateNormal];
    [surface.button setTitleColor:self.action.color forState:UIControlStateNormal];
    [surface.button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    [surface.actions addSubview:surface.button];
    [surface.viewport addSubview:surface.actions];
    surface.foreground = picture;
    picture.userInteractionEnabled = NO;
    [surface.viewport addSubview:picture];
    __weak WCRAFGroupSwipe *weakSelf = self;
    surface.invalidated = ^{ [weakSelf reset]; };
    self.surface = surface;
    [cell addSubview:surface];
    [self setOffset:0];
    return YES;
}

- (void)setOffset:(CGFloat)x {
    WCRAFGroupSwipeSurface *surface = self.surface;
    _offset = isfinite(x) ? MIN(actionWidth, MAX(0, x)) : 0;
    CGRect frame = surface.bounds;
    frame.origin.x = _offset - surface.viewport.frame.origin.x;
    frame.origin.y = -surface.viewport.frame.origin.y;
    surface.foreground.frame = frame;
    surface.actions.frame = CGRectMake(0, 0, _offset, surface.viewport.bounds.size.height);
    surface.button.frame = CGRectMake(0, 0, actionWidth, surface.viewport.bounds.size.height);
}

- (void)settleOpen:(BOOL)open {
    self.open = open;
    self.dismissTap.enabled = open;
    NSUInteger generation = ++self.generation;
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.92 initialSpringVelocity:0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{ [self setOffset:open ? actionWidth : 0]; }
        completion:^(__unused BOOL finished) {
            if (generation != self.generation) return;
            if (!open) [self reset];
        }];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!self.cell) return;
    if (!self.validate || !self.validate(self.cell, self.action.identity, NO)) {
        [self reset];
        return;
    }
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            if (![self beginSurface]) { [self reset]; return; }
            self.start = self.offset;
            break;
        case UIGestureRecognizerStateChanged:
            [self setOffset:self.start + [pan translationInView:self.table].x];
            break;
        case UIGestureRecognizerStateEnded: {
            CGFloat x = self.start + [pan translationInView:self.table].x;
            CGFloat vx = [pan velocityInView:self.table].x;
            [self settleOpen:vx > -420 && (x >= actionWidth * 0.42 || vx >= 520)];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self reset];
            break;
        default: break;
    }
}

- (void)tapped:(UIButton *)button {
    (void)button;
    UITableViewCell *cell = self.cell;
    WCRAFGroupSwipeAction *action = self.action;
    BOOL valid = self.validate && self.validate(cell, action.identity, YES);
    [self reset];
    if (valid && self.perform) self.perform(cell, action);
}

- (void)dismiss:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) [self settleOpen:NO];
}

- (void)scrolled:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) [self reset];
}
@end
