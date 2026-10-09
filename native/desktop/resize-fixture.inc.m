// SPDX-License-Identifier: GPL-3.0-or-later
#include <sys/stat.h>
// Included only by main.m; no historical captured-window fixture is modified.
static BOOL rpPrivateSave(id value,NSString *path) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data&&[data writeToFile:path atomically:YES]&&[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600}ofItemAtPath:path error:nil];
}
static NSArray *rpFrame(NSRect r) {return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
// Read-only private signature precedent: native/backend/bridge.m, yabai
// dd845723416f5fe92af49fad5ebab00369e07edd. No transform setter is loaded.
static NSArray *rpTransform(uint32_t wid) {
    static int (*connection)(void);static CGError (*get)(int,uint32_t,CGAffineTransform *);static dispatch_once_t once;
    dispatch_once(&once,^{void *h=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);if(h){connection=dlsym(h,"SLSMainConnectionID");get=dlsym(h,"SLSGetWindowTransform");}});
    CGAffineTransform t;if(!connection||!get||get(connection(),wid,&t)!=kCGErrorSuccess)return nil;
    return @[@(t.a),@(t.b),@(t.c),@(t.d),@(t.tx),@(t.ty)];
}
@interface RPLayout : FlippedView @end
@implementation RPLayout
- (void)drawRect:(NSRect)dirty {
    (void)dirty;[[NSColor colorWithSRGBRed:.08 green:.08 blue:.08 alpha:1]setFill];NSRectFill(self.bounds);
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    NSArray *colors=@[[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1],[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1],[NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:1],[NSColor colorWithSRGBRed:0 green:1 blue:1 alpha:1],[NSColor colorWithSRGBRed:1 green:0 blue:1 alpha:1],[NSColor colorWithSRGBRed:1 green:1 blue:0 alpha:1]];
    // Constants are separately declared in the byte-level Python oracle.
    [[NSColor colorWithSRGBRed:1 green:.25 blue:0 alpha:1]setFill];NSRectFill(NSMakeRect(16,16,24,24));
    [[NSColor colorWithSRGBRed:.5 green:0 blue:1 alpha:1]setFill];NSRectFill(NSMakeRect(w-40,h-40,24,24));
    NSInteger columns=w>=400?6:3;
    for(NSInteger i=0;i<6;i++){[colors[i]setFill];NSRectFill(NSMakeRect(16+(i%columns)*56,64+(i/columns)*56,36,36));}
}
- (void)setFrameSize:(NSSize)size {[super setFrameSize:size];self.needsDisplay=YES;}
@end
static BOOL rpExpectedFrame(NSRect current,NSRect last,NSDictionary *intent,NSString *nonce) {
    NSSize requested=NSMakeSize([intent[@"width"]doubleValue],[intent[@"height"]doubleValue]);
    NSSize expected=NSMakeSize(fmax(260,fmin(500,requested.width)),fmax(200,fmin(360,requested.height)));
    return [intent[@"nonce"]isEqual:nonce]&&NSEqualSizes(current.size,expected)&&current.origin.x==last.origin.x&&(current.origin.y==last.origin.y||NSMaxY(current)==NSMaxY(last));
}
static NSDictionary *rpFixtureDiagnostics(NSWindow *root,NSWindow *decoy,NSWindow *child,NSRect original,NSRect last,NSRect decoyOriginal,NSArray *transform) {
    NSArray *currentTransform=rpTransform((uint32_t)root.windowNumber);
    BOOL excluded=rpCheckWindows()&&rpWindowExcluded(root)&&rpWindowExcluded(decoy)&&(!child||rpWindowExcluded(child));
    return @{@"timestamp":@(CACurrentMediaTime()),@"input_excluded":@(excluded),@"isolation":rpIsolationDiagnostics(),@"foreground_pid_matches":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==rpIsolation.foreground),@"foreground_birth_matches":@([birth(rpIsolation.foreground)isEqual:rpIsolation.foregroundBirth]),@"initial_transform":transform?:@[],@"current_transform":currentTransform?:@[],@"transform_available":@(currentTransform!=nil),@"transform_unchanged":@(transform&&[currentTransform isEqual:transform]),@"original_frame":rpFrame(original),@"current_frame":rpFrame(root.frame),@"last_recognized_frame":rpFrame(last),@"decoy_unchanged":@(NSEqualRects(decoy.frame,decoyOriginal))};
}
// Missing WindowServer registration is pending, never a usable baseline. A
// present but foreign/ambiguous/moved entry fails instead of becoming a new origin.
static NSDictionary *rpRegistrationWindow(NSWindow *window,NSRect original,CGRect expected,uint32_t frozenID) {
    NSInteger number=window.windowNumber;BOOL positive=number>0&&(uint64_t)number<=UINT32_MAX;
    BOOL sameID=!frozenID||(positive&&(uint32_t)number==frozenID);
    NSDictionary *cg=positive?windowInfo((uint32_t)number):nil;CGRect bounds=CGRectZero;
    BOOL exact=cg&&[cg[(id)kCGWindowNumber]unsignedIntValue]==(uint32_t)number&&[cg[(id)kCGWindowOwnerPID]intValue]==getpid();
    BOOL hasBounds=cg&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)cg[(id)kCGWindowBounds],&bounds);
    BOOL sameBounds=hasBounds&&CGRectEqualToRect(bounds,expected),sameFrame=NSEqualRects(window.frame,original);
    BOOL invalid=!sameID||!sameFrame||(cg&&(!exact||!sameBounds));
    return @{@"window":@(number),@"positive_id":@(positive),@"id_unchanged":@(sameID),@"cg_present":@(cg!=nil),@"exact_owner":@(exact),@"bounds_available":@(hasBounds),@"bounds_match_created_frame":@(sameBounds),@"appkit_frame_unchanged":@(sameFrame),@"expected_cg":rpFrame(expected),@"observed_cg":rpFrame(bounds),@"status":invalid?@"invalid":exact&&sameBounds?@"registered":@"pending"};
}
static NSDictionary *rpWaitForRegistration(NSWindow *root,NSWindow *decoy,NSRect original,NSRect decoyOriginal,pid_t parent,NSArray *parentBirth,double deadline) {
    double began=CACurrentMediaTime(),end=fmin(deadline,began+2.0);NSArray *ownBirth=birth(getpid());
    CGRect expected=topRect(original),decoyExpected=topRect(decoyOriginal);
    uint32_t rootID=0,decoyID=0;NSArray *candidate=nil,*decoyCandidate=nil;NSMutableArray *observations=[NSMutableArray array];NSString *failure=@"registration-deadline";BOOL ready=NO;
    while(CACurrentMediaTime()<end){
        BOOL parentMatches=getppid()==parent&&[birth(parent)isEqual:parentBirth],ownBirthMatches=ownBirth&&[birth(getpid())isEqual:ownBirth];
        BOOL foreground=rpForegroundMatches(),excluded=rpCheckWindows()&&rpInputExcluded();
        NSMutableDictionary *sample=[@{@"elapsed":@(CACurrentMediaTime()-began),@"parent_birth_matches":@(parentMatches),@"own_birth_matches":@(ownBirthMatches),@"foreground_preserved":@(foreground),@"input_excluded":@(excluded),@"signal_clear":@(!stopped),@"isolation":rpIsolationDiagnostics()}mutableCopy];
        [observations addObject:sample];
        if(stopped||!parentMatches||!ownBirthMatches||!foreground||!excluded){failure=@"registration-interrupted";break;}
        NSDictionary *r=rpRegistrationWindow(root,original,expected,rootID),*d=rpRegistrationWindow(decoy,decoyOriginal,decoyExpected,decoyID);sample[@"root"]=r;sample[@"decoy"]=d;
        if(!rootID&&[r[@"positive_id"]boolValue])rootID=[r[@"window"]unsignedIntValue];if(!decoyID&&[d[@"positive_id"]boolValue])decoyID=[d[@"window"]unsignedIntValue];
        if([r[@"status"]isEqual:@"invalid"]||[d[@"status"]isEqual:@"invalid"]){failure=@"registered-identity-or-created-geometry-changed";break;}
        if([r[@"status"]isEqual:@"registered"]&&[d[@"status"]isEqual:@"registered"]){
            // No transform query occurs before BOTH windows have exact registered
            // owners and the original created geometry. First registered values
            // are candidates only; differing later values fail, never rebase.
            NSArray *t=rpTransform(rootID),*dt=rpTransform(decoyID);BOOL rootKnown=t.count==6,decoyKnown=dt.count==6;for(NSNumber *part in t)rootKnown&=isfinite(part.doubleValue);for(NSNumber *part in dt)decoyKnown&=isfinite(part.doubleValue);sample[@"root_transform_known"]=@(rootKnown);sample[@"decoy_transform_known"]=@(decoyKnown);sample[@"root_transform"]=rootKnown?t:@[];sample[@"decoy_transform"]=decoyKnown?dt:@[];
            if(!rootKnown||!decoyKnown){failure=@"registered-transform-unavailable";break;}
            if(candidate){if(![candidate isEqual:t]||![decoyCandidate isEqual:dt]){failure=@"registered-transform-changed";break;}ready=YES;}
            else {candidate=t;decoyCandidate=dt;}
        }else if(candidate){failure=@"registration-lost-after-first-valid-observation";break;}
        // Guard again after every potentially slow query. A successful candidate
        // cannot bless an interruption or geometry change during observation.
        if(stopped||CACurrentMediaTime()>=end||getppid()!=parent||![birth(parent)isEqual:parentBirth]||![birth(getpid())isEqual:ownBirth]||!rpForegroundMatches()||!rpCheckWindows()||!rpInputExcluded()||!NSEqualRects(root.frame,original)||!NSEqualRects(decoy.frame,decoyOriginal)){ready=NO;failure=@"registration-final-guard-failed";break;}
        if(ready){failure=@"";break;}
        // Service real AppKit/WindowServer registration between observations;
        // this is not a fixed sleep or an animation/redraw used to fake capture.
        pump(.015);
    }
    return @{@"ready":@(ready),@"failure":failure,@"elapsed":@(CACurrentMediaTime()-began),@"observations":observations,@"root_window":@(rootID),@"decoy_window":@(decoyID),@"registered_original_cg":rpFrame(expected),@"registered_decoy_cg":rpFrame(decoyExpected),@"root_transform":ready?candidate:@[],@"decoy_transform":ready?decoyCandidate:@[]};
}
static int ownedResizeFixture(NSString *directory,NSString *nonce) {
    NSDictionary *lease=readJSON([directory stringByAppendingPathComponent:@"lease.json"]);
    pid_t parent=getppid();NSArray *parentBirth=birth(parent);
    if(![lease[@"nonce"]isEqual:nonce]||[lease[@"parent"]intValue]!=parent||![lease[@"parent_birth"]isEqual:parentBirth])return 64;
    double start=[lease[@"start"]doubleValue],deadline=[lease[@"deadline"]doubleValue];
    if(CACurrentMediaTime()>=deadline||deadline-start>25)return 64;
    pid_t foreground=[lease[@"foreground"]intValue];NSArray *foregroundBirth=lease[@"foreground_birth"];
    NSWindow *root=rpMakeWindow(NSMakeRect(120,140,440,280),@"Owned native resize",NSWindowStyleMaskBorderless|NSWindowStyleMaskResizable);
    root.title=@"Owned native resize";root.releasedWhenClosed=NO;root.animationBehavior=NSWindowAnimationBehaviorNone;root.hasShadow=NO;root.minSize=NSMakeSize(260,200);root.maxSize=NSMakeSize(500,360);
    root.contentView=[[RPLayout alloc]initWithFrame:NSMakeRect(0,0,440,280)];NSRect original=root.frame;
    if(!rpBeforeOrder(root)){save(rpIsolationDiagnostics(),[directory stringByAppendingPathComponent:@"fixture-order-failure.json"]);[root close];return 2;}[root orderFront:nil];[root display];
    NSWindow *decoy=rpMakeWindow(NSMakeRect(30,30,100,80),root.title,NSWindowStyleMaskBorderless);NSRect decoyOriginal=decoy.frame;
    if(!rpBeforeOrder(decoy)){save(rpIsolationDiagnostics(),[directory stringByAppendingPathComponent:@"fixture-order-failure.json"]);[root close];[decoy close];return 2;}[decoy orderFront:nil];
    NSDictionary *readiness=rpWaitForRegistration(root,decoy,original,decoyOriginal,parent,parentBirth,deadline);
    save(readiness,[directory stringByAppendingPathComponent:@"fixture-readiness.json"]);
    if(![readiness[@"ready"]boolValue]){
        // No ready receipt, controller enrollment, AX mutation, or restoration
        // setter is permitted on this path. Close only these owned objects.
        BOOL unchanged=NSEqualRects(root.frame,original)&&NSEqualRects(decoy.frame,decoyOriginal);
        [root close];[decoy close];
        save(@{@"reason":@"registration-failed",@"readiness_failure":readiness[@"failure"],@"restored":@NO,@"restoration_attempted":@NO,@"original_frames_unchanged":@(unchanged),@"closed_owned_windows":@YES,@"contaminated":@YES,@"final_isolation":rpIsolationDiagnostics()},[directory stringByAppendingPathComponent:@"fixture-exit.json"]);return 2;
    }
    __block NSRect last=original;NSArray *transform=readiness[@"root_transform"];
    NSDictionary *registration=[readiness[@"observations"]lastObject][@"root"];
    if(!rpPrivateSave(@{@"registration":registration,@"registered_original_cg":readiness[@"registered_original_cg"],@"registered_decoy_cg":readiness[@"registered_decoy_cg"],@"pid":@(getpid()),@"birth":birth(getpid())?:@[],@"nonce":nonce,@"window":@(root.windowNumber),@"decoy":@(decoy.windowNumber),@"original":rpFrame(original),@"transform":transform,@"decoy_transform":readiness[@"decoy_transform"],@"input_excluded":@(rpCheckWindows()),@"startup":rpIsolation.startup?:@{}},[directory stringByAppendingPathComponent:@"ready.json"])){[root close];[decoy close];save(@{@"reason":@"ready-publication-failed",@"restored":@NO,@"restoration_attempted":@NO,@"closed_owned_windows":@YES},[directory stringByAppendingPathComponent:@"fixture-exit.json"]);return 2;}
    __block NSDictionary *firstContamination=nil;
    __block BOOL contaminated=NO,restored=NO,finished=NO;__block NSString *reason=@"deadline";__block NSWindow *child=nil;
    void (^finish)(void)=^{
        if(finished)return;finished=YES;
    // Complete every potentially blocking preparation before final authorization.
    // Unknown state is never overwritten, including a change during these reads.
    NSDictionary *pending=readJSON([directory stringByAppendingPathComponent:@"intent.json"]);
    BOOL sameForegroundBirth=[birth(foreground)isEqual:foregroundBirth];
    BOOL sameTransform=transform&&[rpTransform((uint32_t)root.windowNumber)isEqual:transform];
    BOOL sameForeground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==foreground;
    BOOL inputExcluded=rpCheckWindows()&&rpInputExcluded();
    // Only atomic/in-process state reads follow the final exclusion check. The owned
    // NSWindow frame getters do not query AX/WindowServer or pump the run loop.
    NSRect current=root.frame;
    BOOL knownFrame=NSEqualRects(current,last)||rpExpectedFrame(current,last,pending,nonce);
    BOOL decoyUnchanged=NSEqualRects(decoy.frame,decoyOriginal);
    contaminated|=!sameForegroundBirth||!sameTransform||!sameForeground||!inputExcluded||!knownFrame||!decoyUnchanged||rpIsolation.foregroundInterrupted||rpIsolation.unexpectedInput;
    if(!contaminated){[root setFrame:original display:YES];restored=NSEqualRects(root.frame,original);}
    NSDictionary *authorization=@{@"foreground_birth_matches":@(sameForegroundBirth),@"transform_unchanged":@(sameTransform),@"foreground_pid_matches":@(sameForeground),@"input_excluded":@(inputExcluded),@"frame_lineage_known":@(knownFrame),@"decoy_unchanged":@(decoyUnchanged),@"pre_restore_frame":rpFrame(current),@"isolation":rpIsolationDiagnostics()};
    if(contaminated&&!firstContamination)firstContamination=authorization;
    NSDictionary *finishDiagnostics=rpFixtureDiagnostics(root,decoy,child,original,last,decoyOriginal,transform);
    save(@{@"authorization":authorization,@"first_contamination":firstContamination?:@{},@"diagnostics":finishDiagnostics,@"reason":reason,@"restored":@(restored),@"contaminated":@(contaminated),@"original":rpFrame(original),@"final":rpFrame(root.frame),@"transform_unchanged":@([rpTransform((uint32_t)root.windowNumber)isEqual:transform])},[directory stringByAppendingPathComponent:@"restored.json"]);
    // Normal cleanup leaves a short independent AX/CG inspection interval.
    double grace=CACurrentMediaTime()+2;
    while(([reason isEqual:@"requested"]||[reason isEqual:@"controller-death"])&&CACurrentMediaTime()<grace&&![NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"close"]])pump(.01);
    // The observer remains live through the readback hold. A later interruption
    // cannot trigger a second restoration and must not produce a clean receipt.
    contaminated|=!rpInputExcluded()||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=foreground||!NSEqualRects(root.frame,original)||!NSEqualRects(decoy.frame,decoyOriginal);
    [child close];[root close];[decoy close];
    save(@{@"restored":@(restored),@"contaminated":@(contaminated),@"reason":reason,@"closed_owned_windows":@YES,@"diagnostics":finishDiagnostics,@"final_isolation":rpIsolationDiagnostics(),@"first_contamination":firstContamination?:@{}},[directory stringByAppendingPathComponent:@"fixture-exit.json"]);
    };
    // Common/tracking modes also run while AppKit owns a native resize loop.
    NSTimer *watchdog=[NSTimer timerWithTimeInterval:.04 repeats:YES block:^(NSTimer *timer){
        (void)timer;
        if(!rpInputExcluded()||!rpCheckWindows()||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=foreground||![birth(foreground)isEqual:foregroundBirth])contaminated=YES;
        if(contaminated||stopped||CACurrentMediaTime()>=deadline||getppid()!=parent||![birth(parent)isEqual:parentBirth]){
            if(contaminated&&!firstContamination)firstContamination=rpFixtureDiagnostics(root,decoy,child,original,last,decoyOriginal,transform);
            reason=contaminated?@"input-exclusion-or-foreground-failure":stopped?@"signal":CACurrentMediaTime()>=deadline?@"deadline":@"controller-death";finish();
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSEventTrackingRunLoopMode];
    while(!finished&&!stopped&&CACurrentMediaTime()<deadline) {
        if(getppid()!=parent||![birth(parent)isEqual:parentBirth]){reason=@"controller-death";break;}
        if(!rpInputExcluded()||!rpCheckWindows()||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=foreground||![birth(foreground)isEqual:foregroundBirth])contaminated=YES;
        NSDictionary *intent=readJSON([directory stringByAppendingPathComponent:@"intent.json"]);
        if(!NSEqualRects(root.frame,last)){
            NSRect current=root.frame;
            if(!rpExpectedFrame(current,last,intent,nonce))contaminated=YES;
            if(!contaminated)last=current;
        }
        NSMutableDictionary *state=[rpFixtureDiagnostics(root,decoy,child,original,last,decoyOriginal,transform)mutableCopy];
        if(![state[@"decoy_unchanged"]boolValue]||![state[@"transform_unchanged"]boolValue]||![state[@"input_excluded"]boolValue])contaminated=YES;
        state[@"frame"]=rpFrame(last);state[@"contaminated"]=@(contaminated);if(contaminated&&!firstContamination)firstContamination=state.copy;save(state,[directory stringByAppendingPathComponent:@"fixture-state.json"]);
        if([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"family"]]&&!child){child=rpMakeWindow(NSMakeRect(130,150,90,70),@"Owned attached child",NSWindowStyleMaskBorderless);if(!rpBeforeOrder(child)){contaminated=YES;continue;}[root addChildWindow:child ordered:NSWindowAbove];if(!rpBeforeOrder(child)){contaminated=YES;continue;}[child orderFront:nil];save(@{@"window":@(child.windowNumber)},[directory stringByAppendingPathComponent:@"family-ready.json"]);}
        if([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"restore"]]){reason=@"requested";break;}
        pump(.015);
    }
    if(stopped)reason=@"signal";
    [watchdog invalidate];
    finish();
    return restored?0:2;
}
