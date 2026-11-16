// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWScene+Private.h"
@implementation DWControllerReply
- (NSNumber *)dirty { return DWNumber(self.rawDictionary[@"dirty"]); }
- (NSNumber *)needsFrames { return DWNumber(self.rawDictionary[@"needs_frames"]); }
- (NSNumber *)window { return DWNumber(self.rawDictionary[@"window"]); }
- (NSNumber *)output { return DWNumber(self.rawDictionary[@"output"]); }
- (NSNumber *)adopted { return DWNumber(self.rawDictionary[@"adopted"]); }
- (NSNumber *)background { return DWNumber(self.rawDictionary[@"background"]); }
- (NSNumber *)focusOnOpenSuppressed { return DWNumber(self.rawDictionary[@"focus_on_open_suppressed"]); }
- (NSArray *)changedOutputs { return DWArray(self.rawDictionary[@"changed_outputs"]); }
- (DWNavigation *)navigation { return [self cachedProjection:@"navigation" make:^id{return DWProject(DWNavigation.class,self.rawDictionary[@"navigation"]);}]; }
- (NSString *)error { return DWString(self.rawDictionary[@"error"]); }
- (NSString *)message { return DWString(self.rawDictionary[@"message"]); }
- (DWHit *)hit { return [self cachedProjection:@"hit" make:^id{return DWProject(DWHit.class,self.rawDictionary[@"hit"]);}]; }
- (DWBinding *)binding { return [self cachedProjection:@"binding" make:^id{return DWProject(DWBinding.class,self.rawDictionary[@"binding"]);}]; }
- (NSNumber *)passed { return DWNumber(self.rawDictionary[@"passed"]); }
- (NSNumber *)enabled { return DWNumber(self.rawDictionary[@"enabled"]); }
- (NSArray *)fingers { return DWArray(self.rawDictionary[@"fingers"]); }
- (NSNumber *)clockOnly { return DWNumber(self.rawDictionary[@"clock_only"]); }
- (NSNumber *)needsPointer { return DWNumber(self.rawDictionary[@"needs_pointer"]); }
- (NSNumber *)stateEvent { return DWNumber(self.rawDictionary[@"state_event"]); }
- (NSNumber *)revision { return DWNumber(self.rawDictionary[@"revision"]); }
- (NSNumber *)visibilityRevision { return DWNumber(self.rawDictionary[@"visibility_revision"]); }
- (DWSource *)source { return [self cachedProjection:@"source" make:^id{return DWProject(DWSource.class,self.rawDictionary[@"source"]);}]; }
- (DWIdentity *)identity { return [self cachedProjection:@"identity" make:^id{return DWProject(DWIdentity.class,self.rawDictionary[@"identity"]);}]; }
- (NSNumber *)generation { return DWNumber(self.rawDictionary[@"generation"]); }
- (DWSourceBinding *)sourceBinding { return [self cachedProjection:@"sourceBinding" make:^id{return DWProject(DWSourceBinding.class,self.rawDictionary[@"source_binding"]);}]; }
- (DWFocusCorrection *)focusCorrection { return [self cachedProjection:@"focusCorrection" make:^id{return DWProject(DWFocusCorrection.class,self.rawDictionary[@"focus_correction"]);}]; }
+ (instancetype)replyWithDictionary:(id)dictionary { return DWProject(self,dictionary); }
- (NSArray<DWEffect *> *)effects { return [self cachedProjection:@"effects" make:^id{return DWProjectArray(DWEffect.class,self.rawDictionary[@"effects"]);}]; }
- (DWEffect *)navigationEffect {
    return [self cachedProjection:@"navigationEffect" make:^id{
        DWEffect *effect=DWProjectEffect(self.rawDictionary[@"effect"]);if(effect)return effect;
        for(DWEffect *e in self.effects.reverseObjectEnumerator)if([e isKindOfClass:DWEffect.class]&&[e.operation isEqual:@"focus_native_window"])return e;
        return nil;
    }];
}
- (DWFocusEffect *)focusEffect {
    DWEffect *effect=self.navigationEffect;
    return effect.kind==DWEffectFocusNativeWindow?(DWFocusEffect *)effect:nil;
}
- (NSArray<DWSizeEffect *> *)sizeEffects {
    return [self cachedProjection:@"sizeEffects" make:^id{
        NSMutableArray *a=[NSMutableArray array];DWEffect *single=DWProjectEffect(self.rawDictionary[@"effect"]);if([single isKindOfClass:DWSizeEffect.class])[a addObject:single];
        for(DWEffect *e in self.effects)if([e isKindOfClass:DWSizeEffect.class])[a addObject:e];return a.copy;
    }];
}
- (NSArray<DWShellEffect *> *)shellEffects {
    return [self cachedProjection:@"shellEffects" make:^id{
        NSMutableArray *a=[NSMutableArray array];DWEffect *single=DWProjectEffect(self.rawDictionary[@"effect"]);if([single isKindOfClass:DWShellEffect.class])[a addObject:single];
        for(DWEffect *e in self.effects)if([e isKindOfClass:DWShellEffect.class])[a addObject:e];return a.copy;
    }];
}
- (NSArray<DWBinding *> *)bindings { return [self cachedProjection:@"bindings" make:^id{return DWProjectArray(DWBinding.class,self.rawDictionary[@"bindings"]);}]; }
- (DWValuePresence)effectPresence { return DWPresence(self.rawDictionary[@"effect"],NSDictionary.class); }
- (NSNumber *)pick { return DWNumber(self.rawDictionary[@"pick"]); }
- (NSNumber *)forward { return DWNumber(self.rawDictionary[@"forward"]); }
- (DWResizeBorder *)border { return [self cachedProjection:@"border" make:^id{return DWProject(DWResizeBorder.class,self.rawDictionary[@"border"]);}]; }
- (DWGestureState *)gesture { return [self cachedProjection:@"gesture" make:^id{return DWProject(DWGestureState.class,self.rawDictionary[@"gesture"]);}]; }
- (NSString *)line { return DWString(self.rawDictionary[@"line"]); }
- (NSNumber *)resized { return DWNumber(self.rawDictionary[@"resized"]); }
- (NSNumber *)moved { return DWNumber(self.rawDictionary[@"moved"]); }
- (NSString *)path { return DWString(self.rawDictionary[@"path"]); }
- (NSNumber *)exists { return DWNumber(self.rawDictionary[@"exists"]); }
- (NSArray *)warnings { return DWArray(self.rawDictionary[@"warnings"]); }
- (NSArray *)errors { return DWArray(self.rawDictionary[@"errors"]); }
- (NSString *)superModifier { return DWString(self.rawDictionary[@"super"]); }
- (NSNumber *)layoutIndependent { return DWNumber(self.rawDictionary[@"layout_independent"]); }
- (NSNumber *)repeatDelayMilliseconds { return DWNumber(self.rawDictionary[@"repeat_delay_ms"]); }
- (NSNumber *)repeatRateHertz { return DWNumber(self.rawDictionary[@"repeat_rate_hz"]); }
- (DWModifiers *)cycleHold { return [self cachedProjection:@"cycleHold" make:^id{return DWProject(DWModifiers.class,self.rawDictionary[@"cycle_hold"]);}]; }
- (DWPointerSettings *)settings { return [self cachedProjection:@"settings" make:^id{return DWProject(DWPointerSettings.class,self.rawDictionary[@"settings"]);}]; }
- (NSArray<DWBinding *> *)keys { return [self cachedProjection:@"keys" make:^id{return DWProjectArray(DWBinding.class,self.rawDictionary[@"keys"]);}]; }
- (NSArray<DWBinding *> *)mediaKeys { return [self cachedProjection:@"mediaKeys" make:^id{return DWProjectArray(DWBinding.class,self.rawDictionary[@"media_keys"]);}]; }
- (NSArray<DWBinding *> *)taps { return [self cachedProjection:@"taps" make:^id{return DWProjectArray(DWBinding.class,self.rawDictionary[@"taps"]);}]; }
- (NSArray<DWBinding *> *)skipped { return [self cachedProjection:@"skipped" make:^id{return DWProjectArray(DWBinding.class,self.rawDictionary[@"skipped"]);}]; }
- (NSArray<DWBinding *> *)reserved { return [self cachedProjection:@"reserved" make:^id{return DWProjectArray(DWBinding.class,self.rawDictionary[@"reserved"]);}]; }
- (NSArray<DWHotCornerSettings *> *)hotCorners { return [self cachedProjection:@"hotCorners" make:^id{return DWProjectArray(DWHotCornerSettings.class,self.rawDictionary[@"hot_corners"]);}]; }
- (DWControllerReply *)replyWithoutEffect {
    NSMutableDictionary *d=[self.rawDictionary mutableCopy];[d removeObjectForKey:@"effect"];return DWProject(self.class,d);
}
- (NSString *)failure { return DWString(self.rawDictionary[@"failure"]); }
@end
