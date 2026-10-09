// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/handlers/xdg_shell.rs (new_toplevel, toplevel_destroyed: every toplevel is
// managed from the moment it exists), src/handlers/compositor.rs (a new window is
// placed on its first sized commit, not before), src/input/actions.rs (CloseWindow:
// send_close to the focused client) and src/state/suspended.rs (relaunch_suspended:
// resolve the app afresh, report one that no longer resolves). New implementation
// over the macOS window list, ScreenCaptureKit, Accessibility and NSWorkspace; the
// placement, matching and focus rules stay in the controller.
#import "window-manager.h"
#import "../focus/focus.h"
#import <AppKit/AppKit.h>
#include <dlfcn.h>
@interface DWWindowManager ()
@property (weak) id<DWWindowHost> host;
// On-screen candidates already offered, found bound, or given up on.
@property NSMutableSet<NSNumber *> *offered;
// Candidates one read did not list: a second miss ends the asking.
@property NSMutableSet<NSNumber *> *missed;
// The previous poll's candidate bounds, by window number.
@property NSDictionary<NSNumber *,NSDictionary *> *bounds;
// The candidates of the last read, until it succeeds.
@property NSSet<NSNumber *> *requested;
// When each world window last had a placement.
@property NSMutableDictionary<NSNumber *,NSNumber *> *placed;
// The poll at which a read that failed is tried again; 0 when none is owed.
@property NSUInteger polls,retry;
@property BOOL reading, completed, stopped;
@end
@implementation DWWindowManager
+ (instancetype)managerWithHost:(id<DWWindowHost>)host {
    if(!CGPreflightScreenCaptureAccess())return nil;
    DWWindowManager *manager=[self new];manager.host=host;manager.offered=[NSMutableSet set];manager.missed=[NSMutableSet set];manager.placed=[NSMutableDictionary dictionary];return manager;
}
- (void)poll {
    if(self.stopped)return;self.polls++;id<DWWindowHost> host=self.host;
    NSArray<NSDictionary *> *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));if(!list)return;
    NSMutableDictionary<NSNumber *,NSDictionary *> *bounds=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *wanted=[NSMutableDictionary dictionary],*regular=[NSMutableDictionary dictionary];NSMutableArray<NSNumber *> *front=[NSMutableArray array];BOOL moving=NO;
    for(NSDictionary *w in list){
        NSNumber *wid=w[(id)kCGWindowNumber],*pid=w[(id)kCGWindowOwnerPID];NSDictionary *b=w[(id)kCGWindowBounds];CGRect r=CGRectZero;
        if(![wid isKindOfClass:NSNumber.class]||![pid isKindOfClass:NSNumber.class]||[w[(id)kCGWindowLayer]intValue]!=0||pid.intValue==getpid())continue;
        if(![b isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)b,&r)||r.size.width<40||r.size.height<40)continue;
        bounds[wid]=b;if([self.offered containsObject:wid])continue;
        NSNumber *policy=regular[pid];
        if(!policy)policy=regular[pid]=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue].activationPolicy==NSApplicationActivationPolicyRegular?@YES:@NO;
        if(!policy.boolValue)continue;
        if([host managesWindow:wid.unsignedIntValue pid:pid.intValue]){[self.offered addObject:wid];continue;}
        // Upstream places a window on its first sized commit. A window still being
        // sized is not offered: its world size is the source rectangle it is offered with.
        if(![self.bounds[wid]isEqual:b]){moving=YES;continue;}
        wanted[wid]=pid;[front addObject:wid];
    }
    // Leaving the screen ends a window's turn; coming back is a new appearance.
    NSSet<NSNumber *> *present=[NSSet setWithArray:bounds.allKeys];self.bounds=bounds;[self.offered intersectSet:present];[self.missed intersectSet:present];
    // The first pass waits, two seconds at most, until every window holds still, so that one read offers them all.
    if(!self.completed&&moving&&self.polls<25)return;
    if(self.reading)return;
    // A read that failed is tried again after about two seconds, while access still stands: this never asks for it.
    if(self.retry&&self.polls>=self.retry){self.retry=0;if(CGPreflightScreenCaptureAccess())self.requested=nil;}
    // The first pass reads the shareable windows even with nothing to offer: it must name the windows that are not on screen.
    if(!wanted.count&&(self.completed||self.requested))return;
    NSSet<NSNumber *> *ids=[NSSet setWithArray:wanted.allKeys];if(self.requested&&[ids isEqualToSet:self.requested])return;
    self.reading=YES;self.requested=ids;__weak DWWindowManager *weak=self;NSDictionary<NSNumber *,NSNumber *> *asked=[wanted copy];
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){dispatch_async(dispatch_get_main_queue(),^{[weak read:content error:error asked:asked front:front];});}];
}
// `front` is the window list's own order, front to back.
- (void)read:(SCShareableContent *)content error:(NSError *)error asked:(NSDictionary<NSNumber *,NSNumber *> *)asked front:(NSArray<NSNumber *> *)front {
    if(self.stopped)return;self.reading=NO;id<DWWindowHost> host=self.host;
    // `requested` stays: the same candidates are not read again at once, so a failure cannot loop.
    if(!content){self.retry=self.polls+25;[host discoveryFailed:error.localizedDescription?:@"the shareable windows are unavailable"];return;}
    self.requested=nil;self.retry=0;NSMutableDictionary<NSNumber *,SCWindow *> *found=[NSMutableDictionary dictionary];BOOL again=NO;
    for(SCWindow *window in content.windows){NSNumber *wid=@(window.windowID);if(asked[wid]&&asked[wid].intValue==window.owningApplication.processID&&!found[wid])found[wid]=window;}
    // Back to front: the controller raises each window as it maps, so the canvas stacks them as the desktop does.
    for(NSNumber *wid in front.reverseObjectEnumerator){
        SCWindow *window=found[wid];
        // A window the read did not list yet is asked for once more, then left until it next comes on screen.
        if(!window){if([self.missed containsObject:wid])[self.offered addObject:wid];else {[self.missed addObject:wid];again=YES;}continue;}
        [self.offered addObject:wid];
        // The chooser may have bound it while the read was in flight.
        if(![host managesWindow:window.windowID pid:window.owningApplication.processID])[host windowAppeared:window];
        if(self.stopped)return;
    }
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
- (void)stop { self.stopped=YES;self.host=nil; }
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
