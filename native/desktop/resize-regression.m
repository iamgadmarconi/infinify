// SPDX-License-Identifier: GPL-3.0-or-later
// No NSApplication, AX, capture stream, input tap, or native window is started.
#import "resize-coordinator.h"
#import "resize-capture-policy.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreVideo/CoreVideo.h>
#include "driftwm_desktop.h"
static void check(BOOL ok,NSString *why){if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(2);}}
static NSDictionary *rect(double x,double y,double w,double h){return @{ @"origin":@{@"x":@(x),@"y":@(y)},@"size":@{@"width":@(w),@"height":@(h)}};}
static NSDictionary *identity(void){return @{@"pid":@123,@"birth_sec":@1800000000,@"birth_usec":@5,@"wid":@1};}
static NSDictionary *call(DriftDesktop *c,NSDictionary *command){NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command}options:0 error:nil];char *r=driftwm_desktop_request(c,data.bytes,data.length);check(r!=NULL,@"C ABI response");NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:r length:strlen(r)]options:0 error:nil];driftwm_desktop_response_free(r);return [reply[@"ok"]boolValue]?reply[@"data"]:nil;}
@interface Driver : NSObject <DWResizeDriver>
@property CGRect bounds;
@property double skew; // how far right of the Accessibility rectangle, `bounds`, the WindowServer's lies
@property BOOL family,timeout;
@property BOOL silent,garbled; // readback cases: no result at all, and one that breaks the result contract
@property NSString *outcome;
@property NSUInteger setters;
@property NSUInteger performed;
@end
@implementation Driver
- (NSDictionary *)rootExtent:(NSDictionary *)i{(void)i;return self.family?rect(self.bounds.origin.x+self.skew,self.bounds.origin.y,self.bounds.size.width,self.bounds.size.height):nil;}
- (NSDictionary *)perform:(NSDictionary *)e{
    BOOL setter=[e[@"requested"]isKindOfClass:NSDictionary.class];if(setter)self.setters++;self.performed++;
    if(self.silent)return nil;
    if(self.garbled)return @{@"outcome":@"observed",@"ax_error":@0,@"mutation_attempted":@YES,@"observed":@YES,@"requested":@{@"width":@1,@"height":@1},@"actual_ax":rect(0,0,5,5),@"actual_cg":rect(90,90,5,5)};
    NSDictionary *requested=setter?e[@"requested"]:@{@"width":@0,@"height":@0};
    if(setter&&!self.timeout&&![self.outcome isEqual:@"rejected"]){CGSize size=CGSizeMake([requested[@"width"]doubleValue],[requested[@"height"]doubleValue]);if([self.outcome isEqual:@"clamped"])size.width=210;self.bounds=CGRectMake(self.bounds.origin.x,self.bounds.origin.y,size.width,size.height);}
    BOOL observed=!(setter&&self.timeout);NSDictionary *r=observed?[self rootExtent:identity()]:rect(0,0,0,0),*ax=observed&&r?rect(self.bounds.origin.x,self.bounds.origin.y,self.bounds.size.width,self.bounds.size.height):r;
    return @{@"outcome":setter?(self.timeout?@"timed_out":self.outcome?:@"applied"):@"observed",@"ax_error":setter&&self.timeout?@(-25204):@0,@"mutation_attempted":@(setter),@"observed":@(observed),@"requested":requested,@"actual_ax":ax,@"actual_cg":r};
}
@end
static CMSampleBufferRef sample(CGRect native,NSDictionary *overrides){
    CVPixelBufferRef pixels=NULL;check(CVPixelBufferCreate(NULL,480,360,kCVPixelFormatType_32BGRA,NULL,&pixels)==kCVReturnSuccess,@"pixel buffer");
    CMVideoFormatDescriptionRef format=NULL;check(CMVideoFormatDescriptionCreateForImageBuffer(NULL,pixels,&format)==noErr,@"format");
    CMSampleTimingInfo timing={kCMTimeInvalid,CMTimeMake(1,30),kCMTimeInvalid};CMSampleBufferRef s=NULL;check(CMSampleBufferCreateReadyWithImageBuffer(NULL,pixels,format,&timing,&s)==noErr,@"sample");CFRelease(format);CFRelease(pixels);
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(s,YES);NSMutableDictionary *m=(__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(a,0);
    m[SCStreamFrameInfoStatus]=@(SCFrameStatusComplete);m[SCStreamFrameInfoDisplayTime]=@200;m[SCStreamFrameInfoScaleFactor]=@2;m[SCStreamFrameInfoContentScale]=@1;
    m[SCStreamFrameInfoContentRect]=CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(10,10,native.size.width,native.size.height)));m[SCStreamFrameInfoScreenRect]=CFBridgingRelease(CGRectCreateDictionaryRepresentation(native));
    for(id key in overrides){if(overrides[key]==NSNull.null)[m removeObjectForKey:key];else m[key]=overrides[key];}return s;
}
static void drain(NSMutableArray *workers,NSMutableArray *mains){NSUInteger n=0;while(workers.count||mains.count){check(++n<30,@"bounded drain");if(workers.count){DWJob job=workers[0];[workers removeObjectAtIndex:0];job();}if(mains.count){DWJob job=mains[0];[mains removeObjectAtIndex:0];job();}}}
static NSDictionary *snap(DriftDesktop *c){return call(c,@{@"op":@"snapshot"});}
static void scenario(NSString *edge,NSString *outcome,BOOL cancel,BOOL timeout,BOOL removeOutput){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];driver.bounds=CGRectMake(10,20,200,150);driver.family=YES;driver.outcome=outcome;driver.timeout=timeout;
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array];
    DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){return call(c,command);}driver:driver clock:^uint64_t{return 100;}worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];co.enabled=YES;
    check(call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800)})!=nil,@"output");
    check(call(c,@{@"op":@"attach",@"identity":identity(),@"bundle_id":@"test",@"title":@"source",@"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(10,20,200,150),@"world_rect":rect(100,100,200,150)})!=nil,@"attach");
    id stream=[NSObject new];[co bind:@1 stream:stream];CMSampleBufferRef s=sample(driver.bounds,@{});__block CMSampleBufferRef installed=NULL;
    check([co accept:s window:@1 stream:stream install:^BOOL(CMSampleBufferRef actual){installed=actual;return YES;}],@"ack sample");check(installed==s,@"same acknowledged sample installed");
    check(![co accept:s window:@1 stream:[NSObject new] install:^BOOL(CMSampleBufferRef actual){(void)actual;check(NO,@"wrong stream installed");return YES;}],@"wrong stream rejected");
    NSDictionary *sourceState=snap(c)[@"windows"][0][@"source"];
    [co invalidate:@1];
    CFArrayRef update=CMSampleBufferGetSampleAttachmentsArray(s,YES);CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(update,0),(__bridge CFStringRef)SCStreamFrameInfoDisplayTime,(__bridge CFNumberRef)@201);
    check(!call(c,@{@"op":@"native_resize_capture_ready",@"window":@1,@"identity":identity(),@"generation":sourceState[@"generation"],@"observation_revision":sourceState[@"observation_revision"],@"buffer":@{@"width":@480,@"height":@360},@"content_rect":rect(0,0,480,360)}),@"stale capture ack rejected");
    check([co accept:s window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"new token restores capture");
    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(update,0),(__bridge CFStringRef)SCStreamFrameInfoDisplayTime,(__bridge CFNumberRef)@202);
    driver.family=NO;check(![co accept:s window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"family expansion invalidates");driver.family=YES;
    check([co accept:s window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"verified root restores capture");
    CMSampleBufferRef fail=sample(driver.bounds,@{SCStreamFrameInfoDisplayTime:@203});
    check(![co accept:fail window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return NO;}],@"backpressure install failure");
    check(snap(c)[@"windows"][0][@"source"][@"capture_revision"]==NSNull.null,@"failed installation revokes authority");
    check([co accept:fail window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"same fresh sample can retry after installation failure");CFRelease(fail);
    __weak DWResizeCoordinator *weak=co;co.changed=^{if(weak.installingWindow){weak.changed=nil;[weak invalidate:@1];}};
    CMSampleBufferRef interrupted=sample(driver.bounds,@{SCStreamFrameInfoDisplayTime:@204});
    check(![co accept:interrupted window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;check(NO,@"invalidated ack must not install");return YES;}],@"reentrant authority loss blocks installation");
    check([co accept:interrupted window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"fresh retry after reentrant invalidation");CFRelease(interrupted);
    NSDictionary *initial=snap(c);NSDictionary *begin=[co request:@{@"op":@"begin_native_resize",@"window":@1,@"output":@1,@"edges":edge,@"start_screen":@{@"x":@50,@"y":@50}}];check(begin!=nil,@"begin");
    check(co.obligations==1&&workers.count==1,@"obligation precedes dispatch");
    [co consume:begin];check(workers.count==1,@"duplicate dispatch suppressed");drain(workers,mains);[co consume:begin];check(workers.count==0,@"completed effect replay suppressed");
    NSNumber *transaction=begin[@"transaction"];
    [co request:@{@"op":@"native_resize_to",@"transaction":transaction,@"screen":@{@"x":@65,@"y":@65}}];
    [co request:@{@"op":@"native_resize_to",@"transaction":transaction,@"screen":@{@"x":@70,@"y":@70}}];
    check(workers.count==1&&co.obligations==1,@"coalescing has one dispatched setter");check(![co canRemove:@1],@"detach/load blocked");
    if(removeOutput)[co consume:call(c,@{@"op":@"remove_output",@"output":@1})];
    else if(cancel)[co cancel];else [co request:@{@"op":@"end_native_resize",@"transaction":transaction}];
    check(co.obligations==1,@"cancel/release preserves setter");if(cancel||timeout||removeOutput)[co shutdown];drain(workers,mains);check(co.obligations==0,@"every dispatched result drains");
    check(driver.setters==(cancel||timeout||removeOutput?1:2),@"release drains latest; shutdown discards unsent intent only");[co shutdown];
    NSDictionary *after=snap(c);if(!removeOutput)check([initial[@"outputs"]isEqual:after[@"outputs"]],@"cameras fixed");
    check([co canRemove:@1]==!timeout,@"uncertainty retained");
    if(timeout){check([after[@"native_resize"][@"phase"]isEqual:@"needs_observation"],@"timeout remains unresolved");check(![co accept:s window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"timeout blocks capture");}
    else {CMSampleBufferRef fresh=sample(driver.bounds,@{SCStreamFrameInfoDisplayTime:@300});check([co accept:fresh window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){check(x==fresh,@"post-resize sample identity");return YES;}],@"post-resize capture");CFRelease(fresh);}
    if(!timeout&&!removeOutput){
        driver.family=NO;[co observeBindings];NSDictionary *lost=snap(c);check(lost[@"windows"][0][@"source"][@"capture_revision"]==NSNull.null,@"family loss without a frame revokes authority");
        [co observeBindings];check([lost isEqual:snap(c)],@"same observed loss does not churn tokens");
        driver.family=YES;[co observeBindings];driver.family=NO;[co observeBindings];NSDictionary *lostAgain=snap(c);
        check([lostAgain[@"windows"][0][@"source"][@"observation_revision"]unsignedLongLongValue]>[lost[@"windows"][0][@"source"][@"observation_revision"]unsignedLongLongValue],@"new native loss after tick-only recovery fences already invalid capture");
        driver.family=YES;CMSampleBufferRef recovered=sample(driver.bounds,@{SCStreamFrameInfoDisplayTime:@301});check([co accept:recovered window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"frame restores verified root");CFRelease(recovered);
        NSDictionary *before=snap(c);CMSampleBufferRef old=sample(driver.bounds,@{SCStreamFrameInfoDisplayTime:@299});
        check(![co accept:old window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"out-of-order frame discarded");check([before isEqual:snap(c)],@"old frame preserves current authority");CFRelease(old);
        driver.bounds=CGRectOffset(driver.bounds,5,7);[co observeBindings];check(snap(c)[@"windows"][0][@"source"][@"capture_revision"]==NSNull.null,@"idle native relocation without a frame revokes authority");CMSampleBufferRef moved=sample(driver.bounds,@{SCStreamFrameInfoDisplayTime:@400});
        check([co accept:moved window:@1 stream:stream install:^BOOL(CMSampleBufferRef x){(void)x;return YES;}],@"idle move fresh mapping restored");
        check([before[@"windows"][0][@"world_rect"]isEqual:snap(c)[@"windows"][0][@"world_rect"]],@"idle reconciliation preserves world geometry");CFRelease(moved);
    }
    [co invalidate:@1];check(!call(c,@{@"op":@"input",@"output":@1,@"screen":@{@"x":@120,@"y":@120},@"identity":identity()}),@"invalidation blocks input");
    CFRelease(s);driftwm_desktop_destroy(c);
}
static void preparing(BOOL cancel,BOOL noOp){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];driver.bounds=CGRectMake(10,20,200,150);driver.family=YES;
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array];
    DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){return call(c,command);}driver:driver clock:^uint64_t{return 100;}worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];co.enabled=YES;
    call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800)});
    call(c,@{@"op":@"attach",@"identity":identity(),@"bundle_id":@"test",@"title":@"source",@"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(10,20,200,150),@"world_rect":rect(100,100,200,150)});
    NSDictionary *initial=snap(c);NSDictionary *begin=[co request:@{@"op":@"begin_native_resize",@"window":@1,@"output":@1,@"edges":@"right",@"start_screen":@{@"x":@50,@"y":@50}}];NSNumber *transaction=begin[@"transaction"];
    if(cancel&&noOp){drain(workers,mains);NSDictionary *removal=call(c,@{@"op":@"remove_output",@"output":@1});check([removal[@"effect"]isKindOfClass:NSDictionary.class],@"output removal emits final observation");[co consume:removal];check(co.obligations==1,@"output removal effect dispatched");drain(workers,mains);check(co.obligations==0&&[co canRemove:@1],@"output removal observation drained");driftwm_desktop_destroy(c);return;}
    check([co request:@{@"op":@"native_resize_to",@"transaction":transaction,@"screen":@{@"x":@65,@"y":@50}}]!=nil,@"motion accepted while baseline queued");
    check([co request:@{@"op":@"native_resize_to",@"transaction":transaction,@"screen":@{@"x":noOp?@50:@70,@"y":@50}}]!=nil,@"latest preparing motion coalesces");
    check(driver.setters==0&&workers.count==1,@"preparing never dispatches setter");
    if(cancel)[co cancel];else [co request:@{@"op":@"end_native_resize",@"transaction":transaction}];drain(workers,mains);
    check(driver.setters==(cancel||noOp?0:1),@"quick release applies latest once; cancellation/no-op applies none");
    check([snap(c)[@"native_resize"][@"last_committed_size"][@"width"]doubleValue]==(cancel||noOp?200:220),@"quick drag commits observed final size");
    check([initial[@"outputs"]isEqual:snap(c)[@"outputs"]],@"quick drag keeps cameras fixed");check(co.obligations==0&&[co canRemove:@1],@"quick drag drains before structural change");driftwm_desktop_destroy(c);
}
// A window whose Accessibility rectangle lies half a point from the WindowServer's. The controller takes the two for one observation
// (within a point) and keeps the Accessibility one; the root extent is the WindowServer's. While the transaction that observed it is
// live they are one geometry and its frames are acknowledged; at rest the mapping is refreshed to the extent and equality is exact.
// Each refusal on the way has its reason, which is what the shell prints.
static void disagreeing(void){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];driver.bounds=CGRectMake(10,20,200,150);driver.skew=.5;driver.family=YES;CGRect native=CGRectMake(10.5,20,200,150);
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array];
    DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){return call(c,command);}driver:driver clock:^uint64_t{return 100;}worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];co.enabled=YES;
    call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800)});
    call(c,@{@"op":@"attach",@"identity":identity(),@"bundle_id":@"test",@"title":@"source",@"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(10.5,20,200,150),@"world_rect":rect(100,100,200,150)});
    BOOL (^install)(CMSampleBufferRef)=^BOOL(CMSampleBufferRef x){(void)x;return YES;};NSString *detail=nil;
    id stream=[NSObject new];[co bind:@1 stream:stream];check([co refusal:@1 detail:&detail]==nil&&detail==nil,@"nothing refused before a frame is judged");
    CMSampleBufferRef stale=sample(native,@{SCStreamFrameInfoDisplayTime:@100});check(![co accept:stale window:@1 stream:stream install:install]&&[[co refusal:@1 detail:&detail]isEqual:@"stale frame"]&&detail.length,@"a frame from before the observation says so");CFRelease(stale);
    CMSampleBufferRef misplaced=sample(CGRectOffset(native,3,0),@{});check(![co accept:misplaced window:@1 stream:stream install:install]&&[[co refusal:@1 detail:&detail]isEqual:@"metadata"]&&[detail containsString:@"screen rectangle"],@"a frame of another rectangle names the rectangles");CFRelease(misplaced);
    CMSampleBufferRef first=sample(native,@{});check([co accept:first window:@1 stream:stream install:install]&&[co refusal:@1 detail:NULL]==nil,@"an acknowledged capture has no refusal");CFRelease(first);
    driver.family=NO;[co observeBindings];check([[co refusal:@1 detail:&detail]isEqual:@"family"]&&detail.length,@"a family says so without a frame");driver.family=YES;
    CMSampleBufferRef back=sample(native,@{SCStreamFrameInfoDisplayTime:@250});check([co accept:back window:@1 stream:stream install:install],@"root restored");CFRelease(back);
    NSDictionary *begin=[co request:@{@"op":@"begin_native_resize",@"window":@1,@"output":@1,@"edges":@"right",@"start_screen":@{@"x":@50,@"y":@50}}];check(begin!=nil,@"begin at rest, extent exact");drain(workers,mains);
    check([snap(c)[@"windows"][0][@"source"][@"observed_rect"]isEqual:rect(10,20,200,150)]&&![co canRemove:@1],@"the live transaction observed the Accessibility rectangle");
    check([co validate:@1],@"within a point of the extent during its own transaction");
    CMSampleBufferRef live=sample(native,@{SCStreamFrameInfoDisplayTime:@300});check([co accept:live window:@1 stream:stream install:install],@"the transaction's frame is acknowledged across the half point");CFRelease(live);
    CMSampleBufferRef far=sample(CGRectOffset(native,2,0),@{SCStreamFrameInfoDisplayTime:@310});driver.skew=2.5;check(![co accept:far window:@1 stream:stream install:install]&&[[co refusal:@1 detail:&detail]isEqual:@"geometry"]&&[detail containsString:@"{12.5,20,200,150}"],@"more than a point is another geometry, and both rectangles are named");CFRelease(far);driver.skew=.5;
    [co request:@{@"op":@"end_native_resize",@"transaction":begin[@"transaction"]}];drain(workers,mains);check([co canRemove:@1],@"transaction over");
    check(![co validate:@1]&&[[co refusal:@1 detail:&detail]isEqual:@"geometry"]&&[detail containsString:@"mapped again"],@"at rest half a point is a move: mapped again");
    check([snap(c)[@"windows"][0][@"source"][@"observed_rect"]isEqual:rect(10.5,20,200,150)],@"the mapping is the extent");
    CMSampleBufferRef rest=sample(native,@{SCStreamFrameInfoDisplayTime:@400});check([co accept:rest window:@1 stream:stream install:install]&&[co refusal:@1 detail:NULL]==nil,@"and its next frame is acknowledged");CFRelease(rest);
    [co shutdown];driftwm_desktop_destroy(c);
}
// Readback mode, what every normal run sets: no result invalidates a capture, an effect nobody
// answers is discharged by the watchdog, and a result the controller refuses leaves no obligation. After every step the window is
// settled and takes input.
static void readback(void){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];driver.bounds=CGRectMake(10,20,200,150);driver.family=YES;
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array],*delays=[NSMutableArray array],*ops=[NSMutableArray array];__block BOOL deaf=NO;
    DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){[ops addObject:command[@"op"]];if(deaf&&[command[@"op"]isEqual:@"native_resize_result"])return nil;return call(c,command);}driver:driver clock:^uint64_t{return 100;}worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];
    co.enabled=YES;co.acknowledges=NO;co.timeout=3;co.delay=^(NSTimeInterval seconds,DWJob job){check(seconds==3,@"the watchdog waits the timeout");[delays addObject:[job copy]];};
    void (^expire)(void)=^{NSArray *due=[delays copy];[delays removeAllObjects];for(DWJob job in due)job();};
    void (^usable)(NSString *)=^(NSString *when){NSDictionary *source=snap(c)[@"windows"][0][@"source"];
        check([source[@"observation_known"]boolValue]&&[source[@"capture_revision"]isEqual:source[@"observation_revision"]],[@"readback: settled " stringByAppendingString:when]);
        check(call(c,@{@"op":@"input",@"output":@1,@"screen":@{@"x":@120,@"y":@120},@"identity":identity()})!=nil,[@"readback: input taken " stringByAppendingString:when]);};
    NSDictionary *(^resize)(int)=^NSDictionary *(int width){NSDictionary *reply=call(c,@{@"op":@"ipc",@"output":@1,@"request":@{@"Resize":@{@"window":@1,@"to":@[@(width),@200]}}});check([reply[@"effect"]isKindOfClass:NSDictionary.class],@"readback: a size request begins a transaction");[co consume:@{@"effect":reply[@"effect"]}];return reply;};
    check(call(c,@{@"op":@"native_resize_capability",@"enabled":@YES,@"readback":@YES})!=nil,@"capability");
    call(c,@{@"op":@"register_output",@"stable_id":@"one",@"screen_bounds":rect(0,0,1000,800)});
    call(c,@{@"op":@"attach",@"identity":identity(),@"bundle_id":@"test",@"title":@"source",@"buffer":@{@"width":@400,@"height":@300},@"source_rect":rect(10,20,200,150),@"world_rect":rect(100,100,200,150)});
    // An answered transaction: nothing is invalidated, the size is the window's, and the watchdogs find nothing left to do.
    resize(300);check(co.obligations==1&&[[co busyWindow]isEqual:@1],@"readback: the window is busy while its effect is owed");usable(@"while the baseline is owed");
    drain(workers,mains);check(co.obligations==0&&[co canRemove:@1]&&[co busyWindow]==nil,@"readback: answered transaction ends");
    check(![ops containsObject:@"invalidate_native_capture"],@"readback: no result invalidates a capture");
    check([snap(c)[@"windows"][0][@"world_rect"][@"size"]isEqual:@{@"width":@300,@"height":@200}]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"complete"],@"readback: the size the window took is committed");usable(@"after an applied size");
    NSDictionary *ended=snap(c);expire();check([ended isEqual:snap(c)]&&co.obligations==0,@"readback: a watchdog after the result changes nothing");
    // A baseline read nobody answers: the watchdog ends the transaction, and the late result is dropped.
    resize(320);expire();check(co.obligations==0&&[co canRemove:@1]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"failed"],@"readback: the watchdog discharges an unanswered read");usable(@"after an unanswered read");
    ended=snap(c);driver.performed=0;drain(workers,mains);check([ended isEqual:snap(c)]&&co.obligations==0,@"readback: a late result is dropped");
    check(driver.performed==0,@"readback: an effect the watchdog answered for is not performed afterwards");
    // A setter nobody answers: one diagnostic read, unanswered too, and the transaction is over.
    resize(340);{DWJob job=workers[0];[workers removeObjectAtIndex:0];job();job=mains[0];[mains removeObjectAtIndex:0];job();}
    check(co.obligations==1&&[snap(c)[@"native_resize"][@"pending_effect"][@"op"]isEqual:@"resize_native_window"],@"readback: the setter is owed");[delays removeObjectAtIndex:0];
    expire();check(co.obligations==1&&[snap(c)[@"native_resize"][@"pending_effect"][@"op"]isEqual:@"observe_resize_source"]&&![co canRemove:@1],@"readback: an unanswered setter is followed by one read");usable(@"while the diagnostic read is owed");
    expire();check(co.obligations==0&&[co canRemove:@1]&&![snap(c)[@"native_resize"][@"uncertain_mutation"]boolValue],@"readback: the watchdog ends an unanswered setter's transaction");usable(@"after an unanswered setter");
    [workers removeAllObjects];[mains removeAllObjects];driver.bounds=CGRectMake(10,20,300,200);
    // A driver that returns nothing is answered for at once.
    driver.silent=YES;resize(360);drain(workers,mains);driver.silent=NO;check(co.obligations==0&&[co canRemove:@1],@"readback: no result is an unanswered effect");usable(@"after a driver without a result");[delays removeAllObjects];
    // A result the controller refuses is replaced by the unanswered one; when that is refused too the obligation is dropped.
    driver.garbled=YES;resize(380);drain(workers,mains);driver.garbled=NO;check(co.obligations==0&&[co canRemove:@1],@"readback: a refused result leaves no obligation");usable(@"after a refused result");[delays removeAllObjects];
    resize(400);deaf=YES;drain(workers,mains);deaf=NO;check(co.obligations==0&&co.failure.length,@"readback: a result refused twice leaves no obligation");
    // That transaction is still live in the controller with nobody performing its effect: seen twice a second apart, it is ended.
    check(![co canRemove:@1]&&[co busyWindow]==nil,@"readback: an orphaned transaction is live");[co reap];check(![co canRemove:@1],@"readback: an orphan is given one look");[co reap];
    check(co.obligations==0&&[co canRemove:@1],@"readback: an orphaned transaction is reaped");usable(@"after an orphan");
    check(co.failure==nil,@"readback: a failure ends with the next result the controller takes");
    // A resize grab. It begins without the acknowledged mode's check of the window's own extent (the first read is the check), and at
    // rest it owes no effect: it is no orphan while the input that holds it is down, and is reaped like one when that input is gone.
    driver.skew=1;NSDictionary *grab=[co request:@{@"op":@"begin_native_resize",@"window":@1,@"output":@1,@"edges":@"right",@"start_screen":@{@"x":@50,@"y":@50}}];driver.skew=0;
    check(grab!=nil,@"readback: a grab begins on a window whose extent is not the one observed");drain(workers,mains);
    check(co.obligations==0&&![co canRemove:@1]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"dragging"],@"readback: a grab at rest owes nothing and is live");usable(@"during a grab at rest");
    __block BOOL down=YES;co.held=^BOOL(NSNumber *transaction){return down&&[transaction isEqual:grab[@"transaction"]];};
    [co reap];[co reap];[co reap];check(![co canRemove:@1]&&[snap(c)[@"native_resize"][@"phase"]isEqual:@"dragging"],@"readback: a held grab at rest is not reaped");
    down=NO;[co reap];check(![co canRemove:@1],@"readback: a grab nobody holds is given one look");[co reap];drain(workers,mains);
    check(co.obligations==0&&[co canRemove:@1],@"readback: a grab nobody holds is reaped");usable(@"after a reaped grab");[delays removeAllObjects];
    [co shutdown];driftwm_desktop_destroy(c);
}
int main(void){@autoreleasepool{
    CGRect native=CGRectMake(10,20,200,150);CMSampleBufferRef s=sample(native,@{});NSDictionary *m=DWResizeCaptureMetadata(s,100,native);check([m[@"buffer"][@"width"]intValue]==480&&[m[@"content_rect"][@"origin"][@"x"]intValue]==20,@"actual padded crop");CFRelease(s);
    NSArray *invalid=@[@{SCStreamFrameInfoDisplayTime:NSNull.null},@{SCStreamFrameInfoDisplayTime:@100},@{SCStreamFrameInfoDisplayTime:@(-1)},@{SCStreamFrameInfoDisplayTime:@100.5},@{SCStreamFrameInfoDisplayTime:@1e30},@{SCStreamFrameInfoStatus:NSNull.null},@{SCStreamFrameInfoStatus:@.5},@{SCStreamFrameInfoContentScale:@0},@{SCStreamFrameInfoScreenRect:NSNull.null},@{SCStreamFrameInfoContentRect:CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(100,100,200,150)))}];
    for(NSDictionary *override in invalid){s=sample(native,override);NSString *why=nil;check(DWResizeCaptureMetadata(s,100,native)==nil,@"invalid metadata rejected");check(DWResizeCaptureDescription(s,100,native,&why)==nil&&why.length,@"and every rejection says why");CFRelease(s);}
    for(NSString *edge in @[@"top_left",@"top",@"top_right",@"right",@"bottom_right",@"bottom",@"bottom_left",@"left"])scenario(edge,nil,NO,NO,NO);
    scenario(@"right",@"clamped",NO,NO,NO);scenario(@"right",@"rejected",YES,NO,NO);scenario(@"right",nil,YES,YES,NO);scenario(@"right",nil,NO,NO,YES);
    preparing(NO,NO);preparing(YES,NO);preparing(NO,YES);preparing(YES,YES);disagreeing();readback();
    puts("PASS: production resize coordinator + Rust C ABI + real synthetic CV/CMSampleBuffer metadata; no native app/window/AX/capture started");return 0;
}}
