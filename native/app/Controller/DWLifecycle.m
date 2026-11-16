// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWLifecycle
- (NSArray *)relaunching { return DWArray(self.rawDictionary[@"relaunching"]); }
- (NSArray *)standins { return DWArray(self.rawDictionary[@"standins"]); }
- (NSNumber *)settled { return DWNumber(self.rawDictionary[@"settled"]); }
- (NSArray *)held { return DWArray(self.rawDictionary[@"held"]); }
@end
