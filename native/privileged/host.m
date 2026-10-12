// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <signal.h>
#include <math.h>
#import "protocol.h"
// This opt-in load measures the actual presented timestamps of each owned
// native content drawable. It does not observe the final transformed screen
// pixels. The ordinary restoration/protocol fixture remains static.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <libproc.h>
#import <os/lock.h>
#include <fcntl.h>
#include <unistd.h>

#define DW_HOST_PRESENTATIONS 4096
struct DWHostPresentation { uint64_t sequence, frame; double time; };
@interface DWHostProducerStats : NSObject {
@public
    os_unfair_lock lock;
    uint64_t offered, encoded, completed, errors, zero, presented, reported;
    struct DWHostPresentation samples[DW_HOST_PRESENTATIONS];
}
- (NSDictionary *)snapshot;
@end
@implementation DWHostProducerStats
- (instancetype)init { if((self=[super init]))lock=OS_UNFAIR_LOCK_INIT;return self; }
- (NSDictionary *)snapshot {
    struct DWHostPresentation recent[DW_HOST_PRESENTATIONS];
    os_unfair_lock_lock(&lock);
    uint64_t available=presented-reported,count=MIN(available,(uint64_t)DW_HOST_PRESENTATIONS),first=presented-count;
    reported=presented;double sampled=CACurrentMediaTime();
    for(uint64_t i=0;i<count;i++)recent[i]=samples[(first+i)%DW_HOST_PRESENTATIONS];
    uint64_t a=offered,b=encoded,c=completed,d=errors,e=zero,f=presented;
    os_unfair_lock_unlock(&lock);
    NSMutableArray *times=[NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for(uint64_t i=0;i<count;i++)[times addObject:@[@(recent[i].sequence),@(recent[i].time),@(recent[i].frame)]];
    return @{@"offered":@(a),@"encoded":@(b),@"completed":@(c),@"errors":@(d),@"zero_presented_time":@(e),@"presented":@(f),@"sample_capacity":@(DW_HOST_PRESENTATIONS),@"overflow":@(available>count),@"monotonic_s":@(sampled),@"samples":times};
}
@end

@interface DWHostProducer : NSView <CAMetalDisplayLinkDelegate>
@property id<MTLDevice> device;
@property id<MTLCommandQueue> commands;
@property id<MTLRenderPipelineState> pipeline;
@property CAMetalDisplayLink *clock;
@property DWHostProducerStats *counts;
@property uint32_t patternIndex;
@property uint64_t frameNumber;
- (void)start;
- (NSDictionary *)snapshot;
@end
@implementation DWHostProducer
- (instancetype)initWithFrame:(NSRect)frame {if((self=[super initWithFrame:frame]))_counts=[DWHostProducerStats new];return self;}
- (BOOL)isOpaque {return YES;}
- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer=[CAMetalLayer layer];layer.device=self.device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly=YES;layer.opaque=YES;layer.presentsWithTransaction=NO;return layer;
}
- (void)raster {
    if(![self.layer isKindOfClass:CAMetalLayer.class])return;
    CAMetalLayer *layer=(CAMetalLayer *)self.layer;double scale=self.window.backingScaleFactor;
    if(!(scale>0))scale=2;layer.contentsScale=scale;
    layer.drawableSize=CGSizeMake(MAX(1,ceil(self.bounds.size.width*scale)),MAX(1,ceil(self.bounds.size.height*scale)));
}
- (void)viewDidMoveToWindow {[super viewDidMoveToWindow];[self raster];}
- (void)viewDidChangeBackingProperties {[super viewDidChangeBackingProperties];[self raster];}
- (void)setFrameSize:(NSSize)size {[super setFrameSize:size];[self raster];}
- (void)start {
    [self raster];self.clock=[[CAMetalDisplayLink alloc]initWithMetalLayer:(CAMetalLayer *)self.layer];
    self.clock.delegate=self;self.clock.preferredFrameRateRange=CAFrameRateRangeMake(120,120,120);
    [self.clock addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    (void)link;DWHostProducerStats *counts=self.counts;
    os_unfair_lock_lock(&counts->lock);counts->offered++;os_unfair_lock_unlock(&counts->lock);
    // The display link supplies an available drawable: no main-thread
    // nextDrawable, semaphore wait, queued frame description or CPU upload.
    id<CAMetalDrawable> drawable=update.drawable;if(!drawable)return;
    id<MTLCommandBuffer> command=[self.commands commandBuffer];if(!command)return;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder)return;
    uint64_t serial=++self.frameNumber;uint32_t values[2]={(uint32_t)serial,self.patternIndex};
    [encoder setRenderPipelineState:self.pipeline];[encoder setFragmentBytes:values length:sizeof(values) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[encoder endEncoding];
    os_unfair_lock_lock(&counts->lock);counts->encoded++;os_unfair_lock_unlock(&counts->lock);
    [drawable addPresentedHandler:^(id<MTLDrawable> shown){double time=shown.presentedTime;
        os_unfair_lock_lock(&counts->lock);
        if(isfinite(time)&&time>0){uint64_t sequence=++counts->presented;counts->samples[(sequence-1)%DW_HOST_PRESENTATIONS]=(struct DWHostPresentation){sequence,serial,time};}
        else counts->zero++;
        os_unfair_lock_unlock(&counts->lock);
    }];
    [command addCompletedHandler:^(id<MTLCommandBuffer> done){os_unfair_lock_lock(&counts->lock);counts->completed++;counts->errors+=done.status==MTLCommandBufferStatusError;os_unfair_lock_unlock(&counts->lock);}];
    [command commit];[drawable present];
}
- (NSDictionary *)snapshot {
    NSMutableDictionary *record=[[self.counts snapshot]mutableCopy];CAMetalLayer *layer=(CAMetalLayer *)self.layer;
    record[@"window"]=@(self.window.windowNumber);record[@"pixels"]=@[@(layer.drawableSize.width),@(layer.drawableSize.height)];
    record[@"points"]=@[@(self.bounds.size.width),@(self.bounds.size.height)];record[@"requested_rate"]=@120;
    return record;
}
- (void)dealloc {[_clock invalidate];}
@end

static id<MTLRenderPipelineState> producerPipeline(id<MTLDevice> device,NSError **error) {
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 position [[position]]; float2 uv; };\n"
        "vertex V vertex_main(uint id [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return {float4(p[id],0,1),p[id]*.5+.5}; }\n"
        "fragment float4 fragment_main(V v [[stage_in]],constant uint2 &n [[buffer(0)]]) { "
        "float3 c=float3(.04,.24+.025*(n.y%5),.26);float y=fract(float(n.x%720)/720.0);"
        "if(abs(v.uv.y-y)<.02)c=float3(.96,.72,.08);"
        "if(v.uv.y>.94&&v.uv.x<.5){uint bit=min(uint(v.uv.x*48),23u);c=float3((n.x>>bit)&1u);}"
        "return float4(c,1);}\n";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:error];if(!library)return nil;
    MTLRenderPipelineDescriptor *description=[MTLRenderPipelineDescriptor new];
    description.vertexFunction=[library newFunctionWithName:@"vertex_main"];description.fragmentFunction=[library newFunctionWithName:@"fragment_main"];
    description.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    return [device newRenderPipelineStateWithDescriptor:description error:error];
}

