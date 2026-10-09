// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit owned-fixture runner. Production capture acceptance remains untouched.
static NSDictionary *cg(uint32_t wid){return windowInfo(wid);}
#define rect rectJSON
#include "../families/window-server-family.h"
#undef rect
static BOOL rpNear(CGRect a,CGRect b) {return fabs(a.origin.x-b.origin.x)<=1&&fabs(a.origin.y-b.origin.y)<=1&&fabs(a.size.width-b.size.width)<=1&&fabs(a.size.height-b.size.height)<=1;}
// Independent readback: deliberately does not call the resize adapter or use its
// result, controller observed_rect, fixture subview frames, or capture crop.
static NSDictionary *rpObserveDetailed(pid_t pid,NSArray *expectedBirth,uint32_t wid,NSMutableDictionary *details) {
    BOOL birthMatches=[birth(pid)isEqual:expectedBirth];details[@"pid_birth_matches"]=@(birthMatches);if(!birthMatches)return nil;
    AXError (*getID)(AXUIElementRef,uint32_t *)=dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");details[@"ax_window_id_symbol"]=@(getID!=NULL);if(!getID)return nil;
    AXUIElementRef app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,.15);CFTypeRef list=NULL;
    AXError error=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&list);CFRelease(app);details[@"ax_windows_error"]=@(error);details[@"ax_windows_array"]=@(list&&CFGetTypeID(list)==CFArrayGetTypeID());
    if(error||!list||CFGetTypeID(list)!=CFArrayGetTypeID()){if(list)CFRelease(list);return nil;}
    details[@"ax_window_count"]=@(CFArrayGetCount((CFArrayRef)list));
    CGPoint point=CGPointZero;CGSize size=CGSizeZero;NSUInteger matches=0;BOOL valid=YES;double deadline=CACurrentMediaTime()+.8;
    for(id object in (__bridge NSArray *)list){
        AXUIElementRef element=(__bridge AXUIElementRef)object;uint32_t candidate=0;
        AXError idError=kAXErrorSuccess;if(CACurrentMediaTime()>deadline||CFGetTypeID(element)!=AXUIElementGetTypeID()||(idError=AXUIElementSetMessagingTimeout(element,.15))||(idError=getID(element,&candidate))){details[@"ax_identity_error"]=@(idError);details[@"readback_deadline_expired"]=@(CACurrentMediaTime()>deadline);valid=NO;break;}
        if(candidate!=wid)continue;matches++;CFTypeRef position=NULL,extent=NULL;
        AXError positionError=AXUIElementCopyAttributeValue(element,kAXPositionAttribute,&position),sizeError=AXUIElementCopyAttributeValue(element,kAXSizeAttribute,&extent);details[@"ax_position_error"]=@(positionError);details[@"ax_size_error"]=@(sizeError);BOOL ok=!positionError&&!sizeError;
        ok=ok&&position&&extent&&CFGetTypeID(position)==AXValueGetTypeID()&&CFGetTypeID(extent)==AXValueGetTypeID()&&AXValueGetValue(position,kAXValueCGPointType,&point)&&AXValueGetValue(extent,kAXValueCGSizeType,&size);
        if(position)CFRelease(position);if(extent)CFRelease(extent);valid&=ok;
    }
    CFRelease(list);NSDictionary *info=windowInfo(wid);CGRect cg=CGRectZero,ax={point,size};
    BOOL owner=[info[(id)kCGWindowOwnerPID]intValue]==pid,hasBounds=info&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&cg),finalBirth=[birth(pid)isEqual:expectedBirth];
    details[@"exact_ax_matches"]=@(matches);details[@"ax_readback_valid"]=@(valid);details[@"cg_owner_matches"]=@(owner);details[@"cg_bounds_available"]=@(hasBounds);details[@"final_birth_matches"]=@(finalBirth);details[@"ax"]=rpFrame(ax);details[@"cg"]=rpFrame(cg);details[@"ax_cg_agree"]=@(hasBounds&&rpNear(ax,cg));
    if(!valid||matches!=1||!finalBirth||!owner||!hasBounds||!rpNear(ax,cg)||size.width<=0||size.height<=0)return nil;
    return @{@"ax":rpFrame(ax),@"cg":rpFrame(cg)};
}
static NSDictionary *rpObserve(pid_t pid,NSArray *expectedBirth,uint32_t wid){return rpObserveDetailed(pid,expectedBirth,wid,nil);}
static CGRect rpRect(NSArray *r){return CGRectMake([r[0]doubleValue],[r[1]doubleValue],[r[2]doubleValue],[r[3]doubleValue]);}
@interface RPLease : NSObject
@property NSString *directory,*nonce;
@property pid_t pid,foreground;
@property uint32_t wid;
@property NSArray *processBirth,*foregroundBirth,*transform;
@property double start,deadline;
@property BOOL interrupted,consumed;
@property CGRect initial;
@property CGSize requested;
@property NSMutableArray *results;
@property (atomic,copy) NSDictionary *lastChecks;
- (BOOL)check;
- (BOOL)prepare:(NSDictionary *)effect;
- (BOOL)authorize;
@end
@implementation RPLease
- (BOOL)check {
    NSDictionary *ready=readJSON([self.directory stringByAppendingPathComponent:@"ready.json"]),*fixtureState=readJSON([self.directory stringByAppendingPathComponent:@"fixture-state.json"]);
    NSArray *currentTransform=rpTransform(self.wid);NSDictionary *info=windowInfo(self.wid);CGRect current=CGRectZero;
    BOOL hasFrame=[info[(id)kCGWindowOwnerPID]intValue]==self.pid&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&current);
    BOOL expected=hasFrame&&(self.initial.size.width<=0||rpNear(current,self.initial));
    if(self.consumed){CGSize size=CGSizeMake(fmax(260,fmin(500,self.requested.width)),fmax(200,fmin(360,self.requested.height)));expected|=hasFrame&&CGSizeEqualToSize(current.size,size)&&current.origin.x==self.initial.origin.x&&(current.origin.y==self.initial.origin.y||CGRectGetMaxY(current)==CGRectGetMaxY(self.initial));}
    BOOL fixtureFresh=fixtureState&&CACurrentMediaTime()-[fixtureState[@"timestamp"]doubleValue]<=.5;
    NSMutableDictionary *checks=[@{@"signal_clear":@(!stopped),@"deadline_valid":@(CACurrentMediaTime()<self.deadline),@"foreground_pid_matches":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==self.foreground),@"foreground_birth_matches":@([birth(self.foreground)isEqual:self.foregroundBirth]),@"fixture_birth_matches":@([birth(self.pid)isEqual:self.processBirth]),@"nonce_matches":@([ready[@"nonce"]isEqual:self.nonce]),@"window_id_matches":@([ready[@"window"]unsignedIntValue]==self.wid),@"transform_unchanged":@(self.transform&&[currentTransform isEqual:self.transform]),@"cg_frame_recognized":@(expected),@"fixture_state_fresh":@(fixtureFresh),@"fixture_input_excluded":@([fixtureState[@"input_excluded"]boolValue]),@"fixture_uncontaminated":@(fixtureState&&![fixtureState[@"contaminated"]boolValue]),@"controller_input_excluded":@(rpInputExcluded()),@"sticky_clear":@(!self.interrupted)}mutableCopy];
    BOOL ok=YES;for(NSNumber *value in checks.allValues)ok&=value.boolValue;
    checks[@"initial_transform"]=self.transform?:@[];checks[@"current_transform"]=currentTransform?:@[];checks[@"cg_frame"]=rpFrame(current);checks[@"isolation"]=rpIsolationDiagnostics();self.lastChecks=checks;
    ok&=!stopped&&CACurrentMediaTime()<self.deadline&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==self.foreground&&rpInputExcluded()&&!self.interrupted;
    if(!ok)self.interrupted=YES;return ok;
}
- (BOOL)prepare:(NSDictionary *)effect {
    NSDictionary *i=effect[@"identity"];
    if(self.consumed||[i[@"pid"]intValue]!=self.pid||[i[@"wid"]unsignedIntValue]!=self.wid||![i[@"birth_sec"]isEqual:self.processBirth[0]]||![i[@"birth_usec"]isEqual:self.processBirth[1]])return NO;
    NSDictionary *observed=rpObserve(self.pid,self.processBirth,self.wid);
    if(!observed||!rpNear(rpRect(observed[@"cg"]),self.initial)){self.interrupted=YES;return NO;}
    if(![self check])return NO;
    NSDictionary *size=effect[@"requested"];
    if(!rpPrivateSave(@{@"nonce":self.nonce,@"width":size[@"width"],@"height":size[@"height"]},[self.directory stringByAppendingPathComponent:@"intent.json"]))return NO;
    // Last check follows all potentially blocking AX/family reads and file I/O.
    if(![self check])return NO;self.requested=CGSizeMake([size[@"width"]doubleValue],[size[@"height"]doubleValue]);return YES;
}
- (BOOL)authorize {
    // Atomic properties keep the sticky interruption write independent of slow
    // preparation. Only this serial-worker callback consumes the one-shot ticket.
    BOOL valid=!self.consumed&&!stopped&&CACurrentMediaTime()<self.deadline&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==self.foreground;
    valid&=rpInputExcluded()&&rpIsolation.windowsExcluded; // atomic state after foreground query
    valid&=!self.interrupted;       // final atomic latch read, never reset
    if(!valid){self.interrupted=YES;return NO;}
    self.consumed=YES;return YES;
}
@end
static void rpTouch(NSString *directory,NSString *name){[NSData.data writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES];}
static BOOL rpWait(Desktop *desktop,RPLease *lease,double seconds,BOOL (^condition)(void)) {
    double end=fmin(lease.deadline,CACurrentMediaTime()+seconds);
    do {if(!rpCheckWindows()||![lease check]||desktop.probeHumanInput)return NO;[desktop poll];if(condition())return YES;pump(.02);}while(CACurrentMediaTime()<end);
    return NO;
}
static NSEvent *rpEvent(DesktopView *view,CGPoint point,NSEventType type) {
    CGPoint local=CGPointMake(point.x-view.globalBounds.origin.x,point.y-view.globalBounds.origin.y);
    NSPoint windowPoint=[view convertPoint:local toView:nil];
    return [NSEvent mouseEventWithType:type location:windowPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
}
static BOOL rpCapture(Desktop *desktop,RPLease *lease,NSString *phase,NSMutableArray *observations) {
    if(!rpCheckWindows()||![lease check])return NO;
    NSDictionary *native=rpObserve(lease.pid,lease.processBirth,lease.wid);if(!native)return NO;
    SCWindow *host=findWindow(getpid(),(uint32_t)desktop.panels.firstObject.windowNumber);if(!host)return NO;
    NSString *png=[phase stringByAppendingString:@".png"];
    NSDictionary *capture=captureHost([[SCContentFilter alloc]initWithDesktopIndependentWindow:host],[lease.directory stringByAppendingPathComponent:png]);
    NSDictionary *after=rpObserve(lease.pid,lease.processBirth,lease.wid);
    if(![lease check]||!after||![native isEqual:after]||capture[@"error"]){[NSFileManager.defaultManager removeItemAtPath:[lease.directory stringByAppendingPathComponent:png]error:nil];return NO;}
    NSMutableDictionary *entry=[native mutableCopy];entry[@"phase"]=phase;entry[@"png"]=png;[observations addObject:entry];return YES;
}
static NSArray *rpEdges(void){return @[@"top_left",@"top",@"top_right",@"right",@"bottom_right",@"bottom",@"bottom_left",@"left"];}
static BOOL rpScenario(NSString *scenario,NSString **edge,NSString **action) {
    if([@[@"static",@"family",@"sigint",@"sigterm",@"controller-death"]containsObject:scenario]){*edge=@"right";*action=@"shrink";return YES;}
    NSArray *parts=[scenario componentsSeparatedByString:@"-"];
    if(parts.count!=2||![rpEdges()containsObject:parts[0]]||![@[@"grow",@"shrink",@"clamp"]containsObject:parts[1]])return NO;
    *edge=parts[0];*action=parts[1];return YES;
}
static int runOwnedResize(NSString *directory,NSString *scenario) {
    NSString *edge=nil,*action=nil;rpScenario(scenario,&edge,&action);
    NSMutableDictionary *report=[@{@"kind":@"owned native desktop resize",@"scenario":scenario,@"edge":edge,@"action":action,@"zooms":@[@.6,@.9],@"camera":@[@0,@0],@"runtime_status":@"failed",@"native_passed":@NO,@"fixture_scope":@"noninteractive borderless owned layout/capture only; no physical-input or third-party parity",@"permission_requests":@0,@"activation_calls":@0,@"global_input_posts":@0}mutableCopy];
    NSString *receipt=[directory stringByAppendingPathComponent:@"receipt.json"];
    report[@"startup"]=rpIsolation.startup?:@{};
    NSDictionary *preflight=@{@"screen_capture_granted":@(CGPreflightScreenCaptureAccess()),@"accessibility_granted":@(AXIsProcessTrusted()),@"foreground_preserved":@(rpForegroundMatches()),@"input_exclusion_installed":@(rpInputExcluded())};report[@"preflight"]=preflight;
    for(NSNumber *condition in preflight.allValues)if(!condition.boolValue){report[@"error"]=@"Noninteractive preflight failed; see individual conditions. No permissions requested.";save(report,receipt);return 2;}
    RPLease *lease=[RPLease new];lease.directory=directory;lease.nonce=NSUUID.UUID.UUIDString;lease.start=CACurrentMediaTime();lease.deadline=lease.start+23;lease.foreground=rpIsolation.foreground;lease.foregroundBirth=rpIsolation.foregroundBirth;lease.results=[NSMutableArray array];
    if(!lease.foregroundBirth){report[@"error"]=@"Unknown foreground birth";save(report,receipt);return 2;}
    if(!rpPrivateSave(@{@"nonce":lease.nonce,@"parent":@(getpid()),@"parent_birth":birth(getpid()),@"start":@(lease.start),@"deadline":@(lease.start+25),@"foreground":@(lease.foreground),@"foreground_birth":lease.foregroundBirth},[directory stringByAppendingPathComponent:@"lease.json"]))return 2;
    id foregroundObserver=nil;
        foregroundObserver=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *note){NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];if(app.processIdentifier!=lease.foreground){lease.interrupted=YES;}}];
    NSTask *fixture=[NSTask new];fixture.executableURL=NSBundle.mainBundle.executableURL;fixture.arguments=@[@"--owned-resize-fixture",directory,lease.nonce];NSError *error=nil;
    if(![fixture launchAndReturnError:&error]){[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:foregroundObserver];report[@"error"]=error.localizedDescription;save(report,receipt);return 2;}
    lease.pid=fixture.processIdentifier;lease.processBirth=birth(lease.pid);
    Desktop *desktop=[Desktop new];desktop.experimentalResize=YES;desktop.ownedResizeProbe=YES;desktop.demo=YES;desktop.probe=YES;desktop.fixturePID=lease.pid;desktop.statePath=[directory stringByAppendingPathComponent:@"scene.json"];
    NSMutableArray *observations=[NSMutableArray array];BOOL ok=NO;NSString *failure=@"fixture enrollment";
    double readyEnd=CACurrentMediaTime()+3;NSDictionary *ready=nil;
    while(fixture.running&&!stopped&&CACurrentMediaTime()<readyEnd){ready=readJSON([directory stringByAppendingPathComponent:@"ready.json"]);if(ready)break;pump(.02);}
    lease.wid=[ready[@"window"]unsignedIntValue];
    NSArray *currentTransform=lease.wid?rpTransform(lease.wid):nil;
    // The fixture's registered baseline is immutable. Independent observations
    // must confirm it; they must never silently establish a replacement baseline.
    lease.transform=ready[@"transform"];
    NSArray *registeredOriginal=ready[@"registered_original_cg"];
    BOOL baselineValid=[lease.transform isKindOfClass:NSArray.class]&&lease.transform.count==6&&[registeredOriginal isKindOfClass:NSArray.class]&&registeredOriginal.count==4;
    if(baselineValid)lease.initial=rpRect(registeredOriginal);
    NSMutableDictionary *axDiagnostics=[NSMutableDictionary dictionary];
    NSDictionary *initial=lease.wid?rpObserveDetailed(lease.pid,lease.processBirth,lease.wid,axDiagnostics):nil;
    BOOL transformMatches=baselineValid&&[currentTransform isEqual:lease.transform];
    BOOL originalMatches=baselineValid&&initial&&CGRectEqualToRect(rpRect(initial[@"cg"]),lease.initial)&&CGRectEqualToRect(rpRect(initial[@"ax"]),lease.initial);
    report[@"fixture_readiness"]=readJSON([directory stringByAppendingPathComponent:@"fixture-readiness.json"])?:@{};
    report[@"ax_enrollment"]=axDiagnostics;report[@"fixture_startup"]=readJSON([directory stringByAppendingPathComponent:@"fixture-startup.json"])?:@{};
    save(@{@"fixture":@(lease.pid),@"birth":lease.processBirth?:@[],@"windows":@[@(lease.wid),ready[@"decoy"]?:@0],@"original":initial?:@{},@"transform":lease.transform?:@[]},[directory stringByAppendingPathComponent:@"identity.json"]);
    SCWindow *selected=lease.wid&&baselineValid?findWindow(lease.pid,lease.wid):nil;
    report[@"enrollment"]=@{@"sck_exact_window_found":@(selected!=nil),@"ax_cg_observed":@(initial!=nil),@"transform_available":@(lease.transform!=nil),@"controller_transform":currentTransform?:@[],@"registered_baseline_valid":@(baselineValid),@"registered_transform_matches":@(transformMatches),@"registered_original_frame_matches":@(originalMatches),@"registered_original_cg":registeredOriginal?:@[],@"fixture_initial_transform":ready[@"transform"]?:@[],@"nonce_matches":@([ready[@"nonce"]isEqual:lease.nonce]),@"birth_matches":@([ready[@"birth"]isEqual:lease.processBirth]),@"input_exclusion_reported":@([ready[@"input_excluded"]boolValue]),@"fixture_registration":ready[@"registration"]?:@{}};
    @try {
        if(!selected||!initial||!transformMatches||!originalMatches||![ready[@"nonce"]isEqual:lease.nonce]||![ready[@"birth"]isEqual:lease.processBirth]||![lease check])@throw @"fixture registration/identity/AX/transform confirmation failed; see enrollment conditions";
        if(lease.initial.size.width!=440||lease.initial.size.height!=280)@throw @"fixture initial extent differs";

        DWNativeResizeDriver *driver=[DWNativeResizeDriver new];driver.mutationPreparation=^BOOL(NSDictionary *effect){return [lease prepare:effect];};driver.mutationGuard=^BOOL(NSDictionary *effect){(void)effect;return [lease authorize];};driver.didPerform=^(NSDictionary *effect,NSDictionary *result){@synchronized(lease){[lease.results addObject:@{@"effect":effect,@"result":result}];}};desktop.ownedResizeDriver=driver;
        // Guard hooks are immutable from this point until every obligation drains.
        [desktop showChooser:nil];if(!rpWait(desktop,lease,3,^BOOL{return desktop.choices.count>0;}))@throw @"chooser unavailable";
        NSInteger row=-1;for(NSUInteger i=0;i<desktop.choices.count;i++){SCWindow *w=desktop.choices[i][@"window"];if(w.windowID==lease.wid&&w.owningApplication.processID==lease.pid)row=(NSInteger)i;}
        if(row<0)@throw @"exact fixture absent from chooser";
        [desktop.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]byExtendingSelection:NO];[desktop attachChoice:nil];
        DesktopView *view=desktop.views.firstObject;LiveSource *source=desktop.sources.allValues.firstObject;
        if(!source||desktop.sources.count!=1||view.outputs.count!=2||desktop.chooser.visible)@throw @"chooser attachment failed";
        report[@"chooser_attached"]=@YES;
        // Select the source in the real scene model. The raw controller call does
        // not dispatch its returned native-focus effect; this probe never activates.
        NSDictionary *focusReply=[desktop call:@{@"op":@"focus",@"window":source.logical}];
        report[@"logical_focus"]=@{@"requested_window":source.logical,@"command_succeeded":@(focusReply!=nil),@"native_effect_dispatched":@NO};
        if(!focusReply)@throw @"logical source focus failed";
        for(NSUInteger i=0;i<2;i++){CGPoint origin=CGPointMake(view.globalBounds.origin.x+ports[i].origin.x,view.globalBounds.origin.y+ports[i].origin.y);[desktop call:@{@"op":@"zoom",@"output":view.outputs[i],@"zoom":i?@.9:@.6,@"anchor":pointJSON(origin)}];}
        [desktop render];
        BOOL (^settled)(void)=^BOOL{NSArray *placements=[desktop call:@{@"op":@"snapshot"}][@"placements"];if(placements.count!=2)return NO;for(NSDictionary *p in placements)if(![p[@"presentation_settled"]boolValue])return NO;return YES;};
        if(!rpWait(desktop,lease,4,settled))@throw @"initial real capture did not settle";
        NSDictionary *before=[desktop call:@{@"op":@"snapshot"}];
        for(NSUInteger i=0;i<2;i++){NSDictionary *o=before[@"outputs"][i];if(!CGPointEqualToPoint(jsonPoint(o[@"camera"]),CGPointZero)||fabs([o[@"zoom"]doubleValue]-(i?.9:.6))>.000001)@throw @"camera contract differs";}
        NSDictionary *handle=nil,*placement=nil;for(NSDictionary *p in before[@"placements"])if([p[@"output"]isEqual:view.outputs[0]]&&[p[@"window"]isEqual:source.logical]){placement=p;for(NSDictionary *h in DWResizeHandles(jsonRect(p[@"screen_rect"]),jsonRect(p[@"clip_rect"])))if([h[@"edge"]isEqual:edge])handle=h;}
        NSMutableDictionary *handleDiagnostics=[@{@"focused_window":before[@"focused"]?:NSNull.null,@"source_window":source.logical,@"output":view.outputs[0],@"experimental_resize":@(desktop.experimentalResize),@"presentation_settled":placement[@"presentation_settled"]?:@NO,@"screen_rect":placement[@"screen_rect"]?:@{},@"clip_rect":placement[@"clip_rect"]?:@{},@"handle":handle?:@{}}mutableCopy];report[@"handle_preparation"]=handleDiagnostics;
        if(![before[@"focused"]isEqual:source.logical])@throw @"logical source is not focused";
        if(!handle)@throw @"actual handle not visible";
        CGPoint point=CGPointMake([handle[@"x"]doubleValue],[handle[@"y"]doubleValue]);
        CALayer *tile=view.tiles[[NSString stringWithFormat:@"%@:%@",source.logical,view.outputs[0]]];CGRect clip=jsonRect(placement[@"clip_rect"]);BOOL renderedHandle=NO;NSUInteger renderedCount=0;
        for(CALayer *layer in tile.sublayers)if([layer.name isEqual:@"resize-handle"]){renderedCount++;if(!layer.hidden&&layer.opacity>0&&hypot(CGRectGetMidX(layer.frame)+clip.origin.x-point.x,CGRectGetMidY(layer.frame)+clip.origin.y-point.y)<.01)renderedHandle=YES;}
        renderedHandle&=tile&&tile.superlayer==view.layer&&!tile.hidden&&tile.opacity>0&&view.window.visible&&!view.hidden;
        handleDiagnostics[@"rendered_handle_count"]=@(renderedCount);handleDiagnostics[@"rendered_requested_handle"]=@(renderedHandle);
        if(!renderedHandle)@throw @"requested real resize overlay is absent";
        if(!rpCapture(desktop,lease,@"before",observations))@throw @"initial screenshot refused";
        if([scenario isEqual:@"family"]){rpTouch(directory,@"family");if(!rpWait(desktop,lease,1,^BOOL{return readJSON([directory stringByAppendingPathComponent:@"family-ready.json"])!=nil;}))@throw @"owned child not created";}
        if([scenario isEqual:@"family"]){NSDictionary *family=discoverOwnedFamily(lease.wid,lease.pid,lease.processBirth);report[@"family_observation"]=family;NSNumber *childID=readJSON([directory stringByAppendingPathComponent:@"family-ready.json"])[@"window"];BOOL found=NO;for(NSDictionary *member in family[@"members"])if([member[@"id"]isEqual:childID])found=YES;if(![family[@"valid"]boolValue]||[family[@"members"]count]<2||!found)@throw @"owned child family not independently established";}
        if(![lease check])@throw @"interrupted before gesture";
        NSEvent *down=rpEvent(view,point,NSEventTypeLeftMouseDown);CGPoint actual=[view screenPoint:down];NSNumber *actualOutput=[view outputAt:actual];NSDictionary *driveSnapshot=[desktop call:@{@"op":@"snapshot"}];
        handleDiagnostics[@"expected_pointer"]=pointJSON(point);handleDiagnostics[@"actual_pointer"]=pointJSON(actual);handleDiagnostics[@"pointer_output"]=actualOutput?:NSNull.null;handleDiagnostics[@"focused_at_drive"]=driveSnapshot[@"focused"]?:NSNull.null;handleDiagnostics[@"pointer_modifiers"]=@(down.modifierFlags);
        if(![driveSnapshot[@"focused"]isEqual:source.logical]||![actualOutput isEqual:view.outputs[0]]||hypot(actual.x-point.x,actual.y-point.y)>.01)@throw @"handle pointer or logical focus changed before gesture";
        desktop.probeDrivingGesture=YES;[view mouseDown:down];
        BOOL began=view.gesture==4;
        handleDiagnostics[@"gesture_after_down"]=@(view.gesture);handleDiagnostics[@"resize_transaction"]=view.resizeTransaction?:NSNull.null;
        if(began){double width=[action isEqual:@"grow"]?480:[action isEqual:@"shrink"]?320:100,height=[action isEqual:@"grow"]?320:[action isEqual:@"shrink"]?160:100;
            double dx=[edge containsString:@"left"]?440-width:[edge containsString:@"right"]?width-440:0;
            double dy=[edge containsString:@"top"]?280-height:[edge containsString:@"bottom"]?height-280:0;
            [view mouseDragged:rpEvent(view,CGPointMake(point.x+.6*dx,point.y+.6*dy),NSEventTypeLeftMouseDragged)];[view mouseUp:rpEvent(view,point,NSEventTypeLeftMouseUp)];}
        desktop.probeDrivingGesture=NO;
        if([scenario isEqual:@"family"]){if(!rpWait(desktop,lease,2,^BOOL{return desktop.resize.obligations==0;}))@throw @"family refusal did not drain";if(lease.consumed)@throw @"family mutation incorrectly authorized";NSDictionary *unchanged=rpObserve(lease.pid,lease.processBirth,lease.wid);if(!unchanged||![unchanged isEqual:initial])@throw @"family changed native frame";report[@"family_refused"]=@YES;ok=YES;}
        else {
            if(!began)@throw @"real DesktopView handle did not begin resize";
            if(!rpWait(desktop,lease,5,^BOOL{NSDictionary *state=readJSON([directory stringByAppendingPathComponent:@"fixture-state.json"]);return lease.consumed&&desktop.resize.obligations==0&&[desktop.resize canRemove:nil]&&settled()&&state&&![state[@"contaminated"]boolValue];}))@throw @"native mutation or real post-resize capture did not settle";
            NSDictionary *after=[desktop call:@{@"op":@"snapshot"}];if(![before[@"outputs"]isEqual:after[@"outputs"]])@throw @"native resize changed camera";
            if(!rpCapture(desktop,lease,@"after",observations))@throw @"resized screenshot refused";
            BOOL actualSetter=NO;@synchronized(lease){for(NSDictionary *item in lease.results){NSDictionary *result=item[@"result"];if([result[@"mutation_attempted"]boolValue]&&[result[@"observed"]boolValue]&&[@[@"applied",@"clamped"]containsObject:result[@"outcome"]])actualSetter=YES;}}
            if(!actualSetter)@throw @"no independently captured completed setter result";
            report[@"camera_unchanged"]=@YES;report[@"presentation_settled"]=@YES;
            // Supervisor sends only the selected abnormal signal after this receipt.
            if([@[@"sigint",@"sigterm",@"controller-death"]containsObject:scenario]){report[@"observations"]=observations;report[@"runtime_status"]=@"awaiting-abnormal-signal";save(report,receipt);save(@{@"pid":@(getpid()),@"birth":birth(getpid()),@"fixture":@(lease.pid),@"fixture_birth":lease.processBirth},[directory stringByAppendingPathComponent:@"signal-ready.json"]);while(!stopped&&CACurrentMediaTime()<lease.deadline)pump(.02);@throw @"abnormal scenario interrupted";}
            ok=YES;
        }
    } @catch(NSString *reason) {failure=reason;}
    if(foregroundObserver)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:foregroundObserver];
    // Shutdown refuses new setters and drains actual in-flight results, including
    // timeout uncertainty, before the owned fixture is asked to restore itself.
    [desktop cleanup];[desktop.chooser close];rpTouch(directory,@"restore");
    double restoreEnd=CACurrentMediaTime()+1.5;NSDictionary *restored=nil;
    while(fixture.running&&CACurrentMediaTime()<restoreEnd){restored=readJSON([directory stringByAppendingPathComponent:@"restored.json"]);if(restored)break;pump(.01);}
    NSDictionary *restoredNative=restored?rpObserve(lease.pid,lease.processBirth,lease.wid):nil;
    BOOL restoreVerified=restoredNative&&initial&&[restoredNative isEqual:initial]&&[restored[@"restored"]boolValue]&&[rpTransform(lease.wid)isEqual:lease.transform];rpTouch(directory,@"close");
    double exitEnd=CACurrentMediaTime()+2;while(fixture.running&&CACurrentMediaTime()<exitEnd)pump(.02);
    BOOL gone=!fixture.running&&!windowInfo(lease.wid)&&!windowInfo([ready[@"decoy"]unsignedIntValue]);if(!fixture.running)[fixture waitUntilExit];
    BOOL interrupted=lease.interrupted||desktop.probeHumanInput||stopped||!rpInputExcluded()||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=lease.foreground;
    if(interrupted){for(NSString *name in @[@"before.png",@"after.png"])[NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:name]error:nil];}
    @synchronized(lease){report[@"native_results"]=lease.results.copy;}
    report[@"guard_checks"]=lease.lastChecks?:@{};report[@"isolation"]=rpIsolationDiagnostics();
    report[@"observations"]=observations;report[@"interrupted"]=@(interrupted);report[@"restoration_independently_verified"]=@(restoreVerified);report[@"fixture_gone"]=@(gone);report[@"fixture_exit"]=readJSON([directory stringByAppendingPathComponent:@"fixture-exit.json"])?:@{};
    report[@"native_passed"]=@(ok&&!interrupted&&restoreVerified&&gone&&[report[@"fixture_exit"][@"restored"]boolValue]&&![report[@"fixture_exit"][@"contaminated"]boolValue]);report[@"runtime_status"]=[report[@"native_passed"]boolValue]?@"native-path-complete-pixels-require-external-oracle":@"failed";if(!ok)report[@"error"]=failure;
    // Nonce files are ephemeral ownership credentials, not retained evidence.
    for(NSString *name in @[@"lease.json",@"intent.json",@"ready.json"])[NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:name]error:nil];
    save(report,receipt);return [report[@"native_passed"]boolValue]?0:2;
}
static int ownedResizeEntry(int argc,const char **argv) {
    BOOL fixture=!strcmp(argv[1],"--owned-resize-fixture");if((fixture&&argc!=4)||(!fixture&&argc!=3&&argc!=4))return 64;
    NSString *directory=@(argv[2]);struct stat status={0};
    if(lstat(directory.fileSystemRepresentation,&status)||!S_ISDIR(status.st_mode)||status.st_uid!=getuid())return 64;
    BOOL isDirectory=NO;
    if(!directory.isAbsolutePath||![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory]||!isDirectory)return 64;
    if(!fixture&&[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil].count)return 64;
    if(!fixture&&![NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:directory error:nil])return 64;
    NSString *scenario=argc==4?@(argv[3]):@"right-shrink",*edge=nil,*action=nil;
    if(!fixture&&!rpScenario(scenario,&edge,&action))return 64;
    if(fixture){NSDictionary *lease=readJSON([directory stringByAppendingPathComponent:@"lease.json"]);if([lease[@"parent"]intValue]!=getppid()||![lease[@"parent_birth"]isEqual:birth(getppid())]||![lease[@"nonce"]isEqual:scenario])return 64;}
    // Capture the foreground before the first NSApplication initialization. A
    // startup activation is a failure, never a new accepted foreground baseline.
    pid_t beforePID=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;NSArray *beforeBirth=birth(beforePID);
    NSDictionary *parentLease=fixture?readJSON([directory stringByAppendingPathComponent:@"lease.json"]):nil;
    rpIsolation=[RPIsolationState new];rpIsolation.foreground=fixture?[parentLease[@"foreground"]intValue]:beforePID;rpIsolation.foregroundBirth=fixture?parentLease[@"foreground_birth"]:beforeBirth;
    rpIsolation.ownBirth=birth(getpid());rpIsolation.registeredHelpers=[[NSMapTable alloc]initWithKeyOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory capacity:2];
    NSMutableDictionary *startup=[@{@"expected_foreground_pid":@(rpIsolation.foreground),@"expected_foreground_birth":rpIsolation.foregroundBirth?:@[],@"before_appkit_pid":@(beforePID),@"before_appkit_birth":beforeBirth?:@[],@"prestartup_matches":@(beforeBirth&&beforePID==rpIsolation.foreground&&[beforeBirth isEqual:rpIsolation.foregroundBirth]&&beforePID!=getpid())}mutableCopy];
    NSString *startupPath=[directory stringByAppendingPathComponent:fixture?@"fixture-startup.json":@"controller-startup.json"];
    if(![startup[@"prestartup_matches"]boolValue]){save(startup,startupPath);return 2;}
    id observer=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *note){NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];if(app.processIdentifier!=rpIsolation.foreground)rpIsolation.foregroundInterrupted=YES;}];
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [RPIsolatedApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    startup[@"after_appkit_pid"]=@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);startup[@"after_appkit_birth"]=birth(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)?:@[];startup[@"poststartup_matches"]=@(rpForegroundMatches());startup[@"input_exclusion_installed"]=@(rpInputExcluded());rpIsolation.startup=startup;save(startup,startupPath);
    int result=2;
    if([startup[@"poststartup_matches"]boolValue]&&rpInputExcluded())result=fixture?ownedResizeFixture(directory,scenario):runOwnedResize(directory,scenario);
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];return result;
}

