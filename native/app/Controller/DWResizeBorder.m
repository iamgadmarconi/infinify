// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWResizeBorder
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (NSString *)edges { return DWString(self.rawDictionary[@"edges"]); }
- (NSNumber *)snapped { return DWNumber(self.rawDictionary[@"snapped"]); }
@end
