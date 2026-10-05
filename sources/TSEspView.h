//
//  TSEspView.h
//  imgui
//
//  A second, fully pass-through ImGui layer.
//
//  It renders shapes over the whole screen and never takes a touch: hitTest
//  returns nil, pointInside returns NO and interaction is off on every view in
//  it, so taps go straight to whatever is underneath. The menu overlay stays
//  the only interactive surface.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSEspView : UIView

/// Starts and stops drawing. Off by default; while off the Metal view is
/// paused, so an unused layer costs nothing.
- (void)setEspEnabled:(BOOL)enabled;
- (BOOL)isEspEnabled;

@end

NS_ASSUME_NONNULL_END
