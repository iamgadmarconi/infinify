// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWSizeEffect
- (NSNumber *)transaction { return DWNumber(self.rawDictionary[@"transaction"]); }
- (CGSize)requested { return DWSceneSize(self.rawDictionary[@"requested"]); }
- (CGPoint)nativeOrigin { return DWScenePoint(self.rawDictionary[@"native_origin"]); }
- (NSString *)nativeAction { return DWString(self.rawDictionary[@"native_action"]); }
- (DWValuePresence)requestedPresence { return DWPresence(self.rawDictionary[@"requested"],NSDictionary.class); }
- (DWValuePresence)nativeOriginPresence { return DWPresence(self.rawDictionary[@"native_origin"],NSDictionary.class); }
- (BOOL)requestedHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"requested"],1); }
- (BOOL)nativeOriginHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"native_origin"],0); }
- (BOOL)nativeOriginIsExactPoint {
    NSDictionary *point=DWDictionary(self.rawDictionary[@"native_origin"]);
    return point.count==2&&DWSceneGeometryIsNumeric(point,0);
}
- (CGSize)nativeRequestedSize {
    NSDictionary *size=DWDictionary(self.rawDictionary[@"requested"]);
    return CGSizeMake([size[@"width"]doubleValue],[size[@"height"]doubleValue]);
}
@end
