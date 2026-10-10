// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
// The shell's frame callback, in step with a display instead of a 60 Hz timer: the
// display link of one screen (-[NSScreen displayLinkWithTarget:selector:], macOS 14+),
// asked for that screen's full refresh rate. A screen's link, not a view's: a view's
// stops while its view is hidden or covered, and a camera in flight still has to arrive.
// A driver exists only while frames are wanted. It is created running and ended by
// -invalidate; it is never paused and never restarted. Main thread only.
@interface DWFrameDriver : NSObject
// `frame` runs on the main run loop, in the common modes, once per refresh of the
// fastest of `screens` (NSScreen.maximumFramesPerSecond): one callback serves every
// canvas panel, so the controller is ticked once a frame whatever the number of
// displays. The main screen when the list is empty; nil when no screen gives a link.
+ (instancetype)driverOn:(NSArray<NSScreen *> *)screens frame:(void (^)(DWFrameDriver *driver))frame;
// No callback after this, and the block is released. Idempotent. Required before
// release: until then the link keeps the driver alive and firing.
- (void)invalidate;
// When the last callback ran, on CACurrentMediaTime's clock; the creation time before
// the first. A link fires only while its display refreshes, so the owner reads this to
// tell a driver that has gone quiet (a display asleep) from one that is serving frames.
@property (readonly) CFTimeInterval lastFrame;
// Refreshes per second of the screen it follows.
@property (readonly) NSInteger framesPerSecond;
@end