int main(int argc,char **argv) { @autoreleasepool {
    // Trailing flags give the sole protocol v2 server several owned windows;
    // without them the host creates one window. `--activation regular` makes it
    // an application a window manager adopts (a regular one, whose windows have a
    // close, a miniaturize and a resize control) and `--watchdog` gives a longer test
    // its time; neither changes which windows there are or how the helper starts.
    int count=1,v2Queue=-1,watchdog=90,level=NSNormalWindowLevel;BOOL animate=NO;double alpha=1;BOOL several=NO,bad=NO,regular=NO,opaque=YES,allSpaces=NO,floating=NO;NSString *family=@"none";NSSize contentSize=NSZeroSize;
    while(argc>=6 && (!strcmp(argv[argc-2],"--windows") || !strcmp(argv[argc-2],"--size") || !strcmp(argv[argc-2],"--v2-queue") || !strcmp(argv[argc-2],"--activation") || !strcmp(argv[argc-2],"--watchdog") || !strcmp(argv[argc-2],"--level") || !strcmp(argv[argc-2],"--alpha") || !strcmp(argv[argc-2],"--opaque") || !strcmp(argv[argc-2],"--all-spaces") || !strcmp(argv[argc-2],"--family") || !strcmp(argv[argc-2],"--floating-panel") || !strcmp(argv[argc-2],"--animate"))) {
        if(!strcmp(argv[argc-2],"--animate")){if(!strcmp(argv[argc-1],"120"))animate=YES;else bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--size")){char *end=NULL,*tail=NULL;double width=strtod(argv[argc-1],&end),height=0;
            if(end==argv[argc-1]||*end!='x')bad=YES;
            else {height=strtod(end+1,&tail);if(tail==end+1||*tail||!isfinite(width)||!isfinite(height)||width<40||height<40||width>8192||height>8192)bad=YES;else contentSize=NSMakeSize(width,height);}
            argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--floating-panel")){if(!strcmp(argv[argc-1],"yes"))floating=YES;else if(!strcmp(argv[argc-1],"no"))floating=NO;else bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--family")){family=@(argv[argc-1]);if(![@[@"none",@"popup",@"sheet",@"both"]containsObject:family])bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--activation")){if(!strcmp(argv[argc-1],"regular"))regular=YES;else if(strcmp(argv[argc-1],"accessory"))bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--watchdog")){watchdog=atoi(argv[argc-1]);argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--level")){char *end=NULL;long value=strtol(argv[argc-1],&end,10);if(end==argv[argc-1]||*end||value<NSNormalWindowLevel||value>NSFloatingWindowLevel+1)bad=YES;else level=(int)value;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--alpha")){char *end=NULL;double value=strtod(argv[argc-1],&end);if(end==argv[argc-1]||*end||!isfinite(value)||value<0||value>1)bad=YES;else alpha=value;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--opaque")){if(!strcmp(argv[argc-1],"yes"))opaque=YES;else if(!strcmp(argv[argc-1],"no"))opaque=NO;else bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--all-spaces")){if(!strcmp(argv[argc-1],"yes"))allSpaces=YES;else if(!strcmp(argv[argc-1],"no"))allSpaces=NO;else bad=YES;argc-=2;continue;}
        if(!strcmp(argv[argc-2],"--windows"))count=atoi(argv[argc-1]);
        else if(!strcmp(argv[argc-1],"own"))v2Queue=0;
        else if(!strcmp(argv[argc-1],"main"))v2Queue=1;
        else bad=YES;
        several=YES;argc-=2;
    }
    BOOL popup=[family isEqual:@"popup"]||[family isEqual:@"both"],sheet=[family isEqual:@"sheet"]||[family isEqual:@"both"];
    if((argc!=4 && argc!=5) || bad || count<1 || count+(popup?1:0)+(sheet?1:0)>16 || watchdog<1 || watchdog>900){fprintf(stderr,"usage: host payload.dylib private-runtime nonce [allowlist.json] [--windows 1..16] [--size WIDTHxHEIGHT (40..8192 points)] [--v2-queue own|main] [--activation accessory|regular] [--watchdog 1..900] [--level 0..4] [--alpha 0..1] [--opaque yes|no] [--all-spaces yes|no] [--family none|popup|sheet|both] [--floating-panel yes|no] [--animate 120]\n");return 2;}
    [NSApplication sharedApplication];[NSApp setActivationPolicy:regular ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory];
    NSWindowStyleMask style=regular ? NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable : NSWindowStyleMaskTitled;
    id<MTLDevice> producerDevice=animate?MTLCreateSystemDefaultDevice():nil;
    id<MTLCommandQueue> producerCommands=animate?[producerDevice newCommandQueue]:nil;NSError *producerError=nil;
    id<MTLRenderPipelineState> producerState=animate?producerPipeline(producerDevice,&producerError):nil;
    if(animate&&(!producerDevice||!producerCommands||!producerState)){fprintf(stderr,"owned producer setup failed: %s\n",producerError.localizedDescription.UTF8String?:"Metal unavailable");return 1;}
    NSMutableArray<DWHostProducer *> *producers=[NSMutableArray array];
    NSMutableArray<NSWindow *> *windows=[NSMutableArray array];
    uint32_t wids[16];
    for(int i=0;i<count;i++) {
        // One window where it always was; several as a grid of small ones.
        NSRect frame=several ? NSMakeRect(80+(i%4)*340,160+(i/4)*240,320,200) : NSMakeRect(80,160,480,320);
        // Only explicitly requested disposable windows change size; protocol
        // fixtures retain their original small defaults. Readback records the
        // actual native frame before any helper transform is submitted.
        if(contentSize.width>0)frame.size=contentSize;
        BOOL panel=floating&&i==count-1;
        NSWindow *window=[[(panel?NSPanel.class:NSWindow.class) alloc] initWithContentRect:frame styleMask:style|(panel?NSWindowStyleMaskUtilityWindow:0) backing:NSBackingStoreBuffered defer:NO];
        window.level=panel?NSFloatingWindowLevel:level;
        if(panel){((NSPanel *)window).hidesOnDeactivate=NO;window.title=@"DriftWM disposable independent floating panel";}
        // Set through AppKit before ordering only these newly created windows.
        // The helper's restoration oracle captures this initial alpha afterward.
        window.alphaValue=alpha;
        // Opaque-region diagnosis changes only this owned window before ordering;
        // alpha and the helper's transform/alpha restoration contract stay separate.
        window.opaque=opaque;
        // The controlled performance fixture may remain visible across Spaces.
        // Set only these newly constructed windows; no Space is switched.
        if(allSpaces)window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;
        if(!panel)window.title=several ? [NSString stringWithFormat:@"DriftWM disposable fixture %d",i+1] : @"DriftWM disposable privileged-helper fixture";
        if(animate){DWHostProducer *producer=[[DWHostProducer alloc]initWithFrame:window.contentView.bounds];
            producer.device=producerDevice;producer.commands=producerCommands;producer.pipeline=producerState;producer.patternIndex=(uint32_t)i;
            producer.wantsLayer=YES;window.contentView=producer;[producers addObject:producer];
        }else{NSTextField *label=[NSTextField labelWithString:@"Disposable helper transport / restoration fixture"];
            label.frame=several ? NSMakeRect(10,80,300,40) : NSMakeRect(20,130,440,40);[window.contentView addSubview:label];}
        [window orderFrontRegardless];
        [windows addObject:window];wids[i]=(uint32_t)window.windowNumber;
    }
    // Optional, explicitly created child windows. Their real WindowServer
    // parent links, rather than these AppKit references, are what the desktop
    // must independently discover. Every child is in the helper's finite list.
    if(popup){NSWindow *root=windows[0];NSPanel *child=[[NSPanel alloc]initWithContentRect:NSMakeRect(root.frame.origin.x-70,NSMaxY(root.frame)-20,190,150) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];child.title=@"DriftWM disposable child popup";child.level=level;child.alphaValue=alpha;child.opaque=opaque;child.hidesOnDeactivate=NO;if(allSpaces)child.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;child.contentView.wantsLayer=YES;child.contentView.layer.backgroundColor=NSColor.systemOrangeColor.CGColor;[root addChildWindow:child ordered:NSWindowAbove];[child orderFrontRegardless];wids[count++]=(uint32_t)child.windowNumber;[windows addObject:child];}
    if(sheet){NSWindow *child=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,220,170) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];child.title=@"DriftWM disposable child sheet";child.alphaValue=alpha;child.opaque=opaque;child.contentView.wantsLayer=YES;child.contentView.layer.backgroundColor=NSColor.systemBlueColor.CGColor;[windows[0]beginSheet:child completionHandler:nil];wids[count++]=(uint32_t)child.windowNumber;[windows addObject:child];}
    [NSApp finishLaunching];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    // An optional allowlist file exercises exact process-scope refusal.
    NSString *allowlist=argc==5 ? [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[4]] encoding:NSUTF8StringEncoding error:NULL] : nil;
    if(argc==5 && !allowlist){fprintf(stderr,"cannot read allowlist file %s\n",argv[4]);return 1;}
    void *handle=dlopen(argv[1],RTLD_LOCAL|RTLD_NOW);
    if(!handle){fprintf(stderr,"dlopen: %s\n",dlerror());return 1;}
    int status=-1;
    int (*start)(const char *,const char *,const uint32_t *,uint32_t,const char *,int)=dlsym(handle,popup||sheet?"dw_privileged_fixture_start_family_windows":"dw_privileged_fixture_start_windows");
    if(start)status=start(argv[2],argv[3],wids,(uint32_t)count,allowlist ? allowlist.UTF8String : NULL,v2Queue);
    if(status){fprintf(stderr,"helper fixture start failed: %d\n",status);return 1;}
    dispatch_source_t reports=nil;
    if(animate){
        // Only explicit boundary requests publish telemetry. No per-frame file,
        // IPC, native getter or JSON work runs in a producer callback.
        NSString *runtime=@(argv[2]),*requestPath=[runtime stringByAppendingPathComponent:@"producer-request"];
        int requestFD=open(requestPath.fileSystemRepresentation,O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
        uint64_t initialRequest=0;
        if(requestFD<0||write(requestFD,&initialRequest,sizeof(initialRequest))!=sizeof(initialRequest)){
            if(requestFD>=0)close(requestFD);fprintf(stderr,"cannot create private producer telemetry request\n");return 1;
        }
        reports=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,(uintptr_t)requestFD,DISPATCH_VNODE_WRITE,dispatch_get_main_queue());
        if(!reports){close(requestFD);fprintf(stderr,"cannot watch private producer telemetry request\n");return 1;}
        NSString *path=[runtime stringByAppendingPathComponent:@"producer-stats.json"];__block uint64_t report=0;
        dispatch_source_set_event_handler(reports,^{@autoreleasepool{
            uint64_t request=0;if(pread(requestFD,&request,sizeof(request),0)!=sizeof(request)||request<=report)return;
            struct proc_bsdinfo process={0};if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process))return;
            NSMutableArray *rows=[NSMutableArray arrayWithCapacity:producers.count];for(DWHostProducer *producer in producers)[rows addObject:[producer snapshot]];
            report=request;NSDictionary *snapshot=@{@"pid":@(getpid()),@"birth_sec":@(process.pbi_start_tvsec),@"birth_usec":@(process.pbi_start_tvusec),@"report":@(report),@"monotonic_s":@(CACurrentMediaTime()),@"windows":rows};
            NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];if(data)[data writeToFile:path options:NSDataWritingAtomic error:nil];
        }});dispatch_source_set_cancel_handler(reports,^{close(requestFD);});dispatch_resume(reports);
        for(DWHostProducer *producer in producers)[producer start];
    }
    printf("READY %d",getpid());for(int i=0;i<count;i++)printf(" %u",wids[i]);printf("\n");fflush(stdout);
    // Watchdog bounds fixture lifetime even if the test runner dies. Payload restores
    // controller disconnect first; closing the process removes its own fixture window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)watchdog*NSEC_PER_SEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
    [NSApp run];for(DWHostProducer *producer in producers)[producer.clock invalidate];if(reports)dispatch_source_cancel(reports);return 0;
} }
