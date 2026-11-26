//
//  PTCustomInputViewHost.m
//  PlayTools
//
//  Presents custom UIResponder.inputView / inputAccessoryView panels (such as
//  custom secure keyboards and pickers) on Mac Catalyst, where UIKit assumes a
//  hardware keyboard is always attached and suppresses software inputView
//  presentation.
//

#import "PSInternal.h"
#import <math.h>

@class PTCustomInputViewHost;
@class PTCustomInputHostContainerView;

static void pt_notify_container_did_layout(PTCustomInputHostContainerView *container);

static const CGFloat kPTMinInputHeight = 44.0;
static const CGFloat kPTDefaultInputHeight = 256.0;
static const CGFloat kPTMinAccessoryHeight = 24.0;
static const CGFloat kPTMaxAccessoryHeight = 120.0;
static const CGFloat kPTDefaultAccessoryHeight = 44.0;
static const CGFloat kPTMaxTrayHeightRatio = 0.65;
static const NSTimeInterval kPTShowAnimationDuration = 0.22;
static const NSTimeInterval kPTHideAnimationDuration = 0.16;

static void pt_tag_internal_overlay_object(id obj) {
    if (obj == nil) {
        return;
    }
    const void *tagKey = (const void *)(uintptr_t)[PlaySettings pm_internalOverlayTagKeyAddress];
    if (tagKey != NULL) {
        objc_setAssociatedObject(obj, tagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL pt_is_tagged_internal_overlay(id obj) {
    if (obj == nil) {
        return NO;
    }
    const void *tagKey = (const void *)(uintptr_t)[PlaySettings pm_internalOverlayTagKeyAddress];
    if (tagKey == NULL) {
        return NO;
    }
    return objc_getAssociatedObject(obj, tagKey) != nil;
}

static BOOL pt_is_system_keyboard_view(UIView *view) {
    if (view == nil) {
        return YES;
    }
    if (pt_is_tagged_internal_overlay(view)) {
        return YES;
    }
    const char *clsName = class_getName(object_getClass(view));
    if (clsName == NULL) {
        return YES;
    }
    static const char *const kSystemPrefixes[] = {
        "UIKeyboard",
        "_UIKeyboard",
        "UISystemKeyboard",
        "UIInputSet",
        "UIRemoteKeyboard",
        "UICompatibilityInputView",
        "UIEmoji",
        "_UIRemoteInputView",
        "_UITextEffects",
        "PTCustomInput"
    };
    for (size_t i = 0; i < sizeof(kSystemPrefixes) / sizeof(kSystemPrefixes[0]); i++) {
        size_t len = strlen(kSystemPrefixes[i]);
        if (strncmp(clsName, kSystemPrefixes[i], len) == 0) {
            return YES;
        }
    }
    return NO;
}

static UIWindow *pt_resolve_window_for_responder(UIResponder *responder) {
    UIResponder *cursor = responder;
    NSUInteger depth = 0;
    while (cursor != nil && depth < 64U) {
        if ([cursor isKindOfClass:[UIWindow class]]) {
            return (UIWindow *)cursor;
        }
        if ([cursor isKindOfClass:[UIView class]]) {
            UIWindow *win = ((UIView *)cursor).window;
            if (win != nil) {
                return win;
            }
        }
        if ([cursor isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)cursor;
            if (vc.isViewLoaded && vc.view.window != nil) {
                return vc.view.window;
            }
        }
        cursor = [cursor nextResponder];
        depth++;
    }
    return [PlayScreen.shared activeTouchWindow];
}

static UIView *pt_resolve_custom_input_view(UIResponder *responder) {
    if (responder == nil || [responder isKindOfClass:[UIApplication class]]) {
        return nil;
    }
    UIView *v = nil;
    if ([responder respondsToSelector:@selector(inputView)]) {
        v = [responder inputView];
    }
    if (v == nil && [responder respondsToSelector:@selector(inputViewController)]) {
        UIInputViewController *ivc = [responder inputViewController];
        if ([ivc isKindOfClass:[UIViewController class]]) {
            v = ivc.view;
        }
    }
    if (![v isKindOfClass:[UIView class]] || pt_is_system_keyboard_view(v)) {
        return nil;
    }
    return v;
}

static UIView *pt_resolve_custom_accessory_view(UIResponder *responder, UIView *inputView) {
    if (responder == nil || inputView == nil) {
        return nil;
    }
    UIView *acc = nil;
    if ([responder respondsToSelector:@selector(inputAccessoryView)]) {
        acc = [responder inputAccessoryView];
    }
    if (acc == nil && [responder respondsToSelector:@selector(inputAccessoryViewController)]) {
        UIInputViewController *avc = [responder inputAccessoryViewController];
        if ([avc isKindOfClass:[UIViewController class]]) {
            acc = avc.view;
        }
    }
    if (![acc isKindOfClass:[UIView class]] || pt_is_system_keyboard_view(acc)) {
        return nil;
    }
    // Some custom keyboards embed their accessory toolbar directly inside their
    // custom inputView. Never reparent it out of inputView.
    if (acc == inputView || [acc isDescendantOfView:inputView] || [inputView isDescendantOfView:acc]) {
        return nil;
    }
    return acc;
}

static BOOL pt_responder_has_custom_input(UIResponder *responder) {
    return pt_resolve_custom_input_view(responder) != nil;
}

static CGFloat pt_measure_view_height(UIView *view,
                                      CGFloat hostWidth,
                                      CGFloat fallbackHeight,
                                      CGFloat minHeight,
                                      CGFloat maxHeight) {
    CGFloat measured = 0.0;
    CGFloat boundsH = view.bounds.size.height;
    if (isfinite(boundsH) && boundsH > 1.0) {
        measured = boundsH;
    } else {
        CGSize intrinsic = [view intrinsicContentSize];
        if (isfinite(intrinsic.height) &&
            intrinsic.height != UIViewNoIntrinsicMetric &&
            intrinsic.height > 1.0) {
            measured = intrinsic.height;
        } else if (!view.translatesAutoresizingMaskIntoConstraints || view.constraints.count > 0) {
            CGSize fit = [view systemLayoutSizeFittingSize:CGSizeMake(hostWidth, UILayoutFittingCompressedSize.height)
                             withHorizontalFittingPriority:UILayoutPriorityRequired
                                   verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
            if (isfinite(fit.height) && fit.height > 1.0) {
                measured = fit.height;
            }
        }
        if (measured <= 1.0) {
            CGSize thatFits = [view sizeThatFits:CGSizeMake(hostWidth, maxHeight)];
            if (isfinite(thatFits.height) && thatFits.height > 1.0) {
                measured = thatFits.height;
            }
        }
    }
    if (!isfinite(measured) || measured <= 1.0) {
        measured = fallbackHeight;
    }
    CGFloat effectiveMax = MAX(minHeight, maxHeight);
    return MIN(MAX(measured, minHeight), effectiveMax);
}

__attribute__((visibility("hidden")))
@interface PTCustomInputHostContainerView : UIView
@property (nonatomic, strong, readonly) UIView *dockView;
@property (nonatomic, strong, readonly) UIView *topHairlineView;
@property (nonatomic, strong, readonly) UIView *accessorySlotView;
@property (nonatomic, strong, readonly) UIView *inputSlotView;
@end

@implementation PTCustomInputHostContainerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        pt_tag_internal_overlay_object(self);

        _dockView = [[UIView alloc] initWithFrame:CGRectZero];
        _dockView.hidden = YES;
        _dockView.clipsToBounds = NO;
        _dockView.autoresizesSubviews = NO;
        _dockView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _dockView.layer.shadowColor = [UIColor blackColor].CGColor;
        _dockView.layer.shadowOpacity = 0.14f;
        _dockView.layer.shadowOffset = CGSizeMake(0.0, -2.0);
        _dockView.layer.shadowRadius = 6.0;
        pt_tag_internal_overlay_object(_dockView);
        [self addSubview:_dockView];

        _accessorySlotView = [[UIView alloc] initWithFrame:CGRectZero];
        _accessorySlotView.backgroundColor = [UIColor clearColor];
        _accessorySlotView.clipsToBounds = YES;
        _accessorySlotView.autoresizesSubviews = NO;
        pt_tag_internal_overlay_object(_accessorySlotView);
        [_dockView addSubview:_accessorySlotView];

        _inputSlotView = [[UIView alloc] initWithFrame:CGRectZero];
        _inputSlotView.backgroundColor = [UIColor clearColor];
        _inputSlotView.clipsToBounds = NO;
        _inputSlotView.autoresizesSubviews = NO;
        pt_tag_internal_overlay_object(_inputSlotView);
        [_dockView addSubview:_inputSlotView];

        _topHairlineView = [[UIView alloc] initWithFrame:CGRectZero];
        _topHairlineView.backgroundColor = [UIColor separatorColor];
        _topHairlineView.userInteractionEnabled = NO;
        pt_tag_internal_overlay_object(_topHairlineView);
        [_dockView addSubview:_topHairlineView];
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (self.isHidden || !self.userInteractionEnabled || self.alpha <= 0.01 || self.dockView.isHidden) {
        return NO;
    }
    CGPoint dockPoint = [self convertPoint:point toView:self.dockView];
    return CGRectContainsPoint(self.dockView.bounds, dockPoint);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.isHidden || !self.userInteractionEnabled || self.alpha <= 0.01 || self.dockView.isHidden) {
        return nil;
    }
    CGPoint dockPoint = [self convertPoint:point toView:self.dockView];
    if (!CGRectContainsPoint(self.dockView.bounds, dockPoint)) {
        return nil;
    }
    return [self.dockView hitTest:dockPoint withEvent:event];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    pt_notify_container_did_layout(self);
}

@end

__attribute__((visibility("hidden")))
@interface PTCustomInputRootViewController : UIViewController
@property (nonatomic, weak) UIWindow *targetAppWindow;
@property (nonatomic, strong, readonly) PTCustomInputHostContainerView *hostContainerView;
@end

@implementation PTCustomInputRootViewController

- (void)loadView {
    _hostContainerView = [[PTCustomInputHostContainerView alloc] initWithFrame:CGRectZero];
    self.view = _hostContainerView;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (BOOL)shouldAutorotate {
    UIViewController *rootVC = self.targetAppWindow.rootViewController;
    if (rootVC != nil && rootVC != self) {
        return [rootVC shouldAutorotate];
    }
    return YES;
}
#pragma clang diagnostic pop

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *rootVC = self.targetAppWindow.rootViewController;
    if (rootVC != nil && rootVC != self) {
        return [rootVC supportedInterfaceOrientations];
    }
    return UIInterfaceOrientationMaskAll;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    UIViewController *rootVC = self.targetAppWindow.rootViewController;
    if (rootVC != nil && rootVC != self) {
        return [rootVC preferredStatusBarStyle];
    }
    return UIStatusBarStyleDefault;
}

@end

__attribute__((visibility("hidden")))
@interface PTCustomInputWindow : UIWindow
@property (nonatomic, weak) PTCustomInputHostContainerView *hostContainerView;
@end

@implementation PTCustomInputWindow

- (BOOL)_canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeKey {
    return NO;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.isHidden || !self.userInteractionEnabled || self.alpha <= 0.01) {
        return NO;
    }
    PTCustomInputHostContainerView *container = self.hostContainerView;
    if (container == nil || container.isHidden || container.dockView.isHidden) {
        return NO;
    }
    CGPoint ptInContainer = [self convertPoint:point toView:container];
    return [container pointInside:ptInContainer withEvent:event];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.isHidden || !self.userInteractionEnabled || self.alpha <= 0.01) {
        return nil;
    }
    PTCustomInputHostContainerView *container = self.hostContainerView;
    if (container == nil || container.isHidden || container.dockView.isHidden) {
        return nil;
    }
    CGPoint ptInContainer = [self convertPoint:point toView:container];
    return [container hitTest:ptInContainer withEvent:event];
}

