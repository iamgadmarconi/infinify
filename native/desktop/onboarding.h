// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
// A normal run is the desktop and shows no chooser. This is the one small window it shows
// in place of its canvas while it cannot open it: Screen Recording or Accessibility is
// missing, or the launch itself failed. It names what is missing and gives each grant an
// Allow button, which asks macOS for it only from the user's own click and opens its
// pane in System Settings, as the chooser's Allow button does. While it is open it looks
// again once a second and hands over as soon as nothing is missing. Screen Recording
// reaches only a process started after it was granted, so the window says so and offers
// a relaunch. It never asks for anything by itself. Main thread only.
@interface DWOnboarding : NSObject
// `proceed`: both grants are there and the window has closed. `relaunch`: start this run
// again. `quit`: the Quit button, or the window's own close button.
- (instancetype)initWithProceed:(void (^)(void))proceed relaunch:(void (^)(void))relaunch quit:(void (^)(void))quit;
// Shows the window, in front. With `error`, a launch that cannot go on whatever is
// granted, it shows that text and Quit alone, and looks nothing up again.
- (void)show:(NSString *)error;
// Closes the window and ends the look every second. Idempotent. Required before release.
- (void)close;
@end
