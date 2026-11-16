// SPDX-License-Identifier: GPL-3.0-or-later
// Press admission extracted from Desktop categories at 7d4a6d6; original split from native/desktop/main.m at 37b27b1.
#import "Desktop+Private.h"
@implementation Desktop (NativeMouse)
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point { return [self.pressAdmission nativeSource:window at:point]; }
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons { [self.pressAdmission nativeMouseOwnershipChanged:event buttons:buttons]; }
- (void)updateNativeMouseOwners { [self.pressAdmission updateNativeMouseOwners]; }
@end
