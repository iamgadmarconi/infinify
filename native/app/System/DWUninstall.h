// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// `Infinify uninstall [--leave-app]`: takes Infinify off this Mac, run before AppKit like `login-item`. In order: the login
// item is unregistered (which ends the instance launchd started), every other running process of this bundle's executable
// is sent SIGTERM, its orderly end, and given ten seconds; compositor mode is turned off as `native-desktop disable` does
// (login-mode record, Dock reload pause, launch daemon); window settings an unorderly end left changed are put back
// (DWSystemTakeover.h); setup's record is removed, so a later install starts setup afresh; and the bundle goes to the
// Trash, but only from an Applications folder. --leave-app leaves the bundle for a package manager to remove (the cask's
// `zap`). The scene and the config stay. Returns 0 when every step succeeded, 1 when one did not (each says why), 64 usage.
int DWUninstallCommand(int argc,const char **argv);

// Running processes of this user whose executable is the file at `executable`, this process left out.
NSArray<NSNumber *> *DWUninstallInstances(NSString *executable);
// Sends SIGTERM to each and waits up to `seconds` for all of them to end. YES when none is left.
BOOL DWUninstallStopInstances(NSArray<NSNumber *> *pids,NSTimeInterval seconds);

// Removes another copy of Infinify, for setup's welcome pane: that copy's own `uninstall`; for a build from before the
// command (which answers it with the usage status), its `login-item off` and `native-desktop disable`, its instances
// stopped and its bundle moved to the Trash. Blocking: off the main thread. NO with the reason when the copy is still there.
BOOL DWUninstallRetireCopy(NSString *bundle,NSString *__autoreleasing *why);
