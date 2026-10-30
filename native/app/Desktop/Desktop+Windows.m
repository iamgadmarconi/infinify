// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop window lifecycle: attach, discovery (DWWindowHost), tracking, visibility, close, the --manual chooser.
#import "Desktop+Private.h"
#import <unistd.h>
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWWindowEvents.h"
#import "DWNativeFamily.h"
#import "DWGeometryJSON.h"
#import "FixtureWindow.h"
static NSTextField *label(NSString *text, NSRect rect) {
    NSTextField *f=[NSTextField labelWithString:text]; f.frame=rect; return f;
}

// How long a window the manager does not take for its own, but that belongs to a placed root's family, is left to the family reconciliation before the helper's veil is released for it.
static const NSTimeInterval DWFamilyChildGrace=.25;
// Only the AXMoved callback may publish this translated cache. A generic
// observation may retain it privately, but cannot make it hit-test authority.
static NSDictionary *DWNativeMovedButtons(NSDictionary *report,NSDictionary *identity,CGRect native) {
    CGRect old=DWRectFromJSON(report[@"native_bounds"]);double sampled=[report[@"sampled_at"]doubleValue],age=CACurrentMediaTime()-sampled;
    if(!report||![report[@"identity"]isEqual:identity]||!isfinite(sampled)||sampled<=0||age<0||age>.5
        ||!isfinite(native.origin.x)||!isfinite(native.origin.y)||!isfinite(native.size.width)||!isfinite(native.size.height)
        ||native.size.width<=0||native.size.height<=0||!CGSizeEqualToSize(old.size,native.size))return nil;
    NSMutableDictionary *moved=[report mutableCopy];moved[@"native_bounds"]=DWRectJSON(native);return moved.copy;
}