// Read-only supervisor check: never creates NSApplication or enrolls a source.
static int ownedResizeCheckCleanup(NSString *directory) {
    NSDictionary *identity=readJSON([directory stringByAppendingPathComponent:@"identity.json"]);
    NSArray *windows=identity[@"windows"],*expected=identity[@"birth"];
    BOOL known=windows.count==2&&expected.count==2&&[identity[@"fixture"]intValue]>0;
    BOOL gone=known&&![birth([identity[@"fixture"]intValue])isEqual:expected];
    for(NSNumber *wid in windows)gone&=wid.unsignedIntValue>0&&!windowInfo(wid.unsignedIntValue);
    NSDictionary *result=@{@"known":@(known),@"fixture_process_and_windows_gone":@(gone)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];fwrite(json.bytes,1,json.length,stdout);putchar('\n');return gone?0:2;
}

static int ownedResizeCheckRestoration(NSString *directory) {
    NSDictionary *i=readJSON([directory stringByAppendingPathComponent:@"identity.json"]);
    NSArray *windows=i[@"windows"];NSDictionary *r=readJSON([directory stringByAppendingPathComponent:@"restored.json"]);
    NSDictionary *observed=windows.count?rpObserve([i[@"fixture"]intValue],i[@"birth"],[windows[0]unsignedIntValue]):nil;
    BOOL verified=observed&&[observed isEqual:i[@"original"]]&&[r[@"restored"]boolValue]&&![r[@"contaminated"]boolValue]&&[rpTransform([windows[0]unsignedIntValue])isEqual:i[@"transform"]];
    NSDictionary *result=@{@"independent_restoration":@(verified),@"observed":observed?:@{}};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];fwrite(json.bytes,1,json.length,stdout);putchar('\n');return verified?0:2;
}
