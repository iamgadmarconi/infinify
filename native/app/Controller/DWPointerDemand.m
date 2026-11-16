// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWPointerDemand
- (NSNumber *)needsPointer { return DWNumber(self.rawDictionary[@"needs_pointer"]); }
- (NSNumber *)active { return DWNumber(self.rawDictionary[@"active"]); }
@end
