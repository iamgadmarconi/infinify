// SPDX-License-Identifier: GPL-3.0-or-later
// No NSApplication, AX, capture stream, input tap, or native window is started.
#import "resize-coordinator.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreVideo/CoreVideo.h>
#include "driftwm_desktop.h"
#include <math.h>
static void check(BOOL ok,NSString *why){if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(2);}}
static NSDictionary *rect(double x,double y,double w,double h){return @{ @"origin":@{@"x":@(x),@"y":@(y)},@"size":@{@"width":@(w),@"height":@(h)}};}
static NSDictionary *identity(void){return @{@"pid":@123,@"birth_sec":@1800000000,@"birth_usec":@5,@"wid":@1};}
static NSDictionary *call(DriftDesktop *c,NSDictionary *command){NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command}options:0 error:nil];char *r=driftwm_desktop_request(c,data.bytes,data.length);check(r!=NULL,@"C ABI response");NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:r length:strlen(r)]options:0 error:nil];driftwm_desktop_response_free(r);return [reply[@"ok"]boolValue]?reply[@"data"]:nil;}
@interface Driver : NSObject <DWResizeDriver>
@property CGRect bounds;
@property double skew; // how far right of the Accessibility rectangle, `bounds`, the WindowServer's lies
@property BOOL timeout;
@property BOOL silent,garbled; // readback cases: no result at all, and one that breaks the result contract
@property NSString *outcome;
@property NSUInteger setters;
@property NSUInteger performed;
@end
@implementation Driver
- (NSDictionary *)perform:(NSDictionary *)e{
    BOOL setter=[e[@"requested"]isKindOfClass:NSDictionary.class];if(setter)self.setters++;self.performed++;
    if(self.silent)return nil;
    if(self.garbled)return @{@"outcome":@"observed",@"ax_error":@0,@"mutation_attempted":@YES,@"observed":@YES,@"requested":@{@"width":@1,@"height":@1},@"actual_ax":rect(0,0,5,5),@"actual_cg":rect(90,90,5,5)};
    NSDictionary *requested=setter?e[@"requested"]:@{@"width":@0,@"height":@0};
    if(setter&&!self.timeout&&![self.outcome isEqual:@"rejected"]){CGSize size=CGSizeMake([requested[@"width"]doubleValue],[requested[@"height"]doubleValue]);if([self.outcome isEqual:@"clamped"])size.width=210;self.bounds=CGRectMake(self.bounds.origin.x,self.bounds.origin.y,size.width,size.height);}
    BOOL observed=!(setter&&self.timeout);NSDictionary *r=observed?rect(self.bounds.origin.x+self.skew,self.bounds.origin.y,self.bounds.size.width,self.bounds.size.height):rect(0,0,0,0),*ax=observed&&r?rect(self.bounds.origin.x,self.bounds.origin.y,self.bounds.size.width,self.bounds.size.height):r;
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
// Readback mode, what every normal run sets: no result invalidates a capture, an effect nobody
// answers is discharged by the watchdog, and a result the controller refuses leaves no obligation. After every step the window is
// settled and takes input.
static void readback(void){
    DriftDesktop *c=driftwm_desktop_create();Driver *driver=[Driver new];driver.bounds=CGRectMake(10,20,200,150);
    NSMutableArray *workers=[NSMutableArray array],*mains=[NSMutableArray array],*delays=[NSMutableArray array],*ops=[NSMutableArray array];__block BOOL deaf=NO;
    DWResizeCoordinator *co=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *command){[ops addObject:command[@"op"]];if(deaf&&[command[@"op"]isEqual:@"native_resize_result"])return nil;return call(c,command);}driver:driver worker:^(DWJob job){[workers addObject:[job copy]];}main:^(DWJob job){[mains addObject:[job copy]];}];
    co.enabled=YES;co.timeout=3;co.delay=^(NSTimeInterval seconds,DWJob job){check(seconds==3,@"the watchdog waits the timeout");[delays addObject:[job copy]];};
    void (^expire)(void)=^{NSArray *due=[delays copy];[delays removeAllObjects];for(DWJob job in due)job();};
    void (^usable)(NSString *)=^(NSString *when){NSDictionary *source=snap(c)[@"windows"][0][@"source"];
        check([source[@"observation_known"]boolValue],[@"readback: settled " stringByAppendingString:when]);
        check(call(c,@{@"op":@"input",@"output":@1,@"screen":@{@"x":@120,@"y":@120},@"identity":identity()})!=nil,[@"readback: input taken " stringByAppendingString:when]);};
    NSDictionary *(^resize)(int)=^NSDictionary *(int width){NSDictionary *reply=call(c,@{@"op":@"ipc",@"output":@1,@"request":@{@"Resize":@{@"window":@1,@"to":@[@(width),@200]}}});check([reply[@"effect"]isKindOfClass:NSDictionary.class],@"readback: a size request begins a transaction");[co consume:@{@"effect":reply[@"effect"]}];return reply;};
    check(call(c,@{@"op":@"native_resize_capability",@"enabled":@YES})!=nil,@"capability");
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
static BOOL number(id x) { return [x isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)x)!=CFBooleanGetTypeID() && isfinite([x doubleValue]); }
static NSString *text(CGRect r) { return [NSString stringWithFormat:@"{%g,%g,%g,%g}",r.origin.x,r.origin.y,r.size.width,r.size.height]; }
// Standalone ScreenCaptureKit frame metadata oracle retained from the retired capture gate.
// This test-only validator establishes no live resize or capture authority.
static NSDictionary *refused(NSString *__autoreleasing *why,NSString *reason) { if(why)*why=reason;return nil; }
static NSDictionary *captureDescription(CMSampleBufferRef sample,uint64_t cutoff,CGRect nativeRect,NSString *__autoreleasing *why) {
    CGSize extent=nativeRect.size;
    if(!sample||!CMSampleBufferIsValid(sample))return refused(why,@"the sample is not valid");
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);if(!pixels)return refused(why,@"the sample has no pixel buffer");
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(!attachments||CFArrayGetCount(attachments)!=1)return refused(why,[NSString stringWithFormat:@"the sample has %ld frame descriptions, not one",attachments?(long)CFArrayGetCount(attachments):0L]);
    id value=(__bridge id)CFArrayGetValueAtIndex(attachments,0);if(![value isKindOfClass:NSDictionary.class])return refused(why,@"the frame description is not a dictionary");
    NSDictionary *m=value;id status=m[SCStreamFrameInfoStatus],time=m[SCStreamFrameInfoDisplayTime],scale=m[SCStreamFrameInfoScaleFactor],content=m[SCStreamFrameInfoContentScale];
    if(!number(status)||[status doubleValue]!=SCFrameStatusComplete||!number(time)||[time doubleValue]<=0||floor([time doubleValue])!=[time doubleValue]||[time doubleValue]>=18446744073709551616.0||[time unsignedLongLongValue]<=cutoff||!number(scale)||!number(content)||[scale doubleValue]<=0||[content doubleValue]<=0)
        return refused(why,[NSString stringWithFormat:@"frame status %@ (a complete frame is %ld), display time %@ against cutoff %llu, scale factor %@, content scale %@",status?:@"missing",(long)SCFrameStatusComplete,time?:@"missing",cutoff,scale?:@"missing",content?:@"missing"]);
    id screen=m[SCStreamFrameInfoScreenRect];CGRect screenRect=CGRectZero;
    if(![screen isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)screen,&screenRect))return refused(why,@"the frame names no screen rectangle");
    if(!CGRectEqualToRect(screenRect,nativeRect))return refused(why,[NSString stringWithFormat:@"the frame's screen rectangle %@ is not the window extent %@",text(screenRect),text(nativeRect)]);
    id r=m[SCStreamFrameInfoContentRect];CGRect rect=CGRectZero;
    if(![r isKindOfClass:NSDictionary.class]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r,&rect))return refused(why,@"the frame names no content rectangle");
    if(!isfinite(extent.width)||!isfinite(extent.height)||extent.width<=0||extent.height<=0||!isfinite(rect.origin.x)||!isfinite(rect.origin.y)||!isfinite(rect.size.width)||!isfinite(rect.size.height)||rect.size.width<=0||rect.size.height<=0)
        return refused(why,[NSString stringWithFormat:@"content rectangle %@ or window extent %@ is empty or not finite",text(rect),text(nativeRect)]);
    if(fabs(rect.size.width/[content doubleValue]-extent.width)>1||fabs(rect.size.height/[content doubleValue]-extent.height)>1)
        return refused(why,[NSString stringWithFormat:@"content %gx%g at content scale %@ is not the window extent's %gx%g within a point",rect.size.width,rect.size.height,content,extent.width,extent.height]);
    CGFloat s=[scale doubleValue];CGRect crop=CGRectMake(rect.origin.x*s,rect.origin.y*s,rect.size.width*s,rect.size.height*s);
    size_t width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels);
    if(!width||!height||!isfinite(CGRectGetMaxX(crop))||!isfinite(CGRectGetMaxY(crop))||crop.origin.x<0||crop.origin.y<0||CGRectGetMaxX(crop)>width||CGRectGetMaxY(crop)>height)
        return refused(why,[NSString stringWithFormat:@"content rectangle %@ at scale factor %@ lies outside the %zux%zu buffer",text(rect),scale,width,height]);
    return @{ @"buffer":@{@"width":@(width),@"height":@(height)},@"content_rect":@{@"origin":@{@"x":@(crop.origin.x),@"y":@(crop.origin.y)},@"size":@{@"width":@(crop.size.width),@"height":@(crop.size.height)}} };
}
static NSDictionary *captureMetadata(CMSampleBufferRef sample,uint64_t cutoff,CGRect nativeRect) { return captureDescription(sample,cutoff,nativeRect,NULL); }
int main(void){@autoreleasepool{
    CGRect native=CGRectMake(10,20,200,150);CMSampleBufferRef s=sample(native,@{});NSDictionary *m=captureMetadata(s,100,native);check([m[@"buffer"][@"width"]intValue]==480&&[m[@"content_rect"][@"origin"][@"x"]intValue]==20,@"actual padded crop");CFRelease(s);
    NSArray *invalid=@[@{SCStreamFrameInfoDisplayTime:NSNull.null},@{SCStreamFrameInfoDisplayTime:@100},@{SCStreamFrameInfoDisplayTime:@(-1)},@{SCStreamFrameInfoDisplayTime:@100.5},@{SCStreamFrameInfoDisplayTime:@1e30},@{SCStreamFrameInfoStatus:NSNull.null},@{SCStreamFrameInfoStatus:@.5},@{SCStreamFrameInfoContentScale:@0},@{SCStreamFrameInfoScreenRect:NSNull.null},@{SCStreamFrameInfoContentRect:CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(100,100,200,150)))}];
    for(NSDictionary *override in invalid){s=sample(native,override);NSString *why=nil;check(captureMetadata(s,100,native)==nil,@"invalid metadata rejected");check(captureDescription(s,100,native,&why)==nil&&why.length,@"and every rejection says why");CFRelease(s);}
    readback();
    puts("PASS: native readback coordinator + Rust C ABI; standalone synthetic CV/CMSampleBuffer metadata oracle; no native app/window/AX/capture started");return 0;
}}
