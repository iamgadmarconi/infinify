// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation. Private signatures/routing fields referenced from Cantrip
// 4da10af479701c8007074c65f9eb6a2db03c8ffc, macos/skylight.rs; no code copied.
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <libproc.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>

static volatile sig_atomic_t stopped;
static void stopSignal(int s) { stopped = s; }
static void save(id value, NSString *path) {
    [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path atomically:YES];
}
static NSDictionary *readJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static void pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.005]
                                         inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e) [NSApp sendEvent:e];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    } while (!stopped && end.timeIntervalSinceNow > 0);
}
static NSArray *birth(pid_t pid) {
    struct proc_bsdinfo p = {0};
    if (proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&p,sizeof(p)) != sizeof(p)) return nil;
    return @[@(p.pbi_start_tvsec),@(p.pbi_start_tvusec)];
}
static NSDictionary *windowInfo(uint32_t wid) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));
    for (NSDictionary *w in windows) if ([w[(id)kCGWindowNumber] unsignedIntValue] == wid) return w;
    return nil;
}
static NSString *digest(NSString *text) {
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]; unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,result); NSMutableString *hex=[NSMutableString string];
    for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",result[i]]; return hex;
}
static CGPoint pointer(void) { CGEventRef e=CGEventCreate(NULL); CGPoint p=CGEventGetLocation(e); CFRelease(e); return p; }

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end
@interface FixtureWindow : NSWindow
@end
@implementation FixtureWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
@interface CanvasPanel : NSPanel
@end
@implementation CanvasPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
static NSMutableArray *sourceEvents;
static NSUInteger untaggedSourceEvents;
static int64_t lastSourceTag;
@interface ProbeApplication : NSApplication
@end
@implementation ProbeApplication
- (void)sendEvent:(NSEvent *)event {
    if (sourceEvents && (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp ||
                       event.type == NSEventTypeKeyDown || event.type == NSEventTypeScrollWheel)) {
        CGEventRef cg=event.CGEvent;
        lastSourceTag=cg ? CGEventGetIntegerValueField(cg,kCGEventSourceUserData) : 0;
        if(!lastSourceTag)untaggedSourceEvents++;
        [sourceEvents addObject:@{@"type":@(event.type),@"tag":@(lastSourceTag),@"window":@(event.windowNumber),
           @"local":@[@(event.locationInWindow.x),@(event.locationInWindow.y)],@"key_code":@(event.type==NSEventTypeKeyDown?event.keyCode:0),@"marked_text_sha256":event.type==NSEventTypeKeyDown&&lastSourceTag?digest(event.characters?:@""):@"",@"flags":@(event.modifierFlags)}];
    }
    [super sendEvent:event];
    if(sourceEvents && event.type==NSEventTypeKeyDown && event.keyCode==53)stopped=1;
}
@end
@interface SourceControls : NSObject
@property NSInteger clicks;
@property NSMutableArray *actions;
- (void)clicked:(id)sender;
@end
@implementation SourceControls
- (void)clicked:(id)sender { (void)sender; self.clicks++; [self.actions addObject:@{@"count":@(self.clicks),@"tag":@(lastSourceTag)}]; }
@end
static NSTextField *label(NSString *text, NSRect rect) {
    NSTextField *f=[NSTextField labelWithString:text]; f.frame=rect; return f;
}
static NSWindow *makeWindow(NSRect rect, NSString *title) {
    NSWindow *w=[[FixtureWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.title=title; w.releasedWhenClosed=NO; w.animationBehavior=NSWindowAnimationBehaviorNone; w.hasShadow=NO;
    w.collectionBehavior=NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;
    return w;
}
static int source(NSString *directory, double seconds, NSString *nonce) {
    pid_t parent=getppid(); sourceEvents=[NSMutableArray array];
    NSMenu *main=[NSMenu new]; NSMenuItem *editItem=[NSMenuItem new]; [main addItem:editItem];
    NSMenu *editMenu=[[NSMenu alloc]initWithTitle:@"Edit"]; [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"]; editItem.submenu=editMenu; NSApp.mainMenu=main;
    SourceControls *controls=[SourceControls new]; controls.actions=[NSMutableArray array];
    NSWindow *w=makeWindow(NSMakeRect(120,140,560,420),@"DriftWM disposable native source");
    FlippedView *view=[[FlippedView alloc] initWithFrame:NSMakeRect(0,0,560,420)]; w.contentView=view;
    [view addSubview:label(@"Unmodified AppKit controls • live window capture",NSMakeRect(20,5,520,24))];
    NSView *patch=[[NSView alloc] initWithFrame:NSMakeRect(340,35,160,60)]; patch.wantsLayer=YES; [view addSubview:patch];
    NSView *marker=[[NSView alloc] initWithFrame:NSMakeRect(280,110,40,40)]; marker.wantsLayer=YES;
    marker.layer.backgroundColor=[NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:1].CGColor; [view addSubview:marker];
    NSTextField *tick=label(@"tick",NSMakeRect(20,40,300,24)); [view addSubview:tick];
    NSButton *button=[NSButton buttonWithTitle:@"Native button" target:controls action:@selector(clicked:)];
    button.frame=NSMakeRect(40,100,180,40); [view addSubview:button];
    NSTextField *edit=[[NSTextField alloc] initWithFrame:NSMakeRect(40,180,460,32)]; edit.stringValue=@"Editable native text"; [view addSubview:edit];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(40,240,480,160)]; scroll.hasVerticalScroller=YES;
    FlippedView *document=[[FlippedView alloc] initWithFrame:NSMakeRect(0,0,460,1800)];
    for (int i=0;i<60;i++) [document addSubview:label([NSString stringWithFormat:@"Native scroll row %02d",i],NSMakeRect(10,i*30,420,24))];
    scroll.documentView=document; [view addSubview:scroll]; [w makeKeyAndOrderFront:nil]; [w orderFrontRegardless];
    NSDate *start=NSDate.date; double next=0;
    while (!stopped && getppid()==parent && -start.timeIntervalSinceNow<seconds) {
        double elapsed=-start.timeIntervalSinceNow;
        if (elapsed>=next) {
            NSInteger phase=(NSInteger)elapsed%2;
            tick.stringValue=[NSString stringWithFormat:@"Live tick %.1f · native clicks %ld",elapsed,(long)controls.clicks];
            patch.layer.backgroundColor=(phase ? NSColor.blueColor:NSColor.redColor).CGColor;
            save(@{@"pid":@(getpid()),@"birth":birth(getpid())?:@[],@"nonce":nonce,@"window":@(w.windowNumber),
                @"bounds":windowInfo((uint32_t)w.windowNumber)[(id)kCGWindowBounds]?:@{},@"tick":@(elapsed),@"phase":@(phase),
                @"key_window":@(w.keyWindow),@"app_active":@(NSApp.active),@"first_responder":NSStringFromClass([w.firstResponder class]),@"clicks":@(controls.clicks),@"actions":controls.actions,@"text_sha256":digest(edit.currentEditor.string?:edit.stringValue),@"untagged_events":@(untaggedSourceEvents),
                @"scroll_y":@(scroll.contentView.bounds.origin.y),@"events":sourceEvents},[directory stringByAppendingPathComponent:@"source.json"]);
            next=elapsed+.1;
        }
        pump(.015);
    }
    [w close]; save(@{@"pid":@(getpid()),@"reason":stopped?@"signal":getppid()!=parent?@"parent_exit":@"deadline"},[directory stringByAppendingPathComponent:@"source-exit.json"]);
    return 0;
}

@interface Router : NSObject
@property pid_t pid;
@property uint32_t wid;
@property NSArray *processBirth;
@property NSDictionary *bounds;
@property CGEventSourceRef eventSource;
@property int64_t tag;
@property BOOL usePrivate;
@property NSMutableArray *sent;
@property NSDate *deadline;
@property void (*privatePost)(pid_t,CGEventRef);
@property void (*privateLocation)(CGEventRef,CGPoint);
@property void (*privateField)(CGEventRef,uint32_t,int64_t);
- (BOOL)valid;
- (BOOL)loadPrivate;
- (BOOL)post:(CGEventRef)event at:(CGPoint)point;
- (BOOL)click:(CGPoint)point;
- (void)type:(NSString *)text at:(CGPoint)point;
- (void)scroll:(int)delta at:(CGPoint)point;
@end
@implementation Router
- (BOOL)loadPrivate {
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW);
    self.privatePost=sky?dlsym(sky,"SLEventPostToPid"):NULL;
    self.privateField=sky?dlsym(sky,"SLEventSetIntegerValueField"):NULL;
    self.privateLocation=dlsym(RTLD_DEFAULT,"CGEventSetWindowLocation");
    return self.privatePost&&self.privateField&&self.privateLocation;
}
- (BOOL)valid {
    NSDictionary *w=windowInfo(self.wid);
    return [birth(self.pid) isEqual:self.processBirth] && [w[(id)kCGWindowOwnerPID] intValue]==self.pid &&
           [w[(id)kCGWindowBounds] isEqual:self.bounds];
}
- (BOOL)post:(CGEventRef)e at:(CGPoint)p {
    if (!e || ![self valid] || stopped || self.deadline.timeIntervalSinceNow<=0) return NO;
    CGEventSetSource(e,self.eventSource);
    CGEventSetIntegerValueField(e,kCGEventSourceUserData,self.tag);
    CGEventSetIntegerValueField(e,(CGEventField)91,self.wid); CGEventSetIntegerValueField(e,(CGEventField)92,self.wid);
    CGRect bounds; CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)self.bounds,&bounds);
    CGEventSetLocation(e,CGPointMake(bounds.origin.x+p.x,bounds.origin.y+p.y));
    if (self.usePrivate) {
        if (!self.privatePost || !self.privateLocation || !self.privateField) return NO;
        self.privateLocation(e,p);
        self.privateField(e,40,self.pid); self.privateField(e,51,self.wid); self.privateField(e,58,self.tag);
        self.privateField(e,91,self.wid); self.privateField(e,92,self.wid);
        if (CGEventGetType(e)==kCGEventLeftMouseDown || CGEventGetType(e)==kCGEventLeftMouseUp || CGEventGetType(e)==kCGEventLeftMouseDragged)
            self.privateField(e,7,3);
        self.privatePost(self.pid,e);
    } else CGEventPostToPid(self.pid,e);
    [self.sent addObject:@{@"type":@(CGEventGetType(e)),@"tag":@(self.tag),@"point":@[@(p.x),@(p.y)],@"route":self.usePrivate?@"private":@"public"}];
    return YES;
}
- (BOOL)click:(CGPoint)p {
    BOOL result=YES;
    for (int i=0;i<2;i++) {
        CGEventRef e=CGEventCreateMouseEvent(self.eventSource,i?kCGEventLeftMouseUp:kCGEventLeftMouseDown,CGPointZero,kCGMouseButtonLeft);
        CGEventSetIntegerValueField(e,kCGMouseEventClickState,1); result=[self post:e at:p]&&result; CFRelease(e); pump(.08);
    }
    return result;
}
- (void)type:(NSString *)text at:(CGPoint)p {
    // Select all through the real keyboard path, then send Unicode key events.
    for(int i=0;i<2;i++) {
        CGEventRef e=CGEventCreateKeyboardEvent(self.eventSource,0,!i); CGEventSetFlags(e,kCGEventFlagMaskCommand);
        [self post:e at:p]; CFRelease(e); pump(.05);
    }
    NSUInteger count=text.length; UniChar *chars=calloc(count,sizeof(UniChar)); [text getCharacters:chars range:NSMakeRange(0,count)];
    for(int i=0;i<2;i++) { CGEventRef e=CGEventCreateKeyboardEvent(self.eventSource,0,!i); CGEventSetFlags(e,0); CGEventKeyboardSetUnicodeString(e,count,chars); [self post:e at:p]; CFRelease(e); pump(.05); }
    free(chars);
}
- (void)scroll:(int)delta at:(CGPoint)p {
    CGEventRef e=CGEventCreateScrollWheelEvent(self.eventSource,kCGScrollEventUnitPixel,1,delta); [self post:e at:p]; CFRelease(e);
}
@end

