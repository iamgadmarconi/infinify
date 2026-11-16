// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWWindow
- (DWMetadata *)metadata { return [self cachedProjection:@"metadata" make:^id{return DWProject(DWMetadata.class,self.rawDictionary[@"metadata"]);}]; }
- (DWPin *)pinned { return [self cachedProjection:@"pinned" make:^id{return DWProject(DWPin.class,self.rawDictionary[@"pinned"]);}]; }
- (DWWindowRule *)rule { return [self cachedProjection:@"rule" make:^id{return DWProject(DWWindowRule.class,self.rawDictionary[@"rule"]);}]; }
- (NSString *)mode { return DWString(self.rawDictionary[@"mode"]); }
- (DWPlacement *)placementOnOutput:(NSNumber *)output screenRect:(CGRect)screenRect clipRect:(CGRect)clipRect pinned:(BOOL)pinned familyOnly:(BOOL)familyOnly {
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];d[@"output"]=output;d[@"pinned"]=@(pinned);
    d[@"screen_rect"]=DWSceneRectDictionary(screenRect);d[@"clip_rect"]=DWSceneRectDictionary(clipRect);
    d[@"presentation_settled"]=@(self.source.observationKnown.boolValue);
    d[@"world_local_crop"]=NSNull.null;d[@"buffer_crop"]=NSNull.null;d[@"family_only"]=@(familyOnly);
    return DWProject(DWPlacement.class,[d copy]);
}
- (BOOL)hasSameSizeTransitionBindingAsWindow:(DWWindow *)other {
    if(!other)return NO;for(NSString *k in @[@"source",@"world_rect",@"pinned",@"widget",@"mode",@"kind"]){
        if([k isEqual:@"world_rect"]&&self.pinned)continue;
        if(![(self.rawDictionary[k]?:NSNull.null)isEqual:(other.rawDictionary[k]?:NSNull.null)])return NO;
    }return YES;
}
- (DWPlacement *)capturePlacement {
    return [self cachedProjection:@"capturePlacement" make:^id{
        NSMutableDictionary *d=[self.rawDictionary mutableCopy];d[@"presentation_settled"]=@(self.source&&self.source.observationKnown.boolValue);
        if(!d[@"title"])d[@"title"]=self.metadata.title?:@"";
        if(!d[@"app_name"])d[@"app_name"]=self.metadata.bundleID?:@"";return DWProject(DWPlacement.class,[d copy]);
    }];
}
- (BOOL)hasSameSizeTransitionBindingAsWindow:(DWWindow *)other ignoringWorldRect:(BOOL)ignore {
    if(!other)return NO;for(NSString *k in @[@"source",@"world_rect",@"pinned",@"widget",@"mode",@"kind"]){
        if(ignore&&[k isEqual:@"world_rect"])continue;if(![(self.rawDictionary[k]?:NSNull.null)isEqual:(other.rawDictionary[k]?:NSNull.null)])return NO;
    }return YES;
}
- (BOOL)isPinned { id p=self.rawDictionary[@"pinned"];return DWNumber(p).boolValue||DWDictionary(p)!=nil; }
@end