@end

typedef struct {
    BOOL valid;
    CGAffineTransform transform;
    UIViewAutoresizing autoresizingMask;
    BOOL translatesAutoresizingMaskIntoConstraints;
    CGSize originalBoundsSize;
} PTSavedHostedViewState;

typedef struct {
    CGFloat finalHeight;
    CGFloat rawW;
    CGFloat rawH;
    CGFloat scale;
    CGFloat centeredX;
    BOOL usesAutoLayout;
    BOOL usesScale;
    BOOL fillsWidth;
} PTComputedChildLayout;

__attribute__((visibility("hidden")))
@interface PTCustomInputViewHost : NSObject
+ (instancetype)sharedHost;
- (void)customInputContainerDidLayout:(PTCustomInputHostContainerView *)container;
- (void)scheduleEvaluationForBecomeFirstResponder:(UIResponder *)responder;
- (void)scheduleEvaluationForResignFirstResponder:(UIResponder *)responder;
- (void)scheduleEvaluationForReloadInputViews:(UIResponder *)responder;
- (void)handleTextInputDidBegin:(UIResponder *)responder;
- (void)handleTextInputDidEnd:(UIResponder *)responder;
- (void)handleWindowDidBecomeHidden:(UIWindow *)window;
- (void)handleHostWindowGeometryChanged;
@end

