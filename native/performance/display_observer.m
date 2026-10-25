// SPDX-License-Identifier: GPL-3.0-or-later
// Independent, selected-window display capture. No native mutations or prompts.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CommonCrypto/CommonDigest.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <libproc.h>
#include <dlfcn.h>
#include <arm_neon.h>

typedef struct { size_t left,top,right,bottom,count; } MarkerBounds;
static MarkerBounds markerBounds(const uint8_t *data,size_t width,size_t height,size_t stride) {
    MarkerBounds bounds={.left=width,.top=height};
    const uint8x16_t high=vdupq_n_u8(190),green=vdupq_n_u8(65);
    for(size_t y=0;y<height;y++){
        const uint8_t *row=data+y*stride;size_t x=0;BOOL found=NO;
        // Deinterleave all16 BGRA pixels. Every lane uses exactly the scalar
        // predicate below; no spatial downsampling or changed colour threshold.
        for(;width-x>=16;x+=16){
            uint8x16x4_t pixels=vld4q_u8(row+4*x);
            uint8x16_t hit=vandq_u8(vandq_u8(vcgtq_u8(pixels.val[0],high),vcltq_u8(pixels.val[1],green)),
                                   vandq_u8(vcgtq_u8(pixels.val[2],high),vcgtq_u8(pixels.val[3],high)));
            uint64x2_t mask=vreinterpretq_u64_u8(hit);
            uint64_t low=vgetq_lane_u64(mask,0),upper=vgetq_lane_u64(mask,1);
            if(!(low|upper))continue;
            // Apple Silicon is little-endian: one nonzero mask byte per matching
            // pixel, so byte indices give the exact inclusive first/last lanes.
            size_t first=low?(size_t)__builtin_ctzll(low)/8:8+(size_t)__builtin_ctzll(upper)/8;
            size_t last=upper?8+(63-(size_t)__builtin_clzll(upper))/8:(63-(size_t)__builtin_clzll(low))/8;
            bounds.left=MIN(bounds.left,x+first);bounds.right=MAX(bounds.right,x+last);
            bounds.count+=(size_t)vaddvq_u8(vshrq_n_u8(hit,7));found=YES;
        }
        for(;x<width;x++){
            const uint8_t *pixel=row+4*x;
            if(pixel[0]>190&&pixel[1]<65&&pixel[2]>190&&pixel[3]>190){
                bounds.left=MIN(bounds.left,x);bounds.right=MAX(bounds.right,x);bounds.count++;found=YES;
            }
        }
        if(found){bounds.top=MIN(bounds.top,y);bounds.bottom=y;}
    }
    return bounds;
}

// Read metadata only, never pixels from an unlisted application. A fixture-only
// display filter can reconstruct a physically occluded window; this separate
// front-to-back witness conservatively refuses that case.
static BOOL unobscured(uint32_t marker,CGRect captured) {
    static int(*connection)(void);static CGError(*rect)(int,uint32_t,CGRect *);static dispatch_once_t once;
    dispatch_once(&once,^{void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);if(sky){connection=dlsym(sky,"SLSMainConnectionID");rect=dlsym(sky,"SLSGetScreenRectForWindow");}});
    if(!connection||!rect)return NO;
    CFArrayRef raw=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);if(!raw)return NO;
    BOOL found=NO,clear=YES;
    for(NSDictionary *row in (__bridge NSArray *)raw){
        uint32_t wid=[row[(id)kCGWindowNumber]unsignedIntValue];
        if(wid==marker){found=YES;break;}
        if([row[(id)kCGWindowAlpha]doubleValue]<=0)continue;
        CGRect bounds=CGRectNull;
        if(!wid||rect(connection(),wid,&bounds)!=kCGErrorSuccess||CGRectIsNull(bounds)){clear=NO;break;}
        if(CGRectIntersectsRect(bounds,captured)){clear=NO;break;}
    }
    CFRelease(raw);return found&&clear;
}

