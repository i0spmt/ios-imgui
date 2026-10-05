//
//  TSImGuiView.h
//  TrollSpeed
//
//  Created by Lessica on 2024/10/4.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSImGuiView : UIView

/// Shows or hides the ImGui window. Hidden by default.
- (void)setMenuVisible:(BOOL)visible;
- (BOOL)isMenuVisible;

/// Called on the main thread whenever the menu opens or closes, including when
/// the user closes it with the title bar's close box — which happens inside the
/// ImGui draw and is otherwise invisible to the owner.
@property (nonatomic, copy, nullable) void (^menuVisibilityChanged)(BOOL visible);

/// Called when the shapes checkbox in the menu is toggled.
@property (nonatomic, copy, nullable) void (^espEnabledChanged)(BOOL enabled);

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Feeds a touch straight from the HID/AX callback into the ImGui pointer
/// queue, in parallel with the regular UIKit delivery.
///
/// Two things make this necessary in the HUD process. The AX path re-runs
/// hitTest for every single event, so a drag that leaves the ImGui window
/// stops being delivered to it half-way through; and a lost Ended would
/// otherwise leave a widget stuck in the pressed state forever. Feeding the
/// queue here keeps both cases correct regardless of what UIKit decides.
void TSImGuiInjectTouch(CGPoint windowPoint, NSInteger phase,
                        NSInteger pointerId, UIWindow *window);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