static void pt_notify_container_did_layout(PTCustomInputHostContainerView *container) {
    [[PTCustomInputViewHost sharedHost] customInputContainerDidLayout:container];
}

@implementation PTCustomInputViewHost {
    PTCustomInputWindow *_overlayWindow;
    PTCustomInputRootViewController *_overlayRootVC;
    PTCustomInputHostContainerView *_fallbackContainer;

    __weak UIResponder *_activeResponder;
    __weak UIWindow *_targetWindow;
    __weak UIView *_hostedInputView;
    __weak UIView *_hostedAccessoryView;

    NSMutableArray<NSLayoutConstraint *> *_inputPinnedConstraints;
    NSMutableArray<NSLayoutConstraint *> *_accessoryPinnedConstraints;
    PTSavedHostedViewState _savedInputState;
    PTSavedHostedViewState _savedAccessoryState;

    uint64_t _transitionGeneration;
    uint64_t _animationToken;
    BOOL _isKeyboardVisible;
    BOOL _isPostingNotifications;
    BOOL _isLayingOut;
    CGRect _lastPostedKeyboardFrame;
    CGSize _lastLaidOutContainerSize;
}

+ (instancetype)sharedHost {
    static PTCustomInputViewHost *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PTCustomInputViewHost alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _inputPinnedConstraints = [[NSMutableArray alloc] init];
        _accessoryPinnedConstraints = [[NSMutableArray alloc] init];
        _lastPostedKeyboardFrame = CGRectZero;
        _lastLaidOutContainerSize = CGSizeZero;
    }
    return self;
}

- (BOOL)hasActivePresentation {
    return _isKeyboardVisible || _activeResponder != nil || _hostedInputView != nil;
}

- (PTCustomInputHostContainerView *)activeContainerView {
    if (_overlayWindow != nil && !_overlayWindow.isHidden) {
        return _overlayRootVC.hostContainerView;
    }
    if (_fallbackContainer != nil && _fallbackContainer.superview != nil) {
        return _fallbackContainer;
    }
    return nil;
}

- (BOOL)isViewNativelyPresentedOutsideHost:(UIView *)inputView {
    if (inputView == nil || inputView.window == nil) {
        return NO;
    }
    if (inputView.window == _overlayWindow) {
        return NO;
    }
    PTCustomInputHostContainerView *activeContainer = [self activeContainerView];
    if (activeContainer != nil && [inputView isDescendantOfView:activeContainer]) {
        return NO;
    }
    UIWindow *win = inputView.window;
    if (win.isHidden || inputView.isHidden || inputView.alpha <= 0.01) {
        return NO;
    }
    CGRect inWin = [inputView convertRect:inputView.bounds toView:win];
    if (CGRectIsEmpty(inWin) || CGRectGetWidth(inWin) < 1.0 || CGRectGetHeight(inWin) < 1.0) {
        return NO;
    }
    return CGRectIntersectsRect(win.bounds, inWin);
}

- (void)ensureOverlayWindowForScene:(UIWindowScene *)scene targetWindow:(UIWindow *)targetWindow {
    if (_overlayWindow != nil && _overlayWindow.windowScene == scene) {
        _overlayRootVC.targetAppWindow = targetWindow;
        return;
    }
    if (_overlayWindow != nil) {
        _overlayWindow.hidden = YES;
        _overlayWindow.rootViewController = nil;
        _overlayWindow = nil;
        _overlayRootVC = nil;
    }

    _overlayRootVC = [[PTCustomInputRootViewController alloc] init];
    _overlayRootVC.targetAppWindow = targetWindow;
    (void)_overlayRootVC.view;
    pt_tag_internal_overlay_object(_overlayRootVC.view);

    _overlayWindow = [[PTCustomInputWindow alloc] initWithWindowScene:scene];
    _overlayWindow.backgroundColor = [UIColor clearColor];
    _overlayWindow.opaque = NO;
    _overlayWindow.hidden = YES;
    _overlayWindow.userInteractionEnabled = YES;
    _overlayWindow.rootViewController = _overlayRootVC;
    _overlayWindow.hostContainerView = _overlayRootVC.hostContainerView;
    pt_tag_internal_overlay_object(_overlayWindow);
}

- (void)ensureFallbackContainerInWindow:(UIWindow *)targetWindow {
    if (_fallbackContainer == nil) {
        _fallbackContainer = [[PTCustomInputHostContainerView alloc] initWithFrame:targetWindow.bounds];
    }
    _fallbackContainer.frame = targetWindow.bounds;
    if (_fallbackContainer.superview != targetWindow) {
        [_fallbackContainer removeFromSuperview];
        [targetWindow addSubview:_fallbackContainer];
    }
    [targetWindow bringSubviewToFront:_fallbackContainer];
}

