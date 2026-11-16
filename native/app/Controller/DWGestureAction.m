// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWGestureAction
- (NSString *)action { return DWString(self.rawDictionary[@"action"]); }
- (NSString *)error { return DWString(self.rawDictionary[@"error"]); }
@end