@interface Canvas : FlippedView <SCStreamOutput,SCStreamDelegate>
@property NSArray<AVSampleBufferDisplayLayer *> *surfaces;
@property NSArray<CALayer *> *clips;
@property Router *router;
@property NSUInteger frames;
@property NSString *streamError;
@property NSInteger selected;
@property CGPoint lastPoint;
@property BOOL panning;
@property BOOL interactive;
@property NSRunningApplication *previousFocus;
@property NSDate *previousFocusBirth;
@property NSMutableArray *inputMappings;
- (void)layoutCameras;
- (CGPoint)world:(CGPoint)p camera:(NSInteger)i;
- (CGPoint)canvasPoint:(CGPoint)p camera:(NSInteger)i;
- (BOOL)clickWorld:(CGPoint)p camera:(NSInteger)i;
@end
static CGFloat zooms[2]={.8,1.2};
static CGPoint pans[2]={{0,0},{70,20}};
static CGRect ports[2]={{{20,60},{480,500}},{{540,60},{480,500}}};
@implementation Canvas
- (BOOL)acceptsFirstResponder { return YES; }
- (void)layoutCameras {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for(int i=0;i<2;i++) {
        AVSampleBufferDisplayLayer *l=self.surfaces[i]; l.anchorPoint=CGPointZero; l.bounds=CGRectMake(0,0,560,420);
        l.position=CGPointMake(-pans[i].x*zooms[i],-pans[i].y*zooms[i]); l.transform=CATransform3DMakeScale(zooms[i],zooms[i],1);
    }
    [CATransaction commit];
}
- (CGPoint)world:(CGPoint)p camera:(NSInteger)i { return CGPointMake((p.x-ports[i].origin.x)/zooms[i]+pans[i].x,(p.y-ports[i].origin.y)/zooms[i]+pans[i].y); }
- (CGPoint)canvasPoint:(CGPoint)p camera:(NSInteger)i { return CGPointMake((p.x-pans[i].x)*zooms[i]+ports[i].origin.x,(p.y-pans[i].y)*zooms[i]+ports[i].origin.y); }
- (NSInteger)cameraAt:(CGPoint)p { for(int i=0;i<2;i++) if(CGRectContainsPoint(ports[i],p)) return i; return -1; }
- (BOOL)inside:(CGPoint)p { return p.x>=0 && p.y>=0 && p.x<560 && p.y<420; }
- (BOOL)clickWorld:(CGPoint)p camera:(NSInteger)i {
    CGPoint local=[self canvasPoint:p camera:i]; if(!CGRectContainsPoint(ports[i],local)) return NO;
    CGPoint mapped=[self world:local camera:i];
    [self.inputMappings addObject:@{@"camera":@(i),@"canvas":@[@(local.x),@(local.y)],@"source":@[@(mapped.x),@(mapped.y)],@"zoom":@(zooms[i])}];
    return [self.router click:mapped];
}
- (void)mouseDown:(NSEvent *)e {
    if(!self.interactive)return;
    CGPoint p=[self convertPoint:e.locationInWindow fromView:nil]; NSInteger i=[self cameraAt:p]; if(i<0)return;
    self.selected=i;
    if([self.router valid] && !(e.modifierFlags & NSEventModifierFlagOption)) {
        NSRunningApplication *current=NSWorkspace.sharedWorkspace.frontmostApplication;
        if(current.processIdentifier!=self.router.pid) { self.previousFocus=current; self.previousFocusBirth=current.launchDate; [[NSRunningApplication runningApplicationWithProcessIdentifier:self.router.pid]activateWithOptions:0]; }
    }
    self.panning=(e.modifierFlags & NSEventModifierFlagOption)!=0; self.lastPoint=p;
    if(!self.panning) { CGPoint q=[self world:p camera:i]; if([self inside:q]) { CGEventRef cg=CGEventCreateMouseEvent(self.router.eventSource,kCGEventLeftMouseDown,CGPointZero,kCGMouseButtonLeft); CGEventSetIntegerValueField(cg,kCGMouseEventClickState,e.clickCount); [self.router post:cg at:q]; CFRelease(cg); } }
}
- (void)mouseDragged:(NSEvent *)e {
    if(!self.interactive)return;
    CGPoint p=[self convertPoint:e.locationInWindow fromView:nil];
    if(self.panning) { pans[self.selected].x-=(p.x-self.lastPoint.x)/zooms[self.selected]; pans[self.selected].y-=(p.y-self.lastPoint.y)/zooms[self.selected]; [self layoutCameras]; }
    else { CGPoint q=[self world:p camera:self.selected]; if([self inside:q]) { CGEventRef cg=CGEventCreateMouseEvent(self.router.eventSource,kCGEventLeftMouseDragged,CGPointZero,kCGMouseButtonLeft); [self.router post:cg at:q]; CFRelease(cg); } }
    self.lastPoint=p;
}
- (void)mouseUp:(NSEvent *)e {
    if(!self.interactive)return;
    if(!self.panning) { CGPoint q=[self world:[self convertPoint:e.locationInWindow fromView:nil] camera:self.selected]; CGEventRef cg=CGEventCreateMouseEvent(self.router.eventSource,kCGEventLeftMouseUp,CGPointZero,kCGMouseButtonLeft); [self.router post:cg at:q]; CFRelease(cg); }
    self.panning=NO;
}
- (void)zoom:(CGFloat)factor at:(CGPoint)p camera:(NSInteger)i {
    CGPoint before=[self world:p camera:i]; zooms[i]=MAX(.25,MIN(3,zooms[i]*factor));
    pans[i]=CGPointMake(before.x-(p.x-ports[i].origin.x)/zooms[i],before.y-(p.y-ports[i].origin.y)/zooms[i]); [self layoutCameras];
}
- (void)scrollWheel:(NSEvent *)e {
    if(!self.interactive)return;
    CGPoint p=[self convertPoint:e.locationInWindow fromView:nil]; NSInteger i=[self cameraAt:p]; if(i<0)return;
    self.selected=i;
    if(e.modifierFlags & NSEventModifierFlagCommand) [self zoom:exp(e.scrollingDeltaY*.01) at:p camera:i];
    else if(e.modifierFlags & NSEventModifierFlagOption) { pans[i].x-=e.scrollingDeltaX/zooms[i]; pans[i].y-=e.scrollingDeltaY/zooms[i]; [self layoutCameras]; }
    else { CGPoint q=[self world:p camera:i]; if([self inside:q]) { CGEventRef cg=CGEventCreateCopy(e.CGEvent); [self.router post:cg at:q]; CFRelease(cg); } }
}
- (void)magnifyWithEvent:(NSEvent *)e { if(!self.interactive)return; CGPoint p=[self convertPoint:e.locationInWindow fromView:nil]; NSInteger i=[self cameraAt:p]; if(i>=0)[self zoom:1+e.magnification at:p camera:i]; }
- (void)keyDown:(NSEvent *)e { if(e.keyCode==53){stopped=1;return;} if(!self.interactive)return; CGEventRef cg=CGEventCreateCopy(e.CGEvent); [self.router post:cg at:[self world:self.lastPoint camera:self.selected]]; CFRelease(cg); }
- (void)keyUp:(NSEvent *)e { if(!self.interactive)return; CGEventRef cg=CGEventCreateCopy(e.CGEvent); [self.router post:cg at:[self world:self.lastPoint camera:self.selected]]; CFRelease(cg); }
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { (void)stream; self.streamError=error.description; }
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream; if(type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample) || !CMSampleBufferGetImageBuffer(sample))return;
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(a && CFArrayGetCount(a)) { NSDictionary *info=(__bridge NSDictionary *)CFArrayGetValueAtIndex(a,0); if([info[SCStreamFrameInfoStatus] integerValue]!=SCFrameStatusComplete)return; }
    CMSampleBufferRef copy=NULL; if(CMSampleBufferCreateCopy(kCFAllocatorDefault,sample,&copy)!=noErr)return;
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(copy,YES);
    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments,0),kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);
    for(AVSampleBufferDisplayLayer *layer in self.surfaces) { if(layer.sampleBufferRenderer.status==AVQueuedSampleBufferRenderingStatusFailed)[layer.sampleBufferRenderer flush]; if(layer.sampleBufferRenderer.readyForMoreMediaData)[layer.sampleBufferRenderer enqueueSampleBuffer:copy]; }
    self.frames++; CFRelease(copy);
}
@end

