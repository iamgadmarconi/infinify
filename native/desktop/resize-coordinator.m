// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-coordinator.h"
#import "resize-capture-policy.h"
#include <mach/mach_time.h>
static CGRect rjson(NSDictionary *r){return CGRectMake([r[@"origin"][@"x"]doubleValue],[r[@"origin"][@"y"]doubleValue],[r[@"size"][@"width"]doubleValue],[r[@"size"][@"height"]doubleValue]);}
static NSString *rtext(CGRect r){return [NSString stringWithFormat:@"{%g,%g,%g,%g}",r.origin.x,r.origin.y,r.size.width,r.size.height];}
// Host-clock ticks, the unit of a frame's display time and of the production clock, as milliseconds.
static double hostMilliseconds(uint64_t ticks){static mach_timebase_info_data_t base;static dispatch_once_t once;dispatch_once(&once,^{mach_timebase_info(&base);});return base.denom?(double)ticks*base.numer/base.denom/1e6:0;}
static BOOL withinOnePoint(CGRect a,CGRect b){return fabs(a.origin.x-b.origin.x)<=1&&fabs(a.origin.y-b.origin.y)<=1&&fabs(a.size.width-b.size.width)<=1&&fabs(a.size.height-b.size.height)<=1;}
NSArray<NSDictionary *> *DWResizeHandles(CGRect full,CGRect clip){
    NSArray *edges=@[@"top_left",@"top",@"top_right",@"right",@"bottom_right",@"bottom",@"bottom_left",@"left"];
    CGFloat x[]={CGRectGetMinX(full),CGRectGetMidX(full),CGRectGetMaxX(full),CGRectGetMaxX(full),CGRectGetMaxX(full),CGRectGetMidX(full),CGRectGetMinX(full),CGRectGetMinX(full)};
    CGFloat y[]={CGRectGetMinY(full),CGRectGetMinY(full),CGRectGetMinY(full),CGRectGetMidY(full),CGRectGetMaxY(full),CGRectGetMaxY(full),CGRectGetMaxY(full),CGRectGetMidY(full)};
    NSMutableArray *out=[NSMutableArray array];for(int i=0;i<8;i++)if(x[i]>=CGRectGetMinX(clip)&&x[i]<=CGRectGetMaxX(clip)&&y[i]>=CGRectGetMinY(clip)&&y[i]<=CGRectGetMaxY(clip))[out addObject:@{@"edge":edges[i],@"x":@(x[i]),@"y":@(y[i])}];return out;
}
@interface DWResizeCoordinator ()
@property (copy) DWCommand command;
@property id<DWResizeDriver> driver;
@property (copy) uint64_t (^clock)(void);
@property (copy) DWSchedule worker,main;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *pending;
@property NSMutableDictionary<NSNumber *,NSMutableDictionary *> *bindings;
@property BOOL stopping;
@property NSMutableSet<NSNumber *> *seen;
@property (readwrite) NSString *failure;
@property (readwrite) NSNumber *installingWindow;
@property id orphan;
// Effects whose obligation has ended, by id. The one state of the coordinator the worker reads, so it is read and written locked.
@property NSMutableSet<NSNumber *> *discharged;
@end
@implementation DWResizeCoordinator
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWResizeDriver>)driver clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[command copy];_driver=driver;_clock=[clock copy];_worker=[worker copy];_main=[main copy];_pending=[NSMutableDictionary dictionary];_seen=[NSMutableSet set];_bindings=[NSMutableDictionary dictionary];_discharged=[NSMutableSet set];_acknowledges=YES;
        _delay=^(NSTimeInterval seconds,DWJob job){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),job);};}return self;
}
- (NSUInteger)obligations{return self.pending.count;}
- (NSDictionary *)source:(NSNumber *)window {for(NSDictionary *w in self.command(@{@"op":@"snapshot"})[@"windows"])if([w[@"window"]isEqual:window]&&[w[@"source"]isKindOfClass:NSDictionary.class])return w[@"source"];return nil;}
- (NSDictionary *)captureState:(NSNumber *)window { return [self source:window]; }
// Is the window's root extent the geometry the controller observed? The extent is the WindowServer's rectangle. So is the observation
// of a window at rest, and the two are then compared exactly: a native move of one point is still a move, and is mapped again. The
// observation a resize transaction makes is the Accessibility rectangle, which the controller accepts when it agrees with the
// WindowServer's within one point on each coordinate (NATIVE_RESIZE.md): while that transaction is unresolved nothing maps the window
// again, so the same one point is the same geometry here, or a window whose two rectangles differ by a fraction would show no picture
// for as long as it is being resized.
- (BOOL)extent:(NSDictionary *)extent matches:(NSDictionary *)source window:(NSNumber *)window {
    if(!extent)return NO;CGRect native=rjson(extent),observed=rjson(source[@"observed_rect"]);
    return CGRectEqualToRect(native,observed)||(withinOnePoint(native,observed)&&![self canRemove:window]);
}
// Why the capture of a window is not acknowledged: a short reason, and what was compared. Kept until a capture is, or until the
// controller's observation moves on: a refusal says nothing about a revision no frame has been judged against.
- (void)refuse:(NSMutableDictionary *)binding reason:(NSString *)reason detail:(NSString *)detail { binding[@"refusal"]=reason;binding[@"refusal_detail"]=detail?:@""; }
- (NSString *)refusal:(NSNumber *)window detail:(NSString *__autoreleasing *)detail {
    NSDictionary *b=self.bindings[window];NSString *reason=b[@"refusal"];if(detail)*detail=reason?b[@"refusal_detail"]:nil;return reason;
}
- (NSString *)familyDetail:(NSDictionary *)identity { return [self.driver respondsToSelector:@selector(rootExtentRefusal:)]?[self.driver rootExtentRefusal:identity]:@"the window is not alone in its native family, or its family could not be read"; }
- (NSString *)geometryDetail:(NSDictionary *)extent source:(NSDictionary *)source { return [NSString stringWithFormat:@"window extent %@, observed %@",rtext(rjson(extent)),rtext(rjson(source[@"observed_rect"]))]; }
- (void)sync {
    for(NSNumber *w in self.bindings){NSMutableDictionary *b=self.bindings[w];NSDictionary *s=[self source:w];if(!s)continue;
        if(![b[@"revision"]isEqual:s[@"observation_revision"]]){b[@"revision"]=s[@"observation_revision"];b[@"cutoff"]=@(self.clock());[b removeObjectsForKeys:@[@"refusal",@"refusal_detail"]];}
    }
    if(self.changed)self.changed();
}
- (void)consume:(NSDictionary *)reply {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    id e=reply[@"effect"];
    if([e isKindOfClass:NSDictionary.class]&&([e[@"op"]isEqual:@"observe_resize_source"]||[e[@"op"]isEqual:@"resize_native_window"])){
        id transaction=self.command(@{@"op":@"snapshot"})[@"native_resize"];
        if(![transaction isKindOfClass:NSDictionary.class]||![transaction[@"pending_effect"]isEqual:e])return;
        NSNumber *key=e[@"effect_id"];if([self.seen containsObject:key])return;
        [self.seen addObject:key];
        // Registration precedes dispatch; cancellation can never retract this obligation.
        self.pending[key]=e;
        // An effect answered for while it waited for the worker (the watchdog's answer) is not performed: its setter would ask a size
        // of a window whose transaction is over.
        self.worker(^{if([self discharged:key])return;NSDictionary *result=[self.driver perform:e];self.main(^{[self finish:e result:result];});});
        // Readback mode: the watchdog. The real result, should it still come, finds the obligation gone and is dropped.
        if(!self.acknowledges&&self.timeout>0)self.delay(self.timeout,^{[self finish:e result:[self unanswered:e]];});
    }
    [self sync];
}
// What the adapter reports for a call that never returned: nothing observed, and a setter that may still run.
- (NSDictionary *)unanswered:(NSDictionary *)e {
    BOOL setter=[e[@"requested"]isKindOfClass:NSDictionary.class];NSDictionary *none=@{@"origin":@{@"x":@0,@"y":@0},@"size":@{@"width":@0,@"height":@0}};
    return @{@"outcome":@"timed_out",@"ax_error":@(-25204),@"mutation_attempted":setter?@YES:@NO,@"observed":@NO,@"requested":setter?e[@"requested"]:@{@"width":@0,@"height":@0},@"actual_ax":none,@"actual_cg":none};
}
- (BOOL)discharged:(NSNumber *)key { @synchronized(self.discharged){return [self.discharged containsObject:key];} }
- (void)discharge:(NSNumber *)key { [self.pending removeObjectForKey:key];@synchronized(self.discharged){[self.discharged addObject:key];} }
- (NSDictionary *)report:(NSDictionary *)e result:(NSDictionary *)result { return self.command(@{@"op":@"native_resize_result",@"transaction":e[@"transaction"],@"effect_id":e[@"effect_id"],@"identity":e[@"identity"],@"generation":e[@"generation"],@"result":result}); }
// The one completion of an effect, on the main thread: the driver's result, or in readback mode the watchdog's.
- (void)finish:(NSDictionary *)e result:(NSDictionary *)result {
    NSAssert(NSThread.isMainThread,@"Rust controller is main-only");
    NSNumber *key=e[@"effect_id"];if(![self.pending[key]isEqual:e])return;
    if(!result&&!self.acknowledges)result=[self unanswered:e];
    if(!result){self.failure=@"Adapter returned no result; resize obligation remains pending";if(self.changed)self.changed();return;}
    NSDictionary *reply=[self report:e result:result];
    if(!reply&&!self.acknowledges){
        // Readback mode: no obligation outlives its effect. A result the controller would not take is replaced once by the unanswered
        // one, which is valid for any effect still pending; refused too, the transaction is no longer this effect's, and it is let go.
        result=[self unanswered:e];reply=[self report:e result:result];
        if(!reply){[self discharge:key];self.failure=@"The size request ended without a result the controller accepted";[self sync];return;}
    }
    if(!reply){self.failure=@"Adapter result rejected; resize obligation remains pending";if(self.changed)self.changed();return;}
    // A failure is said of the effect it happened to, and ends with the next one the controller takes.
    [self discharge:key];self.failure=nil;
    if(self.acknowledges&&[result[@"observed"]boolValue]){
        // Every accepted native observation establishes a main-thread cutoff,
        // including unchanged-size final reads and native-origin changes.
        [self invalidate:e[@"window"]];
        NSMutableDictionary *binding=self.bindings[e[@"window"]];if(binding)binding[@"cutoff"]=@(self.clock());
    }
    [self consume:reply];
}
- (NSNumber *)busyWindow { return self.pending.allValues.firstObject[@"window"]; }
- (void)reap {
    if(self.acknowledges||self.pending.count||[self canRemove:nil]){self.orphan=nil;return;}
    id t=self.command(@{@"op":@"snapshot"})[@"native_resize"],e=[t isKindOfClass:NSDictionary.class]?t[@"pending_effect"]:nil;id mark=[e isKindOfClass:NSDictionary.class]?e:t;
    if(![self.orphan isEqual:mark]){self.orphan=mark;return;}
    self.orphan=nil;
    if([e isKindOfClass:NSDictionary.class]){[self.seen addObject:e[@"effect_id"]];self.pending[e[@"effect_id"]]=e;[self finish:e result:[self unanswered:e]];}
    else [self cancel];
}
- (NSDictionary *)request:(NSDictionary *)c {
    if(!self.enabled||self.stopping)return nil;
    if([c[@"op"]isEqual:@"begin_native_resize"]){NSDictionary *s=[self source:c[@"window"]];NSDictionary *extent=s?[self.driver rootExtent:s[@"identity"]]:nil;
        if(!extent||!CGRectEqualToRect(rjson(extent),rjson(s[@"observed_rect"])))return nil;
    }
    NSDictionary *reply=self.command(c);[self consume:reply];return reply;
}
- (void)cancel {
    id t=self.command(@{@"op":@"snapshot"})[@"native_resize"];if(![t isKindOfClass:NSDictionary.class])return;
    [self consume:self.command(@{@"op":@"cancel_native_resize",@"transaction":t[@"transaction"]})];
}
- (void)shutdown {self.stopping=YES;[self cancel];}
- (BOOL)canRemove:(NSNumber *)window {
    id t=self.command(@{@"op":@"snapshot"})[@"native_resize"];if(![t isKindOfClass:NSDictionary.class]||(window&&![t[@"window"]isEqual:window]))return YES;
    return t[@"pending_effect"]==NSNull.null&&![t[@"uncertain_mutation"]boolValue]&&([t[@"phase"]isEqual:@"complete"]||[t[@"phase"]isEqual:@"failed"]);
}
- (void)invalidate:(NSNumber *)window {
    NSDictionary *s=[self source:window];if(!s)return;
    NSMutableDictionary *binding=self.bindings[window];if(binding)binding[@"loss_reason"]=@"explicit";
    [self consume:self.command(@{@"op":@"invalidate_native_capture",@"window":window,@"identity":s[@"identity"],@"generation":s[@"generation"]})];
}
- (BOOL)validate:(NSNumber *)window {
    NSMutableDictionary *b=self.bindings[window];NSDictionary *s=[self source:window];
    if(!b||!s||![b[@"identity"]isEqual:s[@"identity"]]||![b[@"generation"]isEqual:s[@"generation"]])return NO;
    NSDictionary *extent=[self.driver rootExtent:s[@"identity"]];
    BOOL matches=[self extent:extent matches:s window:window];if(matches){b[@"native_state"]=@"valid";return YES;}
    NSString *reason=extent?@"geometry":@"family";BOOL transition=![b[@"native_state"]isEqual:reason]||![b[@"loss_reason"]isEqual:reason];b[@"native_state"]=reason;
    if(transition){[self invalidate:window];b[@"loss_reason"]=reason;if(!extent)[self cancel];}
    if(extent&&[self canRemove:window]){self.command(@{@"op":@"observe",@"window":window,@"identity":s[@"identity"],@"source_rect":extent,@"buffer":s[@"buffer"]});[self sync];}
    // After the invalidation and the new observation, which each begin a revision nothing has been refused for. A family is said only
    // when it is news: asking why costs a second family query.
    if(extent)[self refuse:b reason:@"geometry" detail:[[self geometryDetail:extent source:s]stringByAppendingString:[self canRemove:window]?@"; mapped again, waiting for a frame of it":@""]];
    else if(![b[@"refusal"]isEqual:@"family"])[self refuse:b reason:@"family" detail:[self familyDetail:s[@"identity"]]];
    return NO;
}
- (void)observeBindings {for(NSNumber *window in self.bindings.allKeys)[self validate:window];}
- (void)bind:(NSNumber *)window stream:(id)stream {
    NSDictionary *s=[self source:window];if(!s)return;
    self.bindings[window]=[@{@"stream":stream,@"identity":s[@"identity"],@"generation":s[@"generation"],@"revision":s[@"observation_revision"],@"cutoff":@(self.clock())}mutableCopy];
    [self invalidate:window];
}
- (BOOL)accept:(CMSampleBufferRef)sample window:(NSNumber *)window stream:(id)stream install:(BOOL (^)(CMSampleBufferRef))install {
    NSAssert(NSThread.isMainThread,@"Capture acceptance is main-only");
    NSMutableDictionary *b=self.bindings[window];NSDictionary *s=[self source:window];
    if(!b||b[@"stream"]!=stream||!s||![b[@"identity"]isEqual:s[@"identity"]]||![b[@"generation"]isEqual:s[@"generation"]])return NO;
    [self sync];NSNumber *timestamp=DWResizeCaptureTimestamp(sample);
    uint64_t cutoff=MAX([b[@"cutoff"]unsignedLongLongValue],[b[@"last_time"]unsignedLongLongValue]);
    if(timestamp&&timestamp.unsignedLongLongValue<=cutoff){[self refuse:b reason:@"stale frame" detail:[NSString stringWithFormat:@"the last frame offered was displayed %.1f ms before the cutoff (the last observation, or the last frame shown)",hostMilliseconds(cutoff-timestamp.unsignedLongLongValue)]];return NO;}
    NSDictionary *extent=[self.driver rootExtent:s[@"identity"]];BOOL matches=[self extent:extent matches:s window:window];
    NSString *nativeState=!extent?@"family":(matches?@"valid":@"geometry");BOOL nativeTransition=![b[@"native_state"]isEqual:nativeState];b[@"native_state"]=nativeState;
    if(extent&&!CGRectEqualToRect(rjson(extent),rjson(s[@"observed_rect"]))&&[self canRemove:window]){
        // Idle external changes update native mapping, never committed world geometry.
        [self invalidate:window];
        self.command(@{@"op":@"observe",@"window":window,@"identity":s[@"identity"],@"source_rect":extent,@"buffer":s[@"buffer"]});
        [self sync];[self refuse:b reason:@"geometry" detail:[[self geometryDetail:extent source:s]stringByAppendingString:@"; mapped again, waiting for a frame of it"]];return NO; // Require a subsequent post-observation frame.
    }
    NSString *why=nil;NSDictionary *metadata=matches?DWResizeCaptureDescription(sample,cutoff,rjson(extent),&why):nil;
    if(!metadata){NSString *reason=!extent?@"family":(!matches?@"geometry":@"metadata");if(nativeTransition||![b[@"loss_reason"]isEqual:reason]){[self invalidate:window];b[@"loss_reason"]=reason;if(!extent)[self cancel];}
        if(extent||![b[@"refusal"]isEqual:@"family"])[self refuse:b reason:reason detail:!extent?[self familyDetail:s[@"identity"]]:!matches?[self geometryDetail:extent source:s]:why];return NO;}
    NSMutableDictionary *ack=[metadata mutableCopy];[ack addEntriesFromDictionary:@{@"op":@"native_resize_capture_ready",@"window":window,@"identity":b[@"identity"],@"generation":b[@"generation"],@"observation_revision":b[@"revision"]}];
    if(!self.command(ack)){[self refuse:b reason:@"refused" detail:@"the controller did not take the acknowledgement: a native resize of the window is unresolved, or its observation moved on"];return NO;}
    NSDictionary *fresh=[self source:window];if(![fresh[@"identity"]isEqual:b[@"identity"]]||![fresh[@"generation"]isEqual:b[@"generation"]]||![fresh[@"capture_revision"]isEqual:b[@"revision"]])return NO;
    // The retained sample whose metadata was acknowledged is the sample installed.
    CFRetain(sample);self.installingWindow=window;if(self.changed)self.changed();
    fresh=[self source:window];BOOL valid=[fresh[@"identity"]isEqual:b[@"identity"]]&&[fresh[@"generation"]isEqual:b[@"generation"]]&&[fresh[@"capture_revision"]isEqual:ack[@"observation_revision"]]&&self.bindings[window]==b&&b[@"stream"]==stream;
    BOOL installed=valid&&install(sample);self.installingWindow=nil;CFRelease(sample);
    fresh=[self source:window];installed=installed&&[fresh[@"capture_revision"]isEqual:ack[@"observation_revision"]]&&[fresh[@"generation"]isEqual:b[@"generation"]];
    if(!installed){[self invalidate:window];[self refuse:b reason:@"not installed" detail:@"the acknowledged frame could not be shown: its display layer was not ready, or the capture was invalidated meanwhile"];return NO;}b[@"last_time"]=timestamp;[b removeObjectsForKeys:@[@"loss_reason",@"refusal",@"refusal_detail"]];return YES;
}
@end
