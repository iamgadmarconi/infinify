// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/viewport_animation.rs (MOMENTUM_LAUNCH_DELAY, schedule_momentum_timer,
// launch_momentum_on) and src/input/pointer.rs (the finger stop of on_pointer_axis).
// Timing only: the momentum itself is the controller's, launched by its pan_end.
#import <Foundation/Foundation.h>
// When a burst of scroll pans is over. It ends when the device says the scroll
// ended, or 50 ms after its last pan when nothing has said so by then: a wheel
// never does, and a finger at rest on the trackpad sends nothing. A burst
// launches once here. The delay runs on this process's clock, so a busy main
// thread can fire it ahead of an end already queued; whether an end that finds
// the burst launched launches again, as upstream's does after a real rest, is
// the caller's to tell from the events' own times. There is one burst for all
// outputs, as upstream keeps one deadline: a pan on another output takes it over.
// Main thread only.
@interface DWPanLaunch : NSObject
// launch receives the output whose burst ended.
- (instancetype)initWithLaunch:(void (^)(NSNumber *output))launch;
// A pan moved `output`: its burst is open and the delay starts again.
- (void)panned:(NSNumber *)output;
// The device ended the scroll: launches now if a burst is open.
- (void)end;
// Forgets an open burst without launching. Required before release.
- (void)cancel;
@end
