//
//  HUDMainWindow.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import "HUDMainWindow.h"
#import "HUDRootViewController.h"

@implementation HUDMainWindow

- (instancetype)initWithFrame:(CGRect)frame
{
    // Build the window detached from the default scene. A scene-attached
    // window has its hit testing taken over by the render server, which
    // decides the window owns a touch before UIKit is ever asked — so
    // returning nil from hitTest below would change nothing and every touch
    // would be swallowed, leaving the screen under the HUD dead. Detached, the
    // decision stays in this process.
    //
    // The private initialiser skips the public init chain, so commonInit —
    // which sets up the rotation-following state — has to be called by hand.
    // Fall back to the public initialiser if a build lacks the private one.
    if ([self respondsToSelector:@selector(_initWithFrame:attached:)]) {
        self = [super _initWithFrame:frame attached:NO];
    } else {
        self = [super initWithFrame:frame];
    }

    if (self) {
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

// HUDRootViewController drives orientation itself: on every change it swaps
// its view's bounds and applies a rotation transform. If the window also
// followed the application's rotation, the two would compose and the overlay
// would come out rotated twice.
- (BOOL)_shouldControlAutorotation { return NO; }
- (BOOL)isInterfaceAutorotationDisabled { return YES; }

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }

// Fixed at NO on purpose. The window server caches this flag when the window
// is registered, so flipping it at runtime has no effect — a window that
// starts out ignoring hit tests never starts accepting them. Pass-through is
// therefore decided per view instead: everything that should not capture a
// touch returns nil from hitTest, which lets the event fall through to
// whatever is underneath.
- (BOOL)_ignoresHitTest { return NO; }

// Required for the per-view pass-through above to work at all: it keeps hit
// testing in this process rather than in the render server.
- (BOOL)_usesWindowServerHitTesting { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    // Ask the content directly rather than going through super, which would
    // also offer the window itself as a candidate.
    UIView *hitView = [self.rootViewController.view hitTest:point withEvent:event];

    // Nothing interactive claimed the point — the root view itself is just a
    // transparent full-screen container. Returning nil lets the touch reach
    // whatever is behind the HUD instead of being swallowed by it.
    if (!hitView || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}

@end
