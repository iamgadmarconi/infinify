// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWFocusCycle
- (NSNumber *)index { return DWNumber(self.rawDictionary[@"index"]); }
- (NSArray *)windows { return DWArray(self.rawDictionary[@"windows"]); }
@end
