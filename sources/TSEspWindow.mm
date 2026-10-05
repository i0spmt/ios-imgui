//
//  TSEspWindow.mm
//  imgui
//

#import "TSEspWindow.h"

@implementation TSEspWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }

// The whole point of this window: permanently struck off the hit test, so the
// full-screen Metal surface it hosts is transparent to touches no matter what
// it draws.
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_usesWindowServerHitTesting { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }

@end

@implementation TSEspRootViewController

- (void)loadView
{
    UIView *view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    view.backgroundColor = [UIColor clearColor];
    view.userInteractionEnabled = NO;   // nothing in this branch is interactive
    self.view = view;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate
{
    // The content is rotated by hand through a transform, like the menu
    // window's; UIKit must not rotate this one as well.
    return NO;
}

@end
