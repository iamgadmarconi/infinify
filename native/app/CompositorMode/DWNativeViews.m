// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWNativeViews.h"
#import "DWScene.h"
#import "DWTypedValue.h"
#import "DWNativePresenter.h"
#import "DWGeometryJSON.h"
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

static NSArray *viewList(id value) { return [value isKindOfClass:NSArray.class]?value:@[]; }
static BOOL viewPositiveID(NSNumber *number) { return number&&isfinite(number.doubleValue)&&number.doubleValue>0&&floor(number.doubleValue)==number.doubleValue&&number.unsignedLongLongValue>0; }
static CGRect viewRect(id value) {
    NSDictionary *rect=DWTyped(value,NSDictionary.class),*origin=DWTyped(rect[@"origin"],NSDictionary.class),*size=DWTyped(rect[@"size"],NSDictionary.class);
    NSNumber *x=DWTyped(origin[@"x"],NSNumber.class),*y=DWTyped(origin[@"y"],NSNumber.class),*w=DWTyped(size[@"width"],NSNumber.class),*h=DWTyped(size[@"height"],NSNumber.class);
    if(!x||!y||!w||!h||!isfinite(x.doubleValue)||!isfinite(y.doubleValue)||!isfinite(w.doubleValue)||!isfinite(h.doubleValue)||w.doubleValue<=0||h.doubleValue<=0)return CGRectNull;
    CGRect result=CGRectMake(x.doubleValue,y.doubleValue,w.doubleValue,h.doubleValue);return isfinite(CGRectGetMaxX(result))&&isfinite(CGRectGetMaxY(result))?result:CGRectNull;
}
// The controller serializes an optional owner as null; the bound source need
// not carry it. Compare the full process instance and window number directly,
// rather than letting irrelevant representation differences change ownership.
static NSDictionary *viewIdentityFields(NSNumber *pid,NSNumber *seconds,NSNumber *micros,NSNumber *wid) {
    if(!viewPositiveID(pid)||!viewPositiveID(seconds)||!micros||!isfinite(micros.doubleValue)||floor(micros.doubleValue)!=micros.doubleValue||!viewPositiveID(wid)||pid.longLongValue>INT32_MAX||seconds.longLongValue<=0||micros.longLongValue<0||micros.longLongValue>=1000000||wid.unsignedLongLongValue>UINT32_MAX)return nil;
    return @{@"pid":pid,@"birth_sec":seconds,@"birth_usec":micros,@"wid":wid};
}
static NSDictionary *viewIdentity(id value) {
    NSDictionary *identity=DWTyped(value,NSDictionary.class);
    return viewIdentityFields(DWTyped(identity[@"pid"],NSNumber.class),DWTyped(identity[@"birth_sec"],NSNumber.class),DWTyped(identity[@"birth_usec"],NSNumber.class),DWTyped(identity[@"wid"],NSNumber.class));
}
// Native bindings deliberately exclude optional controller owner metadata.
static NSDictionary *viewControllerIdentity(DWIdentity *identity) {
    return viewIdentityFields(identity.pid,identity.birthSeconds,identity.birthMicroseconds,identity.wid);
}
static CGRect viewPositiveRect(CGRect r) {
    return !CGRectIsNull(r)&&isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)
        &&r.size.width>0&&r.size.height>0&&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r))?r:CGRectNull;
}
static NSDictionary<NSNumber *,DWOutput *> *viewOutputs(DWScene *snapshot) {
    NSMutableDictionary<NSNumber *,DWOutput *> *outputs=[NSMutableDictionary dictionary];
    for(id value in snapshot.outputs){DWOutput *output=DWTyped(value,DWOutput.class);NSNumber *identifier=output.identifier,*zoom=output.zoom;
        if(!viewPositiveID(identifier)||CGRectIsNull(viewPositiveRect(output?output.screenBoundsOrNull:CGRectNull))||!zoom||!isfinite(zoom.doubleValue)||zoom.doubleValue<=0||!output.cameraHasNumericComponents||!isfinite(output.camera.x)||!isfinite(output.camera.y))continue;
        if(!outputs[identifier])outputs[identifier]=output;
    }
    return outputs.copy;
}
static NSDictionary<NSNumber *,NSDictionary *> *viewBindings(NSDictionary *identities) {
    identities=DWTyped(identities,NSDictionary.class);NSMutableDictionary<NSNumber *,NSDictionary *> *bindings=[NSMutableDictionary dictionary];
    for(id window in identities){NSDictionary *identity=viewIdentity(identities[window]);if(viewPositiveID(DWTyped(window,NSNumber.class))&&identity)bindings[window]=identity;}
    return bindings.copy;
}
// Presenter receipts serialize their frozen native basis as [x,y,w,h].
static CGRect viewReceiptRect(id value) {
    if(![value isKindOfClass:NSArray.class]||[value count]!=4)return CGRectNull;
    for(id component in value)if(!DWTyped(component,NSNumber.class)||!isfinite([component doubleValue]))return CGRectNull;
    CGRect result=CGRectMake([value[0]doubleValue],[value[1]doubleValue],[value[2]doubleValue],[value[3]doubleValue]);
    return result.size.width>0&&result.size.height>0&&isfinite(CGRectGetMaxX(result))&&isfinite(CGRectGetMaxY(result))?result:CGRectNull;
}
static BOOL viewSameProcess(NSDictionary *a,NSDictionary *b) {
    return a&&b&&[a[@"pid"]isEqual:b[@"pid"]]&&[a[@"birth_sec"]isEqual:b[@"birth_sec"]]&&[a[@"birth_usec"]isEqual:b[@"birth_usec"]];
}
static NSUInteger viewBucket(DWPlacement *placement) {
    return placement.pinned.boolValue?2:placement.widget.boolValue?0:1;
}
// Resolve only observed descendants, not an enclosing box guessed from pixels.
// The audited provider proves parentage; these checks keep stale/malformed
// geometry from requesting a placement after a root's binding has changed.
static NSArray<NSDictionary *> *viewFamilyMembers(NSDictionary *family,DWSource *source,NSDictionary *binding) {
    NSDictionary *identity=viewIdentity(family[@"identity"]);NSNumber *generation=DWTyped(family[@"generation"],NSNumber.class);
    CGRect root=viewRect(family[@"native_bounds"]),observed=viewPositiveRect(source?source.observedRectOrNull:CGRectNull);
    if(!identity||![identity isEqual:binding]||!viewPositiveID(generation)||![generation isEqual:source.generation]||!source.observationKnown.boolValue||CGRectIsNull(root)||CGRectIsNull(observed)||!CGRectEqualToRect(root,observed))return @[];
    NSNumber *rootID=identity[@"wid"];NSMutableDictionary<NSNumber *,NSDictionary *> *members=[NSMutableDictionary dictionary];
    for(id value in viewList(family[@"members"])){NSDictionary *member=DWTyped(value,NSDictionary.class),*who=viewIdentity(member[@"identity"]);NSNumber *parent=DWTyped(member[@"parent"],NSNumber.class);
        if(!viewSameProcess(who,identity)||CGRectIsNull(viewRect(member[@"native_bounds"]))||!parent||!isfinite(parent.doubleValue)||floor(parent.doubleValue)!=parent.doubleValue||parent.longLongValue<0||parent.unsignedLongLongValue>UINT32_MAX)continue;
        NSNumber *wid=who[@"wid"];if(members[wid])continue;
        if([wid isEqual:rootID]){if(parent.unsignedIntValue||!CGRectEqualToRect(viewRect(member[@"native_bounds"]),root))return @[];continue;}
        members[wid]=member;
    }
    NSMutableArray<NSDictionary *> *children=[NSMutableArray array];
    for(NSDictionary *member in members.allValues){NSNumber *cursor=viewIdentity(member[@"identity"])[@"wid"];NSMutableSet<NSNumber *> *seen=[NSMutableSet set];BOOL linked=NO;
        while(cursor&&![seen containsObject:cursor]){if([cursor isEqual:rootID]){linked=YES;break;}[seen addObject:cursor];NSDictionary *parent=members[cursor];cursor=parent?DWTyped(parent[@"parent"],NSNumber.class):nil;}
        if(linked)[children addObject:member];
    }
    return children;
}
// True only when family.members is a well-formed list whose entries all carry the root's numeric wid, so viewFamilyMembers cannot return a child.
// Malformed or non-dictionary entries answer NO (uncertain) so the existing path decides. An empty list is root-only: no child can be linked.
static BOOL viewRootOnlyFamily(NSDictionary *family) {
    NSNumber *root=DWTyped(DWTyped(family[@"identity"],NSDictionary.class)[@"wid"],NSNumber.class);NSArray *members=DWTyped(family[@"members"],NSArray.class);
    if(!root||!members)return NO;
    for(id value in members){NSNumber *wid=DWTyped(DWTyped(DWTyped(value,NSDictionary.class)[@"identity"],NSDictionary.class)[@"wid"],NSNumber.class);if(!wid||![wid isEqual:root])return NO;}
    return YES;
}
// The logical controller deliberately emits no root placement outside an
// output. A native descendant may extend into that output, so create only an
// adapter presentation site from the exact world projection and observed
// root-relative child geometry. No controller state is changed or inferred.
static NSArray<DWPlacement *> *viewFamilyPlacements(DWScene *snapshot,NSDictionary<NSNumber *,DWOutput *> *outputs,NSDictionary<NSNumber *,NSDictionary *> *bindings,NSDictionary<NSNumber *,NSDictionary *> *families) {
    NSMutableArray<DWPlacement *> *placements=[NSMutableArray array];NSMutableSet<NSString *> *sites=[NSMutableSet set];
    NSMutableDictionary<NSNumber *,NSNumber *> *outputRanks=[NSMutableDictionary dictionary],*windowRanks=[NSMutableDictionary dictionary];
    for(id value in snapshot.placements){DWPlacement *placement=DWTyped(value,DWPlacement.class);if(!placement)continue;[placements addObject:placement];NSNumber *window=placement.window,*output=placement.output;if(window&&output)[sites addObject:[NSString stringWithFormat:@"%@/%@",window,output]];}
    NSUInteger originalCount=placements.count;if(!families.count)return placements.copy;
    NSMutableSet<NSNumber *> *fullscreenRoots=[NSMutableSet set];NSUInteger rank=0;
    for(id value in snapshot.outputs){DWOutput *output=DWTyped(value,DWOutput.class);NSNumber *identifier=output.identifier;if(identifier&&outputs[identifier]==output){outputRanks[identifier]=@(rank++);NSNumber *full=output.fullscreen.window;if(full)[fullscreenRoots addObject:full];}}
    rank=0;for(id value in snapshot.windows){DWWindow *window=DWTyped(value,DWWindow.class);NSNumber *identifier=window.window;if(!viewPositiveID(identifier)||windowRanks[identifier])continue;windowRanks[identifier]=@(rank++);
        // Necessary condition for any descendant placement: some member other than the root. Anything unexpected falls through to the full path.
        if(viewRootOnlyFamily(DWTyped(families[identifier],NSDictionary.class)))continue;
        DWSource *source=window.source;NSDictionary *binding=bindings[identifier],*family=DWTyped(families[identifier],NSDictionary.class);
        if(!source||!binding||![viewControllerIdentity(source.identity)isEqual:binding]||![window.kind isEqual:@"window"]||[window.mode isEqual:@"fullscreen"]||[fullscreenRoots containsObject:identifier])continue;
        CGRect native=viewRect(family[@"native_bounds"]),world=viewPositiveRect(window.worldRectOrNull);DWPin *pin=window.pinned;
        if(!pin&&CGRectIsNull(world))continue;
        // Cheap per-output checks first: a root already represented (or visible) on every output needs no family expansion.
        NSMutableArray<NSDictionary *> *candidates=[NSMutableArray array];
        for(NSNumber *outputID in outputs){DWOutput *output=outputs[outputID];if(output.fullscreen)continue;
            NSString *site=[NSString stringWithFormat:@"%@/%@",identifier,outputID];if([sites containsObject:site])continue;
            CGRect bounds=viewPositiveRect(output.screenBoundsOrNull),screen;double zoom=output.zoom.doubleValue;
            if(pin){if(![pin.output isEqual:outputID])continue;screen=viewPositiveRect(pin.screenRectOrNull);}
            else {CGPoint camera=output.camera;screen=CGRectMake(bounds.origin.x+(world.origin.x-camera.x)*zoom,bounds.origin.y+(world.origin.y-camera.y)*zoom,world.size.width*zoom,world.size.height*zoom);}
            if(CGRectIsNull(screen)||!isfinite(screen.origin.x)||!isfinite(screen.origin.y)||!isfinite(screen.size.width)||!isfinite(screen.size.height)||!isfinite(CGRectGetMaxX(screen))||!isfinite(CGRectGetMaxY(screen))||screen.size.width<=0||screen.size.height<=0)continue;
            CGRect rootVisible=CGRectIntersection(screen,bounds);if(!CGRectIsNull(rootVisible)&&!CGRectIsEmpty(rootVisible))continue;
            [candidates addObject:@{@"output":outputID,@"site":site,@"bounds":[NSValue valueWithRect:bounds],@"screen":[NSValue valueWithRect:screen]}];
        }
        if(!candidates.count)continue;
        NSArray<NSDictionary *> *members=viewFamilyMembers(family,source,binding);if(!members.count)continue;
        for(NSDictionary *candidate in candidates){NSNumber *outputID=candidate[@"output"];NSString *site=candidate[@"site"];CGRect bounds=[candidate[@"bounds"]rectValue],screen=[candidate[@"screen"]rectValue];
            CGRect visible=CGRectNull;
            for(NSDictionary *member in members){CGRect child=viewRect(member[@"native_bounds"]);CGRect projected=CGRectMake(screen.origin.x+(child.origin.x-native.origin.x)/native.size.width*screen.size.width,screen.origin.y+(child.origin.y-native.origin.y)/native.size.height*screen.size.height,child.size.width/native.size.width*screen.size.width,child.size.height/native.size.height*screen.size.height);
                if(!isfinite(projected.origin.x)||!isfinite(projected.origin.y)||!isfinite(projected.size.width)||!isfinite(projected.size.height)||!isfinite(CGRectGetMaxX(projected))||!isfinite(CGRectGetMaxY(projected)))continue;
                CGRect clipped=CGRectIntersection(projected,bounds);if(CGRectIsNull(clipped)||CGRectIsEmpty(clipped))continue;visible=CGRectIsNull(visible)?clipped:CGRectUnion(visible,clipped);
            }
            if(CGRectIsNull(visible))continue;
            DWPlacement *placement=[window placementOnOutput:outputID screenRect:screen clipRect:visible pinned:pin!=nil familyOnly:YES];
            [placements addObject:placement];[sites addObject:site];
        }
    }
    if(placements.count==originalCount)return placements.copy;
    // Same controller layering: output, widget/canvas/pin bucket, then the
    // authoritative bottom-to-top window list. Stable ties retain first site.
    NSMutableArray<NSDictionary *> *ordered=[NSMutableArray array];rank=0;for(DWPlacement *placement in placements)[ordered addObject:@{@"placement":placement,@"index":@(rank++)}];
    [ordered sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){DWPlacement *pa=a[@"placement"],*pb=b[@"placement"];NSNumber *outputA=pa.output,*outputB=pb.output,*windowA=pa.window,*windowB=pb.window;NSNumber *oa=(outputA?outputRanks[outputA]:nil)?:@(NSUIntegerMax),*ob=(outputB?outputRanks[outputB]:nil)?:@(NSUIntegerMax);NSComparisonResult compared=[oa compare:ob];if(compared!=NSOrderedSame)return compared;
        NSUInteger ba=viewBucket(pa),bb=viewBucket(pb);if(ba!=bb)return ba<bb?NSOrderedAscending:NSOrderedDescending;
        NSNumber *wa=(windowA?windowRanks[windowA]:nil)?:@(NSUIntegerMax),*wb=(windowB?windowRanks[windowB]:nil)?:@(NSUIntegerMax);compared=[wa compare:wb];return compared!=NSOrderedSame?compared:[a[@"index"]compare:b[@"index"]];
    }];
    [placements removeAllObjects];for(NSDictionary *entry in ordered)[placements addObject:entry[@"placement"]];return placements.copy;
}

