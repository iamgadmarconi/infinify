// SPDX-License-Identifier: GPL-3.0-or-later
#import <ScreenCaptureKit/ScreenCaptureKit.h>
// What the manager asks of the shell. Every call arrives on the main thread.
@protocol DWWindowHost <NSObject>
// Is this native window already bound to a world window?
- (BOOL)managesWindow:(CGWindowID)window pid:(pid_t)pid;
// An ordinary application window on screen that nothing manages yet, once per
// appearance: whatever the host does with it, it is not offered again until it
// has left the screen and come back.
- (void)windowAppeared:(SCWindow *)window;
// The first pass is over: every candidate on screen that held still within its two
// seconds, and that the shareable windows listed in one of two reads, has been offered.
// Once. `present` names, as {bundle_id,title}, the titled candidates that exist but
// were not offered: minimized, hidden, on another Space, or still being moved.
- (void)discoveryCompleted:(NSArray<NSDictionary *> *)present;
// The shareable windows could not be read. Nothing was offered. The read is tried
// again about two seconds later, and at once when the candidates on screen change.
- (void)discoveryFailed:(NSString *)reason;
@end
// DriftWM manages every toplevel; this is that rule for native Mac windows. Candidates
// are the normal-layer windows of regular applications other than this process, at
// least 40x40 and on screen, whose bounds held still from one poll to the next.
// Read-only: it lists windows and never moves, focuses, resizes or closes one. It owns
// no timer, observer or dispatch source: -poll drives it. Main thread only.
@interface DWWindowManager : NSObject
// nil without Screen Recording access, which it never asks for.
+ (instancetype)managerWithHost:(id<DWWindowHost>)host;
// One cheap pass over the on-screen window list. The shareable windows are read only
// when the set of candidates not yet offered changed, once for the first pass even when
// that set is empty, and again after a read that failed.
- (void)poll;
// Capture on demand: should this world window's stream run? YES while it has a
// placement on some output, and for two seconds after its last one went.
- (BOOL)capture:(NSNumber *)window placed:(BOOL)placed;
- (void)forget:(NSNumber *)window;
// No host call after this, a read in flight included. Required before release.
- (void)stop;
@end
// The close_window effect: presses the close button of exactly this window through
// Accessibility. The identity {pid,birth_sec,birth_usec,wid} is validated afresh
// (process birth, window owner) before the lookup and again immediately before the
// press. nil once the press was sent, else why nothing was pressed. Any thread.
NSString *DWCloseWindow(NSDictionary *identity);
// The launch effect: opens the application with this bundle identifier. `failed` is
// called on the main queue when none is installed or it could not be opened.
void DWLaunchApplication(NSString *bundleIdentifier,void (^failed)(NSString *reason));