@interface Observer : NSObject <SCStreamOutput,SCStreamDelegate>
@property FILE *output;
@property CGRect displayFrame;
@property double pointScaleX,pointScaleY;
@property mach_timebase_info_data_t timebase;
@property uint32_t marker;
@property int requestedHz;
@end
@implementation Observer
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;fprintf(stderr,"display observer stopped: %s\n",error.localizedDescription.UTF8String);CFRunLoopStop(CFRunLoopGetMain());
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream;if(type!=SCStreamOutputTypeScreen||!CMSampleBufferIsValid(sample))return;
    @autoreleasepool {
        if(!self.output)return;
        uint64_t callbackTicks=mach_absolute_time();
        uint64_t callbackNS=(uint64_t)((__uint128_t)callbackTicks*self.timebase.numer/self.timebase.denom);
        CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,false);
        if(!attachments||!CFArrayGetCount(attachments))return;
        NSDictionary *info=(__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments,0);
        if([info[SCStreamFrameInfoStatus]integerValue]!=SCFrameStatusComplete)return;
        NSNumber *displayTime=info[SCStreamFrameInfoDisplayTime];if(![displayTime isKindOfClass:NSNumber.class])return;
        uint64_t ticks=displayTime.unsignedLongLongValue;
        uint64_t ns=(uint64_t)((__uint128_t)ticks*self.timebase.numer/self.timebase.denom);
        int64_t displaySkew=(int64_t)ns-(int64_t)callbackNS;
        uint64_t witnessBudgetNS=(uint64_t)(2e9/self.requestedHz);
        // No later witness can make an already stale sample admissible. Avoid
        // scanning it or querying window ordering and extending that backlog.
        if(callbackNS>ns&&callbackNS-ns>witnessBudgetNS){
            fprintf(self.output,"{\"type\":\"pixels\",\"presented_ns\":%llu,\"callback_ns\":%llu,\"display_skew_ns\":%lld,\"observer_wait_ns\":0,\"marker_bounds\":null,\"unobscured\":false,\"visibility_witness_ns\":null,\"pixel_scan_ns\":0,\"visibility_query_ns\":0,\"scan_skipped\":true,\"rejection_reason\":\"already_stale_at_callback\"}\n",ns,callbackNS,displaySkew);
            fflush(self.output);return;
        }
        CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);if(!pixels||CVPixelBufferGetPixelFormatType(pixels)!=kCVPixelFormatType_32BGRA)return;
        if(CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess)return;
        size_t w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels),stride=CVPixelBufferGetBytesPerRow(pixels);
        const uint8_t *data=CVPixelBufferGetBaseAddress(pixels);
        uint64_t scanStart=mach_absolute_time();MarkerBounds marker=markerBounds(data,w,h,stride);
        uint64_t scanNS=(uint64_t)((__uint128_t)(mach_absolute_time()-scanStart)*self.timebase.numer/self.timebase.denom);
        CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
        if(marker.count>16){
            CGRect d=self.displayFrame;
            CGRect captured=CGRectMake(d.origin.x+marker.left*self.pointScaleX,d.origin.y+marker.top*self.pointScaleY,
                                       (marker.right-marker.left+1)*self.pointScaleX,(marker.bottom-marker.top+1)*self.pointScaleY);
            // Virtual displays can deliver a buffer just before its declared
            // display time. Take the ordering witness after that time rather
            // than treating a future-timestamped buffer as already witnessed.
            // This wait is confined to this measurement queue and bounded by
            // two requested refresh periods; larger clock skew is refused.
            uint64_t now=mach_absolute_time();
            uint64_t nowNS=(uint64_t)((__uint128_t)now*self.timebase.numer/self.timebase.denom);
            uint64_t waitNS=0;
            if(ticks>now&&ns-nowNS<=witnessBudgetNS){
                mach_wait_until(ticks);
                uint64_t after=(uint64_t)((__uint128_t)mach_absolute_time()*self.timebase.numer/self.timebase.denom);
                waitNS=after>=nowNS?after-nowNS:0;
            }
            uint64_t queryStart=mach_absolute_time();BOOL clear=unobscured(self.marker,captured);
            uint64_t queryTicks=mach_absolute_time();
            uint64_t queryNS=(uint64_t)((__uint128_t)(queryTicks-queryStart)*self.timebase.numer/self.timebase.denom);
            uint64_t witness=(uint64_t)((__uint128_t)mach_absolute_time()*self.timebase.numer/self.timebase.denom);
            // A delayed witness cannot establish the ordering of an old frame.
            const char *reason=clear?"none":"native_order_or_geometry";
            if(displaySkew>(int64_t)witnessBudgetNS){clear=NO;reason="display_time_too_far_ahead";}
            else if(witness<ns){clear=NO;reason="witness_before_display_time";}
            else if(witness-ns>witnessBudgetNS){clear=NO;reason="stale_visibility_witness";}
            fprintf(self.output,"{\"type\":\"pixels\",\"presented_ns\":%llu,\"callback_ns\":%llu,\"display_skew_ns\":%lld,\"observer_wait_ns\":%llu,\"marker_bounds\":[%.9g,%.9g,%.9g,%.9g],\"marker_pixels\":%zu,\"unobscured\":%s,\"visibility_witness_ns\":%llu,\"pixel_scan_ns\":%llu,\"visibility_query_ns\":%llu,\"scan_skipped\":false,\"rejection_reason\":\"%s\"}\n",ns,callbackNS,displaySkew,waitNS,
                    captured.origin.x,captured.origin.y,captured.size.width,captured.size.height,marker.count,clear?"true":"false",witness,scanNS,queryNS,reason);
        }else fprintf(self.output,"{\"type\":\"pixels\",\"presented_ns\":%llu,\"callback_ns\":%llu,\"display_skew_ns\":%lld,\"marker_bounds\":null,\"pixel_scan_ns\":%llu,\"scan_skipped\":false,\"rejection_reason\":\"no_marker\"}\n",ns,callbackNS,displaySkew,scanNS);
        fflush(self.output);
    }
}
@end

