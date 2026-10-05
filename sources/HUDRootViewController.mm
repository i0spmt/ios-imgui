//
//  HUDRootViewController.mm
//  imgui
//
//  Root view controller of the HUD process. It owns the ImGui overlay, keeps
//  it oriented with the device, and tears the process down when the app is
//  uninstalled.
//

#import <notify.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#import "HUDRootViewController.h"
#import "TSEspView.h"
#import "TSEspWindow.h"
#import "TSImGuiView.h"

#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"

#import "FBSOrientationUpdate.h"
#import "FBSOrientationObserver.h"
#import "UIApplication+Private.h"
#import "LSApplicationProxy.h"
#import "LSApplicationWorkspace.h"
#import "SpringBoardServices.h"

#define NOTIFY_UI_LOCKSTATE    "com.apple.springboard.lockstate"
#define NOTIFY_LS_APP_CHANGED  "com.apple.LaunchServices.ApplicationsChanged"

#pragma mark -

// Tap target that re-opens the ImGui menu once it has been closed.
//
// Touches are handled directly rather than through a UITapGestureRecognizer:
// in the HUD process every touch is synthesised from an AX event, and gesture
// recognition does not fire reliably for those.
@interface TSMenuHotspotView : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation TSMenuHotspotView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (self.onTap) {
        self.onTap();
    }
}

@end

#pragma mark -

@interface HUDRootViewController ()
- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration;
- (void)setEspWindowHidden:(BOOL)hidden;
@end

#pragma mark - Notification callbacks

static void LaunchServicesApplicationStateChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    /* Application installed or uninstalled */

    BOOL isAppInstalled = NO;

    for (LSApplicationProxy *app in [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allApplications])
    {
        if ([app.applicationIdentifier isEqualToString:@"imgui.test.iospmt"])
        {
            isAppInstalled = YES;
            break;
        }
    }

    if (!isAppInstalled)
    {
        [[UIApplication sharedApplication] terminateWithSuccess];
    }
}

static void SpringBoardLockStatusChanged
(CFNotificationCenterRef center,
 void *observer,
 CFStringRef name,
 const void *object,
 CFDictionaryRef userInfo)
{
    HUDRootViewController *rootViewController = (__bridge HUDRootViewController *)observer;
    NSString *lockState = (__bridge NSString *)name;
    if (![lockState isEqualToString:@NOTIFY_UI_LOCKSTATE]) {
        return;
    }

    mach_port_t sbsPort = SBSSpringBoardServerPort();
    if (sbsPort == MACH_PORT_NULL) {
        return;
    }

    BOOL isLocked;
    BOOL isPasscodeSet;
    SBGetScreenLockStatus(sbsPort, &isLocked, &isPasscodeSet);

    // Hiding the root view also stops the Metal view from drawing, so the
    // overlay costs nothing while the device is locked.
    [rootViewController.view setHidden:isLocked];
    [rootViewController setEspWindowHidden:isLocked];
}

#pragma mark - Orientation helpers

static inline CGFloat orientationAngle(UIInterfaceOrientation orientation)
{
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown:
            return M_PI;
        case UIInterfaceOrientationLandscapeLeft:
            return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
            return M_PI_2;
        default:
            return 0;
    }
}

static inline CGRect orientationBounds(UIInterfaceOrientation orientation, CGRect bounds)
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            // Only the landscape cases swap: upside down is a 180° turn, which
            // leaves the extent unchanged.
            return CGRectMake(0, 0, bounds.size.height, bounds.size.width);
        default:
            return bounds;
    }
}

#pragma mark -

@implementation HUDRootViewController {
    UIInterfaceOrientation _orientation;
    FBSOrientationObserver *_orientationObserver;
    TSEspWindow *_espWindow;
    SBSAccessibilityWindowHostingController *_espWindowHostingController;
    TSEspView *_espView;
    TSImGuiView *_imguiView;
    TSMenuHotspotView *_menuHotspotView;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _orientationObserver = [[objc_getClass("FBSOrientationObserver") alloc] init];
        __weak typeof(self) weakSelf = self;
        [_orientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
            // The handler fires on an arbitrary queue; all UI work belongs on
            // the main one.
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf updateOrientation:(UIInterfaceOrientation)orientationUpdate.orientation
                        animateWithDuration:orientationUpdate.duration];
            });
        }];

        [self registerNotifications];
    }
    return self;
}

