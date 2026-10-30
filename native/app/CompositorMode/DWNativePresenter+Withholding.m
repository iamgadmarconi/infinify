// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWDockPayload.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/app/CompositorMode/DWNativePresenter.m (37b27b1): withheld roots, zoom-1 rebase and hidden transitions.
#import "DWNativePresenter+Private.h"
#import "DWGeometryJSON.h"

@implementation DWNativePresenter (Withholding)
- (BOOL)withholdWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended)return NO;
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=wid?_windows[wid]:nil;
    if(!root||root->root!=wid.unsignedIntValue||![DWNativePlacementIdentity(root->identity)isEqual:identity])return NO;
    if(![_withheld[wid]isEqual:identity]){_withheld[wid]=identity.copy;[self requireFreshPlacementAcknowledgement];}
    return YES;
}
- (BOOL)isWindowWithheld:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended||![_withheld[identity[@"wid"]]isEqual:identity]
        ||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq)return NO;
    const struct dw2_record *records=_sent.bytes;
    NSSet *family=_families[identity[@"wid"]];if(!family.count)return NO;
    for(NSUInteger i=0;i<_sent.length/sizeof(*records);i++)if([family containsObject:@(records[i].id.wid)])return NO;
    return YES;
}
- (void)resumeWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||![_withheld[identity[@"wid"]]isEqual:identity])return;
    [_withheld removeObjectForKey:identity[@"wid"]];[_transitions removeObjectForKey:identity[@"wid"]];[_rebases removeObjectForKey:identity[@"wid"]];[_rebased removeObject:identity[@"wid"]];[self requireFreshPlacementAcknowledgement];
}
- (BOOL)canRebaseWindow:(NSDictionary *)identity {
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=_windows[wid];
    return [self isWindowWithheld:identity]&&root&&root->familyKnown&&root->root==wid.unsignedIntValue
        &&[DWNativePlacementIdentity(root->identity)isEqual:identity]&&_families[wid].count==1&&!_rebases[wid]&&![_rebased containsObject:wid];
}
- (BOOL)rebaseWindow:(NSDictionary *)identity bounds:(CGRect)native {
    if(![self canRebaseWindow:identity]||!DWFiniteRect(native)||fabs(native.origin.x)>1e6||fabs(native.origin.y)>1e6)return NO;
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=_windows[wid];
    if(fabs(root->bounds.size.width-native.size.width)>1||fabs(root->bounds.size.height-native.size.height)>1)return NO;
    struct dw2_record record={.id=root->identity,.m={1,0,0,1,-native.origin.x,-native.origin.y}};
    root->bounds=native;_rebases[wid]=[NSData dataWithBytes:&record length:sizeof(record)];[self requireFreshPlacementAcknowledgement];return YES;
}
- (BOOL)isWindowRebased:(NSDictionary *)identity {
    return NSThread.isMainThread&&[_rebased containsObject:identity[@"wid"]]&&_families[identity[@"wid"]].count==1&&[self isWindowWithheld:identity];
}
- (void)cancelRebaseWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||![_withheld[identity[@"wid"]]isEqual:identity])return;
    [_rebases removeObjectForKey:identity[@"wid"]];[_rebased removeObject:identity[@"wid"]];[self requireFreshPlacementAcknowledgement];
}
- (DWNativeHiddenRoot *)beginTransitionForWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended||!(_info.caps&DW2_CAP_ALPHA))return nil;
    NSNumber *wid=identity[@"wid"];DWNativeWindow *root=_windows[wid];
    if(!root||!root->familyKnown||root->root!=wid.unsignedIntValue||_families[wid].count!=1||_withheld[wid]
        ||![DWNativePlacementIdentity(root->identity)isEqual:identity]||!_acknowledgedSequence||_acknowledgedSequence!=_submittedSeq)return nil;
    DWNativePlacementDescription *found=nil;
    for(DWNativePlacementDescription *description in _acknowledgedPlacements.objectEnumerator)
        if(!description->parked&&description->binding.identity.wid==wid.unsignedIntValue&&[description isEqual:_desiredPlacements[@(description->binding.window)]]&&[self placementDescriptionCurrent:description]){found=description;break;}
    if(!found||found->members.length!=sizeof(DWNativePlacementMember))return nil;
    const DWNativePlacementMember *member=found->members.bytes;
    DWNativeHiddenRoot *transition=[[DWNativeHiddenRoot alloc]initWithSession:_placementSession];transition.identity=identity;transition.nativeBounds=member->native;transition.screenRect=found->binding.screen;transition->record=member->record;
    if(![self withholdWindow:identity])return nil;_transitions[wid]=transition;return transition;
}
- (BOOL)transitionCurrent:(DWNativeHiddenRoot *)transition {
    if(!transition)return NO;
    NSNumber *wid=transition.identity[@"wid"];DWNativeWindow *root=_windows[wid];
    return NSThread.isMainThread&&!self.ended&&transition&&transition->session==_placementSession&&_transitions[wid]==transition
        &&[_withheld[wid]isEqual:transition.identity]&&root&&root->familyKnown&&_families[wid].count==1&&[DWNativePlacementIdentity(root->identity)isEqual:transition.identity];
}
- (BOOL)hideTransition:(DWNativeHiddenRoot *)transition {
    if(![self transitionCurrent:transition]||transition->phase!=0||![self isWindowWithheld:transition.identity])return NO;
    transition->record.flags=(transition->record.flags&~DW2_RECORD_PINNED)|DW2_RECORD_HAS_ALPHA;transition->record.alpha=0;transition->phase=1;
    // Normal frames must explicitly restore alpha after this temporary write.
    _windows[transition.identity[@"wid"]]->alpha=YES;[self requireFreshPlacementAcknowledgement];return YES;
}
- (BOOL)isTransitionHidden:(DWNativeHiddenRoot *)transition {
    return [self transitionCurrent:transition]&&transition->phase==3&&[self isWindowWithheld:transition.identity];
}
- (BOOL)revealTransition:(DWNativeHiddenRoot *)transition screen:(CGRect)screen alpha:(double)alpha {
    if(![self isTransitionHidden:transition]||!DWFiniteRect(screen)||!isfinite(alpha)||alpha<0||alpha>1)return NO;
    DWNativeWindow *root=_windows[transition.identity[@"wid"]];CGRect native=root->bounds;
    if(!DWFiniteRect(native))return NO;
    double mx=native.size.width/screen.size.width,my=native.size.height/screen.size.height;
    struct dw2_record record={.id=root->identity,.flags=DW2_RECORD_HAS_ALPHA,.alpha=(float)alpha,.m={mx,0,0,my,-screen.origin.x*mx,-screen.origin.y*my}};
    for(NSUInteger i=0;i<6;i++)if(!isfinite(record.m[i])||fabs(record.m[i])>1e6)return NO;
    transition->record=record;transition->phase=4;[self requireFreshPlacementAcknowledgement];return YES;
}
- (BOOL)isTransitionRevealed:(DWNativeHiddenRoot *)transition {
    return [self transitionCurrent:transition]&&transition->phase==5&&_acknowledgedSequence&&_acknowledgedSequence==_submittedSeq;
}
@end
