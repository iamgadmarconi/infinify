// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1.
// Infinify's desktop shell: the canvas panels, window capture, input routing and run lifecycle around the Rust controller.
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Carbon/Carbon.h>
#import <UserNotifications/UserNotifications.h>
#import "DWCanvasRenderer.h"
#import "DWCanvasCursor.h"
#import "DWConfigWatcher.h"
#import "DWCycleHold.h"
#import "DWDockGuard.h"
#import "DWDockReloader.h"
#import "DWFrameDriver.h"
#import "DWNativeInput.h"
#import "DWHotCorners.h"
#import "DWHotKeys.h"
#import "DWIPCServer.h"
#import "DWMultitouchSource.h"
#import "DWNativePresenter.h"
#import "DWNativePointerGrab.h"
#import "DWNativeRelativeMotion.h"
#import "DWNativeReplicaFamilies.h"
#import "DWNativeResizeDriver.h"
#import "DWNativeTabletRouter.h"
#import "DWNativeTransition.h"
#import "DWNativeViews.h"
#import "DWOnboarding.h"
#import "DWNavigationCoordinator.h"
#import "DWPanLaunch.h"
#import "DWResizeCoordinator.h"
#import "DWSceneWriter.h"
#import "DWSystemTakeover.h"
#import "DWTapKeys.h"
#import "DWTrackpadGestures.h"
#import "DWWindowManager.h"
#import "DWWindowObserver.h"
#include "driftwm_desktop.h"
@class DesktopView, LiveSource;
@interface Desktop : NSObject <NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate>
@property DriftDesktop *controller;
@property DWCanvasCursor *canvasCursor;
@property DWResizeCoordinator *resize;
@property NSNumber *resizeSavedTransaction;
// Every normal run: DriftWM's sizing actions (grow-window, shrink-window, fit-window, fit-window-snapped, fill-window, IPC
// resize), a rule's size and fullscreen are size transactions the controller begins and continues by itself.
@property NSNumber *sizeTransaction; // the transaction a sizing action's effect last named
@property DWNavigationCoordinator *navigation;
@property DWFrameDriver *frameDriver; // the frame timer: a display link, alive only while frames are wanted (-startFrames), and where the canvas is flushed
@property NSDictionary *panelScreens; // physical descriptors at the last panel/output creation
// A change of the compositor's asked for a frame since the frame timer last looked, and the frames it has since gone without one (-frameComing:).
@property BOOL frameOwed;
@property NSInteger frameQuiet;
@property CGPoint pointerReported; // where the pointer was when cursor edge pan was last told (-pointerFrame:)
@property NSTimer *statsTimer; // INFINIFY_DEBUG's frame line, every two seconds (-frameStats)
@property CFTimeInterval statsSince;
@property NSMutableDictionary<NSNumber *,LiveSource *> *exportSources; // one-shot export frames; native pixels retain the transformed window's density
@property NSMutableDictionary<NSNumber *,NSMutableArray<DWCanvasAttachment *> *> *exportAttachments;
@property NSDictionary *exportOrdering; // accepted immutable one-shot cohort only
@property BOOL frameFlying; // the frame timer serves camera motion, not only what the compositor animates by itself (a background, a window opening or leaving)
@property CFTimeInterval lastObservation;
@property CFTimeInterval lastResizeObservation;
@property CFTimeInterval lastPollTiming; // scoped debug: at most one slow-poll stage row per second
@property DWWindowObserver *windowObserver;
@property uint64_t observationEpoch;
@property BOOL windowObservationAgain; // one follow-up after a native family hint during an in-flight read
@property BOOL declineFrameQueued; // one frame is owed to windows the shell declined
@property CFMachPortRef navigationTap;
@property CFRunLoopSourceRef navigationTapSource;
@property BOOL logicalFocus; // --no-native-focus: no native window is ever activated or raised
@property BOOL focusNoted; // the resting status has said that native focus lacks Accessibility
@property BOOL stageNoted; // stderr has said that Stage Manager is on, since it last was off
@property DWSystemTakeover *takeover; // a normal run only: Stage Manager and window tiling off while it is the desktop, put back at its end
@property DWCycleHold *cycleHold;
@property UInt32 cycleModifiers; // Carbon mask of upstream's cycle_hold
@property NSDictionary *nativeTitleClick;
@property NSTimer *nativeTitleClickTimer;
@property BOOL flying;
// Normal runs only: camera motion as DriftWM's. A released pan coasts in the controller;
// the shell says when a pan ends, and where the pointer is while cursor edge pan wants it.
@property DWPanLaunch *panLaunch;
// Normal runs only: where the pointer is has one reading (-outputUnderPointer:), for
// cursor edge pan's report and for hover alike, taken once a frame while the frame timer
// runs (-pointerFrame).
@property NSArray<NSDictionary *> *pointerOutputs; // the latest snapshot's outputs while panels are open, else nil
@property BOOL pointerWanted; // that snapshot asks for the pointer: cursor edge pan is on
@property NSUInteger statusToken;
- (void)applyReply:(NSDictionary *)reply;
- (void)flashStatus:(NSString *)text;
// Keys, pointer gestures and settings come from the DriftWM config.
@property NSString *configPath; // --config; nil is the controller's default path
@property NSString *superChord; // --super; nil is ctrl+alt
@property DWHotKeys *hotKeys;
@property NSNumber *standinKeyboardWindow;
@property NSPanel *standinKeyboardPanel;
@property NSUInteger standinKeyboardSerial;
@property DWTapKeys *tapKeys; // DriftWM's tap bindings, watched while the hot keys are registered
@property DWConfigWatcher *configWatcher;
@property NSString *configNote; // what a config load left for the resting status and the error bar does not show: a --super chord or a load the controller refused
@property BOOL dismissFree; // no binding claims ⌃⌥-click on a window
// Normal runs only: trackpad gestures by DriftWM's [gestures] tables. Three or more
// fingers arrive as raw touches, and DWTrackpadGestures makes libinput's swipe, pinch
// and hold of them; a two-finger pinch is AppKit's magnify stream. The controller
// holds one gesture at a time and decides what it does.
@property DWTrackpadGestures *trackpad;
@property DWGlobalTrackpadInput *globalTrackpad;
@property BOOL globalTrackpadNoted,globalGestureDelivery,globalGestureContact;
// Desktop mode, where MultitouchSupport reports every contact wherever the pointer is: the touch source, its feed into the recogniser, and the tap that holds
// the system's Dock-control gestures back for the finger counts a [gestures] binding takes. While the source delivers, the NSTouch paths below feed nothing.
@property DWMultitouchSource *multitouch;
@property DWMultitouchFeed *touchFeed;
@property DWDockGuard *dockGuard;
@property DWDockTap *dockTap;
@property NSTimeInterval multitouchRetry;
@property (copy) NSString *touchPath; // INFINIFY_DEBUG: which source fed the recogniser last: multitouch, global-tap or view-touches
@property NSTimer *trackpadTimer; // armed for trackpadDeadline, the recogniser's next: hold delay, finger-count debounce
@property NSTimeInterval trackpadDeadline;
@property NSInteger gestureOwner; // whose gesture the controller holds: 0 none, 1 the recogniser's, 2 magnify's
@property NSNumber *gestureOutput; // the output that gesture began on
@property BOOL gestureWatched; // that gesture began with its output's panel under the pointer: while it is, the touches are the panel's
@property BOOL gestureMove; // the controller made a window move or resize of it: it holds a drag, or a resize grab, until its end
@property BOOL gestureResize; // that grab is a resize: a size transaction is held open for it (-configureResize)
@property BOOL askingQueue; // -endLostInput is looking into the event queue for a release: a frame that runs inside that look does not look again
@property BOOL magnifying; // a magnify stream is running, whether or not the controller took it
@property double magnifyScale; // its scale since it began
@property NSTimeInterval lastTouches; // when the last frame of touches came
@property BOOL windowed;
@property NSSize windowSize;
@property DWIPCServer *ipc;
@property NSString *socketPath; // the socket this instance serves; nil while IPC is not up
// Normal runs only, like the config they come from: hot corners, the keyboard
// layout report, the IPC event stream and autostart.
@property DWHotCorners *corners;
@property NSTimer *statePush; // the one pending event for IPC subscribers
@property CFTimeInterval lastStatePush;
@property NSArray *autostart; // the launch load's exec effects until they have run
// A normal run without --manual: every real application window (DWWindowManager.h) lives on the
// canvas, as every toplevel does in DriftWM. The manager exists only while the canvas
// is open and Screen Recording access is granted; without it this run is the manual one.
@property BOOL managing;
@property DWWindowManager *manager;
// --only-pid: pid → that process's start time as read at launch (DWInScope), nil for none. With one, only windows of
// those processes are ever attached, and the manager exists without Screen Recording access too.
@property NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope;
@property BOOL debugPointer; // --debug-pointer: the DebugPointer request is served (-debugPointer:)
// --native-helper: the other way to present (DWNativePresenter.h). The window server draws the real windows where the canvas places
// them and the panel draws none of them; nil in every other run, which is then the overlay and runs none of what this gates.
@property DWNativePresenter *native;
@property DWNativeViews *nativeViews;
@property DWNativeReplicaFamilies *nativeFamilies;
@property NSDictionary *overlayFamilySnapshot,*overlayFamilyBase,*overlayFamilyDescriptions;
@property NSDictionary *nativeViewSnapshot,*nativeOwnerSnapshot;
@property NSDictionary *nativeFillHandoff,*nativeRestoreDeferred;
@property NSArray *nativeFillBackgroundTrace;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *nativeFillHistory;
@property NSMutableSet<NSNumber *> *nativeFillRefusedTransactions;
@property DWNativeResizeDriver *nativeResizeDriver;
@property DWNativeHiddenRoot *nativeFillRoot;
@property DWNativeTransitionCapture *nativeFillCapture;
@property DWNativeTransition *nativeFillPicture;
@property BOOL nativeFillHiding,nativeFillAnimating,nativeFillAnimated,nativeFillRevealing;
@property CFTimeInterval nativeFillPresentationDeadline;
@property BOOL nativeFillResuming;
@property uint64_t nativeFillBlockedButtons;
@property BOOL nativeFillBlockedScroll;
@property (weak) LiveSource *nativeMouseOwner;
@property DWNativePresenter *nativeViewPresenter;
@property NSUInteger nativeFamilyRevision,nativeViewFamilyRevision;
@property BOOL nativeViewEnabled;
@property uint64_t nativeViewTransferRevision,nativePlacementRequestRevision;
@property NSTimer *nativeTransferTimer;
@property CFTimeInterval nativeTransferUntil,nativeTransferNextCheck;
@property NSUInteger nativeTransferCursor;
@property DWNativeViewTransfer *nativeOwnershipTransfer;
@property CFTimeInterval nativeOwnershipDeadline;
// Physical hover observation is coalesced in the tap; staging happens later.
@property NSDictionary *nativeHoverObservation;
@property NSDictionary *nativeHoverPresentation;
@property DWNativeViewTransfer *nativeHoverTransfer;
@property (weak) DesktopView *nativeHoverView;
@property BOOL nativeHoverQueued;
@property uint64_t nativeHoverEpoch;
@property CFTimeInterval nativeHoverUntil;
@property NSArray<NSDictionary *> *nativeEndpoints; // authenticated launch endpoints, never rediscovered
@property DWDockReloader *dockReloader; // compositor mode with the launch daemon on: loads the payload into a Dock that replaced the one the helper lived in
@property BOOL nativeDesktopMode; // explicit login-user desktop authority, never inferred from an empty scope
@property BOOL nativeRestoring,nativeResumeWanted,nativeResumeInFlight;
@property uint64_t nativeSessionEpoch;
@property NSUInteger nativeResumeFailures;
@property CFTimeInterval nativeResumeAfter;
@property NSString *nativeResumeNote;
@property DWNativeInput *nativeInput;
@property DWNativeTabletRouter *tablet;
@property DWNativePointerGrab *pointerGrab;
@property DWNativeRelativeMotion *relativeMotion;
@property NSMutableSet<NSNumber *> *postingTags;
@property NSDictionary *controllerSnapshot,*controllerVisualSnapshot,*renderedPresentation;
@property (copy) NSString *renderedStatusText;
@property DesktopView *nativeGestureView,*nativeScrollView;
@property DesktopView *nativeMagnifyView;
@property LiveSource *nativeMagnifySource;
@property BOOL nativePinchAccepted;
@property NSInteger nativeGestureButton;
@property NSTimeInterval nativeScrollTime;
@property BOOL nativeInputNoted;
// Set only while a fresh plain title down is evaluated at the session tap.
// The copied annotations select the common admission path; nothing is posted.
@property BOOL routingEarlyNativeTitle;
@property NSDictionary *nativeDecorationPress;
@property NSNumber *nativeButtonHover;
@property CFTimeInterval nativeButtonMotion;
@property dispatch_queue_t nativeButtonQueue;
@property BOOL screenshotBusy;
@property BOOL adopted; // adoption_complete was sent for the manager in place
@property NSString *discoveryNote; // the failed-read note last written to stderr
@property BOOL sceneDirty; // window or camera changes: coalesced into the next poll's save
@property DWSceneWriter *sceneWriter;
// The canvas is drawn the way DriftWM draws it, one compositor layer per output.
@property DWCanvasRenderer *compositor;
@property NSString *backgroundNote; // why the background is not the configured one, upstream's error bar
// Per-screen inherited stills. Workspace queries happen on refresh, image I/O
// and Metal upload on a worker; camera/video frames only reuse these programs.
@property NSMutableDictionary<NSNumber *,NSMutableDictionary *> *macWallpapers;
@property dispatch_queue_t wallpaperWorker;
@property NSTimer *wallpaperTimer;
@property id wallpaperSpaceObserver;
@property uint64_t wallpaperEpoch;
@property uint64_t wallpaperRefreshGeneration;

