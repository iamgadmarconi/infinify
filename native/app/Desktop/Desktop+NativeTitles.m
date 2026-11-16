// SPDX-License-Identifier: GPL-3.0-or-later
// Press admission extracted from Desktop categories at 7d4a6d6; original split from native/desktop/main.m at 37b27b1.
#import "Desktop+Private.h"
@implementation Desktop (NativeTitles)
- (void)refreshNativeButtons:(LiveSource *)source { [self.pressAdmission refreshNativeButtons:source]; }
- (BOOL)nativeGreen:(LiveSource *)source at:(CGPoint)point { return [self.pressAdmission nativeGreen:source at:point]; }
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output { return [self.pressAdmission replicaGreen:source at:point output:output]; }
@end
