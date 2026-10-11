// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-coordinator.h"
@interface DWNativeResizeDriver : NSObject <DWResizeDriver>
// Optional owned-probe lease; invoked on the serial worker immediately before AXSize.
// nil preserves the production root-only policy. Never enter the controller here.
@property (copy) BOOL (^mutationPreparation)(NSDictionary *effect);
// Lightweight final check after adapter setup; no AX/family/file operations.
@property (copy) BOOL (^mutationGuard)(NSDictionary *effect);
// YES: no family guard stands before the setter. The root-only guard is a policy of the capture-acknowledged mode, whose picture is
// mapped through the root window's extent alone; readback mode maps nothing through a picture, and a refused guard would disable
// resizing of the window for good. The adapter's own identity checks before and after every call are not a guard and always run.
@property BOOL unguarded;
@property (copy) void (^didPerform)(NSDictionary *effect, NSDictionary *result);
@end
