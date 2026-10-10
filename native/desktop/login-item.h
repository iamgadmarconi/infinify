// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// `Infinify login-item on | off | status`. DriftWM is the session: a display manager
// starts it and it is there until the session ends. Here that is a LaunchAgent of the
// login session, the property list the bundle carries at
// Contents/Library/LaunchAgents/com.marengox.infinify.agent.plist: started at login,
// started again after a crash, and left alone after a deliberate quit. `on` registers
// it through SMAppService, which starts it at once; `off` unregisters it, which ends
// the instance launchd started; `status` only reads. Run before AppKit starts, like
// `msg`: no window, no privacy grant. argv is what follows "login-item".
// Returns the exit status: 0 done or reported, 1 macOS refused, 64 usage.
int DWLoginItemCommand(int argc,const char **argv);
