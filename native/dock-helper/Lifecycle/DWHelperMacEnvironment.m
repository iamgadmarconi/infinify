// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWHelperMacEnvironment.h"
#include <signal.h>
@implementation DWHelperMacEnvironment
- (NSString *)fileSystemPath:(NSString *)logicalPath { return logicalPath; }
- (int)processInfo:(pid_t)pid result:(struct proc_bsdinfo *)result {
    return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,result,sizeof(*result));
}
- (int)probeProcess:(pid_t)pid { return kill(pid,0); }
- (BOOL)bootSessionUUID:(char [37])output { return DWHelperBootSessionUUID(output); }
@end
