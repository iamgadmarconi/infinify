// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWDockPayload.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/app/CompositorMode/DWNativePresenter.m (37b27b1): frame results, placement receipts and their fences.
#import "DWNativePresenter+Private.h"

static const char *statusName(uint8_t status) {
    static const char *names[]={"applied","out of the helper's scope","no such window of that process","matrix refused","alpha refused","its original could not be read","the journal could not be written","the set failed or read back differently","a restore of it is pending","the helper's table is full","malformed record","the window and destination do not have eligible display Spaces","the helper cannot safely read or change the native sublevel"};
    return status<sizeof(names)/sizeof(*names)?names[status]:"unknown status";
}
@implementation DWNativePresenter (Acknowledgement)
// A record the helper did not apply: the window is not where the canvas shows it. Once per window and reason.
- (void)refused:(NSData *)statuses frame:(uint64_t)seq {
    NSData *frame=_frames[@(seq)];const struct dw2_record *records=frame.bytes;const uint8_t *status=statuses.bytes;
    BOOL currentFrame=!self.ended&&seq==_submittedSeq&&frame&&statuses.length==frame.length/sizeof(*records);
    if(currentFrame){
        NSMutableDictionary *acknowledged=[NSMutableDictionary dictionary];
        for(NSNumber *logical in _framePlacements[@(seq)]){
            DWNativePlacementDescription *description=_framePlacements[@(seq)][logical];
            if(![description isEqual:_desiredPlacements[logical]]||![self placementDescriptionCurrent:description])continue;
            const DWNativePlacementMember *members=description->members.bytes;BOOL applied=YES;
            for(NSUInteger i=0;i<description->members.length/sizeof(*members);i++){
                uint32_t index=members[i].index;
                if(index>=statuses.length||status[index]!=DW2_APPLIED||memcmp(&members[i].record,&records[index],sizeof(*records))){applied=NO;break;}
            }
            if(applied)acknowledged[logical]=description;
        }
        _acknowledgedPlacements=acknowledged.copy;_acknowledgedSequence=seq;
        for(DWNativePlacementDescription *description in acknowledged.objectEnumerator){
            DWNativeSpaceReflow *reflow=_spaceReflows[@(description->binding.identity.wid)];
            const DWNativePlacementMember *members=description->members.bytes;
            if(reflow&&description->members.length>=sizeof(*members)&&!memcmp(&reflow->identity,&description->binding.identity,sizeof(reflow->identity)))
                for(NSUInteger i=0;i<description->members.length/sizeof(*members);i++)if(members[i].record.id.wid==reflow->identity.wid&&members[i].targetSpace==reflow->target)
                    reflow->acknowledgedSequence=seq;
        }
        BOOL drained=NO;
        for(NSNumber *wid in _rebases.allKeys){NSData *expected=_rebases[wid];
            for(NSUInteger i=0;i<statuses.length;i++)if(records[i].id.wid==wid.unsignedIntValue&&status[i]==DW2_APPLIED
                &&expected.length==sizeof(*records)&&!memcmp(expected.bytes,&records[i],sizeof(*records))){
                [_rebases removeObjectForKey:wid];[_rebased addObject:wid];drained=YES;break;}
        }
        for(DWNativeHiddenRoot *transition in _transitions.objectEnumerator){
            if(transition->phase!=1&&transition->phase!=2&&transition->phase!=4)continue;
            for(NSUInteger i=0;i<statuses.length;i++)if(status[i]==DW2_APPLIED&&!memcmp(&transition->record,&records[i],sizeof(*records))){
                if(transition->phase==1){CGRect own=transition.nativeBounds;transition->record=(struct dw2_record){.id=transition->record.id,.flags=DW2_RECORD_HAS_ALPHA,.alpha=0,.m={1,0,0,1,-own.origin.x,-own.origin.y}};transition->phase=2;drained=YES;}
                else if(transition->phase==2){transition->phase=3;drained=YES;}
                else transition->phase=5;
                break;
            }
        }
        if(drained)[self requireFreshPlacementAcknowledgement];
    }
    BOOL retry=NO;
    for(NSUInteger i=0;i<statuses.length&&i<frame.length/sizeof(*records);i++){
        NSNumber *wid=@(records[i].id.wid);BOOL release=(records[i].flags&DW2_RECORD_RESTORE)!=0;
        // A decline is a hint that spares the helper's own bound: whatever it answers, it is not asked again.
        DWNativeWindow *declined=release?_releases[wid]:nil;
        if(declined&&declined->declined&&declined->releaseSeq&&seq>=declined->releaseSeq){[_releases removeObjectForKey:wid];_forced=YES;continue;}
        if(status[i]==DW2_APPLIED){
            DWNativeWindow *pending=_releases[wid];
            if(release&&pending&&pending->releaseSeq&&seq>=pending->releaseSeq){[_releases removeObjectForKey:wid];_forced=YES;}
            continue;
        }
        if(status[i]==DW2_NOT_APPLIED||status[i]==DW2_RESTORE_PENDING||status[i]==DW2_SNAPSHOT||status[i]==DW2_JOURNAL||status[i]==DW2_SPACE)retry=YES;
        NSString *key=[NSString stringWithFormat:@"%@:%u:%d",wid,status[i],release];if([_said containsObject:key])continue;[_said addObject:key];
        fprintf(stderr,"Infinify: native presentation: window %u of process %d not %s: %s\n",wid.unsignedIntValue,records[i].id.pid,release?"restored":"placed",statusName(status[i]));
    }
    atomic_store(&_releasing,_releases.count!=0);
    // A rebind can race the helper's pending restoration. Once input stops, keep
    // retrying the latest complete frame until that restore no longer blocks it.
    // Old acknowledgements must not clear a newer frame's retry requirement.
    if(frame&&seq==_submittedSeq)atomic_store(&_retrying,retry);
    // The client accepts a complete reply only for a written frame and accounts
    // for every older unanswered write as superseded before calling us. Those
    // frames can never receive another result. Keep the acknowledged placement
    // descriptions through _acknowledgedPlacements, but release their duplicate
    // history and locally coalesced frames now, rather than after 65 submissions.
    // A missing or short substituted reply does not settle any history.
    if(frame&&statuses.length==frame.length/sizeof(*records))for(NSNumber *resolved in _frames.allKeys)if(resolved.unsignedLongLongValue<=seq){
        [_frames removeObjectForKey:resolved];[_framePlacements removeObjectForKey:resolved];
    }
    // The callback can describe/submit the next transition frame. Finish all
    // ACK bookkeeping first so a reentrant submission retains its own history.
    if(currentFrame&&!self.ended&&self.transitionFrameAcknowledged)self.transitionFrameAcknowledged();
}
- (void)invalidatePlacementReadiness {
    _acknowledgedPlacements=@{};_acknowledgedSequence=0;++_placementRevision;
}
- (void)requireFreshPlacementAcknowledgement {
    if(!NSThread.isMainThread||self.ended)return;
    [self invalidatePlacementReadiness];_described=NO;_forced=YES;
}
- (BOOL)placementDescriptionCurrent:(DWNativePlacementDescription *)description {
    if(!description||self.ended||description->binding.revision!=_placementRevision)return NO;
    const DWNativePlacementBinding *binding=&description->binding;
    DWNativeWindow *root=_windows[@(binding->identity.wid)];NSSet *family=_families[@(binding->identity.wid)];
    NSUInteger count=description->members.length/sizeof(DWNativePlacementMember);
    if(!root||!root->familyKnown||memcmp(&root->identity,&binding->identity,sizeof(root->identity))||root->root!=binding->identity.wid
        ||!family.count||family.count!=count||![root->logical isEqual:@(binding->window)])return NO;
    const DWNativePlacementMember *members=description->members.bytes;
    for(NSUInteger i=0;i<count;i++){
        const DWNativePlacementMember *member=&members[i];DWNativeWindow *current=_windows[@(member->record.id.wid)];
        if(!current||![family containsObject:@(member->record.id.wid)]||current->root!=binding->identity.wid
            ||current->parent!=member->parent||memcmp(&current->identity,&member->record.id,sizeof(current->identity))||!CGRectEqualToRect(current->bounds,member->native))return NO;
    }
    return YES;
}
- (DWNativeAppliedPlacement *)acknowledgedPlacementForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation output:(NSNumber *)output {
    uint64_t wantedWindow=0,wantedGeneration=0,wantedOutput=0;
    if(!NSThread.isMainThread||self.ended||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq||!DWNativePlacementInteger(window,&wantedWindow))return nil;
    DWNativePlacementDescription *description=_acknowledgedPlacements[window];
    if(!description||description->parked||description->binding.window!=wantedWindow||!DWNativePlacementInteger(generation,&wantedGeneration)||!DWNativePlacementInteger(output,&wantedOutput)
        ||description->binding.generation!=wantedGeneration||description->binding.output!=wantedOutput
        ||![DWNativePlacementIdentity(description->binding.identity)isEqual:identity]
        ||![description isEqual:_desiredPlacements[window]]||![self placementDescriptionCurrent:description])return nil;
    return [[DWNativeAppliedPlacement alloc]initWithSession:_placementSession sequence:_acknowledgedSequence description:description];
}
- (BOOL)isParkingAcknowledgedForWindow:(NSNumber *)window identity:(NSDictionary *)identity generation:(NSNumber *)generation {
    uint64_t wantedWindow=0,wantedGeneration=0;
    if(!NSThread.isMainThread||self.ended||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq
        ||!DWNativePlacementInteger(window,&wantedWindow)||!DWNativePlacementInteger(generation,&wantedGeneration))return NO;
    DWNativePlacementDescription *description=_acknowledgedPlacements[window];
    if(!description||!description->parked||description->binding.window!=wantedWindow||description->binding.generation!=wantedGeneration
        ||description->binding.output||_withheld[@(description->binding.identity.wid)]
        ||![DWNativePlacementIdentity(description->binding.identity)isEqual:identity]
        ||![description isEqual:_desiredPlacements[window]]||![self placementDescriptionCurrent:description])return NO;
    const DWNativePlacementMember *members=description->members.bytes;
    for(NSUInteger i=0;i<description->members.length/sizeof(*members);i++){
        const struct dw2_record *record=&members[i].record;
        if(members[i].targetSpace||(record->flags&DW2_RECORD_RESTORE)||record->m[0]!=1||record->m[1]!=0||record->m[2]!=0||record->m[3]!=1)return NO;
    }
    return YES;
}
- (BOOL)isAcknowledgedPlacementCurrent:(DWNativeAppliedPlacement *)placement {
    if(!NSThread.isMainThread||self.ended||![placement isKindOfClass:DWNativeAppliedPlacement.class]
        ||placement.session!=_placementSession||!_acknowledgedSequence||placement.sequence!=_acknowledgedSequence||placement.sequence!=_submittedSeq)return NO;
    DWNativePlacementDescription *description=placement.placementDescription;
    return description&&!description->parked&&description==_acknowledgedPlacements[@(placement.window)]&&[description isEqual:_desiredPlacements[@(placement.window)]]&&[self placementDescriptionCurrent:description];
}
@end
