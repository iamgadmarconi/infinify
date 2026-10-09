// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-coordinator.h"
@interface DWNativeResizeDriver : NSObject <DWResizeDriver>
// Optional owned-probe lease; invoked on the serial worker immediately before AXSize.
// nil preserves the production root-only policy. Never enter the controller here.
@property (copy) BOOL (^mutationPreparation)(NSDictionary *effect);
// Lightweight final check after adapter setup; no AX/family/file operations.
@property (copy) BOOL (^mutationGuard)(NSDictionary *effect);
@property (copy) void (^didPerform)(NSDictionary *effect, NSDictionary *result);
@end
