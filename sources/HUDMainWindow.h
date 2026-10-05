//
//  HUDMainWindow.h
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <UIKit/UIKit.h>

#import "UIApplicationRotationFollowingWindow.h"

NS_ASSUME_NONNULL_BEGIN

// Derives from UIApplicationRotationFollowingWindow rather than UIWindow
// because only that branch of the hierarchy has -_initWithFrame:attached:,
// which is what lets the window be created detached from the scene (see the
// initialiser). Its own autorotation is suppressed — HUDRootViewController
// rotates its view by hand, and letting the window rotate too would apply the
// rotation twice.
@interface HUDMainWindow : UIApplicationRotationFollowingWindow
@end

NS_ASSUME_NONNULL_END
