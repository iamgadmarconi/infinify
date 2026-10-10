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
// application's. window-events.h has the observers and the rest of the provenance. Here an event runs the pass the poll runs.
#import "window-manager.h"
#import "window-events.h"
#import "../focus/focus.h"
#import <AppKit/AppKit.h>
#include <dlfcn.h>
// A candidate is offered once its bounds have held this long. The idle poll comes every 80 ms, so from one poll to the
// next is long enough, as it always was; a pass an event made counts as the first look, so the next poll may offer.
static const NSTimeInterval still=.05;
@interface DWWindowManager () <DWWindowEventSink>
@property (weak) id<DWWindowHost> host;
@property DWWindowEvents *events;
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
@property BOOL reading, completed, stopped;
@end
// Upstream manages toplevels and their dialogs (src/handlers/xdg_shell.rs: new_toplevel), never a popup, a tooltip or a helper
// surface, which Wayland tells apart by role. A Mac window has no such role in the window list: a normal-layer window of a regular
// application may be a browser's status bubble or an editor's completion list. Accessibility has the nearest thing, the window's
// subrole. For each candidate {window number: pid}: the subrole its application reports for it; NSNull when the application answered
// and does not count it among its windows; nothing when Accessibility could not say (no access, an application that did not answer in
// time, a window that gave no subrole). Read-only. Any thread: the lookup talks to every candidate's application, so it runs off the
// main thread. The window number of an Accessibility element is copyWindow's lookup below, with its provenance.
static NSDictionary<NSNumber *,id> *windowSubroles(NSDictionary<NSNumber *,NSNumber *> *asked) {
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
        }
        CFRelease(list);
        if(complete)for(NSNumber *wid in asked)if([asked[wid]isEqual:pid]&&![listed containsObject:wid])subroles[wid]=NSNull.null;
    }
    return subroles;
}
// A real window by that reading: a standard window or a dialog.
static BOOL toplevelSubrole(NSString *subrole) { return [@[(__bridge NSString *)kAXStandardWindowSubrole,(__bridge NSString *)kAXDialogSubrole,(__bridge NSString *)kAXSystemDialogSubrole]containsObject:subrole]; }
@implementation DWWindowManager
+ (instancetype)managerWithHost:(id<DWWindowHost>)host {
    if(!CGPreflightScreenCaptureAccess())return nil;
    DWWindowManager *manager=[self new];manager.host=host;manager.offered=[NSMutableSet set];manager.missed=[NSMutableSet set];manager.unlisted=[NSMutableSet set];manager.placed=[NSMutableDictionary dictionary];
    manager.events=[[DWWindowEvents alloc]initWithSink:manager];return manager;
}
- (BOOL)live { return self.events.live; }
- (BOOL)poll {
    if(self.stopped)return NO;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;BOOL live=self.events.live,due=now>=self.next;
    // With the observers in place the poll is a reconciliation, one pass a second. It keeps its own pace until the first pass
    // has ended, and for a second after an event that may bring a window on screen or a pass that left a candidate owed
    // another look: the window list can show a window a moment after its application reports it.
    if(live&&!due&&self.completed&&now>=self.eager)return NO;
    if(due){self.next=now+1;[self.events reconcile];}
    [self pass:0];return due||!live;
}
// One pass over the on-screen window list. `only`: the application an event concerns, whose candidates alone are looked at;
// 0 for every application, the poll's pass.
- (void)pass:(pid_t)only {
    if(self.stopped)return;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;id<DWWindowHost> host=self.host;if(!self.began)self.began=now;
    // One read must offer every window of the first pass: until it has ended every pass is whole.
    if(!self.completed)only=0;
    NSArray<NSDictionary *> *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));if(!list)return;
    NSMutableDictionary<NSNumber *,NSDictionary *> *bounds=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *wanted=[NSMutableDictionary dictionary],*regular=[NSMutableDictionary dictionary],*since=[NSMutableDictionary dictionary];NSMutableArray<NSNumber *> *front=[NSMutableArray array];BOOL moving=NO;
    for(NSDictionary *w in list){
        NSNumber *wid=w[(id)kCGWindowNumber],*pid=w[(id)kCGWindowOwnerPID];NSDictionary *b=w[(id)kCGWindowBounds];CGRect r=CGRectZero;
        if(![wid isKindOfClass:NSNumber.class]||![pid isKindOfClass:NSNumber.class]||[w[(id)kCGWindowLayer]intValue]!=0||pid.intValue==getpid())continue;
        if(![b isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)b,&r)||r.size.width<40||r.size.height<40)continue;
        NSNumber *held=[self.bounds[wid]isEqual:b]?self.since[wid]:nil;bounds[wid]=b;since[wid]=held?:@(now);
        if([self.offered containsObject:wid]||(only&&pid.intValue!=only))continue;
        NSNumber *policy=regular[pid];
        if(!policy)policy=regular[pid]=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue].activationPolicy==NSApplicationActivationPolicyRegular?@YES:@NO;
        if(!policy.boolValue)continue;
        if([host managesWindow:wid.unsignedIntValue pid:pid.intValue]){[self.offered addObject:wid];continue;}
        // Upstream places a window on its first sized commit. A window still being
        // sized is not offered: its world size is the source rectangle it is offered with.
        if(!held||now-held.doubleValue<still){moving=YES;continue;}
        wanted[wid]=pid;[front addObject:wid];
    }
    // Leaving the screen ends a window's turn; coming back is a new appearance.
    NSSet<NSNumber *> *present=[NSSet setWithArray:bounds.allKeys];self.bounds=bounds;self.since=since;[self.offered intersectSet:present];[self.missed intersectSet:present];[self.unlisted intersectSet:present];
    // A candidate that has not held still yet is looked at again at the poll's own pace, not a reconciliation later.
    if(moving)self.eager=now+1;
    // The first pass waits, two seconds at most, until every window holds still, so that one read offers them all.
    if(!self.completed&&moving&&now-self.began<2)return;
    if(self.reading){if(wanted.count)self.eager=now+1;return;}
    // A read that failed is tried again after about two seconds, while access still stands: this never asks for it.
    if(self.retry&&now>=self.retry){self.retry=0;if(CGPreflightScreenCaptureAccess())self.requested=nil;}
    // While a failed read is owed its retry an event reads nothing: only the poll's pass decides when to read again.
    if(only&&self.requested)return;
    // The first pass reads the shareable windows even with nothing to offer: it must name the windows that are not on screen.
    if(!wanted.count&&(self.completed||self.requested))return;
    NSSet<NSNumber *> *ids=[NSSet setWithArray:wanted.allKeys];if(self.requested&&[ids isEqualToSet:self.requested])return;
    self.reading=YES;self.requested=ids;__weak DWWindowManager *weak=self;NSDictionary<NSNumber *,NSNumber *> *asked=[wanted copy];
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){NSDictionary<NSNumber *,id> *subroles=content?windowSubroles(asked):nil;dispatch_async(dispatch_get_main_queue(),^{[weak read:content error:error asked:asked front:front subroles:subroles];});}];
}
// `front` is the window list's own order, front to back. `subroles` is windowSubroles' answer for `asked`, read before this turn of the main queue.
- (void)read:(SCShareableContent *)content error:(NSError *)error asked:(NSDictionary<NSNumber *,NSNumber *> *)asked front:(NSArray<NSNumber *> *)front subroles:(NSDictionary<NSNumber *,id> *)subroles {
    if(self.stopped)return;self.reading=NO;id<DWWindowHost> host=self.host;
    // `requested` stays: the same candidates are not read again at once, so a failure cannot loop.
    if(!content){self.retry=NSProcessInfo.processInfo.systemUptime+2;[host discoveryFailed:error.localizedDescription?:@"the shareable windows are unavailable"];return;}
    self.requested=nil;self.retry=0;NSMutableDictionary<NSNumber *,SCWindow *> *found=[NSMutableDictionary dictionary];BOOL again=NO;
    for(SCWindow *window in content.windows){NSNumber *wid=@(window.windowID);if(asked[wid]&&asked[wid].intValue==window.owningApplication.processID&&!found[wid])found[wid]=window;}
    // Back to front: the controller raises each window as it maps, so the canvas stacks them as the desktop does.
    for(NSNumber *wid in front.reverseObjectEnumerator){
        SCWindow *window=found[wid];
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
        BOOL real=[subrole isKindOfClass:NSString.class]?toplevelSubrole(subrole):window.title.length||(window.frame.size.width>=200&&window.frame.size.height>=150);
        [self.offered addObject:wid];
        if(!real){
            // A window of a size a person would call a window is named, so that one this rule leaves out can be found and added by hand.
            if(window.frame.size.width>=200&&window.frame.size.height>=150)fprintf(stderr,"%s window \"%s\" (%gx%g) not adopted: %s. Choose windows adds it by hand.\n",(window.owningApplication.applicationName?:@"An application's").UTF8String,(window.title?:@"").UTF8String,window.frame.size.width,window.frame.size.height,
                [subrole isKindOfClass:NSString.class]?[NSString stringWithFormat:@"Accessibility reports it as %@, not a standard window or a dialog",subrole].UTF8String:"its application does not list it among its windows");
            continue;
        }
        // The chooser may have bound it while the read was in flight.
        if(![host managesWindow:window.windowID pid:window.owningApplication.processID])[host windowAppeared:window];
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
- (void)complete:(SCShareableContent *)content {
    NSMutableArray<NSDictionary *> *present=[NSMutableArray array];id<DWWindowHost> host=self.host;
    for(SCWindow *w in content.windows){
        pid_t pid=w.owningApplication.processID;NSString *bundle=w.owningApplication.bundleIdentifier;
        if(w.windowLayer!=0||pid==getpid()||w.frame.size.width<40||w.frame.size.height<40||!w.title.length||!bundle.length||[self.offered containsObject:@(w.windowID)])continue;
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
- (void)stop { self.stopped=YES;self.host=nil;[self.events stop];self.events=nil; }
// DWWindowEventSink. An event runs the pass the poll runs, at once and for its application, and the poll then keeps its
// own pace for a second. The pass reads the window list itself, so an event repeated, or followed by the poll, finds the
// window offered, read or bound already and does nothing.
- (void)windowsChanged:(pid_t)pid { if(self.stopped)return;self.eager=NSProcessInfo.processInfo.systemUptime+1;[self pass:pid]; }
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;
    // A candidate not offered yet: its stillness counts from this change. A bound window is the host's to look at.
    if(window&&![self.offered containsObject:@(window)])[self pass:pid];
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
