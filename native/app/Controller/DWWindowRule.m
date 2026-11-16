// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWWindowRule
- (NSNumber *)preserveAspectRatio { return DWNumber(self.rawDictionary[@"preserve_aspect_ratio"]); }
@end
