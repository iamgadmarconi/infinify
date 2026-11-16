// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWLifecycleEvent
- (NSNumber *)serial { return DWNumber(self.rawDictionary[@"serial"]); }
- (NSString *)event { return DWString(self.rawDictionary[@"event"]); }
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
@end
