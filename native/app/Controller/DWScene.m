// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
#import "DWBackingArray.h"
@implementation DWScene
- (DWFocus *)focus { return [self cachedProjection:@"focus" make:^id{return DWProject(DWFocus.class,self.rawDictionary[@"focus"]);}]; }
- (DWNavigation *)navigation { return [self cachedProjection:@"navigation" make:^id{return DWProject(DWNavigation.class,self.rawDictionary[@"navigation"]);}]; }
- (DWResizeTransaction *)nativeResize { return [self cachedProjection:@"nativeResize" make:^id{return DWProject(DWResizeTransaction.class,self.rawDictionary[@"native_resize"]);}]; }
- (DWRender *)render { return [self cachedProjection:@"render" make:^id{return DWProject(DWRender.class,self.rawDictionary[@"render"]);}]; }
- (DWLifecycle *)lifecycle { return [self cachedProjection:@"lifecycle" make:^id{return DWProject(DWLifecycle.class,self.rawDictionary[@"lifecycle"]);}]; }
+ (instancetype)sceneWithDictionary:(id)dictionary { return DWProject(self,dictionary); }
- (NSArray<DWWindow *> *)windows { return [self cachedProjection:@"windows" make:^id{return DWProjectArray(DWWindow.class,self.rawDictionary[@"windows"]);}]; }
- (NSArray<DWPlacement *> *)placements { return [self cachedProjection:@"placements" make:^id{return DWProjectArray(DWPlacement.class,self.rawDictionary[@"placements"]);}]; }
- (NSArray<DWOutput *> *)outputs { return [self cachedProjection:@"outputs" make:^id{return DWProjectArray(DWOutput.class,self.rawDictionary[@"outputs"]);}]; }
- (NSArray<DWLifecycleEvent *> *)lifecycleEvents { return [self cachedProjection:@"lifecycleEvents" make:^id{return DWProjectArray(DWLifecycleEvent.class,self.rawDictionary[@"lifecycle_events"]);}]; }
- (DWWindow *)windowWithID:(NSNumber *)identifier { for(DWWindow *w in self.windows)if([w isKindOfClass:DWWindow.class]&&[w.window isEqual:identifier])return w;return nil; }
- (DWOutput *)outputWithID:(NSNumber *)identifier { for(DWOutput *o in self.outputs)if([o isKindOfClass:DWOutput.class]&&[o.identifier isEqual:identifier])return o;return nil; }
- (DWScene *)sceneWithPlacements:(NSArray<DWPlacement *> *)placements {
    NSArray *values=[placements copy];NSMutableDictionary *d=[self.rawDictionary mutableCopy];
    d[@"placements"]=[[DWBackingArray alloc]initWithValues:values];DWScene *scene=DWProject(self.class,[d copy]);
    [scene sceneBySeedingProjectionsFrom:self];[scene cacheProjection:@"placements" value:values];return scene;
}
- (DWScene *)sceneWithOutputs:(NSArray<DWOutput *> *)outputs {
    NSArray *values=[outputs copy];NSMutableDictionary *d=[self.rawDictionary mutableCopy];
    d[@"outputs"]=[[DWBackingArray alloc]initWithValues:values];DWScene *scene=DWProject(self.class,[d copy]);
    [scene sceneBySeedingProjectionsFrom:self];[scene cacheProjection:@"outputs" value:values];return scene;
}
- (DWValuePresence)nativeResizePresence { return DWPresence(self.rawDictionary[@"native_resize"],NSDictionary.class); }
- (NSNumber *)passesAllKeys { return DWNumber(self.rawDictionary[@"pass_keys"]); }
- (NSArray<NSString *> *)passedKeyCombos { return DWArray(self.rawDictionary[@"pass_keys"]); }
- (DWValuePresence)passKeysPresence {
    id v=self.rawDictionary[@"pass_keys"];return DWPresence(v,[v isKindOfClass:NSArray.class]?NSArray.class:NSNumber.class);
}
- (BOOL)windowsAreObjects {
    NSArray *a=DWArray(self.rawDictionary[@"windows"]);if(!a)return NO;for(id v in a)if(!DWDictionary(v))return NO;return YES;
}
- (BOOL)placementsAreObjects {
    NSArray *a=DWArray(self.rawDictionary[@"placements"]);if(!a)return NO;for(id v in a)if(!DWDictionary(v))return NO;return YES;
}
- (BOOL)hasCurrentOutputPlacements {
    if(!self.placementsAreObjects)return NO;for(DWPlacement *p in self.placements)if(!p.isCurrentOutputPlacement)return NO;return YES;
}
- (DWScene *)sceneBySeedingProjectionsFrom:(DWScene *)previous {
    if(!previous)return self;
    static const struct { __unsafe_unretained NSString *raw;__unsafe_unretained NSString *projection; } sections[]={
        {@"windows",@"windows"},{@"placements",@"placements"},{@"outputs",@"outputs"},{@"focus",@"focus"},
        {@"navigation",@"navigation"},{@"native_resize",@"nativeResize"},{@"render",@"render"},
        {@"lifecycle",@"lifecycle"},{@"lifecycle_events",@"lifecycleEvents"}};
    for(NSUInteger i=0;i<sizeof(sections)/sizeof(sections[0]);i++){
        NSString *raw=sections[i].raw;
        if(self.rawDictionary[raw]==previous.rawDictionary[raw])[self seedCachedProjectionForKey:sections[i].projection fromValue:previous];
    }return self;
}
@end
