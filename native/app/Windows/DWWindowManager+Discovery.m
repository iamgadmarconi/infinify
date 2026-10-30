// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm (https://github.com/malbiruk/driftwm) 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/handlers/xdg_shell.rs (new_toplevel, toplevel_destroyed: every toplevel is
// managed from the moment it exists), src/handlers/compositor.rs (a new window is
// placed on its first sized commit, not before), src/input/actions.rs (CloseWindow:
// send_close to the focused client) and src/state/suspended.rs (relaunch_suspended:
// resolve the app afresh, report one that no longer resolves). New implementation
// over the macOS window list, ScreenCaptureKit, Accessibility and NSWorkspace; the
// placement, matching and focus rules stay in the controller.
// Event-driven tracking is adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT;
// licence text in YABAI-NOTICE.txt), src/event_loop.c:
// WINDOW_CREATED, WINDOW_DEMINIMIZED and APPLICATION_VISIBLE look for the window at once, APPLICATION_LAUNCHED for all of an
// application's. DWWindowEvents.h has the observers and the rest of the provenance. Here creation hints coalesce into the
// host's single-flight worker observation; existing bound-window events are delivered to the host immediately.
// Split from native/desktop/window-manager.m at 37b27b1: the discovery passes (the pass over the window records, the shareable
// read and its completion), moved verbatim.
#import "DWWindowManager+Private.h"
#import "DWNativeFamily.h"
#import "DWNativeFocus.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <libproc.h>
@implementation DWWindowManager (Discovery)
// One completed worker read serves the whole discovery set. No event starts a
// second global enumeration while another application's observation is in flight.
- (void)passRecords:(NSArray<NSDictionary *> *)list nativeCandidateBases:(NSDictionary<NSNumber *,NSDictionary *> *)nativeCandidateBases sampledAt:(CFTimeInterval)sampledAt {
    if(self.native)self.nativeSampleAt=MAX(self.nativeSampleAt,sampledAt);
    if(self.stopped)return;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;id<DWWindowHost> host=self.host;if(!self.began)self.began=now;
    NSMutableDictionary<NSNumber *,NSDictionary *> *bounds=[NSMutableDictionary dictionary],*bases=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *wanted=[NSMutableDictionary dictionary],*warming=[NSMutableDictionary dictionary],*regular=[NSMutableDictionary dictionary],*since=[NSMutableDictionary dictionary],*scoped=[NSMutableDictionary dictionary],*sampled=[NSMutableDictionary dictionary];NSMutableDictionary *candidateTitles=[NSMutableDictionary dictionary];NSMutableArray<NSNumber *> *front=[NSMutableArray array];BOOL moving=NO;NSTimeInterval stabilityDelay=still,titleDelay=0;
    for(NSDictionary *w in list){
        NSNumber *wid=w[(id)kCGWindowNumber],*pid=w[(id)kCGWindowOwnerPID];NSDictionary *b=w[(id)kCGWindowBounds];CGRect r=CGRectZero;
        NSInteger level=[w[(id)kCGWindowLayer]integerValue];BOOL testPanel=self.scope&&self.testPanelWindowLevel>0&&level==self.testPanelWindowLevel;
        if(![wid isKindOfClass:NSNumber.class]||![pid isKindOfClass:NSNumber.class]||pid.intValue==getpid())continue;
        // --only-pid: a window of any other process leaves no trace here. It is neither timed nor wanted, so nothing below asks about it.
        if(self.scope){NSNumber *within=scoped[pid];if(!within)within=scoped[pid]=@(DWInScope(self.scope,pid.intValue));if(!within.boolValue)continue;}
        BOOL panel=self.nativePanels&&level==NSFloatingWindowLevel;
        if(level!=0&&!testPanel&&!panel)continue;
        if(![b isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)b,&r)||r.size.width<40||r.size.height<40)continue;
        bounds[wid]=b;
        if([self.offered containsObject:wid])continue;
        NSNumber *policy=regular[pid];
        if(!policy)policy=regular[pid]=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue].activationPolicy==NSApplicationActivationPolicyRegular?@YES:@NO;
        if(!policy.boolValue){[self declineWindow:wid pid:pid];continue;}
        if([host managesWindow:wid.unsignedIntValue pid:pid.intValue]){[self.offered addObject:wid];continue;}
        // CG bounds include the owner's opening animation. Native stability is
        // the fresh untransformed extent AND original affine basis, while the
        // actual CG list still decides on-screen eligibility and stack order.
        NSDictionary *basis=self.native?nativeCandidateBases[wid]:b;
        if(self.native){NSDictionary *who=basis[@"identity"];NSDictionary *own=basis[@"native_bounds"];CGRect native=CGRectZero;
            if(![who[@"pid"]isEqual:pid]||![who[@"wid"]isEqual:wid]||![own isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)own,&native)||native.size.width<40||native.size.height<40){moving=YES;continue;}
            b=own;bounds[wid]=own;
        }
        BOOL recent=!self.native||(self.sampled[wid]&&sampledAt-self.sampled[wid].doubleValue<=.1);
        NSNumber *held=recent&&[self.bases[wid]isEqual:basis]?self.since[wid]:nil;bases[wid]=basis;sampled[wid]=@(sampledAt);since[wid]=held?:@(now);
        if([w[(id)kCGWindowName]isKindOfClass:NSString.class])candidateTitles[wid]=w[(id)kCGWindowName];
        NSDictionary *titleRetry=self.titleRetries[wid];
        if(titleRetry&&(![titleRetry[@"basis"]isEqual:basis]||[w[(id)kCGWindowName]isKindOfClass:NSString.class])){[self.titleRetries removeObjectForKey:wid];titleRetry=nil;}
        // Upstream places a window on its first sized commit. A window still being
        // sized is not offered: its world size is the source rectangle it is offered with.
        if(!held||now-held.doubleValue<still){moving=YES;stabilityDelay=MIN(stabilityDelay,held?still-(now-held.doubleValue):still);if(self.native)warming[wid]=pid;continue;}
        NSTimeInterval remaining=[titleRetry[@"deadline"]doubleValue]-now;
        if(remaining>0){titleDelay=titleDelay?MIN(titleDelay,remaining):remaining;continue;}
        if(titleRetry&&[titleRetry[@"deadline"]doubleValue]>0)[self.titleRetries removeObjectForKey:wid];
        wanted[wid]=pid;[front addObject:wid];
    }
    // Leaving the screen ends a window's turn; coming back is a new appearance.
    NSSet<NSNumber *> *present=[NSSet setWithArray:bounds.allKeys];self.bounds=bounds;self.bases=bases;self.sampled=sampled;self.since=since;[self.offered intersectSet:present];[self.declined intersectSet:present];[self.missed intersectSet:present];[self.unlisted intersectSet:present];
    for(NSNumber *wid in self.titleRetries.allKeys)if(![self.titleRetries[wid][@"basis"]isEqual:bases[wid]])[self.titleRetries removeObjectForKey:wid];
    for(NSNumber *wid in self.nativeMetadata.allKeys){NSDictionary *ticket=self.nativeMetadata[wid];
        if(![ticket[@"basis"]isEqual:bases[wid]]||![ticket[@"since"]isEqual:since[wid]]||![ticket[@"cg_title"]isEqual:candidateTitles[wid]?:NSNull.null])[self.nativeMetadata removeObjectForKey:wid];
    }
    // The same 50 ms hold, followed by a fresh worker read at its earliest due
    // deadline. Polling remains the fallback for a host without this callback.
    if(moving||titleDelay){if(moving)self.eager=now+1;[self requestDiscoveryAfter:moving?(titleDelay?MIN(stabilityDelay,titleDelay):stabilityDelay):titleDelay];}
    else {[self.discoveryTimer invalidate];self.discoveryTimer=nil;self.discoveryDeadline=0;}
    // AX selection overlaps the wait, but never competes with a stable read or
    // starts a second flight. Only its exact post-AX proof may end the hold early.
    BOOL startupWaiting=!self.completed&&moving&&now-self.began<2;
    if(self.native&&!self.reading&&(!self.retry||now>=self.retry)&&(!wanted.count||startupWaiting)&&AXIsProcessTrusted()){
        for(NSNumber *wid in warming.allKeys)if(self.nativeMetadata[wid])[warming removeObjectForKey:wid];
        if(warming.count)[self prefetchNativeMetadata:warming.copy titles:candidateTitles records:list];
    }
    // The first pass waits, two seconds at most, until every window holds still, so that one read offers them all.
    if(startupWaiting)return;
    if(self.reading){if(wanted.count)self.eager=now+1;return;}
    if(self.native&&self.retry&&now<self.retry)return;
    // A read that failed is tried again after about two seconds, while access still stands: this never asks for it.
    if(self.retry&&now>=self.retry){self.retry=0;if(self.native||CGPreflightScreenCaptureAccess())self.requested=nil;}
    // The first pass reads the shareable windows even with nothing to offer: it must name the windows that are not on screen.
    if(!wanted.count&&(self.completed||self.requested||self.titleRetries.count))return;
    NSSet<NSNumber *> *ids=[NSSet setWithArray:wanted.allKeys];if(self.requested&&[ids isEqualToSet:self.requested])return;
    self.reading=YES;self.requested=ids;__weak DWWindowManager *weak=self;NSDictionary<NSNumber *,NSNumber *> *asked=[wanted copy];
    NSMutableDictionary *levels=[NSMutableDictionary dictionary],*listedTitles=[NSMutableDictionary dictionary];
    for(NSDictionary *row in list){NSNumber *wid=row[(id)kCGWindowNumber];if(![asked[wid]isEqual:row[(id)kCGWindowOwnerPID]])continue;
        levels[wid]=row[(id)kCGWindowLayer];NSString *title=row[(id)kCGWindowName];
        if([title isKindOfClass:NSString.class])listedTitles[wid]=title;
    }
    NSMutableDictionary<NSNumber *,NSDictionary *> *requestedBounds=[NSMutableDictionary dictionary],*requestedBases=[NSMutableDictionary dictionary],*titleTickets=[NSMutableDictionary dictionary];for(NSNumber *wid in asked){requestedBounds[wid]=bounds[wid];requestedBases[wid]=bases[wid];
        if(self.native&&!listedTitles[wid]){NSMutableDictionary *ticket=[@{@"basis":bases[wid],@"deadline":@0}mutableCopy];self.titleRetries[wid]=ticket;titleTickets[wid]=ticket;}}
    NSDictionary *frames=requestedBounds.copy,*basis=requestedBases.copy,*tickets=titleTickets.copy;
    if(self.capturing){[SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){NSDictionary<NSNumber *,id> *subroles=content?DWWindowManagerSubroles(asked,nil):nil;dispatch_async(dispatch_get_main_queue(),^{[weak read:content error:error asked:asked front:front subroles:subroles titles:nil frames:nil levels:levels basis:basis titleTickets:tickets earlyTickets:nil];});}];return;}
    // Native presentation or a scoped overlay without Screen Recording access: shareable windows are not asked for, so nothing can prompt. What they
    // would have said of a candidate is read from the window list (this pass's bounds) and from Accessibility, off the main thread like the subroles.
    NSMutableDictionary *uncached=[asked mutableCopy],*cachedRoles=[NSMutableDictionary dictionary],*cachedTitles=[listedTitles mutableCopy];
    for(NSNumber *wid in asked){NSDictionary *ticket=self.nativeMetadata[wid];
        if(ticket[@"subrole"]&&ticket[@"title"]&&now-[ticket[@"started"]doubleValue]<=.1&&[ticket[@"basis"]isEqual:basis[wid]]&&[ticket[@"since"]isEqual:self.since[wid]]){
            cachedRoles[wid]=ticket[@"subrole"];cachedTitles[wid]=ticket[@"title"];[uncached removeObjectForKey:wid];
        }
    }
    if(asked.count&&!uncached.count){[self read:nil error:nil asked:asked front:front subroles:cachedRoles titles:cachedTitles frames:frames levels:levels basis:basis titleTickets:tickets earlyTickets:nil];return;}
    // Do not carry an older prefetched result through another app's slow read.
    // A mixed batch uses the ordinary fresh selection for its complete set.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSMutableDictionary<NSNumber *,NSString *> *titles=[listedTitles mutableCopy];NSDictionary<NSNumber *,id> *subroles=DWWindowManagerSubroles(asked,titles);dispatch_async(dispatch_get_main_queue(),^{[weak read:nil error:nil asked:asked front:front subroles:subroles titles:titles frames:frames levels:levels basis:basis titleTickets:tickets earlyTickets:nil];});});
}
// `front` is the window list's own order, front to back. `subroles` is DWWindowManagerSubroles' answer for `asked`, read before this turn of the main queue.
// `titles` and `frames` stand in for the shareable windows in a run that does not read them (`capturing` NO): `content` is then nil and no failure.
- (void)read:(SCShareableContent *)content error:(NSError *)error asked:(NSDictionary<NSNumber *,NSNumber *> *)asked front:(NSArray<NSNumber *> *)front subroles:(NSDictionary<NSNumber *,id> *)subroles titles:(NSDictionary<NSNumber *,NSString *> *)titles frames:(NSDictionary<NSNumber *,NSDictionary *> *)frames levels:(NSDictionary<NSNumber *,NSNumber *> *)levels basis:(NSDictionary<NSNumber *,NSDictionary *> *)basis titleTickets:(NSDictionary<NSNumber *,NSDictionary *> *)tickets earlyTickets:(NSDictionary<NSNumber *,NSDictionary *> *)earlyTickets {
    if(self.stopped)return;self.reading=NO;id<DWWindowHost> host=self.host;
    // `requested` stays: the same candidates are not read again at once, so a failure cannot loop.
    if(!content&&self.capturing){self.retry=NSProcessInfo.processInfo.systemUptime+2;[host discoveryFailed:error.localizedDescription?:@"the shareable windows are unavailable"];return;}
    self.requested=nil;self.retry=0;NSMutableDictionary<NSNumber *,DWWindowCandidate *> *found=[NSMutableDictionary dictionary];BOOL again=NO;
    for(SCWindow *window in content.windows){NSNumber *wid=@(window.windowID);if(asked[wid]&&asked[wid].intValue==window.owningApplication.processID&&!found[wid])found[wid]=[DWWindowCandidate candidateWithShareable:window];}
    // Without the shareable windows every candidate asked about is found: the window list had it on screen a moment ago.
    if(!self.capturing)for(NSNumber *wid in asked){
        DWWindowCandidate *candidate=[DWWindowCandidate new];NSRunningApplication *running=[NSRunningApplication runningApplicationWithProcessIdentifier:asked[wid].intValue];CGRect frame=CGRectZero;
        if(!frames[wid]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)frames[wid],&frame))continue;
        candidate.pid=asked[wid].intValue;candidate.window=wid.unsignedIntValue;candidate.bundleIdentifier=running.bundleIdentifier;candidate.applicationName=running.localizedName;candidate.title=titles[wid];candidate.frame=frame;found[wid]=candidate;
    }
    // Back to front: the controller raises each window as it maps, so the canvas stacks them as the desktop does.
    for(NSNumber *wid in front.reverseObjectEnumerator){
        // A newer metadata batch can arrive while role/title selection is in
        // flight. It must still list this candidate at the exact stable bounds
        // that were selected, including a move away and back during the read.
        // Do not spend its appearance on an obsolete asynchronous result.
        NSNumber *held=self.since[wid];
        // An AX role/title reply cannot turn an aged native stability sample
        // into current eligibility. The date is separate from basis equality.
        if(self.native&&(!self.sampled[wid]||CACurrentMediaTime()-self.sampled[wid].doubleValue>.1)){again=YES;[self requestDiscoveryAfter:0];continue;}
        NSDictionary *early=earlyTickets[wid];BOOL earlyReady=self.native&&self.completed&&early&&self.nativeMetadata[wid]==early
            &&[early[@"basis"]isEqual:basis[wid]]&&[early[@"since"]isEqual:held]&&NSProcessInfo.processInfo.systemUptime-[early[@"started"]doubleValue]<=.1
            &&[levels[wid]integerValue]==0&&[subroles[wid]isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
            &&[titles[wid]isKindOfClass:NSString.class]&&DWWindowManagerIsCanonicalBasis(basis[wid]);
        if(![self.bases[wid]isEqual:basis[wid]]||!held||(earlyTickets?!earlyReady:NSProcessInfo.processInfo.systemUptime-held.doubleValue<still)){again=YES;continue;}
        DWWindowCandidate *window=found[wid];
        // A window the read did not list yet is asked for once more, then left until it next comes on screen.
        if(!window){if([self.missed containsObject:wid]){[self.offered addObject:wid];[self declineWindow:wid pid:asked[wid]];}else {[self.missed addObject:wid];again=YES;}continue;}
        // Only a real window is adopted: by Accessibility a standard window or a dialog, whatever its size or title. One its application does not
        // list yet is asked about once more, by its own count (`unlisted`: a read that missed it above has not spent that look). Where
        // Accessibility cannot say, or the application still does not list the window (it lists only those of the active Space), the rule is the
        // size floor it always was, less the untitled window smaller than 200x150 that no application shows as a window of its own: a helper
        // adopted by mistake can be dismissed, a real window refused cannot be reached at all. The test is made once per appearance and only here, before adoption: a
        // window already on the canvas is never asked again, whatever it turns into.
        id subrole=subroles[wid];
        if(subrole==NSNull.null&&![self.unlisted containsObject:wid]){[self.unlisted addObject:wid];again=YES;continue;}
        BOOL floating=self.nativePanels&&[levels[wid]integerValue]==NSFloatingWindowLevel;
        window.displayFixed=floating&&[subrole isEqual:(__bridge NSString *)kAXFloatingWindowSubrole];
        // Utility panels have an explicit AX role and keep their native window
        // level. Do not guess a panel from a title, size or failed AX response.
        BOOL real=floating?window.displayFixed:([subrole isKindOfClass:NSString.class]?DWWindowManagerIsToplevelSubrole(subrole):window.title.length||(window.frame.size.width>=200&&window.frame.size.height>=150));
        // An unavailable title is not an authored "Untitled" document. During
        // startup that invented name could bind a different same-app saved slot.
        // Keep an otherwise eligible native candidate unoffered until CG or AX
        // supplies a string; a successfully read empty string is still known.
        if(self.native&&real&&window.title==nil){
            again=YES;NSMutableDictionary *ticket=self.titleRetries[wid];
            if(ticket&&ticket==tickets[wid]){ticket[@"deadline"]=@(NSProcessInfo.processInfo.systemUptime+2);[self requestDiscoveryAfter:2];}
            else [self requestDiscoveryAfter:0];
            continue;
        }
        [self.titleRetries removeObjectForKey:wid];
        [self.nativeMetadata removeObjectForKey:wid];
        [self.offered addObject:wid];
        if(!real){
            [self declineWindow:wid pid:asked[wid]];
            // A window of a size a person would call a window is named, so that one this rule leaves out can be found and added by hand.
            if(window.frame.size.width>=200&&window.frame.size.height>=150)fprintf(stderr,"%s window \"%s\" (%gx%g) not adopted: %s. Choose windows adds it by hand.\n",(window.applicationName?:@"An application's").UTF8String,(window.title?:@"").UTF8String,window.frame.size.width,window.frame.size.height,
                [subrole isKindOfClass:NSString.class]?[NSString stringWithFormat:@"Accessibility reports it as %@, not a standard window or a dialog",subrole].UTF8String:"its application does not list it among its windows");
            continue;
        }
        // The chooser may have bound it while the read was in flight. Under --only-pid its process is asked for once more: it may have
        // ended during the read, and its pid be another's by now.
        if(DWInScope(self.scope,window.pid)&&![host managesWindow:window.window pid:window.pid])[host windowAppeared:window];
        if(self.stopped)return;
    }
    // A candidate owed its second read is read at the poll's own pace, not a reconciliation later.
    if(again)self.eager=NSProcessInfo.processInfo.systemUptime+1;
    // The first pass ends once no candidate is owed its second read.
    if(!self.completed&&!again&&!self.titleRetries.count)[self complete:content];
}
// A window that exists but was not offered is named, so that the controller keeps its
// slot waiting instead of taking the window for closed. Titled windows only, and by
// their exact title: the full list carries helper windows no slot should be kept for.
// Under --only-pid only the scope's own: another process's window is none of this run's. Native mode uses a separate
// metadata-only pass; it neither widens on-screen discovery nor requests capture permission.
- (void)complete:(SCShareableContent *)content {
    if(self.native){
        self.reading=YES;NSDictionary *scope=self.scope;NSSet *offered=self.offered.copy;NSInteger panelLevel=self.testPanelWindowLevel;__weak DWWindowManager *weak=self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *why=nil;NSArray *records=DWWindowManagerPreservedWindows(scope,offered,panelLevel,&why);
            dispatch_async(dispatch_get_main_queue(),^{DWWindowManager *manager=weak;if(!manager||manager.stopped)return;manager.reading=NO;
                if(!records){manager.retry=NSProcessInfo.processInfo.systemUptime+2;manager.requested=[NSSet set];[manager.host discoveryFailed:why];return;}
                NSMutableArray *present=[NSMutableArray array];
                for(NSDictionary *record in records)if(![manager.offered containsObject:record[@"window"]]&&![manager.host managesWindow:[record[@"window"]unsignedIntValue] pid:[record[@"pid"]intValue]])
                    [present addObject:@{@"bundle_id":record[@"bundle_id"],@"title":record[@"title"]}];
                manager.completed=YES;[manager.host discoveryCompleted:present];
            });
        });return;
    }
    NSMutableArray<NSDictionary *> *present=[NSMutableArray array];id<DWWindowHost> host=self.host;
    for(SCWindow *w in content.windows){
        pid_t pid=w.owningApplication.processID;NSString *bundle=w.owningApplication.bundleIdentifier;
        BOOL testPanel=self.scope&&self.testPanelWindowLevel>0&&w.windowLayer==self.testPanelWindowLevel;
        if((w.windowLayer!=0&&!testPanel)||pid==getpid()||w.frame.size.width<40||w.frame.size.height<40||!w.title.length||!bundle.length||[self.offered containsObject:@(w.windowID)]||!DWInScope(self.scope,pid))continue;
        if([NSRunningApplication runningApplicationWithProcessIdentifier:pid].activationPolicy!=NSApplicationActivationPolicyRegular||[host managesWindow:w.windowID pid:pid])continue;
        [present addObject:@{@"bundle_id":bundle,@"title":w.title}];
    }
    self.completed=YES;[host discoveryCompleted:present];
}
@end
