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
// With the observers of window-events.h. Each is a hint to look now at what the poll would look at later, never the change
// itself, and may be repeated, late or about a window nothing binds.
// This native window moved, was resized, retitled, miniaturized or shown again, or its application was hidden, shown or
// ended. `window` 0: some window of the application, which one is not known.
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid;
// Its application reported the window destroyed. The window list may still have it at this moment, and keeps it when
// the application keeps the window object.
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid;
// Native focus may have moved: an application was activated, or changed its focused window.
- (void)focusChanged;
@end
// DriftWM manages every toplevel; this is that rule for native Mac windows. Candidates
// are the normal-layer windows of regular applications other than this process, at
// least 40x40 and on screen, whose bounds held still from one poll to the next (for 50 ms,
// counted from the event that announced the window when there was one).
// Of those only a real window is offered, as upstream manages toplevels and their
// dialogs and never a popup or a helper surface: with Accessibility access, one whose
// subrole is AXStandardWindow, AXDialog or AXSystemDialog; where Accessibility cannot
// say (no access, an application that does not answer), any candidate but an untitled
// one smaller than 200x150. Tested once per appearance, before adoption only.
// Read-only: it lists windows and never moves, focuses, resizes or closes one. It owns
// no timer or dispatch source: -poll drives it, and so do the observers it owns
// (window-events.h), which exist from +managerWithHost: until -stop. Main thread only.
//
// Tracking is event-driven where Accessibility access allows. NSWorkspace and one
// AXObserver per regular application say when an application launched or was shown and
// when a window was created or came back from the Dock: the pass below then runs at
// once, for that application, and -poll keeps the idle poll's own pace for a second,
// because the window list can show a window a moment after its application reports it.
// A window that moved, was resized, retitled, miniaturized or destroyed, and native
// focus that moved, are handed to the host at once. -poll is then a reconciliation, one
// pass a second, that finds whatever no event announced. Without Accessibility access,
// and while an application is not observed in full (it does not answer yet, or refused a
// notification), every -poll is a pass, as it always was.
@interface DWWindowManager : NSObject
// nil without Screen Recording access, which it never asks for.
+ (instancetype)managerWithHost:(id<DWWindowHost>)host;
// Called at the idle poll's pace. One cheap pass over the on-screen window list, unless
// the observers are in place and the reconciliation is not due. The shareable windows are
// read only when the set of candidates not yet offered changed, once for the first pass
// even when that set is empty, and again after a read that failed. YES when the host
// should look at every bound window now too: on every call without the observers, once
// a second with them.
- (BOOL)poll;
// YES while the observers report window changes: Accessibility access stands and every
// regular application is observed in full.
@property (readonly) BOOL live;
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
