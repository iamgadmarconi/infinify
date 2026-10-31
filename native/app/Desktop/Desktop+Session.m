// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop session: system takeover, opening the canvas, native suspend/resume, onboarding, quit and cleanup.
#import "Desktop+Private.h"
@implementation Desktop (Session)
// Stage Manager can be switched on under a canvas that is already open, from Control Centre for one. A normal run switched it off
// itself when its canvas opened and does not fight the user over it: the run goes on and says once what its windows will look like
// until it is off again, and what it put back at its end leaves it on, as the user set it. Other runs never touched the setting.
- (void)refreshStageManager {
    BOOL on=self.manager&&DWStageManagerOn();if(on&&!self.stageNoted)[self say:self.takeover.engaged?DWStageManagerBackNote:DWStageManagerNote];
    self.stageNoted=on;
}
// A size transaction of the controller's own is left to run: the quit action ends a fullscreen first, and its reply carries the
// transaction that hands the window its size back. -cleanup performs it to its end, then shuts the coordinator down as before.
- (void)quit:(id)sender { (void)sender;if(![self sizing])[self.resize shutdown];[self stopNavigation];DWStopSignal=1; }
// The saved world and its cameras need no capture: placeholders, navigation and
// view actions work before any source is chosen or any privacy grant exists.
// A normal run's takeover of Stage Manager and window tiling (DWSystemTakeover.m): its own stderr line says what changed. Idempotent.
// Said before the canvas opens, so a launch that failed to switch them off tells the user why windows may still be thumbnails.
- (void)takeOverWindowSettings {
    NSString *note=nil;[self.takeover engage:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String);
}
// Put back after everything else has ended, so no window is still parked or scaled when Stage Manager comes back on. Idempotent.
- (void)putBackWindowSettings {
    NSString *note=nil;[self.takeover restore:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String);
}
- (void)openCanvas:(id)sender {
    (void)sender;if(self.startupError){self.chooserStatus.stringValue=self.startupError;return;}
    // The canvas about to open must find windows as the user left them, not thumbnails or tiles: macOS follows the change live.
    [self takeOverWindowSettings];
    // A --manual run's chooser stays open above the canvas, the one place a window is added or rebound from.
    [self openPanels];[self render];
}
// Session departure and unexpected native loss cancel the same input/frame
// state and drain the existing helper. Outputs and world geometry stay in place.
- (BOOL)nativeUnavailable { return self.native&&(self.native.ended||self.nativeResumeWanted||self.nativeRestoring||self.nativeResumeInFlight); }
- (void)suspendPresentationLeavingSession:(BOOL)leaving {
    [self clearNativeFillPresentation];
    self.compositor.nativeMenuBackground=NO;
    self.nativeMouseOwner=nil;
    for(LiveSource *source in self.sources.allValues){source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.observationEpoch;}
    [self cancelCapturedInputForWindow:nil];
    [self cancelGestures];[self cancelNativeInput];[self.panLaunch cancel];
    for(DesktopView *view in self.views){view.scrollPan=nil;view.scrollPanTime=0;view.lastScrollPan=0;if(view.gesture){view.clearsFocus=NO;view.lastDragPan=0;[view released:view.lastPoint at:NSProcessInfo.processInfo.systemUptime];}}
    if(![self sizing])[self.resize cancel];
    [self.navigation invalidate];self.navigation.enabled=NO;
    [self.frameDriver invalidate];self.frameDriver=nil;self.frameFlying=NO;self.flying=NO;self.pointerWanted=NO;
    // Held input is cancelled first; departure is inactive before any native
    // drain/completion can ask to reconnect, even if that completion is immediate.
    if(leaving)self.sessionInactive=YES;
    [self stopNativeTransferTimer];self.nativeOwnershipTransfer=nil;[self.canvasCursor reset];[self saveScene];
    [self.nativeFamilies reset];self.overlayFamilySnapshot=self.overlayFamilyBase=self.overlayFamilyDescriptions=nil;
    // Capture work stops with presentation in both backends. Retain overlay
    // bindings/shareable windows so normal demand can resume them on return.
    self.captureRecoveryGeneration++;self.captureRecoveryReading=NO;
    for(LiveSource *source in self.sources.allValues){source.replicaWanted=NO;[self stopCapture:source];}
    if(self.native){[self.nativeViews reset];for(LiveSource *source in self.sources.allValues){source.observationToken=++self.observationEpoch;[self forgetNativeFamily:source];source.window=nil;[source clearSample];}}
    self.nativeSessionEpoch++;
    if(self.nativeEndpoints.count){
        // Keep the input bridge's physical button-pair bookkeeping alive: a
        // cancelled grab's drag/up still belongs to its swallowed down event.
        self.nativeResumeWanted=YES;self.nativeResumeFailures=0;self.nativeResumeAfter=0;
        if(!self.nativeRestoring){self.nativeRestoring=YES;__weak Desktop *weak=self;
            [self.native suspendWithCompletion:^{Desktop *d=weak;if(!d)return;d.nativeRestoring=NO;[d resumeNative];}];}
    }
}
- (void)leftSession {
    if(self.cleaning||self.sessionInactive)return;
    [self suspendPresentationLeavingSession:YES];
}
- (void)resumeNative {
    if(self.cleaning||DWStopSignal)return;
    if(self.native.ended&&self.nativeEndpoints.count&&!self.nativeResumeWanted&&!self.sessionInactive){
        // Loss can occur with the desktop still active. Enter the same drain and
        // authenticated re-admission used after session return, once per loss.
        self.statusText=@"Native presentation lost; restoring and reconnecting";[self say:self.statusText];
        [self suspendPresentationLeavingSession:NO];[self render];
    }
    if(self.sessionInactive||!self.panels.count||!self.nativeResumeWanted||self.nativeRestoring||self.nativeResumeInFlight||CACurrentMediaTime()<self.nativeResumeAfter)return;
    // The Dock was replaced: the old endpoint is gone with it, and the reloader says when a new one answers (-adoptEndpoint:).
    if(self.dockReloader.awaitingEndpoint)return;
    // Preserve the endpoint, credentials and authority selected at launch.
    // Scoped recovery pins the original process births; desktop recovery
    // reaudits its Dock peer. Candidates stay inert until this main turn.
    NSArray *endpoints=self.nativeEndpoints;NSDictionary *scope=self.scope;uint64_t epoch=self.nativeSessionEpoch;BOOL desktopMode=self.nativeDesktopMode;
    self.nativeResumeInFlight=YES;__weak Desktop *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *failure=nil;NSDictionary *endpoint=endpoints.firstObject;
        DWNativePresenter *candidate=desktopMode?[DWNativePresenter reconnectedDesktopPresenterAt:endpoint[@"runtime"] nonce:endpoint[@"nonce"] why:&failure]
            :[DWNativePresenter reconnectedPresentersAt:endpoints scope:scope why:&failure];
        dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;
            if(d)d.nativeResumeInFlight=NO;
            if(!d||d.cleaning||DWStopSignal||d.sessionInactive||epoch!=d.nativeSessionEpoch||!d.nativeResumeWanted){[candidate suspendWithCompletion:nil];return;}
            if(!candidate||![candidate activate]){
                [candidate suspendWithCompletion:nil];d.nativeResumeFailures++;
                d.nativeResumeAfter=CACurrentMediaTime()+fmin(30,.25*pow(2,MIN(d.nativeResumeFailures-1,7u)));
                NSString *note=[@"Native session waiting: " stringByAppendingString:failure?:@"a helper was lost before admission"];
                if(![d.nativeResumeNote isEqual:note]){d.nativeResumeNote=note;[d say:note];}return;
            }
            d.native=candidate;d.nativeResumeWanted=NO;d.nativeResumeFailures=0;d.nativeResumeNote=nil;
            [d say:@"Native presentation reconnected after authenticated restoration audit"];d.statusText=[d restingStatus];
            d.navigation.enabled=YES;d.lastObservation=0;
            for(LiveSource *source in d.sources.allValues){source.observationToken=++d.observationEpoch;[source invalidateNativeButtons];
                if(source.nativeMinimized||source.nativeVisibilityHeld){source.nativeVisibilityRevision++;source.nativeVisibilityWanted=YES;source.nativeVisibilityRetryAt=0;source.nativeVisibilityStable=nil;source.nativeVisibilityRestore=nil;}}
            d.windowObservationAgain=YES;[d requestWindowObservation];[d configureNativeInput];[d render];
        });
    });
}
- (void)returned {
    if(self.cleaning||!self.desktopUp||!self.session.ready)return;
    self.sessionInactive=NO;self.navigation.enabled=!self.native||!self.native.ended;self.lastObservation=0;[self resumeNative];
    if(!self.panels.count){[self openPanels];if(!self.panels.count)return;[self runAutostart];}
    for(LiveSource *source in self.sources.allValues)if(source.captureRecovering)source.captureRetryAt=CACurrentMediaTime();
    for(LiveSource *source in self.sources.allValues)if(source.nativeMinimized||source.nativeVisibilityHeld)[self requestVisibility:source];
    BOOL screensChanged=![self.panelScreens isEqual:physicalScreens()];
    if(screensChanged)[self screensChanged:nil];
    // Unmanaged canvases do not have captureDemand. Resume their
    // existing sources explicitly, using the current screens' capture rate.
    if(!self.native&&!self.manager)for(LiveSource *source in self.sources.allValues)if(!source.stream&&!source.detached&&!source.error&&!source.captureRecovering&&source.window){
        CGSize pixels=source.captureSize;if(pixels.width<1||pixels.height<1)pixels=source.buffer;
        [self startCapture:source size:pixels interval:[self captureInterval]];
    }
    if(screensChanged)return;[self refreshOutputUsableAreas];[self refreshMacWallpapers];
    [self windowDiscoveryRequested];
    if(self.windowed){[self render];return;}
    for(NSUInteger i=0;i<self.panels.count&&i<self.views.count;i++){NSPanel *panel=self.panels[i];NSRect frame=topRect(self.views[i].globalBounds);if(!NSEqualRects(panel.frame,frame))[panel setFrame:frame display:YES];[panel orderFrontRegardless];}
    [self render];
}
// A launch that cannot open its canvas: a grant is missing, or the saved scene could not be loaded (the window then
// says that and offers Quit alone). The canvas opens from the window itself once required grants are there, and autostart
// runs then: a Relaunch from the window is this run started again, whose config load hands the autostart commands over
// once more, so they must not have run here already.
- (void)onboard {
    __weak Desktop *weak=self;
    if(!self.onboarding)self.onboarding=[[DWOnboarding alloc]initWithProceed:^{[weak openCanvas:nil];[weak runAutostart];} relaunch:^{weak.relaunch=YES;[weak quit:nil];} quit:^{[weak quit:nil];} requiresScreenCapture:self.native==nil];
    [self.onboarding show:self.startupError];
}
// Log out, restart and shut down ask an application to quit through AppKit, whose terminate: ends the process where it
// stands: no fullscreen ended, nothing saved. The quit is performed here to its end, as main() performs any other, and
// AppKit then exits with status 0. A quit already under way (SIGTERM came first: launchd sends it at log out as well)
// is waiting further down this very stack, since -cleanup handles events while it waits, and cannot go on until this
// returns: what it had left is given up but for the save, and the process ends here.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;if(self.cleaning){[self saveScene];return NSTerminateNow;}
    [self quit:nil];[self.ipc stop];self.ipc=nil;[self cleanup];[self.chooser close];[self.onboarding close];return NSTerminateNow;
}
// Infinify opened again from Finder while the desktop runs: the setup assistant, in a process of its own (`Infinify setup`,
// DWSetupAssistant.h), so it never holds up the canvas; a second one ends by itself while one is showing. It is not the
// login item's job, whatever this run is: launchd's job name stays out of its environment, so a hand-over from it asks
// launchd to start the job afresh. Windowed, chooser and scoped runs are not the desktop and open nothing.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    (void)sender;(void)visible;
    if(self.windowed||!self.managing||self.scope)return NO;
    [self openSetupAssistant];
    return NO;
}
- (void)openSetupAssistant {
    NSTask *setup=[NSTask new];setup.executableURL=NSBundle.mainBundle.executableURL;setup.arguments=@[@"setup"];
    NSMutableDictionary<NSString *,NSString *> *environment=[NSProcessInfo.processInfo.environment mutableCopy];
    [environment removeObjectForKey:@"XPC_SERVICE_NAME"];setup.environment=environment;
    NSError *error=nil;if(![setup launchAndReturnError:&error])[self say:[NSString stringWithFormat:@"The setup assistant did not start: %@",error.localizedDescription]];
}
// macOS platform rule: applications outlive Infinify, where upstream's clients end with the compositor. A window still fullscreen, or
// still owed its size by a fullscreen that has ended, would keep the display's size after the canvas is gone, so each fullscreen is
// ended and its size transaction performed to its end before anything is shut down, one at a time, the slot being one. Upstream's
// quit ends fullscreen first too. The snapshot is read again before every step: toggle-fullscreen ends the focused window's
// fullscreen before the named output's, and on an output that has none it would enter one. With no fullscreen left, one read-only
// ipc request carries a size still owed. A resize the pointer began is cancelled first; the controller's own finishes. Bounded: an
// unanswered or uncertain resize is left to the shutdown that follows, and the scene then saves the size the window has.
- (void)endFullscreens {
    if(!self.resize)return;
    if(![self sizing])[self.resize cancel];
    CFTimeInterval deadline=CACurrentMediaTime()+3;
    for(int step=0;step<16;step++){
        while((self.resize.obligations||![self.resize canRemove:nil])&&CACurrentMediaTime()<deadline){self.statusText=@"Quit pending: waiting for native resize result";[self render];DWDesktopPump(.01);}
        if(self.resize.obligations||![self.resize canRemove:nil])return;
        NSArray *outputs=asArray([self call:@{@"op":@"snapshot"}][@"outputs"]);NSNumber *held=nil;
        for(id o in outputs)if(DWTyped(DWTyped(o,NSDictionary.class)[@"fullscreen"],NSDictionary.class)){held=DWTyped(DWTyped(o,NSDictionary.class)[@"id"],NSNumber.class);break;}
        NSNumber *output=held?:DWTyped(DWTyped(outputs.firstObject,NSDictionary.class)[@"id"],NSNumber.class);if(!output)return;
        NSString *status=self.statusText;
        NSDictionary *reply=[self call:held?@{@"op":@"action",@"output":held,@"action":@"toggle-fullscreen"}:@{@"op":@"ipc",@"output":output,@"request":@"State"}];
        if(!reply){self.statusText=status;return;}
        if(![self consumeSize:reply]&&!held)return;
    }
}
- (void)cleanup {
    if(self.cleaning)return;
    [self.dockReloader stop];self.dockReloader=nil;
    self.compositor.nativeMenuBackground=NO;
    [self stopMacWallpapers];
    [self cancelCapturedInputForWindow:nil];
    self.cleaning=YES;[self clearNativeFillPresentation];[self stopNativeTransferTimer];self.nativeOwnershipTransfer=nil;[self.canvasCursor reset];self.captureRecoveryGeneration++;self.captureRecoveryReading=NO;
    self.nativeMouseOwner=nil;
    for(LiveSource *source in self.sources.allValues){source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.observationEpoch;}
    [self.nativeFamilies reset];self.nativeFamilies=nil;self.nativeViewSnapshot=nil;self.nativeOwnerSnapshot=nil;self.nativeViewPresenter=nil;self.overlayFamilySnapshot=self.overlayFamilyBase=self.overlayFamilyDescriptions=nil;
    self.nativeSessionEpoch++;self.nativeResumeWanted=NO;
    [self.windowObserver cancel];self.windowObserver=nil;
    [self.globalTrackpad stop];self.globalTrackpad=nil;
    [self.multitouch stop];self.multitouch=nil;self.touchFeed=nil;[self.dockTap stop];self.dockTap=nil;self.dockGuard=nil;
    [self.nativeInput stop];self.nativeInput=nil;[self.pointerGrab reset];[self.relativeMotion reset];[self.tablet reset];
    // Native presentation ends first, while the canvas is still there: every window is put back where and as it was before anything
    // else is shut down, so no wait further down (a size owed, a fullscreen ending) is spent with a window parked or scaled.
    [self.native finish];
    CFTimeInterval restoredBy=CACurrentMediaTime()+2.1;
    while(self.nativeRestoring&&CACurrentMediaTime()<restoredBy)DWDesktopPump(.01);
    // No window is discovered and no read answers from here on; a reopened canvas gets a new manager, which ends a pass of its own.
    [self.manager stop];self.manager=nil;self.adopted=NO;
    // Nor is a panel put back in front or rebuilt: the session watch ends with the canvas, and a reopened one makes its own.
    [self.session stop];self.session=nil;self.desktopUp=NO;self.sessionInactive=NO;
    // Inert from here until the canvas reopens: no config hot key, tap watch, key repeat, input-source observer, config watch, hot corner, pending event, pan launch or pointer report outlives this line.
    [self.hotKeys invalidate];self.hotKeys=nil;[self.tapKeys stop];self.tapKeys=nil;[self.configWatcher stop];self.configWatcher=nil;self.corners=nil;[self.statePush invalidate];self.statePush=nil;[self.panLaunch cancel];self.pointerOutputs=nil;self.pointerWanted=NO;
    // A trackpad gesture in progress ends cancelled while its output still exists; no touch or hold timer outlives this line either.
    [self cancelGestures];self.trackpad=nil;
    // Nor a tracking area or a pending hover: cleanup keeps handling events while it waits for streams.
    for(DesktopView *view in self.views)[view.hover stop];
    [self endFullscreens];
    [self.resize shutdown];[self stopNavigation];
    // Effects are answered within the watchdog's three seconds; shutdown still has a five-second bound.
    CFTimeInterval drained=CACurrentMediaTime()+5;
    while(self.resize.obligations&&CACurrentMediaTime()<drained){self.statusText=@"Quit pending: waiting for native resize result";[self render];DWDesktopPump(.01);}
    if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize uncertainty remains unresolved at shutdown";fprintf(stderr,"%s\n",self.statusText.UTF8String);}
    [self saveScene];
    for(DesktopView *view in self.views)[view releasePressed];
    NSArray *closing=self.sources.allValues;
    for(LiveSource *source in closing)[self detach:source];
    // Streaming lifetime is separate from controller removal: uncertainty retains
    // the binding but cannot leave callbacks alive across controller destruction.
    for(LiveSource *source in self.sources.allValues)if(source.stream&&![self.pendingStops containsObject:source]){
        source.detached=YES;[self.pendingStops addObject:source];
        [source.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{source.streamStopped=YES;source.stream=nil;[self.pendingStops removeObject:source];});}];
    }
    CFTimeInterval stopDeadline=CACurrentMediaTime()+2;
    while(self.pendingStops.count&&CACurrentMediaTime()<stopDeadline){self.statusText=@"Shutdown pending: waiting for capture streams";DWDesktopPump(.01);}
    if(self.pendingStops.count){self.captureStopsTimedOut=self.pendingStops.count;fprintf(stderr,"Infinify: %lu capture stops did not complete within 2 s; detached callbacks are ignored during process exit\n",(unsigned long)self.captureStopsTimedOut);[self.pendingStops removeAllObjects];}
    for(DesktopView *view in self.views)for(NSNumber *output in view.outputs){NSDictionary *reply=[self call:@{@"op":@"remove_output",@"output":output}];[self.resize consume:reply];}
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}[self.panels removeAllObjects];[self.views removeAllObjects];
    // Every compositor layer, kept pixel buffer and background program goes with the panels.
    [self.compositor reset];self.compositor=nil;self.backgroundNote=nil;
    [self stopKeys];
    if(!self.sources.count)self.resize=nil;
    [self putBackWindowSettings];
}
@end
