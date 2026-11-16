// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWPin
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
- (CGRect)screenRect { return DWSceneRect(self.rawDictionary[@"screen_rect"]); }
- (DWValuePresence)screenRectPresence { return DWPresence(self.rawDictionary[@"screen_rect"],NSDictionary.class); }
- (BOOL)screenRectHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"screen_rect"],2); }
- (CGRect)screenRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"screen_rect"],2)?self.screenRect:CGRectNull; }
@end
