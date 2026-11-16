// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop: init/dealloc, typed controller ownership, the shared reply tail, status notes, scene load/save and the poll.
#import "Desktop.h"
#import "Desktop+Private.h"
#import "DWPressNativeAdapter.h"
#import "DWPressSceneAdapter.h"
#import "DWDebugTrace.h"
#import "DWInputSources.h"
@implementation Desktop
@synthesize pressAdmission=_pressAdmission;
@synthesize dockGuard=_dockGuard;
- (void)setDockGuard:(DWDockGuard *)guard {
    _dockGuard=guard;__weak Desktop *weak=self;
    if(guard)self.controller.refreshGestureFingers=^{[weak refreshGestureFingers];};
    else self.controller.refreshGestureFingers=nil;
}
- (DWPressAdmission *)pressAdmission {
    if(!_pressAdmission)_pressAdmission=[[DWPressAdmission alloc]initWithDesktop:self scene:[[DWPressSceneAdapter alloc]initWithDesktop:self] native:[DWPressNativeAdapter new]];
    return _pressAdmission;
}
- (instancetype)init {
    if((self=[super init])){_controller=[DWController new];_panels=[NSMutableArray array];_views=[NSMutableArray array];_sources=[NSMutableDictionary dictionary];_choices=[NSMutableArray array];_pendingStops=[NSMutableArray array];_postingTags=[NSMutableSet set];
        __weak Desktop *weak=self;_controller.failed=^(NSString *reason){weak.statusText=reason;};_panLaunch=[[DWPanLaunch alloc]initWithLaunch:^(NSNumber *output){[weak panEnd:output];}];}
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
- (void)applyReply:(DWControllerReply *)reply {
    DWSizeEffect *sized=[self.sizeTransition consumeSize:reply];
    reply=[reply replyForNavigationAfterConsumingSizeEffect:sized];
    // A gesture reply says itself when frames are needed; clock-only camera ticks are not flights.
    BOOL flight=reply.navigation!=nil||[reply.needsFrames isEqual:@YES];if(flight&&!self.navigation)self.flying=YES;
    [self.navigation perform:reply];
    [self render];if(flight)[self ensureFrames];
    if([reply.dirty isEqual:@YES])self.sceneDirty=YES;
    for(DWShellEffect *effect in reply.arrayShellEffects){
        switch(effect.kind){
        case DWEffectQuit:[self quit:nil];break;
        case DWEffectExec:if(effect.command){[self.navigation noteSystemUIIntent];[self exec:effect];}break;
        // Explicit user action. Position only; this shell owns no application mouse association.
        case DWEffectWarpPointer:{CGPoint point=effect.screen;if(effect.screenHasNumericComponents&&isfinite(point.x)&&isfinite(point.y))CGWarpMouseCursorPosition(point);break;}
        case DWEffectSwitchLayout:{NSString *error=DWSwitchLayout(effect.layoutTarget,effect.layoutIndex);if(error)[self flashStatus:error];[self reportLayout];break;}
        case DWEffectReloadConfig:{__weak Desktop *weak=self;dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(d&&!d.cleaning)[d loadConfig:NO];});break;}
        case DWEffectCloseWindow:[self closeWindow:effect];break;
        case DWEffectSetMinimized:[self setNativeMinimized:effect];break;
        case DWEffectLaunch:[self launch:effect.bundleID];break;
        default:break;
        }
    }
}
- (BOOL)loadScene:(NSString *)path {
    [self.sceneWriter drain];
    [self cancelNavigation];[self.sizeTransition cancel];if(self.sizeTransition&&![self.sizeTransition canRemove:nil]){self.statusText=@"Resize must settle before loading";return NO;}
    self.statePath=path;
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return YES;
    if([self.controller loadScene:path])return YES;
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
        if([self.controller submitSceneToWriter:self.sceneWriter path:self.statePath])self.sceneDirty=NO;
        else {self.sceneDirty=YES;self.statusText=@"Scene save could not prepare an independent controller copy";}
        return;
    }
    // Shutdown keeps synchronous completion. Drain older snapshots first
    // so they cannot overwrite the final scene after its atomic commit.
    [self.sceneWriter drain];
    if([self.controller saveScene:self.statePath])self.sceneDirty=NO;
}
- (void)poll {
    [self.session poll]; // blocked startup/early wake retries before the inactive early return
    [self updateNativeMouseOwners];
    [self.sizeTransition observe];
    [self updateNativeVisibility];
    if(self.cleaning||self.sessionInactive)return;
    [self resumeNative];
    if([self nativeUnavailable]){
        // Registered receipts/watchdogs run on main independently of this poll.
        // Keep orphan settlement too, without allowing new input or camera work.
        if(self.sizeTransition&&CACurrentMediaTime()-self.lastResizeObservation>=1){self.lastResizeObservation=CACurrentMediaTime();[self.sizeTransition reap];}
        return;
    }
    BOOL timing=self.scope&&getenv("INFINIFY_DEBUG")&&atoi(getenv("INFINIFY_DEBUG"))==1;
    CFTimeInterval stages[7]={0};if(timing)stages[0]=CACurrentMediaTime();
    [self.pressAdmission pollNativeButtons];
    if(self.sizeTransition&&CACurrentMediaTime()-self.lastResizeObservation>=1){self.lastResizeObservation=CACurrentMediaTime();[self.sizeTransition reap];}
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
    if(self.manager){
        // Eager discovery after a hint enumerates candidates; only the periodic deadline (or an unhealthy observer) audits every source.
        BOOL due=[self.manager reconciliationDue]||[self windowObservationPending];if(due)self.discoveryWanted=YES;if([self.manager periodicAuditDue])self.auditAllWanted=YES;
        for(LiveSource *source in self.sources.allValues)if(source.error||source.destroyed||(source.nativeVisibilityWanted&&CACurrentMediaTime()>=source.nativeVisibilityRetryAt)){due=YES;[self wantWindowAudit:NO pid:0 logical:source.logical];}
        if(due)[self requestWindowObservation];}
    BOOL describe=reconcile;
    if(reconcile)for(LiveSource *source in self.sources.allValues)[self track:source];
    if(timing)stages[4]=CACurrentMediaTime();
    [self captureDemand];
    [self captureRecovery];
    [self advanceNativeTransfers];
    // A stopped display link is ordinary idle, not a reason to reserialize
    // every window and rebuild every layer. Clock-only ticks retain this
    // projection; any other command or native family/owner change replaces it.
    DWScene *presentation=[self presentationSnapshot];
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
- (void)dealloc { [self stopMacWallpapers];[_ipc stop];[_manager stop];[_session stop];[_onboarding close];[self stopNavigation];[_hotKeys invalidate];[_tapKeys stop];[_configWatcher stop];[_statePush invalidate];[_panLaunch cancel];[_trackpadTimer invalidate];[_multitouch stop];[_dockTap stop];[_sceneWriter drain]; }
@end
