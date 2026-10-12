// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-coordinator.h"
@interface DWNativeResizeDriver : NSObject <DWResizeDriver>
// Readback resizing keeps the adapter's fresh identity checks before and after every native call.
@property (copy) void (^didPerform)(NSDictionary *effect, NSDictionary *result);
@end
