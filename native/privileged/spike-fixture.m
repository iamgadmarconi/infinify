// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable spike fixture. One titled window with one large button and a large
// click-count label, drawn at a fixed place so the owner can find it when the Dock
// helper scales it. It only publishes a JSON status file and counts input; it owns
// no other window and changes no setting. Original GPL code.
#import <AppKit/AppKit.h>
#import <libproc.h>

@interface Fixture : NSObject
@property(nonatomic) NSWindow *window;
@property(nonatomic) NSTextField *label;
@property(nonatomic) NSString *path;
@property(nonatomic) NSInteger clicks;
@property(nonatomic) NSInteger keyDowns;
@property(nonatomic) int birthSec;
@property(nonatomic) int birthUsec;
@end

@implementation Fixture
- (void)writeStatus {
    NSRect f=self.window.frame;
    // Convert the AppKit bottom-left frame to a global top-left rectangle, measured
    // from the top of the primary screen, so the driver can compare it with the
    // WindowServer screen rectangle.
    CGFloat primaryHeight=NSScreen.screens.firstObject.frame.size.height;
    NSDictionary *status=@{
        @"pid":@(getpid()),
        @"birth_sec":@(self.birthSec),
        @"birth_usec":@(self.birthUsec),
        @"window_number":@(self.window.windowNumber),
        @"click_count":@(self.clicks),
        @"key_down_count":@(self.keyDowns),
        @"is_key":@(self.window.isKeyWindow),
        @"app_active":@(NSApp.isActive),
        @"occlusion_visible":@((self.window.occlusionState & NSWindowOcclusionStateVisible)!=0),
        @"frame_global_topleft":@[@(f.origin.x),@(primaryHeight-(f.origin.y+f.size.height)),@(f.size.width),@(f.size.height)],
    };
    NSData *data=[NSJSONSerialization dataWithJSONObject:status options:0 error:NULL];
    // atomically:YES writes a temp file and renames, so a reader never sees a partial.
    [data writeToFile:self.path atomically:YES];
}
- (void)clicked:(id)sender {
    (void)sender;
    self.clicks++;
    self.label.stringValue=[NSString stringWithFormat:@"%ld",(long)self.clicks];
    [self writeStatus];
}
- (void)keyed { self.keyDowns++; [self writeStatus]; }
@end

int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=3){fprintf(stderr,"usage: spike-fixture /abs/status.json seconds\n");return 2;}
    double seconds=atof(argv[2]);
    if(seconds<=0)seconds=1;
    if(seconds>600)seconds=600;

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,640,420) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title=@"DriftWM disposable spike fixture";
    window.releasedWhenClosed=NO;

    Fixture *fixture=[Fixture new];
    fixture.window=window;
    fixture.path=[NSString stringWithUTF8String:argv[1]];
    struct proc_bsdinfo info={0};
    if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)) {
        fixture.birthSec=info.pbi_start_tvsec;
        fixture.birthUsec=info.pbi_start_tvusec;
    }

    NSTextField *label=[NSTextField labelWithString:@"0"];
    label.font=[NSFont boldSystemFontOfSize:64];
    label.alignment=NSTextAlignmentCenter;
    label.frame=NSMakeRect(20,320,600,80);
    fixture.label=label;
    [window.contentView addSubview:label];

    NSButton *button=[NSButton buttonWithTitle:@"Spike fixture — click me" target:fixture action:@selector(clicked:)];
    button.frame=NSMakeRect(40,40,560,260);
    button.font=[NSFont systemFontOfSize:28];
    [window.contentView addSubview:button];

    // Shown above ordinary windows and never activated: the owner is at a sudo password prompt when this opens, and the
    // terminal they type into must keep the keyboard and must not be able to cover the window they are asked to find.
    window.level=NSFloatingWindowLevel;
    [window orderFrontRegardless];
    [NSApp finishLaunching];

    // Count key presses without changing any other behaviour.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event){[fixture keyed];return event;}];

    // At least four status writes a second, plus one on every counted change above.
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer){(void)timer;[fixture writeStatus];}];
    [fixture writeStatus];

    // Exit by itself after the bounded lifetime and on SIGTERM; either way the
    // process end removes its one window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
    signal(SIGTERM,SIG_IGN);
    static dispatch_source_t term;
    term=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(term,^{[NSApp terminate:nil];});
    dispatch_resume(term);

    [NSApp run];
    return 0;
} }
