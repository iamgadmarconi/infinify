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
// The bundle's LaunchAgent property list, as SMAppService names it, and the pane where the owner approves the login item
// and the launch daemon (native-desktop-cli.m and loader-service.m name both).
extern NSString *const DWLoginItemAgentPlist;
extern NSString *const DWLoginItemsPane;
// Says on stderr, as `who: registering the bundle at PATH, which is not in an Applications folder; ...`, when the running
// bundle is not in an Applications folder: a registration names the bundle where it is, and a build directory's is replaced by every build.
void DWLoginItemWarnIfOutsideApplications(const char *who);
