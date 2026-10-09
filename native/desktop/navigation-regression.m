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
    [nav navigate:cycle];drain(worker);drain(main);[nav hold:1];NSNumber *chosen=snapshot()[@"focused"];[nav releaseCycle];[nav invalidate];
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
    check([snapshot()[@"focus"][@"cycle"]isEqual:@2]&&[snapshot()[@"focused"]isEqual:order[2]]&&[nav poll:1],@"logical-only held cycle steps past the second window");
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
    [nav navigate:navigate(1,o1)];weak=nav;[nav shutdown];nav=nil;drain(worker);drain(main);
    driftwm_desktop_destroy(host);}
    check(weak==nil,@"queued closures safely retain until shutdown completion");puts("PASS: headless Objective-C coordinator with actual Rust ABI; no native focus or UI proof.");return 0;
}
