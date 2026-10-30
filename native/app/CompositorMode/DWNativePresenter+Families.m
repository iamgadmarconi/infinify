// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation over the client library of native/dock-helper/Client (DWHelperClient.h,
// DWHelperProtocol.h). The two window-server queries are resolved by name, with the signatures
// native/dock-helper/Payload/DWPayload.m uses, cross-checked there against yabai
// dd845723416f5fe92af49fad5ebab00369e07edd (src/misc/extern.h), https://github.com/asmvik/yabai;
// see native/app/Resources/YABAI-NOTICE.txt. Nothing here changes a window: every change is the
// helper's, asked for through its socket.
// Split from native/desktop/native-presenter.m (37b27b1): binding, native families, release and decline, display-Space reflow.
#import "DWNativePresenter+Private.h"
#import "DWNativeFamily.h"

// How long the last audited family of a root is kept when the window server's answer cannot be read again. Chromium's hover cards, tooltips and
// completion lists are windows that come without a parent or without a size for a few frames; every read that met one failed the whole report
// for 4 to 100 ms in the guest. A family the shell has just audited is still the best account of the windows it placed, and a root is not
// parked on account of a read that failed once. Past this the family is let go (children restored) as it always was.
static const uint64_t DWNativeFamilyGraceMS=500;
@implementation DWNativePresenter (Families)
- (BOOL)familiesNeeded { return _desktopWide||_info.scope==DW2_SCOPE_ALLOWLIST||(_info.scope==DW2_SCOPE_COOPERATIVE&&(_info.caps&DW2_CAP_FIXTURE_FAMILY)); }
- (BOOL)allowsWindow:(NSDictionary *)identity {
    if(![identity[@"pid"]isKindOfClass:NSNumber.class]||![identity[@"wid"]isKindOfClass:NSNumber.class]||![identity[@"wid"]unsignedIntValue])return NO;
    NSArray *born=[self admittedBirth:identity];if(born.count!=2||![born[0]isEqual:identity[@"birth_sec"]]||![born[1]isEqual:identity[@"birth_usec"]])return NO;
    if(!self.familiesNeeded)return YES;
    uint32_t parent=0;return DWNativeWindowParent(identity,&parent)&&!parent;
}
- (NSNumber *)rootWindowFor:(CGWindowID)window {
    DWNativeWindow *member=window?_windows[@(window)]:nil;return member&&!self.ended?@(member->root):nil;
}
- (void)forgetChildrenOf:(NSNumber *)root reason:(NSString *)reason {
    DWNativeWindow *window=_windows[root];if(window&&window->familyKnown){window->familyKnown=NO;[self invalidatePlacementReadiness];}
    for(NSNumber *child in _families[root])if(![child isEqual:root]){DWNativeWindow *old=_windows[child];if(old)[self releaseWindow:old];}
    _families[root]=[NSSet setWithObject:root];
    NSString *key=[NSString stringWithFormat:@"family:%@:%@",root,reason];
    if(![_said containsObject:key]){[_said addObject:key];fprintf(stderr,"Infinify: native family #%u unavailable: %s\n",root.unsignedIntValue,reason.UTF8String);}
}
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native { [self bound:identity bounds:native family:nil]; }
- (void)bound:(NSDictionary *)identity bounds:(CGRect)native family:(NSDictionary *)family {
    NSNumber *wid=identity[@"wid"];NSArray *born=[self admittedBirth:identity];
    if(!wid.unsignedIntValue || born.count!=2 || ![born[0]isEqual:identity[@"birth_sec"]] || ![born[1]isEqual:identity[@"birth_usec"]])return;
    if(_desktopWide&&![self allowsWindow:identity])return;
    DWNativeWindow *window=_windows[wid];
    if(window && (window->identity.pid!=[identity[@"pid"]intValue] || window->identity.birth_sec!=[identity[@"birth_sec"]unsignedLongLongValue] || window->identity.birth_usec!=[identity[@"birth_usec"]unsignedLongLongValue])){[self unbound:@{@"pid":@(window->identity.pid),@"wid":wid,@"birth_sec":@(window->identity.birth_sec),@"birth_usec":@(window->identity.birth_usec)}];window=nil;}
    if(_releases[wid]){[_releases removeObjectForKey:wid];atomic_store(&_releasing,_releases.count!=0);_forced=YES;}
    if(!window){window=_windows[wid]=[DWNativeWindow new];window->identity=(struct dw2_identity){.pid=[identity[@"pid"]intValue],.wid=wid.unsignedIntValue,.birth_sec=[identity[@"birth_sec"]unsignedLongLongValue],.birth_usec=[identity[@"birth_usec"]unsignedLongLongValue]};window->bounds=CGRectNull;window->root=wid.unsignedIntValue;_families[wid]=[NSSet setWithObject:wid];}
    // A window that moved or took a new size by itself: what the window server then does to its transform is not known, so the frame is sent again.
    if(!CGRectEqualToRect(window->bounds,native)){[self invalidatePlacementReadiness];window->bounds=native;_forced=YES;}
    // A cooperative helper's narrow scope does not supply native ancestry.
    // Receipt readiness in every scope requires an actual audited family report.
    // Without one, retain the existing ordinary placement rather than discovering
    // additional windows outside that helper's explicitly enrolled WID scope.
    if(!self.familiesNeeded&&!family){
        if(window->familyKnown){window->familyKnown=NO;[self invalidatePlacementReadiness];}
        return;
    }
    NSString *why=nil;if(!family)family=DWNativeWindowFamily(identity,&why);
    // A report that could not be read (nil, or the empty marker of a requested audit that failed) is not a report of a changed family: a root whose
    // family was audited a moment ago keeps it, with its children placed, until the next read; one that stays unreadable is let go as before.
    if((!family||![family isKindOfClass:NSDictionary.class]||!family.count)&&window->familyKnown&&uptime()-window->familyAt<DWNativeFamilyGraceMS){
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native family kept root=%u reason=%s\n",wid.unsignedIntValue,why.UTF8String?:"unreadable");
        return;
    }
    if(!family||![family[@"identity"]isEqual:identity]||![family[@"root"]isEqual:wid]){
        [self forgetChildrenOf:wid reason:why?:@"identity changed"];return;
    }
    NSArray *report=[family[@"members"]isKindOfClass:NSArray.class]?family[@"members"]:nil;
    if(!report.count||report.count>64){[self forgetChildrenOf:wid reason:@"missing or unbounded family report"];return;}
    NSMutableSet<NSNumber *> *members=[NSMutableSet set];NSMutableDictionary<NSNumber *,NSNumber *> *parents=[NSMutableDictionary dictionary];BOOL sound=YES;
    // Validate the whole report before installing any child. A separately bound
    // root or a child already belonging to another root makes it ambiguous.
    for(id value in report){
        if(![value isKindOfClass:NSDictionary.class]){sound=NO;break;}NSDictionary *member=value,*who=member[@"identity"],*frame=member[@"native_bounds"];
        if(![who isKindOfClass:NSDictionary.class]||![frame isKindOfClass:NSDictionary.class]){sound=NO;break;}
        NSNumber *child=who[@"wid"];uint64_t childID=0,parent=0;
        if(!DWNativePlacementInteger(child,&childID)||!childID||childID>UINT32_MAX
            ||!DWNativePlacementInteger(member[@"parent"],&parent)||parent>UINT32_MAX
            ||([child isEqual:wid]?parent!=0:parent==0)){sound=NO;break;}
        DWNativeWindow *existing=_windows[child];
        NSDictionary *origin=frame[@"origin"],*size=frame[@"size"];
        if(![origin isKindOfClass:NSDictionary.class]||![size isKindOfClass:NSDictionary.class]){sound=NO;break;}
        for(id number in @[origin[@"x"]?:NSNull.null,origin[@"y"]?:NSNull.null,size[@"width"]?:NSNull.null,size[@"height"]?:NSNull.null])if(![number isKindOfClass:NSNumber.class])sound=NO;
        if(!sound)break;
        double x=[origin[@"x"]doubleValue],y=[origin[@"y"]doubleValue],w=[size[@"width"]doubleValue],h=[size[@"height"]doubleValue];
        if(!isfinite(x)||!isfinite(y)||!isfinite(w)||!isfinite(h)||w<=0||h<=0
            ||![who[@"pid"]isEqual:identity[@"pid"]]||![who[@"birth_sec"]isEqual:born[0]]||![who[@"birth_usec"]isEqual:born[1]]
            ||(existing&&existing->root!=wid.unsignedIntValue)||[members containsObject:child]
            ||([child isEqual:wid]&&!CGRectEqualToRect(CGRectMake(x,y,w,h),native))
            ||(_desktopWide&&(![self admittedBirth:who]||!DWNativeWindowBelongsToRoot(who,identity)))){sound=NO;break;}
        [members addObject:child];parents[child]=@(parent);
    }
    // Preserve the reported topology, rather than treating missing parents as
    // roots or trusting a root label without a complete acyclic parent chain.
    if(sound)for(NSNumber *child in members){
        NSNumber *cursor=child;NSMutableSet *seen=[NSMutableSet set];
        while(![cursor isEqual:wid]){
            if([seen containsObject:cursor]||!parents[cursor]||![members containsObject:parents[cursor]]){sound=NO;break;}
            [seen addObject:cursor];cursor=parents[cursor];
        }
        if(!sound)break;
    }
    if(!sound||![members containsObject:wid]){[self forgetChildrenOf:wid reason:@"inconsistent, duplicate or changed family member"];return;}
    for(NSNumber *old in _families[wid])if(![members containsObject:old]){DWNativeWindow *removed=_windows[old];if(removed)[self releaseWindow:removed];}
    for(NSDictionary *member in report){
        NSDictionary *who=member[@"identity"];NSNumber *child=who[@"wid"];
        NSDictionary *origin=member[@"native_bounds"][@"origin"],*size=member[@"native_bounds"][@"size"];
        CGRect frame=CGRectMake([origin[@"x"]doubleValue],[origin[@"y"]doubleValue],[size[@"width"]doubleValue],[size[@"height"]doubleValue]);
        DWNativeWindow *attached=_windows[child];if(!attached){attached=_windows[child]=[DWNativeWindow new];attached->identity=window->identity;attached->identity.wid=child.unsignedIntValue;attached->root=wid.unsignedIntValue;attached->bounds=CGRectNull;_forced=YES;}
        if(_releases[child]){[_releases removeObjectForKey:child];atomic_store(&_releasing,_releases.count!=0);_forced=YES;}
        uint32_t parent=[parents[child]unsignedIntValue];
        if(attached->parent!=parent){[self invalidatePlacementReadiness];attached->parent=parent;_forced=YES;}
        if(!CGRectEqualToRect(attached->bounds,frame)){[self invalidatePlacementReadiness];attached->bounds=frame;_forced=YES;}
    }
    _families[wid]=members.copy;window->familyAt=uptime();if(!window->familyKnown){window->familyKnown=YES;[self invalidatePlacementReadiness];}
}
- (void)releaseWindow:(DWNativeWindow *)window {
    [self invalidatePlacementReadiness];
    [_spaceReflows removeObjectForKey:@(window->identity.wid)];
    NSNumber *wid=@(window->identity.wid);[_windows removeObjectForKey:wid];if(self.ended)return;
    window->releaseSeq=0;_releases[wid]=window;atomic_store(&_releasing,true);_forced=YES;
}
- (BOOL)observeSpaceReflow:(NSDictionary *)identity bounds:(CGRect)native nativeInput:(BOOL)nativeInput {
    if(!NSThread.isMainThread||self.ended)return NO;
    DWNativeSpaceReflow *reflow=_spaceReflows[identity[@"wid"]];
    if(!reflow||![DWNativePlacementIdentity(reflow->identity)isEqual:identity])return NO;
    if(reflow->settled)return NO;
    uint64_t now=uptime();
    if(!CGRectEqualToRect(reflow->observed,native)){
        reflow->observed=native;reflow->changedAt=now;reflow->changed=YES;
        if(!reflow->settled)reflow->acknowledgedSequence=0;
    }
    if(nativeInput){reflow->nativeInput=YES;reflow->settled=YES;return NO;}
    // Space membership ACK can precede AppKit's asynchronous reflow. Keep a
    // two-second settling window and require a quiet frame plus a fresh ACK
    // after every observed geometry change. The final observation is still
    // basis-only; later equal observations must not resize the world again.
    if(reflow->acknowledgedSequence&&now-reflow->submittedAt>=2000&&now-reflow->changedAt>=250)reflow->settled=YES;
    return YES;
}
- (void)unbound:(NSDictionary *)identity {
    NSNumber *wid=identity[@"wid"];DWNativeWindow *window=wid?_windows[wid]:nil;if(!window)return;
    if(window->identity.pid!=[identity[@"pid"]intValue]||window->identity.birth_sec!=[identity[@"birth_sec"]unsignedLongLongValue]||window->identity.birth_usec!=[identity[@"birth_usec"]unsignedLongLongValue])return;
    [_withheld removeObjectForKey:wid];[_transitions removeObjectForKey:wid];[_rebases removeObjectForKey:wid];[_rebased removeObject:wid];
    NSSet *members=_families[wid]?:[NSSet setWithObject:wid];for(NSNumber *child in members){DWNativeWindow *attached=_windows[child];if(attached)[self releaseWindow:attached];}[_families removeObjectForKey:wid];
}
// A window this shell will not manage, which the helper's arrival veil may hold invisible: asked to release it now. The helper
// answers a release of a window it holds nothing of with a no-op, and lets the window go itself after its own bound otherwise.
- (void)declineWindow:(NSDictionary *)identity {
    if(!NSThread.isMainThread||self.ended||!_veiling)return;
    NSNumber *wid=identity[@"wid"];NSArray *born=[self admittedBirth:identity];
    if(!wid.unsignedIntValue||born.count!=2||![born[0]isEqual:identity[@"birth_sec"]]||![born[1]isEqual:identity[@"birth_usec"]]||_windows[wid]||_releases[wid])return;
    DWNativeWindow *window=[DWNativeWindow new];
    window->identity=(struct dw2_identity){.pid=[identity[@"pid"]intValue],.wid=wid.unsignedIntValue,.birth_sec=[born[0]unsignedLongLongValue],.birth_usec=[born[1]unsignedLongLongValue]};
    window->bounds=CGRectNull;window->root=wid.unsignedIntValue;window->declined=YES;window->releaseSeq=0;
    _releases[wid]=window;atomic_store(&_releasing,true);_forced=YES;
}
@end
