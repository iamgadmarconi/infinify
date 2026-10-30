// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop window visibility: minimize and restore, the visibility ticket and observation, closing a window, the native family forget.
#import "Desktop+Private.h"
#import <unistd.h>
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWWindowEvents.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
#import "FixtureWindow.h"
@implementation Desktop (Visibility)
// Minimize retains the native identity, controller slot and helper journal.
// AX notifications request a bounded worker observation; they are not proof of
// visibility. Restores remain ineligible for input until a fresh placement ACK.
- (NSDictionary *)visibilityBinding:(LiveSource *)source {
    if(!source||source.detached||self.sources[source.logical]!=source)return nil;
    for(NSDictionary *row in [self call:@{@"op":@"snapshot"}][@"windows"])
        if([row[@"window"]isEqual:source.logical]&&boundIdentity(row[@"source"][@"identity"],source.identity))return DWTyped(row[@"source"],NSDictionary.class);
    return nil;
}
- (BOOL)visibilityTicketCurrent:(NSDictionary *)ticket source:(LiveSource *)source {
    if(!ticket||self.cleaning||self.sessionInactive||!self.native||self.native.ended||ticket[@"presenter"]!=self.native
        ||[ticket[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!source||source.detached
        ||self.sources[source.logical]!=source||!boundIdentity(source.identity,ticket[@"identity"]))return NO;
    NSDictionary *binding=[self visibilityBinding:source];
    return [binding[@"generation"]isEqual:ticket[@"generation"]];
}
- (void)requestVisibility:(LiveSource *)source {
    if(!source||source.detached)return;
    NSDictionary *binding=[self visibilityBinding:source];
    if(!binding||![self call:@{@"op":@"source_visibility_pending",@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"]}])return;
    source.nativeVisibilityRevision++;source.nativeVisibilityWanted=YES;source.nativeVisibilityRetryAt=0;
    source.nativeVisibilityStable=nil;source.nativeVisibilityRestore=nil;
    source.observationToken=++self.observationEpoch;[source invalidateNativeButtons];
    [self cancelNativeHoverForWindow:source.logical];[self cancelCapturedInputForWindow:source.logical];
    [self interruptFillForVisibility:source];
    if([[self.resize busyWindow]isEqual:source.logical])[self.resize cancel];
    if(self.native&&!self.nativeFillHandoff&&![[self.resize busyWindow]isEqual:source.logical]
        &&[self.native withholdWindow:source.identity])source.nativeVisibilityHeld=YES;
    self.nativeViewSnapshot=nil;self.windowObservationAgain=YES;[self render];[self requestWindowObservation];
}
- (void)windowVisibilityChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window)[self requestVisibility:source];
}
- (void)setNativeMinimized:(NSDictionary *)effect {
    LiveSource *source=self.sources[effect[@"window"]];NSDictionary *binding=[self visibilityBinding:source];
    if(!self.native||!source||!boundIdentity(source.identity,effect[@"identity"])||![binding[@"generation"]isEqual:effect[@"generation"]]){
        [self flashStatus:@"Minimize skipped: native window binding is unavailable"];return;
    }
    if(source.nativeVisibilityEffect){[self flashStatus:@"A window visibility request is already pending"];return;}
    NSMutableDictionary *ticket=[effect mutableCopy];ticket[@"presenter"]=self.native;ticket[@"session"]=@(self.nativeSessionEpoch);ticket[@"deadline"]=@(CACurrentMediaTime()+8);ticket[@"revision"]=@(source.nativeVisibilityRevision);
    source.nativeVisibilityEffect=ticket.copy;[self updateNativeVisibility];
}
static bool DWVisibilityAllowed(DWFocusIdentity selected,void *context) {
    (void)selected;BOOL (^check)(void)=(__bridge id)context;__block BOOL allowed=NO;
    dispatch_sync(dispatch_get_main_queue(),^{allowed=check();});return allowed;
}
- (void)updateNativeVisibility {
    if(self.cleaning||self.sessionInactive||!self.native||self.native.ended)return;
    for(LiveSource *source in self.sources.allValues){
        NSDictionary *effect=source.nativeVisibilityEffect;
        if(effect&&!source.nativeVisibilityWriting){
            if(![self visibilityTicketCurrent:effect source:source]||[effect[@"revision"]unsignedLongLongValue]!=source.nativeVisibilityRevision||CACurrentMediaTime()>[effect[@"deadline"]doubleValue]){
                source.nativeVisibilityEffect=nil;[self requestVisibility:source];[self flashStatus:@"Window visibility request expired before native ownership settled"];continue;
            }
            // A Fill exit owns the same withhold/resume mechanism. Finish it,
            // including its helper ACK, before handing this window to AppKit.
            if(self.nativeFillHandoff||![self.resize canRemove:source.logical]||source.nativeMouseOwnership)continue;
            if(![self.native withholdWindow:source.identity])continue;
            source.nativeVisibilityHeld=YES;
            if(![self.native isWindowWithheld:source.identity]){[self render];continue;}
            source.nativeVisibilityWriting=YES;
            [source invalidateNativeButtons];[self cancelNativeHoverForWindow:source.logical];[self cancelCapturedInputForWindow:source.logical];
            __weak Desktop *weak=self;__weak LiveSource *live=source;
            BOOL (^valid)(void)=^BOOL{Desktop *d=weak;LiveSource *s=live;
                return d&&s&&s.nativeVisibilityEffect==effect&&[d visibilityTicketCurrent:effect source:s]
                    &&[effect[@"revision"]unsignedLongLongValue]==s.nativeVisibilityRevision&&CACurrentMediaTime()<[effect[@"deadline"]doubleValue]&&!d.nativeFillHandoff&&[d.resize canRemove:s.logical]
                    &&[d.native isWindowWithheld:s.identity];};
            NSDictionary *identity=source.identity;
            DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                DWFocusResult result=dw_focus_set_minimized(selected,[effect[@"minimized"]boolValue],DWVisibilityAllowed,(__bridge void *)valid);
                dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;LiveSource *s=live;if(!d||!s||d.sources[s.logical]!=s)return;
                    s.nativeVisibilityWriting=NO;if(s.nativeVisibilityEffect==effect)s.nativeVisibilityEffect=nil;
                    if(![d visibilityTicketCurrent:effect source:s])return;
                    // A successful setter is still only an attempt. Read the
                    // actual AX value through the existing observer worker.
                    [d requestVisibility:s];
                    if(result.outcome!=DWFocusObserved)[d flashStatus:[NSString stringWithFormat:@"Window visibility request: %s",dw_focus_outcome_name(result.outcome)]];
                    if(DWDebugTrace())fprintf(stderr,"debug: native visibility write window=#%s minimized=%d attempted=%d outcome=%s\n",s.logical.description.UTF8String,[effect[@"minimized"]boolValue],result.mutation_attempted,dw_focus_outcome_name(result.outcome));
                });
            });
        }
        NSDictionary *restore=source.nativeVisibilityRestore;if(!restore)continue;
        if(![self visibilityTicketCurrent:restore source:source]||[restore[@"revision"]unsignedLongLongValue]!=source.nativeVisibilityRevision){source.nativeVisibilityRestore=nil;continue;}
        if(self.nativeFillHandoff||source.nativeVisibilityWanted||source.nativeVisibilityWriting)continue;
        NSNumber *output=[self.nativeViews desiredOwnerForWindow:source.logical];
        DWNativeAppliedPlacement *receipt=output?[self.native acknowledgedPlacementForWindow:source.logical identity:source.identity generation:restore[@"generation"] output:output]:nil;
        BOOL ready=output?(receipt&&[self.native isAcknowledgedPlacementCurrent:receipt]):[self.native isParkingAcknowledgedForWindow:source.logical identity:source.identity generation:restore[@"generation"]];
        if(!ready)continue;
        if(![self.resize canRemove:source.logical])continue;
        NSDictionary *binding=[self visibilityBinding:source];
        if([binding[@"visibility"]isEqual:@"restoring"]){
            NSDictionary *reply=[self call:@{@"op":@"source_visible",@"window":source.logical,@"identity":source.identity,@"generation":restore[@"generation"],@"visibility_revision":restore[@"visibility_revision"]}];
            if(!reply)continue;
            // External Fill minimization retained a size debt. Its first
            // acknowledged restore starts that guarded transaction; input
            // remains closed until a later ACK observes it fully settled.
            if(sizeEffect(reply)){[self applyReply:reply];continue;}
            if(![reply[@"visibility"]isEqual:@"visible"])continue;
        }else if(![binding[@"visibility"]isEqual:@"visible"])continue;
        source.nativeMinimized=NO;source.nativeVisibilityHeld=NO;source.nativeVisibilityRestore=nil;
        if(DWDebugTrace())fprintf(stderr,"debug: native visibility ready window=#%s revision=%llu sequence=%llu parked=%d\n",source.logical.description.UTF8String,[restore[@"revision"]unsignedLongLongValue],(unsigned long long)receipt.sequence,!output);
        [self render];[self focusChanged];
    }
}
- (void)observeVisibility:(DWWindowObservation *)observation source:(LiveSource *)source {
    NSDictionary *request=observation.request;
    if(!request[@"visibility_revision"]||[request[@"visibility_revision"]unsignedLongLongValue]!=source.nativeVisibilityRevision||!source.nativeVisibilityWanted)return;
    source.nativeVisibilityRetryAt=CACurrentMediaTime()+.1;
    if(!observation.minimized||self.nativeFillHandoff||![self.resize canRemove:source.logical]||source.nativeVisibilityWriting)return;
    BOOL minimized=observation.minimized.boolValue;
    NSDictionary *binding=[self visibilityBinding:source];if(!binding)return;
    if(!minimized){
        // AppKit's deminiaturization owns its native animation. Two fresh,
        // unchanged native readings keep its moving geometry out of ours.
        // An off-canvas source can legitimately remain off screen.
        if(!observation.hasBounds){source.nativeVisibilityStable=nil;return;}
        NSDictionary *stable=@{@"bounds":DWRectJSON(observation.bounds),@"displayed":observation.info[(id)kCGWindowBounds]?:@{},@"onscreen":@([observation.info[(id)kCGWindowIsOnscreen]boolValue])};
        if(![source.nativeVisibilityStable isEqual:stable]){source.nativeVisibilityStable=stable;source.nativeVisibilityStableSince=CACurrentMediaTime();return;}
        if(CACurrentMediaTime()-source.nativeVisibilityStableSince<.05)return;
    }
    if(observation.hasBounds)[self.native bound:source.identity bounds:observation.bounds family:observation.family];
    if(![self.native withholdWindow:source.identity])return;
    source.nativeVisibilityHeld=YES;
    NSDictionary *reply=[self call:@{@"op":@"observe_visibility",@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"minimized":@(minimized)}];if(!reply)return;
    source.nativeVisibilityWanted=NO;source.nativeVisibilityStable=nil;
    source.nativeMinimized=minimized;
    if(minimized){if([reply[@"changed"]boolValue])self.sceneDirty=YES;source.nativeVisibilityRestore=nil;[self forgetNativeFamily:source];self.nativeViewSnapshot=nil;[self render];return;}
    // Rebind the fresh native basis while preserving the controller's world
    // rectangle. The restore placement is presentable but never a hit target.
    [self.native bound:source.identity bounds:observation.bounds family:observation.family];
    source.router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observation.bounds));
    [self call:@{@"op":@"observe_presentation",@"window":source.logical,@"identity":source.identity,@"source_rect":DWRectJSON(observation.bounds),@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)}}];
    binding=[self visibilityBinding:source];
    source.nativeVisibilityRestore=@{@"identity":source.identity.copy,@"generation":binding[@"generation"],@"visibility_revision":binding[@"visibility_revision"],@"revision":@(source.nativeVisibilityRevision),@"presenter":self.native,@"session":@(self.nativeSessionEpoch)};
    [self.native resumeWindow:source.identity];self.nativeViewSnapshot=nil;[self render];
}
// The close_window effect of close-window and suspend-window. It is taken only from the
// reply to a binding or an IPC request, never from a window that came
// or went by itself, and only for the binding the controller named: this shell's own
// source for that window, still bound by the controller at that generation. The window
// stays bound until it is gone; -poll then reports window_closed and the controller's
// mark decides between a real close and a stand-in. The press is validated afresh and
// sent off the main thread.
- (void)closeWindow:(NSDictionary *)effect {
    NSNumber *window=DWTyped(effect[@"window"],NSNumber.class);LiveSource *source=window?self.sources[window]:nil;NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];id binding=nil;
    for(NSDictionary *w in snapshot[@"windows"])if([w[@"window"]isEqual:window])binding=w[@"source"];
    NSDictionary *bound=DWTyped(binding,NSDictionary.class),*identity=source.identity;
    if(!source||source.detached||!bound||!boundIdentity(identity,effect[@"identity"])||!boundIdentity(identity,bound[@"identity"])||![bound[@"generation"]isEqual:effect[@"generation"]]){[self flashStatus:@"Close skipped: the window is no longer the one that was bound"];[self render];return;}
    if(!AXIsProcessTrusted()){[self flashStatus:@"Closing a window requires Accessibility access. Enable it in System Settings, then reopen."];[self render];return;}
    __weak Desktop *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *error=DWCloseWindow(identity);if(error)dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(!d||d.cleaning)return;[d flashStatus:[@"Window not closed: " stringByAppendingString:error]];[d render];});});
}
- (void)forgetNativeFamily:(LiveSource *)source {
    if(source.nativeFamily){source.nativeFamily=nil;self.nativeFamilyRevision++;}
}
@end
