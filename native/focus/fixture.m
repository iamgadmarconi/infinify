// SPDX-License-Identifier: GPL-3.0-or-later
#import "common.h"
static int64_t expectedTag,currentTag;
static pid_t controller;
static NSUInteger foreignEvents;
static NSMutableArray *events;
static NSString *auditKey;
// Only the exact retained event object minted during teardown is admitted.
// Human/synthetic events cannot opt in by reproducing a tag or event number.
static NSEvent *pendingTeardownRelease;
static NSInteger pendingDownWindow;
static NSUInteger teardownReleases;
static BOOL teardownStarted;
@interface AuditApplication:NSApplication @end
@implementation AuditApplication
- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask untilDate:(NSDate *)date inMode:(NSRunLoopMode)mode dequeue:(BOOL)dequeue {
    NSEvent *e=[super nextEventMatchingMask:mask untilDate:date inMode:mode dequeue:dequeue];
    if(!e||!dequeue)return e;
    if(teardownStarted&&e==pendingTeardownRelease&&e.type==NSEventTypeLeftMouseUp&&
       e.windowNumber==pendingDownWindow&&NSEqualPoints(e.locationInWindow,NSMakePoint(-10,-10))){
        pendingTeardownRelease=nil;pendingDownWindow=0;currentTag=0;teardownReleases++;return e;
    }
    BOOL input=e.type==NSEventTypeLeftMouseDown||e.type==NSEventTypeLeftMouseUp||e.type==NSEventTypeKeyDown||e.type==NSEventTypeKeyUp||e.type==NSEventTypeFlagsChanged||e.type==NSEventTypeScrollWheel||e.type==NSEventTypeRightMouseDown||e.type==NSEventTypeOtherMouseDown;
    if(input){CGEventRef cg=e.CGEvent;currentTag=cg?CGEventGetIntegerValueField(cg,kCGEventSourceUserData):0;pid_t sender=cg?(pid_t)CGEventGetIntegerValueField(cg,kCGEventSourceUnixProcessID):0;
        BOOL trusted=controller>0&&sender==controller&&currentTag==expectedTag;
        if(!trusted){foreignEvents++;interrupted=1;return nil;} // Never forward human input into the disposable controls.
        NSMutableDictionary *record=[@{@"sequence":@(events.count),@"type":@(e.type),@"tag":@(currentTag),@"sender":@(sender),@"window":@(e.windowNumber),@"key_window":@(NSApp.keyWindow.windowNumber),@"active":@(NSApp.active),@"local":@[@(e.locationInWindow.x),@(e.locationInWindow.y)]}mutableCopy];
        if(e.type==NSEventTypeKeyDown)record[@"text_sha256"]=digest(e.characters?:@"");
        if(e.type==NSEventTypeLeftMouseDown)pendingDownWindow=e.windowNumber;
        if(e.type==NSEventTypeLeftMouseUp&&pendingDownWindow==e.windowNumber)pendingDownWindow=0;
        record[@"signature"]=signature(record,auditKey);[events addObject:record];
    }
    return e;
}
@end
@interface Controls:NSObject
@property NSInteger clicks;
@property NSMutableArray *actions;
@end
@implementation Controls
- (void)clicked:(NSButton *)sender{self.clicks++;[self.actions addObject:@{@"tag":@(currentTag),@"window":@(sender.window.windowNumber),@"key_window":@(NSApp.keyWindow.windowNumber),@"state":@(sender.state)}];}
@end
static NSArray *point(NSView *v){NSPoint p=[v convertPoint:NSMakePoint(NSMidX(v.bounds),NSMidY(v.bounds)) toView:nil];return @[@(p.x),@(v.window.frame.size.height-p.y)];}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=4||strcmp(argv[1],"--owned-fixture"))return 64;
    NSString *dir=@(argv[2]),*name=@(argv[3]);NSDictionary *config=load([dir stringByAppendingPathComponent:@"private.json"]);if(!config)return 64;
    pid_t parent=getppid();NSArray *parentBirth=birth(parent);NSDate *end=[NSDate dateWithTimeIntervalSinceNow:25];signals();
    auditKey=config[@"key"];expectedTag=[config[@"tag"]longLongValue];events=[NSMutableArray new];
    [AuditApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    NSMenu *menu=[NSMenu new];NSMenuItem *item=[NSMenuItem new];NSMenu *edit=[NSMenu new];[edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];item.submenu=edit;[menu addItem:item];NSApp.mainMenu=menu;
    NSMutableArray<NSWindow *> *windows=[NSMutableArray new];NSMutableArray<Controls *> *controls=[NSMutableArray new];NSMutableArray<NSTextField *> *texts=[NSMutableArray new];NSMutableArray<NSButton *> *buttons=[NSMutableArray new];NSMutableArray<NSValue *> *originalFrames=[NSMutableArray new];
    for(int n=0;n<2;n++){
        NSWindow *w=[[NSWindow alloc]initWithContentRect:NSMakeRect(100+n*60,130+n*50,440,280) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        w.title=@"Owned focus fixture — identical title";w.releasedWhenClosed=NO;w.animationBehavior=NSWindowAnimationBehaviorNone;
        Controls *c=[Controls new];c.actions=[NSMutableArray new];NSButton *b=[NSButton checkboxWithTitle:@"Native check button" target:c action:@selector(clicked:)];b.frame=NSMakeRect(35,180,220,35);[w.contentView addSubview:b];
        NSTextField *t=[[NSTextField alloc]initWithFrame:NSMakeRect(35,100,360,30)];t.stringValue=@"";[w.contentView addSubview:t];
        [windows addObject:w];[controls addObject:c];[texts addObject:t];[buttons addObject:b];[originalFrames addObject:[NSValue valueWithRect:w.frame]];[w orderFront:nil];
    }
    // AppKit controls can enter a nested event-tracking loop during a mouse down.
    // A common/tracking-mode watchdog wakes that loop with an in-process release,
    // never a globally posted event. Cleanup then restores every owned control.
    __block BOOL trackingWake=NO,trackingRecorded=NO;__block NSString *lastMove=nil;
    NSTimer *watchdog=[NSTimer timerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer){(void)timer;
        NSDictionary *command=load([dir stringByAppendingPathComponent:@"controller.json"]);pid_t pid=[command[@"pid"]intValue];
        if(!trackingRecorded&&pendingDownWindow&&[[NSRunLoop currentRunLoop].currentMode isEqual:NSEventTrackingRunLoopMode]&&[config[@"scenario"]isEqual:@"partial-down-controller-death"]){
            NSMutableDictionary *receipt=[@{@"native_tracking_entered":@YES,@"pid":@(getpid()),@"window":@(pendingDownWindow),@"events":events}mutableCopy];receipt[@"signature"]=signature(receipt,auditKey);
            trackingRecorded=save(receipt,[dir stringByAppendingPathComponent:@"partial-down.json"]);
        }
        // Deterministic owned-window race hook, enabled only in explicit race scenarios.
        if([config[@"scenario"]hasPrefix:@"bounds-"]){NSString *path=[dir stringByAppendingPathComponent:[name stringByAppendingString:@"-move.json"]];NSDictionary *move=load(path);NSMutableDictionary *unsignedMove=[move mutableCopy];[unsignedMove removeObjectForKey:@"signature"];
            if(move&&![lastMove isEqual:move[@"nonce"]]&&[move[@"signature"]isEqual:signature(unsignedMove,auditKey)]){
                for(NSWindow *w in windows){DWFocusIdentity i;DWFocusIdentity requested=identity(move[@"identity"]);if(dw_focus_identity(getpid(),(uint32_t)w.windowNumber,&i)&&i.pid==requested.pid&&i.window==requested.window&&i.seconds==requested.seconds&&i.microseconds==requested.microseconds){
                    NSRect old=w.frame;[w setFrameOrigin:NSMakePoint(old.origin.x+37,old.origin.y+23)];lastMove=move[@"nonce"];
                    NSMutableDictionary *ack=[@{@"nonce":lastMove,@"identity":ident(i),@"moved":@(!NSEqualRects(old,w.frame))}mutableCopy];ack[@"signature"]=signature(ack,auditKey);save(ack,[dir stringByAppendingPathComponent:[name stringByAppendingString:@"-moved.json"]]);break;}}}
        }
        BOOL dead=getppid()!=parent||![birth(parent)isEqual:parentBirth]||(pid>0&&![birth(pid)isEqual:command[@"birth"]]);
        if(!teardownStarted&&(interrupted||dead||end.timeIntervalSinceNow<=0)){teardownStarted=YES;interrupted=interrupted?:SIGTERM;
            for(NSWindow *w in windows)if(w.windowNumber==pendingDownWindow){trackingWake=YES;
                pendingTeardownRelease=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(-10,-10) modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
                [NSApp postEvent:pendingTeardownRelease atStart:YES];break;}}
    }];
    [[NSRunLoop currentRunLoop]addTimer:watchdog forMode:NSRunLoopCommonModes];[[NSRunLoop currentRunLoop]addTimer:watchdog forMode:NSEventTrackingRunLoopMode];
    NSUInteger sequence=0;NSString *statePath=[dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]];
    while(!interrupted&&end.timeIntervalSinceNow>0&&getppid()==parent&&[birth(parent)isEqual:parentBirth]){
        NSDictionary *command=load([dir stringByAppendingPathComponent:@"controller.json"]);controller=[command[@"pid"]intValue];if(controller>0&&![birth(controller)isEqual:command[@"birth"]])break;
        NSMutableArray *states=[NSMutableArray new];
        for(int n=0;n<2;n++){NSWindow *w=windows[n];DWFocusIdentity i;dw_focus_identity(getpid(),(uint32_t)w.windowNumber,&i);NSMutableDictionary *v=[ident(i)mutableCopy];v[@"label"]=[NSString stringWithFormat:@"%@%d",name,n+1];v[@"key"]=@(w.keyWindow);v[@"clicks"]=@(controls[n].clicks);v[@"button_state"]=@(buttons[n].state);v[@"text_sha256"]=digest(texts[n].currentEditor.string?:texts[n].stringValue);v[@"actions"]=controls[n].actions;v[@"button_point"]=point(buttons[n]);v[@"text_point"]=point(texts[n]);[states addObject:v];}
        NSMutableDictionary *state=[@{@"pid":@(getpid()),@"birth":birth(getpid())?:@[],@"sequence":@(sequence++),@"controller":@(controller),@"active":@(NSApp.active),@"key_window":@(NSApp.keyWindow.windowNumber),@"windows":states,@"events":events,@"foreign_events":@(foreignEvents)}mutableCopy];state[@"signature"]=signature(state,auditKey);if(!save(state,statePath))break;pump(.025);
    }
    [watchdog invalidate];
    NSString *reason=interrupted?@"signal_or_foreign_input":end.timeIntervalSinceNow<=0?@"deadline":@"supervisor_exit";
    for(int n=0;n<2;n++){[windows[n] endEditingFor:nil];buttons[n].state=NSControlStateValueOff;[buttons[n] highlight:NO];[windows[n] setFrame:originalFrames[n].rectValue display:NO];controls[n].clicks=0;[controls[n].actions removeAllObjects];texts[n].stringValue=@"";}
    BOOL restored=YES;for(int n=0;n<2;n++)restored&=buttons[n].state==NSControlStateValueOff&&controls[n].clicks==0&&!buttons[n].highlighted&&NSEqualRects(windows[n].frame,originalFrames[n].rectValue)&&[texts[n].stringValue isEqual:@""];
    BOOL foreground=restore(config[@"prior"],@[@{@"pid":@(getpid()),@"birth":birth(getpid())?:@[]}]);
    save(@{@"reason":reason,@"controls_restored":@(restored),@"tracking_watchdog_wake":@(trackingWake),@"teardown_releases_accepted":@(teardownReleases),@"native_tracking_entered":@(trackingRecorded),@"foreground_restore_requested":@(foreground),@"foreign_events":@(foreignEvents),@"pid":@(getpid())},[dir stringByAppendingPathComponent:[name stringByAppendingString:@"-exit.json"]]);
    for(NSWindow *w in windows)[w close];return 0;
}}
