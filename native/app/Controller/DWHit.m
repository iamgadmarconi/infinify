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
- (NSNumber *)nativeMember { return DWNumber(self.rawDictionary[@"native_member"]); }
- (DWIdentity *)rootIdentity { return [self cachedProjection:@"rootIdentity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"root_identity"]);}]; }
@end
