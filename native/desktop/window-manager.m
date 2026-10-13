// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/handlers/xdg_shell.rs (new_toplevel, toplevel_destroyed: every toplevel is
// managed from the moment it exists), src/handlers/compositor.rs (a new window is
// placed on its first sized commit, not before), src/input/actions.rs (CloseWindow:
// send_close to the focused client) and src/state/suspended.rs (relaunch_suspended:
// resolve the app afresh, report one that no longer resolves). New implementation
// over the macOS window list, ScreenCaptureKit, Accessibility and NSWorkspace; the
// placement, matching and focus rules stay in the controller.
// Event-driven tracking is adapted from koekeishiya/yabai dd845723416f5fe92af49fad5ebab00369e07edd (MIT), src/event_loop.c:
// WINDOW_CREATED, WINDOW_DEMINIMIZED and APPLICATION_VISIBLE look for the window at once, APPLICATION_LAUNCHED for all of an
// application's. window-events.h has the observers and the rest of the provenance. Here creation hints coalesce into the
// host's single-flight worker observation; existing bound-window events are delivered to the host immediately.
#import "window-manager.h"
#import "window-events.h"
#import "../focus/focus.h"
#import <AppKit/AppKit.h>
#include <dlfcn.h>
// A candidate is offered once its bounds have held this long. The idle poll comes
// every 80 ms, so successive completed observations normally satisfy this delay.
static const NSTimeInterval still=.05;
@interface DWWindowManager () <DWWindowEventSink>
@property (weak) id<DWWindowHost> host;
@property DWWindowEvents *events;
@property NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope;
@property (readwrite) BOOL capturing;
// On-screen candidates already offered, found bound, or given up on.
@property NSMutableSet<NSNumber *> *offered;
// Candidates one read did not list: a second miss ends the asking.
@property NSMutableSet<NSNumber *> *missed;
// Candidates their application answered for without listing them among its windows: each is asked about once more.
// Its own count, not `missed`: a window the shareable windows missed first is still owed that second look.
@property NSMutableSet<NSNumber *> *unlisted;
// The previous pass's candidate bounds, by window number, and when each window was first seen with them.
@property NSDictionary<NSNumber *,NSDictionary *> *bounds;
@property NSDictionary<NSNumber *,NSNumber *> *since;
// The candidates of the last read, until it succeeds.
@property NSSet<NSNumber *> *requested;
// When each world window last had a placement.
@property NSMutableDictionary<NSNumber *,NSNumber *> *placed;
// When the first pass began; when a read that failed is tried again, 0 when none is owed; when the next reconciliation is
// due; and until when the poll keeps its own pace although the observers are in place.
@property NSTimeInterval began,retry,next,eager;
@property NSTimer *discoveryTimer;
@property NSTimeInterval discoveryDeadline;
@property BOOL reading, completed, stopped;
@end
// Upstream manages toplevels and their dialogs (src/handlers/xdg_shell.rs: new_toplevel), never a popup, a tooltip or a helper
// surface, which Wayland tells apart by role. A Mac window has no such role in the window list: a normal-layer window of a regular
// application may be a browser's status bubble or an editor's completion list. Accessibility has the nearest thing, the window's
// subrole. For each candidate {window number: pid}: the subrole its application reports for it; NSNull when the application answered
// and does not count it among its windows; nothing when Accessibility could not say (no access, an application that did not answer in
// time, a window that gave no subrole). Read-only. Any thread: the lookup talks to every candidate's application, so it runs off the
// main thread. The window number of an Accessibility element is copyWindow's lookup below, with its provenance.
// `titles`, when given, takes each listed window's Accessibility title as well: a run that cannot read the shareable windows has
// no other. nil in every run that can, whose Accessibility traffic is then what it was.
static NSDictionary<NSNumber *,id> *windowSubroles(NSDictionary<NSNumber *,NSNumber *> *asked,NSMutableDictionary<NSNumber *,NSString *> *titles) {
    NSMutableDictionary<NSNumber *,id> *subroles=[NSMutableDictionary dictionary];
    AXError (*get)(AXUIElementRef,uint32_t *)=(AXError (*)(AXUIElementRef,uint32_t *))dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    if(!AXIsProcessTrusted()||!get)return subroles;
    for(NSNumber *pid in [NSSet setWithArray:asked.allValues]){
        AXUIElementRef app=AXUIElementCreateApplication(pid.intValue);AXUIElementSetMessagingTimeout(app,.1);CFTypeRef list=NULL;
        AXError error=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&list);CFRelease(app);
        if(error||!list||CFGetTypeID(list)!=CFArrayGetTypeID()){if(list)CFRelease(list);continue;}
        BOOL complete=YES;NSMutableSet<NSNumber *> *listed=[NSMutableSet set];
        for(CFIndex n=0;n<CFArrayGetCount(list);n++){
            AXUIElementRef w=(AXUIElementRef)CFArrayGetValueAtIndex(list,n);uint32_t wid=0;
            // A window that does not answer may be any of this application's candidates: none of them is then taken for unlisted.
            if(CFGetTypeID(w)!=AXUIElementGetTypeID()||AXUIElementSetMessagingTimeout(w,.1)||get(w,&wid)){complete=NO;continue;}
            if(![asked[@(wid)]isEqual:pid])continue;
            [listed addObject:@(wid)];CFTypeRef subrole=NULL;
            if(!AXUIElementCopyAttributeValue(w,kAXSubroleAttribute,&subrole)&&subrole&&CFGetTypeID(subrole)==CFStringGetTypeID())subroles[@(wid)]=[(__bridge NSString *)subrole copy];
            if(subrole)CFRelease(subrole);
            if(!titles)continue;
            CFTypeRef title=NULL;if(!AXUIElementCopyAttributeValue(w,kAXTitleAttribute,&title)&&title&&CFGetTypeID(title)==CFStringGetTypeID())titles[@(wid)]=[(__bridge NSString *)title copy];
            if(title)CFRelease(title);
        }
        CFRelease(list);
        if(complete)for(NSNumber *wid in asked)if([asked[wid]isEqual:pid]&&![listed containsObject:wid])subroles[wid]=NSNull.null;
    }
    return subroles;
}
// A real window by that reading: a standard window or a dialog.
static BOOL toplevelSubrole(NSString *subrole) { return [@[(__bridge NSString *)kAXStandardWindowSubrole,(__bridge NSString *)kAXDialogSubrole,(__bridge NSString *)kAXSystemDialogSubrole]containsObject:subrole]; }
@implementation DWWindowCandidate
+ (instancetype)candidateWithShareable:(SCWindow *)shareable {
    DWWindowCandidate *candidate=[self new];candidate.pid=shareable.owningApplication.processID;candidate.window=shareable.windowID;candidate.bundleIdentifier=shareable.owningApplication.bundleIdentifier;
    candidate.applicationName=shareable.owningApplication.applicationName;candidate.title=shareable.title;candidate.frame=shareable.frame;candidate.shareable=shareable;return candidate;
}
@end
@implementation DWWindowManager
+ (instancetype)managerWithHost:(id<DWWindowHost>)host scope:(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *)scope mode:(DWWindowDiscoveryMode)mode {
    if(mode!=DWWindowDiscoveryModeCaptureOverlay&&mode!=DWWindowDiscoveryModeNativePresentation)return nil;
    BOOL native=mode==DWWindowDiscoveryModeNativePresentation;
    BOOL capturing=!native&&CGPreflightScreenCaptureAccess();if(!scope&&!native&&!capturing)return nil;
    DWWindowManager *manager=[self new];manager.scope=[scope copy];manager.capturing=capturing;manager.host=host;manager.offered=[NSMutableSet set];manager.missed=[NSMutableSet set];manager.unlisted=[NSMutableSet set];manager.placed=[NSMutableDictionary dictionary];
    manager.events=[[DWWindowEvents alloc]initWithSink:manager scope:manager.scope];return manager;
}
- (BOOL)live { return self.events.live; }
- (BOOL)reconciliationDue {
    if(self.stopped)return NO;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    return !self.events.live||now>=self.next||!self.completed||now<self.eager;
}
- (BOOL)pollWithWindowRecords:(NSArray<NSDictionary *> *)records {
    if(self.stopped||!records)return NO;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;BOOL live=self.events.live,due=now>=self.next;
    if(due){self.next=now+1;[self.events reconcile];}
    [self passRecords:records];return due||!live;
}
- (void)requestDiscoveryAfter:(NSTimeInterval)delay {
    if(self.stopped||![self.host respondsToSelector:@selector(windowDiscoveryRequested)])return;
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+MAX(0,delay);
    if(self.discoveryTimer&&self.discoveryDeadline<=deadline)return;
    [self.discoveryTimer invalidate];self.discoveryDeadline=deadline;__weak DWWindowManager *weak=self;
    self.discoveryTimer=[NSTimer timerWithTimeInterval:MAX(0,delay) repeats:NO block:^(NSTimer *timer){
        DWWindowManager *manager=weak;if(!manager||manager.stopped||manager.discoveryTimer!=timer)return;
        manager.discoveryTimer=nil;manager.discoveryDeadline=0;[manager.host windowDiscoveryRequested];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.discoveryTimer forMode:NSRunLoopCommonModes];
}
// One completed worker read serves the whole discovery set. No event starts a
// second global enumeration while another application's observation is in flight.
- (void)passRecords:(NSArray<NSDictionary *> *)list {
    if(self.stopped)return;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;id<DWWindowHost> host=self.host;if(!self.began)self.began=now;
    NSMutableDictionary<NSNumber *,NSDictionary *> *bounds=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *wanted=[NSMutableDictionary dictionary],*regular=[NSMutableDictionary dictionary],*since=[NSMutableDictionary dictionary],*scoped=[NSMutableDictionary dictionary];NSMutableArray<NSNumber *> *front=[NSMutableArray array];BOOL moving=NO;NSTimeInterval stabilityDelay=still;
    for(NSDictionary *w in list){
        NSNumber *wid=w[(id)kCGWindowNumber],*pid=w[(id)kCGWindowOwnerPID];NSDictionary *b=w[(id)kCGWindowBounds];CGRect r=CGRectZero;
        NSInteger level=[w[(id)kCGWindowLayer]integerValue];BOOL benchmark=self.scope&&self.benchmarkWindowLevel>0&&level==self.benchmarkWindowLevel;
        if(![wid isKindOfClass:NSNumber.class]||![pid isKindOfClass:NSNumber.class]||pid.intValue==getpid())continue;
        // --only-pid: a window of any other process leaves no trace here. It is neither timed nor wanted, so nothing below asks about it.
        if(self.scope){NSNumber *within=scoped[pid];if(!within)within=scoped[pid]=@(DWInScope(self.scope,pid.intValue));if(!within.boolValue)continue;}
        BOOL panel=self.nativePanels&&level==NSFloatingWindowLevel;
        if(level!=0&&!benchmark&&!panel)continue;
        if(![b isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)b,&r)||r.size.width<40||r.size.height<40)continue;
        NSNumber *held=[self.bounds[wid]isEqual:b]?self.since[wid]:nil;bounds[wid]=b;since[wid]=held?:@(now);
        if([self.offered containsObject:wid])continue;
        NSNumber *policy=regular[pid];
        if(!policy)policy=regular[pid]=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue].activationPolicy==NSApplicationActivationPolicyRegular?@YES:@NO;
        if(!policy.boolValue)continue;
        if([host managesWindow:wid.unsignedIntValue pid:pid.intValue]){[self.offered addObject:wid];continue;}
        // Upstream places a window on its first sized commit. A window still being
        // sized is not offered: its world size is the source rectangle it is offered with.
        if(!held||now-held.doubleValue<still){moving=YES;stabilityDelay=MIN(stabilityDelay,held?still-(now-held.doubleValue):still);continue;}
        wanted[wid]=pid;[front addObject:wid];
    }
    // Leaving the screen ends a window's turn; coming back is a new appearance.
    NSSet<NSNumber *> *present=[NSSet setWithArray:bounds.allKeys];self.bounds=bounds;self.since=since;[self.offered intersectSet:present];[self.missed intersectSet:present];[self.unlisted intersectSet:present];
    // The same 50 ms hold, followed by a fresh worker read at its earliest due
    // deadline. Polling remains the fallback for a host without this callback.
    if(moving){self.eager=now+1;[self requestDiscoveryAfter:stabilityDelay];}
    else {[self.discoveryTimer invalidate];self.discoveryTimer=nil;self.discoveryDeadline=0;}
    // The first pass waits, two seconds at most, until every window holds still, so that one read offers them all.
    if(!self.completed&&moving&&now-self.began<2)return;
    if(self.reading){if(wanted.count)self.eager=now+1;return;}
    // A read that failed is tried again after about two seconds, while access still stands: this never asks for it.
    if(self.retry&&now>=self.retry){self.retry=0;if(CGPreflightScreenCaptureAccess())self.requested=nil;}
    // The first pass reads the shareable windows even with nothing to offer: it must name the windows that are not on screen.
    if(!wanted.count&&(self.completed||self.requested))return;
    NSSet<NSNumber *> *ids=[NSSet setWithArray:wanted.allKeys];if(self.requested&&[ids isEqualToSet:self.requested])return;
    self.reading=YES;self.requested=ids;__weak DWWindowManager *weak=self;NSDictionary<NSNumber *,NSNumber *> *asked=[wanted copy];
    NSMutableDictionary *levels=[NSMutableDictionary dictionary];for(NSDictionary *row in list)if(asked[row[(id)kCGWindowNumber]])levels[row[(id)kCGWindowNumber]]=row[(id)kCGWindowLayer];
    NSMutableDictionary<NSNumber *,NSDictionary *> *requestedBounds=[NSMutableDictionary dictionary];for(NSNumber *wid in asked)requestedBounds[wid]=bounds[wid];NSDictionary *basis=requestedBounds.copy;
    if(self.capturing){[SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){NSDictionary<NSNumber *,id> *subroles=content?windowSubroles(asked,nil):nil;dispatch_async(dispatch_get_main_queue(),^{[weak read:content error:error asked:asked front:front subroles:subroles titles:nil frames:nil levels:levels basis:basis];});}];return;}
    // Native presentation or a scoped overlay without Screen Recording access: shareable windows are not asked for, so nothing can prompt. What they
    // would have said of a candidate is read from the window list (this pass's bounds) and from Accessibility, off the main thread like the subroles.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSMutableDictionary<NSNumber *,NSString *> *titles=[NSMutableDictionary dictionary];NSDictionary<NSNumber *,id> *subroles=windowSubroles(asked,titles);dispatch_async(dispatch_get_main_queue(),^{[weak read:nil error:nil asked:asked front:front subroles:subroles titles:titles frames:basis levels:levels basis:basis];});});
}
// `front` is the window list's own order, front to back. `subroles` is windowSubroles' answer for `asked`, read before this turn of the main queue.
// `titles` and `frames` stand in for the shareable windows in a run that does not read them (`capturing` NO): `content` is then nil and no failure.
- (void)read:(SCShareableContent *)content error:(NSError *)error asked:(NSDictionary<NSNumber *,NSNumber *> *)asked front:(NSArray<NSNumber *> *)front subroles:(NSDictionary<NSNumber *,id> *)subroles titles:(NSDictionary<NSNumber *,NSString *> *)titles frames:(NSDictionary<NSNumber *,NSDictionary *> *)frames levels:(NSDictionary<NSNumber *,NSNumber *> *)levels basis:(NSDictionary<NSNumber *,NSDictionary *> *)basis {
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
        if(![self.bounds[wid]isEqual:basis[wid]]||!held||NSProcessInfo.processInfo.systemUptime-held.doubleValue<still){again=YES;continue;}
        DWWindowCandidate *window=found[wid];
        // A window the read did not list yet is asked for once more, then left until it next comes on screen.
        if(!window){if([self.missed containsObject:wid])[self.offered addObject:wid];else {[self.missed addObject:wid];again=YES;}continue;}
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
        BOOL real=floating?window.displayFixed:([subrole isKindOfClass:NSString.class]?toplevelSubrole(subrole):window.title.length||(window.frame.size.width>=200&&window.frame.size.height>=150));
        [self.offered addObject:wid];
        if(!real){
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
    if(!self.completed&&!again)[self complete:content];
}
// A window that exists but was not offered is named, so that the controller keeps its
// slot waiting instead of taking the window for closed. Titled windows only, and by
// their exact title: the full list carries helper windows no slot should be kept for.
// Under --only-pid only the scope's own: another process's window is none of this run's. A run that does not read the
// shareable windows has no `content` and names none, so the controller keeps no slot waiting for a window off screen.
- (void)complete:(SCShareableContent *)content {
    NSMutableArray<NSDictionary *> *present=[NSMutableArray array];id<DWWindowHost> host=self.host;
    for(SCWindow *w in content.windows){
        pid_t pid=w.owningApplication.processID;NSString *bundle=w.owningApplication.bundleIdentifier;
        BOOL benchmark=self.scope&&self.benchmarkWindowLevel>0&&w.windowLayer==self.benchmarkWindowLevel;
        if((w.windowLayer!=0&&!benchmark)||pid==getpid()||w.frame.size.width<40||w.frame.size.height<40||!w.title.length||!bundle.length||[self.offered containsObject:@(w.windowID)]||!DWInScope(self.scope,pid))continue;
        if([NSRunningApplication runningApplicationWithProcessIdentifier:pid].activationPolicy!=NSApplicationActivationPolicyRegular||[host managesWindow:w.windowID pid:pid])continue;
        [present addObject:@{@"bundle_id":bundle,@"title":w.title}];
    }
    self.completed=YES;[host discoveryCompleted:present];
}
- (BOOL)capture:(NSNumber *)window placed:(BOOL)placed {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(placed){self.placed[window]=@(now);return YES;}
    NSNumber *last=self.placed[window];return last&&now-last.doubleValue<2;
}
- (void)forget:(NSNumber *)window { if(window)[self.placed removeObjectForKey:window]; }
- (void)stop { self.stopped=YES;[self.discoveryTimer invalidate];self.discoveryTimer=nil;self.discoveryDeadline=0;self.host=nil;[self.events stop];self.events=nil; }
// DWWindowEventSink. Creation/appearance hints coalesce into the host's next
// worker observation. Bound-window and family invalidations still arrive now.
- (void)windowsChanged:(pid_t)pid { if(self.stopped)return;self.eager=NSProcessInfo.processInfo.systemUptime+1;if([self.host respondsToSelector:@selector(windowFamilyChanged:)])[self.host windowFamilyChanged:pid]; }
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;
    // A candidate not offered yet needs a discovery pass. A bound window is the host's to look at now.
    if(window&&![self.offered containsObject:@(window)])self.eager=NSProcessInfo.processInfo.systemUptime+1;
    [self.host windowChanged:window pid:pid];
}
// The window number may come back on screen, when its application kept the window object and shows it again. That is
// then a new appearance, whenever the next pass comes.
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;NSNumber *wid=@(window);[self.offered removeObject:wid];[self.missed removeObject:wid];[self.unlisted removeObject:wid];
    [self.host windowDestroyed:window pid:pid];
}
- (void)focusChanged { if(!self.stopped)[self.host focusChanged]; }
@end
// The Accessibility element of exactly one window: the lookup of resolve() in
// native/focus/focus.m, which is private to that file. Every window of the process
// is asked for its window number; one match owned by that process is required, and
// any window that does not answer refuses the whole lookup. Signature provenance as
// there: yabai dd845723416f5fe92af49fad5ebab00369e07edd, src/misc/extern.h:8.
typedef AXError (*GetWindow)(AXUIElementRef,uint32_t *);
static AXUIElementRef copyWindow(DWFocusIdentity i) {
    GetWindow get=(GetWindow)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");if(!get)return NULL;
    AXUIElementRef app=AXUIElementCreateApplication(i.pid);AXUIElementSetMessagingTimeout(app,.1);CFTypeRef list=NULL;
    AXError error=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&list);CFRelease(app);
    if(error||!list||CFGetTypeID(list)!=CFArrayGetTypeID()){if(list)CFRelease(list);return NULL;}
    AXUIElementRef found=NULL;int matches=0;BOOL valid=YES;
    for(CFIndex n=0;n<CFArrayGetCount(list);n++){
        AXUIElementRef w=(AXUIElementRef)CFArrayGetValueAtIndex(list,n);uint32_t wid=0;pid_t pid=0;
        if(CFGetTypeID(w)!=AXUIElementGetTypeID()||AXUIElementSetMessagingTimeout(w,.1)||get(w,&wid)){valid=NO;break;}
        if(wid!=i.window)continue;
        if(AXUIElementGetPid(w,&pid)||pid!=i.pid){valid=NO;break;}
        matches++;if(!found)found=(AXUIElementRef)CFRetain(w);
    }
    CFRelease(list);
    if(valid&&matches==1&&dw_focus_owner(i,NULL))return found;
    if(found)CFRelease(found);return NULL;
}
NSString *DWCloseWindow(NSDictionary *value) { @autoreleasepool {
    DWFocusIdentity i={[value[@"pid"]intValue],[value[@"birth_sec"]unsignedLongLongValue],[value[@"birth_usec"]unsignedLongLongValue],[value[@"wid"]unsignedIntValue]};
    if(!AXIsProcessTrusted())return @"Accessibility access is required";
    if(!dw_focus_owner(i,NULL))return @"the window is gone or is no longer the one that was bound";
    AXUIElementRef window=copyWindow(i);if(!window)return @"Accessibility did not find exactly that window";
    CFTypeRef button=NULL;AXError error=AXUIElementCopyAttributeValue(window,kAXCloseButtonAttribute,&button);CFRelease(window);
    if(error||!button||CFGetTypeID(button)!=AXUIElementGetTypeID()){if(button)CFRelease(button);return @"the window has no close button";}
    // The identity once more, immediately before the only mutation.
    if(!dw_focus_owner(i,NULL)){CFRelease(button);return @"the window is gone or is no longer the one that was bound";}
    AXUIElementSetMessagingTimeout((AXUIElementRef)button,1);error=AXUIElementPerformAction((AXUIElementRef)button,kAXPressAction);CFRelease(button);
    // No answer in time is not a refusal: an application that asks about unsaved changes answers late.
    return !error||error==kAXErrorCannotComplete?nil:[NSString stringWithFormat:@"its close button could not be pressed (AXError %d)",(int)error];
} }
void DWLaunchApplication(NSString *bundleIdentifier,void (^failed)(NSString *reason)) {
    NSURL *url=bundleIdentifier.length?[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleIdentifier]:nil;
    if(!url){dispatch_async(dispatch_get_main_queue(),^{failed([NSString stringWithFormat:@"no application with bundle identifier \"%@\" is installed",bundleIdentifier?:@""]);});return;}
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:^(NSRunningApplication *app,NSError *error){(void)app;if(error)dispatch_async(dispatch_get_main_queue(),^{failed(error.localizedDescription);});}];
}