@implementation Desktop (Windows)
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
- (void)refreshChoices:(id)sender {
    (void)sender;if(self.chooser)[self fillRebind:YES];[self.choices removeAllObjects];[self.table reloadData];
    if(self.startupError){self.chooserStatus.stringValue=self.startupError;return;}
    // The app asks macOS for a grant only from the user's own click on this button.
    BOOL capture=CGPreflightScreenCaptureAccess();self.grant.hidden=capture&&AXIsProcessTrusted();self.grant.title=capture?@"Allow input…":@"Allow screen recording…";
    if(!capture){self.chooserStatus.stringValue=@"No windows are listed: Infinify has no Screen Recording access. Click Allow screen recording…, enable Infinify in System Settings, then quit and reopen. Open canvas works without it.";return;}
    self.chooserStatus.stringValue=@"Reading available local windows…";
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        self.shareable=content.windows;[self.choices removeAllObjects];
        for(SCWindow *w in content.windows){NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.owningApplication.processID];if(w.windowLayer!=0||w.owningApplication.processID==getpid()||w.frame.size.width<40||w.frame.size.height<40||app.activationPolicy!=NSApplicationActivationPolicyRegular)continue;
            [self.choices addObject:@{@"window":w,@"label":[NSString stringWithFormat:@"%@ — %@",w.owningApplication.applicationName,w.title.length?w.title:@"Untitled window"]}];}
        [self.table reloadData];self.chooserStatus.stringValue=error?error.localizedDescription:AXIsProcessTrusted()?@"Select a window explicitly. Native keyboard and IME stay with the selected application.":@"Viewing is available. Native input requires Accessibility access in System Settings.";
    });}];
}
// The Rebind drop-down: a new world window, or one of the world windows that has no source now. A --manual run's chooser stays open
// above the canvas, so there the list is made again by Refresh and after every Add (keep: what is chosen stays chosen while it can still be rebound).
- (void)fillRebind:(BOOL)keep {
    NSNumber *chosen=keep?self.rebind.selectedItem.representedObject:nil;
    [self.rebind removeAllItems];[self.rebind addItemWithTitle:@"Create a new world window"];
    for(NSDictionary *w in [self call:@{@"op":@"snapshot"}][@"windows"])if(!self.sources[w[@"window"]]){[self.rebind addItemWithTitle:[NSString stringWithFormat:@"Rebind %@: %@",w[@"window"],w[@"metadata"][@"title"]?:@"window"]];self.rebind.lastItem.representedObject=w[@"window"];}
    NSInteger kept=chosen?[self.rebind indexOfItemWithRepresentedObject:chosen]:-1;if(kept>=0)[self.rebind selectItemAtIndex:kept];
}
- (void)showChooser:(id)sender {
    if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize is pending or unresolved; source retained";[self render];return;}
    [self cancelNavigation];
    (void)sender;
    if(!self.chooser){self.chooser=[[(FixtureWindow.class) alloc]initWithContentRect:NSMakeRect(200,180,720,470) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.chooser.title=@"Infinify — choose native windows";self.chooser.level=NSFloatingWindowLevel+1;self.chooser.releasedWhenClosed=NO;self.chooser.delegate=self;
        NSView *v=self.chooser.contentView;NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(18,130,684,315)];scroll.hasVerticalScroller=YES;
        self.table=[[NSTableView alloc]initWithFrame:scroll.bounds];NSTableColumn *column=[[NSTableColumn alloc]initWithIdentifier:@"Window"];column.title=@"Application — native window";column.width=675;[self.table addTableColumn:column];self.table.dataSource=self;self.table.delegate=self;scroll.documentView=self.table;[v addSubview:scroll];
        self.chooserStatus=label(@"",NSMakeRect(18,55,480,60));self.chooserStatus.maximumNumberOfLines=3;[v addSubview:self.chooserStatus];
        self.grant=[NSButton buttonWithTitle:@"" target:self action:@selector(grantAccess:)];self.grant.frame=NSMakeRect(507,70,195,30);self.grant.hidden=YES;[v addSubview:self.grant];
        self.rebind=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(18,15,205,30) pullsDown:NO];[v addSubview:self.rebind];
        NSButton *attach=[NSButton buttonWithTitle:@"Add selected window" target:self action:@selector(attachChoice:)];attach.frame=NSMakeRect(229,15,170,30);[v addSubview:attach];
        NSButton *canvas=[NSButton buttonWithTitle:@"Open canvas" target:self action:@selector(openCanvas:)];canvas.frame=NSMakeRect(405,15,120,30);canvas.toolTip=@"Show the saved world without adding a window";[v addSubview:canvas];
        NSButton *refresh=[NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshChoices:)];refresh.frame=NSMakeRect(531,15,85,30);[v addSubview:refresh];
        NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:self action:@selector(quit:)];quit.frame=NSMakeRect(622,15,80,30);[v addSubview:quit];}
    [self fillRebind:NO];
    [self.chooser makeKeyAndOrderFront:nil];[NSApp activate];[self refreshChoices:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;if(!self.panels.count)stopped=1;return YES; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView;return self.choices.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {(void)tableView;(void)column;return self.choices[row][@"label"];}
- (void)grantAccess:(id)sender {
    (void)sender;BOOL capture=CGPreflightScreenCaptureAccess();
    if(!capture)CGRequestScreenCaptureAccess();else AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES});
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:capture?@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility":@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    self.chooserStatus.stringValue=capture?@"Enable Infinify under Accessibility, then click Refresh.":@"Enable Infinify under Screen & System Audio Recording, then quit and reopen Infinify.";
}
- (void)attachChoice:(id)sender {
    (void)sender;NSInteger row=self.table.selectedRow;if(row<0||row>=(NSInteger)self.choices.count){if(CGPreflightScreenCaptureAccess())self.chooserStatus.stringValue=@"Select a source window first.";else [self refreshChoices:nil];return;}
    [self openPanels];NSNumber *logical=self.rebind.selectedItem.representedObject;
    BOOL added=[self attach:[DWWindowCandidate candidateWithShareable:self.choices[row][@"window"]] logical:logical world:nil];[self fillRebind:YES];
    if(added){[self saveScene];[self render];}else self.chooserStatus.stringValue=self.statusText;
}
- (BOOL)attach:(DWWindowCandidate *)window logical:(NSNumber *)logical world:(NSDictionary *)world { return [self attach:window logical:logical world:world placed:NO]; }
// placed: a window that appeared by itself. It is sent with neither a logical id nor a
// world rectangle, so the controller adopts it into a matching slot or places it by
// window_placement around the active output and the pointer. Only its size is native.
// The one place a native window is bound: the only LiveSource, Router and identity made, and the
// only attach command sent. Under --only-pid a window of any other process is refused here before any of them exists, so
// nothing that acts on a native window (native focus, a forwarded press or motion, close, native resize) has one to act on.
- (BOOL)attach:(DWWindowCandidate *)window logical:(NSNumber *)logical world:(NSDictionary *)world placed:(BOOL)placed {
    if([self nativeUnavailable]){self.statusText=@"Native presentation is reconnecting; window discovery will retry";return NO;}
    if(!placed)[self cancelNavigation];
    pid_t pid=window.pid;uint32_t wid=window.window;
    if(!DWInScope(self.scope,pid)){self.statusText=@"Not attached: its process is outside --only-pid";return NO;}
    // Under a scope the start time is the one DWInScope has just matched, not a second reading that another process could answer.
    NSArray *processBirth=self.scope?self.scope[@(pid)]:birth(pid);NSDictionary *info=windowInfo(wid);CGRect bounds=CGRectZero;
    NSDictionary *created=window.nativeIdentity;
    if(created&&(![created[@"pid"]isEqual:@(pid)]||![created[@"wid"]isEqual:@(wid)]||processBirth.count!=2||
        ![created[@"birth_sec"]isEqual:processBirth[0]]||![created[@"birth_usec"]isEqual:processBirth[1]])){self.statusText=@"Source identity changed after its creation notification";return NO;}
    if(!processBirth||[info[(id)kCGWindowOwnerPID]intValue]!=pid||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)){self.statusText=@"Source closed or identity changed; refresh the chooser.";return NO;}
    if(window.displayFixed&&(!self.native||[info[(id)kCGWindowLayer]integerValue]!=NSFloatingWindowLevel)){self.statusText=@"Utility panel changed its native level before adoption";return NO;}
    // Native presentation: the window's own frame, not where the helper may still be drawing it for a run that ended without restoring.
    NSDictionary *frame=info[(id)kCGWindowBounds];
    if(self.native){if(!DWNativeBounds(wid,&bounds)){self.statusText=@"Not attached: the window server did not give the window's own frame";return NO;}frame=CFBridgingRelease(CGRectCreateDictionaryRepresentation(bounds));}
    for(LiveSource *existing in self.sources.allValues)if(existing.router.pid==pid&&existing.router.wid==wid){self.statusText=@"This source is already attached; every display can view the same world window.";return NO;}
    LiveSource *source=[LiveSource new];source.router=[Router new];source.router.pid=pid;source.router.wid=wid;source.router.processBirth=processBirth;source.router.bounds=frame;source.router.tag=(int64_t)(arc4random_uniform(0x7fffff)+1)*100;source.router.eventSource=CGEventSourceCreate(kCGEventSourceStatePrivate);
    [self.postingTags addObject:@(source.router.tag)];
    BOOL privateAvailable=[source.router loadPrivate];source.identity=@{@"pid":@(pid),@"birth_sec":processBirth[0],@"birth_usec":processBirth[1],@"wid":@(wid)};
    if(self.native&&![self.native allowsWindow:source.identity])return NO;
    source.buffer=CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2));
    NSMutableDictionary *command=[@{@"op":@"attach",@"identity":source.identity,@"bundle_id":window.bundleIdentifier?:@"",@"title":window.title?:@"Untitled",@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)},@"source_rect":DWRectJSON(bounds)} mutableCopy];
    if(placed){NSNumber *output=[self viewOutput];if(output)command[@"output"]=output;command[@"pointer"]=pointJSON(pointer());}
    else if(logical)command[@"logical_id"]=logical;else {if(!world){NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];NSDictionary *o=[snapshot[@"outputs"]firstObject];double zoom=[o[@"zoom"]doubleValue];CGPoint camera=jsonPoint(o[@"camera"]);world=DWRectJSON(CGRectMake(camera.x+30/MAX(.001,zoom),camera.y+30/MAX(.001,zoom),bounds.size.width,bounds.size.height));}command[@"world_rect"]=world;}
    if(window.displayFixed){
        NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*chosen=nil;double best=INFINITY;
        CGPoint center=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
        for(NSDictionary *output in snapshot[@"outputs"]){CGRect screen=DWRectFromJSON(output[@"screen_bounds"]);if(CGRectIsEmpty(screen))continue;
            double dx=center.x-fmin(CGRectGetMaxX(screen),fmax(CGRectGetMinX(screen),center.x)),dy=center.y-fmin(CGRectGetMaxY(screen),fmax(CGRectGetMinY(screen),center.y));double distance=dx*dx+dy*dy;
            if(distance<best){best=distance;chosen=output;}}
        if(!chosen){self.statusText=@"Utility panel has no live display to pin to";return NO;}
        CGRect screen=DWRectFromJSON(chosen[@"screen_bounds"]);
        command[@"screen_pin"]=@{@"output":chosen[@"id"],@"screen_pos":pointJSON(CGPointMake(bounds.origin.x-screen.origin.x,bounds.origin.y-screen.origin.y))};
    }
    NSDictionary *reply=[self call:command];source.logical=reply[@"window"];if(!source.logical)return NO;source.observationToken=++self.observationEpoch;self.sources[source.logical]=source;
    source.window=self.native?nil:window.shareable;source.nativeReplica=self.native!=nil;[self.native bound:source.identity bounds:bounds];source.title=DWTyped(info[(id)kCGWindowName],NSString.class)?:command[@"title"];
    [self refreshNativeButtons:source];
    // A new frame redraws only the outputs that show this window. The first picture of a window that just opened begins its open animation, which the frame timer plays.
    {__weak Desktop *weak=self;NSNumber *logical=source.logical;source.presented=^{Desktop *d=weak;if([d.compositor contentChanged:logical])[d startFrames];};}
    // A window rule's size: the controller began its size transaction with the attach, and the coordinator performs it as it
    // performs a sizing action's. Its result reaches the controller on a later turn of the main queue, after this method.
    // Until it has settled the compositor is given no picture of the window, so its open animation waits with it (-render: there).
    if(placed)[self consumeSize:reply];
    // A managed run captures on demand: -captureDemand starts the stream once the window has a placement.
    if(!self.manager&&![self startCapture:source size:source.buffer interval:[self captureInterval]]&&!source.captureRecovering){[self detach:source];return NO;}
    if(!privateAvailable)self.statusText=@"Live view only: private per-window input is unavailable on this OS.";
    if(placed){if(self.navigationTap&&self.navigationTapSource&&CGEventTapIsEnabled(self.navigationTap))[self.navigation preserveBackgroundArrival:reply];[self follow:reply];}
    [self render];return YES;
}
// A window that came, went or was renamed by itself: the flight its reply armed is
// flown, and the scene is saved on the next poll unless the reply says nothing changed.
// Its focus request, for a new window or for the one that follows a close, is the
// coordinator's to perform on the native window or to answer focus_logical, like the
// request of any other reply; a reply without one withdraws only work in flight for a
// request the controller has dropped. Such a reply carries no other effect, but for the size transaction of a window whose
// rule names a size, which -attach:logical:world:placed: hands to the resize coordinator itself.
- (void)follow:(NSDictionary *)reply {
    NSDictionary *effect=DWTyped(reply[@"effect"],NSDictionary.class);[self.navigation perform:effect?@{@"effect":effect}:@{}];
    if(DWTyped(reply[@"navigation"],NSDictionary.class)){if(!self.navigation)self.flying=YES;[self ensureFrames];}
    if(![reply[@"dirty"]isEqual:@NO])self.sceneDirty=YES;
}
// Native readback: is a size transaction of this window live with no effect owed? Only a resize grab is, between two sizes it asks: the
// controller takes no close, removal or observation of the window meanwhile, exactly as while a result is owed.
- (BOOL)grabbed:(LiveSource *)source { return self.resize&&![[self.resize busyWindow]isEqual:source.logical]&&![self.resize canRemove:source.logical]; }
- (void)detach:(LiveSource *)source {
    [self cancelNavigation];
    // Only this window's transaction is cancelled: its last read is then all that is waited for.
    // A resize grab of this window at rest owes no result and is cancelled the same way: one read follows, and ends it.
    if(source.detached)return;if([[self.resize busyWindow]isEqual:source.logical]||[self grabbed:source])[self.resize cancel];
    [self cancelCapturedInputForWindow:source.logical];
    for(DesktopView *view in self.views)if(view.pressedSource==source)[view releasePressed];
    if(![self call:@{@"op":@"remove_source",@"window":source.logical,@"identity":source.identity,@"keep_placeholder":@YES}])return;
    [self drop:source];
}
// The shell's half of a source the controller no longer binds: held button, kept frame, stream and table.
- (void)drop:(LiveSource *)source {
    [self cancelCapturedInputForWindow:source.logical];
    [self forgetNativeFamily:source];
    for(DesktopView *view in self.views)if(view.pressedSource==source)[view releasePressed];source.detached=YES;[self.native unbound:source.identity];[source clearSample];[self.manager forget:source.logical];
    // Capture on demand may have stopped the stream already: only a stop that was asked for is waited on.
    if(source.stream){[self.pendingStops addObject:source];[source.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{source.streamStopped=YES;source.stream=nil;[self.pendingStops removeObject:source];});}];}else source.streamStopped=YES;
    [self.sources removeObjectForKey:source.logical];
}
// The native window is gone. The controller takes its world window off the canvas, or
// leaves a stand-in under session.suspend_on_close, and moves focus as upstream's
// toplevel_destroyed does, flying on the active output when auto_navigate_on_close asks.
// A refusal keeps the world place the way a lost source always did.
- (void)closed:(LiveSource *)source {
    if(source.detached)return;
    NSMutableDictionary *command=[@{@"op":@"window_closed",@"window":source.logical,@"identity":source.identity}mutableCopy];NSNumber *output=[self viewOutput];if(output)command[@"output"]=output;
    NSDictionary *reply=[self call:command];
    if(!reply){[self detach:source];return;}
    [self drop:source];[self follow:reply];[self render];
}
- (BOOL)managesWindow:(CGWindowID)window pid:(pid_t)pid {
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window)return YES;
    return NO;
}
- (void)windowAppeared:(DWWindowCandidate *)window {
    // The manager has marked it offered and will not offer it again while it stays: a window nothing here can adopt now is let go.
    if(self.cleaning||!self.panels.count){[self windowNotAdopted:window.window pid:window.pid];return;}
    // A positively identified child belongs to its already managed native
    // parent. Do not also adopt it as an independent canvas root.
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.pid==window.pid&&source.router.wid!=window.window){
        NSMutableDictionary *identity=[source.identity mutableCopy];identity[@"wid"]=@(window.window);
        if(DWNativeWindowBelongsToRoot(identity,source.identity)){[self windowFamilyChanged:window.pid];return;}
    }
    // Its focus event may have come before it was bound, and no other follows: native focus is read again at the next poll, not a reconciliation later.
    if([self attach:window logical:nil world:nil placed:YES]){self.lastObservation=0;return;}
    // Nobody chose this window: a refusal is a passing note.
    NSString *note=[NSString stringWithFormat:@"%@ window not adopted: %@",window.applicationName?:@"A",self.statusText?:@"refused"];
    [self say:note];[self flashStatus:note];[self render];
    [self windowNotAdopted:window.window pid:window.pid];
}
// The helper's arrival veil holds a new window invisible until a frame places it; one that is never to be placed is let go at once
// rather than at the helper's own bound. Several arrive together at times, so the frame that carries their releases is made once.
- (void)windowNotAdopted:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning||!self.native||self.native.ended)return;
    // A window the manager does not take for a window of its own may still be a child of a root that is placed (a hover card, a completion list,
    // a sheet): the family reconciliation places it with its root, which also lifts the helper's veil. Releasing it at once would show it where
    // the application put it, not where the browser is drawn. It is released after DWFamilyChildGrace if nothing has placed it by then.
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.pid==pid&&source.router.wid!=window){
        NSMutableDictionary *identity=[source.identity mutableCopy];identity[@"wid"]=@(window);
        if(!DWNativeWindowBelongsToRoot(identity,source.identity))continue;
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native decline deferred pid=%d wid=%u root=%u at=%.6f\n",(int)pid,(unsigned)window,(unsigned)source.router.wid,NSProcessInfo.processInfo.systemUptime);
        [self windowFamilyChanged:pid];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(DWFamilyChildGrace*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self releaseUnplacedWindow:window pid:pid];});
        return;
    }
    [self releaseUnplacedWindow:window pid:pid];
}
// The release itself. The presenter refuses it for a window it has bound, so one the family placed in the meantime is never released.
- (void)releaseUnplacedWindow:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning||!self.native||self.native.ended)return;
    NSArray *born=birth(pid);if(born.count!=2)return;
    if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native decline pid=%d wid=%u at=%.6f\n",(int)pid,(unsigned)window,NSProcessInfo.processInfo.systemUptime);
    [self.native declineWindow:@{@"pid":@(pid),@"wid":@(window),@"birth_sec":born[0],@"birth_usec":born[1]}];
    if(self.declineFrameQueued)return;
    self.declineFrameQueued=YES;
    dispatch_async(dispatch_get_main_queue(),^{self.declineFrameQueued=NO;if(!self.cleaning&&!self.sessionInactive&&self.native&&!self.native.ended)[self render];});
}
// macOS platform rule: on Wayland quitting the compositor ends its clients, here
// applications outlive Infinify. The saved scene keeps one slot per window, the windows
// on screen were just adopted into theirs, `present` names the ones that exist off
// screen, whose slots keep waiting, and the controller now drops the slots nothing
// matched unless session.restore_windows keeps them as dormant stand-ins.
// Sent once per manager, and always: at launch, where until it arrives the controller
// treats every window as one that was already open and neither focuses nor reveals it,
// and again by a canvas reopened after Return to desktop, whose windows returned to
// their slots while one that closed in between left its slot behind.
- (void)discoveryCompleted:(NSArray<NSDictionary *> *)present {
    if(self.adopted||self.cleaning)return;self.adopted=YES;
    NSString *status=self.statusText;NSDictionary *reply=[self call:@{@"op":@"adoption_complete",@"present":present?:@[]}];
    if(!reply){fprintf(stderr,"adoption_complete: %s\n",self.statusText.UTF8String);self.statusText=status;return;}
    [self follow:reply];[self render];
}
// The manager reads again about every two seconds: the status note is renewed each
// time, stderr gets each distinct reason once.
- (void)discoveryFailed:(NSString *)reason {
    NSString *note=[@"Windows could not be listed: " stringByAppendingString:reason];
    if(![note isEqual:self.discoveryNote]){self.discoveryNote=note;[self say:note];}
    [self flashStatus:note];[self render];
}
// Did close-window or suspend-window ask this window to close? The controller's mark.
- (BOOL)marked:(LiveSource *)source { return DWTyped([self call:@{@"op":@"snapshot"}][@"lifecycle"][@"marks"],NSDictionary.class)[source.logical.stringValue]!=nil; }
- (void)requestWindowObservation {
    if(self.cleaning||self.sessionInactive||self.native.ended||!self.manager)return;
    if(!self.windowObserver)self.windowObserver=[DWWindowObserver new];if(self.windowObserver.inFlight)return;
    self.windowObservationAgain=NO;
    NSMutableArray *requests=[NSMutableArray array];
    for(LiveSource *source in self.sources.allValues)if(!source.detached){
        NSMutableDictionary *request=[@{@"logical":source.logical,@"generation":@(source.observationToken),@"identity":source.identity,@"native_bounds":@(self.native!=nil),@"families":@(self.native.familiesNeeded||source.nativeTransferFamilyWanted)}mutableCopy];
        if(source.nativeVisibilityWanted&&CACurrentMediaTime()>=source.nativeVisibilityRetryAt)request[@"visibility_revision"]=@(source.nativeVisibilityRevision);
        if(source.router.bounds)request[@"prior_bounds"]=source.router.bounds;[requests addObject:request];
    }
    DWWindowManager *manager=self.manager;DWNativePresenter *presenter=self.native;uint64_t session=self.nativeSessionEpoch;__weak Desktop *weak=self;__block BOOL reconcile=NO;
    [self.windowObserver requestSources:requests scope:self.scope nativeDiscoveryExclusions:self.native?manager.offeredWindows:nil discovery:^(DWWindowObservationSnapshot *snapshot){
        Desktop *d=weak;CFTimeInterval now=CACurrentMediaTime();
        if(!d||d.cleaning||d.sessionInactive||d.manager!=manager||d.native!=presenter||d.native.ended||d.nativeSessionEpoch!=session
            ||!snapshot.listSucceeded||now-snapshot.startedAt>.1||now-snapshot.finishedAt>.1)return;
        // Timely discovery does not wait behind audits of already bound roots.
        // Adoption still performs its fresh native identity/authority checks.
        reconcile=[manager pollWithWindowRecords:snapshot.orderedOnScreen nativeCandidateBases:snapshot.nativeCandidateBases sampledAt:snapshot.startedAt];
    } completion:^(DWWindowObservationSnapshot *snapshot){
        Desktop *d=weak;CFTimeInterval now=CACurrentMediaTime();
        if(!d||d.cleaning||d.sessionInactive||d.manager!=manager||d.native!=presenter||d.native.ended||d.nativeSessionEpoch!=session)return;
        @try {
        if(!snapshot.listSucceeded||now-snapshot.startedAt>.1||now-snapshot.finishedAt>.1){
            BOOL changed=NO;
            for(DWWindowObservation *observation in snapshot.sources){NSDictionary *request=observation.request;LiveSource *source=d.sources[request[@"logical"]];
                if(source&&source.observationToken==[request[@"generation"]unsignedLongLongValue]&&[source.identity isEqual:request[@"identity"]]&&source.nativeFamily){
                    // This cache has no age-based lifetime. A late, successful
                    // read of exactly the same complete family is a missed
                    // refresh, not evidence that the previous audit changed.
                    // Adopt nothing from it; ordinary idle reconciliation will
                    // retry. Failed or changed reads still revoke the cache.
                    NSDictionary *cached=source.nativeFamily;
                    BOOL unchanged=snapshot.listSucceeded&&observation.state==DWWindowObservationPresent&&observation.hasBounds
                        &&[source.router.bounds isEqual:request[@"prior_bounds"]]
                        &&boundIdentity(cached[@"identity"],source.identity)&&boundIdentity(observation.family[@"identity"],source.identity)
                        &&[observation.family[@"root"]isEqual:source.identity[@"wid"]]
                        &&CGRectEqualToRect(DWRectFromJSON(cached[@"native_bounds"]),observation.bounds)
                        &&[asArray(cached[@"members"])isEqual:asArray(observation.family[@"members"])];
                    if(unchanged)continue;
                    [d forgetNativeFamily:source];changed=YES;}}
            if(changed&&!d.frameFlying)[d render];return;
        }
        BOOL describe=NO;
        for(DWWindowObservation *observation in snapshot.sources){
            NSDictionary *request=observation.request;LiveSource *source=d.sources[request[@"logical"]];
            if(!source||source.detached||source.observationToken!=[request[@"generation"]unsignedLongLongValue]||![source.identity isEqual:request[@"identity"]]||![source.router.bounds isEqual:request[@"prior_bounds"]]||CACurrentMediaTime()-observation.sampledAt>.1)continue;
            // Discovery can stay eager after an appearance hint without asking
            // the controller to observe every unchanged overlay root again.
            if(!presenter&&!reconcile&&!source.error&&!source.destroyed)continue;
            [d observeVisibility:observation source:source];
            if(observation.state==DWWindowObservationReadFailed){[d forgetNativeFamily:source];continue;}
            if(observation.state!=DWWindowObservationPresent){[d track:source];describe=YES;continue;}
            if(!DWInScope(d.scope,source.router.pid))continue;
            [d track:source info:observation.info observation:observation];describe=YES;
        }
        if(!d.frameFlying&&(describe||d.sceneDirty))[d render];
        } @finally {if(!d.cleaning&&d.windowObservationAgain)[d requestWindowObservation];}
    }];
}
// One look at one bound window: is it gone, was it retitled, where and how large is it now. The poll's look and an event's are this one
// method. Events read afresh; poll observations carry a bounded worker read with
// an unchanged source identity/generation/previous-bounds fence. A second look
// that finds nothing new sends no window_closed and no retitle.
- (void)track:(LiveSource *)source { [self track:source info:windowInfo(source.router.wid)]; }
- (void)track:(LiveSource *)source info:(NSDictionary *)w { [self track:source info:w observation:nil]; }
- (void)track:(LiveSource *)source info:(NSDictionary *)w observation:(DWWindowObservation *)observation {
        source.observationToken=++self.observationEpoch;
        if(self.native&&(self.sessionInactive||self.native.ended)){[self forgetNativeFamily:source];return;}
        // Miniaturization can temporarily remove a WindowServer record. A
        // live process without a destroy hint keeps its minimized binding.
        if(!w&&(source.nativeMinimized||(source.nativeVisibilityHeld&&source.nativeVisibilityWanted))&&!source.destroyed
            &&[birth(source.router.pid)isEqual:source.router.processBirth])return;
        BOOL gone=sourceGone(source,w)||[self destroyed:source info:w];
        if(gone)[self forgetNativeFamily:source];
        // WindowServer owns the complete physical pair and final settling.
        // Neither raw-origin reconciliation nor presenter bounds may race it.
        if(source.nativeMouseOwnership&&!source.nativeMouseAdopting&&!gone)return;
        // Titles follow in a managed run, under native resize too. A refused title is not offered again.
        NSString *title=self.manager&&!gone?DWTyped(w[(id)kCGWindowName],NSString.class):nil;
        if(title&&![title isEqual:source.title]){[source invalidateNativeButtons];source.title=title;NSString *status=self.statusText;NSDictionary *reply=[self call:@{@"op":@"retitle",@"window":source.logical,@"identity":source.identity,@"title":title}];if(reply)[self follow:reply];else self.statusText=status;}

        // A managed run tells a window that closed from a capture that failed: only the second keeps today's placeholder.
        // A manual run does so for a window close-window or suspend-window asked to close: the controller's mark decides what is left.
        // A size request of this window is still owed its result. The controller takes no close, removal or observation of the window until
        // it has one (bounded: the adapter's deadline, then the coordinator's watchdog), and the end of the transaction looks at the window
        // again (-configureResize). Its bounds are not read meanwhile either: the look that follows the transaction reports them.
        BOOL busy=[[self.resize busyWindow]isEqual:source.logical];
        if(gone&&busy)return;
        // A resize grab of this window whose pointer rests: no result is owed that would find the window gone, so the grab is cancelled
        // here. The one read that follows fails, the transaction ends, and its end looks at the window again and finds it closed. While
        // the window is there its frame is the transaction's to read, not this look's.
        if([self grabbed:source]){if(gone)[self.resize cancel];return;}
        if(gone&&(self.manager||[self marked:source])){[self closed:source];return;}
        if((source.error&&!source.captureRecovering&&!source.nativeReplica)||gone){self.statusText=source.error?:@"A source closed. Its world placeholder is retained for explicit rebind.";[self detach:source];return;}
        if(source.nativeMinimized&&!source.nativeVisibilityWanted&&[w[(id)kCGWindowIsOnscreen]boolValue]){
            [self requestVisibility:source];return; // bounded recovery for a missed deminiaturized hint
        }
        if(source.nativeMinimized||source.nativeVisibilityHeld)return;
        CGRect bounds=CGRectZero;NSDictionary *frame=w[(id)kCGWindowBounds],*family=nil;
        // Native presentation: the window list's bounds are where the helper draws the window, at the size the zoom gives it. Observed
        // as the window's size they would become its world size, drawn smaller again on the next frame, and so on. The window's own
        // frame is read instead, which no transform changes, and the presenter draws from it.
        if(self.native){
            if(busy)return;
            // A deliberately unrequested family is different from a requested
            // audit that failed. Only explicit families:false permits nil; a
            // missing flag or failed requested report still revokes readiness.
            BOOL familyRequested=observation?![observation.request[@"families"]isEqual:@NO]:(self.native.familiesNeeded||source.nativeTransferFamilyWanted);
            if(observation){if(!observation.hasBounds){[self forgetNativeFamily:source];return;}bounds=observation.bounds;family=observation.family;}
            else {if(!DWNativeBounds(source.router.wid,&bounds)){[self forgetNativeFamily:source];return;}if(familyRequested)family=DWNativeWindowFamily(source.identity,NULL);}
            frame=CFBridgingRelease(CGRectCreateDictionaryRepresentation(bounds));[self.native bound:source.identity bounds:bounds family:family?:(familyRequested?@{}:nil)];
        }
        else if(busy||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)frame,&bounds))return;
        // The application's origin is a presentation basis, not a canvas
        // movement. Display reflow and AppKit tiling can change it without a
        // user drag. Only our gesture path or the explicitly owned native
        // mouse pair may relocate the logical window.
        CGRect prior=CGRectZero;
        if(self.native&&DWDebugTrace()&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&prior)
            &&!CGPointEqualToPoint(prior.origin,bounds.origin))
            fprintf(stderr,"debug: native origin window=#%s pid=%d wid=%u old=(%g,%g,%g,%g) new=(%g,%g,%g,%g) raw_delta=(%g,%g) reconcile=basis_only\n",source.logical.description.UTF8String,source.router.pid,source.router.wid,prior.origin.x,prior.origin.y,prior.size.width,prior.size.height,bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height,bounds.origin.x-prior.origin.x,bounds.origin.y-prior.origin.y);
        if(![source.router.bounds isEqual:frame]){
            NSDictionary *candidate=source.nativeButtons?:source.nativeButtonsMoveCandidate;
            // A poll can observe a move before AXMoved is delivered. Retain no
            // public cache until that hint certifies this origin-only change.
            if(!self.native||!DWNativeMovedButtons(candidate,source.identity,bounds))candidate=nil;
            [source invalidateNativeButtons];source.nativeButtonsMoveCandidate=candidate;
            source.router.bounds=frame;
        }
        // Manual sources retry the latest native size after an earlier configuration completes too.
        if(!self.manager&&source.stream&&!CGSizeEqualToSize(source.captureNativeSize,bounds.size))[self updateCapture:source size:CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2)) native:bounds.size interval:[self captureInterval]];
        // A helper Space handoff can make AppKit reflow its own frame. Refresh
        // the true native basis without treating that presentation side effect
        // as a world resize. Explicit native mouse ownership remains user intent.
        BOOL spaceReflow=self.native&&[self.native observeSpaceReflow:source.identity bounds:bounds nativeInput:source.nativeMouseAdopting];
        if(spaceReflow&&DWDebugTrace()&&!CGSizeEqualToSize(prior.size,bounds.size))
            fprintf(stderr,"debug: native Space reflow window=#%s pid=%d wid=%u before=%gx%g observed=%gx%g world_size=preserved native_frame_restore=unowned\n",source.logical.description.UTF8String,source.router.pid,source.router.wid,prior.size.width,prior.size.height,bounds.size.width,bounds.size.height);
        DriftDesktopObservation controllerObservation={.window=source.logical.unsignedLongLongValue,.birth_sec=[source.identity[@"birth_sec"]longLongValue],.x=bounds.origin.x,.y=bounds.origin.y,.width=bounds.size.width,.height=bounds.size.height,.pid=[source.identity[@"pid"]intValue],.birth_usec=[source.identity[@"birth_usec"]intValue],.wid=[source.identity[@"wid"]unsignedIntValue],.owner=[source.identity[@"owner"]unsignedIntValue],.buffer_width=(uint32_t)source.buffer.width,.buffer_height=(uint32_t)source.buffer.height};
        BOOL current=self.native&&driftwm_desktop_observation_current(self.controller,&controllerObservation);
        if(!current){
            NSDictionary *seen=[self call:@{@"op":spaceReflow?@"observe_presentation":@"observe",@"window":source.logical,@"identity":source.identity,@"source_rect":DWRectJSON(bounds),@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)}}];
            if([DWTyped(seen[@"resized"],NSNumber.class)boolValue])self.sceneDirty=YES;
        }
        if(self.native){
            NSDictionary *binding=nil;if(family)for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical]){binding=DWTyped(window[@"source"],NSDictionary.class);break;}
            if(family&&boundIdentity(family[@"identity"],source.identity)&&boundIdentity(binding[@"identity"],source.identity)&&binding[@"generation"]&&[binding[@"observation_known"]boolValue]&&CGRectEqualToRect(DWRectFromJSON(binding[@"observed_rect"]),bounds)){
                NSDictionary *description=@{@"identity":source.identity,@"generation":binding[@"generation"],@"native_bounds":DWRectJSON(bounds),@"members":asArray(family[@"members"])?:@[]};
                if(![source.nativeFamily isEqual:description]){source.nativeFamily=description;self.nativeFamilyRevision++;}
            }else [self forgetNativeFamily:source];
        }
}
// A window its application reported destroyed is gone once it is also off screen, whether or not the window list still has its number: the
// list may drop it a moment after the report, and may keep it when the application keeps the window object to show again. Until then it
// is looked at on every poll. While the window is still on screen nothing is concluded, and a report still contradicted a second later is
// forgotten. Not observed on a real window: which applications report a window they keep as destroyed is not known.
- (BOOL)destroyed:(LiveSource *)source info:(NSDictionary *)info {
    if(!source.destroyed)return NO;
    if(![info[(id)kCGWindowIsOnscreen]boolValue])return YES;
    if(CACurrentMediaTime()-source.destroyed>1)source.destroyed=0;
    return NO;
}
// DWWindowHost, from the observers: the look the poll takes, taken now and at the windows concerned only.
- (void)windowMoved:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;BOOL matched=NO,changed=NO;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window){
        matched=YES;NSDictionary *report=source.nativeButtons?:source.nativeButtonsMoveCandidate,*identity=source.identity.copy;
        NSString *title=source.title;NSDictionary *prior=source.router.bounds;
        [source invalidateNativeButtons];[self track:source];
        CGRect native=CGRectZero,current=CGRectZero;NSDictionary *info=windowInfo(window);
        if(self.native&&!self.sessionInactive&&!self.native.ended&&self.sources[source.logical]==source&&!source.detached
            &&[source.identity isEqual:identity]&&[source.title isEqual:title]&&[birth(pid)isEqual:source.router.processBirth]
            &&DWInScope(self.scope,pid)&&[info[(id)kCGWindowOwnerPID]intValue]==pid
            &&DWNativeBounds(window,&native)&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&current)
            &&CGRectEqualToRect(native,current))source.nativeButtons=DWNativeMovedButtons(report,identity,native);
        [self refreshNativeButtons:source];if(source.title!=title||source.router.bounds!=prior)changed=YES;
    }
    if(!matched)[self windowFamilyChanged:pid];
    if(changed&&!self.frameFlying)[self render];
}
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;BOOL changed=NO,matched=NO;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&(!window||source.router.wid==window)){
        matched=YES;
        [source invalidateNativeButtons];
        NSString *title=source.title;NSDictionary *bounds=source.router.bounds;[self track:source];[self refreshNativeButtons:source];if(source.title!=title||source.router.bounds!=bounds)changed=YES;}
    if(!matched)[self windowFamilyChanged:pid];
    // A window that closed was drawn by -closed:. A look that found nothing new draws nothing: the reports of one busy application come 12 times a second.
    if(changed&&!self.frameFlying)[self render];
}
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;BOOL matched=NO;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window){matched=YES;[source invalidateNativeButtons];source.destroyed=CACurrentMediaTime();[self track:source];}
    if(!matched)[self windowFamilyChanged:pid];
}
- (void)windowFamilyChanged:(pid_t)pid {
    if(self.cleaning||self.sessionInactive||self.native.ended||(pid&&!DWInScope(self.scope,pid)))return;
    if(self.native&&!self.native.familiesNeeded){[self windowDiscoveryRequested];return;}
    [self.nativeFamilies invalidatePID:pid];
    if(!self.native){[self captureDemand];[self render];return;}
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&(!pid||source.router.pid==pid)){[self forgetNativeFamily:source];source.observationToken=++self.observationEpoch;[source invalidateNativeButtons];[self refreshNativeButtons:source];}
    // An application's first window has no bound source to invalidate. Its
    // creation hint still requests discovery now, through the same single-flight
    // observer; a hint during a read queues at most one fresh follow-up batch.
    [self windowDiscoveryRequested];
}
- (void)windowDiscoveryRequested {
    if(self.cleaning||self.sessionInactive||self.native.ended||!self.manager)return;
    self.windowObservationAgain=YES;[self requestWindowObservation];
}
// Native focus may have moved (Command-Tab, a click on another window): read now, through the coordinator's own path.
- (void)focusChanged { if(self.cleaning||[self nativeUnavailable]||!self.navigation)return;self.lastObservation=CACurrentMediaTime();[self refreshFocusAccess];[self.navigation observe]; }
@end
