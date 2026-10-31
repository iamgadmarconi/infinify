// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// What setup has decided, read from facts and one record, before AppKit starts: `login-start` and a plain launch ask it
// whether to start compositor mode, show the setup assistant (DWSetupAssistant.h) or run the demo.
//
// Compositor mode is the product; capture mode, which shows copies of the windows, is the demo for a Mac whose SIP still
// keeps the Dock helper out. Compositor mode is the login default exactly when the login-mode record exists (login.plist,
// DWNativeDesktopCLI.h), whether setup or `native-desktop enable` wrote it. The demo is remembered in setup.plist in the
// support directory, an owner-only record that also names the pane setup resumes at, so that setup goes on after the
// relaunch Screen Recording needs and after the restart Recovery needs.

typedef NS_ENUM(NSInteger,DWSetupMode) {
    DWSetupIncomplete, // a plain launch and the login item show the assistant
    DWSetupCompositor, // a plain launch and the login item start compositor mode through the bundled launcher
    DWSetupDemo,       // a plain launch and the login item open the capture-mode canvas
};
typedef NS_ENUM(NSInteger,DWSetupPane) {
    DWSetupPaneWelcome,
    DWSetupPanePermissions,
    DWSetupPaneLogin,
    DWSetupPaneCompositor,
    DWSetupPaneReady,
};
// The number of panes, for "N of 5".
extern const NSInteger DWSetupPaneCount;

// The mode, given the support directory and whether the login-mode record exists.
DWSetupMode DWSetupModeAt(NSString *supportDirectory,BOOL compositorAtLogin);
// The pane setup resumes at: the one recorded, else the welcome. A record that chose the demo resumes at the compositor
// pane, the one step left.
DWSetupPane DWSetupResumePaneAt(NSString *supportDirectory);
// Records the pane reached (keeping a demo choice), the demo, or nothing at all. YES when written or removed.
BOOL DWSetupRecordPane(NSString *supportDirectory,DWSetupPane pane);
BOOL DWSetupRecordDemo(NSString *supportDirectory);
BOOL DWSetupForget(NSString *supportDirectory);

// SIP and the arm64e boot argument as the doctor reads them (DWPreflight.h), read-only. `known` is NO when SIP could not be
// queried. Passing is what the launcher requires before it loads anything; it does not prove a load will work.
typedef struct { BOOL known,sipRelaxed,bootArgument; } DWSetupPolicy;
DWSetupPolicy DWSetupReadPolicy(void);
static inline BOOL DWSetupPolicyAllows(DWSetupPolicy policy) { return policy.known&&policy.sipRelaxed&&policy.bootArgument; }

// /Applications/Infinify.app and ~/Applications/Infinify.app, where an install puts the app.
NSArray<NSString *> *DWSetupCopyCandidates(void);
// YES when `bundle` is a directory holding a bundle with Infinify's identifier.
BOOL DWSetupIsInfinifyAt(NSString *bundle);
// The candidates that are another Infinify (a bundle with Infinify's identifier, not the file at `runningBundle`).
NSArray<NSString *> *DWSetupOtherCopies(NSString *runningBundle,NSArray<NSString *> *candidates);

// YES when this process is the login item's job: launchd names the job in XPC_SERVICE_NAME.
BOOL DWSetupRunningAsLoginItem(void);
// Compositor mode from setup: replaces this process, before AppKit or after its cleanup, so that the launcher's own check
// for a running Infinify finds none. The login item's job runs the launcher's --login itself; any other process asks
// launchd to start the login item (its program, `login-start`, does the same), so that the desktop is the job launchd
// restarts after a crash. `byHand` (Try again, after the launcher refused at login) runs the launcher as a start by hand
// instead, which also lifts a pause of automatic loading after Dock restarts. Returns only when the exec failed, with the
// exit status to use.
int DWSetupHandOverToCompositor(BOOL byHand);
