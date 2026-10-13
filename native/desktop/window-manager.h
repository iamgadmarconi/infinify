// SPDX-License-Identifier: GPL-3.0-or-later
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
@property BOOL displayFixed; // independently rooted AXFloatingWindow at the floating level
+ (instancetype)candidateWithShareable:(SCWindow *)shareable;
@end
// What the manager asks of the shell. Every call arrives on the main thread.
@protocol DWWindowHost <NSObject>
// Is this native window already bound to a world window?
- (BOOL)managesWindow:(CGWindowID)window pid:(pid_t)pid;
// An ordinary application window on screen that nothing manages yet, once per
// appearance: whatever the host does with it, it is not offered again until it
// has left the screen and come back.
- (void)windowAppeared:(DWWindowCandidate *)window;
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
@optional
// A candidate's existing bounds-stability deadline is due. Request the host's
// single-flight worker observation now; this callback performs no enumeration.
- (void)windowDiscoveryRequested;
// A creation/appearance hint can concern a child that is deliberately never
// adopted as a toplevel. Native family presentation must reconcile its roots
// without waiting for the regular one-second poll. 0 means all scoped roots.
- (void)windowFamilyChanged:(pid_t)pid;
@end
// DriftWM manages every toplevel; this is that rule for native Mac windows. Candidates
// are the normal-layer windows of regular applications other than this process, at
// least 40x40 and on screen, whose bounds held still between worker observations for 50 ms.
// Of those only a real window is offered, as upstream manages toplevels and their
// dialogs and never a popup or a helper surface: with Accessibility access, one whose
// subrole is AXStandardWindow, AXDialog or AXSystemDialog; where Accessibility cannot
// say (no access, an application that does not answer), any candidate but an untitled
// one smaller than 200x150. Tested once per appearance, before adoption only.
// Read-only: it lists windows and never moves, focuses, resizes or closes one. It owns
// one candidate-stability timer: the host's poll drives reconciliation, and so do the observers it owns
// (window-events.h), which exist from +managerWithHost:scope:mode: until -stop. Main thread only.
//
// Tracking is event-driven where Accessibility access allows. NSWorkspace and one
// AXObserver per regular application say when an application launched or was shown and
// when a window was created or came back from the Dock: native discovery requests
// the host's single-flight worker immediately, including an application's first window.
// A candidate-stability deadline requests another fresh observation after the existing
// 50 ms hold, without waiting for the idle poll. Reconciliation stays eager for a second,
// because the window list can show a window a moment after its application reports it.
// A window that moved, was resized, retitled, miniaturized or destroyed, and native
// focus that moved, are handed to the host at once. The poll is then a reconciliation, one
// pass a second, that finds whatever no event announced. Without Accessibility access,
// and while an application is not observed in full (it does not answer yet, or refused a
// notification), every poll requests a pass, with at most one read in flight.
//
// `--only-pid` gives it a scope: pid → that process's start time as read at launch (DWInScope, window-events.h). A window of
// any other process is then no candidate at all: it is not timed, not asked about through Accessibility, not read, not
// offered and not named as present, and no observer is put on its application. With a scope the manager also exists
// without Screen Recording access (`capturing` NO). Authenticated native presentation also uses metadata-only discovery
// without a finite scope: the presenter's own scope checks authorize each adoption. The shareable windows are then never read, so nothing can prompt, and
// its candidates come from the window list and Accessibility alone. Such a run names no window that is off screen
// (-discoveryCompleted: is given none), so a saved slot is not kept waiting for one.
typedef NS_ENUM(NSUInteger,DWWindowDiscoveryMode) {
    DWWindowDiscoveryModeCaptureOverlay,
    // Select only after the native presenter has authenticated its helper and scope.
    // Discovery reads metadata; every native adoption still checks presenter authority.
    DWWindowDiscoveryModeNativePresentation,
};
@interface DWWindowManager : NSObject
// Overlay with no scope: nil without Screen Recording access. Native presentation
// never reads shareable windows, even if recording access is granted. Neither mode
// requests permission. Unknown modes are refused.
+ (instancetype)managerWithHost:(id<DWWindowHost>)host scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope mode:(DWWindowDiscoveryMode)mode;
// Whether this manager reads the shareable windows: Screen Recording access as it stood when the manager was made.
// Always NO in native presentation.
@property (readonly) BOOL capturing;
// A disposable native benchmark may put its owned windows above the canvas.
// Default 0; an extra level is considered only with an explicit process scope.
@property NSInteger benchmarkWindowLevel;
// Native presentation only: discover application utility panels. A positive
// floating level alone is insufficient; AX must report a floating-window role.
@property BOOL nativePanels;
// Called at the idle poll's pace to request a single-flight worker observation.
// Creation/appearance hints mark discovery due; they never enumerate on main.
- (BOOL)reconciliationDue;
// Consume that worker's ordered on-screen records on main. The caller must reject
// aged snapshots from the start of the read; adoption still validates identities
// afresh. The shareable windows are read only for a changed candidate set, initial
// discovery or retry. YES when bound windows also need reconciliation: each pass
// without full observers, otherwise once a second. Bound-window event/input/resize
// checks keep their immediate fresh reads, independent of this discovery batch.
- (BOOL)pollWithWindowRecords:(NSArray<NSDictionary *> *)records;
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
