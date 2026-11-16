// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWScreenshotRegionTarget
- (NSNumber *)x { return DWNumber(self.rawDictionary[@"x"]); }
- (NSNumber *)y { return DWNumber(self.rawDictionary[@"y"]); }
- (NSNumber *)w { return DWNumber(self.rawDictionary[@"w"]); }
- (NSNumber *)h { return DWNumber(self.rawDictionary[@"h"]); }
- (NSNumber *)fromScreen { return DWNumber(self.rawDictionary[@"from_screen"]); }
@end
