// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop: init/dealloc, the controller boundary (call:), the shared reply tail, status notes, scene load/save and the poll.
#import "Desktop.h"
#import "Desktop+Private.h"
#import "DWDebugTrace.h"
#import "DWInputSources.h"
@implementation Desktop
- (instancetype)init {
    if((self=[super init])){_controller=driftwm_desktop_create();_panels=[NSMutableArray array];_views=[NSMutableArray array];_sources=[NSMutableDictionary dictionary];_choices=[NSMutableArray array];_pendingStops=[NSMutableArray array];_postingTags=[NSMutableSet set];
        __weak Desktop *weak=self;_panLaunch=[[DWPanLaunch alloc]initWithLaunch:^(NSNumber *output){[weak panEnd:output];}];}
    return self;
}
- (void)flashStatus:(NSString *)text {
    self.statusText=text;NSUInteger token=++self.statusToken;__weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{Desktop *d=weak;if(d.statusToken!=token||d.cleaning||![d.statusText isEqual:text])return;d.statusText=[d restingStatus];[d render];});
}
// What the resting status returns to: a config load the controller refused, or its --super chord, stays up, else why the background fell back, else nothing.
// A problem in the config file itself is the error bar's alone (-loadConfig:).
- (NSString *)restingStatus { return self.configNote?:self.backgroundNote?:@""; }
// A normal run draws no status line. A note that would have been shown there is one line on stderr instead, and is not
// written again while it stays up: one renewed before it expired is one line. Once the status is back at rest the same
// note is news again (-render forgets it there), so two refusals a minute apart are two lines.
- (void)say:(NSString *)note { if(!note.length||[note isEqual:self.said])return;self.said=note;fprintf(stderr,"%s\n",note.UTF8String); }
// Shared tail of every bound or scripted command: redraw, fly, persist, and the effects
// the shell owns: quit, exec, a config reload, a pointer warp, a keyboard layout switch,
// a window's close button and the launch of a stand-in's application.
- (void)applyReply:(NSDictionary *)reply {
    NSDictionary *sized=[self consumeSize:reply];
    // The navigation coordinator reads "effect" as a focus request. A reply that lists "effects" keeps its focus request there:
    // its "effect" is a size transaction's, or null without one, and is kept from that reading. The one reply whose "effect" stays
    // a focus request beside a size transaction is the attach's shape, the transaction as an entry of "effects": an activation or a
    // hover that leaves fullscreen may answer so, and its focus request is still the coordinator's.
    BOOL beside=sized&&reply[@"effect"]!=sized&&DWTyped(reply[@"effect"],NSDictionary.class);
    if(reply[@"effect"]&&!beside&&(sized||[reply[@"effects"]isKindOfClass:NSArray.class])){NSMutableDictionary *rest=[reply mutableCopy];[rest removeObjectForKey:@"effect"];reply=rest;}
    // A gesture reply says itself when frames are needed: a camera coasting after a swipe, or the edge pan under a move, is no flight.
    BOOL flight=DWTyped(reply[@"navigation"],NSDictionary.class)!=nil||[reply[@"needs_frames"]isEqual:@YES];if(flight&&!self.navigation)self.flying=YES;
    // The reply's focus request, if any, is the coordinator's to perform on the native window.
    [self.navigation perform:reply];
    [self render];if(flight)[self ensureFrames];
    if([reply[@"dirty"]isEqual:@YES])self.sceneDirty=YES;
    for(id effect in asArray(reply[@"effects"])){NSDictionary *e=DWTyped(effect,NSDictionary.class);NSString *op=DWTyped(e[@"op"],NSString.class);
        if([op isEqual:@"quit"])[self quit:nil];
        else if([op isEqual:@"exec"]&&DWTyped(e[@"command"],NSString.class))[self exec:e];
        // send-cursor-to-output, an explicit user action: the point is in the coordinates of screen_bounds.
        // Position only: this shell does not own an application's mouse/cursor association.
        else if([op isEqual:@"warp_pointer"]){NSDictionary *screen=DWTyped(e[@"screen"],NSDictionary.class);CGPoint to=jsonPoint(screen);if(DWTyped(screen[@"x"],NSNumber.class)&&DWTyped(screen[@"y"],NSNumber.class)&&isfinite(to.x)&&isfinite(to.y)){CGWarpMouseCursorPosition(to);}}
        // The selection is reported at once; the input-source notification reports it again.
        else if([op isEqual:@"switch_layout"]){NSString *error=DWSwitchLayout(e);if(error)[self flashStatus:error];[self reportLayout];}
        // Deferred: a reload replaces the hot keys, and this may be running inside one of their handlers.
        else if([op isEqual:@"reload_config"]){__weak Desktop *weak=self;dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(d&&!d.cleaning)[d loadConfig:NO];});}
        else if([op isEqual:@"close_window"])[self closeWindow:e];
        else if([op isEqual:@"set_minimized"])[self setNativeMinimized:e];
        else if([op isEqual:@"launch"])[self launch:DWTyped(e[@"bundle_id"],NSString.class)];
    }
}
- (NSDictionary *)call:(NSDictionary *)command { return [self call:command raw:NULL]; }
// raw receives the controller's own response bytes.
- (NSDictionary *)call:(NSDictionary *)command raw:(NSData *__autoreleasing *)raw {
    // These four queries execute on &self before the controller's transaction
    // clone. Every other request invalidates the cache BEFORE it can change
    // state. Retain one immutable decoded snapshot, without raw bytes.
    BOOL snapshot=command.count==1&&[command[@"op"]isEqual:@"snapshot"];
    if(snapshot&&!raw&&self.controllerSnapshot)return self.controllerSnapshot;
    NSString *operation=DWTyped(command[@"op"],NSString.class);
    BOOL query=snapshot||[operation isEqual:@"hit"]||[operation isEqual:@"input"]||[operation isEqual:@"resize_border"]||[operation isEqual:@"gesture_fingers"];
    BOOL tick=[operation isEqual:@"tick_navigation"];
    NSDictionary *before=tick?self.controllerSnapshot:nil,*visual=tick?self.controllerVisualSnapshot:nil;
    if(!query){self.controllerSnapshot=nil;self.controllerVisualSnapshot=nil;}
    NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command} options:0 error:nil];
    char *response=driftwm_desktop_request(self.controller,request.bytes,request.length);if(!response){self.statusText=@"Controller unavailable";return nil;}
    NSData *data=[NSData dataWithBytes:response length:strlen(response)];driftwm_desktop_response_free(response);if(raw)*raw=data;
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![reply[@"ok"]boolValue]){self.statusText=reply[@"error"]?:@"Controller error";return nil;}
    NSDictionary *result=DWTyped(reply[@"data"],NSDictionary.class); // every controller reply is an object; a null or other JSON value is no reply
    if(DWDebugTrace()){
        NSMutableArray *effects=[asArray(result[@"effects"])mutableCopy]?:[NSMutableArray array];
        if(DWTyped(result[@"effect"],NSDictionary.class))[effects addObject:result[@"effect"]];
        for(NSDictionary *effect in effects)if([effect[@"op"]isEqual:@"observe_resize_source"]||[effect[@"op"]isEqual:@"resize_native_window"]){
            id ipc=command[@"request"];NSString *variant=DWTyped(ipc,NSString.class)?:((NSDictionary *)DWTyped(ipc,NSDictionary.class)).allKeys.firstObject?:@"none";
            NSString *action=DWTyped(command[@"action"],NSString.class)?:DWTyped(DWTyped(ipc,NSDictionary.class)[@"Action"],NSString.class);
            if(![@[@"toggle-fullscreen",@"fullscreen",@"fill",@"restore",@"center",@"fit"]containsObject:action?:@""])action=@"other";
            fprintf(stderr,"debug: native resize origin operation=%s ipc=%s action=%s transaction=%llu effect=%llu window=%llu\n",operation.UTF8String,variant.UTF8String,action.UTF8String,[effect[@"transaction"]unsignedLongLongValue],[effect[@"effect_id"]unsignedLongLongValue],[effect[@"window"]unsignedLongLongValue]);
        }
    }
    // set-trackpad switches every gesture off or on: the finger counts the system's own gestures are held back for follow it. A key, a gesture, a corner or `msg action` may run it.
    if(self.dockGuard&&!query){NSString *ran=DWTyped(command[@"action"],NSString.class)?:DWTyped(DWTyped(command[@"request"],NSDictionary.class)[@"Action"],NSString.class)?:DWTyped(DWTyped(result[@"fired"],NSDictionary.class)[@"action"],NSString.class);if([ran hasPrefix:@"set-trackpad"])[self refreshGestureFingers];}
    if(snapshot){self.controllerSnapshot=result;if(!self.controllerVisualSnapshot)self.controllerVisualSnapshot=result;}
    else if(tick&&[result[@"clock_only"]isEqual:@YES]){
        // This successful tick changed only clock_ns. Never mutate a retained
        // dictionary: ordinary Snapshot readers see the current clock, while
        // rendering/capture keep the same proven-unchanged geometry projection.
        if(before){NSMutableDictionary *next=[before mutableCopy],*navigation=[DWTyped(before[@"navigation"],NSDictionary.class)mutableCopy];navigation[@"clock_ns"]=command[@"timestamp_ns"];next[@"navigation"]=navigation.copy;self.controllerSnapshot=next.copy;}
        self.controllerVisualSnapshot=visual;
    }
    return result;
}
- (BOOL)loadScene:(NSString *)path {
    [self.sceneWriter drain];
    [self cancelNavigation];[self.resize cancel];if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize must settle before loading";return NO;}
    self.statePath=path;
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return YES;
    if([self call:@{@"op":@"load",@"path":path}])return YES;
    self.startupError=[NSString stringWithFormat:@"Saved scene could not be loaded: %@. Original file preserved. Quit and repair it, or restart with --state and a different path.",self.statusText];
    // Every save path, including quit and Return to desktop, is disabled.
    self.statePath=nil;return NO;
}
- (void)saveScene {
    if(self.sessionAwaitingCanvas)return;
    if(!self.statePath)return;
    if(!self.cleaning){
        if(!self.sceneWriter){self.sceneWriter=[DWSceneWriter new];__weak Desktop *weak=self;
            self.sceneWriter.failed=^(NSString *reason){Desktop *desktop=weak;if(!desktop||desktop.cleaning)return;desktop.sceneDirty=YES;desktop.statusText=reason;};}
        if([self.sceneWriter submit:self.controller path:self.statePath])self.sceneDirty=NO;
        else {self.sceneDirty=YES;self.statusText=@"Scene save could not prepare an independent controller copy";}
        return;
    }
    // Shutdown keeps synchronous completion. Drain older snapshots first
    // so they cannot overwrite the final scene after its atomic commit.
    [self.sceneWriter drain];
    if([self call:@{@"op":@"save",@"path":self.statePath}])self.sceneDirty=NO;
}
- (void)poll {
    [self.session poll]; // blocked startup/early wake retries before the inactive early return
    [self updateNativeMouseOwners];
    [self updateNativeFill];
    [self updateNativeVisibility];
    if(self.cleaning||self.sessionInactive)return;
    [self resumeNative];
    if([self nativeUnavailable]){
        // Registered receipts/watchdogs run on main independently of this poll.
        // Keep orphan settlement too, without allowing new input or camera work.
        if(self.resize&&CACurrentMediaTime()-self.lastResizeObservation>=1){self.lastResizeObservation=CACurrentMediaTime();[self.resize reap];}
        return;
    }
    BOOL timing=self.scope&&getenv("INFINIFY_DEBUG")&&atoi(getenv("INFINIFY_DEBUG"))==1;
    CFTimeInterval stages[7]={0};if(timing)stages[0]=CACurrentMediaTime();
    if(self.nativeButtonHover)[self refreshNativeButtons:self.sources[self.nativeButtonHover]];
    if(self.resize&&CACurrentMediaTime()-self.lastResizeObservation>=1){self.lastResizeObservation=CACurrentMediaTime();[self.resize reap];}
    [self endLostInput];
    [self watchCorners];
    if(timing)stages[1]=CACurrentMediaTime();
    // Idle polling keeps the clock current and, while cursor edge pan wants it, the pointer reported; motion found while the timer does not serve it regains the display's rate.
    // A display link calls back only while its display refreshes. Motion it has not served for a quarter of a second (a display asleep, no screen to follow)
    // is ticked here instead, at the poll's pace, so a flight still arrives and a frame timer that never fires cannot hold the canvas still.
    BOOL stalled=self.frameFlying&&CACurrentMediaTime()-self.frameDriver.lastFrame>.25;
    if(!self.frameFlying||stalled){if([self cameraFrame])[self ensureFrames];else if(stalled)self.frameFlying=NO;}
    if(timing)stages[2]=CACurrentMediaTime();
    // Where the observers report native focus (-focusChanged) the focus poll is a reconciliation, once a second.
    if(self.navigation&&CACurrentMediaTime()-self.lastObservation>=(self.manager.live?1:.5)){self.lastObservation=CACurrentMediaTime();[self refreshFocusAccess];[self refreshStageManager];[self.navigation observe];}
    if(timing)stages[3]=CACurrentMediaTime();
    // Managed discovery and reconciliation share one bounded worker observation.
    // Appearance storms can request at the idle poll's pace but never enumerate
    // on the frame thread or queue more than one read. Event/input/resize paths
    // retain their own fresh validation; unmanaged manual sources retain their poll.
    BOOL reconcile=!self.manager;
    if(self.manager){BOOL due=[self.manager reconciliationDue];for(LiveSource *source in self.sources.allValues)if(source.error||source.destroyed||(source.nativeVisibilityWanted&&CACurrentMediaTime()>=source.nativeVisibilityRetryAt))due=YES;if(due)[self requestWindowObservation];}
    BOOL describe=reconcile;
    if(reconcile)for(LiveSource *source in self.sources.allValues)[self track:source];
    if(timing)stages[4]=CACurrentMediaTime();
    [self captureDemand];
    [self captureRecovery];
    [self advanceNativeTransfers];
    // A stopped display link is ordinary idle, not a reason to reserialize
    // every window and rebuild every layer. Clock-only ticks retain this
    // projection; any other command or native family/owner change replaces it.
    NSDictionary *presentation=[self presentationSnapshot];
    describe=describe||self.sceneDirty||!presentation||self.renderedPresentation!=presentation||![self.renderedStatusText?:@"" isEqual:self.statusText?:@""];
    if(self.sceneDirty)[self saveScene];
    if(timing)stages[5]=CACurrentMediaTime();
    // An active compositor already animates the current description at display
    // rate. Preserve reconciliation, exceptional sources and every scene change,
    // without copying/serializing the same idle controller on each poll.
    if(!self.frameFlying){
        if(describe)[self render];
        else if(![self frameComing:NO]){
            // Retry an owed drawable or native restore/rebind without making
            // a new description. Each owner keeps its existing retry fence.
            [self.compositor flushDescribed];[self.native submit];
        }
    }
    if(timing){stages[6]=CACurrentMediaTime();if(stages[6]-stages[0]>=.004&&stages[6]-self.lastPollTiming>=1){self.lastPollTiming=stages[6];
        fprintf(stderr,"poll: total_ms=%.3f input_resize_ms=%.3f camera_ms=%.3f focus_ms=%.3f reconcile_track_ms=%.3f demand_save_ms=%.3f render_ms=%.3f reconcile=%d\n",(stages[6]-stages[0])*1000,(stages[1]-stages[0])*1000,(stages[2]-stages[1])*1000,(stages[3]-stages[2])*1000,(stages[4]-stages[3])*1000,(stages[5]-stages[4])*1000,(stages[6]-stages[5])*1000,reconcile);}}
}
- (void)dealloc { [self stopMacWallpapers];[_ipc stop];[_manager stop];[_session stop];[_onboarding close];[self stopNavigation];[_hotKeys invalidate];[_tapKeys stop];[_configWatcher stop];[_statePush invalidate];[_panLaunch cancel];[_trackpadTimer invalidate];[_multitouch stop];[_dockTap stop];[_sceneWriter drain];if(_controller)driftwm_desktop_destroy(_controller); }
@end
