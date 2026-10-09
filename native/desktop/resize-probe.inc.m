// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit owned-fixture runner. Production capture acceptance remains untouched.
static NSDictionary *cg(uint32_t wid){return windowInfo(wid);}
#define rect rectJSON
#include "../families/window-server-family.h"
#undef rect
static BOOL rpNear(CGRect a,CGRect b) {return fabs(a.origin.x-b.origin.x)<=1&&fabs(a.origin.y-b.origin.y)<=1&&fabs(a.size.width-b.size.width)<=1&&fabs(a.size.height-b.size.height)<=1;}
// Independent readback: deliberately does not call the resize adapter or use its
// result, controller observed_rect, fixture subview frames, or capture crop.
static NSDictionary *rpObserve(pid_t pid,NSArray *expectedBirth,uint32_t wid) {
    if(![birth(pid)isEqual:expectedBirth])return nil;
    AXError (*getID)(AXUIElementRef,uint32_t *)=dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");if(!getID)return nil;
    AXUIElementRef app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,.15);CFTypeRef list=NULL;
    AXError error=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&list);CFRelease(app);
    if(error||!list||CFGetTypeID(list)!=CFArrayGetTypeID()){if(list)CFRelease(list);return nil;}
    CGPoint point=CGPointZero;CGSize size=CGSizeZero;NSUInteger matches=0;BOOL valid=YES;double deadline=CACurrentMediaTime()+.8;
    for(id object in (__bridge NSArray *)list){
        AXUIElementRef element=(__bridge AXUIElementRef)object;uint32_t candidate=0;
        if(CACurrentMediaTime()>deadline||CFGetTypeID(element)!=AXUIElementGetTypeID()||AXUIElementSetMessagingTimeout(element,.15)||getID(element,&candidate)){valid=NO;break;}
        if(candidate!=wid)continue;matches++;CFTypeRef position=NULL,extent=NULL;
        BOOL ok=!AXUIElementCopyAttributeValue(element,kAXPositionAttribute,&position)&&!AXUIElementCopyAttributeValue(element,kAXSizeAttribute,&extent);
        ok=ok&&position&&extent&&CFGetTypeID(position)==AXValueGetTypeID()&&CFGetTypeID(extent)==AXValueGetTypeID()&&AXValueGetValue(position,kAXValueCGPointType,&point)&&AXValueGetValue(extent,kAXValueCGSizeType,&size);
        if(position)CFRelease(position);if(extent)CFRelease(extent);valid&=ok;
    }
    CFRelease(list);NSDictionary *info=windowInfo(wid);CGRect cg=CGRectZero,ax={point,size};
    if(!valid||matches!=1||![birth(pid)isEqual:expectedBirth]||[info[(id)kCGWindowOwnerPID]intValue]!=pid||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&cg)||!rpNear(ax,cg)||size.width<=0||size.height<=0)return nil;
    return @{@"ax":rpFrame(ax),@"cg":rpFrame(cg)};
}
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
- (BOOL)check;
- (BOOL)prepare:(NSDictionary *)effect;
- (BOOL)authorize;
@end
@implementation RPLease
- (BOOL)check {
    NSDictionary *ready=readJSON([self.directory stringByAppendingPathComponent:@"ready.json"]);
    BOOL ok=!stopped&&!self.interrupted&&CACurrentMediaTime()<self.deadline&&rpIdleSince(self.start)&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==self.foreground&&[birth(self.foreground)isEqual:self.foregroundBirth]&&[birth(self.pid)isEqual:self.processBirth]&&[ready[@"nonce"]isEqual:self.nonce]&&[ready[@"window"]unsignedIntValue]==self.wid&&[rpTransform(self.wid)isEqual:self.transform];
    CGRect current=CGRectZero;NSDictionary *info=windowInfo(self.wid);
    BOOL hasFrame=[info[(id)kCGWindowOwnerPID]intValue]==self.pid&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&current);
    if(self.initial.size.width>0){BOOL expected=rpNear(current,self.initial);
        if(self.consumed){CGSize size=CGSizeMake(fmax(260,fmin(500,self.requested.width)),fmax(200,fmin(360,self.requested.height)));expected|=CGSizeEqualToSize(current.size,size)&&current.origin.x==self.initial.origin.x&&(current.origin.y==self.initial.origin.y||CGRectGetMaxY(current)==CGRectGetMaxY(self.initial));}
        ok&=hasFrame&&expected;}
    ok&=!stopped&&CACurrentMediaTime()<self.deadline&&rpIdleSince(self.start)&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==self.foreground;
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
    valid&=rpIdleSince(self.start); // after the foreground query
    valid&=!self.interrupted;       // final atomic latch read, never reset
    if(!valid){self.interrupted=YES;return NO;}
    self.consumed=YES;return YES;
}
@end
static void rpTouch(NSString *directory,NSString *name){[NSData.data writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES];}
static BOOL rpWait(Desktop *desktop,RPLease *lease,double seconds,BOOL (^condition)(void)) {
    double end=fmin(lease.deadline,CACurrentMediaTime()+seconds);
    do {if(![lease check]||desktop.probeHumanInput)return NO;[desktop poll];if(condition())return YES;pump(.02);}while(CACurrentMediaTime()<end);
    return NO;
}
static NSEvent *rpEvent(DesktopView *view,CGPoint point,NSEventType type) {
    CGPoint local=CGPointMake(point.x-view.globalBounds.origin.x,point.y-view.globalBounds.origin.y);
    NSPoint windowPoint=[view convertPoint:local toView:nil];
    return [NSEvent mouseEventWithType:type location:windowPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
}
static BOOL rpCapture(Desktop *desktop,RPLease *lease,NSString *phase,NSMutableArray *observations) {
    if(![lease check])return NO;
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
    NSMutableDictionary *report=[@{@"kind":@"owned native desktop resize",@"scenario":scenario,@"edge":edge,@"action":action,@"zooms":@[@.6,@.9],@"camera":@[@0,@0],@"runtime_status":@"failed",@"native_passed":@NO,@"fixture_scope":@"borderless resizable AppKit only; not third-party parity",@"permission_requests":@0,@"activation_calls":@0,@"global_input_posts":@0}mutableCopy];
    NSString *receipt=[directory stringByAppendingPathComponent:@"receipt.json"];
    if(!CGPreflightScreenCaptureAccess()||!AXIsProcessTrusted()||!CGPreflightListenEventAccess()||CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState,kCGAnyInputEventType)<3){report[@"error"]=@"Existing capture, AX, input-observation grants and 3 seconds of HID inactivity required; no prompts.";save(report,receipt);return 2;}
    RPLease *lease=[RPLease new];lease.directory=directory;lease.nonce=NSUUID.UUID.UUIDString;lease.start=CACurrentMediaTime();lease.deadline=lease.start+23;lease.foreground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;lease.foregroundBirth=birth(lease.foreground);lease.results=[NSMutableArray array];
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
    lease.transform=rpTransform(lease.wid);
    NSDictionary *initial=rpObserve(lease.pid,lease.processBirth,lease.wid);
    save(@{@"fixture":@(lease.pid),@"birth":lease.processBirth?:@[],@"windows":@[@(lease.wid),ready[@"decoy"]?:@0],@"original":initial?:@{},@"transform":lease.transform?:@[]},[directory stringByAppendingPathComponent:@"identity.json"]);
    SCWindow *selected=findWindow(lease.pid,lease.wid);
    @try {
        if(!selected||!initial||!lease.transform||![ready[@"nonce"]isEqual:lease.nonce]||![ready[@"birth"]isEqual:lease.processBirth]||![lease check])@throw @"fixture identity, AX or transform unavailable";
        lease.initial=rpRect(initial[@"cg"]);if(lease.initial.size.width!=440||lease.initial.size.height!=280)@throw @"fixture initial extent differs";

        DWNativeResizeDriver *driver=[DWNativeResizeDriver new];driver.mutationPreparation=^BOOL(NSDictionary *effect){return [lease prepare:effect];};driver.mutationGuard=^BOOL(NSDictionary *effect){(void)effect;return [lease authorize];};driver.didPerform=^(NSDictionary *effect,NSDictionary *result){@synchronized(lease){[lease.results addObject:@{@"effect":effect,@"result":result}];}};desktop.ownedResizeDriver=driver;
        // Guard hooks are immutable from this point until every obligation drains.
        [desktop showChooser:nil];if(!rpWait(desktop,lease,3,^BOOL{return desktop.choices.count>0;}))@throw @"chooser unavailable";
        NSInteger row=-1;for(NSUInteger i=0;i<desktop.choices.count;i++){SCWindow *w=desktop.choices[i][@"window"];if(w.windowID==lease.wid&&w.owningApplication.processID==lease.pid)row=(NSInteger)i;}
        if(row<0)@throw @"exact fixture absent from chooser";
        [desktop.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]byExtendingSelection:NO];[desktop attachChoice:nil];
        DesktopView *view=desktop.views.firstObject;LiveSource *source=desktop.sources.allValues.firstObject;
        if(!source||desktop.sources.count!=1||view.outputs.count!=2||desktop.chooser.visible)@throw @"chooser attachment failed";
        report[@"chooser_attached"]=@YES;
        for(NSUInteger i=0;i<2;i++){CGPoint origin=CGPointMake(view.globalBounds.origin.x+ports[i].origin.x,view.globalBounds.origin.y+ports[i].origin.y);[desktop call:@{@"op":@"zoom",@"output":view.outputs[i],@"zoom":i?@.9:@.6,@"anchor":pointJSON(origin)}];}
        [desktop render];
        BOOL (^settled)(void)=^BOOL{NSArray *placements=[desktop call:@{@"op":@"snapshot"}][@"placements"];if(placements.count!=2)return NO;for(NSDictionary *p in placements)if(![p[@"presentation_settled"]boolValue])return NO;return YES;};
        if(!rpWait(desktop,lease,4,settled))@throw @"initial real capture did not settle";
        NSDictionary *before=[desktop call:@{@"op":@"snapshot"}];
        for(NSUInteger i=0;i<2;i++){NSDictionary *o=before[@"outputs"][i];if(!CGPointEqualToPoint(jsonPoint(o[@"camera"]),CGPointZero)||fabs([o[@"zoom"]doubleValue]-(i?.9:.6))>.000001)@throw @"camera contract differs";}
        if(!rpCapture(desktop,lease,@"before",observations))@throw @"initial screenshot refused";
        NSDictionary *handle=nil;for(NSDictionary *p in before[@"placements"])if([p[@"output"]isEqual:view.outputs[0]])for(NSDictionary *h in DWResizeHandles(jsonRect(p[@"screen_rect"]),jsonRect(p[@"clip_rect"])))if([h[@"edge"]isEqual:edge])handle=h;
        if(!handle)@throw @"actual handle not visible";
        CGPoint point=CGPointMake([handle[@"x"]doubleValue],[handle[@"y"]doubleValue]);
        if([scenario isEqual:@"family"]){rpTouch(directory,@"family");if(!rpWait(desktop,lease,1,^BOOL{return readJSON([directory stringByAppendingPathComponent:@"family-ready.json"])!=nil;}))@throw @"owned child not created";}
        if([scenario isEqual:@"family"]){NSDictionary *family=discoverOwnedFamily(lease.wid,lease.pid,lease.processBirth);report[@"family_observation"]=family;NSNumber *childID=readJSON([directory stringByAppendingPathComponent:@"family-ready.json"])[@"window"];BOOL found=NO;for(NSDictionary *member in family[@"members"])if([member[@"id"]isEqual:childID])found=YES;if(![family[@"valid"]boolValue]||[family[@"members"]count]<2||!found)@throw @"owned child family not independently established";}
        if(![lease check])@throw @"interrupted before gesture";
        desktop.probeDrivingGesture=YES;[view mouseDown:rpEvent(view,point,NSEventTypeLeftMouseDown)];
        BOOL began=view.gesture==4;
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
    BOOL interrupted=lease.interrupted||desktop.probeHumanInput||stopped||!rpIdleSince(lease.start)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=lease.foreground;
    if(interrupted){for(NSString *name in @[@"before.png",@"after.png"])[NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:name]error:nil];}
    @synchronized(lease){report[@"native_results"]=lease.results.copy;}
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
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [ProbeApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    return fixture?ownedResizeFixture(directory,scenario):runOwnedResize(directory,scenario);
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
