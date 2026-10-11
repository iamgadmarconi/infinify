// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
@class IFCompositorLayer;
NS_ASSUME_NONNULL_BEGIN
// The shell's frame callback follows the fastest canvas output. A Metal link
// supplies its drawable with each visible frame; a screen link keeps camera
// navigation advancing when drawable offers stop while covered or asleep.
// A driver exists only while frames are wanted. It is created running and ended by
// -invalidate; it is never paused and never restarted. Its process activity ends
// with it, keeps requested frames out of App Nap and allows idle sleep. Main thread only.
@interface DWFrameDriver : NSObject
// `frame` runs on the main run loop, in the common modes, following the requested
// cadence of the fastest of `screens` (NSScreen.maximumFramesPerSecond): one callback serves every
// canvas panel, so the controller is ticked once a frame whatever the number of
// displays. The main screen when the list is empty; nil when no screen gives a link.
+ (nullable instancetype)driverOn:(NSArray<NSScreen *> *)screens frame:(void (^)(DWFrameDriver *driver))frame;
// A visible Metal output supplies the drawable and clock together. Its callback
// advances camera/native state and encodes the offered drawable once. The screen
// link remains a controller fallback when the Metal link stops offering frames;
// it does not request a drawable while the output is occluded or asleep.
// nil keeps the screen-link path. Main thread only.
+ (nullable instancetype)driverOn:(NSArray<NSScreen *> *)screens
                   layer:(nullable IFCompositorLayer *)layer
                   frame:(void (^)(DWFrameDriver *driver))frame;
// Scoped diagnostic only: Core Video's separate display thread publishes the
// newest target to at most one pending main-queue tick. All scene/render work
// remains on main, and the ordinary screen link is a fallback if it goes quiet.
// This deprecated clock is never selected implicitly or together with `layer`.
+ (nullable instancetype)driverOn:(NSArray<NSScreen *> *)screens
                   layer:(nullable IFCompositorLayer *)layer
           hardwareClock:(BOOL)hardwareClock
                   frame:(void (^)(DWFrameDriver *driver))frame;
// No callback after this, and the block is released. Idempotent. Required before
// release: until then the link keeps the driver alive and firing.
- (void)invalidate;
// When the last callback ran, on CACurrentMediaTime's clock; the creation time before
// the first. A link fires only while its display refreshes, so the owner reads this to
// tell a driver that has gone quiet (a display asleep) from one that is serving frames.
@property (readonly) CFTimeInterval lastFrame;
// Refreshes per second of the screen it follows.
@property (readonly) NSInteger framesPerSecond;
// The expected presentation of the callback now being served, on the Mach absolute
// clock used by CADisplayLink and Metal. Zero outside a callback / before the first.
@property (readonly) CFTimeInterval presentationTime;
@end
NS_ASSUME_NONNULL_END