- (void)detachView:(UIView * __weak *)viewIvar
        savedState:(PTSavedHostedViewState *)savedState
       constraints:(NSMutableArray<NSLayoutConstraint *> *)constraints {
    UIView *v = *viewIvar;
    if (constraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:constraints];
        [constraints removeAllObjects];
    }
    if (v != nil) {
        PTCustomInputHostContainerView *container = [self activeContainerView];
        if (v.superview != nil &&
            ((container != nil && (v.superview == container.inputSlotView || v.superview == container.accessorySlotView)) ||
             (_overlayRootVC != nil &&
              (v.superview == _overlayRootVC.hostContainerView.inputSlotView ||
               v.superview == _overlayRootVC.hostContainerView.accessorySlotView)) ||
             (_fallbackContainer != nil &&
              (v.superview == _fallbackContainer.inputSlotView ||
               v.superview == _fallbackContainer.accessorySlotView)))) {
            [v removeFromSuperview];
        }
        if (savedState->valid) {
            v.transform = CGAffineTransformIdentity;
            if (savedState->translatesAutoresizingMaskIntoConstraints &&
                savedState->originalBoundsSize.width > 1.0 &&
                savedState->originalBoundsSize.height > 1.0) {
                CGRect b = v.bounds;
                b.size = savedState->originalBoundsSize;
                v.bounds = b;
            }
            v.transform = savedState->transform;
            v.autoresizingMask = savedState->autoresizingMask;
            v.translatesAutoresizingMaskIntoConstraints = savedState->translatesAutoresizingMaskIntoConstraints;
        }
    }
    *viewIvar = nil;
    savedState->valid = NO;
}

- (void)attachHostedView:(UIView *)view
                  toSlot:(UIView *)slotView
              savedState:(PTSavedHostedViewState *)savedState {
    if (view == nil || slotView == nil) {
        return;
    }
    savedState->valid = YES;
    savedState->transform = view.transform;
    savedState->autoresizingMask = view.autoresizingMask;
    savedState->translatesAutoresizingMaskIntoConstraints = view.translatesAutoresizingMaskIntoConstraints;
    savedState->originalBoundsSize = view.bounds.size;

    if (view.superview != slotView) {
        [view removeFromSuperview];
        [slotView addSubview:view];
    }
}

- (CGRect)screenFrameForDock:(UIView *)dockView
                    inWindow:(UIWindow *)containerWindow
                targetWindow:(UIWindow *)targetWindow {
    id<UICoordinateSpace> space = containerWindow.screen.coordinateSpace;
    if (space == nil && targetWindow != nil) {
        space = targetWindow.screen.coordinateSpace;
    }
    if (space == nil) {
        space = containerWindow ?: targetWindow;
    }
    if (space != nil) {
        return [dockView convertRect:dockView.bounds toCoordinateSpace:space];
    }
    return dockView.frame;
}

- (NSDictionary *)keyboardUserInfoWithBeginFrame:(CGRect)beginFrame
                                         endFrame:(CGRect)endFrame
                                         duration:(NSTimeInterval)duration {
    return @{
        UIKeyboardFrameBeginUserInfoKey : [NSValue valueWithCGRect:beginFrame],
        UIKeyboardFrameEndUserInfoKey : [NSValue valueWithCGRect:endFrame],
        UIKeyboardAnimationDurationUserInfoKey : @(duration),
        UIKeyboardAnimationCurveUserInfoKey : @(UIViewAnimationCurveEaseOut),
        UIKeyboardIsLocalUserInfoKey : @YES,
    };
}

- (void)postNotificationName:(NSNotificationName)name userInfo:(NSDictionary *)userInfo {
    if (_isPostingNotifications) {
        return;
    }
    _isPostingNotifications = YES;
    @try {
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:userInfo];
    } @finally {
        _isPostingNotifications = NO;
    }
}

- (PTComputedChildLayout)computeLayoutForView:(UIView *)view
                                    savedState:(const PTSavedHostedViewState *)savedState
                                     hostWidth:(CGFloat)hostW
                                     maxHeight:(CGFloat)maxAllowedH
                                       isInput:(BOOL)isInput {
    PTComputedChildLayout layout;
    memset(&layout, 0, sizeof(layout));
    if (view == nil) {
        return layout;
    }

    CGFloat clampedHostW = MAX(1.0, hostW);
    if (!view.translatesAutoresizingMaskIntoConstraints) {
        layout.usesAutoLayout = YES;
        layout.finalHeight = pt_measure_view_height(view,
                                                    clampedHostW,
                                                    isInput ? kPTDefaultInputHeight : kPTDefaultAccessoryHeight,
                                                    isInput ? kPTMinInputHeight : kPTMinAccessoryHeight,
                                                    maxAllowedH);
        return layout;
    }

    BOOL flexWidth = ((savedState != NULL && savedState->valid)
        ? ((savedState->autoresizingMask & UIViewAutoresizingFlexibleWidth) != 0)
        : ((view.autoresizingMask & UIViewAutoresizingFlexibleWidth) != 0));

    CGFloat rawW = view.bounds.size.width;
    if (savedState != NULL && savedState->valid && !flexWidth && savedState->originalBoundsSize.width > 1.0) {
        rawW = savedState->originalBoundsSize.width;
    }
    CGFloat rawH = pt_measure_view_height(view,
                                          clampedHostW,
                                          isInput ? kPTDefaultInputHeight : kPTDefaultAccessoryHeight,
                                          isInput ? kPTMinInputHeight : kPTMinAccessoryHeight,
                                          maxAllowedH);
    layout.rawW = rawW;
    layout.rawH = rawH;

    if (!isfinite(rawW) || rawW <= 1.0 || fabs(rawW - clampedHostW) <= 2.0 || flexWidth) {
        layout.fillsWidth = YES;
        layout.finalHeight = rawH;
        return layout;
    }

    if (rawW < clampedHostW - 2.0) {
        layout.centeredX = floor((clampedHostW - rawW) * 0.5);
        layout.finalHeight = rawH;
        return layout;
    }

    // Fixed-width panel wider than current window (e.g., narrow portrait/split window):
    // scale uniformly so all buttons remain visible and clickable without truncation.
    CGFloat scale = clampedHostW / rawW;
    CGFloat scaledH = ceil(rawH * scale);
    if (scaledH > maxAllowedH && scaledH > 0.0) {
        scaledH = maxAllowedH;
    }
    layout.usesScale = YES;
    layout.scale = scale;
    layout.finalHeight = scaledH;
    return layout;
}

