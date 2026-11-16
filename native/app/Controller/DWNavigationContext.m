// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWNavigationContext
- (NSString *)mode { return DWString(self.rawDictionary[@"mode"]); }
- (NSNumber *)zoom { return DWNumber(self.rawDictionary[@"zoom"]); }
- (CGPoint)camera { return DWScenePoint(self.rawDictionary[@"camera"]); }
- (DWValuePresence)cameraPresence { return DWPresence(self.rawDictionary[@"camera"],NSDictionary.class); }
- (BOOL)cameraHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"camera"],0); }
- (CGRect)usableRectLocal { return DWSceneRect(self.rawDictionary[@"usable_rect_local"]); }
- (CGRect)usableRectLocalOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"usable_rect_local"],2)?self.usableRectLocal:CGRectNull; }
- (BOOL)hasUsableRectEqualToRect:(CGRect)rect {
    return [self.rawDictionary[@"usable_rect_local"]isEqual:DWSceneRectDictionary(rect)];
}
@end
