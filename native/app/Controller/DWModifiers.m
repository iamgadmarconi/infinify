// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWModifiers
- (NSNumber *)command { return DWNumber(self.rawDictionary[@"command"]); }
- (NSNumber *)control { return DWNumber(self.rawDictionary[@"control"]); }
- (NSNumber *)option { return DWNumber(self.rawDictionary[@"option"]); }
- (NSNumber *)shift { return DWNumber(self.rawDictionary[@"shift"]); }
@end
