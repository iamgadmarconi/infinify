// SPDX-License-Identifier: GPL-3.0-or-later
// New bounded AppKit/ScreenCaptureKit feasibility fixture. No upstream code copied.
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreImage/CoreImage.h>
#import <libproc.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>

static volatile sig_atomic_t halted;
static void stop(int s) { halted=s; }
static void save(id object, NSString *file) { [[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil] writeToFile:file atomically:YES]; }
static NSDictionary *load(NSString *file) { NSData *data=[NSData dataWithContentsOfFile:file];return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil; }
static void pump(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    do { NSEvent *e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.005] inMode:NSDefaultRunLoopMode dequeue:YES];if(e)[NSApp sendEvent:e];[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]]; } while(!halted&&end.timeIntervalSinceNow>0);
}
static NSArray *birth(pid_t pid) { struct proc_bsdinfo b={0};return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))==sizeof(b)?@[@(b.pbi_start_tvsec),@(b.pbi_start_tvusec)]:nil; }
static NSDictionary *cg(uint32_t wid) { NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));for(NSDictionary *w in all)if([w[(id)kCGWindowNumber]unsignedIntValue]==wid)return w;return nil; }
static NSArray *rect(CGRect r) {return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
static CGRect fromRect(NSArray *a) { return a.count==4?CGRectMake([a[0]doubleValue],[a[1]doubleValue],[a[2]doubleValue],[a[3]doubleValue]):CGRectZero; }
#include "window-server-family.h"
#include "owned-window-geometry.h"
static NSUInteger untagged;
@interface FamilyApplication : NSApplication
@end
@implementation FamilyApplication
- (void)sendEvent:(NSEvent *)e { if(e.type==NSEventTypeLeftMouseDown||e.type==NSEventTypeKeyDown||e.type==NSEventTypeScrollWheel)untagged++;[super sendEvent:e]; }
@end
@interface ColorView : NSView
@property NSInteger kind;
@property NSInteger phase;
@end
@implementation ColorView
- (void)drawRect:(NSRect)dirty { (void)dirty;[[NSColor colorWithSRGBRed:.15 green:.15 blue:.15 alpha:1]setFill];NSRectFill(self.bounds);
    NSArray *colors=@[NSColor.redColor,NSColor.greenColor,NSColor.blueColor,NSColor.magentaColor];
    [colors[self.kind]setFill];NSRectFill(NSMakeRect(20,20,80,60));
    [(self.phase?NSColor.cyanColor:NSColor.yellowColor)setFill];NSRectFill(NSMakeRect(110,20,40,40));
}
@end
@interface Family : NSObject
@property NSWindow *a;
@property NSWindow *b;
@property NSPanel *panel;
@property NSWindow *sheet;
@property NSInteger actions;
- (void)openPanel:(id)sender;
- (void)closePanel:(id)sender;
- (void)openLeftUpPanel:(id)sender;
- (void)openSheet:(id)sender;
- (void)closeSheet:(id)sender;
@end
static NSWindow *window(NSString *title, NSRect frame, NSInteger kind, BOOL panel) {
    NSWindow *w=panel?[[NSPanel alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO]:[[NSWindow alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed=NO;w.title=title;w.hasShadow=NO;w.animationBehavior=NSWindowAnimationBehaviorNone;
    ColorView *v=[[ColorView alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];v.kind=kind;w.contentView=v;return w;
}
static void button(NSWindow *w, Family *f, NSString *name, SEL action, CGFloat x) { NSButton *b=[NSButton buttonWithTitle:name target:f action:action];b.frame=NSMakeRect(x,110,140,32);b.accessibilityIdentifier=name;[w.contentView addSubview:b]; }
@implementation Family
- (void)openPanel:(id)sender { (void)sender;if(self.panel)return;self.actions++;self.panel=(NSPanel *)window(@"family-child-panel",NSMakeRect(self.a.frame.origin.x+300,self.a.frame.origin.y+30,190,170),2,YES);button(self.panel,self,@"dismiss-panel",@selector(closePanel:),10);[self.a addChildWindow:self.panel ordered:NSWindowAbove];[self.panel orderFront:nil]; }
- (void)openLeftUpPanel:(id)sender { (void)sender;if(self.panel)return;self.actions++;self.panel=(NSPanel *)window(@"family-left-up-panel",NSMakeRect(self.a.frame.origin.x-80,self.a.frame.origin.y+240,190,170),2,YES);button(self.panel,self,@"dismiss-panel",@selector(closePanel:),10);[self.a addChildWindow:self.panel ordered:NSWindowAbove];[self.panel orderFront:nil]; }
- (void)closePanel:(id)sender { (void)sender;if(!self.panel)return;self.actions++;[self.a removeChildWindow:self.panel];[self.panel close];self.panel=nil; }
- (void)openSheet:(id)sender { (void)sender;if(self.sheet)return;self.actions++;self.sheet=window(@"family-child-sheet",NSMakeRect(0,0,220,170),3,NO);button(self.sheet,self,@"dismiss-sheet",@selector(closeSheet:),10);[self.a beginSheet:self.sheet completionHandler:nil]; }
- (void)closeSheet:(id)sender { (void)sender;if(!self.sheet)return;self.actions++;[self.a endSheet:self.sheet];[self.sheet orderOut:nil];[self.sheet close];self.sheet=nil; }
@end
static NSDictionary *identity(NSWindow *w, NSString *kind, NSArray *enrolledBirth) {
    NSDictionary *info=cg((uint32_t)w.windowNumber);CGRect r=CGRectZero;
    if(info)CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&r);
    return @{@"kind":kind,@"id":@(w.windowNumber),@"parent":@(w.parentWindow.windowNumber),
        @"sheet_parent":@(w.sheetParent.windowNumber),@"bounds":rect(r),@"visible":@(w.visible),
        @"bounds_coordinate_basis":@"CG global screen coordinates, top-left origin, y down",
        @"geometry_diagnostic":ownedGeometry((uint32_t)w.windowNumber,getpid(),enrolledBirth,w)};
}
static int source(NSString *dir, NSString *nonce, double seconds) {
    pid_t parent=getppid();if(parent<=1)return 2;NSArray *enrolledBirth=birth(getpid());if(!enrolledBirth)return 2;Family *f=[Family new];f.a=window(@"family-parent-A",NSMakeRect(300,150,360,240),0,NO);f.b=window(@"family-top-B",NSMakeRect(840,150,360,240),1,NO);
    button(f.a,f,@"create-panel",@selector(openPanel:),10);button(f.a,f,@"create-sheet",@selector(openSheet:),170);
    [f.a orderFront:nil];[f.b orderFront:nil];NSDate *start=NSDate.date;
    NSInteger setupPhase=0;
    while(!halted&&getppid()==parent&&-start.timeIntervalSinceNow<seconds) {
        NSInteger desired=MIN(6,(NSInteger)(-start.timeIntervalSinceNow/6));
        if(desired>setupPhase){if(desired==1)[f openPanel:nil];if(desired==2)[f closePanel:nil];if(desired==3)[f openSheet:nil];if(desired==4)[f closeSheet:nil];if(desired==5)[f openLeftUpPanel:nil];if(desired==6)[f closePanel:nil];setupPhase=desired;}
        NSMutableArray *windows=[NSMutableArray array];for(NSWindow *w in @[f.a,f.b,f.panel?:NSNull.null,f.sheet?:NSNull.null])if([w isKindOfClass:NSWindow.class]) { ColorView *v=(ColorView *)w.contentView;v.phase=((NSInteger)(-start.timeIntervalSinceNow*2))%2;v.needsDisplay=YES;[w displayIfNeeded];[windows addObject:identity(w,@[@"parent",@"other-top",@"panel",@"sheet"][v.kind],enrolledBirth)]; }
        save(@{@"pid":@(getpid()),@"birth":enrolledBirth,@"nonce":nonce,@"windows":windows,@"setup_phase":@(setupPhase),@"actions":@(f.actions),@"untagged":@(untagged),@"tick":@(-start.timeIntervalSinceNow)},[dir stringByAppendingPathComponent:@"source.json"]);pump(.05);
    }
    [f closeSheet:nil];[f closePanel:nil];[f.a close];[f.b close];save(@{@"reason":getppid()!=parent?@"parent_exit":halted?@"signal":@"deadline",@"pid":@(getpid())},[dir stringByAppendingPathComponent:@"source-exit.json"]);return 0;
}
// AX identifiers are read only from the spawned process. Window identity is cross-checked
// against CGWindow ownership and SCWindow, rather than inferred from a title.
static id attr(AXUIElementRef element, CFStringRef name) {CFTypeRef v=NULL;return AXUIElementCopyAttributeValue(element,name,&v)==kAXErrorSuccess?CFBridgingRelease(v):nil;}
static AXError (*axWindow)(AXUIElementRef,CGWindowID *);
static void walkAX(AXUIElementRef e, NSMutableArray *out, NSString *wanted, AXUIElementRef *found, int depth, uint32_t parent) {
    if(depth>8||out.count>200)return;uint32_t wid=0;if(axWindow)axWindow(e,&wid);
    NSString *role=attr(e,kAXRoleAttribute)?:@"",*identifier=attr(e,kAXIdentifierAttribute)?:@"";
    [out addObject:@{@"role":role,@"identifier":identifier,@"window":@(wid),@"ancestor_window":@(parent),@"depth":@(depth)}];
    if(wanted&&[identifier isEqual:wanted]&&[role isEqual:(__bridge NSString *)kAXButtonRole]&&!*found)*found=(AXUIElementRef)CFRetain(e);
    NSArray *children=attr(e,depth==0?kAXWindowsAttribute:kAXChildrenAttribute);for(id child in children)walkAX((__bridge AXUIElementRef)child,out,wanted,found,depth+1,wid?:parent);
}
static SCShareableContent *shareable(void) {__block BOOL done=NO;__block SCShareableContent *result=nil;[SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *c,NSError *e){(void)e;dispatch_async(dispatch_get_main_queue(),^{result=c;done=YES;});}];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];while(!done&&!halted&&deadline.timeIntervalSinceNow>0)pump(.01);return result;}
@interface Capture : NSObject <SCStreamOutput,SCStreamDelegate>
@property SCStream *stream;
@property CGImageRef image;
@property NSUInteger frames;
@property NSString *error;
@property BOOL stopped;
@property CGRect bounds;
@property NSString *kind;
@property NSNumber *wid;
@property NSDictionary *metadata;
@property NSDictionary *filterMetadata;
@property NSDictionary *normalization;
@property NSMutableArray *extentChanges;
@property pid_t sourcePID;
@property NSArray *sourceBirth;
@end
@implementation Capture
- (void)dealloc {if(_image)CGImageRelease(_image);}
- (void)stream:(SCStream *)s didStopWithError:(NSError *)e {(void)s;self.error=e.description;}
- (void)stream:(SCStream *)s didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)s;if(type!=SCStreamOutputTypeScreen||!CMSampleBufferIsValid(sample))return;
    NSArray *attachments=CFBridgingRelease(CMSampleBufferGetSampleAttachmentsArray(sample,NO)?CFRetain(CMSampleBufferGetSampleAttachmentsArray(sample,NO)):NULL);
    if([attachments.firstObject[SCStreamFrameInfoStatus]integerValue]!=SCFrameStatusComplete)return;
    NSMutableDictionary *metadata=[NSMutableDictionary dictionary];for(NSString *key in @[SCStreamFrameInfoContentRect,SCStreamFrameInfoScreenRect,SCStreamFrameInfoBoundingRect,SCStreamFrameInfoContentScale,SCStreamFrameInfoScaleFactor])if(attachments.firstObject[key])metadata[key]=attachments.firstObject[key];self.metadata=metadata;
    CVPixelBufferRef buffer=CMSampleBufferGetImageBuffer(sample);if(!buffer)return;
    NSDictionary *m=self.metadata;CGRect screen=CGRectZero,content=CGRectZero;
    BOOL rects=[m[SCStreamFrameInfoScreenRect]isKindOfClass:NSDictionary.class]&&[m[SCStreamFrameInfoContentRect]isKindOfClass:NSDictionary.class]&&
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)m[SCStreamFrameInfoScreenRect],&screen)&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)m[SCStreamFrameInfoContentRect],&content);
    CGFloat scale=[m[SCStreamFrameInfoScaleFactor]doubleValue],contentScale=[m[SCStreamFrameInfoContentScale]doubleValue];
    size_t width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer);
    CGRect pixels=CGRectMake(content.origin.x*scale,content.origin.y*scale,content.size.width*scale,content.size.height*scale);
    BOOL valid=rects&&isfinite(scale)&&isfinite(contentScale)&&scale>0&&contentScale>0&&screen.size.width>0&&screen.size.height>0&&
        isfinite(screen.origin.x)&&isfinite(screen.origin.y)&&isfinite(screen.size.width)&&isfinite(screen.size.height)&&
        isfinite(pixels.origin.x)&&isfinite(pixels.origin.y)&&isfinite(pixels.size.width)&&isfinite(pixels.size.height)&&
        pixels.size.width>0&&pixels.size.height>0&&pixels.origin.x>=-.5&&pixels.origin.y>=-.5&&
        CGRectGetMaxX(pixels)<=(CGFloat)width+.5&&CGRectGetMaxY(pixels)<=(CGFloat)height+.5&&
        content.size.width/contentScale>=screen.size.width-.5&&content.size.height/contentScale>=screen.size.height-.5;
    // Genuine WindowServer associations/parent IDs supply the native origin.
    // The original size still comes independently from frame metadata. A mismatch
    // is an unsupported or transitional frame, never a guessed family mapping.
    NSDictionary *family=discoverOwnedFamily(self.wid.unsignedIntValue,self.sourcePID,self.sourceBirth);
    CGRect native=fromRect(family[@"native_bounds"]);BOOL mapped=valid&&[family[@"valid"]boolValue]&&
        fabs(content.size.width/contentScale-native.size.width)<1&&fabs(content.size.height/contentScale-native.size.height)<1;
    CGRect extent=CGRectMake(native.origin.x,native.origin.y,valid?content.size.width/contentScale:0,valid?content.size.height/contentScale:0);
    NSDictionary *normalization=@{@"valid":@(mapped),@"native_extent":rect(extent),@"screen_rect":rect(screen),@"pixel_rect":rect(pixels),@"buffer_size":@[@(width),@(height)],
        @"pixel_to_native_scale":@(mapped?1/(scale*contentScale):0),@"frame":@(self.frames+1),@"native_family":family};
    if(!self.extentChanges)self.extentChanges=[NSMutableArray array];
    if(![self.normalization[@"native_extent"]isEqual:normalization[@"native_extent"]]||![self.normalization[@"pixel_rect"]isEqual:normalization[@"pixel_rect"]])
        [self.extentChanges addObject:@{@"normalization":normalization,@"metadata":m}];
    CIImage *ci=[CIImage imageWithCVPixelBuffer:buffer];CGImageRef next=[[CIContext contextWithOptions:nil]createCGImage:ci fromRect:ci.extent];
    if(next){if(self.image)CGImageRelease(self.image);self.image=next;self.normalization=normalization;self.frames++;}

}
@end
static Capture *startCapture(SCWindow *window, NSString *kind) {
    Capture *c=[Capture new];c.bounds=window.frame;c.kind=kind;c.wid=@(window.windowID);c.sourcePID=window.owningApplication.processID;c.sourceBirth=birth(c.sourcePID);
    SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:window];
    c.filterMetadata=@{@"content_rect":rect(filter.contentRect),@"point_pixel_scale":@(filter.pointPixelScale),@"style":@(filter.style)};
    SCStreamConfiguration *config=[SCStreamConfiguration new];
    config.width=(size_t)ceil(filter.contentRect.size.width*filter.pointPixelScale);
    config.height=(size_t)ceil(filter.contentRect.size.height*filter.pointPixelScale);
    config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;config.pixelFormat=kCVPixelFormatType_32BGRA;
    config.minimumFrameInterval=CMTimeMake(1,15);config.queueDepth=3;
    c.stream=[[SCStream alloc]initWithFilter:filter configuration:config delegate:c];NSError *e=nil;
    if(![c.stream addStreamOutput:c type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&e])c.error=e.description;
    [c.stream startCaptureWithCompletionHandler:^(NSError *error){if(error)dispatch_async(dispatch_get_main_queue(),^{c.error=error.description;});}];return c;
}
static NSDictionary *finishCapture(Capture *c) {__block BOOL done=NO;[c.stream stopCaptureWithCompletionHandler:^(NSError *e){dispatch_async(dispatch_get_main_queue(),^{if(e&&!c.error)c.error=e.description;done=YES;});}];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(!done&&deadline.timeIntervalSinceNow>0)pump(.01);c.stopped=done;[c.stream removeStreamOutput:c type:SCStreamOutputTypeScreen error:nil];c.stream=nil;return @{@"id":c.wid,@"kind":c.kind,@"frames":@(c.frames),@"stop_completed":@(done),@"error":c.error?:@"",@"extent_changes":c.extentChanges?:@[]};}
static void png(CGImageRef image, NSString *path) {NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]initWithCGImage:image];[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:path atomically:YES];}
static NSDictionary *render(NSArray<Capture *> *captures, NSString *dir, NSString *name) {
    const size_t width=1040,height=520;CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGContextRef ctx=CGBitmapContextCreate(NULL,width,height,8,width*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);CGContextSetRGBFillColor(ctx,.05,.05,.05,1);CGContextFillRect(ctx,CGRectMake(0,0,width,height));
    // Top-down source/display coordinates: each exact SCWindow image keeps its measured
    // relative position; both cameras have independent pan and scale and hard clipping.
    CGContextTranslateCTM(ctx,0,height);CGContextScaleCTM(ctx,1,-1);NSMutableArray *views=[NSMutableArray array];CGRect origin=captures.firstObject.bounds;
    for(int i=0;i<2;i++){CGRect clip=CGRectMake(i?540:20,20,480,i?180:480);CGFloat zoom=i?.75:.6;CGPoint pan=i?CGPointMake(0,-10):CGPointMake(-20,-30);CGContextSaveGState(ctx);CGContextClipToRect(ctx,clip);NSMutableArray *placements=[NSMutableArray array];
        for(Capture *c in captures){CGRect b=fromRect(c.normalization[@"native_extent"]);CGRect dest=CGRectMake(clip.origin.x+(b.origin.x-origin.origin.x-pan.x)*zoom,clip.origin.y+(b.origin.y-origin.origin.y-pan.y)*zoom,b.size.width*zoom,b.size.height*zoom);
            if(c.image&&[c.normalization[@"valid"]boolValue]){
                CGRect pixel=fromRect(c.normalization[@"pixel_rect"]);CGFloat sx=dest.size.width/pixel.size.width,sy=dest.size.height/pixel.size.height;
                CGRect imageDest=CGRectMake(dest.origin.x-pixel.origin.x*sx,dest.origin.y-pixel.origin.y*sy,CGImageGetWidth(c.image)*sx,CGImageGetHeight(c.image)*sy);
                CGContextSaveGState(ctx);CGContextClipToRect(ctx,dest);CGContextTranslateCTM(ctx,imageDest.origin.x,imageDest.origin.y+imageDest.size.height);
                CGContextScaleCTM(ctx,1,-1);CGContextDrawImage(ctx,CGRectMake(0,0,imageDest.size.width,imageDest.size.height),c.image);CGContextRestoreGState(ctx);
            }
            [placements addObject:@{@"id":c.wid,@"kind":c.kind,@"destination":rect(dest),@"native_bounds":rect(b),@"frames":@(c.frames),@"stream_metadata":c.metadata?:@{},@"filter_metadata":c.filterMetadata?:@{},@"normalization":c.normalization?:@{}}];
        }CGContextRestoreGState(ctx);[views addObject:@{@"clip":rect(clip),@"zoom":@(zoom),@"pan":@[@(pan.x),@(pan.y)],@"placements":placements}];
    }CGImageRef image=CGBitmapContextCreateImage(ctx);png(image,[dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]);CGImageRelease(image);CGContextRelease(ctx);CGColorSpaceRelease(space);
    for(Capture *c in captures)if(c.image)png(c.image,[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.png",name,c.kind]]);
    return @{@"name":name,@"views":views};
}
static BOOL guarded(NSDictionary *s,NSTask *child,NSArray *enrolled,NSString *nonce,pid_t foreground) {return !halted&&child.running&&[s[@"pid"]intValue]==child.processIdentifier&&[s[@"nonce"]isEqual:nonce]&&[s[@"birth"]isEqual:enrolled]&&[birth(child.processIdentifier)isEqual:enrolled]&&![s[@"untagged"]unsignedIntegerValue]&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==foreground;}
static int host(NSString *dir,NSString *executable) {
    NSMutableDictionary *report=[@{@"permission_requests":@0,@"activation_requests":@0,@"global_input_posts":@0,@"source_custom_surface_exports":@0,@"control_route":@"Passive scheduled fixture setup invokes the real AppKit actions; native buttons retained, AXPress/pointer/keyboard parity NOT proven",@"capture_route":@"One desktopIndependentWindow stream per explicitly selected root; normalize each frame from SCK screenRect, contentRect, contentScale, scaleFactor and buffer dimensions; native origin from verified WindowServer parent/association IDs and CG bounds; no child streams or display fallback",@"stages":[NSMutableArray array],@"controls":[NSMutableArray array],@"closed_streams":[NSMutableArray array]}mutableCopy];
    report[@"runtime"]=@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"architecture":@"arm64",@"private_abi_provenance":@"yabai dd845723416f5fe92af49fad5ebab00369e07edd"};
    if(!CGPreflightScreenCaptureAccess()||!AXIsProcessTrusted()){report[@"failure"]=@"Existing screen capture and accessibility permissions required; no prompts requested";save(report,[dir stringByAppendingPathComponent:@"receipt.json"]);return 2;}
    NSTask *child=[NSTask new];NSString *nonce=NSUUID.UUID.UUIDString;child.executableURL=[NSURL fileURLWithPath:executable];child.arguments=@[@"--source",dir,nonce];NSError *error=nil;if(![child launchAndReturnError:&error])return 2;
    pid_t foreground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;report[@"foreground_pid"]=@(foreground);report[@"source_pid"]=@(child.processIdentifier);
    NSString *statePath=[dir stringByAppendingPathComponent:@"source.json"];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:45];NSDictionary *state=nil;for(int n=0;n<100&&child.running&&!halted;n++){state=load(statePath);if([state[@"windows"]count]==2)break;pump(.03);}NSArray *enrolled=state[@"birth"];
    AXUIElementRef app=AXUIElementCreateApplication(child.processIdentifier);AXUIElementSetMessagingTimeout(app,1);axWindow=dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");NSMutableDictionary<NSNumber *,Capture *> *streams=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSDictionary *> *priorChildren=[NSMutableDictionary dictionary];BOOL okay=YES;
    NSArray *names=@[@"baseline",@"panel",@"panel-dismissed",@"sheet",@"sheet-dismissed",@"left-up-panel",@"left-up-dismissed"];
    pump(.4);
    for(NSUInteger phase=0;phase<names.count&&okay;phase++) {
        do {pump(.03);state=load(statePath);} while([state[@"setup_phase"]unsignedIntegerValue]<phase&&guarded(state,child,enrolled,nonce,foreground)&&deadline.timeIntervalSinceNow>0);
        if(!guarded(state,child,enrolled,nonce,foreground)||deadline.timeIntervalSinceNow<=0){report[@"failure"]=@"Owned identity, foreground, input guard or deadline interrupted";report[@"guard_failure_source_snapshot"]=state?:@{};okay=NO;break;}
        pump(.3);state=load(statePath);
        SCShareableContent *content=shareable();NSMutableArray *selected=[NSMutableArray array],*observed=[NSMutableArray array],*ax=[NSMutableArray array];AXUIElementRef unused=NULL;walkAX(app,ax,nil,&unused,0,0);
        NSMutableSet *live=[NSMutableSet set];for(NSDictionary *s in state[@"windows"]) {
            NSNumber *wid=s[@"id"];SCWindow *match=nil;for(SCWindow *w in content.windows)if(w.windowID==wid.unsignedIntValue&&w.owningApplication.processID==child.processIdentifier)match=w;
            NSDictionary *info=cg(wid.unsignedIntValue);BOOL identity=match&&[info[(id)kCGWindowOwnerPID]intValue]==child.processIdentifier&&CGRectEqualToRect(match.frame,fromRect(s[@"bounds"]));
            NSMutableDictionary *record=[s mutableCopy];record[@"cg_owner"]=info[(id)kCGWindowOwnerPID]?:@0;record[@"sc_found"]=@(match!=nil);record[@"identity_verified"]=@(identity);record[@"sc_bounds"]=match?rect(match.frame):@[];CGRect liveBounds=CGRectZero;if(info)CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&liveBounds);record[@"cg_bounds"]=rect(liveBounds);record[@"host_geometry_diagnostic"]=ownedGeometry(wid.unsignedIntValue,child.processIdentifier,enrolled,nil);[observed addObject:record];
            if(!identity){report[@"failure"]=[NSString stringWithFormat:@"Native %@ window unavailable or mismatched in SC/CG",s[@"kind"]];okay=NO;continue;}
            [live addObject:wid];
            // The two roots are explicitly enrolled at baseline. Fixture parent IDs
            // never select streams or derive their captured extent.
            if(phase==0){Capture *c=startCapture(match,s[@"kind"]);streams[wid]=c;}
            if(streams[wid])[selected addObject:streams[wid]];
        }
        for(NSNumber *wid in streams.allKeys)if(![live containsObject:wid]){report[@"failure"]=@"Enrolled root disappeared";okay=NO;}
        NSMutableArray *dismissed=[NSMutableArray array];
        for(NSNumber *wid in priorChildren)if(![live containsObject:wid]){BOOL present=NO;for(SCWindow *w in content.windows)if(w.windowID==wid.unsignedIntValue)present=YES;
            [dismissed addObject:@{@"id":wid,@"kind":priorChildren[wid][@"kind"],@"cg_absent":@(cg(wid.unsignedIntValue)==nil),@"sc_still_enumerated":@(present)}];}
        [priorChildren removeAllObjects];for(NSDictionary *w in observed)if(!streams[w[@"id"]])priorChildren[w[@"id"]]=w;
        NSMutableDictionary *stage=[@{@"name":names[phase],@"source":state?:@{},@"windows":observed,@"ax":ax,@"dismissed":dismissed,@"frames":[NSMutableArray array]}mutableCopy];[report[@"stages"]addObject:stage];
        if(!okay)break;
        if(selected.count!=2){okay=NO;report[@"failure"]=@"Expected exactly two enrolled root streams";break;}
        for(int sample=0;sample<4;sample++){
            pump(.65);NSDictionary *current=load(statePath);BOOL stable=[current[@"setup_phase"]unsignedIntegerValue]==phase&&[current[@"windows"]count]==observed.count;
            for(NSDictionary *expected in observed){BOOL found=NO;for(NSDictionary *now in current[@"windows"])if([now[@"id"]isEqual:expected[@"id"]]&&[now[@"bounds"]isEqual:expected[@"bounds"]])found=YES;stable&=found;}
            for(Capture *c in selected){NSDictionary *now=cg(c.wid.unsignedIntValue);CGRect actual=CGRectZero;if(now)CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)now[(id)kCGWindowBounds],&actual);stable&=CGRectEqualToRect(actual,c.bounds);}
            if(!stable||!guarded(current,child,enrolled,nonce,foreground)){okay=NO;report[@"failure"]=@"Native bounds, human input or foreground changed during capture";report[@"guard_failure_source_snapshot"]=current?:@{};break;}
            NSString *name=[NSString stringWithFormat:@"%@-%d",names[phase],sample];
            [stage[@"frames"]addObject:render(selected,dir,name)];
            for(Capture *c in selected)if(![c.normalization[@"valid"]boolValue]||c.error){okay=NO;report[@"failure"]=@"Frame metadata cannot substantiate a native extent mapping";}
            if(!okay)break;
        }

    }
    for(Capture *c in streams.allValues)[report[@"closed_streams"]addObject:finishCapture(c)];CFRelease(app);
    report[@"foreground_after"]=@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);report[@"source_final"]=load(statePath)?:@{};
    if(child.running)[child terminate];NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2];while(child.running&&end.timeIntervalSinceNow>0)usleep(10000);if(child.running)kill(child.processIdentifier,SIGKILL);[child waitUntilExit];report[@"source_reaped"]=@(!child.running);report[@"source_exit_status"]=@(child.terminationStatus);report[@"signal"]=@(halted);report[@"capture_sequence_completed"]=@(okay);save(report,[dir stringByAppendingPathComponent:@"receipt.json"]);return okay?0:2;
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc==1||(argc==2&&!strcmp(argv[1],"--help"))){puts("native-families --probe EMPTY_DIRECTORY\nBounded owned AppKit family capture gate; pre-existing permissions only. No activation or key input. Default is read-only.");return 0;}
    BOOL src=(argc==4||argc==5)&&!strcmp(argv[1],"--source"),probe=argc==3&&!strcmp(argv[1],"--probe");if(!src&&!probe)return 64;NSString *dir=@(argv[2]);BOOL directory=NO;if(![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&directory]||!directory||(!src&&[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count))return 64;
    double seconds=50;if(src&&argc==5){char *end=NULL;seconds=strtod(argv[4],&end);if(!end||*end||!isfinite(seconds)||seconds<1||seconds>50)return 64;}
    signal(SIGTERM,stop);signal(SIGINT,stop);signal(SIGHUP,stop);[FamilyApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];return src?source(dir,@(argv[3]),seconds):host(dir,NSBundle.mainBundle.executablePath);
}}
