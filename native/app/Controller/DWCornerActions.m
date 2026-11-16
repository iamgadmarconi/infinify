// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWCornerActions
- (NSString *)topLeft { return DWString(self.rawDictionary[@"top_left"]); }
- (NSString *)topRight { return DWString(self.rawDictionary[@"top_right"]); }
- (NSString *)bottomLeft { return DWString(self.rawDictionary[@"bottom_left"]); }
- (NSString *)bottomRight { return DWString(self.rawDictionary[@"bottom_right"]); }
- (BOOL)hasEntries { return self.rawDictionary.count>0; }
@end
