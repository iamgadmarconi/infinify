// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWHit
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
- (DWIdentity *)identity { return [self cachedProjection:@"identity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"identity"]);}]; }
- (CGPoint)local { return DWScenePoint(self.rawDictionary[@"local"]); }
- (CGPoint)bufferLocal { return DWScenePoint(self.rawDictionary[@"buffer_local"]); }
- (CGPoint)nativeScreen { return DWScenePoint(self.rawDictionary[@"native_screen"]); }
- (NSNumber *)requiresNativeRevalidation { return DWNumber(self.rawDictionary[@"requires_native_revalidation"]); }
- (NSNumber *)widget { return DWNumber(self.rawDictionary[@"widget"]); }
- (NSNumber *)pinned { return DWNumber(self.rawDictionary[@"pinned"]); }
- (DWValuePresence)localPresence { return DWPresence(self.rawDictionary[@"local"],NSDictionary.class); }
- (BOOL)localHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"local"],0); }
- (DWValuePresence)bufferLocalPresence { return DWPresence(self.rawDictionary[@"buffer_local"],NSDictionary.class); }
- (BOOL)bufferLocalHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"buffer_local"],0); }
- (DWValuePresence)nativeScreenPresence { return DWPresence(self.rawDictionary[@"native_screen"],NSDictionary.class); }
- (BOOL)nativeScreenHasNumericComponents { return DWSceneGeometryIsNumeric(self.rawDictionary[@"native_screen"],0); }
- (NSNumber *)pick { return DWNumber(self.rawDictionary[@"pick"]); }
- (NSDictionary *)nativeMember { return DWDictionary(self.rawDictionary[@"native_member"]); }
- (DWIdentity *)rootIdentity { return [self cachedProjection:@"rootIdentity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"root_identity"]);}]; }
- (DWHit *)hitWithPick:(BOOL)pick { NSMutableDictionary *copy=[self.rawDictionary mutableCopy];copy[@"pick"]=@(pick);return DWProject(DWHit.class,[copy copy]); }
- (DWHit *)hitWithNativeMember:(NSDictionary *)member { NSMutableDictionary *copy=[self.rawDictionary mutableCopy];copy[@"native_member"]=member;return DWProject(DWHit.class,[copy copy]); }
+ (instancetype)hitWithWindow:(NSNumber *)window identity:(DWIdentity *)identity generation:(NSNumber *)generation local:(NSValue *)local nativeMember:(NSDictionary *)member pick:(NSNumber *)pick widget:(NSNumber *)widget pinned:(NSNumber *)pinned {
    NSMutableDictionary *raw=[NSMutableDictionary new];
    if(window)raw[@"window"]=window;if(identity)raw[@"identity"]=identity.rawDictionary;if(generation)raw[@"generation"]=generation;
    if(local){CGPoint p=local.pointValue;raw[@"local"]=@{@"x":@(p.x),@"y":@(p.y)};}
    if(member)raw[@"native_member"]=member;if(pick)raw[@"pick"]=pick;if(widget)raw[@"widget"]=widget;if(pinned)raw[@"pinned"]=pinned;
    return DWProject(self,[raw copy]);
}
- (NSNumber *)placeholder { return DWNumber(self.rawDictionary[@"placeholder"]); }
@end