- (void)applyLayout:(PTComputedChildLayout)layout
             toView:(UIView *)view
             inSlot:(UIView *)slotView
          hostWidth:(CGFloat)hostW
        constraints:(NSMutableArray<NSLayoutConstraint *> *)constraints {
    if (view == nil || slotView == nil) {
        return;
    }

    if (constraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:constraints];
        [constraints removeAllObjects];
    }

    CGFloat clampedHostW = MAX(1.0, hostW);
    if (layout.usesAutoLayout) {
        view.transform = CGAffineTransformIdentity;
        NSLayoutConstraint *lead = [view.leadingAnchor constraintEqualToAnchor:slotView.leadingAnchor];
        NSLayoutConstraint *trail = [view.trailingAnchor constraintEqualToAnchor:slotView.trailingAnchor];
        NSLayoutConstraint *top = [view.topAnchor constraintEqualToAnchor:slotView.topAnchor];
        NSLayoutConstraint *bottom = [view.bottomAnchor constraintEqualToAnchor:slotView.bottomAnchor];
        bottom.priority = UILayoutPriorityDefaultHigh;
        NSLayoutConstraint *heightC = [view.heightAnchor constraintEqualToConstant:layout.finalHeight];
        heightC.priority = UILayoutPriorityDefaultHigh + 1.0f;
        [constraints addObjectsFromArray:@[lead, trail, top, bottom, heightC]];
        [NSLayoutConstraint activateConstraints:constraints];
        [slotView layoutIfNeeded];
        return;
    }

    view.transform = CGAffineTransformIdentity;
    if (layout.fillsWidth) {
        view.frame = CGRectMake(0.0, 0.0, clampedHostW, layout.finalHeight);
        return;
    }
    if (layout.usesScale) {
        view.bounds = CGRectMake(0.0, 0.0, layout.rawW, layout.rawH);
        view.transform = CGAffineTransformMakeScale(layout.scale, layout.scale);
        view.center = CGPointMake(clampedHostW * 0.5, layout.finalHeight * 0.5);
        return;
    }
    view.frame = CGRectMake(layout.centeredX, 0.0, layout.rawW, layout.finalHeight);
}

