// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// `Infinify native-desktop [--check | --help | enable | disable | status]`, and `login-start`, which the login item runs.
// Run before AppKit, like `msg` and `login-item`: no window, no privacy grant.
//
//   (no argument)  the bundled launcher, in the owner's terminal: loads the Dock payload (through the launch daemon once
//                  enabled, else through sudo), then starts the app in compositor mode; it lifts a pause of automatic loading
//   --check        the launcher's read-only check
//   enable         make compositor mode the login default: register the launch daemon (the owner approves it once in
//                  System Settings > General > Login Items & Extensions), mark the login item as starting compositor mode,
//                  and register the login item if it was not on
//   disable        undo exactly that
//   status         report it, changing nothing
//   daemon status | ping | load ARGS...   the launcher's way to the launch daemon (not for typing)
//
// Returns the exit status: 0 done or reported, 1 refused, 64 usage; the launcher forms replace this process.
int DWNativeDesktopCommand(int argc,const char **argv);
// `login-start`: whether the owner enabled compositor mode as the login default.
BOOL DWNativeLoginIsCompositor(void);
// The login-mode record and the pause, for tests: the directory they live in.
BOOL DWNativeWriteLoginRecord(NSString *directory,BOOL agentAdded);
NSDictionary *DWNativeReadLoginRecord(NSString *directory);
BOOL DWNativeRemoveLoginRecord(NSString *directory);
