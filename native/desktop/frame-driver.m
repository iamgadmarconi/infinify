// SPDX-License-Identifier: GPL-3.0-or-later
// DriftWM (malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d) ticks its
// animations from the output's own frame loop (src/backend/udev.rs: render_if_needed,
// tick_all_animations), so its motion runs at the monitor's refresh rate. This is that
// cadence for the macOS shell. New implementation over CADisplayLink.
#import "frame-driver.h"
#import <QuartzCore/QuartzCore.h>
@implementation DWFrameDriver {
    void (^_frame)(DWFrameDriver *);
    CADisplayLink *_link;
}
+ (instancetype)driverOn:(NSArray<NSScreen *> *)screens frame:(void (^)(DWFrameDriver *))frame {
    NSScreen *fastest=nil;for(NSScreen *screen in screens)if(!fastest||screen.maximumFramesPerSecond>fastest.maximumFramesPerSecond)fastest=screen;
    if(!fastest)fastest=NSScreen.mainScreen?:NSScreen.screens.firstObject;if(!fastest)return nil;
    DWFrameDriver *driver=[self new];driver->_frame=[frame copy];driver->_lastFrame=CACurrentMediaTime();driver->_framesPerSecond=fastest.maximumFramesPerSecond;
    // The link retains its target until -invalidate.
    CADisplayLink *link=[fastest displayLinkWithTarget:driver selector:@selector(tick:)];if(!link)return nil;
    // A variable-refresh display is otherwise free to call back below its full rate.
    if(driver->_framesPerSecond>0){float rate=(float)driver->_framesPerSecond;link.preferredFrameRateRange=CAFrameRateRangeMake(rate,rate,rate);}
    driver->_link=link;[link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];return driver;
}
// The block may end this driver, which lets go of the link's reference to it: it is held until the callback returns.
- (void)tick:(CADisplayLink *)link {
    if(link!=_link)return;
    __attribute__((objc_precise_lifetime)) DWFrameDriver *alive=self;void (^frame)(DWFrameDriver *)=_frame;
    _lastFrame=CACurrentMediaTime();if(frame)frame(alive);
}
- (void)invalidate { CADisplayLink *link=_link;_link=nil;_frame=nil;[link invalidate]; }
@end
