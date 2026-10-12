// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-views.h"
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

static NSDictionary *viewDictionary(id value) { return [value isKindOfClass:NSDictionary.class]?value:nil; }
static NSArray *viewList(id value) { return [value isKindOfClass:NSArray.class]?value:@[]; }
static NSNumber *viewNumber(id value) { return [value isKindOfClass:NSNumber.class]?value:nil; }
static NSString *viewText(id value) { return [value isKindOfClass:NSString.class]?value:nil; }
static BOOL viewPositiveID(NSNumber *number) { return number&&isfinite(number.doubleValue)&&number.doubleValue>0&&floor(number.doubleValue)==number.doubleValue&&number.unsignedLongLongValue>0; }
static CGRect viewRect(id value) {
    NSDictionary *rect=viewDictionary(value),*origin=viewDictionary(rect[@"origin"]),*size=viewDictionary(rect[@"size"]);
    NSNumber *x=viewNumber(origin[@"x"]),*y=viewNumber(origin[@"y"]),*w=viewNumber(size[@"width"]),*h=viewNumber(size[@"height"]);
    if(!x||!y||!w||!h||!isfinite(x.doubleValue)||!isfinite(y.doubleValue)||!isfinite(w.doubleValue)||!isfinite(h.doubleValue)||w.doubleValue<=0||h.doubleValue<=0)return CGRectNull;
    CGRect result=CGRectMake(x.doubleValue,y.doubleValue,w.doubleValue,h.doubleValue);return isfinite(CGRectGetMaxX(result))&&isfinite(CGRectGetMaxY(result))?result:CGRectNull;
}
// The controller serializes an optional owner as null; the bound source need
// not carry it. Compare the full process instance and window number directly,
// rather than letting irrelevant representation differences change ownership.
static NSDictionary *viewIdentity(id value) {
    NSDictionary *identity=viewDictionary(value);NSNumber *pid=viewNumber(identity[@"pid"]),*seconds=viewNumber(identity[@"birth_sec"]),*micros=viewNumber(identity[@"birth_usec"]),*wid=viewNumber(identity[@"wid"]);
    if(!viewPositiveID(pid)||!viewPositiveID(seconds)||!micros||!isfinite(micros.doubleValue)||floor(micros.doubleValue)!=micros.doubleValue||!viewPositiveID(wid)||pid.longLongValue>INT32_MAX||seconds.longLongValue<=0||micros.longLongValue<0||micros.longLongValue>=1000000||wid.unsignedLongLongValue>UINT32_MAX)return nil;
    return @{@"pid":pid,@"birth_sec":seconds,@"birth_usec":micros,@"wid":wid};
}
static NSDictionary<NSNumber *,NSDictionary *> *viewOutputs(NSDictionary *snapshot) {
    NSMutableDictionary<NSNumber *,NSDictionary *> *outputs=[NSMutableDictionary dictionary];
    for(id value in viewList(snapshot[@"outputs"])){NSDictionary *output=viewDictionary(value);NSNumber *identifier=viewNumber(output[@"id"]),*zoom=viewNumber(output[@"zoom"]);NSDictionary *camera=viewDictionary(output[@"camera"]);
        if(!viewPositiveID(identifier)||CGRectIsNull(viewRect(output[@"screen_bounds"]))||!zoom||!isfinite(zoom.doubleValue)||zoom.doubleValue<=0||!viewNumber(camera[@"x"])||!viewNumber(camera[@"y"])||!isfinite([camera[@"x"]doubleValue])||!isfinite([camera[@"y"]doubleValue]))continue;
        if(!outputs[identifier])outputs[identifier]=output;
    }
    return outputs.copy;
}
static NSDictionary<NSNumber *,NSDictionary *> *viewBindings(NSDictionary *identities) {
    identities=viewDictionary(identities);NSMutableDictionary<NSNumber *,NSDictionary *> *bindings=[NSMutableDictionary dictionary];
    for(id window in identities){NSDictionary *identity=viewIdentity(identities[window]);if(viewPositiveID(viewNumber(window))&&identity)bindings[window]=identity;}
    return bindings.copy;
}
static NSDictionary *viewRectJSON(CGRect rect) {
    return @{@"origin":@{@"x":@(rect.origin.x),@"y":@(rect.origin.y)},@"size":@{@"width":@(rect.size.width),@"height":@(rect.size.height)}};
}
static BOOL viewSameProcess(NSDictionary *a,NSDictionary *b) {
    return a&&b&&[a[@"pid"]isEqual:b[@"pid"]]&&[a[@"birth_sec"]isEqual:b[@"birth_sec"]]&&[a[@"birth_usec"]isEqual:b[@"birth_usec"]];
}
static NSUInteger viewBucket(NSDictionary *placement) {
    return [viewNumber(placement[@"pinned"])boolValue]?2:[viewNumber(placement[@"widget"])boolValue]?0:1;
}
// Resolve only observed descendants, not an enclosing box guessed from pixels.
// The audited provider proves parentage; these checks keep stale/malformed
// geometry from requesting a placement after a root's binding has changed.
static NSArray<NSDictionary *> *viewFamilyMembers(NSDictionary *family,NSDictionary *source,NSDictionary *binding) {
    NSDictionary *identity=viewIdentity(family[@"identity"]);NSNumber *generation=viewNumber(family[@"generation"]);
    CGRect root=viewRect(family[@"native_bounds"]),observed=viewRect(source[@"observed_rect"]);
    if(!identity||![identity isEqual:binding]||!viewPositiveID(generation)||![generation isEqual:source[@"generation"]]||![viewNumber(source[@"observation_known"])boolValue]||CGRectIsNull(root)||CGRectIsNull(observed)||!CGRectEqualToRect(root,observed))return @[];
    NSNumber *rootID=identity[@"wid"];NSMutableDictionary<NSNumber *,NSDictionary *> *members=[NSMutableDictionary dictionary];
    for(id value in viewList(family[@"members"])){NSDictionary *member=viewDictionary(value),*who=viewIdentity(member[@"identity"]);NSNumber *parent=viewNumber(member[@"parent"]);
        if(!viewSameProcess(who,identity)||CGRectIsNull(viewRect(member[@"native_bounds"]))||!parent||!isfinite(parent.doubleValue)||floor(parent.doubleValue)!=parent.doubleValue||parent.longLongValue<0||parent.unsignedLongLongValue>UINT32_MAX)continue;
        NSNumber *wid=who[@"wid"];if(members[wid])continue;
        if([wid isEqual:rootID]){if(parent.unsignedIntValue||!CGRectEqualToRect(viewRect(member[@"native_bounds"]),root))return @[];continue;}
        members[wid]=member;
    }
    NSMutableArray<NSDictionary *> *children=[NSMutableArray array];
    for(NSDictionary *member in members.allValues){NSNumber *cursor=viewIdentity(member[@"identity"])[@"wid"];NSMutableSet<NSNumber *> *seen=[NSMutableSet set];BOOL linked=NO;
        while(cursor&&![seen containsObject:cursor]){if([cursor isEqual:rootID]){linked=YES;break;}[seen addObject:cursor];NSDictionary *parent=members[cursor];cursor=parent?viewNumber(parent[@"parent"]):nil;}
        if(linked)[children addObject:member];
    }
    return children;
}
// The logical controller deliberately emits no root placement outside an
// output. A native descendant may extend into that output, so create only an
// adapter presentation site from the exact world projection and observed
// root-relative child geometry. No controller state is changed or inferred.
static NSArray<NSDictionary *> *viewFamilyPlacements(NSDictionary *snapshot,NSDictionary<NSNumber *,NSDictionary *> *outputs,NSDictionary<NSNumber *,NSDictionary *> *bindings,NSDictionary<NSNumber *,NSDictionary *> *families) {
    NSMutableArray<NSDictionary *> *placements=[NSMutableArray array];NSMutableSet<NSString *> *sites=[NSMutableSet set];
    NSMutableDictionary<NSNumber *,NSNumber *> *outputRanks=[NSMutableDictionary dictionary],*windowRanks=[NSMutableDictionary dictionary];
    for(id value in viewList(snapshot[@"placements"])){NSDictionary *placement=viewDictionary(value);if(!placement)continue;[placements addObject:placement];NSNumber *window=viewNumber(placement[@"window"]),*output=viewNumber(placement[@"output"]);if(window&&output)[sites addObject:[NSString stringWithFormat:@"%@/%@",window,output]];}
    NSUInteger originalCount=placements.count;if(!families.count)return placements.copy;
    NSMutableSet<NSNumber *> *fullscreenRoots=[NSMutableSet set];NSUInteger rank=0;
    for(id value in viewList(snapshot[@"outputs"])){NSDictionary *output=viewDictionary(value);NSNumber *identifier=viewNumber(output[@"id"]);if(identifier&&outputs[identifier]==output){outputRanks[identifier]=@(rank++);NSNumber *full=viewNumber(viewDictionary(output[@"fullscreen"])[@"window"]);if(full)[fullscreenRoots addObject:full];}}
    rank=0;for(id value in viewList(snapshot[@"windows"])){NSDictionary *window=viewDictionary(value);NSNumber *identifier=viewNumber(window[@"window"]);if(!viewPositiveID(identifier)||windowRanks[identifier])continue;windowRanks[identifier]=@(rank++);
        NSDictionary *source=viewDictionary(window[@"source"]),*binding=bindings[identifier],*family=viewDictionary(families[identifier]);
        if(!source||!binding||![viewIdentity(source[@"identity"])isEqual:binding]||![viewText(window[@"kind"])isEqual:@"window"]||[viewText(window[@"mode"])isEqual:@"fullscreen"]||[fullscreenRoots containsObject:identifier])continue;
        NSArray<NSDictionary *> *members=viewFamilyMembers(family,source,binding);if(!members.count)continue;
        CGRect native=viewRect(family[@"native_bounds"]),world=viewRect(window[@"world_rect"]);NSDictionary *pin=viewDictionary(window[@"pinned"]);
        if(!pin&&CGRectIsNull(world))continue;
        for(NSNumber *outputID in outputs){NSDictionary *output=outputs[outputID];if(viewDictionary(output[@"fullscreen"]))continue;
            NSString *site=[NSString stringWithFormat:@"%@/%@",identifier,outputID];if([sites containsObject:site])continue;
            CGRect bounds=viewRect(output[@"screen_bounds"]),screen;double zoom=[viewNumber(output[@"zoom"])doubleValue];
            if(pin){if(![pin[@"output"]isEqual:outputID])continue;screen=viewRect(pin[@"screen_rect"]);}
            else {NSDictionary *camera=viewDictionary(output[@"camera"]);screen=CGRectMake(bounds.origin.x+(world.origin.x-[viewNumber(camera[@"x"])doubleValue])*zoom,bounds.origin.y+(world.origin.y-[viewNumber(camera[@"y"])doubleValue])*zoom,world.size.width*zoom,world.size.height*zoom);}
            if(CGRectIsNull(screen)||!isfinite(screen.origin.x)||!isfinite(screen.origin.y)||!isfinite(screen.size.width)||!isfinite(screen.size.height)||!isfinite(CGRectGetMaxX(screen))||!isfinite(CGRectGetMaxY(screen))||screen.size.width<=0||screen.size.height<=0)continue;
            CGRect rootVisible=CGRectIntersection(screen,bounds);if(!CGRectIsNull(rootVisible)&&!CGRectIsEmpty(rootVisible))continue;
            CGRect visible=CGRectNull;
            for(NSDictionary *member in members){CGRect child=viewRect(member[@"native_bounds"]);CGRect projected=CGRectMake(screen.origin.x+(child.origin.x-native.origin.x)/native.size.width*screen.size.width,screen.origin.y+(child.origin.y-native.origin.y)/native.size.height*screen.size.height,child.size.width/native.size.width*screen.size.width,child.size.height/native.size.height*screen.size.height);
                if(!isfinite(projected.origin.x)||!isfinite(projected.origin.y)||!isfinite(projected.size.width)||!isfinite(projected.size.height)||!isfinite(CGRectGetMaxX(projected))||!isfinite(CGRectGetMaxY(projected)))continue;
                CGRect clipped=CGRectIntersection(projected,bounds);if(CGRectIsNull(clipped)||CGRectIsEmpty(clipped))continue;visible=CGRectIsNull(visible)?clipped:CGRectUnion(visible,clipped);
            }
            if(CGRectIsNull(visible))continue;
            NSMutableDictionary *placement=[window mutableCopy];placement[@"output"]=outputID;placement[@"pinned"]=@(pin!=nil);placement[@"screen_rect"]=viewRectJSON(screen);placement[@"clip_rect"]=viewRectJSON(visible);placement[@"world_local_crop"]=NSNull.null;placement[@"buffer_crop"]=NSNull.null;placement[@"family_only"]=@YES;
            placement[@"presentation_settled"]=@([viewNumber(source[@"observation_known"])boolValue]);
            [placements addObject:placement.copy];[sites addObject:site];
        }
    }
    if(placements.count==originalCount)return placements.copy;
    // Same controller layering: output, widget/canvas/pin bucket, then the
    // authoritative bottom-to-top window list. Stable ties retain first site.
    NSMutableArray<NSDictionary *> *ordered=[NSMutableArray array];rank=0;for(NSDictionary *placement in placements)[ordered addObject:@{@"placement":placement,@"index":@(rank++)}];
    [ordered sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSDictionary *pa=a[@"placement"],*pb=b[@"placement"];NSNumber *outputA=viewNumber(pa[@"output"]),*outputB=viewNumber(pb[@"output"]),*windowA=viewNumber(pa[@"window"]),*windowB=viewNumber(pb[@"window"]);NSNumber *oa=(outputA?outputRanks[outputA]:nil)?:@(NSUIntegerMax),*ob=(outputB?outputRanks[outputB]:nil)?:@(NSUIntegerMax);NSComparisonResult compared=[oa compare:ob];if(compared!=NSOrderedSame)return compared;
        NSUInteger ba=viewBucket(pa),bb=viewBucket(pb);if(ba!=bb)return ba<bb?NSOrderedAscending:NSOrderedDescending;
        NSNumber *wa=(windowA?windowRanks[windowA]:nil)?:@(NSUIntegerMax),*wb=(windowB?windowRanks[windowB]:nil)?:@(NSUIntegerMax);compared=[wa compare:wb];return compared!=NSOrderedSame?compared:[a[@"index"]compare:b[@"index"]];
    }];
    [placements removeAllObjects];for(NSDictionary *entry in ordered)[placements addObject:entry[@"placement"]];return placements.copy;
}

