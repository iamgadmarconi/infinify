// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
// A desktop stays up. Calls `returned` on the main thread when the Mac or its displays
// woke, when the login session became the active one again (the lock screen was left, a
// user switched back) and when the active Space changed, a fullscreen application's
// Space included: the moments after which the canvas panels may no longer be in front
// of the windows they cover. It only tells; what is put back is its owner's. A wake
// arrives as several of these in a row, so the block must be cheap to run again.
// Main thread only.
@interface DWSessionWatch : NSObject
- (instancetype)initWithReturned:(void (^)(void))returned;
// Removes every observer: no call after this. Idempotent. Required before release.
- (void)stop;
@end