static SCWindow *findWindow(pid_t pid,uint32_t wid) {
    __block BOOL done=NO; __block SCShareableContent *content=nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *c,NSError *e){(void)e;dispatch_async(dispatch_get_main_queue(),^{content=c;done=YES;});}];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3]; while(!done&&!stopped&&end.timeIntervalSinceNow>0)pump(.02);
    for(SCWindow *w in content.windows)if(w.windowID==wid&&w.owningApplication.processID==pid)return w;
    return nil;
}
static NSDictionary *captureHost(SCContentFilter *filter,NSString *path) {
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=1040;config.height=600;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;
    __block BOOL done=NO,abandoned=NO;__block CGImageRef image=NULL;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef img,NSError *error){(void)error;CGImageRef retained=img?CGImageRetain(img):NULL;dispatch_async(dispatch_get_main_queue(),^{if(abandoned){if(retained)CGImageRelease(retained);return;}image=retained;done=YES;});}];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];while(!done&&!stopped&&end.timeIntervalSinceNow>0)pump(.02);abandoned=!done;
    if(!image)return @{@"error":@"Exact host capture failed"};
    NSBitmapImageRep *png=[[NSBitmapImageRep alloc]initWithCGImage:image];[[png representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:path atomically:YES];
    size_t w=CGImageGetWidth(image),h=CGImageGetHeight(image);unsigned char *pixels=calloc(w*h,4);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGContextRef ctx=CGBitmapContextCreate(pixels,w,h,8,w*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx,CGRectMake(0,0,w,h),image);NSMutableArray *views=[NSMutableArray array];
    for(int i=0;i<2;i++) { NSUInteger red=0,blue=0,green=0,outside=0;int minx=(int)w,miny=(int)h,maxx=-1,maxy=-1;
        for(int y=0;y<(int)h;y++)for(int x=i?520:0;x<(i?(int)w:520);x++) { unsigned char *p=pixels+(y*w+x)*4;BOOL r=p[0]>200&&p[1]<60&&p[2]<60,b=p[2]>200&&p[0]<60&&p[1]<60,g=p[1]>180&&p[0]<150&&p[2]<100;red+=r;blue+=b;green+=g;if(g){minx=MIN(minx,x);maxx=MAX(maxx,x);miny=MIN(miny,y);maxy=MAX(maxy,y);}if((r||b||g)&&!CGRectContainsPoint(ports[i],CGPointMake(x,y)))outside++; }
        [views addObject:@{@"red":@(red),@"blue":@(blue),@"green":@(green),@"outside_clip":@(outside),@"marker_bounds":@[@(minx),@(miny),@(maxx-minx+1),@(maxy-miny+1)]}];
    }
    CGContextRelease(ctx);CGColorSpaceRelease(space);CGImageRelease(image);free(pixels);
    return @{@"png":path,@"width":@(w),@"height":@(h),@"views":views};
}
static NSDictionary *attempt(Canvas *canvas,NSString *directory,int camera,BOOL privateRoute) {
    Router *r=canvas.router;r.usePrivate=privateRoute;r.tag++;NSDictionary *before=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
    [canvas clickWorld:CGPointMake(120,120) camera:camera];pump(.3);
    NSDictionary *button=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
    [canvas clickWorld:CGPointMake(170,195) camera:camera];pump(.15);
    NSString *text=[NSString stringWithFormat:@"view-%d-%@",camera,privateRoute?@"private":@"public"];
    CGPoint p=[canvas world:[canvas canvasPoint:CGPointMake(170,195) camera:camera] camera:camera];[r type:text at:p];pump(.35);
    NSDictionary *typed=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
    p=[canvas world:[canvas canvasPoint:CGPointMake(200,300) camera:camera] camera:camera];[r scroll:-100 at:p];pump(.4);
    NSDictionary *after=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
    BOOL action=NO;for(NSDictionary *a in button[@"actions"])if([a[@"tag"] longLongValue]==r.tag)action=YES;
    BOOL clean=[after[@"untagged_events"]unsignedIntegerValue]==[before[@"untagged_events"]unsignedIntegerValue];
    BOOL keyDelivered=NO,scrollDelivered=NO; for(NSDictionary *event in after[@"events"])if([event[@"tag"]longLongValue]==r.tag && [event[@"window"]unsignedIntValue]==r.wid){ if([event[@"type"]intValue]==NSEventTypeKeyDown && [event[@"marked_text_sha256"]isEqual:digest(text)])keyDelivered=YES; if([event[@"type"]intValue]==NSEventTypeScrollWheel)scrollDelivered=YES; }
    if(!clean)stopped=1;
    return @{@"camera":@(camera),@"uncontaminated":@(clean),@"route":privateRoute?@"private":@"public",@"tag":@(r.tag),@"before":before?:@{},@"after":after?:@{},
        @"button_proven":@(clean&&action&&[button[@"clicks"] integerValue]>[before[@"clicks"] integerValue]),
        @"text_proven":@(clean&&keyDelivered&&[typed[@"text_sha256"] isEqual:digest(text)]),@"scroll_proven":@(clean&&scrollDelivered&&[after[@"scroll_y"] doubleValue]>[typed[@"scroll_y"] doubleValue]),@"expected_text":text};
}
static int host(NSString *directory,double seconds,BOOL demo,NSString *executable) {
    NSMutableDictionary *report=[@{@"host_pid":@(getpid()),@"screen_capture_preflight":@(CGPreflightScreenCaptureAccess()),@"accessibility_preflight":@(AXIsProcessTrusted()),@"permission_requests":@0,@"global_input_posts":@0,@"window_transform_calls":@0,@"source_custom_surface_exports":@0,@"frames":[NSMutableArray array],@"attempts":[NSMutableArray array]}mutableCopy];
    NSString *receipt=[directory stringByAppendingPathComponent:@"receipt.json"];
    if(!CGPreflightScreenCaptureAccess()||!AXIsProcessTrusted()){report[@"error"]=@"Existing capture and accessibility access required; no prompt requested";save(report,receipt);return 2;}
    NSRunningApplication *previous=NSWorkspace.sharedWorkspace.frontmostApplication;
    report[@"prior_foreground_pid"]=@(previous.processIdentifier);
    CGPoint pointerBefore=pointer();NSString *nonce=NSUUID.UUID.UUIDString;
    NSTask *child=[NSTask new];child.executableURL=[NSURL fileURLWithPath:executable];child.arguments=@[@"--source",directory,[NSString stringWithFormat:@"%.1f",seconds+5],nonce];
    NSError *error=nil;if(![child launchAndReturnError:&error]){report[@"error"]=error.description;save(report,receipt);return 2;}
    report[@"source_pid"]=@(child.processIdentifier);NSDate *start=NSDate.date;NSDictionary *ready=nil;
    while(child.running&&!stopped&&-start.timeIntervalSinceNow<3){ready=readJSON([directory stringByAppendingPathComponent:@"source.json"]);if([ready[@"bounds"] count] && [ready[@"window"] unsignedIntValue])break;pump(.02);}
    pump(.4); ready=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
    Router *router=[Router new];router.pid=child.processIdentifier;router.wid=[ready[@"window"]unsignedIntValue];router.processBirth=ready[@"birth"];router.bounds=ready[@"bounds"];router.sent=[NSMutableArray array];router.tag=(int64_t)(arc4random_uniform(0x7fffff)+1)*100;
    router.deadline=[start dateByAddingTimeInterval:seconds];
    router.eventSource=CGEventSourceCreate(kCGEventSourceStatePrivate);
    BOOL enrolled=ready&&[ready[@"nonce"]isEqual:nonce]&&[ready[@"pid"]intValue]==child.processIdentifier&&[router valid];
    report[@"identity_enrolled"]=@(enrolled);report[@"source_initial"]=ready?:@{};
    NSWindow *window=nil;SCStream *stream=nil;Canvas *canvas=nil;
    if(enrolled&&!stopped){
        SCWindow *sourceWindow=findWindow(router.pid,router.wid);
        if(sourceWindow){
            window=[[CanvasPanel alloc]initWithContentRect:NSMakeRect(100,120,1040,600) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed=NO;window.animationBehavior=NSWindowAnimationBehaviorNone;window.hasShadow=NO;
            window.collectionBehavior=NSWindowCollectionBehaviorMoveToActiveSpace|NSWindowCollectionBehaviorFullScreenAuxiliary;
            canvas=[[Canvas alloc]initWithFrame:NSMakeRect(0,0,1040,600)];window.contentView=canvas;canvas.wantsLayer=YES;canvas.layer.backgroundColor=NSColor.darkGrayColor.CGColor;canvas.router=router;canvas.interactive=demo; if(demo){router.usePrivate=[router loadPrivate];report[@"private_available"]=@(router.usePrivate);canvas.interactive=router.usePrivate;} canvas.inputMappings=[NSMutableArray array];
            [canvas addSubview:label(@"LIVE native window × 2   |   Option-drag / Option-scroll: pan   |   ⌘-scroll / pinch: zoom   |   Esc: close",NSMakeRect(20,15,1000,30))];
            NSMutableArray *surfaces=[NSMutableArray array],*clips=[NSMutableArray array];
            for(int i=0;i<2;i++){CALayer *clip=[CALayer layer];clip.frame=ports[i];clip.masksToBounds=YES;clip.backgroundColor=NSColor.blackColor.CGColor;[canvas.layer addSublayer:clip];AVSampleBufferDisplayLayer *surface=[AVSampleBufferDisplayLayer layer];surface.videoGravity=AVLayerVideoGravityResize;[clip addSublayer:surface];[clips addObject:clip];[surfaces addObject:surface];}
            canvas.surfaces=surfaces;canvas.clips=clips;[canvas layoutCameras];
            SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:sourceWindow];
            SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=560;config.height=420;config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=CMTimeMake(1,30);config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;
            stream=[[SCStream alloc]initWithFilter:filter configuration:config delegate:canvas];
            if(![stream addStreamOutput:canvas type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&error])report[@"stream_error"]=error.description;
            [stream startCaptureWithCompletionHandler:^(NSError *e){if(e)canvas.streamError=e.description;}];
            window.level=NSFloatingWindowLevel; [window orderFrontRegardless];[window makeFirstResponder:canvas];
            SCWindow *hostWindow=findWindow(getpid(),(uint32_t)window.windowNumber);
            SCContentFilter *hostFilter=hostWindow?[[SCContentFilter alloc]initWithDesktopIndependentWindow:hostWindow]:nil;
            report[@"host_window"]=@(window.windowNumber);report[@"source_window"]=@(router.wid);
            NSDictionary *hostInfo=windowInfo((uint32_t)window.windowNumber); report[@"host_bounds"]=hostInfo[(id)kCGWindowBounds]?:@{};
            NSArray *stack=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
            NSInteger hi=-1,si=-1,index=0;for(NSDictionary *entry in stack){uint32_t wid=[entry[(id)kCGWindowNumber]unsignedIntValue];if(wid==window.windowNumber)hi=index;if(wid==router.wid)si=index;index++;}
            CGRect hb=CGRectZero,sb=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)hostInfo[(id)kCGWindowBounds],&hb);CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)router.bounds,&sb);
            report[@"source_behind_covering_host"]=@(hi>=0&&si>hi&&CGRectContainsRect(hb,sb));
            // Pixel snapshots inspect the actual host composition, never the source's telemetry.
            for(int i=0;i<6&&!stopped&&-start.timeIntervalSinceNow<seconds;i++) {
                pump(.72);
                if([readJSON([directory stringByAppendingPathComponent:@"source.json"])[@"untagged_events"]unsignedIntegerValue]) {
                    // Physical typing is normal demo input. Stop saving pixels,
                    // but reserve contamination cancellation for scripted proof.
                    report[@"human_input_interrupted_capture"]=@YES;
                    report[@"screenshots_suppressed_after_input"]=@YES;
                    if(!demo)stopped=1;
                    break;
                }
                if(hostFilter)[report[@"frames"]addObject:captureHost(hostFilter,[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%d.png",i]])];
            }
            if(!demo&&!stopped&&-start.timeIntervalSinceNow+7<seconds){
                for(int i=0;i<2&&!stopped;i++)[report[@"attempts"]addObject:attempt(canvas,directory,i,NO)];
                BOOL publicPass=YES;for(NSDictionary *a in report[@"attempts"])publicPass&=[a[@"button_proven"]boolValue]&&[a[@"text_proven"]boolValue]&&[a[@"scroll_proven"]boolValue];
                if(!publicPass&&!stopped){report[@"private_available"]=@([router loadPrivate]);if([report[@"private_available"]boolValue]) {
                    // Normal native activation is needed for reliable AppKit keyboard dispatch.
                    // Request it only for this short key test; never reactivate after a human switch.
                    NSRunningApplication *prior=NSWorkspace.sharedWorkspace.frontmostApplication; NSDate *priorBirth=prior.launchDate;
                    BOOL requested=[router valid]&&[[NSRunningApplication runningApplicationWithProcessIdentifier:router.pid]activateWithOptions:0];
                    report[@"source_activation_requested"]=@(requested); pump(.2);
                    report[@"source_active_for_private"]=@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==router.pid);
                    for(int i=0;i<2&&!stopped;i++)[report[@"attempts"]addObject:attempt(canvas,directory,i,YES)];
                    BOOL restore=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==router.pid && !prior.terminated && [prior.launchDate isEqual:priorBirth];
                    report[@"foreground_restore_attempted"]=@(restore); if(restore)[prior activateWithOptions:0];
                }}
            }
            while(!stopped&&child.running&&-start.timeIntervalSinceNow<seconds)pump(.03);
            report[@"stream_frames"]=@(canvas.frames);report[@"stream_error"]=canvas.streamError?:@"";report[@"input_mappings"]=canvas.inputMappings;
        }else report[@"error"]=@"Exact child window unavailable to ScreenCaptureKit";
    }
    report[@"source_final"]=readJSON([directory stringByAppendingPathComponent:@"source.json"])?:@{};report[@"identity_still_valid"]=@([router valid]);report[@"sent"]=router.sent;
    report[@"foreground_before_cleanup"]=@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    __block BOOL streamStopped=stream==nil;
    [stream stopCaptureWithCompletionHandler:^(NSError *e){(void)e;dispatch_async(dispatch_get_main_queue(),^{streamStopped=YES;});}];
    NSDate *streamDeadline=[NSDate dateWithTimeIntervalSinceNow:2];while(!streamStopped&&streamDeadline.timeIntervalSinceNow>0)pump(.01);
    report[@"stream_stopped"]=@(streamStopped);[window orderOut:nil];[window close];
    if(demo && canvas.previousFocus && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==router.pid && !canvas.previousFocus.terminated && [canvas.previousFocus.launchDate isEqual:canvas.previousFocusBirth]) {
        report[@"foreground_restore_attempted"]=@YES;[canvas.previousFocus activateWithOptions:0];
    }
    if(child.running)[child terminate];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(child.running&&deadline.timeIntervalSinceNow>0)usleep(10000);if(child.running)kill(child.processIdentifier,SIGKILL);[child waitUntilExit];
    if(router.eventSource)CFRelease(router.eventSource);report[@"source_reaped"]=@(!child.running);report[@"source_exit_status"]=@(child.terminationStatus);report[@"signal"]=@(stopped);
    CGPoint pointerAfter=pointer();report[@"pointer_before"]=@[@(pointerBefore.x),@(pointerBefore.y)];report[@"pointer_after"]=@[@(pointerAfter.x),@(pointerAfter.y)];
    NSMutableArray *capabilities=[NSMutableArray array];
    for(int i=0;i<2;i++){BOOL b=NO,t=NO,sc=NO;for(NSDictionary *a in report[@"attempts"])if([a[@"camera"]intValue]==i){b|=[a[@"button_proven"]boolValue];t|=[a[@"text_proven"]boolValue];sc|=[a[@"scroll_proven"]boolValue];}[capabilities addObject:@{@"camera":@(i),@"button":@(b),@"text":@(t),@"scroll":@(sc)}];}
    report[@"controls_by_camera"]=capabilities;report[@"activation_policy"]=@"owned source only, short private keyboard probe or explicit demo click";
    save(report,receipt);return enrolled&&canvas.frames>0?0:2;
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc==1||(argc==2&&!strcmp(argv[1],"--help"))){puts("captured-windows --probe|--demo EMPTY_EVIDENCE_DIRECTORY SECONDS(1..60)\nDefault/help is read-only. Only disposable child and host windows; pre-existing capture + accessibility required.\nOption-drag / Option-wheel pan; Command-wheel / pinch zoom; normal input forwards to child; Escape closes.");return 0;}
    BOOL child=argc==5&&!strcmp(argv[1],"--source"),probe=argc==4&&!strcmp(argv[1],"--probe"),demo=argc==4&&!strcmp(argv[1],"--demo");if(!child&&!probe&&!demo)return 64;
    char *end=NULL;double seconds=strtod(argv[3],&end);if(!end||*end||!isfinite(seconds)||seconds<1||seconds>(child?65:60))return 64;
    NSString *dir=@(argv[2]);BOOL isDir=NO;if(![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir]||!isDir)return 64;
    if(!child&&[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count)return 64;
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [ProbeApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    return child?source(dir,seconds,@(argv[4])):host(dir,seconds,demo,NSBundle.mainBundle.executablePath);
}}
