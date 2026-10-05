//
//  TSEspWindow.h
//  imgui
//
//  A window dedicated to the pass-through shape layer.
//
//  The shape layer has to live in a window of its own rather than beside the
//  menu, because the window server caches _ignoresHitTest when the window is
//  registered and never re-reads it. The menu window must hit test so the menu
//  can be tapped — but a full-screen Metal surface inside a hit-testing window
//  claims the whole screen, and touches stop reaching whatever is underneath.
//
//  So the shape layer gets a window with _ignoresHitTest permanently YES: it is
//  struck off the server's hit test for good and can never take a touch. Its
//  level sits just below the menu, so the menu still draws on top.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSEspWindow : UIWindow
@end

@interface TSEspRootViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
