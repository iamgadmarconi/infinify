// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "DWSetupState.h"
#import "DWLoaderService.h"
// The setup assistant: the one window a plain launch shows until setup is done, and again when Infinify is opened from
// Finder while it runs. It grows out of the permission window (DWOnboarding.h) and takes over the terminal steps of an
// install. Five panes, in Ego's design language (DWSetupButton.h):
//
//   Welcome      what Infinify is; another copy in an Applications folder is removed first (DWUninstall.h)
//   Permissions  Accessibility (required) and Screen Recording (for extra displays and the demo), each with Allow
//   Login        the login item is registered, not offered: Infinify starts at every login and after a crash
//   Compositor   the doctor's reading of SIP and the boot argument; while it fails, the Recovery steps, what each changes
//                and how to undo it, and the demo; once it passes, the launch daemon is registered and approved
//   Ready        the keys to find one's way; Start hands over to compositor mode, or opens the demo
//
// Every pane reached is recorded (DWSetupState.h), so setup resumes there after the Screen Recording relaunch and after
// the restart Recovery needs (the login item, registered by then, opens it). The assistant changes nothing by itself: each
// registration follows the owner's click, and SIP and the boot argument stay the owner's to change. Main thread only.
@interface DWSetupAssistant : NSObject
- (instancetype)initWithSupportDirectory:(NSString *)supportDirectory;
// Compositor mode is set up and Start was clicked: the run ends and hands over (DWSetupHandOverToCompositor).
@property(copy) void (^onCompositor)(void);
// The demo was chosen and Start was clicked: this run opens its capture-mode canvas.
@property(copy) void (^onDemo)(void);
// Screen Recording was allowed: this run starts again, since macOS gives it only to a newly started process.
@property(copy) void (^onRelaunch)(void);
// The window was closed before setup ended.
@property(copy) void (^onQuit)(void);
// Why compositor mode did not start, as the launcher said it; shown on the compositor pane.
@property(copy) NSString *refusal;
// The mode of the canvas this run has open, DWSetupIncomplete for none (the assistant was opened again from Finder in a
// running Infinify otherwise): with a canvas, closing the window only closes it, and Ready says Done for the mode running.
@property DWSetupMode canvasMode;
// Shows the window at the pane setup resumes at (the compositor pane when there is a refusal), or at the given pane.
- (void)show;
- (void)showPane:(DWSetupPane)pane;
@property(readonly) DWSetupPane pane;
@property(readonly) NSWindow *window;
// Closes the window and stops looking. Idempotent.
- (void)close;

// Seams, for the fixture that draws every pane (tests/native/app/System/DWSetupAssistantFixture.m). Each defaults to the
// real thing: the two grants, the doctor's policy, the launch daemon, the login item, the other copies and their removal.
@property(copy) BOOL (^accessibility)(void);
@property(copy) BOOL (^screenRecording)(void);
@property(copy) DWSetupPolicy (^policy)(void);
@property(copy) DWLoaderState (^daemonState)(void);
@property(copy) NSInteger (^loginItemStatus)(void); // an SMAppServiceStatus
@property(copy) BOOL (^compositorAtLogin)(void);    // the login-mode record exists (DWNativeDesktopCLI.h)
@property(copy) NSArray<NSString *> *(^otherCopies)(void);
// Builds the pane into the window without showing it or recording it; for the fixture's pictures.
- (void)buildPane:(DWSetupPane)pane;
@end

// `Infinify setup [--refused REASON]`, and what a plain launch or the login item runs while setup is not done: the assistant
// alone, with no canvas and without the canvas run's lease, so it can run beside an Infinify that holds it (an older copy
// being replaced, or a demo canvas). One assistant at a time (setup.lock in the support directory; a second one ends at
// once with status 0). It ends by replacing this process: with the hand-over to compositor mode (a running demo canvas of
// this bundle is ended first), with `--demo` (the capture-mode canvas), or with itself again for Screen Recording.
// --refused is how the launcher, refused at login, says why compositor mode did not start. Returns the exit status when it
// ends without replacing itself: 0 when the window was closed.
int DWSetupRun(int argc,const char **argv);
