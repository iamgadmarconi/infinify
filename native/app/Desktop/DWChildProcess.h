// SPDX-License-Identifier: GPL-3.0-or-later
// The open-file limit at launch and the exec effect's child process.
#import <Foundation/Foundation.h>
// Raises the soft open-file limit at launch and remembers the original for children (DWChildProcess.m).
void raiseOpenFileLimit(void);
// The exec effect: /bin/sh -c in a session of its own; nil, or why it could not start (DWChildProcess.m).
NSString *execCommand(NSString *command,NSDictionary *env,void (^missing)(void));