- (void)presentResponder:(UIResponder *)responder {
    UIView *inputView = pt_resolve_custom_input_view(responder);
    if (inputView == nil) {
        [self dismissIfActive];
        return;
    }

    if ([self isViewNativelyPresentedOutsideHost:inputView]) {
        if ([self hasActivePresentation]) {
            [self dismissIfActive];
        }
        return;
    }

    UIWindow *targetWindow = pt_resolve_window_for_responder(responder);
    if (targetWindow == nil || targetWindow.isHidden) {
        return;
    }

    UIView *accessoryView = pt_resolve_custom_accessory_view(responder, inputView);

    BOOL wasVisible = _isKeyboardVisible;
    CGRect prevPostedFrame = _lastPostedKeyboardFrame;

    PTCustomInputHostContainerView *container = nil;
    UIWindow *hostWindowForLayout = nil;
    if (targetWindow.windowScene != nil) {
        if (_fallbackContainer != nil && _fallbackContainer.superview != nil) {
            [_fallbackContainer removeFromSuperview];
        }
        [self ensureOverlayWindowForScene:targetWindow.windowScene targetWindow:targetWindow];
        CGRect sceneBounds = targetWindow.frame;
        if (CGRectIsEmpty(sceneBounds) || CGRectGetWidth(sceneBounds) <= 1.0 || CGRectGetHeight(sceneBounds) <= 1.0) {
            if (@available(macCatalyst 16.0, iOS 16.0, *)) {
                sceneBounds = targetWindow.windowScene.effectiveGeometry.coordinateSpace.bounds;
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (CGRectIsEmpty(sceneBounds) || CGRectGetWidth(sceneBounds) <= 1.0 || CGRectGetHeight(sceneBounds) <= 1.0) {
            sceneBounds = targetWindow.windowScene.coordinateSpace.bounds;
        }
#pragma clang diagnostic pop
        if (CGRectIsEmpty(sceneBounds) || CGRectGetWidth(sceneBounds) <= 1.0 || CGRectGetHeight(sceneBounds) <= 1.0) {
            sceneBounds = UIScreen.mainScreen.bounds;
        }
        _overlayWindow.frame = sceneBounds;
        _overlayWindow.windowLevel = MAX(targetWindow.windowLevel + 10.0, UIWindowLevelAlert - 1.0);
        _overlayWindow.hidden = NO;
        container = _overlayRootVC.hostContainerView;
        container.frame = _overlayWindow.bounds;
        hostWindowForLayout = _overlayWindow;
    } else {
        if (_overlayWindow != nil) {
            _overlayWindow.hidden = YES;
        }
        [self ensureFallbackContainerInWindow:targetWindow];
        container = _fallbackContainer;
        hostWindowForLayout = targetWindow;
    }

    BOOL needInputReattach = (_hostedInputView != inputView || inputView.superview != container.inputSlotView);
    BOOL needAccReattach = (_hostedAccessoryView != accessoryView ||
                            (accessoryView != nil && accessoryView.superview != container.accessorySlotView));

    if (needInputReattach) {
        [self detachView:&_hostedInputView savedState:&_savedInputState constraints:_inputPinnedConstraints];
    }
    if (needAccReattach) {
        [self detachView:&_hostedAccessoryView savedState:&_savedAccessoryState constraints:_accessoryPinnedConstraints];
    }

    _activeResponder = responder;
    _targetWindow = targetWindow;

    if (needInputReattach) {
        _hostedInputView = inputView;
        [self attachHostedView:inputView toSlot:container.inputSlotView savedState:&_savedInputState];
    }
    if (needAccReattach && accessoryView != nil) {
        _hostedAccessoryView = accessoryView;
        [self attachHostedView:accessoryView toSlot:container.accessorySlotView savedState:&_savedAccessoryState];
    }

    _isLayingOut = YES;
    CGFloat hostW = container.bounds.size.width;
    CGFloat hostH = container.bounds.size.height;
    if (!isfinite(hostW) || hostW <= 1.0) {
        hostW = targetWindow.bounds.size.width;
    }
    if (!isfinite(hostH) || hostH <= 1.0) {
        hostH = targetWindow.bounds.size.height;
    }
    CGFloat maxTrayH = MAX(kPTMinInputHeight, floor(hostH * kPTMaxTrayHeightRatio));

    PTComputedChildLayout accLayout;
    memset(&accLayout, 0, sizeof(accLayout));
    if (accessoryView != nil) {
        CGFloat maxAccH = MIN(kPTMaxAccessoryHeight, MAX(kPTMinAccessoryHeight, floor(maxTrayH * 0.35)));
        accLayout = [self computeLayoutForView:accessoryView
                                    savedState:&_savedAccessoryState
                                     hostWidth:hostW
                                     maxHeight:maxAccH
                                       isInput:NO];
    }

    CGFloat maxInputH = MAX(kPTMinInputHeight, maxTrayH - accLayout.finalHeight);
    PTComputedChildLayout inputLayout = [self computeLayoutForView:inputView
                                                        savedState:&_savedInputState
                                                         hostWidth:hostW
                                                         maxHeight:maxInputH
                                                           isInput:YES];

    CGFloat accessoryH = accLayout.finalHeight;
    CGFloat inputH = inputLayout.finalHeight;
    CGFloat totalH = accessoryH + inputH;

    // Position the dock and slot containers BEFORE sizing the hosted children
    // so slot geometry settles cleanly without triggering inverse autoresizing.
    container.dockView.backgroundColor = inputView.backgroundColor ?: [UIColor secondarySystemBackgroundColor];
    container.accessorySlotView.hidden = (accessoryH <= 0.0);
    container.accessorySlotView.frame = CGRectMake(0.0, 0.0, hostW, accessoryH);
    container.inputSlotView.frame = CGRectMake(0.0, accessoryH, hostW, inputH);
    container.topHairlineView.frame = CGRectMake(0.0, 0.0, hostW, 0.5);
    container.dockView.hidden = NO;

    CGRect finalDockFrame = CGRectMake(0.0, MAX(0.0, hostH - totalH), hostW, totalH);
    container.dockView.frame = finalDockFrame;

    if (accessoryView != nil) {
        [self applyLayout:accLayout
                   toView:accessoryView
                   inSlot:container.accessorySlotView
                hostWidth:hostW
              constraints:_accessoryPinnedConstraints];
    }
    [self applyLayout:inputLayout
               toView:inputView
               inSlot:container.inputSlotView
            hostWidth:hostW
          constraints:_inputPinnedConstraints];
    [inputView layoutIfNeeded];
    if (accessoryView != nil) {
        [accessoryView layoutIfNeeded];
    }
    _lastLaidOutContainerSize = container.bounds.size;

    CGRect endScreenFrame = [self screenFrameForDock:container.dockView
                                            inWindow:hostWindowForLayout
                                        targetWindow:targetWindow];
    CGRect beginScreenFrame = wasVisible && !CGRectIsEmpty(prevPostedFrame)
        ? prevPostedFrame
        : CGRectMake(endScreenFrame.origin.x,
                     endScreenFrame.origin.y + endScreenFrame.size.height,
                     endScreenFrame.size.width,
                     endScreenFrame.size.height);

    BOOL shouldAnimateShow = (!wasVisible && [UIView areAnimationsEnabled]);
    NSTimeInterval duration = shouldAnimateShow ? kPTShowAnimationDuration : 0.0;
    if (shouldAnimateShow) {
        container.dockView.frame = CGRectMake(0.0, hostH, hostW, totalH);
    }
    _isLayingOut = NO;

    _isKeyboardVisible = YES;
    _lastPostedKeyboardFrame = endScreenFrame;
    uint64_t animToken = _animationToken;
    if (shouldAnimateShow) {
        _animationToken++;
        animToken = _animationToken;
    }

    if (!wasVisible) {
        NSDictionary *info = [self keyboardUserInfoWithBeginFrame:beginScreenFrame
                                                        endFrame:endScreenFrame
                                                        duration:duration];
        [self postNotificationName:UIKeyboardWillShowNotification userInfo:info];
        [self postNotificationName:UIKeyboardWillChangeFrameNotification userInfo:info];
    } else if (!CGRectEqualToRect(prevPostedFrame, endScreenFrame)) {
        NSDictionary *info = [self keyboardUserInfoWithBeginFrame:beginScreenFrame
                                                        endFrame:endScreenFrame
                                                        duration:0.0];
        [self postNotificationName:UIKeyboardWillChangeFrameNotification userInfo:info];
    }

    if (shouldAnimateShow) {
        __weak typeof(self) weakSelf = self;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             container.dockView.frame = finalDockFrame;
                         }
                         completion:^(BOOL finished) {
                             (void)finished;
                             PTCustomInputViewHost *strongSelf = weakSelf;
                             if (strongSelf == nil || strongSelf->_animationToken != animToken || !strongSelf->_isKeyboardVisible) {
                                 return;
                             }
                             NSDictionary *doneInfo = [strongSelf keyboardUserInfoWithBeginFrame:beginScreenFrame
                                                                                        endFrame:endScreenFrame
                                                                                        duration:duration];
                             [strongSelf postNotificationName:UIKeyboardDidShowNotification userInfo:doneInfo];
                             [strongSelf postNotificationName:UIKeyboardDidChangeFrameNotification userInfo:doneInfo];
                         }];
    } else {
        NSDictionary *doneInfo = [self keyboardUserInfoWithBeginFrame:beginScreenFrame
                                                             endFrame:endScreenFrame
                                                             duration:0.0];
        if (!wasVisible) {
            [self postNotificationName:UIKeyboardDidShowNotification userInfo:doneInfo];
            [self postNotificationName:UIKeyboardDidChangeFrameNotification userInfo:doneInfo];
        } else if (!CGRectEqualToRect(prevPostedFrame, endScreenFrame)) {
            [self postNotificationName:UIKeyboardDidChangeFrameNotification userInfo:doneInfo];
        }
    }
}

