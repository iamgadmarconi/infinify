// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-views.h"
#import "native-presenter.h"
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
static BOOL viewNativeExtentFits(NSDictionary *placement,NSDictionary *viewport,NSDictionary *binding) {
    NSDictionary *source=viewDictionary(placement[@"source"]),*identity=viewDictionary(source[@"identity"]);
    NSNumber *generation=viewNumber(source[@"generation"]);
    CGRect native=viewRect(source[@"observed_rect"]),display=viewRect(viewport[@"screen_bounds"]);
    return binding&&[viewIdentity(identity)isEqual:binding]&&(!identity[@"owner"]||identity[@"owner"]==NSNull.null)
        &&viewPositiveID(generation)&&CFGetTypeID((__bridge CFTypeRef)generation)!=CFBooleanGetTypeID()
        &&[source[@"observation_known"]isEqual:@YES]&&!CGRectIsNull(native)&&!CGRectIsNull(display)
        &&native.size.width<=display.size.width&&native.size.height<=display.size.height;
}
static NSDictionary *viewRectJSON(CGRect rect) {
    return @{@"origin":@{@"x":@(rect.origin.x),@"y":@(rect.origin.y)},@"size":@{@"width":@(rect.size.width),@"height":@(rect.size.height)}};
}
// Presenter receipts serialize their frozen native basis as [x,y,w,h].
static CGRect viewReceiptRect(id value) {
    if(![value isKindOfClass:NSArray.class]||[value count]!=4)return CGRectNull;
    for(id component in value)if(!viewNumber(component)||!isfinite([component doubleValue]))return CGRectNull;
    CGRect result=CGRectMake([value[0]doubleValue],[value[1]doubleValue],[value[2]doubleValue],[value[3]doubleValue]);
    return result.size.width>0&&result.size.height>0&&isfinite(CGRectGetMaxX(result))&&isfinite(CGRectGetMaxY(result))?result:CGRectNull;
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

// Transfer admission is stricter than ordinary presentation. It must name a
// complete audited family and every projected member must fit this display;
// a partial clip cannot be made safe by a placement ACK.
static NSDictionary *viewTransferSite(NSNumber *window,NSNumber *output,NSDictionary *placement,NSDictionary *viewport,NSDictionary *binding,NSDictionary *family) {
    NSDictionary *source=viewDictionary(placement[@"source"]),*rawIdentity=viewDictionary(source[@"identity"]);
    NSNumber *generation=viewNumber(source[@"generation"]);CGRect screen=viewRect(placement[@"screen_rect"]),clip=viewRect(placement[@"clip_rect"]),display=viewRect(viewport[@"screen_bounds"]),native=viewRect(family[@"native_bounds"]);
    if(!family||!binding||![viewIdentity(rawIdentity)isEqual:binding]||![viewIdentity(family[@"identity"])isEqual:binding]
        ||![family[@"generation"]isEqual:generation]||!CGRectEqualToRect(native,viewRect(source[@"observed_rect"]))||(rawIdentity[@"owner"]&&rawIdentity[@"owner"]!=NSNull.null)
        ||!viewPositiveID(generation)||CFGetTypeID((__bridge CFTypeRef)generation)==CFBooleanGetTypeID()||![source[@"observation_known"]isEqual:@YES]
        ||[viewNumber(placement[@"family_only"])boolValue]||CGRectIsNull(screen)||CGRectIsNull(clip)||CGRectIsNull(display)||CGRectIsNull(native)
        ||screen.size.width<1||screen.size.height<1||!CGRectEqualToRect(screen,clip)||!CGRectContainsRect(display,screen))return nil;
    NSArray *children=viewFamilyMembers(family,source,binding),*reported=viewList(family[@"members"]);
    if(reported.count!=children.count+1)return nil;
    NSMutableArray *members=[NSMutableArray array];BOOL rootSeen=NO;
    for(id value in reported){NSDictionary *member=viewDictionary(value),*who=viewIdentity(member[@"identity"]);NSNumber *parent=viewNumber(member[@"parent"]);CGRect bounds=viewRect(member[@"native_bounds"]);
        if(!who||!viewSameProcess(who,binding)||!parent||CFGetTypeID((__bridge CFTypeRef)parent)==CFBooleanGetTypeID()
            ||!isfinite(parent.doubleValue)||floor(parent.doubleValue)!=parent.doubleValue||parent.doubleValue<0||parent.unsignedLongLongValue>UINT32_MAX||CGRectIsNull(bounds))return nil;
        if([who[@"wid"]isEqual:binding[@"wid"]]){if(rootSeen||parent.unsignedIntValue||!CGRectEqualToRect(bounds,native))return nil;rootSeen=YES;}
        CGRect projected=CGRectMake(screen.origin.x+(bounds.origin.x-native.origin.x)/native.size.width*screen.size.width,
            screen.origin.y+(bounds.origin.y-native.origin.y)/native.size.height*screen.size.height,
            bounds.size.width/native.size.width*screen.size.width,bounds.size.height/native.size.height*screen.size.height);
        if(!isfinite(projected.origin.x)||!isfinite(projected.origin.y)||!isfinite(projected.size.width)||!isfinite(projected.size.height)
            ||projected.size.width<1||projected.size.height<1||!CGRectContainsRect(display,projected))return nil;
        [members addObject:@{@"identity":who,@"native_bounds":viewRectJSON(bounds),@"parent":parent}];
    }
    if(!rootSeen)return nil;
    [members sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"identity"][@"wid"]compare:b[@"identity"][@"wid"]];}];
    return @{@"window":window,@"output":output,@"identity":binding,@"generation":generation,@"screen_rect":viewRectJSON(screen),@"clip_rect":viewRectJSON(clip),@"viewport":viewRectJSON(display),@"members":members.copy};
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
    NSDictionary<NSNumber *,NSDictionary<NSNumber *,NSDictionary *> *> *_placements;
    NSDictionary *_presentationSnapshot;
    NSDictionary<NSNumber *,NSDictionary<NSNumber *,NSDictionary *> *> *_transferSites;
    NSMutableDictionary<NSNumber *,DWNativeViewTransfer *> *_transfers;
    NSMutableDictionary<NSNumber *,DWNativeViewAdmission *> *_admissions;
    NSMutableSet<NSNumber *> *_covered;
    uint64_t _transferRevision,_placementRequestRevision;
    BOOL _requiresNativeExtentFit;
}
- (instancetype)init { if((self=[super init]))[self reset];return self; }
- (BOOL)requiresNativeExtentFit { return _requiresNativeExtentFit; }
- (void)setRequiresNativeExtentFit:(BOOL)required { if(_requiresNativeExtentFit==required)return;_requiresNativeExtentFit=required;[self reset]; }
- (void)reset { _owners=@{};_identities=@{};_replicas=@{};_placements=@{};_presentationSnapshot=nil;_transferSites=@{};_transfers=[NSMutableDictionary dictionary];_admissions=[NSMutableDictionary dictionary];_covered=[NSMutableSet set];++_transferRevision;++_placementRequestRevision; }
- (NSDictionary *)presentationSnapshot { return _presentationSnapshot; }
- (NSSet<NSNumber *> *)capturedWindows { return [NSSet setWithArray:_replicas.allKeys?:@[]]; }
- (BOOL)replica:(NSNumber *)window output:(NSNumber *)output { return window&&output&&[_replicas[window]containsObject:output]; }
- (NSDictionary *)placement:(NSNumber *)window output:(NSNumber *)output { return window&&output?_placements[window][output]:nil; }
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
- (BOOL)completeParkingForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation current:(BOOL (^)(void))current {
    NSDictionary *sites=window?_placements[window]:nil;uint64_t revision=_transferRevision;
    if(!window||!_requiresNativeExtentFit||!current||![_covered containsObject:window]||!sites.count||_owners[window]||_transfers[window]||[_transferSites[window]count]
        ||![viewIdentity(identity)isEqual:_identities[window]]||!viewPositiveID(generation))return NO;
    for(NSDictionary *site in sites.objectEnumerator){NSDictionary *source=viewDictionary(site[@"source"]);
        if(![source[@"generation"]isEqual:generation]||![source[@"observation_known"]isEqual:@YES]||![viewIdentity(source[@"identity"])isEqual:_identities[window]])return NO;}
    if(!current()||revision!=_transferRevision||sites!=_placements[window])return NO;
    [_covered removeObject:window];++_transferRevision;[self refreshReplicas];return YES;
}
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
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities {
    return [self describe:snapshot bound:identities families:@{}];
}
- (NSDictionary *)describe:(NSDictionary *)snapshot bound:(NSDictionary<NSNumber *,NSDictionary *> *)identities families:(NSDictionary<NSNumber *,NSDictionary *> *)families {
    if(!viewDictionary(snapshot)){[self reset];return nil;}
    NSDictionary *auditedFamilies=viewDictionary(families)?:@{};
    NSDictionary<NSNumber *,NSDictionary *> *outputs=viewOutputs(snapshot),*bindings=viewBindings(identities);
    NSArray<NSDictionary *> *presented=viewFamilyPlacements(snapshot,outputs,bindings,auditedFamilies);NSMutableDictionary *presentation=[snapshot mutableCopy];presentation[@"placements"]=presented;_presentationSnapshot=presentation.copy;
    NSMutableDictionary *choices=[NSMutableDictionary dictionary],*areas=[NSMutableDictionary dictionary],*placements=[NSMutableDictionary dictionary];
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
        if(familyOnly)continue; // observed descendants cannot move or unpark the real root
        // The helper parks these sites. Suppressing their canvas image as a
        // native owner would make the window disappear on every display.
        if(screen.size.width<1||screen.size.height<1)continue;
        if(_requiresNativeExtentFit&&!viewNativeExtentFits(placement,viewport,bindings[window]))continue;
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
    NSMutableDictionary *owners=[NSMutableDictionary dictionary],*transferSites=[NSMutableDictionary dictionary];
    for(NSNumber *window in placements){NSMutableDictionary *sites=[NSMutableDictionary dictionary];for(NSNumber *output in placements[window]){
        if(_requiresNativeExtentFit&&!viewNativeExtentFits(placements[window][output],outputs[output],bindings[window]))continue;
        NSDictionary *site=viewTransferSite(window,output,placements[window][output],outputs[output],bindings[window],viewDictionary(auditedFamilies[window]));if(site)sites[output]=site;}
        if(sites.count)transferSites[window]=sites.copy;}
    _transferSites=transferSites.copy;
    for(NSNumber *window in _transfers.allKeys)if(![self isTransferCurrent:_transfers[window]]){
        [_transfers removeObjectForKey:window];[_admissions removeObjectForKey:window];if([_covered containsObject:window])++_placementRequestRevision;++_transferRevision;}
    // Removal of the binding/site ends only this adapter state. Native release
    // and restore obligations remain the presenter's responsibility.
    for(NSNumber *window in _covered.allObjects)if(!placements[window]||![_identities[window]isEqual:bindings[window]]){[_covered removeObject:window];++_transferRevision;++_placementRequestRevision;}
    for(NSNumber *window in choices)owners[window]=choices[window][@"output"];
    _owners=owners.copy;_identities=bindings.copy;_placements=placements.copy;
    for(NSNumber *window in _covered)if(!_transfers[window]){[self recoverWindow:window];if(_transfers[window]){++_transferRevision;++_placementRequestRevision;}}
    NSMutableArray *native=[NSMutableArray array];NSMutableSet *emitted=[NSMutableSet set];
    // Preserve the controller's order. The helper sorts its records separately.
    for(NSDictionary *placement in presented){NSNumber *window=viewNumber(placement[@"window"]);
        NSNumber *desired=window?[self desiredOwnerForWindow:window]:nil;
        if(!window||!desired||_placements[window][desired]!=placement||[emitted containsObject:window])continue;
        [native addObject:placement];[emitted addObject:window];
    }
    [self refreshReplicas];
    NSMutableDictionary *result=[snapshot mutableCopy];result[@"placements"]=native.copy;return result;
}
@end
