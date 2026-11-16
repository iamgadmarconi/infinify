// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
#include <math.h>
@implementation DWDrawnValue
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (CGRect)worldRect { return DWSceneRect(self.rawDictionary[@"world_rect"]); }
- (NSString *)kind { return DWString(self.rawDictionary[@"kind"]); }
- (NSNumber *)focused { return DWNumber(self.rawDictionary[@"focused"]); }
- (NSString *)title { return DWString(self.rawDictionary[@"title"]); }
- (NSString *)appName { return DWString(self.rawDictionary[@"app_name"]); }
- (NSNumber *)launching { return DWNumber(self.rawDictionary[@"launching"]); }
- (DWDecoration *)decoration { return [self cachedProjection:@"decoration" make:^id{return DWProject(DWDecoration.class,self.rawDictionary[@"decoration"]);}]; }
- (DWSource *)source { return [self cachedProjection:@"source" make:^id{return DWProject(DWSource.class,self.rawDictionary[@"source"]);}]; }
- (NSNumber *)opacity { return DWNumber(self.rawDictionary[@"opacity"]); }
- (NSNumber *)presentationSettled { return DWNumber(self.rawDictionary[@"presentation_settled"]); }
- (NSNumber *)widget { return DWNumber(self.rawDictionary[@"widget"]); }
- (DWValuePresence)worldRectPresence { return DWPresence(self.rawDictionary[@"world_rect"],NSDictionary.class); }
- (BOOL)worldRectHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"world_rect"],2); }
- (CGRect)worldRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"world_rect"],2)?self.worldRect:CGRectNull; }
- (BOOL)isCurrentDrawnPlacement {
    CGRect r=self.worldRectOrNull;
    return ([self.kind isEqual:@"window"]||[self.kind isEqual:@"standin"])&&self.focused
        &&isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        &&r.size.width>0&&r.size.height>0&&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r));
}
@end
