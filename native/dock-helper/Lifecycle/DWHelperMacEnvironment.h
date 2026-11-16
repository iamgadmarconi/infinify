// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWHelperLifecycle.h"
// Real adapter: no path substitution, libproc queries, and the boot-session sysctl.
@interface DWHelperMacEnvironment : NSObject <DWHelperLifecycleEnvironment>
@end
