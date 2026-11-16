// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWScreenshotWindowTarget
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (NSNumber *)fitPadding { return DWNumber(self.rawDictionary[@"fit_padding"]); }
- (NSNumber *)opacity { return DWNumber(self.rawDictionary[@"opacity"]); }
@end