- (void)dismissIfActive {
    if (![self hasActivePresentation]) {
        return;
    }

    BOOL wasVisible = _isKeyboardVisible;
    PTCustomInputHostContainerView *container = [self activeContainerView];
    CGRect beginScreenFrame = _lastPostedKeyboardFrame;
    CGRect endScreenFrame = beginScreenFrame;
    if (CGRectGetHeight(beginScreenFrame) > 0.0) {
        endScreenFrame.origin.y += beginScreenFrame.size.height;
    }

    _activeResponder = nil;
    _targetWindow = nil;
    _isKeyboardVisible = NO;
    _lastPostedKeyboardFrame = CGRectZero;
    _lastLaidOutContainerSize = CGSizeZero;
    _animationToken++;
    uint64_t animToken = _animationToken;

    BOOL shouldAnimateHide = (wasVisible && container != nil && !container.dockView.isHidden && [UIView areAnimationsEnabled]);
    NSTimeInterval duration = shouldAnimateHide ? kPTHideAnimationDuration : 0.0;

    if (wasVisible) {
        NSDictionary *hideInfo = [self keyboardUserInfoWithBeginFrame:beginScreenFrame
                                                            endFrame:endScreenFrame
                                                            duration:duration];
        [self postNotificationName:UIKeyboardWillHideNotification userInfo:hideInfo];
        [self postNotificationName:UIKeyboardWillChangeFrameNotification userInfo:hideInfo];
    }

    void (^finishDismiss)(PTCustomInputViewHost *) = ^(PTCustomInputViewHost *host) {
        [host detachView:&host->_hostedInputView savedState:&host->_savedInputState constraints:host->_inputPinnedConstraints];
        [host detachView:&host->_hostedAccessoryView savedState:&host->_savedAccessoryState constraints:host->_accessoryPinnedConstraints];
        if (host->_overlayRootVC != nil) {
            host->_overlayRootVC.hostContainerView.dockView.hidden = YES;
            host->_overlayRootVC.targetAppWindow = nil;
        }
        if (host->_overlayWindow != nil) {
            host->_overlayWindow.hidden = YES;
        }
        if (host->_fallbackContainer != nil) {
            host->_fallbackContainer.dockView.hidden = YES;
            [host->_fallbackContainer removeFromSuperview];
        }
        if (wasVisible) {
            NSDictionary *doneInfo = [host keyboardUserInfoWithBeginFrame:beginScreenFrame
                                                                endFrame:endScreenFrame
                                                                duration:duration];
            [host postNotificationName:UIKeyboardDidHideNotification userInfo:doneInfo];
            [host postNotificationName:UIKeyboardDidChangeFrameNotification userInfo:doneInfo];
        }
    };

    if (shouldAnimateHide) {
        CGFloat hostH = container.bounds.size.height;
        CGRect dockFrame = container.dockView.frame;
        CGRect offscreenFrame = CGRectMake(dockFrame.origin.x, hostH, dockFrame.size.width, dockFrame.size.height);
        __weak typeof(self) weakSelf = self;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             container.dockView.frame = offscreenFrame;
                         }
                         completion:^(BOOL finished) {
                             (void)finished;
                             PTCustomInputViewHost *strongSelf = weakSelf;
                             if (strongSelf == nil || strongSelf->_animationToken != animToken || strongSelf->_isKeyboardVisible) {
                                 return;
                             }
                             finishDismiss(strongSelf);
                         }];
    } else {
        finishDismiss(self);
    }
}

- (void)evaluateCurrentState {
    UIResponder *active = _activeResponder;
    if (active != nil && [active isFirstResponder]) {
        [self presentResponder:active];
        return;
    }
    [self dismissIfActive];
}

- (void)customInputContainerDidLayout:(PTCustomInputHostContainerView *)container {
    if (_isLayingOut || ![self hasActivePresentation]) {
        return;
    }
    UIResponder *active = _activeResponder;
    if (active == nil || ![active isFirstResponder]) {
        [self dismissIfActive];
        return;
    }
    if ([active isKindOfClass:[UIView class]] && ((UIView *)active).window == nil) {
        [self dismissIfActive];
        return;
    }
    if (_isKeyboardVisible &&
        container != nil &&
        fabs(container.bounds.size.width - _lastLaidOutContainerSize.width) < 0.5 &&
        fabs(container.bounds.size.height - _lastLaidOutContainerSize.height) < 0.5 &&
        _hostedInputView != nil &&
        _hostedInputView.superview == container.inputSlotView) {
        return;
    }
    [self presentResponder:active];
}

- (void)scheduleEvaluationForBecomeFirstResponder:(UIResponder *)responder {
    if (responder == nil) {
        return;
    }
    BOOL wantsCustom = pt_responder_has_custom_input(responder);
    if (!wantsCustom && ![self hasActivePresentation]) {
        return;
    }
    _transitionGeneration++;
    uint64_t expectedGen = _transitionGeneration;
    __weak UIResponder *weakResponder = responder;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTCustomInputViewHost *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_transitionGeneration != expectedGen) {
            return;
        }
        UIResponder *strongResponder = weakResponder;
        if (strongResponder != nil && [strongResponder isFirstResponder]) {
            [strongSelf presentResponder:strongResponder];
        } else {
            [strongSelf evaluateCurrentState];
        }
    });
}

- (void)scheduleEvaluationForResignFirstResponder:(UIResponder *)responder {
    if (![self hasActivePresentation]) {
        return;
    }
    if (responder != nil && _activeResponder != nil && responder != _activeResponder) {
        return;
    }
    _transitionGeneration++;
    uint64_t expectedGen = _transitionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTCustomInputViewHost *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_transitionGeneration != expectedGen) {
            return;
        }
        [strongSelf evaluateCurrentState];
    });
}

- (void)scheduleEvaluationForReloadInputViews:(UIResponder *)responder {
    if (responder == nil || ![responder isFirstResponder]) {
        return;
    }
    BOOL wantsCustom = pt_responder_has_custom_input(responder);
    if (!wantsCustom && ![self hasActivePresentation]) {
        return;
    }
    _transitionGeneration++;
    uint64_t expectedGen = _transitionGeneration;
    __weak UIResponder *weakResponder = responder;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        PTCustomInputViewHost *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_transitionGeneration != expectedGen) {
            return;
        }
        UIResponder *strongResponder = weakResponder;
        if (strongResponder != nil && [strongResponder isFirstResponder]) {
            [strongSelf presentResponder:strongResponder];
        } else {
            [strongSelf evaluateCurrentState];
        }
    });
}

