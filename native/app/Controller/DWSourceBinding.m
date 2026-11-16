// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWSourceBinding
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (DWIdentity *)identity { return [self cachedProjection:@"identity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"identity"]);}]; }
- (NSNumber *)generation { return DWNumber(self.rawDictionary[@"generation"]); }
- (NSNumber *)observationKnown { return DWNumber(self.rawDictionary[@"observation_known"]); }
- (CGRect)observedRect { return DWSceneRect(self.rawDictionary[@"observed_rect"]); }
- (CGRect)observedRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"observed_rect"],2)?self.observedRect:CGRectNull; }
+ (instancetype)bindingWithWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation {
    return DWProject(self,@{@"window":window,@"identity":identity.rawDictionary,@"generation":generation});
}
@end
