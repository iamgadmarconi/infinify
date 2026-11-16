// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWMetadata
- (NSString *)bundleID { return DWString(self.rawDictionary[@"bundle_id"]); }
- (NSString *)title { return DWString(self.rawDictionary[@"title"]); }
@end
