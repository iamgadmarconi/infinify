// SPDX-License-Identifier: GPL-3.0-or-later
// DriftWM (malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d) ticks its
// animations from the output's own frame loop (src/backend/udev.rs: render_if_needed,
// tick_all_animations), so its motion runs at the monitor's refresh rate. This is that
// cadence for the macOS shell. New implementation over the macOS display links.
#import "frame-driver.h"
#import "compositor.h"
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
@interface DWFrameDriver () <CAMetalDisplayLinkDelegate>
- (void)hardwareOutputAt:(double)target interval:(double)interval;
@end
// Core Video is a scoped comparison against the main-run-loop clock, not a
// production fallback to a deprecated API. The output block is owned by the
// link and holds only a weak driver; no unretained callback context can outlive
// teardown. Scene work and layer ownership remain on main.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CVDisplayLinkRef DWCreateHardwareClock(CGDirectDisplayID display,CVDisplayLinkOutputHandler handler) {
    CVDisplayLinkRef link=NULL;
    if(CVDisplayLinkCreateWithCGDisplay(display,&link)!=kCVReturnSuccess||!link){if(link)CVDisplayLinkRelease(link);return NULL;}
    if(CVDisplayLinkSetOutputHandler(link,handler)!=kCVReturnSuccess||CVDisplayLinkStart(link)!=kCVReturnSuccess){CVDisplayLinkRelease(link);return NULL;}
    return link;
}
static void DWStopHardwareClock(CVDisplayLinkRef link) {if(link){CVDisplayLinkStop(link);CVDisplayLinkRelease(link);}}
#pragma clang diagnostic pop
@implementation DWFrameDriver {
    void (^_frame)(DWFrameDriver *);
    CADisplayLink *_link;
    CAMetalDisplayLink *_metalLink;
    IFCompositorLayer *_metalLayer;
    id _activity;
    CVDisplayLinkRef _hardwareLink;
    os_unfair_lock _hardwareLock;
    BOOL _hardwarePending,_hardwareCancelled,_measureHardware;
    double _hardwareTarget,_hardwareInterval,_hardwareArrived,_hardwareQueuedAt,_hardwareDeliveredTarget;
    double _hardwareStatsSince,_hardwarePrevious,_hardwareGapWorst,_hardwareQueueWorst,_hardwareLatestWorst;
    NSUInteger _hardwareCallbacks,_hardwareDelivered,_hardwareCoalesced,_hardwareStale,_hardwareInvalid;
    double _lastMetal,_previousMetalTarget;
    double _statsSince,_statsPrevious,_statsGap,_statsWorst;
    NSUInteger _statsTicks;
    NSUInteger _metalOffers,_fallbackTicks,_deadlineLate,_unusedOffers;
    double _deadlineMargin,_presentationBudget;
}
+ (instancetype)driverOn:(NSArray<NSScreen *> *)screens frame:(void (^)(DWFrameDriver *))frame {
    return [self driverOn:screens layer:nil frame:frame];
}
+ (instancetype)driverOn:(NSArray<NSScreen *> *)screens layer:(IFCompositorLayer *)layer frame:(void (^)(DWFrameDriver *))frame {
    return [self driverOn:screens layer:layer hardwareClock:NO frame:frame];
}
+ (instancetype)driverOn:(NSArray<NSScreen *> *)screens layer:(IFCompositorLayer *)layer hardwareClock:(BOOL)hardwareClock frame:(void (^)(DWFrameDriver *))frame {
    NSScreen *fastest=nil;for(NSScreen *screen in screens)if(!fastest||screen.maximumFramesPerSecond>fastest.maximumFramesPerSecond)fastest=screen;
    if(!fastest)fastest=NSScreen.mainScreen?:NSScreen.screens.firstObject;if(!fastest)return nil;
    DWFrameDriver *driver=[self new];driver->_frame=[frame copy];driver->_lastFrame=CACurrentMediaTime();driver->_framesPerSecond=fastest.maximumFramesPerSecond;
    // The link retains its target until -invalidate.
    CADisplayLink *link=[fastest displayLinkWithTarget:driver selector:@selector(tick:)];if(!link)return nil;
    // The accessory app can keep animating without incoming input. Declare
    // that requested frame work until this driver ends, so App Nap does not
    // defer it between events. This option allows both idle sleep and display
    // sleep; no process-wide preference or latency-critical assertion is used.
    driver->_activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Presenting Infinify canvas frames"];
    // A variable-refresh display is otherwise free to call back below its full rate.
    if(driver->_framesPerSecond>0){float rate=(float)driver->_framesPerSecond;link.preferredFrameRateRange=CAFrameRateRangeMake(rate,rate,rate);}
    driver->_link=link;[link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    if(hardwareClock){
        NSNumber *display=fastest.deviceDescription[@"NSScreenNumber"];double hostSeconds=1.0/CVGetHostClockFrequency();
        driver->_measureHardware=getenv("INFINIFY_DEBUG")!=NULL;driver->_hardwareArrived=CACurrentMediaTime();
        __weak DWFrameDriver *weak=driver;
        if(display&&isfinite(hostSeconds)&&hostSeconds>0)driver->_hardwareLink=DWCreateHardwareClock(display.unsignedIntValue,^CVReturn(CVDisplayLinkRef clock,const CVTimeStamp *now,const CVTimeStamp *output,CVOptionFlags incoming,CVOptionFlags *outgoing){
            (void)clock;(void)now;(void)incoming;*outgoing=0;
            @autoreleasepool{
                double target=(output->flags&kCVTimeStampHostTimeValid)?output->hostTime*hostSeconds:0,interval=0;
                if((output->flags&kCVTimeStampVideoRefreshPeriodValid)&&output->videoTimeScale>0)interval=(double)output->videoRefreshPeriod/output->videoTimeScale;
                if(output->flags&kCVTimeStampRateScalarValid)interval=isfinite(output->rateScalar)&&output->rateScalar>0?interval/output->rateScalar:0;
                [weak hardwareOutputAt:target interval:interval];
            }
            return kCVReturnSuccess;
        });
    }else if(layer&&layer.renderer){
        layer.displayLinkDriven=YES;
        CAMetalDisplayLink *metal=[[CAMetalDisplayLink alloc]initWithMetalLayer:layer];
        if(metal){
            driver->_metalLayer=layer;
            // Two frames allow CPU/GPU overlap without the independent acquire
            // and scene clocks retaining additional frames before presentation.
            // The measured one-frame preference did not improve this path.
            metal.preferredFrameLatency=2;
            if(driver->_framesPerSecond>0){float rate=(float)driver->_framesPerSecond;metal.preferredFrameRateRange=CAFrameRateRangeMake(rate,rate,rate);}
            metal.delegate=driver;driver->_metalLink=metal;driver->_lastMetal=CACurrentMediaTime();
            [metal addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }else layer.displayLinkDriven=NO;
    }
    return driver;
}
- (void)hardwareOutputAt:(double)target interval:(double)interval {
    double arrived=CACurrentMediaTime();os_unfair_lock_lock(&_hardwareLock);
    if(_hardwareCancelled){os_unfair_lock_unlock(&_hardwareLock);return;}
    if(_measureHardware){if(!_hardwareStatsSince)_hardwareStatsSince=arrived;if(_hardwarePrevious>0)_hardwareGapWorst=fmax(_hardwareGapWorst,arrived-_hardwarePrevious);_hardwarePrevious=arrived;_hardwareCallbacks++;}
    if(!isfinite(target)||target<=0||!isfinite(interval)||interval<=0){_hardwareInvalid++;os_unfair_lock_unlock(&_hardwareLock);return;}
    _hardwareTarget=target;_hardwareInterval=interval;_hardwareArrived=arrived;
    BOOL pending=_hardwarePending;if(pending)_hardwareCoalesced++;else {_hardwarePending=YES;_hardwareQueuedAt=arrived;}
    os_unfair_lock_unlock(&_hardwareLock);if(pending)return;
    // The block retains this driver only until the one queued tick returns.
    // Further display callbacks replace its target instead of queueing scenes.
    dispatch_async(dispatch_get_main_queue(),^{
        double began=CACurrentMediaTime();os_unfair_lock_lock(&self->_hardwareLock);
        self->_hardwarePending=NO;BOOL stopped=self->_hardwareCancelled;double time=self->_hardwareTarget,period=self->_hardwareInterval;
        if(!stopped){self->_hardwareQueueWorst=fmax(self->_hardwareQueueWorst,began-self->_hardwareQueuedAt);self->_hardwareLatestWorst=fmax(self->_hardwareLatestWorst,began-self->_hardwareArrived);}
        os_unfair_lock_unlock(&self->_hardwareLock);if(stopped||!self->_hardwareLink||!self->_frame)return;
        if(time<=self->_hardwareDeliveredTarget){os_unfair_lock_lock(&self->_hardwareLock);self->_hardwareStale++;os_unfair_lock_unlock(&self->_hardwareLock);return;}
        self->_hardwareDeliveredTarget=time;os_unfair_lock_lock(&self->_hardwareLock);self->_hardwareDelivered++;os_unfair_lock_unlock(&self->_hardwareLock);
        [self deliver:time interval:period deadline:0 layer:nil clock:"display_thread"];
    });
}
// The block may end this driver, which lets go of the link's reference to it: it is held until the callback returns.
- (void)deliver:(double)target interval:(double)interval deadline:(double)deadline layer:(IFCompositorLayer *)layer clock:(const char *)clock {
    __attribute__((objc_precise_lifetime)) DWFrameDriver *alive=self;void (^frame)(DWFrameDriver *)=_frame;
    _lastFrame=CACurrentMediaTime();_presentationTime=target;@autoreleasepool{if(frame)frame(alive);}_presentationTime=0;
    if(getenv("INFINIFY_DEBUG")){
        if(deadline>0){double submitted=layer.displaySubmissionTime;
            if(submitted>0){double margin=deadline-submitted;_deadlineMargin=fmin(_deadlineMargin,margin);_deadlineLate+=margin<0;}
            else _unusedOffers++;}
        if(!_statsSince)_statsSince=_lastFrame;
        if(_statsPrevious>0){double gap=_lastFrame-_statsPrevious;_statsGap+=gap;_statsWorst=fmax(_statsWorst,gap);}_statsPrevious=_lastFrame;_statsTicks++;
        double span=_lastFrame-_statsSince;if(span>=2){
            fprintf(stderr,"cadence: %.2fs callbacks=%.1f target_hz=%.1f callback_gap_ms=%.3f/%.3f requested_hz=%ld clock=%s activity=%d\n",span,_statsTicks/span,interval>0?1.0/interval:0,_statsTicks?_statsGap/_statsTicks*1000:0,_statsWorst*1000,(long)_framesPerSecond,clock,_activity!=nil);
            if(_hardwareLink){os_unfair_lock_lock(&_hardwareLock);double hardwareSpan=_lastFrame-_hardwareStatsSince;
                NSUInteger callbacks=_hardwareCallbacks,delivered=_hardwareDelivered,coalesced=_hardwareCoalesced,stale=_hardwareStale,invalid=_hardwareInvalid;
                double gap=_hardwareGapWorst,queue=_hardwareQueueWorst,latest=_hardwareLatestWorst;
                _hardwareStatsSince=_lastFrame;_hardwareCallbacks=_hardwareDelivered=_hardwareCoalesced=_hardwareStale=_hardwareInvalid=0;_hardwareGapWorst=_hardwareQueueWorst=_hardwareLatestWorst=0;os_unfair_lock_unlock(&_hardwareLock);
                fprintf(stderr,"display_thread: callbacks=%lu callback_hz=%.1f delivered=%lu coalesced=%lu stale=%lu invalid=%lu callback_gap_worst_ms=%.3f pending_age_worst_ms=%.3f latest_age_worst_ms=%.3f\n",(unsigned long)callbacks,hardwareSpan>0?callbacks/hardwareSpan:0,(unsigned long)delivered,(unsigned long)coalesced,(unsigned long)stale,(unsigned long)invalid,gap*1000,queue*1000,latest*1000);}
            if(_metalOffers||_fallbackTicks)fprintf(stderr,"metal_clock: offers=%lu fallback=%lu unused=%lu submission_late=%lu deadline_margin_ms=%.3f presentation_budget_ms=%.3f\n",(unsigned long)_metalOffers,(unsigned long)_fallbackTicks,(unsigned long)_unusedOffers,(unsigned long)_deadlineLate,_deadlineMargin*1000,_presentationBudget*1000);
            _statsSince=_lastFrame;_statsTicks=0;_statsGap=0;_statsWorst=0;}
        if(!_statsTicks){_metalOffers=_fallbackTicks=_deadlineLate=_unusedOffers=0;_deadlineMargin=_presentationBudget=0;}
    }
}
- (void)tick:(CADisplayLink *)link {
    if(link!=_link)return;
    if(_hardwareLink){os_unfair_lock_lock(&_hardwareLock);double last=_hardwareArrived;os_unfair_lock_unlock(&_hardwareLock);if(CACurrentMediaTime()-last<.25)return;_fallbackTicks++;}
    // Occlusion may stop drawable offers. Keep navigation advancing on the
    // display's clock without acquiring/rendering pixels for a covered layer.
    if(_metalLink&&CACurrentMediaTime()-_lastMetal<.25)return;
    if(_metalLink)_fallbackTicks++;
    [self deliver:link.targetTimestamp interval:link.targetTimestamp-link.timestamp deadline:0 layer:nil clock:_hardwareLink?"display_thread_fallback":_metalLink?"controller_fallback":"screen"];
}
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    if(link!=_metalLink||!_frame)return;
    _lastMetal=CACurrentMediaTime();double target=update.targetPresentationTimestamp;
    double interval=_previousMetalTarget>0?target-_previousMetalTarget:(_framesPerSecond>0?1.0/_framesPerSecond:0);_previousMetalTarget=target;
    BOOL measured=getenv("INFINIFY_DEBUG")!=NULL;double deadline=update.targetTimestamp;
    if(measured){double margin=deadline-_lastMetal,budget=target-_lastMetal;_metalOffers++;
        _deadlineMargin=_metalOffers==1?margin:fmin(_deadlineMargin,margin);_presentationBudget=_metalOffers==1?budget:fmin(_presentationBudget,budget);}
    IFCompositorLayer *layer=_metalLayer;
    [layer withDisplayDrawable:update.drawable presentationTime:target frame:^{[self deliver:target interval:interval deadline:deadline layer:layer clock:"metal"];}];
}
- (void)invalidate {
    CADisplayLink *link=_link;CAMetalDisplayLink *metal=_metalLink;IFCompositorLayer *layer=_metalLayer;id activity=_activity;
    os_unfair_lock_lock(&_hardwareLock);_hardwareCancelled=YES;_hardwarePending=NO;os_unfair_lock_unlock(&_hardwareLock);
    CVDisplayLinkRef hardware=_hardwareLink;_hardwareLink=NULL;
    _link=nil;_metalLink=nil;_metalLayer=nil;_activity=nil;_frame=nil;[metal invalidate];[link invalidate];layer.displayLinkDriven=NO;
    DWStopHardwareClock(hardware);
    if(activity)[NSProcessInfo.processInfo endActivity:activity];
}
@end
