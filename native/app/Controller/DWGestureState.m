// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWGestureState
- (NSString *)state { return DWString(self.rawDictionary[@"state"]); }
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
@end
