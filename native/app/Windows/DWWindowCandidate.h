// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/window-manager.h at 37b27b1, moved verbatim.
#import <ScreenCaptureKit/ScreenCaptureKit.h>
// One window the manager offers: what the shell binds it by and names it with. Read from the shareable windows where the
// run can capture; in native presentation or an `--only-pid` run without Screen Recording access from the window list (pid, number, frame),
// Accessibility (title) and the running application (bundle identifier, name), and `shareable` is then nil: such a window
// is bound, focused and clicked like any other. Native presentation draws the actual window; a scoped overlay has no picture.
@interface DWWindowCandidate : NSObject
@property pid_t pid;
@property CGWindowID window;
@property (copy) NSString *bundleIdentifier, *applicationName, *title;
@property CGRect frame;
@property SCWindow *shareable;
// A direct AX creation result stays bound to this original process instance.
// The host must compare it before constructing a source from a fresh PID read.
@property (copy) NSDictionary *nativeIdentity;
@property BOOL displayFixed; // independently rooted AXFloatingWindow at the floating level
+ (instancetype)candidateWithShareable:(SCWindow *)shareable;
@end
