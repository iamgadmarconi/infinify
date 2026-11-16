// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWBlurSettings
- (NSNumber *)enabled { return DWNumber(self.rawDictionary[@"enabled"]); }
- (NSNumber *)radius { return DWNumber(self.rawDictionary[@"radius"]); }
- (NSNumber *)passes { return DWNumber(self.rawDictionary[@"passes"]); }
- (NSNumber *)noise { return DWNumber(self.rawDictionary[@"noise"]); }
@end