DWScene *DWNativeFamilyPresentationSnapshot(DWScene *snapshot,NSDictionary<NSNumber *,NSDictionary *> *bound,NSDictionary<NSNumber *,NSDictionary *> *families) {
    snapshot=DWTyped(snapshot,DWScene.class);if(!snapshot)return nil;
    NSArray<DWPlacement *> *placements=viewFamilyPlacements(snapshot,viewOutputs(snapshot),viewBindings(bound),DWTyped(families,NSDictionary.class)?:@{});
    return [snapshot sceneWithPlacements:placements];
}

// Transfer admission is stricter than ordinary presentation. It must name a
// complete audited family and every projected member must fit this display;
// a partial clip cannot be made safe by a placement ACK.
BOOL DWNativeViewsHoverImpossible(BOOL planCurrent,BOOL heldTransfer,NSUInteger replicaSites) { return planCurrent&&!heldTransfer&&!replicaSites; }
static NSDictionary *viewTransferSite(NSNumber *window,NSNumber *output,DWPlacement *placement,DWOutput *viewport,NSDictionary *binding,NSDictionary *family) {
    DWSource *source=placement.source;DWIdentity *rawIdentity=source.identity;
    NSNumber *generation=source.generation;CGRect screen=viewPositiveRect(placement?placement.screenRectOrNull:CGRectNull),clip=viewPositiveRect(placement?placement.clipRectOrNull:CGRectNull),display=viewPositiveRect(viewport?viewport.screenBoundsOrNull:CGRectNull),native=viewRect(family[@"native_bounds"]);
    if(!family||!binding||![viewControllerIdentity(rawIdentity)isEqual:binding]||![viewIdentity(family[@"identity"])isEqual:binding]
        ||![family[@"generation"]isEqual:generation]||!CGRectEqualToRect(native,viewPositiveRect(source?source.observedRectOrNull:CGRectNull))||(rawIdentity.ownerPresence!=DWValueAbsent&&rawIdentity.ownerPresence!=DWValueNull)
        ||!viewPositiveID(generation)||CFGetTypeID((__bridge CFTypeRef)generation)==CFBooleanGetTypeID()||![source.observationKnown isEqual:@YES]
        ||placement.familyOnly.boolValue||CGRectIsNull(screen)||CGRectIsNull(clip)||CGRectIsNull(display)||CGRectIsNull(native)
        ||screen.size.width<1||screen.size.height<1||!CGRectEqualToRect(screen,clip)||!CGRectContainsRect(display,screen))return nil;
    NSArray *children=viewFamilyMembers(family,source,binding),*reported=viewList(family[@"members"]);
    if(reported.count!=children.count+1)return nil;
    NSMutableArray *members=[NSMutableArray array];BOOL rootSeen=NO;
    for(id value in reported){NSDictionary *member=DWTyped(value,NSDictionary.class),*who=viewIdentity(member[@"identity"]);NSNumber *parent=DWTyped(member[@"parent"],NSNumber.class);CGRect bounds=viewRect(member[@"native_bounds"]);
        if(!who||!viewSameProcess(who,binding)||!parent||CFGetTypeID((__bridge CFTypeRef)parent)==CFBooleanGetTypeID()
            ||!isfinite(parent.doubleValue)||floor(parent.doubleValue)!=parent.doubleValue||parent.doubleValue<0||parent.unsignedLongLongValue>UINT32_MAX||CGRectIsNull(bounds))return nil;
        if([who[@"wid"]isEqual:binding[@"wid"]]){if(rootSeen||parent.unsignedIntValue||!CGRectEqualToRect(bounds,native))return nil;rootSeen=YES;}
        CGRect projected=CGRectMake(screen.origin.x+(bounds.origin.x-native.origin.x)/native.size.width*screen.size.width,
            screen.origin.y+(bounds.origin.y-native.origin.y)/native.size.height*screen.size.height,
            bounds.size.width/native.size.width*screen.size.width,bounds.size.height/native.size.height*screen.size.height);
        if(!isfinite(projected.origin.x)||!isfinite(projected.origin.y)||!isfinite(projected.size.width)||!isfinite(projected.size.height)
            ||projected.size.width<1||projected.size.height<1||!CGRectContainsRect(display,projected))return nil;
        [members addObject:@{@"identity":who,@"native_bounds":DWRectJSON(bounds),@"parent":parent}];
    }
    if(!rootSeen)return nil;
    [members sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"identity"][@"wid"]compare:b[@"identity"][@"wid"]];}];
    return @{@"window":window,@"output":output,@"identity":binding,@"generation":generation,@"screen_rect":DWRectJSON(screen),@"clip_rect":DWRectJSON(clip),@"viewport":DWRectJSON(display),@"members":members.copy};
}
@interface DWNativeViewTransfer ()
@property(nonatomic,readonly) NSDictionary *site;
- (instancetype)initWithSite:(NSDictionary *)site;
@end
@implementation DWNativeViewTransfer {
    NSUUID *_requestID;
    NSDictionary *_site;
}
- (instancetype)initWithSite:(NSDictionary *)site { if((self=[super init])){_requestID=[NSUUID UUID];_site=[site copy];}return self; }
- (NSUUID *)requestID { return _requestID; }
- (NSDictionary *)site { return _site; }
- (uint64_t)window { return [_site[@"window"]unsignedLongLongValue]; }
- (uint64_t)generation { return [_site[@"generation"]unsignedLongLongValue]; }
- (uint64_t)output { return [_site[@"output"]unsignedLongLongValue]; }
- (NSDictionary *)identity { return _site[@"identity"]; }
- (CGRect)screenRect { return viewRect(_site[@"screen_rect"]); }
- (CGRect)clipRect { return viewRect(_site[@"clip_rect"]); }
- (CGRect)viewport { return viewRect(_site[@"viewport"]); }
- (NSArray<NSDictionary *> *)members { return _site[@"members"]; }
@end
@interface DWNativeViewAdmission : NSObject
@property DWNativeAppliedPlacement *placement;
@property(copy) DWNativeViewPlacementCheck current;
@end
@implementation DWNativeViewAdmission
@end

