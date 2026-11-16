// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWPlacement
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
- (CGRect)screenRect { return DWSceneRect(self.rawDictionary[@"screen_rect"]); }
- (CGRect)clipRect { return DWSceneRect(self.rawDictionary[@"clip_rect"]); }
- (CGRect)worldLocalCrop { return DWSceneRect(self.rawDictionary[@"world_local_crop"]); }
- (CGRect)bufferCrop { return DWSceneRect(self.rawDictionary[@"buffer_crop"]); }
- (NSNumber *)pinned { return DWNumber(self.rawDictionary[@"pinned"]); }
- (NSNumber *)fullscreen { return DWNumber(self.rawDictionary[@"fullscreen"]); }
- (NSNumber *)familyOnly { return DWNumber(self.rawDictionary[@"family_only"]); }
- (NSNumber *)nativeMember { return DWNumber(self.rawDictionary[@"native_member"]); }
- (DWIdentity *)rootIdentity { return [self cachedProjection:@"rootIdentity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"root_identity"]);}]; }
- (DWPlacement *)placementWithScreenRect:(CGRect)screenRect clipRect:(CGRect)clipRect {
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];d[@"screen_rect"]=DWSceneRectDictionary(screenRect);d[@"clip_rect"]=DWSceneRectDictionary(clipRect);return DWProject(self.class,[d copy]);
}
- (DWPlacement *)placementWithNativeMember:(NSNumber *)member rootIdentity:(DWIdentity *)identity {
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];d[@"native_member"]=member;d[@"root_identity"]=identity.rawDictionary;return DWProject(self.class,[d copy]);
}
- (DWValuePresence)bufferCropPresence { return DWPresence(self.rawDictionary[@"buffer_crop"],NSDictionary.class); }
- (DWValuePresence)worldLocalCropPresence { return DWPresence(self.rawDictionary[@"world_local_crop"],NSDictionary.class); }
- (BOOL)isEqualIgnoringFocus:(DWPlacement *)other {
    if(!other)return NO;NSMutableDictionary *a=[self.rawDictionary mutableCopy],*b=[other.rawDictionary mutableCopy];[a removeObjectForKey:@"focused"];[b removeObjectForKey:@"focused"];return [a isEqual:b];
}
- (DWValuePresence)screenRectPresence { return DWPresence(self.rawDictionary[@"screen_rect"],NSDictionary.class); }
- (BOOL)screenRectHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"screen_rect"],2); }
- (DWValuePresence)clipRectPresence { return DWPresence(self.rawDictionary[@"clip_rect"],NSDictionary.class); }
- (BOOL)clipRectHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"clip_rect"],2); }
- (BOOL)worldLocalCropHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"world_local_crop"],2); }
- (BOOL)bufferCropHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"buffer_crop"],2); }
- (DWPlacement *)placementByRemovingFocus {
    if(!self.rawDictionary[@"focused"])return self;
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];[d removeObjectForKey:@"focused"];return DWProject(self.class,[d copy]);
}
- (CGRect)screenRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"screen_rect"],2)?self.screenRect:CGRectNull; }
- (CGRect)clipRectOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"clip_rect"],2)?self.clipRect:CGRectNull; }
- (CGRect)worldLocalCropOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"world_local_crop"],2)?self.worldLocalCrop:CGRectNull; }
- (CGRect)bufferCropOrNull { return DWSceneGeometryIsNumeric(self.rawDictionary[@"buffer_crop"],2)?self.bufferCrop:CGRectNull; }
- (BOOL)isCurrentOutputPlacement { return self.window&&self.output&&self.isCurrentDrawnPlacement; }
- (BOOL)isPinned { id pin=self.rawDictionary[@"pinned"];return DWNumber(pin).boolValue||DWDictionary(pin)!=nil; }
- (CGRect)nativePresentationRect {
    NSDictionary *origin=self.rawDictionary[@"screen_rect"][@"origin"],*size=self.rawDictionary[@"screen_rect"][@"size"];
    return CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[size[@"width"]doubleValue],[size[@"height"]doubleValue]);
}
- (double)nativePresentationClipArea {
    NSDictionary *size=self.rawDictionary[@"clip_rect"][@"size"];
    return [size[@"width"]doubleValue]*[size[@"height"]doubleValue];
}
- (NSNumber *)alpha { return DWNumber(self.rawDictionary[@"alpha"]); }
@end