- (void)handleTextInputDidBegin:(UIResponder *)responder {
    if (responder != nil && [responder isFirstResponder] && pt_responder_has_custom_input(responder)) {
        [self scheduleEvaluationForBecomeFirstResponder:responder];
    } else if ([self hasActivePresentation]) {
        [self scheduleEvaluationForResignFirstResponder:nil];
    }
}

- (void)handleTextInputDidEnd:(UIResponder *)responder {
    if (![self hasActivePresentation]) {
        return;
    }
    if (responder == nil || responder == _activeResponder || _activeResponder == nil || ![_activeResponder isFirstResponder]) {
        [self scheduleEvaluationForResignFirstResponder:responder];
    }
}

- (void)handleWindowDidBecomeHidden:(UIWindow *)window {
    if (![self hasActivePresentation]) {
        return;
    }
    if (window == nil || window == _targetWindow) {
        [self dismissIfActive];
    }
}

- (void)handleHostWindowGeometryChanged {
    if (![self hasActivePresentation]) {
        return;
    }
    [self evaluateCurrentState];
}

@end

@implementation PSSwizzleHooks (PTCustomInputViewHost)

- (BOOL)pm_ptkb_becomeFirstResponder {
    BOOL became = [self pm_ptkb_becomeFirstResponder];
    if (became && [self isKindOfClass:[UIResponder class]]) {
        UIResponder *resp = (UIResponder *)self;
        if ([NSThread isMainThread]) {
            [[PTCustomInputViewHost sharedHost] scheduleEvaluationForBecomeFirstResponder:resp];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[PTCustomInputViewHost sharedHost] scheduleEvaluationForBecomeFirstResponder:resp];
            });
        }
    }
    return became;
}

- (BOOL)pm_ptkb_resignFirstResponder {
    BOOL resigned = [self pm_ptkb_resignFirstResponder];
    if (resigned && [self isKindOfClass:[UIResponder class]]) {
        UIResponder *resp = (UIResponder *)self;
        if ([NSThread isMainThread]) {
            [[PTCustomInputViewHost sharedHost] scheduleEvaluationForResignFirstResponder:resp];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[PTCustomInputViewHost sharedHost] scheduleEvaluationForResignFirstResponder:resp];
            });
        }
    }
    return resigned;
}

- (void)pm_ptkb_reloadInputViews {
    [self pm_ptkb_reloadInputViews];
    if ([self isKindOfClass:[UIResponder class]]) {
        UIResponder *resp = (UIResponder *)self;
        if ([NSThread isMainThread]) {
            [[PTCustomInputViewHost sharedHost] scheduleEvaluationForReloadInputViews:resp];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[PTCustomInputViewHost sharedHost] scheduleEvaluationForReloadInputViews:resp];
            });
        }
    }
}

@end

__attribute__((visibility("hidden"))) void ps_install_custom_input_view_host(void) {
    const char *disableEnv = pt_raw_getenv("PLAYTOOLS_DISABLE_CUSTOM_INPUT_HOST");
    if (disableEnv != NULL && strcmp(disableEnv, "1") == 0) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_register_hidden_class("PTCustomInputWindow");
        pt_register_hidden_class("PTCustomInputRootViewController");
        pt_register_hidden_class("PTCustomInputHostContainerView");
        pt_register_hidden_class("PTCustomInputViewHost");

        Class responderCls = objc_getClass("UIResponder");
        if (responderCls != Nil) {
            ps_swizzle_instance_method(responderCls,
                                       @selector(becomeFirstResponder),
                                       @selector(pm_ptkb_becomeFirstResponder));
            ps_swizzle_instance_method(responderCls,
                                       @selector(resignFirstResponder),
                                       @selector(pm_ptkb_resignFirstResponder));
            ps_swizzle_instance_method(responderCls,
                                       @selector(reloadInputViews),
                                       @selector(pm_ptkb_reloadInputViews));
        }

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];

        [nc addObserverForName:UITextFieldTextDidBeginEditingNotification
                        object:nil
                         queue:mainQueue
                    usingBlock:^(NSNotification *note) {
                        if ([note.object isKindOfClass:[UIResponder class]]) {
                            [[PTCustomInputViewHost sharedHost] handleTextInputDidBegin:(UIResponder *)note.object];
                        }
                    }];
        [nc addObserverForName:UITextFieldTextDidEndEditingNotification
                        object:nil
                         queue:mainQueue
                    usingBlock:^(NSNotification *note) {
                        if ([note.object isKindOfClass:[UIResponder class]]) {
                            [[PTCustomInputViewHost sharedHost] handleTextInputDidEnd:(UIResponder *)note.object];
                        }
                    }];
        [nc addObserverForName:UITextViewTextDidBeginEditingNotification
                        object:nil
                         queue:mainQueue
                    usingBlock:^(NSNotification *note) {
                        if ([note.object isKindOfClass:[UIResponder class]]) {
                            [[PTCustomInputViewHost sharedHost] handleTextInputDidBegin:(UIResponder *)note.object];
                        }
                    }];
        [nc addObserverForName:UITextViewTextDidEndEditingNotification
                        object:nil
                         queue:mainQueue
                    usingBlock:^(NSNotification *note) {
                        if ([note.object isKindOfClass:[UIResponder class]]) {
                            [[PTCustomInputViewHost sharedHost] handleTextInputDidEnd:(UIResponder *)note.object];
                        }
                    }];
        [nc addObserverForName:UIWindowDidBecomeHiddenNotification
                        object:nil
                         queue:mainQueue
                    usingBlock:^(NSNotification *note) {
                        if ([note.object isKindOfClass:[UIWindow class]]) {
                            [[PTCustomInputViewHost sharedHost] handleWindowDidBecomeHidden:(UIWindow *)note.object];
                        }
                    }];
        [nc addObserverForName:@"NSWindowDidEndLiveResizeNotification"
                        object:nil
                         queue:mainQueue
                    usingBlock:^(NSNotification *note) {
                        (void)note;
                        [[PTCustomInputViewHost sharedHost] handleHostWindowGeometryChanged];
                    }];
    });
}
