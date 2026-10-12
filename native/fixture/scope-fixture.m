// SPDX-License-Identifier: GPL-3.0-or-later
// The disposable application tests/e2e/scoped-windows.sh starts and names to `Infinify --only-pid`: one titled window of
// a regular application, so that the window manager takes it for a real window, holding the three kinds of content a click
// can land in. A first-mouse control (NSButton), a plain view that takes no first click, and a web view, whose page is
// what an inactive application drops a click on and stops drawing under a cover. It never activates itself and posts
// nothing: it only reports, in DIR/status.json, what reached it and where. The one thing it does when asked: DIR/below
// holding a window number puts its window directly under that window (the test names the canvas), without activating.
// ScopeFixture DIR TITLE DX SECONDS: the window is centred on the main screen's visible area, DX points to the right;
// the process ends after SECONDS (300 at most) or when its parent is gone.
// tests/e2e/scoped-sizing.sh adds words after those four, in any order, and nothing below applies without them:
//   resizable          the window can be resized, and its three views follow its size
//   min WxH, max WxH   contentMinSize and contentMaxSize
//   increment WxH      contentResizeIncrements; a size that is off the increment all the same is snapped down by the fixture itself
//                      and counted in `snapped`, so the case does not depend on AppKit applying increments to a size set from outside
//   hidden             the window is shown only when DIR/show appears
//   size WxH           the window's content opens at this size, or at what of it fits the screen's visible area, instead of 420x470
//                      (tests/e2e/scoped-render-bench.sh: a window as large as a person keeps one)
//   animate RATE       explicitly redraw a moving band in the plain view at RATE Hz, even under the canvas (capture benchmark only)
//   report_ms 50|500    periodic status reporting at 50ms (default) or every tenth 50ms tick; watchdog/commands and animation are unchanged
//   corner WxH         the window opens with its lower right corner W and H points inside the visible area's, instead of centred:
//                      from there a larger size does not fit the screen
// and it then also obeys, each a file in DIR removed once read: `frame` "W H" (set its own frame size, top left kept), `hang` SECONDS
// (block the main thread now), `stall` SECONDS (block it inside the next resize, once the window has its new size) and `close` (close the window; the process ends on the next tick).
// With animate, DIR/stripes enables a one-point black/white export marker after the benchmark's timing phases.
// The report gains `limits` (min, max as frame sizes and increment, or null), `snapped` and `resizes`.
// Every report has `screen_visible`, the visible area of the window's screen as the window server and Accessibility measure it,
// and `screen_size`, that screen's whole size.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <libproc.h>
static NSWindow *window;
static NSString *directory;
static NSMutableDictionary<NSString *,NSNumber *> *counts;
static NSMutableDictionary<NSString *,NSArray *> *last;
// What this application was as each kind of event was handled: a later reading may find the foreground gone elsewhere.
static NSMutableDictionary<NSString *,NSDictionary *> *front;
static NSUInteger activations;
static NSButton *button;
static NSView *plain;
static WKWebView *web;
static NSSize increment,base;
static double stall;
static NSUInteger snapped,resizes;
static double animationRate;
static NSUInteger reportEvery=1;
static NSUInteger animationFrames;
static BOOL exportStripes;
static id pair(NSSize s) { return s.width>0&&s.height>0?@[@(s.width),@(s.height)]:(id)NSNull.null; }
// A content size as the size of the frame that holds it: what the window server and Accessibility report.
static id framed(NSSize content) { if(!(content.width>0&&content.height>0)||content.width>=FLT_MAX||content.height>=FLT_MAX)return NSNull.null;return pair([window frameRectForContentRect:(NSRect){NSZeroPoint,content}].size); }
static void resizeFrame(NSSize size) { NSRect f=window.frame;[window setFrame:NSMakeRect(f.origin.x,NSMaxY(f)-size.height,size.width,size.height) display:YES]; }
// Window-local points from the window's top left corner, the frame of reference a forwarded event is addressed in.
static NSArray *local(NSPoint inWindow) { return @[@(inWindow.x),@(window.frame.size.height-inWindow.y)]; }
static NSArray *control(NSView *view) { NSRect r=[view convertRect:view.bounds toView:nil];return @[@(r.origin.x),@(window.frame.size.height-NSMaxY(r)),@(r.size.width),@(r.size.height)]; }
static void count(NSString *key) {
    counts[key]=@(counts[key].unsignedIntegerValue+1);
    front[key]=@{@"app_active":@(NSApp.active),@"key_window":@(window.keyWindow),@"main_window":@(window.mainWindow)};
}
static void report(void) {
    uint32_t wid=(uint32_t)window.windowNumber;struct proc_bsdinfo p={0};proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&p,sizeof(p));
    id bounds=NSNull.null;
    for(NSDictionary *w in CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid)))if([w[(id)kCGWindowNumber]unsignedIntValue]==wid){
        CGRect r=CGRectZero;if(CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r))bounds=@[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
    // Every window the window server draws over this one, front to back: the canvas that covers it must be among them.
    NSMutableArray *above=[NSMutableArray array];
    for(NSDictionary *w in CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenAboveWindow|kCGWindowListExcludeDesktopElements,wid))){
        CGRect r=CGRectZero;if([w[(id)kCGWindowLayer]intValue]!=0||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r))continue;
        [above addObject:@[w[(id)kCGWindowOwnerPID]?:@0,@[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)],w[(id)kCGWindowNumber]?:@0]];}
    // Measured downwards from the primary screen's top left corner, as `bounds` is.
    NSRect area=(window.screen?:NSScreen.mainScreen?:NSScreen.screens.firstObject).visibleFrame;
    NSSize whole=(window.screen?:NSScreen.mainScreen?:NSScreen.screens.firstObject).frame.size;
    NSArray *visible=@[@(area.origin.x),@(NSMaxY(NSScreen.screens.firstObject.frame)-NSMaxY(area)),@(area.size.width),@(area.size.height)];
    NSDictionary *status=@{@"pid":@(getpid()),@"birth":@[@(p.pbi_start_tvsec),@(p.pbi_start_tvusec)],@"window":@(wid),@"title":window.title,@"bounds":bounds,
        @"controls":@{@"button":control(button),@"plain":control(plain),@"web":control(web)},@"counts":[counts copy],@"last":[last copy],@"front":[front copy],@"visible":@(window.visible),
        @"frontmost":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),
        @"key_window":@(window.keyWindow),@"main_window":@(window.mainWindow),@"app_active":@(NSApp.active),@"activations":@(activations),
        @"occlusion_visible":(window.occlusionState&NSWindowOcclusionStateVisible)?@YES:@NO,@"above":above,@"animation_frames":@(animationFrames),@"export_stripes":@(exportStripes),
        @"limits":@{@"min":framed(window.contentMinSize),@"max":framed(window.contentMaxSize),@"increment":pair(increment)},@"snapped":@(snapped),@"resizes":@(resizes),@"screen_visible":visible,@"screen_size":@[@(whole.width),@(whole.height)]};
    // Whole or not at all: a reader never sees half a report.
    NSString *path=[directory stringByAppendingPathComponent:@"status.json"],*partial=[path stringByAppendingString:@".tmp"];
    if([[NSJSONSerialization dataWithJSONObject:status options:0 error:nil]writeToFile:partial atomically:NO])rename(partial.fileSystemRepresentation,path.fileSystemRepresentation);
}
@interface ScopePlain : NSView
@end
@implementation ScopePlain
// The point of this view: a click on it while its application is inactive is not delivered.
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e;return NO; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;[NSColor.systemTealColor setFill];NSRectFill(self.bounds);
    if(animationRate>0){
        [NSColor.systemYellowColor setFill];NSRectFill(NSMakeRect(0,fmod(animationFrames*9,self.bounds.size.height),self.bounds.size.width,48));
        // One-point stripes disappear in an overview raster. A 2x export must recover their contrast from native pixels.
        if(exportStripes)for(int x=0;x<64;x++){[(x%2?NSColor.whiteColor:NSColor.blackColor)setFill];NSRectFill(NSMakeRect(16+x,16,1,32));}
    }
}
- (void)mouseDown:(NSEvent *)e { count(@"plain_down");last[@"plain_down"]=local(e.locationInWindow);report(); }
- (void)mouseUp:(NSEvent *)e { count(@"plain_up");last[@"plain_up"]=local(e.locationInWindow);report(); }
@end
@interface ScopeTarget : NSObject <WKScriptMessageHandler,NSWindowDelegate>
@end
@implementation ScopeTarget
- (void)windowDidResize:(NSNotification *)note {
    (void)note;resizes++;
    // Off the increment: down to the last whole step from the size the window opened with, top left kept.
    if(increment.width>0){NSSize c=[window contentRectForFrameRect:window.frame].size;
        NSSize to=NSMakeSize(base.width+floor((c.width-base.width)/increment.width)*increment.width,base.height+floor((c.height-base.height)/increment.height)*increment.height);
        if(to.width!=c.width||to.height!=c.height){snapped++;resizeFrame([window frameRectForContentRect:(NSRect){NSZeroPoint,to}].size);}}
    // The window has its new size and whoever asked for it is still waiting for the answer.
    if(stall>0){double seconds=stall;stall=0;usleep((useconds_t)(seconds*1e6));}
    report();
}
- (void)action:(id)sender { (void)sender;count(@"button_action");report(); }
- (void)active:(NSNotification *)note { (void)note;activations++;report(); }
// The page reports each mouse event with its client point, and its animation frames by their running count.
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;NSDictionary *body=[message.body isKindOfClass:NSDictionary.class]?message.body:nil;NSString *kind=body[@"t"];
    if([kind isEqual:@"raf"]){counts[@"raf"]=body[@"n"];return;}
    if(![@[@"down",@"up",@"click"]containsObject:kind])return;
    NSString *key=[@"web_" stringByAppendingString:kind];count(key);
    // The web view is flipped: a client point is measured from its top left corner.
    last[key]=local([web convertPoint:NSMakePoint([body[@"x"]doubleValue],[body[@"y"]doubleValue]) toView:nil]);report();
}
@end
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc<5)return 64;
    directory=@(argv[1]);char *end=NULL;double dx=strtod(argv[3],&end);if(!end||*end)return 64;
    double seconds=strtod(argv[4],&end);if(!end||*end||!(seconds>=1&&seconds<=300))return 64;
    BOOL resizable=NO,hidden=NO;NSSize least=NSZeroSize,most=NSZeroSize,opens=NSZeroSize,corner=NSZeroSize;
    for(int i=5;i<argc;i++){
        if(!strcmp(argv[i],"resizable")){resizable=YES;continue;}
        if(!strcmp(argv[i],"hidden")){hidden=YES;continue;}
        if(!strcmp(argv[i],"animate")){if(++i>=argc)return 64;animationRate=strtod(argv[i],&end);if(!end||*end||!isfinite(animationRate)||animationRate<1||animationRate>240)return 64;continue;}
        if(!strcmp(argv[i],"report_ms")){if(++i>=argc)return 64;if(!strcmp(argv[i],"50"))reportEvery=1;else if(!strcmp(argv[i],"500"))reportEvery=10;else return 64;continue;}
        NSSize *into=!strcmp(argv[i],"min")?&least:!strcmp(argv[i],"max")?&most:!strcmp(argv[i],"increment")?&increment:!strcmp(argv[i],"size")?&opens:!strcmp(argv[i],"corner")?&corner:NULL;int w=0,h=0;
        if(!into||++i>=argc||sscanf(argv[i],"%dx%d",&w,&h)!=2||w<1||h<1)return 64;
        *into=NSMakeSize(w,h);
    }
    BOOL isDirectory=NO;if(![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory]||!isDirectory)return 64;
    counts=[NSMutableDictionary dictionary];last=[NSMutableDictionary dictionary];front=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"button_action",@"plain_down",@"plain_up",@"web_down",@"web_up",@"web_click",@"raf"])counts[key]=@0;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSRect area=(NSScreen.mainScreen?:NSScreen.screens.firstObject).visibleFrame;CGFloat width=420,height=470;
    // Less its title bar, and no wider than leaves DX its place.
    if(opens.width>0){width=MAX(420,MIN(opens.width,area.size.width-2*fabs(dx)));height=MAX(470,MIN(opens.height,area.size.height-40));}
    NSRect opening=NSMakeRect(NSMidX(area)-width/2+dx,NSMidY(area)-height/2,width,height);
    if(corner.width>0)opening.origin=NSMakePoint(NSMaxX(area)-corner.width-width,NSMinY(area)+corner.height);
    window=[[NSWindow alloc]initWithContentRect:opening styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|(resizable?NSWindowStyleMaskResizable:0) backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;window.title=@(argv[2]);base=NSMakeSize(width,height);
    if(least.width>0)window.contentMinSize=least;
    if(most.width>0)window.contentMaxSize=most;
    if(increment.width>0)window.contentResizeIncrements=increment;
    ScopeTarget *target=[ScopeTarget new];NSView *content=window.contentView;
    [NSNotificationCenter.defaultCenter addObserver:target selector:@selector(active:) name:NSApplicationDidBecomeActiveNotification object:nil];
    if(argc>5)window.delegate=target;
    // AppKit's content view is not flipped: the three are laid out from the top down by hand.
    button=[NSButton buttonWithTitle:@"First-mouse button" target:target action:@selector(action:)];button.frame=NSMakeRect(20,height-50,width-40,32);[content addSubview:button];
    // Laid out from the top down, and so held to the top edge when the window is resized.
    if(resizable)button.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
    plain=[[ScopePlain alloc]initWithFrame:NSMakeRect(20,height-160,width-40,90)];[content addSubview:plain];
    if(resizable)plain.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];[configuration.userContentController addScriptMessageHandler:target name:@"s"];
    web=[[WKWebView alloc]initWithFrame:NSMakeRect(20,20,width-40,height-200) configuration:configuration];[content addSubview:web];
    if(resizable)web.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [web loadHTMLString:@"<!doctype html><style>html,body{margin:0;height:100%}button{width:100%;height:100%;font:16px system-ui}</style><button id=b>Web button</button><script>"
        "const s=m=>webkit.messageHandlers.s.postMessage(m);for(const[e,t]of[['mousedown','down'],['mouseup','up'],['click','click']])document.getElementById('b').addEventListener(e,v=>s({t,x:v.clientX,y:v.clientY}));"
        "let n=0;const f=()=>{s({t:'raf',n:++n});requestAnimationFrame(f)};requestAnimationFrame(f);</script>" baseURL:nil];
    // In front of what is on screen, but never the active application: that is for the click under test to bring about.
    if(!hidden)[window orderFrontRegardless];
    __block BOOL waiting=hidden;BOOL commanded=argc>5;
    // A command of the sizing test: the file's text, and the file gone.
    NSString *(^command)(NSString *)=^NSString *(NSString *name){NSString *path=[directory stringByAppendingPathComponent:name],*text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];if(text)[NSFileManager.defaultManager removeItemAtPath:path error:nil];return text;};
    pid_t parent=getppid();NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];__block NSUInteger reportTicks=0;
    [NSTimer scheduledTimerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer){(void)timer;if(getppid()!=parent||until.timeIntervalSinceNow<=0||(!waiting&&!window.visible))exit(0);
        if(commanded){NSString *text=nil;
            if(waiting&&command(@"show")){waiting=NO;[window orderFrontRegardless];}
            if((text=command(@"frame"))){NSArray<NSString *> *size=[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(size.count>=2)resizeFrame(NSMakeSize(size[0].doubleValue,size[1].doubleValue));}
            if((text=command(@"stall")))stall=text.doubleValue;
            if((text=command(@"hang")))usleep((useconds_t)(text.doubleValue*1e6));
            if(command(@"close"))[window close];}
        NSString *below=[directory stringByAppendingPathComponent:@"below"],*number=[NSString stringWithContentsOfFile:below encoding:NSUTF8StringEncoding error:nil];
        if(number.integerValue>0){[NSFileManager.defaultManager removeItemAtPath:below error:nil];[window orderWindow:NSWindowBelow relativeTo:number.integerValue];}
        if(animationRate>0&&command(@"stripes"))exportStripes=YES;
        // The first periodic tick still reports promptly. Only this diagnostic
        // cadence changes; event-driven reports above stay immediate.
        if(reportTicks++%reportEvery==0)report();}];
    if(animationRate>0){NSTimer *animation=[NSTimer timerWithTimeInterval:1/animationRate repeats:YES block:^(NSTimer *timer){(void)timer;animationFrames++;[plain display];}];[NSRunLoop.mainRunLoop addTimer:animation forMode:NSRunLoopCommonModes];}
    [NSApp run];return 0;
} }
