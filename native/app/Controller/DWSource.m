// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWSource
- (DWIdentity *)identity { return [self cachedProjection:@"identity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"identity"]);}]; }
- (NSNumber *)generation { return DWNumber(self.rawDictionary[@"generation"]); }
- (CGSize)buffer { return DWSceneSize(self.rawDictionary[@"buffer"]); }
- (CGRect)contentRect { return DWSceneRect(self.rawDictionary[@"content_rect"]); }
- (CGRect)originalRect { return DWSceneRect(self.rawDictionary[@"original_rect"]); }
- (CGRect)observedRect { return DWSceneRect(self.rawDictionary[@"observed_rect"]); }
- (NSNumber *)observationKnown { return DWNumber(self.rawDictionary[@"observation_known"]); }
- (NSString *)visibility { return DWString(self.rawDictionary[@"visibility"]); }
- (NSNumber *)visibilityRevision { return DWNumber(self.rawDictionary[@"visibility_revision"]); }
- (NSNumber *)visibilityPending { return DWNumber(self.rawDictionary[@"visibility_pending"]); }
- (NSNumber *)visibilityPlacementReady { return DWNumber(self.rawDictionary[@"visibility_placement_ready"]); }
+ (instancetype)sourceWithIdentity:(DWIdentity *)identity generation:(NSNumber *)generation buffer:(CGSize)buffer contentRect:(CGRect)contentRect originalRect:(CGRect)originalRect observedRect:(CGRect)observedRect observationKnown:(BOOL)known {
    return DWProject(self,@{@"identity":identity.rawDictionary,@"generation":generation,@"buffer":DWSceneSizeDictionary(buffer),@"content_rect":DWSceneRectDictionary(contentRect),@"original_rect":DWSceneRectDictionary(originalRect),@"observed_rect":DWSceneRectDictionary(observedRect),@"observation_known":@(known)});
}
- (DWValuePresence)bufferPresence { return DWPresence(self.rawDictionary[@"buffer"],NSDictionary.class); }
- (BOOL)bufferHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"buffer"],1); }
- (DWValuePresence)contentRectPresence { return DWPresence(self.rawDictionary[@"content_rect"],NSDictionary.class); }
- (BOOL)contentRectHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"content_rect"],2); }
- (DWValuePresence)originalRectPresence { return DWPresence(self.rawDictionary[@"original_rect"],NSDictionary.class); }
- (BOOL)originalRectHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"original_rect"],2); }
- (DWValuePresence)observedRectPresence { return DWPresence(self.rawDictionary[@"observed_rect"],NSDictionary.class); }
- (BOOL)observedRectHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"observed_rect"],2); }
- (CGRect)contentRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"content_rect"],2)?self.contentRect:CGRectNull; }
- (CGRect)originalRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"original_rect"],2)?self.originalRect:CGRectNull; }
- (CGRect)observedRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"observed_rect"],2)?self.observedRect:CGRectNull; }
@end
