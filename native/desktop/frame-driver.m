// SPDX-License-Identifier: GPL-3.0-or-later
// DriftWM (https://github.com/malbiruk/driftwm @ 352333a8fa1b22171492d4b71a54102045c9a19d) ticks its
// animations from the output's own frame loop (src/backend/udev.rs: render_if_needed,
// tick_all_animations), so its motion runs at the monitor's refresh rate. This is that
// cadence for the macOS shell. New implementation over the macOS display link.
#import "frame-driver.h"
#import <QuartzCore/QuartzCore.h>
@implementation DWFrameDriver {
    void (^_frame)(DWFrameDriver *);
    CADisplayLink *_link;
    id _activity;
    double _statsSince,_statsPrevious,_statsGap,_statsWorst;
    NSUInteger _statsTicks;
}
+ (instancetype)driverOn:(NSArray<NSScreen *> *)screens frame:(void (^)(DWFrameDriver *))frame {
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
    return driver;
}
- (void)tick:(CADisplayLink *)link {
    if(link!=_link)return;
    double target=link.targetTimestamp,interval=link.targetTimestamp-link.timestamp;
    // The block may end this driver, which lets go of the link's reference to it: it is held until the callback returns.
    __attribute__((objc_precise_lifetime)) DWFrameDriver *alive=self;void (^frame)(DWFrameDriver *)=_frame;
    _lastFrame=CACurrentMediaTime();_presentationTime=target;@autoreleasepool{if(frame)frame(alive);}_presentationTime=0;
    if(getenv("INFINIFY_DEBUG")){
        if(!_statsSince)_statsSince=_lastFrame;
        if(_statsPrevious>0){double gap=_lastFrame-_statsPrevious;_statsGap+=gap;_statsWorst=fmax(_statsWorst,gap);}_statsPrevious=_lastFrame;_statsTicks++;
        double span=_lastFrame-_statsSince;if(span>=2){
            fprintf(stderr,"cadence: %.2fs callbacks=%.1f target_hz=%.1f callback_gap_ms=%.3f/%.3f requested_hz=%ld activity=%d\n",span,_statsTicks/span,interval>0?1.0/interval:0,_statsTicks?_statsGap/_statsTicks*1000:0,_statsWorst*1000,(long)_framesPerSecond,_activity!=nil);
            _statsSince=_lastFrame;_statsTicks=0;_statsGap=0;_statsWorst=0;}
    }
}
- (void)invalidate {
    CADisplayLink *link=_link;id activity=_activity;
    _link=nil;_activity=nil;_frame=nil;[link invalidate];
    if(activity)[NSProcessInfo.processInfo endActivity:activity];
}
@end
