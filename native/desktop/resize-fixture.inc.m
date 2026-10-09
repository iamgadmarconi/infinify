// SPDX-License-Identifier: GPL-3.0-or-later
#include <sys/stat.h>
// Included only by main.m; no historical captured-window fixture is modified.
static BOOL rpPrivateSave(id value,NSString *path) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data&&[data writeToFile:path atomically:YES]&&[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600}ofItemAtPath:path error:nil];
}
static NSArray *rpFrame(NSRect r) {return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
static BOOL rpIdleSince(double start) {
    double idle=CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState,kCGAnyInputEventType);
    return isfinite(idle)&&idle>=CACurrentMediaTime()-start;
}
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
static int ownedResizeFixture(NSString *directory,NSString *nonce) {
    NSDictionary *lease=readJSON([directory stringByAppendingPathComponent:@"lease.json"]);
    pid_t parent=getppid();NSArray *parentBirth=birth(parent);
    if(![lease[@"nonce"]isEqual:nonce]||[lease[@"parent"]intValue]!=parent||![lease[@"parent_birth"]isEqual:parentBirth])return 64;
    double start=[lease[@"start"]doubleValue],deadline=[lease[@"deadline"]doubleValue];
    if(CACurrentMediaTime()>=deadline||deadline-start>25)return 64;
    pid_t foreground=[lease[@"foreground"]intValue];NSArray *foregroundBirth=lease[@"foreground_birth"];
    NSWindow *root=[[FixtureWindow alloc]initWithContentRect:NSMakeRect(120,140,440,280) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    root.title=@"Owned native resize";root.releasedWhenClosed=NO;root.animationBehavior=NSWindowAnimationBehaviorNone;root.hasShadow=NO;root.minSize=NSMakeSize(260,200);root.maxSize=NSMakeSize(500,360);
    root.contentView=[[RPLayout alloc]initWithFrame:NSMakeRect(0,0,440,280)];[root orderFront:nil];[root display];
    NSWindow *decoy=makeWindow(NSMakeRect(30,30,100,80),root.title);[decoy orderFront:nil];
    NSRect original=root.frame,decoyOriginal=decoy.frame;__block NSRect last=original;NSArray *transform=rpTransform((uint32_t)root.windowNumber);
    rpPrivateSave(@{@"pid":@(getpid()),@"birth":birth(getpid())?:@[],@"nonce":nonce,@"window":@(root.windowNumber),@"decoy":@(decoy.windowNumber),@"original":rpFrame(original),@"transform":transform?:@[]},[directory stringByAppendingPathComponent:@"ready.json"]);
    __block BOOL contaminated=NO,restored=NO,finished=NO;__block NSString *reason=@"deadline";__block NSWindow *child=nil;
    void (^finish)(void)=^{
        if(finished)return;finished=YES;
    // Repeat the guard at teardown. Unknown/human state is never overwritten.
    NSDictionary *pending=readJSON([directory stringByAppendingPathComponent:@"intent.json"]);
    if(!contaminated&&!NSEqualRects(root.frame,last)&&rpExpectedFrame(root.frame,last,pending,nonce))last=root.frame;
    contaminated|=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=foreground||![birth(foreground)isEqual:foregroundBirth];
    contaminated|=!rpIdleSince(start)||!NSEqualRects(root.frame,last)||!NSEqualRects(decoy.frame,decoyOriginal)||![rpTransform((uint32_t)root.windowNumber)isEqual:transform];
    if(!contaminated&&transform){[root setFrame:original display:YES];restored=NSEqualRects(root.frame,original);}
    save(@{@"reason":reason,@"restored":@(restored),@"contaminated":@(contaminated),@"original":rpFrame(original),@"final":rpFrame(root.frame),@"transform_unchanged":@([rpTransform((uint32_t)root.windowNumber)isEqual:transform])},[directory stringByAppendingPathComponent:@"restored.json"]);
    // Normal cleanup leaves a short independent AX/CG inspection interval.
    double grace=CACurrentMediaTime()+2;
    while(([reason isEqual:@"requested"]||[reason isEqual:@"controller-death"])&&CACurrentMediaTime()<grace&&![NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"close"]])pump(.01);
    [child close];[root close];[decoy close];
    save(@{@"restored":@(restored),@"contaminated":@(contaminated),@"reason":reason,@"closed_owned_windows":@YES},[directory stringByAppendingPathComponent:@"fixture-exit.json"]);
    };
    id foregroundObserver=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *note){NSRunningApplication *app=note.userInfo[NSWorkspaceApplicationKey];if(app.processIdentifier!=foreground)contaminated=YES;}];
    // Common/tracking modes also run while AppKit owns a native resize loop.
    NSTimer *watchdog=[NSTimer timerWithTimeInterval:.04 repeats:YES block:^(NSTimer *timer){
        (void)timer;
        if(!rpIdleSince(start)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=foreground||![birth(foreground)isEqual:foregroundBirth])contaminated=YES;
        if(contaminated||stopped||CACurrentMediaTime()>=deadline||getppid()!=parent||![birth(parent)isEqual:parentBirth]){
            reason=contaminated?@"human-or-foreground-interruption":stopped?@"signal":CACurrentMediaTime()>=deadline?@"deadline":@"controller-death";finish();
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSEventTrackingRunLoopMode];
    while(!finished&&!stopped&&CACurrentMediaTime()<deadline) {
        if(getppid()!=parent||![birth(parent)isEqual:parentBirth]){reason=@"controller-death";break;}
        if(!rpIdleSince(start)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=foreground||![birth(foreground)isEqual:foregroundBirth])contaminated=YES;
        NSDictionary *intent=readJSON([directory stringByAppendingPathComponent:@"intent.json"]);
        if(!NSEqualRects(root.frame,last)){
            NSRect current=root.frame;
            if(!rpExpectedFrame(current,last,intent,nonce))contaminated=YES;
            if(!contaminated)last=current;
        }
        save(@{@"frame":rpFrame(last),@"contaminated":@(contaminated)},[directory stringByAppendingPathComponent:@"fixture-state.json"]);
        if(!NSEqualRects(decoy.frame,decoyOriginal)||![rpTransform((uint32_t)root.windowNumber)isEqual:transform])contaminated=YES;
        if([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"family"]]&&!child){child=makeWindow(NSMakeRect(130,150,90,70),@"Owned attached child");[root addChildWindow:child ordered:NSWindowAbove];[child orderFront:nil];save(@{@"window":@(child.windowNumber)},[directory stringByAppendingPathComponent:@"family-ready.json"]);}
        if([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"restore"]]){reason=@"requested";break;}
        pump(.015);
    }
    if(stopped)reason=@"signal";
    [watchdog invalidate];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:foregroundObserver];
    finish();
    return restored?0:2;
}
