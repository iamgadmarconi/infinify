// SPDX-License-Identifier: GPL-3.0-or-later
#import "common.h"
#import "geometry.h"
#include <dlfcn.h>
static int64_t sessionTag;
static BOOL foreignInput,tapLost;
static CFMachPortRef tap;
static CGEventRef monitor(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *ctx){(void)proxy;(void)ctx;if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){tapLost=YES;return event;}if(CGEventGetIntegerValueField(event,kCGEventSourceUserData)!=sessionTag||CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)!=getpid())foreignInput=YES;return event;}
static CGPoint pointer(void){CGEventRef e=CGEventCreate(NULL);CGPoint p=e?CGEventGetLocation(e):CGPointMake(NAN,NAN);if(e)CFRelease(e);return p;}
static BOOL verified(NSDictionary *v,NSString *key){if(!v)return NO;NSMutableDictionary *copy=[v mutableCopy];NSString *sig=copy[@"signature"];[copy removeObjectForKey:@"signature"];return [sig isEqual:signature(copy,key)];}
@interface Context:NSObject
@property NSString *dir,*key;
@property NSArray *owned;
@property DWFocusIdentity selected;
@property pid_t previous;
@property NSArray *previousBirth;
@property NSDate *deadline;
@property CGPoint pointer;
@property NSString *failure;
@property BOOL transition;
@end
@implementation Context @end
static BOOL same(DWFocusIdentity a,DWFocusIdentity b){return a.pid==b.pid&&a.window==b.window&&a.seconds==b.seconds&&a.microseconds==b.microseconds;}
static bool guard(DWFocusIdentity i,void *raw){Context *c=(__bridge Context *)raw;
    pump(.001);
    if(interrupted||foreignInput||tapLost||!tap||!CGEventTapIsEnabled(tap)||c.deadline.timeIntervalSinceNow<=0||!CGPointEqualToPoint(pointer(),c.pointer)){c.failure=interrupted?@"signal":foreignInput?@"human_input":tapLost||!tap||!CGEventTapIsEnabled(tap)?@"tap_unavailable":c.deadline.timeIntervalSinceNow<=0?@"deadline":@"pointer_moved";return false;}
    if(!same(c.selected,i)){c.failure=@"selection_changed";return false;}
    BOOL enrolled=NO;for(NSDictionary *v in c.owned)if(same(identity(v),i))enrolled=YES;
    if(!enrolled||!dw_focus_owner(i,NULL)){c.failure=@"stale_or_unauthorized_selection";return false;}
    pid_t front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if(front!=i.pid&&(!c.transition||front!=c.previous||![birth(front)isEqual:c.previousBirth])){c.failure=@"foreground_interference";return false;}
    for(NSString *name in @[@"A",@"B"]){NSDictionary *s=load([c.dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);if(!verified(s,c.key)||[s[@"foreign_events"]unsignedIntegerValue]){c.failure=@"fixture_audit_invalid_or_foreign_input";return false;}}
    return true;
}
static NSDictionary *observation(DWFocusResult r){return @{@"outcome":@(dw_focus_outcome_name(r.outcome)),@"ax_error":@(r.ax_error),@"mutation_attempted":@(r.mutation_attempted),@"system_pid":@(r.system_pid),@"system_window":@(r.system_window),@"app_window":@(r.app_window),@"actual_native_focus":@(r.focused),@"bounds":@[@(r.bounds.origin.x),@(r.bounds.origin.y),@(r.bounds.size.width),@(r.bounds.size.height)]};}
static BOOL fixtureReady(NSDictionary *s,NSString *key,pid_t controller){
    if(!verified(s,key)||![s[@"ready"]boolValue]||[s[@"controller"]intValue]!=controller||[s[@"pid"]intValue]<=0||![s[@"foreign_events"]isKindOfClass:NSNumber.class]||[s[@"foreign_events"]unsignedIntegerValue]!=0)return NO;
    NSArray *processBirth=s[@"birth"],*windows=s[@"windows"];if(processBirth.count!=2||[processBirth[0]unsignedLongLongValue]==0||windows.count!=2)return NO;
    uint32_t first=0;for(NSUInteger n=0;n<windows.count;n++){NSDictionary *w=windows[n];DWFocusIdentity i=identity(w);if(i.pid!=[s[@"pid"]intValue]||i.window==0||i.seconds==0||![w[@"birth"]isEqual:processBirth]||!dw_focus_owner(i,NULL)||(n&&i.window==first))return NO;if(!n)first=i.window;}
    return YES;
}
static BOOL matchesProcess(pid_t pid,NSArray *processBirth,NSDictionary *candidate){return pid>0&&processBirth.count==2&&[candidate[@"pid"]intValue]==pid&&[candidate[@"birth"]isEqual:processBirth];}
static BOOL matchesOwnedProcess(pid_t pid,NSArray *processBirth,NSArray *owned){for(NSDictionary *candidate in owned)if(matchesProcess(pid,processBirth,candidate))return YES;return NO;}
static BOOL allowedForeground(pid_t pid,NSArray *processBirth,NSDictionary *prior,NSArray *owned){return matchesProcess(pid,processBirth,prior)||matchesOwnedProcess(pid,processBirth,owned);}
static int checkPreflightPolicy(void){
    NSDictionary *prior=@{@"pid":@10,@"birth":@[@100,@0]};NSArray *owned=@[@{@"pid":@20,@"birth":@[@200,@0],@"window":@1},@{@"pid":@20,@"birth":@[@200,@0],@"window":@2}];
    NSDictionary *checks=@{@"original":@(allowedForeground(10,@[@100,@0],prior,owned)),@"owned":@(allowedForeground(20,@[@200,@0],prior,owned)),@"unknown_rejected":@(!allowedForeground(30,@[@300,@0],prior,owned)),@"reused_pid_rejected":@(!allowedForeground(20,@[@201,@0],prior,owned))};
    BOOL passed=YES;for(NSNumber *value in checks.allValues)passed&=value.boolValue;NSMutableDictionary *report=[checks mutableCopy];report[@"passed"]=@(passed);puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL] encoding:NSUTF8StringEncoding].UTF8String);return passed?0:2;
}
// Private event ABI provenance: Cantrip 4da10af479701c8007074c65f9eb6a2db03c8ffc,
// macos/skylight.rs, same signatures/fields as native/captured-windows/captured.m.
// No global post fallback, physical pointer movement, or target inference from title.
@interface Router:NSObject
@property Context *context;
@property CGEventSourceRef source;
@property CGRect bounds;
@property NSString *raceStage;
@property(copy) BOOL (^raceHook)(void);
@property NSMutableArray *sent;
@property void (*postPID)(pid_t,CGEventRef);
@property void (*location)(CGEventRef,CGPoint);
@property void (*field)(CGEventRef,uint32_t,int64_t);
@end
@implementation Router
- (BOOL)post:(CGEventRef)e at:(DWPoint)p {
    DWFocusIdentity i=self.context.selected;CGRect b;
    if(!e||!guard(i,(__bridge void *)self.context)||!dw_focus_owner(i,&b)||!CGRectEqualToRect(b,self.bounds)||p.x<0||p.y<0||p.x>=b.size.width||p.y>=b.size.height)return NO;
    if([self.raceStage isEqual:@"bounds-before-readback"]&&self.raceHook&&!self.raceHook())return NO;
    DWFocusResult f=dw_focus_observe(i);if(!f.focused)return NO;
    if(!CGRectEqualToRect(f.bounds,self.bounds)){self.context.failure=@"bounds_changed_readback";return NO;}
    if(!guard(i,(__bridge void *)self.context))return NO;
    CGEventSetSource(e,self.source);CGEventSetIntegerValueField(e,kCGEventSourceUserData,sessionTag);CGEventSetIntegerValueField(e,kCGEventSourceUnixProcessID,getpid());
    CGEventSetIntegerValueField(e,(CGEventField)91,i.window);CGEventSetIntegerValueField(e,(CGEventField)92,i.window);
    CGEventSetLocation(e,CGPointMake(b.origin.x+p.x,b.origin.y+p.y));self.location(e,CGPointMake(p.x,p.y));self.field(e,40,i.pid);self.field(e,51,i.window);self.field(e,58,sessionTag);self.field(e,91,i.window);self.field(e,92,i.window);
    if(CGEventGetType(e)==kCGEventLeftMouseDown||CGEventGetType(e)==kCGEventLeftMouseUp)self.field(e,7,3);
    if([self.raceStage isEqual:@"bounds-after-guard"]&&self.raceHook&&!self.raceHook())return NO;
    // No callbacks, run-loop pumping or blocking AX calls between this final CG
    // ownership/birth/bounds check and the scoped post. Never remap a stale click.
    CGRect finalBounds;
    if(!dw_focus_owner(i,&finalBounds)||!CGRectEqualToRect(finalBounds,self.bounds)||!CGRectEqualToRect(finalBounds,f.bounds)){self.context.failure=@"bounds_changed_before_post";return NO;}
    self.postPID(i.pid,e);[self.sent addObject:@{@"target":ident(i),@"type":@(CGEventGetType(e)),@"local":@[@(p.x),@(p.y)],@"tag":@(sessionTag)}];return YES;
}
- (BOOL)click:(DWPoint)p {for(int n=0;n<2;n++){CGEventRef e=CGEventCreateMouseEvent(self.source,n?kCGEventLeftMouseUp:kCGEventLeftMouseDown,CGPointZero,kCGMouseButtonLeft);CGEventSetIntegerValueField(e,kCGMouseEventClickState,1);BOOL ok=[self post:e at:p];CFRelease(e);if(!ok)return NO;pump(.04);}return YES;}
- (BOOL)type:(NSString *)text at:(DWPoint)p {for(int up=0;up<2;up++){CGEventRef e=CGEventCreateKeyboardEvent(self.source,0,!up);CGEventSetFlags(e,kCGEventFlagMaskCommand);BOOL ok=[self post:e at:p];CFRelease(e);if(!ok)return NO;pump(.04);}NSUInteger n=text.length;UniChar chars[n];[text getCharacters:chars range:NSMakeRange(0,n)];for(int up=0;up<2;up++){CGEventRef e=CGEventCreateKeyboardEvent(self.source,0,!up);CGEventSetFlags(e,0);CGEventKeyboardSetUnicodeString(e,n,chars);BOOL ok=[self post:e at:p];CFRelease(e);if(!ok)return NO;pump(.04);}return YES;}
@end
static NSDictionary *snapshot(Context *c){NSMutableDictionary *out=[NSMutableDictionary new];for(NSString *name in @[@"A",@"B"]){NSDictionary *s=load([c.dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);if(!verified(s,c.key))return nil;for(NSDictionary *w in s[@"windows"])out[w[@"label"]]=w;}return out;}
static BOOL keyProof(Context *c,DWFocusIdentity i,NSUInteger after){NSString *name=[c.owned[0][@"pid"]intValue]==i.pid?@"A":@"B";NSDictionary *s=load([c.dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);return verified(s,c.key)&&[s[@"sequence"]unsignedIntegerValue]>after&&[s[@"key_window"]unsignedIntValue]==i.window&&[s[@"active"]boolValue];}
static int run(NSString *dir){
    NSDictionary *config=load([dir stringByAppendingPathComponent:@"private.json"]);if(!config)return 64;
    NSDate *armedEnd=[NSDate dateWithTimeIntervalSinceNow:2];BOOL armed=NO;
    while(!armed&&!interrupted&&armedEnd.timeIntervalSinceNow>0){armed=YES;for(NSString *name in @[@"A",@"B"]){NSDictionary *s=load([dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);armed&=fixtureReady(s,config[@"key"],getpid());}if(!armed)pump(.02);}
    if(!armed){save(@{@"passed":@NO,@"error":@"fixtures did not acknowledge owned controller"},[dir stringByAppendingPathComponent:@"probe.json"]);return 2;}
    sessionTag=[config[@"tag"]longLongValue];Context *c=[Context new];c.dir=dir;c.key=config[@"key"];c.deadline=[NSDate dateWithTimeIntervalSinceNow:15];c.pointer=pointer();c.failure=@"";
    NSMutableDictionary *report=[@{@"passed":@NO,@"steps":[NSMutableArray new],@"scope":@"owned same-title ordinary NSWindows; no IME, menus or drag-and-drop claim"}mutableCopy];
    NSString *receipt=[dir stringByAppendingPathComponent:@"probe.json"];
    NSMutableArray *owned=[NSMutableArray new];for(NSString *name in @[@"A",@"B"]){NSDictionary *s=load([dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);if(!fixtureReady(s,c.key,getpid())){report[@"error"]=@"fixture signed readiness validation failed";save(report,receipt);return 2;}for(NSDictionary *w in s[@"windows"])[owned addObject:ident(identity(w))];}
    c.owned=owned;
    DWFocusIdentity stale=identity(owned[0]);stale.seconds++;DWFocusResult rejected=dw_focus_observe(stale);
    DWFocusIdentity wrongOwner=identity(owned[0]);wrongOwner.pid=[owned[2][@"pid"]intValue];DWFocusResult rejectedOwner=dw_focus_observe(wrongOwner);
    DWFocusIdentity absent=identity(owned[0]);absent.window=0;DWFocusResult rejectedWindow=dw_focus_observe(absent);
    report[@"invalid_identity_rejection"]=@[@(rejected.outcome==DWFocusStale&&!rejected.mutation_attempted),@(rejectedOwner.outcome==DWFocusStale&&!rejectedOwner.mutation_attempted),@(rejectedWindow.outcome==DWFocusStale&&!rejectedWindow.mutation_attempted)];
    BOOL axTrusted=AXIsProcessTrusted(),listenGranted=CGPreflightListenEventAccess();pid_t front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;NSArray *frontBirth=birth(front)?:@[];BOOL priorFront=matchesProcess(front,frontBirth,config[@"prior"]),ownedFront=matchesOwnedProcess(front,frontBirth,owned);NSTimeInterval idle=CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState,kCGAnyInputEventType);BOOL foregroundAllowed=priorFront||ownedFront,idleEnough=idle>=3;
    report[@"preflight"]=@{@"fixture_readiness_validated":@YES,@"ax_trusted":@(axTrusted),@"listen_granted":@(listenGranted),@"foreground":@{@"pid":@(front),@"birth":frontBirth},@"original_prior":config[@"prior"]?:@{},@"foreground_matches_original":@(priorFront),@"foreground_matches_enrolled_owned":@(ownedFront),@"foreground_allowed":@(foregroundAllowed),@"idle_seconds":@(idle),@"idle_requirement_met":@(idleEnough)};
    if(!axTrusted||!listenGranted||!foregroundAllowed||!idleEnough){report[@"error"]=@"preflight unavailable, foreground not original/enrolled-owned, or human input in last 3 seconds";save(report,receipt);return 2;}
    c.previous=front;c.previousBirth=frontBirth;
    CGEventMask mask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|CGEventMaskBit(kCGEventMouseMoved)|CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventRightMouseDragged)|CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|CGEventMaskBit(kCGEventFlagsChanged)|CGEventMaskBit(kCGEventScrollWheel)|CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|CGEventMaskBit(kCGEventOtherMouseDragged)|CGEventMaskBit(kCGEventTabletPointer)|CGEventMaskBit(kCGEventTabletProximity);
    tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,monitor,NULL);if(!tap){report[@"error"]=@"listen-only input guard unavailable";save(report,receipt);return 2;}
    CFRunLoopSourceRef source=CFMachPortCreateRunLoopSource(NULL,tap,0);CFRunLoopAddSource(CFRunLoopGetCurrent(),source,kCFRunLoopCommonModes);
    Router *router=[Router new];router.context=c;router.sent=[NSMutableArray new];router.source=CGEventSourceCreate(kCGEventSourceStatePrivate);
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW);router.postPID=sky?dlsym(sky,"SLEventPostToPid"):NULL;router.field=sky?dlsym(sky,"SLEventSetIntegerValueField"):NULL;router.location=dlsym(RTLD_DEFAULT,"CGEventSetWindowLocation");
    BOOL pass=router.source&&router.postPID&&router.field&&router.location;
    DWCamera cameras[]={{{20,40},{0,0},.75},{{520,80},{35,25},1.5}};
    // Repeat complete A1 -> A2 -> B1 sequence under each camera.
    for(int camera=0;camera<2&&pass;camera++)for(NSString *label in @[@"A1",@"A2",@"B1"]){
        NSDictionary *before=snapshot(c),*selected=before[label];NSMutableDictionary *eventOffsets=[NSMutableDictionary new];for(NSString *name in @[@"A",@"B"])eventOffsets[name]=@([load([dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]])[@"events"]count]);if(!selected){pass=NO;break;}c.selected=identity(selected);c.transition=YES;
        NSString *app=[label substringToIndex:1];NSUInteger seq=[load([dir stringByAppendingPathComponent:[app stringByAppendingString:@".json"]])[@"sequence"]unsignedIntegerValue];
        DWFocusResult focus=dw_focus_select(c.selected,guard,(__bridge void *)c);c.transition=NO;
        NSMutableDictionary *step=[@{@"selected":label,@"identity":ident(c.selected),@"camera":@(camera),@"focus":observation(focus),@"native_key_window":@NO,@"event_target_mapping":@NO,@"controls_proven":@NO}mutableCopy];[report[@"steps"]addObject:step];
        NSDate *keyEnd=[NSDate dateWithTimeIntervalSinceNow:.5];while(focus.focused&&keyEnd.timeIntervalSinceNow>0&&!keyProof(c,c.selected,seq)&&guard(c.selected,(__bridge void *)c))pump(.02);
        BOOL native=focus.focused&&keyProof(c,c.selected,seq)&&guard(c.selected,(__bridge void *)c);step[@"native_key_window"]=@(native);if(!native){pass=NO;break;}
        router.bounds=focus.bounds;NSMutableArray *mappings=[NSMutableArray new];DWPoint local[2];NSArray *points=@[selected[@"button_point"],selected[@"text_point"]];
        for(int n=0;n<2;n++){DWPoint target={[points[n][0]doubleValue],[points[n][1]doubleValue]};DWCamera cam=cameras[camera];DWPoint screen={cam.viewport.x+(target.x-cam.pan.x)*cam.zoom,cam.viewport.y+(target.y-cam.pan.y)*cam.zoom};BOOL mapped=dw_focus_inverse(cam,screen,&local[n])&&fabs(local[n].x-target.x)<1e-6&&fabs(local[n].y-target.y)<1e-6;[mappings addObject:@{@"screen":@[@(screen.x),@(screen.y)],@"local":@[@(local[n].x),@(local[n].y)],@"inverse_matches":@(mapped)}];pass&=mapped;}step[@"mappings"]=mappings;
        if(camera==0&&[label isEqual:@"A1"]&&[config[@"scenario"]isEqual:@"partial-down-controller-death"]){
            CGEventRef down=CGEventCreateMouseEvent(router.source,kCGEventLeftMouseDown,CGPointZero,kCGMouseButtonLeft);CGEventSetIntegerValueField(down,kCGMouseEventClickState,1);BOOL posted=[router post:down at:local[0]];CFRelease(down);
            NSDate *trackingEnd=[NSDate dateWithTimeIntervalSinceNow:2];NSDictionary *tracking=nil;
            while(posted&&trackingEnd.timeIntervalSinceNow>0&&guard(c.selected,(__bridge void *)c)){tracking=load([dir stringByAppendingPathComponent:@"partial-down.json"]);if(verified(tracking,c.key)&&[tracking[@"native_tracking_entered"]boolValue]&&[tracking[@"pid"]intValue]==c.selected.pid&&[tracking[@"window"]unsignedIntValue]==c.selected.window)break;pump(.02);}
            BOOL entered=verified(tracking,c.key)&&[tracking[@"native_tracking_entered"]boolValue]&&[tracking[@"pid"]intValue]==c.selected.pid&&[tracking[@"window"]unsignedIntValue]==c.selected.window;
            if(posted&&entered){save(@{@"ready":@YES,@"partial_down_native_tracking":@YES,@"sent":router.sent},[dir stringByAppendingPathComponent:@"checkpoint.json"]);while(guard(c.selected,(__bridge void *)c))pump(.02);}pass=NO;break;
        }
        if(camera==0&&[label isEqual:@"A1"]&&[config[@"scenario"]hasPrefix:@"bounds-"]){
            router.raceStage=config[@"scenario"];__block BOOL moved=NO;
            router.raceHook=^BOOL{
                NSString *nonce=NSUUID.UUID.UUIDString;NSMutableDictionary *move=[@{@"nonce":nonce,@"identity":ident(c.selected)}mutableCopy];move[@"signature"]=signature(move,c.key);
                if(!save(move,[dir stringByAppendingPathComponent:[app stringByAppendingString:@"-move.json"]]))return NO;
                NSDate *moveEnd=[NSDate dateWithTimeIntervalSinceNow:1];while(moveEnd.timeIntervalSinceNow>0&&guard(c.selected,(__bridge void *)c)){NSDictionary *ack=load([dir stringByAppendingPathComponent:[app stringByAppendingString:@"-moved.json"]]);if(verified(ack,c.key)&&[ack[@"nonce"]isEqual:nonce]&&same(identity(ack[@"identity"]),c.selected)&&[ack[@"moved"]boolValue]){moved=YES;return YES;}pump(.01);}return NO;
            };
            CGEventRef event=CGEventCreateMouseEvent(router.source,kCGEventLeftMouseDown,CGPointZero,kCGMouseButtonLeft);BOOL posted=[router post:event at:local[0]];CFRelease(event);router.raceHook=nil;
            NSString *expectedFailure=[config[@"scenario"]isEqual:@"bounds-before-readback"]?@"bounds_changed_readback":@"bounds_changed_before_post";
            NSDictionary *afterRace=snapshot(c);BOOL unchanged=afterRace.count==before.count;
            for(NSString *name in before){NSDictionary *b=before[name],*a=afterRace[name];for(NSString *field in @[@"clicks",@"button_state",@"text_sha256",@"actions"])unchanged&=[a[field]isEqual:b[field]];}
            for(NSString *name in @[@"A",@"B"]){NSDictionary *audit=load([dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);unchanged&=verified(audit,c.key)&&[audit[@"events"]count]==[eventOffsets[name]unsignedIntegerValue];}
            report[@"race_controls_and_events_unchanged"]=@(unchanged);
            report[@"bounds_race_rejected"]=@(unchanged&&moved&&!posted&&router.sent.count==0&&[c.failure isEqual:expectedFailure]);report[@"race_stage"]=config[@"scenario"];report[@"race_window_moved"]=@(moved);pass=NO;break;
        }
        NSString *text=[NSString stringWithFormat:@"focus-%@-%d",label,camera];NSString *expected=text;
        pass=pass&&[router click:local[0]]&&[router click:local[1]]&&[router type:text at:local[1]];pump(.15);NSDictionary *after=snapshot(c);BOOL controls=pass;
        for(NSString *name in before){NSDictionary *b=before[name],*a=after[name];BOOL chosen=[name isEqual:label];controls&=a&&[a[@"clicks"]integerValue]==[b[@"clicks"]integerValue]+(chosen?1:0)&&[a[@"text_sha256"]isEqual:chosen?digest(expected):b[@"text_sha256"]]&&[a[@"button_state"]integerValue]==(chosen?1-[b[@"button_state"]integerValue]:[b[@"button_state"]integerValue]);}
        BOOL mapping=YES;NSUInteger seen=0;
        for(NSString *name in @[@"A",@"B"]){NSDictionary *audit=load([dir stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]);mapping&=verified(audit,c.key);NSArray *records=audit[@"events"];NSUInteger offset=[eventOffsets[name]unsignedIntegerValue];mapping&=records.count>=offset;
            for(NSUInteger n=offset;n<records.count;n++){NSDictionary *event=records[n];mapping&=[name isEqual:app]&&verified(event,c.key)&&[event[@"window"]unsignedIntValue]==c.selected.window&&[event[@"key_window"]unsignedIntValue]==c.selected.window&&[event[@"active"]boolValue]&&[event[@"tag"]longLongValue]==sessionTag&&[event[@"sender"]intValue]==getpid();
                NSUInteger type=[event[@"type"]unsignedIntegerValue];if(type==NSEventTypeLeftMouseDown||type==NSEventTypeLeftMouseUp){DWPoint wanted=local[seen<2?0:1];NSArray *actual=event[@"local"];mapping&=actual.count==2&&fabs([actual[0]doubleValue]-wanted.x)<1&&fabs(router.bounds.size.height-[actual[1]doubleValue]-wanted.y)<1;}seen++;}}
        mapping&=seen==8;
        step[@"event_target_mapping"]=@(mapping&&seen>0);step[@"controls_proven"]=@(controls);step[@"text_expected_sha256"]=digest(expected);step[@"after"]=after?:@{};pass=pass&&controls&&mapping&&seen>0&&guard(c.selected,(__bridge void *)c)&&dw_focus_observe(c.selected).focused;
        if(pass&&camera==0&&[label isEqual:@"A1"]&&[config[@"scenario"]isEqual:@"normal"]==NO){save(@{@"ready":@YES},[dir stringByAppendingPathComponent:@"checkpoint.json"]);while(guard(c.selected,(__bridge void *)c))pump(.02);pass=NO;}
        c.previous=c.selected.pid;c.previousBirth=@[@(c.selected.seconds),@(c.selected.microseconds)];if(!pass)break;
    }
    report[@"passed"]=@(pass&&[report[@"steps"]count]==6&&!foreignInput&&!tapLost&&!interrupted);report[@"guard_failure"]=c.failure;report[@"foreign_input"]=@(foreignInput);report[@"tap_lost"]=@(tapLost);report[@"signal"]=@(interrupted);report[@"sent"]=router.sent;report[@"pointer_unchanged"]=@(CGPointEqualToPoint(pointer(),c.pointer));
    report[@"foreground_restore_requested"]=@(restore(config[@"prior"],owned));
    CGEventTapEnable(tap,false);CFRunLoopRemoveSource(CFRunLoopGetCurrent(),source,kCFRunLoopCommonModes);CFRelease(source);CFRelease(tap);tap=NULL;if(router.source)CFRelease(router.source);
    save(report,receipt);return [report[@"passed"]boolValue]?0:2;
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc==1||!strcmp(argv[1],"--help")){puts("focus-probe --doctor | --preflight-policy-check | --run-owned EMPTY_PREPARED_DIRECTORY\nDefault/doctor/policy check never activates or injects. Live gate requires explicit e2e --live-owned-focus flag.");return 0;}
    if(argc==2&&!strcmp(argv[1],"--preflight-policy-check"))return checkPreflightPolicy();
    if(argc==3&&!strcmp(argv[1],"--birth")){NSArray *b=birth(atoi(argv[2]));if(!b)return 2;printf("[%llu,%llu]\n",[b[0]unsignedLongLongValue],[b[1]unsignedLongLongValue]);return 0;}
    if(argc==2&&!strcmp(argv[1],"--doctor")){pid_t p=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;NSDictionary *v=@{@"ax_trusted":@(AXIsProcessTrusted()),@"listen_granted":@(CGPreflightListenEventAccess()),@"private_ax_symbol":@(dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow")!=NULL),@"prior":@{@"pid":@(p),@"birth":birth(p)?:@[]},@"idle_seconds":@(CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState,kCGAnyInputEventType))};puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:v options:0 error:NULL] encoding:NSUTF8StringEncoding].UTF8String);return 0;}
    if(argc!=3||strcmp(argv[1],"--run-owned"))return 64;signals();[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];[NSApp finishLaunching];return run(@(argv[2]));
}}