static NSString *sha256(NSData *data) { unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);NSMutableString *s=[NSMutableString string];for(unsigned i=0;i<sizeof(bytes);i++)[s appendFormat:@"%02x",bytes[i]];return s; }
int main(int argc,const char **argv){
    @autoreleasepool{
        if(argc!=5){fprintf(stderr,"usage: display-observer FIXTURE_JSON OUTPUT_JSONL HZ SECONDS\n");return 64;}
        if(!CGPreflightScreenCaptureAccess()){fprintf(stderr,"NOT MEASURED: existing Screen Recording access is required; no prompt requested\n");return 3;}
        int hz=atoi(argv[3]),seconds=atoi(argv[4]);if(hz<1||hz>240||seconds<1||seconds>120)return 64;
        NSData *manifestBytes=[NSData dataWithContentsOfFile:@(argv[1])];
        NSDictionary *manifest=manifestBytes?[NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:NULL]:nil;
        if(![manifest[@"fixture_kind"]isEqual:@"infinify-disposable-cooperative-host"]||![manifest[@"windows"]isKindOfClass:NSArray.class])return 64;
        NSArray *windows=manifest[@"windows"];if(!windows.count||windows.count>16)return 64;
        uint32_t first=[windows[0][@"wid"]unsignedIntValue];pid_t pid=[manifest[@"pid"]intValue];
        struct proc_bsdinfo process={0};
        if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process)
           ||process.pbi_start_tvsec!=[manifest[@"birth_sec"]unsignedLongLongValue]
           ||process.pbi_start_tvusec!=[manifest[@"birth_usec"]unsignedLongLongValue]
           ||process.pbi_uid!=[manifest[@"uid"]unsignedIntValue])return 1;
        __block SCShareableContent *content=nil;__block NSError *failure=nil;__block BOOL done=NO;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *c,NSError *e){dispatch_async(dispatch_get_main_queue(),^{content=c;failure=e;done=YES;});}];
        double until=CFAbsoluteTimeGetCurrent()+10;while(!done&&CFAbsoluteTimeGetCurrent()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);
        if(!content||failure)return 1;
        NSMutableArray<SCWindow *> *included=[NSMutableArray array];SCWindow *target=nil;
        for(NSDictionary *row in windows){
            uint32_t wid=[row[@"wid"]unsignedIntValue];SCWindow *found=nil;
            for(SCWindow *w in content.windows)if(w.windowID==wid&&w.owningApplication.processID==pid){found=w;break;}
            if(!found){fprintf(stderr,"fixture window identity unavailable\n");return 1;}[included addObject:found];if(wid==first)target=found;
        }
        SCDisplay *display=nil;for(SCDisplay *candidate in content.displays)if(CGRectIntersectsRect(candidate.frame,target.frame)){display=candidate;break;}
        if(!display)return 1;
        SCContentFilter *filter=[[SCContentFilter alloc]initWithDisplay:display includingWindows:included];
        filter.includeMenuBar=NO;
        SCStreamConfiguration *config=[SCStreamConfiguration new];
        config.width=display.width;config.height=display.height;config.minimumFrameInterval=CMTimeMake(1,hz);
        config.queueDepth=3;config.pixelFormat=kCVPixelFormatType_32BGRA;config.showsCursor=NO;config.capturesAudio=NO;
        Observer *observer=[Observer new];observer.displayFrame=display.frame;
        observer.marker=first;observer.requestedHz=hz;
        observer.pointScaleX=display.frame.size.width/config.width;observer.pointScaleY=display.frame.size.height/config.height;
        mach_timebase_info_data_t timebase;mach_timebase_info(&timebase);observer.timebase=timebase;
        observer.output=fopen(argv[2],"wx");if(!observer.output)return 1;
        NSData *observerBytes=[NSData dataWithContentsOfFile:@(argv[0])];
        NSString *observerHash=observerBytes?sha256(observerBytes):@"";
        fprintf(observer.output,"{\"schema\":2,\"type\":\"observer\",\"capture_method\":\"display_capture\",\"filtered_fixture_only\":true,\"physical_panel_optical_proof\":false,\"marker_scan\":\"neon_exact_bgra_all_pixels\",\"visibility_witness_policy\":\"after_display_time_wait_max_two_refreshes\",\"observer_sha256\":\"%s\",\"fixture_manifest_sha256\":\"%s\",\"wid\":%u,\"pid\":%d,\"display_id\":%u,\"width\":%zu,\"height\":%zu,\"point_scale_x\":%.9g,\"point_scale_y\":%.9g,\"requested_hz\":%d,\"clock\":\"mach_absolute_time_ns\"}\n",observerHash.UTF8String,sha256(manifestBytes).UTF8String,first,pid,display.displayID,config.width,config.height,observer.pointScaleX,observer.pointScaleY,hz);fflush(observer.output);
        SCStream *stream=[[SCStream alloc]initWithFilter:filter configuration:config delegate:observer];NSError *error=nil;
        dispatch_queue_t sampleQueue=dispatch_queue_create("org.infinify.bench.display-observer",DISPATCH_QUEUE_SERIAL);
        if(![stream addStreamOutput:observer type:SCStreamOutputTypeScreen sampleHandlerQueue:sampleQueue error:&error])return 1;
        __block BOOL started=NO;
        [stream startCaptureWithCompletionHandler:^(NSError *e){dispatch_async(dispatch_get_main_queue(),^{failure=e;started=YES;});}];
        until=CFAbsoluteTimeGetCurrent()+10;while(!started&&CFAbsoluteTimeGetCurrent()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);
        if(!started||failure){dispatch_sync(sampleQueue,^{FILE *output=observer.output;observer.output=NULL;if(output)fclose(output);});return 1;}
        fprintf(stdout,"READY fixture-only display observer\n");fflush(stdout);
        signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
        dispatch_source_t term=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
        dispatch_source_t interrupt=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(term,^{CFRunLoopStop(CFRunLoopGetMain());});dispatch_resume(term);
        dispatch_source_set_event_handler(interrupt,^{CFRunLoopStop(CFRunLoopGetMain());});dispatch_resume(interrupt);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)seconds*NSEC_PER_SEC),dispatch_get_main_queue(),^{CFRunLoopStop(CFRunLoopGetMain());});
        CFRunLoopRun();
        __block BOOL stopped=NO;[stream stopCaptureWithCompletionHandler:^(NSError *e){(void)e;dispatch_async(dispatch_get_main_queue(),^{stopped=YES;});}];
        until=CFAbsoluteTimeGetCurrent()+3;while(!stopped&&CFAbsoluteTimeGetCurrent()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);
        dispatch_sync(sampleQueue,^{FILE *output=observer.output;observer.output=NULL;if(output)fclose(output);});
    }return 0;
}