- (void)dealloc
{
    [_orientationObserver invalidate];
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

- (void)registerNotifications
{
    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        LaunchServicesApplicationStateChanged,
        CFSTR(NOTIFY_LS_APP_CHANGED),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        SpringBoardLockStatusChanged,
        CFSTR(NOTIFY_UI_LOCKSTATE),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
}

#pragma mark - Shape layer window

- (void)setupEspWindow
{
    if (_espWindow) {
        return;
    }

    _espWindow = [[TSEspWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _espWindow.backgroundColor = [UIColor clearColor];
    _espWindow.opaque = NO;
    _espWindow.userInteractionEnabled = NO;
    _espWindow.rootViewController = [[TSEspRootViewController alloc] init];
    // One level below the menu window, so the menu always draws on top.
    [_espWindow setWindowLevel:10000009.0];
    [_espWindow setHidden:NO];

    _espView = [[TSEspView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_espWindow.rootViewController.view addSubview:_espView];

    // Like the menu window, this one has to be registered with SpringBoard to
    // be composited above other apps.
    _espWindowHostingController = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init];
    unsigned int contextId = [_espWindow _contextId];
    double windowLevel = [_espWindow windowLevel];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:_espWindowHostingController];
    [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [invocation setArgument:&contextId atIndex:2];
    [invocation setArgument:&windowLevel atIndex:3];
    [invocation invoke];
#pragma clang diagnostic pop
}

- (void)setEspWindowHidden:(BOOL)hidden
{
    [_espWindow setHidden:hidden];
}

#pragma mark - View

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self setupEspWindow];

    // Tap target at the centre of the screen that re-opens the menu. The
    // near-zero alpha sits on the background colour, not on the view's own
    // alpha: UIKit skips hit testing for a view whose alpha is at or below
    // 0.01, so making the view itself transparent would stop it receiving the
    // tap. This way it is invisible but still hit-testable.
    _menuHotspotView = [[TSMenuHotspotView alloc] init];
    _menuHotspotView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.001];
    _menuHotspotView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_menuHotspotView];
    [NSLayoutConstraint activateConstraints:@[
        [_menuHotspotView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_menuHotspotView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_menuHotspotView.widthAnchor constraintEqualToConstant:32.0],
        [_menuHotspotView.heightAnchor constraintEqualToConstant:32.0],
    ]];

    // self.view.bounds can still be CGRectZero in viewDidLoad; use the main
    // screen so the Metal view is created at the real screen size.
    _imguiView = [[TSImGuiView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _imguiView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_imguiView];

    __weak typeof(self) weakSelf = self;
    _menuHotspotView.onTap = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf->_imguiView setMenuVisible:YES];
    };

    // The hotspot would otherwise sit under the ImGui window and take taps
    // meant for it, so the two are kept mutually exclusive.
    _imguiView.menuVisibilityChanged = ^(BOOL visible) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf->_menuHotspotView.hidden = visible;
        strongSelf->_menuHotspotView.userInteractionEnabled = !visible;
    };

    _imguiView.espEnabledChanged = ^(BOOL enabled) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf->_espView setEspEnabled:enabled];
    };

    [_imguiView setMenuVisible:YES];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    notify_post(NOTIFY_LAUNCHED_HUD);
}

#pragma mark - Orientation

- (void)updateOrientation:(UIInterfaceOrientation)orientation animateWithDuration:(NSTimeInterval)duration
{
    if (orientation == _orientation) {
        return;
    }
    _orientation = orientation;

    // Always measured from the untouched portrait screen rect, never from the
    // current bounds, so repeated rotations cannot accumulate error.
    CGRect bounds = orientationBounds(orientation, [UIScreen mainScreen].bounds);

    // Hidden before the geometry changes: between the new bounds and the new
    // transform the view is briefly inconsistent, and a single frame in that
    // state shows the overlay skewed across the screen.
    [self.view setHidden:YES];

    // setBounds, not setFrame: this preserves the centre, so rotating about it
    // still covers the screen exactly. setFrame would shift the centre and the
    // view would end up off screen.
    [self.view setBounds:bounds];

    // Resize the overlay explicitly rather than leaving it to autoresizing:
    // autoresizing scales proportionally when width and height swap, which
    // does not give an exact match for the Metal drawable.
    [_imguiView setFrame:self.view.bounds];

    // The shape layer lives in its own window, which is never rotated either,
    // so its content view gets the same treatment by hand.
    UIView *espRootView = _espWindow.rootViewController.view;
    [espRootView setHidden:YES];
    [espRootView setBounds:bounds];
    [_espView setFrame:espRootView.bounds];

    const CGFloat angle = orientationAngle(orientation);

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration animations:^{
        [weakSelf.view setTransform:CGAffineTransformMakeRotation(angle)];
        [espRootView setTransform:CGAffineTransformMakeRotation(angle)];
    } completion:^(BOOL finished) {
        [weakSelf.view setHidden:NO];
        [espRootView setHidden:NO];
    }];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    // The device orientation is tracked through FBSOrientationObserver and
    // applied by hand above; UIKit must not rotate this window as well.
    return UIInterfaceOrientationMaskPortrait;
}

@end
