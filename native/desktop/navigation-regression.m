// SPDX-License-Identifier: GPL-3.0-or-later
// Foundation-only host: actual coordinator and Rust ABI, no NSApplication/native driver.
#import "navigation-coordinator.h"
#include "driftwm_desktop.h"
static void check(BOOL value,NSString *message){if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static BOOL rejectionExpected=NO;
static NSDictionary *call(DriftDesktop *host,NSDictionary *command){
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command} options:0 error:nil];
    char *raw=driftwm_desktop_request(host,data.bytes,data.length);check(raw!=NULL,@"ABI response");
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:strlen(raw)] options:0 error:nil];driftwm_desktop_response_free(raw);
    if(![reply[@"ok"]boolValue]&&rejectionExpected){rejectionExpected=NO;return nil;}
    check([reply[@"ok"]boolValue],[NSString stringWithFormat:@"%@ → %@",command,reply]);return reply[@"data"];
}
static NSDictionary *rect(double x,double y,double w,double h){return @{@"origin":@{@"x":@(x),@"y":@(y)},@"size":@{@"width":@(w),@"height":@(h)}};}
static NSDictionary *ident(int pid,int wid){return @{@"pid":@(pid),@"birth_sec":@100,@"birth_usec":@7,@"wid":@(wid)};}
@interface FakeDriver : NSObject <DWNavigationDriver>
@property NSUInteger calls;
@property BOOL permitted,success;
@property NSDictionary *observation;
@property (copy) DWJob during;
@end
@implementation FakeDriver
- (DWGuard)authorization:(NSDictionary *)identity {(void)identity;return ^BOOL{return self.permitted;};}
- (BOOL)select:(NSDictionary *)identity guard:(DWGuard)guard {(void)identity;self.calls++;BOOL before=guard();if(self.during)self.during();return before&&guard()&&self.success;}
- (NSDictionary *)observe{return self.observation;}
@end
static void drain(NSMutableArray *jobs){while(jobs.count){DWJob job=jobs[0];[jobs removeObjectAtIndex:0];job();}}
int main(void){__weak DWNavigationCoordinator *weak;@autoreleasepool{
    DriftDesktop *host=driftwm_desktop_create();NSMutableArray *worker=[NSMutableArray array],*main=[NSMutableArray array];FakeDriver *driver=[FakeDriver new];driver.permitted=driver.success=YES;
    __block uint64_t clock=1000000000;__block NSUInteger saved=0,rendered=0;
    DWNavigationCoordinator *nav=[[DWNavigationCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return call(host,c);} driver:driver clock:^uint64_t{return clock;} worker:^(DWJob job){[worker addObject:[job copy]];} main:^(DWJob job){[main addObject:[job copy]];}];
    nav.focusAllowed=YES;nav.changed=^{rendered++;};nav.settled=^{saved++;};
    NSNumber *o1=call(host,@{@"op":@"register_output",@"stable_id":@"left",@"screen_bounds":rect(0,64,900,600)})[@"output"];
    NSNumber *o2=call(host,@{@"op":@"register_output",@"stable_id":@"right",@"screen_bounds":rect(1000,64,900,600)})[@"output"];
    NSArray *ids=@[ident(10,1),ident(10,2),ident(20,3)];NSMutableArray *windows=[NSMutableArray array];
    for(NSUInteger n=0;n<ids.count;n++)[windows addObject:call(host,@{@"op":@"attach",@"identity":ids[n],@"bundle_id":@"test",@"title":@"normal",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(0,0,200,100),@"world_rect":rect(1500+n*500,400,200,100)})[@"window"]];
    NSDictionary *(^navigate)(NSUInteger,NSNumber *)=^NSDictionary *(NSUInteger n,NSNumber *o){return @{@"op":@"navigate_window",@"window":windows[n],@"output":o,@"zoom_policy":@"reset"};};
    NSDictionary *(^snapshot)(void)=^NSDictionary *{return call(host,@{@"op":@"snapshot"});};
    [nav navigate:navigate(0,o1)];check(worker.count==0&&driver.calls==0,@"disabled default does no work");nav.enabled=YES;[nav frame];
    for(NSUInteger n=0;n<3;n++){[nav navigate:navigate(n,o1)];drain(worker);drain(main);}
    check([snapshot()[@"focus"][@"history"]isEqual:@[windows[2],windows[1],windows[0]]],@"A1 A2 B1 exact confirmations");
    NSDictionary *cycle=@{@"op":@"cycle_navigate",@"output":o1,@"backward":@NO,@"held":@YES};
    [nav navigate:navigate(0,o1)];NSDictionary *accepted=snapshot()[@"focus"][@"pending_effect"];rejectionExpected=YES;
    [nav navigate:@{@"op":@"navigate_window",@"window":windows[0],@"output":@9999,@"zoom_policy":@"reset"}];check(!rejectionExpected&&[snapshot()[@"focus"][@"pending_effect"]isEqual:accepted],@"rejected navigation preserves accepted pending effect");drain(worker);drain(main);check([snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[0]],@"accepted ticket survives rejected navigation");
    // Restore known history for the next cycle scenario.
    [nav navigate:navigate(1,o1)];drain(worker);drain(main);[nav navigate:navigate(2,o1)];drain(worker);drain(main);
    NSUInteger before=driver.calls;[nav navigate:cycle];[nav navigate:cycle];[nav releaseCycle];drain(worker);drain(main);
    check(driver.calls==before+1,@"obsolete queued ticket skips driver");check([snapshot()[@"focus"][@"history"][0]isEqual:windows[0]],@"release pending commits latest only");
    [nav navigate:cycle];drain(worker);drain(main);id held=snapshot()[@"focus"][@"cycle"];check(held!=NSNull.null,@"held cycle stays live");
    NSMutableDictionary *observed=[snapshot()[@"focus"][@"observed_native"][@"identity"] mutableCopy];[observed removeObjectForKey:@"owner"];driver.observation=observed;[nav observe];drain(worker);drain(main);check([snapshot()[@"focus"][@"cycle"]isEqual:held],@"duplicate confirmation preserves cycle");
    [nav navigate:cycle];DWJob delayed=worker[0];[worker removeObjectAtIndex:0];
    NSMutableDictionary *pendingIdentity=[snapshot()[@"focus"][@"pending_effect"][@"identity"]mutableCopy];[pendingIdentity removeObjectForKey:@"owner"];driver.observation=pendingIdentity;
    NSUInteger callsBeforeObservation=driver.calls;[nav observe];drain(worker);drain(main);delayed();delayed=nil;drain(main);
    check(driver.calls==callsBeforeObservation&&snapshot()[@"focus"][@"pending_effect"]==NSNull.null&&snapshot()[@"focus"][@"cycle"]!=NSNull.null,@"independent expected confirmation preserves cycle and cancels queued mutation");
    // Hold-to-commit: modifiers are opaque bits here; 1 holds the cycle, 2 is any other modifier.
    check(![nav poll:0],@"no hold is open before a held step");
    [nav navigate:@{@"op":@"cycle_navigate",@"output":o1,@"backward":@YES,@"held":@YES}];[nav hold:1];
    check([nav poll:1]&&[nav poll:3]&&snapshot()[@"focus"][@"cycle"]!=NSNull.null,@"hold modifier down keeps the cycle open");
    check(![nav poll:2]&&[snapshot()[@"focus"][@"release_pending"]boolValue],@"hold modifier up ends the cycle and waits for the pending result");
    drain(worker);drain(main);check(snapshot()[@"focus"][@"cycle"]==NSNull.null&&![nav poll:1],@"reverse release finishes and the hold is closed");
    [nav navigate:cycle];drain(worker);drain(main);[nav hold:1];id live=snapshot()[@"focus"][@"cycle"];before=driver.calls;
    [nav interrupt];drain(worker);drain(main);check(live!=NSNull.null&&[snapshot()[@"focus"][@"cycle"]isEqual:live]&&[nav poll:1]&&driver.calls==before,@"unrelated input with no request in flight leaves a confirmed held cycle open");
    check(![nav poll:0]&&snapshot()[@"focus"][@"cycle"]==NSNull.null,@"confirmed held cycle commits on release");
    // A canvas press, as the shell sends it: the cycle is released, then focus work is withdrawn and flights stop.
    [nav navigate:cycle];drain(worker);drain(main);[nav hold:1];NSNumber *chosen=snapshot()[@"focus"][@"intent"];[nav releaseCycle];[nav invalidate];
    check(snapshot()[@"focus"][@"cycle"]==NSNull.null&&[snapshot()[@"focus"][@"history"][0]isEqual:chosen]&&![nav poll:1],@"canvas press commits a confirmed held cycle");
    [nav navigate:cycle];[nav hold:1];before=driver.calls;[nav releaseCycle];[nav invalidate];drain(worker);drain(main);
    check(driver.calls==before&&snapshot()[@"focus"][@"pending_effect"]==NSNull.null&&snapshot()[@"focus"][@"cycle"]==NSNull.null&&[snapshot()[@"focus"][@"history"][0]isEqual:chosen],@"canvas press drops a held cycle whose selection is still in flight");
    [nav navigate:cycle];[nav hold:1];before=driver.calls;[nav interrupt];drain(worker);drain(main);
    check(driver.calls==before&&snapshot()[@"focus"][@"pending_effect"]==NSNull.null&&snapshot()[@"focus"][@"cycle"]==NSNull.null&&![nav poll:1],@"unrelated input withdraws the request in flight, its cycle and its hold");
    // An action or IPC reply carries its focus request inside "effects", beside the shell's own.
    NSDictionary *request=call(host,@{@"op":@"focus",@"window":windows[1]})[@"effect"];before=driver.calls;
    [nav perform:@{@"navigation":NSNull.null,@"effects":@[@{@"op":@"exec",@"command":@"true",@"env":@{}},request],@"dirty":@YES}];drain(worker);drain(main);
    check(driver.calls==before+1&&[snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[1]],@"focus request inside effects reaches the driver and is confirmed");
    [nav navigate:navigate(2,o1)];before=driver.calls;[nav perform:@{@"navigation":NSNull.null,@"effects":@[],@"dirty":@NO}];drain(worker);drain(main);
    check(driver.calls==before+1&&[snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[2]],@"reply without a focus request leaves the pending one in flight");
    [nav navigate:navigate(0,o1)];call(host,@{@"op":@"cancel_focus_cycle"});before=driver.calls;[nav perform:@{@"navigation":NSNull.null,@"effects":@[],@"dirty":@NO}];drain(worker);drain(main);
    check(driver.calls==before&&[snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[2]],@"request the controller dropped is withdrawn from the driver");
    driver.observation=nil;NSDictionary *unchanged=snapshot();[nav observe];drain(worker);drain(main);check([snapshot()isEqual:unchanged],@"unknown observation is no-op");
    driver.observation=ids[1];[nav observe];drain(worker);drain(main);check([snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[1]],@"external bound focus reconciles");
    driver.observation=ident(99,99);[nav observe];drain(worker);drain(main);check(snapshot()[@"focus"][@"observed_native"]==NSNull.null,@"verified outside focus lost");
    driver.observation=ids[0];[nav observe];[nav navigate:navigate(2,o1)];drain(worker);drain(main);check([snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[2]],@"old observation cannot overwrite new action");
    [nav navigate:navigate(0,o1)];[nav invalidate];drain(worker);drain(main);check(snapshot()[@"focus"][@"pending_effect"]==NSNull.null,@"pointer intent cancels pending");check([snapshot()[@"navigation"][@"flights"]count]==0,@"pointer freezes flights");
    [nav navigate:navigate(0,o1)];check(snapshot()[@"focus"][@"pending_effect"]!=NSNull.null,@"focus effect pending");[nav cancelFocus];drain(worker);drain(main);check(snapshot()[@"focus"][@"pending_effect"]==NSNull.null,@"observed input cancels pending");check([snapshot()[@"navigation"][@"flights"]count]==1,@"observed input leaves the camera flight flying");
    driver.during=^{[nav invalidate];};[nav navigate:navigate(1,o1)];drain(worker);drain(main);check(snapshot()[@"focus"][@"pending_effect"]==NSNull.null,@"running guard sees cancellation");driver.during=nil;
    driver.permitted=NO;[nav navigate:navigate(1,o1)];drain(worker);drain(main);check(![snapshot()[@"focus"][@"last_result"][@"success"]boolValue],@"authorization denied cannot confirm");driver.permitted=YES;
    driver.success=NO;[nav navigate:navigate(1,o1)];drain(worker);drain(main);check(![snapshot()[@"focus"][@"last_result"][@"success"]boolValue],@"adapter failure cannot confirm");driver.success=YES;
    // Logical-only focus: the request is answered focus_logical and never reaches the driver. It claims no native
    // focus, the window enters the order, and a held cycle steps past the second window and commits on release.
    nav.focusAllowed=NO;before=driver.calls;id seen=snapshot()[@"focus"][@"observed_native"];[nav navigate:navigate(0,o1)];NSDictionary *logical=snapshot()[@"focus"];
    check(driver.calls==before&&worker.count==0&&![logical[@"last_result"][@"success"]boolValue]&&[logical[@"last_result"][@"logical"]boolValue]&&logical[@"pending_effect"]==NSNull.null,@"logical-only focus never reaches the adapter");
    check([logical[@"history"][0]isEqual:windows[0]]&&[logical[@"observed_native"]isEqual:seen],@"logical-only focus enters the order and claims no native focus");
    NSArray *order=logical[@"history"];[nav navigate:cycle];[nav navigate:cycle];[nav hold:1];
    check([snapshot()[@"focus"][@"cycle"]isEqual:@2]&&[snapshot()[@"focus"][@"intent"]isEqual:order[2]]&&[nav poll:1],@"logical-only held cycle steps past the second window");
    check(![nav poll:0]&&snapshot()[@"focus"][@"cycle"]==NSNull.null&&[snapshot()[@"focus"][@"history"][0]isEqual:order[2]]&&[snapshot()[@"focus"][@"observed_native"]isEqual:seen]&&driver.calls==before&&worker.count==0,@"logical-only held cycle commits on release");nav.focusAllowed=YES;
    [nav navigate:navigate(0,o1)];clock+=2000000000;drain(worker);drain(main);check(![snapshot()[@"focus"][@"last_result"][@"success"]boolValue],@"deadline cannot confirm");
    [nav navigate:navigate(0,o1)];NSDictionary *old=snapshot()[@"focus"][@"pending_effect"];[nav invalidate];call(host,@{@"op":@"remove_source",@"window":windows[0],@"identity":ids[0],@"keep_placeholder":@YES});
    call(host,@{@"op":@"attach",@"logical_id":windows[0],@"identity":ids[0],@"bundle_id":@"test",@"title":@"rebound",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(0,0,200,100)});
    [nav navigate:navigate(0,o1)];check(![old[@"generation"]isEqual:snapshot()[@"focus"][@"pending_effect"][@"generation"]],@"rebind generation differs");drain(worker);drain(main);
    [nav navigate:navigate(2,o2)];drain(worker);drain(main);NSDictionary *initial=snapshot()[@"outputs"];[nav frame];clock+=16666667;check([nav frame],@"two-output flight active");check(![snapshot()[@"outputs"]isEqual:initial],@"intermediate actual camera placement");
    for(int n=0;n<1000;n++){clock+=16666667;if(![nav frame])break;}
    check([snapshot()[@"navigation"][@"flights"]count]==0&&saved>0&&rendered>0,@"one clock settles all outputs");NSUInteger savedBefore=saved;[nav frame];check(saved==savedBefore,@"idle does not repeatedly save");
    NSString *path=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];call(host,@{@"op":@"save",@"path":path});DriftDesktop *reloaded=driftwm_desktop_create();call(reloaded,@{@"op":@"load",@"path":path});
    call(reloaded,@{@"op":@"register_output",@"stable_id":@"left",@"screen_bounds":rect(0,64,900,600)});call(reloaded,@{@"op":@"register_output",@"stable_id":@"right",@"screen_bounds":rect(1000,64,900,600)});NSDictionary *savedSnapshot=call(reloaded,@{@"op":@"snapshot"});check([savedSnapshot[@"outputs"]isEqual:snapshot()[@"outputs"]],@"saved final two output camera poses");driftwm_desktop_destroy(reloaded);[NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSMutableDictionary *owned=[ident(30,4)mutableCopy];owned[@"owner"]=@88;
    NSNumber *unsupported=call(host,@{@"op":@"attach",@"identity":owned,@"bundle_id":@"test",@"title":@"unsupported owner",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(0,0,200,100)})[@"window"];
    before=driver.calls;[nav navigate:@{@"op":@"navigate_window",@"window":unsupported,@"output":o1,@"zoom_policy":@"reset"}];check(worker.count==0&&driver.calls==before,@"unsupported owner authority never dispatches");
    driver.observation=ident(30,4);unchanged=snapshot();[nav observe];drain(worker);drain(main);check([snapshot()isEqual:unchanged],@"unvalidated owner observation stays unknown");
    // The native tap observes a real root press; no synthetic click or focus
    // setter is involved. This uses the actual coordinator and controller.
    NSDictionary *(^view)(void)=^NSDictionary *{for(NSDictionary *o in snapshot()[@"outputs"])if([o[@"id"]isEqual:o1])return o;return nil;};
    NSDictionary *(^clickBinding)(void)=^NSDictionary *{for(NSDictionary *w in snapshot()[@"windows"])if([w[@"window"]isEqual:windows[0]])return @{@"window":windows[0],@"identity":w[@"source"][@"identity"],@"generation":w[@"source"][@"generation"]};return nil;};
    void (^partialView)(void)=^{
        [nav invalidate];call(host,@{@"op":@"zoom",@"output":o1,@"zoom":@.5,@"anchor":@{@"x":@0,@"y":@64}});
        NSDictionary *camera=view()[@"camera"];call(host,@{@"op":@"pan",@"output":o1,@"screen_delta":@{@"x":@((1600-[camera[@"x"]doubleValue])*.5),@"y":@(-[camera[@"y"]doubleValue]*.5)}});
    };
    partialView();NSDictionary *click=clickBinding(),*pose=view();before=driver.calls;
    NSDictionary *other=nil;for(NSDictionary *w in snapshot()[@"windows"])if([w[@"window"]isEqual:windows[1]])other=@{@"op":@"observe_focus",@"window":windows[1],@"identity":w[@"source"][@"identity"],@"generation":w[@"source"][@"generation"]};
    call(host,other);driver.observation=ids[1];[nav beginNativeClick:click output:o1];drain(worker);drain(main);
    check([view()isEqual:pose]&&[snapshot()[@"navigation"][@"flights"]count]==0,@"pre-delivery old focus does not consume the native click");
    driver.observation=ids[0];[nav observe];drain(worker);drain(main);
    check([snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[0]]&&[view()isEqual:pose]&&[snapshot()[@"navigation"][@"flights"]count]==0&&driver.calls==before,@"native root click confirms actual focus without activation pan, zoom or native setter");
    [nav endNativeClick:click completed:YES];drain(worker);drain(main);
    check([snapshot()[@"navigation"][@"flights"]count]==0,@"default click release leaves a clipped native window and camera alone");
    NSString *clickConfig=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    check([@"[navigation]\nauto_navigate_on_click = true\n" writeToFile:clickConfig atomically:YES encoding:NSUTF8StringEncoding error:nil],@"write owned click config");
    call(host,@{@"op":@"load_config",@"path":clickConfig});[NSFileManager.defaultManager removeItemAtPath:clickConfig error:nil];
    __block BOOL resumed=NO;nav.nativeClickReleaseReady=^BOOL(NSDictionary *binding){return resumed&&[binding[@"window"]isEqual:windows[0]];};
    partialView();[nav beginNativeClick:click output:o1];[nav endNativeClick:click completed:YES];drain(worker);drain(main);
    check([snapshot()[@"navigation"][@"flights"]count]==0,@"completed already-focused click waits for native ownership release and placement ACK");
    resumed=YES;[nav frame];drain(worker);drain(main);
    NSDictionary *flight=snapshot()[@"navigation"][@"flights"][o1.stringValue];
    check(flight&&[flight[@"zoom_target"]doubleValue]==.5&&driver.calls==before,@"acknowledged completed click navigates at current zoom without a native focus setter");
    partialView();[nav beginNativeClick:click output:o1];[nav endNativeClick:click completed:NO];drain(worker);drain(main);
    check([snapshot()[@"navigation"][@"flights"]count]==0,@"a native drag or cancelled pair never becomes release navigation");
    partialView();resumed=NO;[nav beginNativeClick:click output:o1];[nav endNativeClick:click completed:YES];drain(worker);drain(main);
    call(host,@{@"op":@"pan",@"output":o1,@"screen_delta":@{@"x":@10,@"y":@0}});pose=view();resumed=YES;[nav frame];drain(worker);drain(main);
    check([view()isEqual:pose]&&[snapshot()[@"navigation"][@"flights"]count]==0,@"deferred click cannot overwrite a newer camera pose");
    partialView();resumed=NO;[nav beginNativeClick:click output:o1];[nav endNativeClick:click completed:YES];drain(worker);drain(main);clock+=2000000000;[nav frame];resumed=YES;[nav frame];drain(worker);drain(main);
    check([snapshot()[@"navigation"][@"flights"]count]==0,@"expired placement wait cannot navigate later");
    partialView();call(host,other);[nav beginNativeClick:click output:o1];drain(worker);clock+=200000000;drain(main);
    check([snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[1]],@"aged root readback cannot confirm a click");
    [nav endNativeClick:click completed:NO];drain(worker);drain(main);check([snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[0]]&&[snapshot()[@"navigation"][@"flights"]count]==0,@"fresh readback after rejected aged result stays focus-only");
    // A real app can become key while its new root is deliberately placed
    // behind Fill. Correct that launch observation once; later input wins.
    [nav invalidate];call(host,@{@"op":@"adoption_complete"});call(host,@{@"op":@"native_resize_capability",@"enabled":@YES});
    [nav navigate:@{@"op":@"focus",@"window":windows[0]}];drain(worker);drain(main);
    NSDictionary * (^full)(void)=^NSDictionary *{return snapshot()[@"outputs"][0][@"fullscreen"];};
    void (^enter)(void)=^{[nav navigate:@{@"op":@"focus",@"window":windows[0]}];drain(worker);drain(main);[nav navigate:@{@"op":@"action",@"output":o1,@"action":@"toggle-fullscreen"}];drain(worker);drain(main);check([full()[@"window"]isEqual:windows[0]],@"enter Fill for arrival policy");};
    enter();NSDictionary *arrival=call(host,@{@"op":@"attach",@"identity":ident(40,5),@"bundle_id":@"new",@"title":@"arriving",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(0,0,200,100),@"output":o1});
    check([arrival[@"background"]boolValue],@"attach exposes actual background placement provenance");
    NSDictionary *filled=snapshot()[@"outputs"];[nav preserveBackgroundArrival:arrival];before=driver.calls;
    driver.observation=ident(40,5);[nav observe];drain(worker);drain(main);
    check([full()[@"window"]isEqual:windows[0]]&&[snapshot()[@"outputs"]isEqual:filled]&&driver.calls==before,@"launch focus leaves Fill and camera unchanged and queues one actual refocus");
    drain(worker);drain(main);check(driver.calls==before+1&&[snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[0]],@"background correction uses the driver, not newcomer readback, to confirm Fill focus");
    [nav observe];drain(worker);drain(main);check(full()==(id)NSNull.null&&[snapshot()[@"focus"][@"intent"]isEqual:arrival[@"window"]],@"later native activation is not suppressed after the one correction");
    enter();[nav preserveBackgroundArrival:arrival];[nav cancelBackgroundArrival];before=driver.calls;[nav observe];drain(worker);drain(main);
    check(full()==(id)NSNull.null&&driver.calls==before,@"physical keyboard or Dock input retires launch correction before native activation");
    enter();[nav preserveBackgroundArrival:arrival];clock+=1600000000;before=driver.calls;[nav observe];drain(worker);drain(main);
    check(full()==(id)NSNull.null&&driver.calls==before,@"expired arrival cannot override later native focus");
    enter();[nav preserveBackgroundArrival:arrival];before=driver.calls;
    nav.observationBinding=^DWObservedBinding{NSDictionary *binding=nil;for(NSDictionary *w in snapshot()[@"windows"])if([w[@"window"]isEqual:windows[0]])binding=@{@"window":w[@"window"],@"identity":w[@"source"][@"identity"],@"generation":w[@"source"][@"generation"]};return ^NSDictionary *(NSDictionary *actual){(void)actual;return binding;};};
    driver.observation=ident(10,99);[nav observe];drain(worker);drain(main);
    check([full()[@"window"]isEqual:windows[0]]&&driver.calls==before,@"Fill parent's verified native dialog keeps focus without corrective root selection");nav.observationBinding=nil;
    [nav preserveBackgroundArrival:arrival];driver.observation=ident(40,5);before=driver.calls;[nav observe];drain(worker);drain(main);
    driver.observation=ident(40,99);drain(worker);drain(main);check(driver.calls==before&&snapshot()[@"focus"][@"pending_effect"]==NSNull.null,@"new arrival's dialog supersedes a queued root refocus before any native setter");
    // An authored quiet rule has the same launch-only correction outside Fill.
    // The real app may activate itself despite the controller requesting no focus.
    if(full()!=(id)NSNull.null)[nav navigate:@{@"op":@"action",@"output":o1,@"action":@"toggle-fullscreen"}];
    [nav navigate:@{@"op":@"focus",@"window":windows[0]}];drain(worker);drain(main);[nav invalidate];
    NSString *quietConfig=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    check([@"[[window_rules]]\napp_id = \"quiet\"\nfocus_on_open = false\n" writeToFile:quietConfig atomically:YES encoding:NSUTF8StringEncoding error:nil],@"write owned quiet config");
    call(host,@{@"op":@"load_config",@"path":quietConfig});[NSFileManager.defaultManager removeItemAtPath:quietConfig error:nil];
    NSDictionary *quietArrival=call(host,@{@"op":@"attach",@"identity":ident(50,6),@"bundle_id":@"quiet",@"title":@"quiet arrival",@"buffer":@{@"width":@200,@"height":@100},@"source_rect":rect(0,0,200,100),@"output":o1});
    check(![quietArrival[@"background"]boolValue]&&quietArrival[@"effect"]==NSNull.null,@"quiet rule keeps ordinary arrival unfocused outside Fill");
    NSDictionary *quietViews=snapshot()[@"outputs"];[nav preserveBackgroundArrival:quietArrival];before=driver.calls;driver.observation=ident(50,6);
    [nav observe];drain(worker);drain(main);
    check([snapshot()[@"focus"][@"intent"]isEqual:windows[0]]&&[snapshot()[@"outputs"]isEqual:quietViews]&&driver.calls==before,@"quiet launch native activation preserves exact prior live focus and camera");
    drain(worker);drain(main);check(driver.calls==before+1&&[snapshot()[@"focus"][@"observed_native"][@"window"]isEqual:windows[0]],@"quiet correction confirms only the actual driver result");
    [nav observe];drain(worker);drain(main);check([snapshot()[@"focus"][@"intent"]isEqual:quietArrival[@"window"]],@"quiet rule does not suppress later native selection");
    [nav navigate:@{@"op":@"focus",@"window":windows[0]}];drain(worker);drain(main);[nav preserveBackgroundArrival:quietArrival];[nav cancelBackgroundArrival];before=driver.calls;
    [nav observe];drain(worker);drain(main);check([snapshot()[@"focus"][@"intent"]isEqual:quietArrival[@"window"]]&&driver.calls==before,@"physical input cancels quiet launch correction");
    [nav navigate:navigate(1,o1)];weak=nav;[nav shutdown];nav=nil;drain(worker);drain(main);
    driftwm_desktop_destroy(host);}
    check(weak==nil,@"queued closures safely retain until shutdown completion");puts("PASS: headless Objective-C coordinator with actual Rust ABI; no native focus or UI proof.");return 0;
}