@implementation DWNativeViews {
    NSDictionary<NSNumber *,NSNumber *> *_owners;
    NSDictionary<NSNumber *,NSDictionary *> *_identities;
    NSDictionary<NSNumber *,NSSet<NSNumber *> *> *_replicas;
    NSDictionary<NSNumber *,NSDictionary<NSNumber *,DWPlacement *> *> *_placements;
    DWScene *_presentationSnapshot;
    NSDictionary<NSNumber *,NSDictionary<NSNumber *,NSDictionary *> *> *_transferSites;
    NSMutableDictionary<NSNumber *,DWNativeViewTransfer *> *_transfers;
    NSMutableDictionary<NSNumber *,DWNativeViewAdmission *> *_admissions;
    NSMutableSet<NSNumber *> *_covered;
    uint64_t _transferRevision,_placementRequestRevision;
}
- (instancetype)init { if((self=[super init]))[self reset];return self; }
- (void)reset { _owners=@{};_identities=@{};_replicas=@{};_placements=@{};_presentationSnapshot=nil;_transferSites=@{};_transfers=[NSMutableDictionary dictionary];_admissions=[NSMutableDictionary dictionary];_covered=[NSMutableSet set];++_transferRevision;++_placementRequestRevision; }
- (DWScene *)presentationSnapshot { return _presentationSnapshot; }
- (NSSet<NSNumber *> *)capturedWindows { return [NSSet setWithArray:_replicas.allKeys?:@[]]; }
- (NSUInteger)replicaSiteCount { NSUInteger count=0;for(NSSet *outputs in _replicas.allValues)count+=outputs.count;return count; }
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output { return window&&output&&[_replicas[window]containsObject:output]; }
- (DWPlacement *)placement:(NSNumber *)window output:(NSNumber *)output { return window&&output?_placements[window][output]:nil; }
- (uint64_t)transferRevision { return _transferRevision; }
- (uint64_t)placementRequestRevision { return _placementRequestRevision; }
- (NSArray<DWNativeViewTransfer *> *)pendingTransfers {
    NSMutableArray *pending=[NSMutableArray array];for(NSNumber *window in [_covered.allObjects sortedArrayUsingSelector:@selector(compare:)])if(_transfers[window])[pending addObject:_transfers[window]];return pending.copy;
}
- (void)refreshReplicas {
    NSMutableDictionary *replicas=[NSMutableDictionary dictionary];
    for(NSNumber *window in _placements){NSMutableSet *copies=[NSMutableSet setWithArray:_placements[window].allKeys];
        NSNumber *owner=_owners[window];if(owner&&![_covered containsObject:window])[copies removeObject:owner];if(copies.count)replicas[window]=copies.copy;}
    _replicas=replicas.copy;
}
- (NSNumber *)desiredOwnerForWindow:(NSNumber *)window { if(!window)return nil;DWNativeViewTransfer *transfer=_transfers[window];return transfer?@(transfer.output):_owners[window]; }
- (DWNativeViewTransfer *)currentTransferForWindow:(NSNumber *)window { return window?_transfers[window]:nil; }
- (BOOL)requiresPlacementAdmissionForWindow:(NSNumber *)window {
    return window&&[_covered containsObject:window];
}
- (BOOL)isTransferCurrent:(DWNativeViewTransfer *)transfer {
    if(![transfer isKindOfClass:DWNativeViewTransfer.class])return NO;NSNumber *window=@(transfer.window);
    return _transfers[window]==transfer&&[transfer.site isEqual:_transferSites[window][@(transfer.output)]];
}
- (BOOL)canTransferWindow:(NSNumber *)window output:(NSNumber *)output { return window&&output&&_transferSites[window][output]!=nil; }
- (DWNativeViewTransfer *)requestTransferForWindow:(NSNumber *)window output:(NSNumber *)output {
    if(![self canTransferWindow:window output:output])return nil;NSDictionary *site=_transferSites[window][output];
    DWNativeViewTransfer *transfer=[[DWNativeViewTransfer alloc]initWithSite:site];_transfers[window]=transfer;[_admissions removeObjectForKey:window];[_covered addObject:window];
    ++_transferRevision;++_placementRequestRevision;[self refreshReplicas];return transfer;
}
- (void)recoverWindow:(NSNumber *)window {
    NSDictionary *sites=_transferSites[window];NSNumber *output=_owners[window];if(!output||!sites[output])output=[sites.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject;
    if(output)_transfers[window]=[[DWNativeViewTransfer alloc]initWithSite:sites[output]];
}
- (void)cancelTransfer:(DWNativeViewTransfer *)transfer {
    if(![transfer isKindOfClass:DWNativeViewTransfer.class]||_transfers[@(transfer.window)]!=transfer)return;
    NSNumber *window=@(transfer.window);[_transfers removeObjectForKey:window];[_admissions removeObjectForKey:window];
    if([_covered containsObject:window]){[self recoverWindow:window];++_placementRequestRevision;}++_transferRevision;[self refreshReplicas];
}
- (BOOL)placement:(DWNativeAppliedPlacement *)placement matches:(DWNativeViewTransfer *)transfer {
    if(![placement isKindOfClass:DWNativeAppliedPlacement.class]||placement.window!=transfer.window||placement.generation!=transfer.generation||placement.output!=transfer.output
        ||![placement.identity isEqual:transfer.identity]||!CGRectEqualToRect(placement.requestedScreenRect,transfer.screenRect)
        ||!CGRectEqualToRect(placement.requestedClipRect,transfer.clipRect)||!CGRectEqualToRect(placement.requestedViewport,transfer.viewport))return NO;
    NSArray *members=placement.members;if(members.count!=transfer.members.count)return NO;
    for(NSUInteger i=0;i<members.count;i++){NSDictionary *actual=members[i],*expected=transfer.members[i];
        if(![actual[@"identity"]isEqual:expected[@"identity"]]||![actual[@"parent"]isEqual:expected[@"parent"]]
            ||!CGRectEqualToRect(viewReceiptRect(actual[@"native_bounds"]),viewRect(expected[@"native_bounds"])))return NO;}
    return YES;
}
- (BOOL)completeTransfer:(DWNativeViewTransfer *)transfer placement:(DWNativeAppliedPlacement *)placement current:(DWNativeViewPlacementCheck)current validateGeometry:(DWNativeViewPlacementCheck)validateGeometry {
    if(![self isTransferCurrent:transfer]||![_covered containsObject:@(transfer.window)]||!current||!validateGeometry||![self placement:placement matches:transfer]
        ||!current(placement)||!validateGeometry(placement)||![self isTransferCurrent:transfer]||!current(placement)||![self isTransferCurrent:transfer])return NO;
    NSNumber *window=@(transfer.window);NSMutableDictionary *owners=[_owners mutableCopy];owners[window]=@(transfer.output);_owners=owners.copy;
    DWNativeViewAdmission *admission=[DWNativeViewAdmission new];admission.placement=placement;admission.current=current;_admissions[window]=admission;[_covered removeObject:window];
    ++_transferRevision;[self refreshReplicas];return YES;
}
- (BOOL)isAdmissionCurrentForTransfer:(DWNativeViewTransfer *)transfer placement:(DWNativeAppliedPlacement *)placement {
    if(![self isTransferCurrent:transfer])return NO;DWNativeViewAdmission *admission=_admissions[@(transfer.window)];
    return admission&&admission.placement==placement&&admission.current(placement)&&[self isTransferCurrent:transfer];
}
- (DWNativeAppliedPlacement *)admittedPlacementForWindow:(NSNumber *)window {
    DWNativeViewTransfer *transfer=window?_transfers[window]:nil;DWNativeViewAdmission *admission=window?_admissions[window]:nil;
    return [self isAdmissionCurrentForTransfer:transfer placement:admission.placement]?admission.placement:nil;
}
- (NSNumber *)admittedOwnerForWindow:(NSNumber *)window { DWNativeAppliedPlacement *placement=[self admittedPlacementForWindow:window];return placement?@(placement.output):nil; }
- (DWScene *)describe:(DWScene *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    return [self describe:snapshot bound:identities families:@{}];
}
- (DWScene *)describe:(DWScene *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities families:(NSDictionary<NSNumber *,NSDictionary *> *)families {
    if(!DWTyped(snapshot,DWScene.class)){[self reset];return nil;}
    NSDictionary *auditedFamilies=DWTyped(families,NSDictionary.class)?:@{};
    NSDictionary<NSNumber *,DWOutput *> *outputs=viewOutputs(snapshot);NSDictionary<NSNumber *,NSDictionary *> *bindings=viewBindings(identities);
    NSArray<DWPlacement *> *presented=viewFamilyPlacements(snapshot,outputs,bindings,auditedFamilies);_presentationSnapshot=[snapshot sceneWithPlacements:presented];
    NSMutableDictionary *choices=[NSMutableDictionary dictionary],*areas=[NSMutableDictionary dictionary],*placements=[NSMutableDictionary dictionary];
    for(DWPlacement *placement in presented){
        NSNumber *window=placement.window,*output=placement.output;if(!viewPositiveID(window)||!viewPositiveID(output))continue;
        DWOutput *viewport=outputs[output];DWSource *source=placement.source;
        NSString *kind=placement.kind;NSDictionary *identity=viewControllerIdentity(source.identity);
        if(!viewPositiveID(window)||!viewport||!bindings[window]||![identity isEqual:bindings[window]]||(kind&&![kind isEqual:@"window"]))continue;
        DWFullscreen *fullscreen=viewport.fullscreen;BOOL full=placement.fullscreen.boolValue;
        if(fullscreen?(!full||![fullscreen.window isEqual:window]):full)continue;
        CGRect screen=viewPositiveRect(placement?placement.screenRectOrNull:CGRectNull),clip=viewPositiveRect(placement?placement.clipRectOrNull:CGRectNull);if(CGRectIsNull(screen)||CGRectIsNull(clip))continue;
        // A stale clip from before a resize cannot claim area outside the
        // current output or root projection. Keep the controller's geometry
        // unchanged; this intersection is only the ownership score.
        BOOL familyOnly=placement.familyOnly.boolValue;CGRect visible=CGRectIntersection(clip,viewPositiveRect(viewport?viewport.screenBoundsOrNull:CGRectNull));if(!familyOnly)visible=CGRectIntersection(visible,screen);
        double area=visible.size.width*visible.size.height;
        if(!isfinite(area)||area<=0)continue;
        NSMutableDictionary *views=placements[window];if(views[output])continue; // same first-record rule as the canvas
        if(!views)placements[window]=views=[NSMutableDictionary dictionary];views[output]=placement;
        if(familyOnly)continue; // observed descendants cannot move or unpark the real root
        // The helper parks these sites. Suppressing their canvas image as a
        // native owner would make the window disappear on every display.
        if(screen.size.width<1||screen.size.height<1)continue;
        // Keep the existing native site while it is visible. Crossing an area
        // tie during a pan must not move the real window to another display.
        NSNumber *owner=[_identities[window]isEqual:bindings[window]]?_owners[window]:nil;
        DWPlacement *chosen=choices[window];BOOL chosenFull=chosen.fullscreen.boolValue;
        if(chosen){
            if(chosenFull&&!full)continue;
            if(chosenFull==full){
                if([chosen.output isEqual:owner])continue;
                if(![output isEqual:owner]){double previous=[areas[window]doubleValue];if(area<previous||(area==previous&&[output compare:chosen.output]!=NSOrderedAscending))continue;}
            }
        }
        choices[window]=placement;areas[window]=@(area);
    }
    NSMutableDictionary *owners=[NSMutableDictionary dictionary],*transferSites=[NSMutableDictionary dictionary];
    for(NSNumber *window in placements){NSMutableDictionary *sites=[NSMutableDictionary dictionary];for(NSNumber *output in placements[window]){
        NSDictionary *site=viewTransferSite(window,output,placements[window][output],outputs[output],bindings[window],DWTyped(auditedFamilies[window],NSDictionary.class));if(site)sites[output]=site;}
        if(sites.count)transferSites[window]=sites.copy;}
    _transferSites=transferSites.copy;
    for(NSNumber *window in _transfers.allKeys)if(![self isTransferCurrent:_transfers[window]]){
        [_transfers removeObjectForKey:window];[_admissions removeObjectForKey:window];if([_covered containsObject:window])++_placementRequestRevision;++_transferRevision;}
    // Removal of the binding/site ends only this adapter state. Native release
    // and restore obligations remain the presenter's responsibility.
    for(NSNumber *window in _covered.allObjects)if(!placements[window]||![_identities[window]isEqual:bindings[window]]){[_covered removeObject:window];++_transferRevision;++_placementRequestRevision;}
    for(NSNumber *window in choices)owners[window]=[(DWPlacement *)choices[window] output];
    _owners=owners.copy;_identities=bindings.copy;_placements=placements.copy;
    for(NSNumber *window in _covered)if(!_transfers[window]){[self recoverWindow:window];if(_transfers[window]){++_transferRevision;++_placementRequestRevision;}}
    NSMutableArray *native=[NSMutableArray array];NSMutableSet *emitted=[NSMutableSet set];
    // Preserve the controller's order. The helper sorts its records separately.
    for(DWPlacement *placement in presented){NSNumber *window=placement.window;
        NSNumber *desired=window?[self desiredOwnerForWindow:window]:nil;
        if(!window||!desired||_placements[window][desired]!=placement||[emitted containsObject:window])continue;
        [native addObject:placement];[emitted addObject:window];
    }
    [self refreshReplicas];
    return [snapshot sceneWithPlacements:native.copy];
}
@end