@property NSMutableArray<NSPanel *> *panels;
@property NSMutableArray<DesktopView *> *views;
@property NSMutableDictionary<NSNumber *,LiveSource *> *sources;
@property NSMutableArray<NSDictionary *> *choices;
@property NSMutableArray *pendingStops; // sources being detached, and streams stopped on demand
@property BOOL captureRecoveryReading;
@property NSUInteger captureRecoveryGeneration;
@property NSUInteger captureStopsTimedOut;
@property NSArray<SCWindow *> *shareable;
@property NSWindow *chooser;
@property NSTableView *table;
@property NSTextField *chooserStatus;
@property NSPopUpButton *rebind;
@property NSButton *grant;
@property NSString *statePath;
@property NSString *startupError;
@property NSString *statusText;
@property BOOL cleaning;
@property EventHotKeyRef exitHotkey;
@property EventHandlerRef hotkeyHandler;
- (NSDictionary *)call:(NSDictionary *)command;
- (void)poll;
- (void)saveScene;
- (BOOL)loadScene:(NSString *)path;
@property DWOnboarding *onboarding; // the one window of a launch that cannot open its canvas yet
@property BOOL relaunch; // that window's Relaunch: main() starts this run again once it has ended
@property BOOL hoverUndelivered; // --no-hover-forwarding: pointer motion never reaches an application
@end
// What main.m calls to start and end a run (implemented in the Desktop+*.m files; see Desktop+Private.h for the rest).
@interface Desktop (Launch) <NSApplicationDelegate>
- (void)say:(NSString *)note;
- (void)resizeCapability;
- (void)quit:(id)sender;
- (void)loadConfig:(BOOL)platform;
- (BOOL)startIPC:(NSString *)path;
- (void)showChooser:(id)sender;
- (void)openCanvas:(id)sender;
- (void)putBackWindowSettings;
- (void)cleanup;
- (void)onboard;
- (void)runAutostart;
// The setup assistant beside this run (Desktop+Session.m), given `setup`'s arguments: what opening Infinify again shows
// (none), and what the update notification opens (--update).
- (void)openSetupAssistant:(NSArray<NSString *> *)arguments;
@end
// A newer release (DWUpdateCheck.h), read when a desktop run starts and every six hours after, told once per version by a
// notification whose click opens the setup assistant (Desktop+Updates.m). Windowed, chooser and scoped runs never look.
@interface Desktop (Updates) <UNUserNotificationCenterDelegate>
- (void)watchForUpdates;
@end
