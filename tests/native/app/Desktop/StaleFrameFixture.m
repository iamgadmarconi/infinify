// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable fixture for tests/e2e/capture-stale-frame.sh: one regular, titled window of its own whose content is a grey
// checkerboard with a pure red 40x40 point square at its top-left and a pure blue one at its bottom-right. SIGUSR1 grows the
// content to the large size, SIGUSR2 shrinks it back, both with the window's top-left kept where it is. It changes no
// other window and no setting, prints READY and one RESIZED line per change, and quits after its watchdog.
//
//   StaleFrameFixture SMALLxHEIGHT LARGExHEIGHT WATCHDOG_SECONDS
#import <AppKit/AppKit.h>
#include <signal.h>
#include <time.h>

@interface DWStaleFrameView : NSView
@end
@implementation DWStaleFrameView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;NSRect b=self.bounds;const CGFloat cell=20,marker=40;
    for(CGFloat y=0;y<b.size.height;y+=cell)for(CGFloat x=0;x<b.size.width;x+=cell){
        BOOL dark=((int)(x/cell)+(int)(y/cell))%2;[[NSColor colorWithSRGBRed:dark?.55:.85 green:dark?.55:.85 blue:dark?.55:.85 alpha:1]setFill];
        NSRectFill(NSMakeRect(x,y,cell,cell));
    }
    [[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1]setFill];NSRectFill(NSMakeRect(0,0,marker,marker));
    [[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1]setFill];NSRectFill(NSMakeRect(b.size.width-marker,b.size.height-marker,marker,marker));
}
@end

static BOOL parseSize(const char *text,NSSize *size) {
    char *end=NULL;double w=strtod(text,&end);if(end==text||*end!='x')return NO;
    const char *rest=end+1;double h=strtod(rest,&end);if(end==rest||*end||w<120||h<120||w>2000||h>2000)return NO;
    *size=NSMakeSize(w,h);return YES;
}
static double monotonic(void) { struct timespec t;clock_gettime(CLOCK_UPTIME_RAW,&t);return t.tv_sec+t.tv_nsec/1e9; }

int main(int argc,char **argv) { @autoreleasepool {
    NSSize small,large;int watchdog=argc==4?atoi(argv[3]):0;
    if(argc!=4||!parseSize(argv[1],&small)||!parseSize(argv[2],&large)||watchdog<1||watchdog>900){fprintf(stderr,"usage: StaleFrameFixture SMALLxH LARGExH WATCHDOG_SECONDS\n");return 2;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(160,200,small.width,small.height)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;window.title=@"DriftWM disposable stale-frame fixture";window.contentView=[[DWStaleFrameView alloc]initWithFrame:NSMakeRect(0,0,small.width,small.height)];
    [window orderFrontRegardless];[NSApp finishLaunching];
    void (^resize)(NSSize)=^(NSSize size){
        NSRect frame=window.frame;CGFloat top=NSMaxY(frame);
        NSRect content=[window frameRectForContentRect:NSMakeRect(frame.origin.x,0,size.width,size.height)];content.origin.y=top-content.size.height;
        [window setFrame:content display:YES];[window.contentView setNeedsDisplay:YES];[window displayIfNeeded];
        printf("RESIZED %g %g t=%.6f\n",window.contentView.bounds.size.width,window.contentView.bounds.size.height,monotonic());fflush(stdout);
    };
    signal(SIGUSR1,SIG_IGN);signal(SIGUSR2,SIG_IGN);
    dispatch_source_t grow=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGUSR1,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(grow,^{resize(large);});dispatch_resume(grow);
    dispatch_source_t shrink=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGUSR2,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(shrink,^{resize(small);});dispatch_resume(shrink);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)watchdog*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
    [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
    printf("READY %d %ld\n",getpid(),(long)window.windowNumber);fflush(stdout);
    [NSApp run];return 0;
} }