NSDictionary *DWNativeFamilyPresentationSnapshot(NSDictionary *snapshot,NSDictionary<NSNumber *,NSDictionary *> *bound,NSDictionary<NSNumber *,NSDictionary *> *families) {
    snapshot=viewDictionary(snapshot);if(!snapshot)return nil;
    NSArray<NSDictionary *> *placements=viewFamilyPlacements(snapshot,viewOutputs(snapshot),viewBindings(bound),viewDictionary(families)?:@{});
    NSMutableDictionary *presentation=[snapshot mutableCopy];presentation[@"placements"]=placements;return presentation.copy;
}

@implementation DWNativeViews {
    NSDictionary<NSNumber *,NSNumber *> *_owners;
    NSDictionary<NSNumber *,NSDictionary *> *_identities;
    NSDictionary<NSNumber *,NSSet<NSNumber *> *> *_replicas;
    NSDictionary<NSNumber *,NSDictionary<NSNumber *,NSDictionary *> *> *_placements;
    NSDictionary *_presentationSnapshot;
}
- (void)reset { _owners=@{};_identities=@{};_replicas=@{};_placements=@{};_presentationSnapshot=nil; }
- (NSDictionary *)presentationSnapshot { return _presentationSnapshot; }
- (NSSet<NSNumber *> *)capturedWindows { return [NSSet setWithArray:_replicas.allKeys?:@[]]; }
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output { return window&&output&&[_replicas[window]containsObject:output]; }
- (NSDictionary *)placement:(NSNumber *)window output:(NSNumber *)output { return window&&output?_placements[window][output]:nil; }
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    return [self describe:snapshot bound:identities families:@{}];
}
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities families:(NSDictionary<NSNumber *,NSDictionary *> *)families {
    if(!viewDictionary(snapshot))return nil;
    NSDictionary<NSNumber *,NSDictionary *> *outputs=viewOutputs(snapshot),*bindings=viewBindings(identities);
    NSArray<NSDictionary *> *presented=viewFamilyPlacements(snapshot,outputs,bindings,viewDictionary(families)?:@{});NSMutableDictionary *presentation=[snapshot mutableCopy];presentation[@"placements"]=presented;_presentationSnapshot=presentation.copy;
    NSMutableDictionary *choices=[NSMutableDictionary dictionary],*areas=[NSMutableDictionary dictionary],*copies=[NSMutableDictionary dictionary],*placements=[NSMutableDictionary dictionary];
    for(NSDictionary *placement in presented){
        NSNumber *window=viewNumber(placement[@"window"]),*output=viewNumber(placement[@"output"]);if(!viewPositiveID(window)||!viewPositiveID(output))continue;
        NSDictionary *viewport=outputs[output],*source=viewDictionary(placement[@"source"]);
        NSString *kind=viewText(placement[@"kind"]);NSDictionary *identity=viewIdentity(source[@"identity"]);
        if(!viewPositiveID(window)||!viewport||!bindings[window]||![identity isEqual:bindings[window]]||(kind&&![kind isEqual:@"window"]))continue;
        NSDictionary *fullscreen=viewDictionary(viewport[@"fullscreen"]);BOOL full=[viewNumber(placement[@"fullscreen"])boolValue];
        if(fullscreen?(!full||![fullscreen[@"window"]isEqual:window]):full)continue;
        CGRect screen=viewRect(placement[@"screen_rect"]),clip=viewRect(placement[@"clip_rect"]);if(CGRectIsNull(screen)||CGRectIsNull(clip))continue;
        // A stale clip from before a resize cannot claim area outside the
        // current output or root projection. Keep the controller's geometry
        // unchanged; this intersection is only the ownership score.
        BOOL familyOnly=[viewNumber(placement[@"family_only"])boolValue];CGRect visible=CGRectIntersection(clip,viewRect(viewport[@"screen_bounds"]));if(!familyOnly)visible=CGRectIntersection(visible,screen);
        double area=visible.size.width*visible.size.height;
        if(!isfinite(area)||area<=0)continue;
        NSMutableDictionary *views=placements[window];if(views[output])continue; // same first-record rule as the canvas
        if(!views)placements[window]=views=[NSMutableDictionary dictionary];views[output]=placement;
        NSMutableSet *outputs=copies[window];if(!outputs)copies[window]=outputs=[NSMutableSet set];[outputs addObject:output];
        if(familyOnly)continue; // observed descendants cannot move or unpark the real root
        // The helper parks these sites. Suppressing their canvas image as a
        // native owner would make the window disappear on every display.
        if(screen.size.width<1||screen.size.height<1)continue;
        // Keep the existing native site while it is visible. Crossing an area
        // tie during a pan must not move the real window to another display.
        NSNumber *owner=[_identities[window]isEqual:bindings[window]]?_owners[window]:nil;
        NSDictionary *chosen=choices[window];BOOL chosenFull=[viewNumber(chosen[@"fullscreen"])boolValue];
        if(chosen){
            if(chosenFull&&!full)continue;
            if(chosenFull==full){
                if([chosen[@"output"]isEqual:owner])continue;
                if(![output isEqual:owner]){double previous=[areas[window]doubleValue];if(area<previous||(area==previous&&[output compare:chosen[@"output"]]!=NSOrderedAscending))continue;}
            }
        }
        choices[window]=placement;areas[window]=@(area);
    }
    NSMutableDictionary *owners=[NSMutableDictionary dictionary],*replicas=[NSMutableDictionary dictionary];
    NSMutableArray *native=[NSMutableArray array];NSMutableSet *emitted=[NSMutableSet set];
    // Preserve the controller's order. The helper sorts its records separately.
    for(NSDictionary *placement in presented){NSNumber *window=viewNumber(placement[@"window"]);
        if(!window||choices[window]!=placement||[emitted containsObject:window])continue;
        NSNumber *owner=placement[@"output"];owners[window]=owner;[native addObject:placement];[emitted addObject:window];
    }
    for(NSNumber *window in copies){NSMutableSet *views=copies[window];NSNumber *owner=owners[window];if(owner)[views removeObject:owner];if(views.count)replicas[window]=views.copy;}
    _owners=owners.copy;_identities=bindings.copy;_replicas=replicas.copy;_placements=placements.copy;
    NSMutableDictionary *result=[snapshot mutableCopy];result[@"placements"]=native.copy;return result;
}
@end
