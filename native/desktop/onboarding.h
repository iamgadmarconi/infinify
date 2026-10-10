// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
// A normal run is the desktop and shows no chooser. This is the one small window it shows
// in place of its canvas while it cannot open it: Screen Recording or Accessibility is
// missing, Stage Manager is on, or the launch itself failed. It names what is in the way
// and gives each grant an Allow button, which asks macOS for it only from the user's own
// click and opens its pane in System Settings, as the chooser's Allow button does. Stage
// Manager gets a button that opens Desktop & Dock and nothing more: the setting is the
// user's and is only ever read here. While the window is open it looks again once a
// second and hands over as soon as nothing is in the way. Screen Recording reaches only a
// process started after it was granted, so the window says so and offers a relaunch. It
// never asks for anything by itself. Main thread only.

// Whether Stage Manager is on now (com.apple.WindowManager, GloballyEnabled), read afresh
// on every call and never written. On, macOS keeps only the current stage's windows at
// their size and scales every other window into a thumbnail in its strip: a window's
// bounds, its picture and the place a click would have to go are then the thumbnail's,
// and each application switch swaps which windows that is. No canvas can show real
// windows over that, so a normal run waits for it to be turned off.
BOOL DWStageManagerOn(void);
// What a run that is already the desktop says, on stderr, when Stage Manager comes on under it.
extern NSString *const DWStageManagerNote;
@interface DWOnboarding : NSObject
// `proceed`: both grants are there, Stage Manager is off and the window has closed.
// `relaunch`: start this run again. `quit`: the Quit button, or the window's own close button.
- (instancetype)initWithProceed:(void (^)(void))proceed relaunch:(void (^)(void))relaunch quit:(void (^)(void))quit;
// Shows the window, in front. With `error`, a launch that cannot go on whatever is
// granted, it shows that text and Quit alone, and looks nothing up again.
- (void)show:(NSString *)error;
// Closes the window and ends the look every second. Idempotent. Required before release.
- (void)close;
@end
