// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWRenderOutline
- (DWRGBA *)color { return [self cachedProjection:@"color" make:^id{return DWProjectColor(self.rawDictionary[@"color"]);}]; }
- (NSNumber *)thickness { return DWNumber(self.rawDictionary[@"thickness"]); }
- (NSNumber *)opacity { return DWNumber(self.rawDictionary[@"opacity"]); }
@end
