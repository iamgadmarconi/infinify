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
#import "native-family.h"
#import "../focus/focus.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <libproc.h>
// Ordinary candidates wait for two stable observations. A positively identified
// standard native window may use the stricter post-AX basis check below instead.
static const NSTimeInterval still=.05;
@interface DWWindowManager () <DWWindowEventSink>
@property (weak) id<DWWindowHost> host;
@property DWWindowEvents *events;
@property NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope;
@property (readwrite) BOOL capturing;
@property BOOL native;
// On-screen candidates already offered, found bound, or given up on.
@property NSMutableSet<NSNumber *> *offered;
// The windows -windowNotAdopted: has been told of, until they leave the screen.
@property NSMutableSet<NSNumber *> *declined;
// Candidates one read did not list: a second miss ends the asking.
@property NSMutableSet<NSNumber *> *missed;
// Candidates their application answered for without listing them among its windows: each is asked about once more.
// Its own count, not `missed`: a window the shareable windows missed first is still owed that second look.
@property NSMutableSet<NSNumber *> *unlisted;
// The previous pass's candidate bounds, by window number, and when each window was first seen with them.
@property NSDictionary<NSNumber *,NSDictionary *> *bounds;
@property NSDictionary<NSNumber *,NSDictionary *> *bases;
@property NSDictionary<NSNumber *,NSNumber *> *sampled;
@property NSDictionary<NSNumber *,NSNumber *> *since;
// An unavailable native title delays only this exact appearance/basis. Each
// read owns its ticket; a fresh CG title or change hint retires that ticket so
// an older AX reply cannot put the candidate back into a two-second wait.
@property NSMutableDictionary<NSNumber *,NSMutableDictionary *> *titleRetries;
// Positive AX metadata may arrive during the native basis hold. Tickets bind
// it to one exact appearance, basis and CG-title version; negative early reads
// do not spend admission retries or invent a title.
@property NSMutableDictionary<NSNumber *,NSMutableDictionary *> *nativeMetadata;
// One direct AX creation read, independent of the global discovery/AX flight.
// Raw events retire its ticket even while their ordinary hint is coalesced.
@property NSDictionary *creationTicket;
@property BOOL creationReading;
@property CFTimeInterval nativeSampleAt;
@property NSUInteger creationTraceLines; // DEBUG only, bounded for this manager lifetime
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
// Startup preservation is not discovery/admission: these records can only keep
// an existing exact bundle/title slot waiting. In particular, the all-window
// list never supplies native candidate bases or calls windowAppeared:. Read on
// the worker, with the same login UID and exact process instance checked around
// the metadata read. Missing titles cannot be guessed from application names.
static NSArray<NSNumber *> *preservationBirth(pid_t pid) {
    struct proc_bsdinfo process={0};
    if(pid<=1||pid==getpid()||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process)||process.pbi_uid!=getuid()||
       !process.pbi_start_tvsec||process.pbi_start_tvusec>=1000000)return nil;
    return @[@(process.pbi_start_tvsec),@(process.pbi_start_tvusec)];
}
static NSArray<NSDictionary *> *nativePreservedWindows(NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope,NSSet<NSNumber *> *offered,NSInteger benchmark,NSString *__autoreleasing *why) {
    NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    if(!rows){if(why)*why=@"the all-window metadata for saved slots is unavailable";return nil;}
    NSMutableDictionary *births=[NSMutableDictionary dictionary],*bundles=[NSMutableDictionary dictionary],*candidates=[NSMutableDictionary dictionary],*asked=[NSMutableDictionary dictionary],*titles=[NSMutableDictionary dictionary];
    for(NSDictionary *row in rows){
        NSNumber *wid=row[(id)kCGWindowNumber],*pid=row[(id)kCGWindowOwnerPID],*level=row[(id)kCGWindowLayer];CGRect frame=CGRectZero;
        if(![wid isKindOfClass:NSNumber.class]||!wid.unsignedIntValue||![pid isKindOfClass:NSNumber.class]||pid.intValue<=1||pid.intValue==getpid()||[offered containsObject:wid]||(scope&&!scope[pid]))continue;
        if(![level isKindOfClass:NSNumber.class]||(level.integerValue!=0&&!(scope&&benchmark>0&&level.integerValue==benchmark)))continue;
        NSDictionary *bounds=row[(id)kCGWindowBounds];
        if(![bounds isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&frame)||
           !isfinite(frame.origin.x)||!isfinite(frame.origin.y)||!isfinite(frame.size.width)||!isfinite(frame.size.height)||frame.size.width<40||frame.size.height<40)continue;
        id born=births[pid];if(!born){born=preservationBirth(pid.intValue)?:NSNull.null;births[pid]=born;}
        if(born==NSNull.null||(scope&&![scope[pid]isEqual:born]))continue;
        id bundle=bundles[pid];if(!bundle){NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
            bundle=app&&app.activationPolicy==NSApplicationActivationPolicyRegular&&app.bundleIdentifier.length?app.bundleIdentifier:NSNull.null;bundles[pid]=bundle;}
        if(bundle==NSNull.null)continue;
        candidates[wid]=@{@"pid":pid,@"birth":born,@"bundle_id":bundle};
        NSString *title=row[(id)kCGWindowName];if([title isKindOfClass:NSString.class]&&title.length)titles[wid]=title;
        else asked[wid]=pid;
    }
    // AX can name a minimized window when the public list omits its title.
    // This is the existing read-only lookup, never a raise or a Space change.
    if(asked.count)windowSubroles(asked,titles);
    NSArray *current=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    if(!current){if(why)*why=@"the saved-slot window metadata could not be revalidated";return nil;}
    NSMutableDictionary *owners=[NSMutableDictionary dictionary],*freshBirths=[NSMutableDictionary dictionary];
    for(NSDictionary *row in current){NSNumber *wid=row[(id)kCGWindowNumber],*pid=row[(id)kCGWindowOwnerPID];
        if([wid isKindOfClass:NSNumber.class]&&[pid isKindOfClass:NSNumber.class])owners[wid]=pid;}
    NSMutableArray *present=[NSMutableArray array];
    for(NSNumber *wid in candidates){NSDictionary *candidate=candidates[wid];NSNumber *pid=candidate[@"pid"];NSString *title=titles[wid];
        if(!title.length||![owners[wid]isEqual:pid])continue;
        id born=freshBirths[pid];if(!born){born=preservationBirth(pid.intValue)?:NSNull.null;freshBirths[pid]=born;}
        if(![born isEqual:candidate[@"birth"]])continue;
        // Keep WID/PID only until the main-thread bound/offered check. The
        // controller receives no native identity and cannot adopt from this.
        [present addObject:@{@"window":wid,@"pid":pid,@"bundle_id":candidate[@"bundle_id"],@"title":title}];
    }
    return present.copy;
}
// A real window by that reading: a standard window or a dialog.
static BOOL toplevelSubrole(NSString *subrole) { return [@[(__bridge NSString *)kAXStandardWindowSubrole,(__bridge NSString *)kAXDialogSubrole,(__bridge NSString *)kAXSystemDialogSubrole]containsObject:subrole]; }
// Restrict early admission to the native, unscaled presentation basis. This is
// only an eligibility check: the helper still snapshots the actual original.
static const char *canonicalNativeBasisRefusal(NSDictionary *basis) {
    if(!basis)return "basis_unavailable_before";
    CGRect bounds=CGRectZero;id matrix=basis[@"transform"],frame=basis[@"native_bounds"];
    if(![matrix isKindOfClass:NSArray.class]||[matrix count]!=6||![frame isKindOfClass:NSDictionary.class]||
       !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)frame,&bounds)||!isfinite(bounds.origin.x)||!isfinite(bounds.origin.y)||
       !isfinite(bounds.size.width)||!isfinite(bounds.size.height)||bounds.size.width<40||bounds.size.height<40)return "basis_format_or_extent";
    for(id number in matrix)if(![number isKindOfClass:NSNumber.class]||!isfinite([number doubleValue]))return "basis_matrix_nonfinite";
    if([matrix[0]doubleValue]!=1||[matrix[1]doubleValue]!=0||[matrix[2]doubleValue]!=0||[matrix[3]doubleValue]!=1)return "basis_matrix_not_unit";
    if([matrix[4]doubleValue]!=-bounds.origin.x)return "basis_translation_x";
    if([matrix[5]doubleValue]!=-bounds.origin.y)return "basis_translation_y";
    return NULL;
}
static BOOL canonicalNativeBasis(NSDictionary *basis) { return canonicalNativeBasisRefusal(basis)==NULL; }
// Creation already supplies an exact AX element: no AXWindows enumeration or
// global discovery queue is needed. Still only admit a visible, canonical
// standard window, with two matching fresh native bases after its AX metadata.
static void creationTrace(NSUInteger *lines,const char *stage,pid_t pid,CGWindowID wid,CFTimeInterval started,const char *detail) {
    if(!getenv("INFINIFY_DEBUG")||*lines>=128)return;(*lines)++;CFTimeInterval at=CACurrentMediaTime();
    fprintf(stderr,"debug: native creation trace stage=%s pid=%d wid=%u at=%.6f elapsed_ms=%.3f detail=%s\n",stage,pid,wid,at,started?(at-started)*1000:0,detail?:"none");
}
static DWWindowCandidate *createdNativeWindow(AXUIElementRef element,pid_t pid,NSArray *born,NSDictionary **verified,const char **refusal,CGWindowID *observedWindow) {
    *refusal="birth_or_trust";
    if(born.count!=2||![preservationBirth(pid)isEqual:born]||!AXIsProcessTrusted())return nil;
    AXError (*get)(AXUIElementRef,uint32_t *)=(AXError (*)(AXUIElementRef,uint32_t *))dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    uint32_t wid=0;pid_t owner=0;
    *refusal="ax_identity";
    if(!get||AXUIElementSetMessagingTimeout(element,.1)||AXUIElementGetPid(element,&owner)||owner!=pid||get(element,&wid)||!wid)return nil;
    *observedWindow=wid;*refusal="canonical_before";
    NSDictionary *identity=@{@"pid":@(pid),@"wid":@(wid),@"birth_sec":born[0],@"birth_usec":born[1]};
    CFTypeRef role=NULL,subrole=NULL,title=NULL;
    *refusal="role";BOOL known=AXUIElementCopyAttributeValue(element,kAXRoleAttribute,&role)==kAXErrorSuccess&&role&&CFEqual(role,kAXWindowRole);
    if(known){*refusal="subrole";known=AXUIElementCopyAttributeValue(element,kAXSubroleAttribute,&subrole)==kAXErrorSuccess&&subrole&&CFEqual(subrole,kAXStandardWindowSubrole);}
    if(known){*refusal="title_unavailable";known=AXUIElementCopyAttributeValue(element,kAXTitleAttribute,&title)==kAXErrorSuccess&&title&&CFGetTypeID(title)==CFStringGetTypeID();}
    NSString *name=known?[(__bridge NSString *)title copy]:nil;
    if(role)CFRelease(role);if(subrole)CFRelease(subrole);if(title)CFRelease(title);if(!known)return nil;
    // AXCreated can precede publication of the window's CG ownership record.
    // Use that exact element's positive metadata while its application finishes
    // opening; ownership, on-screen state and canonical geometry are still
    // proved afresh below, twice, before any candidate can be offered.
    NSDictionary *before=DWNativeWindowDiscoveryBasis(identity);const char *basisRefusal=canonicalNativeBasisRefusal(before);if(basisRefusal){*refusal=basisRefusal;return nil;}
    *refusal="cg_duplicate";NSArray *rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));NSDictionary *row=nil;
    for(NSDictionary *entry in rows)if([entry[(id)kCGWindowNumber]unsignedIntValue]==wid){if(row)return nil;row=entry;}
    NSRunningApplication *application=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    *refusal="cg_visibility_owner_layer_or_app";
    if([row[(id)kCGWindowOwnerPID]intValue]!=pid||![row[(id)kCGWindowIsOnscreen]boolValue]||
        ![row[(id)kCGWindowLayer]isKindOfClass:NSNumber.class]||[row[(id)kCGWindowLayer]integerValue]!=0||
        !application||application.activationPolicy!=NSApplicationActivationPolicyRegular||!application.bundleIdentifier.length)return nil;
    *refusal="final_basis_or_birth";NSDictionary *after=DWNativeWindowDiscoveryBasis(identity);
    if(![after isEqual:before]||![preservationBirth(pid)isEqual:born])return nil;
    *refusal="final_bounds";CGRect frame=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)after[@"native_bounds"],&frame))return nil;
    DWWindowCandidate *candidate=[DWWindowCandidate new];candidate.pid=pid;candidate.window=wid;candidate.nativeIdentity=identity;
    candidate.frame=frame;candidate.title=name;candidate.bundleIdentifier=application.bundleIdentifier;candidate.applicationName=application.localizedName;
    *verified=after;*refusal="qualified";return candidate;
}
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
    DWWindowManager *manager=[self new];manager.scope=[scope copy];manager.capturing=capturing;manager.native=native;manager.host=host;manager.offered=[NSMutableSet set];manager.declined=[NSMutableSet set];manager.missed=[NSMutableSet set];manager.unlisted=[NSMutableSet set];manager.placed=[NSMutableDictionary dictionary];manager.titleRetries=[NSMutableDictionary dictionary];
    manager.nativeMetadata=[NSMutableDictionary dictionary];manager.events=[[DWWindowEvents alloc]initWithSink:manager scope:manager.scope];return manager;
}
- (BOOL)live { return self.events.live; }
- (NSSet<NSNumber *> *)offeredWindows { return self.offered.copy; }
- (BOOL)reconciliationDue {
    if(self.stopped)return NO;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    return !self.events.live||now>=self.next||!self.completed||now<self.eager;
}
- (BOOL)pollWithWindowRecords:(NSArray<NSDictionary *> *)records nativeCandidateBases:(NSDictionary<NSNumber *,NSDictionary *> *)nativeCandidateBases sampledAt:(CFTimeInterval)sampledAt {
    if(self.stopped||!records)return NO;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;BOOL live=self.events.live,due=now>=self.next;
    if(due){self.next=now+1;[self.events reconcile];}
    [self passRecords:records nativeCandidateBases:nativeCandidateBases sampledAt:sampledAt];return due||!live;
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
- (void)prefetchNativeMetadata:(NSDictionary<NSNumber *,NSNumber *> *)asked titles:(NSDictionary *)listedTitles records:(NSArray<NSDictionary *> *)records {
    NSMutableDictionary *tickets=[NSMutableDictionary dictionary];NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    for(NSNumber *wid in asked){NSMutableDictionary *ticket=[@{@"basis":self.bases[wid],@"since":self.since[wid],@"cg_title":listedTitles[wid]?:NSNull.null,@"started":@(now)}mutableCopy];self.nativeMetadata[wid]=ticket;tickets[wid]=ticket;}
    NSMutableArray *front=[NSMutableArray array];NSMutableDictionary *levels=[NSMutableDictionary dictionary];
    for(NSDictionary *row in records){NSNumber *wid=row[(id)kCGWindowNumber];if([asked[wid]isEqual:row[(id)kCGWindowOwnerPID]]){[front addObject:wid];levels[wid]=row[(id)kCGWindowLayer];}}
    BOOL afterStartup=self.completed;
    self.reading=YES;__weak DWWindowManager *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSMutableDictionary *titles=[NSMutableDictionary dictionary];NSDictionary *roles=windowSubroles(asked,titles);
        NSMutableDictionary *verified=[NSMutableDictionary dictionary];
        if(afterStartup)for(NSNumber *wid in asked){NSDictionary *ticket=tickets[wid],*basis=ticket[@"basis"];
            if([levels[wid]integerValue]!=0||![roles[wid]isEqual:(__bridge NSString *)kAXStandardWindowSubrole]||
               ![titles[wid]isKindOfClass:NSString.class]||!canonicalNativeBasis(basis)||CACurrentMediaTime()-[ticket[@"started"]doubleValue]>.1)continue;
            NSDictionary *fresh=DWNativeWindowDiscoveryBasis(basis[@"identity"]);
            if([fresh isEqual:basis])verified[wid]=fresh;
        }
        dispatch_async(dispatch_get_main_queue(),^{DWWindowManager *manager=weak;if(!manager||manager.stopped)return;manager.reading=NO;
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime,delay=still;
            NSMutableDictionary *early=[NSMutableDictionary dictionary],*earlyAsked=[NSMutableDictionary dictionary],*frames=[NSMutableDictionary dictionary],*bases=[NSMutableDictionary dictionary];
            for(NSNumber *wid in tickets){NSMutableDictionary *ticket=tickets[wid];
                if(manager.nativeMetadata[wid]!=ticket||![ticket[@"basis"]isEqual:manager.bases[wid]]||![ticket[@"since"]isEqual:manager.since[wid]])continue;
                delay=MIN(delay,MAX(0,[ticket[@"since"]doubleValue]+still-now));
                BOOL positive=[roles[wid]isKindOfClass:NSString.class]&&(toplevelSubrole(roles[wid])||[roles[wid]isEqual:(__bridge NSString *)kAXFloatingWindowSubrole]);
                if(now-[ticket[@"started"]doubleValue]<=.1&&positive&&[titles[wid]isKindOfClass:NSString.class]){ticket[@"subrole"]=roles[wid];ticket[@"title"]=titles[wid];
                    if(manager.completed&&verified[wid]){early[wid]=ticket;earlyAsked[wid]=asked[wid];frames[wid]=verified[wid][@"native_bounds"];bases[wid]=verified[wid];}}
            }
            // This one fresh post-AX sample may end the hold only for exact
            // standard-window tickets. Unknown or changing windows still wait.
            if(early.count){NSMutableArray *ordered=[NSMutableArray array];for(NSNumber *wid in front)if(early[wid])[ordered addObject:wid];
                [manager read:nil error:nil asked:earlyAsked front:ordered subroles:roles titles:titles frames:frames levels:levels basis:bases titleTickets:@{} earlyTickets:early];}
            [manager requestDiscoveryAfter:delay];
        });
    });
}
- (void)windowCreatedElement:(AXUIElementRef)element pid:(pid_t)pid birth:(NSArray<NSNumber *> *)born {
    const char *skip=self.stopped?"stopped":!self.native?"not_native":!self.completed?"startup":self.creationReading?"busy":!element?"no_element":
        (pid<=1||pid==getpid())?"pid":born.count!=2?"birth":(self.scope&&![self.scope[@(pid)]isEqual:born])?"scope":NULL;
    if(skip){creationTrace(&_creationTraceLines,"ingress_skip",pid,0,0,skip);return;}
    NSDictionary *ticket=@{@"pid":@(pid),@"started":@(CACurrentMediaTime())};self.creationTicket=ticket;self.creationReading=YES;
    creationTrace(&_creationTraceLines,"started",pid,0,[ticket[@"started"]doubleValue],NULL);
    NSArray *original=[born copy];CFRetain(element);__weak DWWindowManager *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSDictionary *basis=nil;const char *refusal=NULL;CGWindowID observedWindow=0;
        DWWindowCandidate *candidate=createdNativeWindow(element,pid,original,&basis,&refusal,&observedWindow);CFRelease(element);
        dispatch_async(dispatch_get_main_queue(),^{DWWindowManager *manager=weak;if(!manager)return;manager.creationReading=NO;
            CFTimeInterval started=[ticket[@"started"]doubleValue];
            creationTrace(&manager->_creationTraceLines,"worker",pid,observedWindow,started,refusal);
            if(manager.creationTicket!=ticket){creationTrace(&manager->_creationTraceLines,"completion_skip",pid,observedWindow,started,"ticket_retired");return;}manager.creationTicket=nil;
            const char *skip=manager.stopped?"stopped":!manager.native?"not_native":!manager.completed?"startup":!candidate?"worker_refused":CACurrentMediaTime()-started>.1?"age":NULL;
            if(skip){creationTrace(&manager->_creationTraceLines,"completion_skip",pid,observedWindow,started,skip);return;}
            NSNumber *wid=@(candidate.window);
            if([manager.offered containsObject:wid]||[manager.host managesWindow:candidate.window pid:pid]){creationTrace(&manager->_creationTraceLines,"completion_skip",pid,observedWindow,started,"already_managed");return;}
            // A newer global observation can only reject this direct proof;
            // it cannot be replaced or have its single-flight state cleared.
            if(manager.nativeSampleAt>started&&(!manager.bounds[wid]||(manager.sampled[wid].doubleValue>started&&![manager.bases[wid]isEqual:basis]))){
                creationTrace(&manager->_creationTraceLines,"completion_skip",pid,observedWindow,started,"newer_observation");return;}
            if(!DWInScope(manager.scope,pid)){creationTrace(&manager->_creationTraceLines,"completion_skip",pid,observedWindow,started,"scope");return;}
            [manager.offered addObject:wid];[manager.titleRetries removeObjectForKey:wid];[manager.nativeMetadata removeObjectForKey:wid];
            if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native creation direct pid=%d wid=%u metadata_ms=%.3f\n",pid,candidate.window,(CACurrentMediaTime()-started)*1000);
            [manager.host windowAppeared:candidate];
        });
    });
}
- (void)windowCreationInvalidated:(pid_t)pid {
    if(!pid||[self.creationTicket[@"pid"]intValue]==pid){
        if(self.creationTicket)creationTrace(&_creationTraceLines,"invalidated",[self.creationTicket[@"pid"]intValue],0,[self.creationTicket[@"started"]doubleValue],pid?"pid_hint":"global_hint");
        self.creationTicket=nil;
    }
}
// One completed worker read serves the whole discovery set. No event starts a
// second global enumeration while another application's observation is in flight.
- (void)passRecords:(NSArray<NSDictionary *> *)list nativeCandidateBases:(NSDictionary<NSNumber *,NSDictionary *> *)nativeCandidateBases sampledAt:(CFTimeInterval)sampledAt {
    if(self.native)self.nativeSampleAt=MAX(self.nativeSampleAt,sampledAt);
    if(self.stopped)return;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;id<DWWindowHost> host=self.host;if(!self.began)self.began=now;
    NSMutableDictionary<NSNumber *,NSDictionary *> *bounds=[NSMutableDictionary dictionary],*bases=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSNumber *> *wanted=[NSMutableDictionary dictionary],*warming=[NSMutableDictionary dictionary],*regular=[NSMutableDictionary dictionary],*since=[NSMutableDictionary dictionary],*scoped=[NSMutableDictionary dictionary],*sampled=[NSMutableDictionary dictionary];NSMutableDictionary *candidateTitles=[NSMutableDictionary dictionary];NSMutableArray<NSNumber *> *front=[NSMutableArray array];BOOL moving=NO;NSTimeInterval stabilityDelay=still,titleDelay=0;
    for(NSDictionary *w in list){
        NSNumber *wid=w[(id)kCGWindowNumber],*pid=w[(id)kCGWindowOwnerPID];NSDictionary *b=w[(id)kCGWindowBounds];CGRect r=CGRectZero;
        NSInteger level=[w[(id)kCGWindowLayer]integerValue];BOOL benchmark=self.scope&&self.benchmarkWindowLevel>0&&level==self.benchmarkWindowLevel;
        if(![wid isKindOfClass:NSNumber.class]||![pid isKindOfClass:NSNumber.class]||pid.intValue==getpid())continue;
        // --only-pid: a window of any other process leaves no trace here. It is neither timed nor wanted, so nothing below asks about it.
        if(self.scope){NSNumber *within=scoped[pid];if(!within)within=scoped[pid]=@(DWInScope(self.scope,pid.intValue));if(!within.boolValue)continue;}
        BOOL panel=self.nativePanels&&level==NSFloatingWindowLevel;
        if(level!=0&&!benchmark&&!panel)continue;
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
    if(self.capturing){[SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){NSDictionary<NSNumber *,id> *subroles=content?windowSubroles(asked,nil):nil;dispatch_async(dispatch_get_main_queue(),^{[weak read:content error:error asked:asked front:front subroles:subroles titles:nil frames:nil levels:levels basis:basis titleTickets:tickets earlyTickets:nil];});}];return;}
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSMutableDictionary<NSNumber *,NSString *> *titles=[listedTitles mutableCopy];NSDictionary<NSNumber *,id> *subroles=windowSubroles(asked,titles);dispatch_async(dispatch_get_main_queue(),^{[weak read:nil error:nil asked:asked front:front subroles:subroles titles:titles frames:frames levels:levels basis:basis titleTickets:tickets earlyTickets:nil];});});
}
// `front` is the window list's own order, front to back. `subroles` is windowSubroles' answer for `asked`, read before this turn of the main queue.
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
            &&[titles[wid]isKindOfClass:NSString.class]&&canonicalNativeBasis(basis[wid]);
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
        BOOL real=floating?window.displayFixed:([subrole isKindOfClass:NSString.class]?toplevelSubrole(subrole):window.title.length||(window.frame.size.width>=200&&window.frame.size.height>=150));
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
        self.reading=YES;NSDictionary *scope=self.scope;NSSet *offered=self.offered.copy;NSInteger benchmark=self.benchmarkWindowLevel;__weak DWWindowManager *weak=self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *why=nil;NSArray *records=nativePreservedWindows(scope,offered,benchmark,&why);
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
        BOOL benchmark=self.scope&&self.benchmarkWindowLevel>0&&w.windowLayer==self.benchmarkWindowLevel;
        if((w.windowLayer!=0&&!benchmark)||pid==getpid()||w.frame.size.width<40||w.frame.size.height<40||!w.title.length||!bundle.length||[self.offered containsObject:@(w.windowID)]||!DWInScope(self.scope,pid))continue;
        if([NSRunningApplication runningApplicationWithProcessIdentifier:pid].activationPolicy!=NSApplicationActivationPolicyRegular||[host managesWindow:w.windowID pid:pid])continue;
        [present addObject:@{@"bundle_id":bundle,@"title":w.title}];
    }
    self.completed=YES;[host discoveryCompleted:present];
}
// Told to the host once per appearance, from the first pass on: a window that arrives while it runs is held back too.
- (void)declineWindow:(NSNumber *)wid pid:(NSNumber *)pid {
    if(self.stopped||!self.native||[self.declined containsObject:wid])return;
    [self.declined addObject:wid];
    if([self.host respondsToSelector:@selector(windowNotAdopted:pid:)])[self.host windowNotAdopted:wid.unsignedIntValue pid:pid.intValue];
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
- (void)invalidateNativeMetadata:(CGWindowID)window pid:(pid_t)pid {
    [self windowCreationInvalidated:pid];
    for(NSNumber *wid in self.nativeMetadata.allKeys)if((!window||wid.unsignedIntValue==window)&&(!pid||[self.nativeMetadata[wid][@"basis"][@"identity"][@"pid"]intValue]==pid))[self.nativeMetadata removeObjectForKey:wid];
}
- (void)windowsChanged:(pid_t)pid { if(self.stopped)return;[self invalidateNativeMetadata:0 pid:pid];self.eager=NSProcessInfo.processInfo.systemUptime+1;if([self.host respondsToSelector:@selector(windowFamilyChanged:)])[self.host windowFamilyChanged:pid]; }
- (void)windowMoved:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;
    [self invalidateNativeMetadata:window pid:pid];
    if(window&&![self.offered containsObject:@(window)])self.eager=NSProcessInfo.processInfo.systemUptime+1;
    [self.host windowMoved:window pid:pid];
}
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;
    [self invalidateNativeMetadata:window pid:pid];
    BOOL titleChanged=NO;
    for(NSNumber *wid in self.titleRetries.allKeys)if((!window||wid.unsignedIntValue==window)&&[self.titleRetries[wid][@"basis"][@"identity"][@"pid"]intValue]==pid){[self.titleRetries removeObjectForKey:wid];titleChanged=YES;}
    if(titleChanged)[self requestDiscoveryAfter:0];
    // A candidate not offered yet needs a discovery pass. A bound window is the host's to look at now.
    if(window&&![self.offered containsObject:@(window)])self.eager=NSProcessInfo.processInfo.systemUptime+1;
    [self.host windowChanged:window pid:pid];
}
- (void)windowVisibilityChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;[self invalidateNativeMetadata:window pid:pid];
    if([self.host respondsToSelector:@selector(windowVisibilityChanged:pid:)])[self.host windowVisibilityChanged:window pid:pid];
}
// The window number may come back on screen, when its application kept the window object and shows it again. That is
// then a new appearance, whenever the next pass comes.
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid {
    if(self.stopped)return;NSNumber *wid=@(window);[self.offered removeObject:wid];[self.missed removeObject:wid];[self.unlisted removeObject:wid];
    if([self.titleRetries[wid][@"basis"][@"identity"][@"pid"]intValue]==pid)[self.titleRetries removeObjectForKey:wid];
    [self invalidateNativeMetadata:window pid:pid];
    [self.host windowDestroyed:window pid:pid];
}
- (void)focusChanged { if(!self.stopped)[self.host focusChanged]; }
@end
// The Accessibility element of exactly one window: the lookup of resolve() in
// native/focus/focus.m, which is private to that file. Every window of the process
// is asked for its window number; one match owned by that process is required, and
// any unknown window that does not answer refuses the whole lookup. Signature provenance as
// there: yabai dd845723416f5fe92af49fad5ebab00369e07edd, src/misc/extern.h:8.
typedef AXError (*GetWindow)(AXUIElementRef,uint32_t *);
// Finder's AXWindows includes its same-process desktop AXScrollArea, which
// has no WindowServer ID. Match the narrow exception in focus/resize: only
// IllegalArgument with this verified PID and exact role is a non-window.
static BOOL windowlessScrollArea(AXUIElementRef element,pid_t expectedPID) {
    pid_t pid=0;if(AXUIElementGetPid(element,&pid)!=kAXErrorSuccess||pid!=expectedPID)return NO;
    CFTypeRef role=NULL;AXError error=AXUIElementSetMessagingTimeout(element,.1);
    if(error==kAXErrorSuccess)error=AXUIElementCopyAttributeValue(element,kAXRoleAttribute,&role);
    BOOL known=error==kAXErrorSuccess&&role&&CFGetTypeID(role)==CFStringGetTypeID()&&CFEqual(role,kAXScrollAreaRole);
    if(role)CFRelease(role);return known;
}
static AXUIElementRef copyWindow(DWFocusIdentity i) {
    GetWindow get=(GetWindow)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");if(!get)return NULL;
    AXUIElementRef app=AXUIElementCreateApplication(i.pid);AXUIElementSetMessagingTimeout(app,.1);CFTypeRef list=NULL;
    AXError error=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&list);CFRelease(app);
    if(error||!list||CFGetTypeID(list)!=CFArrayGetTypeID()){if(list)CFRelease(list);return NULL;}
    AXUIElementRef found=NULL;int matches=0;BOOL valid=YES;
    for(CFIndex n=0;n<CFArrayGetCount(list);n++){
        AXUIElementRef w=(AXUIElementRef)CFArrayGetValueAtIndex(list,n);uint32_t wid=0;pid_t pid=0;
        if(CFGetTypeID(w)!=AXUIElementGetTypeID()||AXUIElementSetMessagingTimeout(w,.1)){valid=NO;break;}
        AXError windowError=get(w,&wid);
        if(windowError==kAXErrorIllegalArgument&&windowlessScrollArea(w,i.pid))continue;
        if(windowError){valid=NO;break;}
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
