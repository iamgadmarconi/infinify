// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWFullscreen
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (NSString *)backdrop { return DWString(self.rawDictionary[@"backdrop"]); }
@end
