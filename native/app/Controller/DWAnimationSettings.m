// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWAnimationSettings
- (NSNumber *)enabled { return DWNumber(self.rawDictionary[@"enabled"]); }
- (NSNumber *)duration { return DWNumber(self.rawDictionary[@"duration"]); }
@end
