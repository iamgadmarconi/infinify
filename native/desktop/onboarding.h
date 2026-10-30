// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
// A normal run is the desktop and shows no chooser. This is the one small window it shows
// in place of its canvas while it cannot open it: required Screen Recording or Accessibility is
// missing, or the launch itself failed. It names what is in the way and gives each grant an
// Allow button, which asks macOS for it only from the user's own click and opens its pane in
// System Settings, as the chooser's Allow button does. While the window is open it looks again
// once a second and hands over as soon as nothing is in the way. Screen Recording reaches only a
// process started after it was granted, so the window says so and offers a relaunch. It never
// asks for anything by itself. Stage Manager is no concern of this window: a normal run switches
// it off itself when its canvas opens (system-takeover.h). Main thread only.

// Capture overlays require recording access. An authenticated native primary needs
// Accessibility; extra captured display views remain optional.
static inline BOOL DWDesktopAccessReady(BOOL requiresScreenCapture,BOOL capture,BOOL input) {
    return input&&(!requiresScreenCapture||capture);
}
@interface DWOnboarding : NSObject
// `proceed`: required grants are there and the window has closed.
// `relaunch`: start this run again. `quit`: the Quit button, or the window's own close button.
- (instancetype)initWithProceed:(void (^)(void))proceed relaunch:(void (^)(void))relaunch quit:(void (^)(void))quit requiresScreenCapture:(BOOL)requiresScreenCapture;
// Shows the window, in front. With `error`, a launch that cannot go on whatever is
// granted, it shows that text and Quit alone, and looks nothing up again.
- (void)show:(NSString *)error;
// Closes the window and ends the look every second. Idempotent. Required before release.
- (void)close;
@end
