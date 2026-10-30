// SPDX-License-Identifier: GPL-3.0-or-later
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "DWWindowCandidate.h"
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
// Startup metadata could not be read. Completion is withheld so unknown offscreen
// presence does not discard saved slots. Retry about two seconds later; already
// offered native windows stay bound. Capture-mode candidate changes may retry sooner.
- (void)discoveryFailed:(NSString *)reason;
// With the observers of DWWindowEvents.h. Each is a hint to look now at what the poll would look at later, never the change
// itself, and may be repeated, late or about a window nothing binds.
// Only AXMoved named this known window in the coalesced batch. Fresh identity and
// unchanged native extent must be verified before reusing any local chrome data.
- (void)windowMoved:(CGWindowID)window pid:(pid_t)pid;
// This native window was resized, retitled, miniaturized or shown again, its application was hidden, shown or ended,
// or the change is mixed/unknown. `window` 0: some window of the application, which one is not known.
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid;
// Its application reported the window destroyed. The window list may still have it at this moment, and keeps it when
// the application keeps the window object.
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid;
// Native focus may have moved: an application was activated, or changed its focused window.
- (void)focusChanged;
@optional
- (void)windowVisibilityChanged:(CGWindowID)window pid:(pid_t)pid;
// A candidate's existing bounds-stability deadline is due. Request the host's
// single-flight worker observation now; this callback performs no enumeration.
- (void)windowDiscoveryRequested;
// A creation/appearance hint can concern a child that is deliberately never
// adopted as a toplevel. Native family presentation must reconcile its roots
// without waiting for the regular one-second poll. 0 means all scoped roots.
- (void)windowFamilyChanged:(pid_t)pid;
// A window the manager decided, at one of three places, it will not offer, once per appearance and from the
// first pass on (a window that was open before the run is told as well; a host that held nothing back for it has
// nothing to undo). It is on screen at a candidate level and at least 40x40, and either its application is not a
// regular one (told on first sight), or the shareable windows did not list it in two reads, or the read of it
// settled as not a real window. Not told: a window under 40x40 or at another level, one still moving or waiting
// for a title, one that was offered (a host that refuses it in -windowAppeared: reports that itself), and one the
// manager never sees (outside --only-pid). A native host that lets the window server hold new windows invisible
// until they are placed uses this to let the window appear now rather than at that hold's own bound.
- (void)windowNotAdopted:(CGWindowID)window pid:(pid_t)pid;
@end
// DriftWM manages every toplevel; this is that rule for native Mac windows. Candidates
// are the normal-layer windows of regular applications other than this process, at
// least 40x40 and on screen, whose bounds held still between worker observations for 50 ms.
// Native presentation uses the window's fresh untransformed bounds and original
// affine basis; CG bounds include owner opening animations. Overlay uses CG bounds.
// Of those only a real window is offered, as upstream manages toplevels and their
// dialogs and never a popup or a helper surface: with Accessibility access, one whose
// subrole is AXStandardWindow, AXDialog or AXSystemDialog; where Accessibility cannot
// say (no access, an application that does not answer), any candidate but an untitled
// one smaller than 200x150. Tested once per appearance, before adoption only.
// Read-only: it lists windows and never moves, focuses, resizes or closes one. It owns
// one candidate-stability timer: the host's poll drives reconciliation, and so do the observers it owns
// (DWWindowEvents.h), which exist from +managerWithHost:scope:mode: until -stop. Main thread only.
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
// `--only-pid` gives it a scope: pid → that process's start time as read at launch (DWInScope, DWWindowEvents.h). A window of
// any other process is then no candidate at all: it is not timed, not asked about through Accessibility, not read, not
// offered and not named as present, and no observer is put on its application. With a scope the manager also exists
// without Screen Recording access (`capturing` NO). Authenticated native presentation also uses metadata-only discovery
// without a finite scope: the presenter's own scope checks authorize each adoption. The shareable windows are then never read, so nothing can prompt, and
// its candidates come from the window list and Accessibility alone. At startup a separate all-window metadata read
// preserves exact titled saved slots for existing same-login windows, including offscreen ones, after process-birth
// and WID-owner revalidation. Those names only reach -discoveryCompleted:; they are never offered for adoption,
// capture or placement. Unknown titles are not guessed; duplicate titles retain one entry per existing window.
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
// Already offered WIDs, for excluding redundant native candidate getter reads.
// This is discovery bookkeeping and never native ownership/identity authority.
@property (copy,readonly) NSSet<NSNumber *> *offeredWindows;
// A disposable native test panel may put its owned windows above the canvas.
// Default 0; an extra level is considered only with an explicit process scope.
@property NSInteger testPanelWindowLevel;
// Native presentation only: discover application utility panels. A positive
// floating level alone is insufficient; AX must report a floating-window role.
@property BOOL nativePanels;
// Called at the idle poll's pace to request a single-flight worker observation.
// Creation/appearance hints mark discovery due; they never enumerate on main.
- (BOOL)reconciliationDue;
// Consume that worker's ordered on-screen records on main. The caller must reject
// aged snapshots from the start of the read; adoption still validates identities
// afresh. Native candidates require that batch's separately audited native bases;
// a missing basis retains CG presence but withholds adoption and requests retry.
// The shareable windows are read only for a changed candidate set, initial
// discovery or retry. YES when bound windows also need reconciliation: each pass
// without full observers, otherwise once a second. Bound-window event/input/resize
// checks keep their immediate fresh reads, independent of this discovery batch.
- (BOOL)pollWithWindowRecords:(NSArray<NSDictionary *> *)records nativeCandidateBases:(NSDictionary<NSNumber *,NSDictionary *> *)nativeCandidateBases sampledAt:(CFTimeInterval)sampledAt;
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
