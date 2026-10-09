// SPDX-License-Identifier: GPL-3.0-or-later
#import "resize-coordinator.h"
#import "resize-capture-policy.h"
static CGRect rjson(NSDictionary *r){return CGRectMake([r[@"origin"][@"x"]doubleValue],[r[@"origin"][@"y"]doubleValue],[r[@"size"][@"width"]doubleValue],[r[@"size"][@"height"]doubleValue]);}
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
@end
@implementation DWResizeCoordinator
- (instancetype)initWithCommand:(DWCommand)command driver:(id<DWResizeDriver>)driver clock:(uint64_t (^)(void))clock worker:(DWSchedule)worker main:(DWSchedule)main {
    if((self=[super init])){_command=[command copy];_driver=driver;_clock=[clock copy];_worker=[worker copy];_main=[main copy];_pending=[NSMutableDictionary dictionary];_seen=[NSMutableSet set];_bindings=[NSMutableDictionary dictionary];}return self;
}
- (NSUInteger)obligations{return self.pending.count;}
- (NSDictionary *)source:(NSNumber *)window {for(NSDictionary *w in self.command(@{@"op":@"snapshot"})[@"windows"])if([w[@"window"]isEqual:window]&&[w[@"source"]isKindOfClass:NSDictionary.class])return w[@"source"];return nil;}
- (NSDictionary *)captureState:(NSNumber *)window { return [self source:window]; }
- (void)sync {
    for(NSNumber *w in self.bindings){NSMutableDictionary *b=self.bindings[w];NSDictionary *s=[self source:w];if(!s)continue;
        if(![b[@"revision"]isEqual:s[@"observation_revision"]]){b[@"revision"]=s[@"observation_revision"];b[@"cutoff"]=@(self.clock());}
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
        self.worker(^{NSDictionary *result=[self.driver perform:e];self.main(^{
            if(![self.pending[key]isEqual:e])return;
            if(!result){self.failure=@"Adapter returned no result; resize obligation remains pending";if(self.changed)self.changed();return;}
            NSDictionary *reply=self.command(@{@"op":@"native_resize_result",@"transaction":e[@"transaction"],@"effect_id":key,@"identity":e[@"identity"],@"generation":e[@"generation"],@"result":result});
            if(!reply){self.failure=@"Adapter result rejected; resize obligation remains pending";if(self.changed)self.changed();return;}
            [self.pending removeObjectForKey:key];
            if([result[@"observed"]boolValue]){
                // Every accepted native observation establishes a main-thread cutoff,
                // including unchanged-size final reads and native-origin changes.
                [self invalidate:e[@"window"]];
                NSMutableDictionary *binding=self.bindings[e[@"window"]];if(binding)binding[@"cutoff"]=@(self.clock());
            }
            [self consume:reply];
        });});
    }
    [self sync];
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
    if(timestamp&&timestamp.unsignedLongLongValue<=cutoff)return NO;
    NSDictionary *extent=[self.driver rootExtent:s[@"identity"]];
    if(extent&&!CGRectEqualToRect(rjson(extent),rjson(s[@"observed_rect"]))&&[self canRemove:window]){
        // Idle external changes update native mapping, never committed world geometry.
        [self invalidate:window];
        self.command(@{@"op":@"observe",@"window":window,@"identity":s[@"identity"],@"source_rect":extent,@"buffer":s[@"buffer"]});
        [self sync];return NO; // Require a subsequent post-observation frame.
    }
    NSDictionary *metadata=extent&&CGRectEqualToRect(rjson(extent),rjson(s[@"observed_rect"]))?DWResizeCaptureMetadata(sample,cutoff,rjson(extent)):nil;
    if(!metadata){NSString *reason=!extent?@"family":(!CGRectEqualToRect(rjson(extent),rjson(s[@"observed_rect"]))?@"geometry":@"metadata");if(![b[@"loss_reason"]isEqual:reason]){[self invalidate:window];b[@"loss_reason"]=reason;if(!extent)[self cancel];}return NO;}
    NSMutableDictionary *ack=[metadata mutableCopy];[ack addEntriesFromDictionary:@{@"op":@"native_resize_capture_ready",@"window":window,@"identity":b[@"identity"],@"generation":b[@"generation"],@"observation_revision":b[@"revision"]}];
    if(!self.command(ack))return NO;
    NSDictionary *fresh=[self source:window];if(![fresh[@"identity"]isEqual:b[@"identity"]]||![fresh[@"generation"]isEqual:b[@"generation"]]||![fresh[@"capture_revision"]isEqual:b[@"revision"]])return NO;
    // The retained sample whose metadata was acknowledged is the sample installed.
    CFRetain(sample);self.installingWindow=window;if(self.changed)self.changed();
    fresh=[self source:window];BOOL valid=[fresh[@"identity"]isEqual:b[@"identity"]]&&[fresh[@"generation"]isEqual:b[@"generation"]]&&[fresh[@"capture_revision"]isEqual:ack[@"observation_revision"]]&&self.bindings[window]==b&&b[@"stream"]==stream;
    BOOL installed=valid&&install(sample);self.installingWindow=nil;CFRelease(sample);
    fresh=[self source:window];installed=installed&&[fresh[@"capture_revision"]isEqual:ack[@"observation_revision"]]&&[fresh[@"generation"]isEqual:b[@"generation"]];
    if(!installed){[self invalidate:window];return NO;}b[@"last_time"]=timestamp;[b removeObjectForKey:@"loss_reason"];return YES;
}
@end
