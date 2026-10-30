// SPDX-License-Identifier: GPL-3.0-or-later
// Actual root mailbox and source acceptance methods, extracted from main.m by
// the runner. Only sample storage, image installation and asynchronous dispatch
// are substituted. No SCStream, AppKit window, native input or capture is made.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import "DWTypedValue.h"
#include <math.h>
#include <stdint.h>

@class LiveSource,Router;
#include "root-capture-mailbox-interface.inc"

@interface MailboxImage : NSObject
@property size_t width,height;
@property NSUInteger phase;
@end
@implementation MailboxImage
@end
@interface MailboxSample : NSObject
@property BOOL valid;
@property MailboxImage *image;
@property NSArray *attachments;
@property NSUInteger phase;
@end
@implementation MailboxSample
@end
@interface LiveSource : NSObject
@property SCStream *stream;
@property DWRootCaptureMailbox *captureMailbox;
@property BOOL detached,restarted,rejectInstall,nativeVisibilityHeld,nativeVisibilityWanted;
@property NSString *error;
@property NSNumber *logical;
@property NSDictionary *identity;
@property Router *router;
@property NSUInteger delivered,skipped,installs,phase;
@property MailboxImage *installedImage;
@property(readonly) CVPixelBufferRef pixels;
@property CGRect contentRect;
@property(copy) dispatch_block_t duringInstall;
- (BOOL)acceptCapturedSample:(CMSampleBufferRef)sample stream:(SCStream *)stream received:(NSUInteger)received forceInstall:(BOOL)force;
- (BOOL)installSample:(CMSampleBufferRef)sample;
- (BOOL)installPixels:(CVPixelBufferRef)pixels contentRect:(CGRect)crop;
@end

static BOOL sampleValid(CMSampleBufferRef sample) { return sample&&((__bridge MailboxSample *)sample).valid; }
static CVImageBufferRef sampleImage(CMSampleBufferRef sample) { return (__bridge CVImageBufferRef)((__bridge MailboxSample *)sample).image; }
static CFArrayRef sampleAttachments(CMSampleBufferRef sample,BOOL create) {
    (void)create;return (__bridge CFArrayRef)((__bridge MailboxSample *)sample).attachments;
}
static size_t imageWidth(CVImageBufferRef image) { return ((__bridge MailboxImage *)image).width; }
static size_t imageHeight(CVImageBufferRef image) { return ((__bridge MailboxImage *)image).height; }
static CFTypeRef retainObject(CFTypeRef object) { return CFBridgingRetain((__bridge id)object); }
static void releaseObject(CFTypeRef object) { (void)CFBridgingRelease(object); }
static NSMutableArray<dispatch_block_t> *jobs;
static void deferDispatch(dispatch_queue_t queue,dispatch_block_t block) { (void)queue;[jobs addObject:[block copy]]; }

#define CMSampleBufferIsValid sampleValid
#define CMSampleBufferGetImageBuffer sampleImage
#define CMSampleBufferGetSampleAttachmentsArray sampleAttachments
#define CVPixelBufferGetWidth imageWidth
#define CVPixelBufferGetHeight imageHeight
#define CFRetain retainObject
#define CFRelease releaseObject
#define dispatch_async deferDispatch

#include "root-capture-crop.inc"
#include "native-transition-capture-geometry.inc"
@implementation LiveSource
- (instancetype)init { if((self=[super init]))_contentRect=CGRectNull;return self; }
- (CVPixelBufferRef)pixels { return (__bridge CVPixelBufferRef)self.installedImage; }
#include "root-capture-source-acceptance.inc"
- (BOOL)installPixels:(CVPixelBufferRef)pixels contentRect:(CGRect)crop {
    if(self.rejectInstall)return NO;
    self.installedImage=(__bridge MailboxImage *)pixels;self.phase=self.installedImage.phase;self.contentRect=crop;self.installs++;self.restarted=NO;
    dispatch_block_t during=self.duringInstall;self.duringInstall=nil;if(during)during();
    return YES;
}
@end
#include "root-capture-mailbox-implementation.inc"
#include "root-capture-input-availability.inc"

#undef CMSampleBufferIsValid
#undef CMSampleBufferGetImageBuffer
#undef CMSampleBufferGetSampleAttachmentsArray
#undef CVPixelBufferGetWidth
#undef CVPixelBufferGetHeight
#undef CFRetain
#undef CFRelease
#undef dispatch_async

static NSUInteger checks;
static void check(BOOL value,NSString *message) {
    checks++;if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static MailboxSample *packet(id status,BOOL image,BOOL dirty,NSUInteger phase) {
    MailboxSample *sample=[MailboxSample new];sample.valid=YES;sample.phase=phase;
    if(image){sample.image=[MailboxImage new];sample.image.width=64;sample.image.height=48;sample.image.phase=phase;}
    NSMutableDictionary *info=[NSMutableDictionary dictionary];if(status)info[SCStreamFrameInfoStatus]=status;
    info[SCStreamFrameInfoContentRect]=@{@"X":@0,@"Y":@0,@"Width":@32,@"Height":@24};
    info[SCStreamFrameInfoScaleFactor]=@2;info[SCStreamFrameInfoContentScale]=@1;
    info[SCStreamFrameInfoDirtyRects]=dirty?@[@1]:@[];sample.attachments=@[info];return sample;
}
static void deliverPacket(LiveSource *source,MailboxSample *sample) {
    [source.captureMailbox stream:source.stream didOutputSampleBuffer:(__bridge CMSampleBufferRef)sample ofType:SCStreamOutputTypeScreen];
}
static void drainOne(void) {
    check(jobs.count==1,@"one coalesced main drain");dispatch_block_t job=jobs.firstObject;[jobs removeObjectAtIndex:0];job();
}
static LiveSource *source(void) {
    LiveSource *result=[LiveSource new];result.restarted=YES;
    result.stream=(SCStream *)(id)[NSObject new];
    result.captureMailbox=[[DWRootCaptureMailbox alloc]initWithSource:result stream:result.stream];return result;
}
static void publish(LiveSource *source,NSUInteger phase) {
    deliverPacket(source,packet(@(SCFrameStatusComplete),YES,YES,phase));drainOne();
    check(source.captureMailbox.currentImageAvailable,@"Complete becomes available after actual publication");
}
static void resetSource(LiveSource *source) { [source.captureMailbox cancel];while(jobs.count)drainOne(); }

int main(void) {@autoreleasepool {
    // Actual Finder metadata from v24-transition-metadata.json. SCK's raster
    // follows the outward-rounded CG rectangle, not the exact helper mapping.
    CGRect finderMapping=CGRectMake(656.13232665461635,435.61747525278042,743.73534669076719,408.76504949443915);
    CGRect finderObserved=CGRectMake(656,435,744,410);double width=0,height=0;
    check(roundedEdgesMatch(finderMapping,finderObserved),@"live Finder phase satisfies the existing per-edge mapping fence");
    check(captureImageGeometry(finderMapping,finderObserved,finderObserved,finderObserved,2,&width,&height)&&width==1488&&height==820,
        @"live Finder rounded filter produces the observed raster without rejecting its exact logical mapping");
    check(!captureImageGeometry(finderMapping,finderObserved,CGRectOffset(finderObserved,1,0),finderObserved,2,&width,&height),
        @"a stale enumerated SCWindow frame cannot authorize the pinned capture");
    check(!captureImageGeometry(finderMapping,finderObserved,finderObserved,CGRectOffset(finderObserved,1,0),2,&width,&height),
        @"same-aspect shifted filter cannot replace the exact pinned observed window");
    check(!captureImageGeometry(finderMapping,finderObserved,finderObserved,CGRectInset(finderObserved,-1,-1),2,&width,&height),
        @"a padded filter cannot map extra pixels into the window");
    check(!captureImageGeometry(finderMapping,finderObserved,finderObserved,CGRectInset(finderObserved,1,1),2,&width,&height),
        @"a cropped filter cannot stretch partial content over the entire window");
    CGRect outside=finderMapping;outside.origin.x=finderObserved.origin.x+1;
    check(!captureImageGeometry(outside,finderObserved,finderObserved,finderObserved,2,&width,&height),
        @"raster admission retains the original strict less-than-one-point edge fence");
    check(!captureImageGeometry(finderMapping,finderObserved,finderObserved,finderObserved,NAN,&width,&height)
        &&!captureImageGeometry(finderMapping,finderObserved,finderObserved,finderObserved,0,&width,&height)
        &&!captureImageGeometry(finderMapping,finderObserved,finderObserved,finderObserved,32,&width,&height),
        @"invalid density and oversized rasters remain refused");
    CGRect ordinary=CGRectMake(-40,30,656,422);
    check(captureImageGeometry(ordinary,ordinary,ordinary,ordinary,2,&width,&height)&&width==1312&&height==844,
        @"unscaled whole-window capture retains native raster sizing");
    jobs=[NSMutableArray array];LiveSource *s=source();
    check(!s.captureMailbox.currentImageAvailable,@"new stream has no published image");
    check(!DWCapturedInputAvailable(s),@"new capture cannot authorize input");
    deliverPacket(s,packet(@(SCFrameStatusIdle),NO,NO,0));
    check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"initial Idle cannot create availability or main work");
    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,1));
    check(!s.captureMailbox.currentImageAvailable&&s.installs==0,@"receipt is not image publication");drainOne();
    check(s.captureMailbox.currentImageAvailable&&s.phase==1,@"first image is published");
    check(DWCapturedInputAvailable(s),@"published production capture is eligible for captured input");
    deliverPacket(s,packet(@(SCFrameStatusIdle),NO,NO,1));
    check(s.captureMailbox.currentImageAvailable&&jobs.count==0,@"Idle preserves a current image without dispatch");
    deliverPacket(s,packet(@(SCFrameStatusSuspended),NO,NO,1));
    check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"no-image suspension immediately revokes without dispatch");
    check(!DWCapturedInputAvailable(s),@"retained suspended pixels cannot authorize input");
    deliverPacket(s,packet(@(SCFrameStatusIdle),NO,NO,1));
    check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"Idle cannot revive suspension");
    NSUInteger installed=s.installs;deliverPacket(s,packet(@(SCFrameStatusComplete),YES,NO,2));
    check(!s.captureMailbox.currentImageAvailable,@"post-revocation receipt still needs publication");drainOne();
    check(s.captureMailbox.currentImageAvailable&&s.installs==installed+1&&s.phase==2,
        @"first post-revocation Complete with empty dirty rects must install its new image");
    installed=s.installs;deliverPacket(s,packet(@(SCFrameStatusComplete),YES,NO,3));drainOne();
    check(s.captureMailbox.currentImageAvailable&&s.installs==installed&&s.phase==2&&s.skipped==1,
        @"ordinary unchanged Complete retains the current image without redraw");

    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,4));
    deliverPacket(s,packet(@(SCFrameStatusSuspended),NO,NO,4));deliverPacket(s,packet(@(SCFrameStatusIdle),YES,NO,4));
    check(!s.captureMailbox.currentImageAvailable&&jobs.count==1,@"queued old Complete survives Idle coalescing but stays revoked");drainOne();
    check(!s.captureMailbox.currentImageAvailable&&s.phase==4,@"pre-suspension Complete publication cannot revive availability");
    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,NO,5));deliverPacket(s,packet(@(SCFrameStatusIdle),YES,NO,5));drainOne();
    check(s.captureMailbox.currentImageAvailable&&s.phase==5,@"pending Complete keeps its own callback sequence across a later Idle");

    __weak LiveSource *weak=s;s.duringInstall=^{deliverPacket(weak,packet(@(SCFrameStatusSuspended),NO,NO,6));};
    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,6));drainOne();
    check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"suspension during installation cannot be overwritten by publication");
    s.rejectInstall=YES;deliverPacket(s,packet(@(SCFrameStatusComplete),YES,NO,7));drainOne();
    check(!s.captureMailbox.currentImageAvailable&&s.phase==6,@"failed image publication cannot revive availability");
    s.rejectInstall=NO;deliverPacket(s,packet(@(SCFrameStatusComplete),YES,NO,8));drainOne();
    check(s.captureMailbox.currentImageAvailable&&s.phase==8,@"later successfully installed Complete revives the exact stream");

    NSArray *unavailable=@[@(SCFrameStatusBlank),@(SCFrameStatusSuspended),@(SCFrameStatusStarted),@(SCFrameStatusStopped),@99,@.5,@YES,NSNull.null];
    NSUInteger phase=20;
    for(id status in unavailable){
        deliverPacket(s,packet(status,NO,NO,phase));check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"unavailable or malformed no-image status revokes without dispatch");
        deliverPacket(s,packet(@(SCFrameStatusIdle),NO,NO,phase));check(!s.captureMailbox.currentImageAvailable,@"Idle cannot revive any unavailable status");
        publish(s,phase++);
    }
    deliverPacket(s,packet(nil,NO,NO,0));check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"missing status revokes");publish(s,phase++);
    deliverPacket(s,packet(@(SCFrameStatusComplete),NO,NO,0));check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"Complete without an image revokes");publish(s,phase++);
    MailboxSample *invalid=packet(@(SCFrameStatusComplete),YES,YES,0);invalid.valid=NO;
    deliverPacket(s,invalid);check(!s.captureMailbox.currentImageAvailable&&jobs.count==0,@"invalid sample revokes");publish(s,phase++);
    deliverPacket(s,packet(@.5,YES,YES,0));drainOne();check(!s.captureMailbox.currentImageAvailable,@"fractional Complete-shaped metadata cannot authorize a published image");publish(s,phase++);

    installed=s.installs;for(NSUInteger i=0;i<50;i++)deliverPacket(s,packet(@(SCFrameStatusComplete),YES,i==0,100+i));
    check(jobs.count==1,@"callback burst schedules only one main drain");drainOne();
    check(s.captureMailbox.currentImageAvailable&&s.installs==installed+1&&s.phase==149,@"coalesced publication uses the latest retained image and accumulated dirty state");
    NSUInteger delivered=s.delivered;deliverPacket(s,packet(@(SCFrameStatusSuspended),NO,NO,0));
    check(s.delivered==delivered&&jobs.count==0,@"status-only revocation never reaches source acceptance");publish(s,phase++);

    s.detached=YES;check(!s.captureMailbox.currentImageAvailable,@"detached source rejects currentness");s.detached=NO;
    s.error=@"fixture failure";check(!s.captureMailbox.currentImageAvailable,@"source error rejects currentness");s.error=nil;
    SCStream *original=s.stream;s.stream=(SCStream *)(id)[NSObject new];
    check(!s.captureMailbox.currentImageAvailable,@"stream identity replacement rejects old published image");s.stream=original;
    DWRootCaptureMailbox *old=s.captureMailbox;deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,200));installed=s.installs;
    s.stream=(SCStream *)(id)[NSObject new];s.captureMailbox=[[DWRootCaptureMailbox alloc]initWithSource:s stream:s.stream];
    drainOne();check(s.installs==installed&&!old.currentImageAvailable&&!s.captureMailbox.currentImageAvailable,@"late old drain cannot publish into a replaced proxy");
    publish(s,201);[old stream:original didOutputSampleBuffer:(__bridge CMSampleBufferRef)packet(@(SCFrameStatusSuspended),NO,NO,0) ofType:SCStreamOutputTypeScreen];
    check(s.captureMailbox.currentImageAvailable&&jobs.count==0,@"old-stream revocation cannot affect replacement mailbox");
    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,202));installed=s.installs;[s.captureMailbox cancel];
    check(!s.captureMailbox.currentImageAvailable,@"cancel immediately revokes");drainOne();
    check(s.installs==installed&&!s.captureMailbox.currentImageAvailable,@"cancelled queued image never publishes");
    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,203));check(jobs.count==0,@"cancelled callback does not dispatch");
    resetSource(s);

    resetSource(s);check(jobs.count==0,@"all deferred work is reaped");
    s=source();MailboxSample *cropped=packet(@(SCFrameStatusComplete),YES,YES,600);
    NSMutableDictionary *cropInfo=[cropped.attachments[0]mutableCopy];
    cropInfo[SCStreamFrameInfoContentRect]=@{@"X":@2,@"Y":@3,@"Width":@20,@"Height":@15};
    cropInfo[SCStreamFrameInfoScaleFactor]=@2;cropInfo[SCStreamFrameInfoContentScale]=@.5;cropped.attachments=@[cropInfo];
    deliverPacket(s,cropped);drainOne();installed=s.installs;
    check(CGRectEqualToRect(s.contentRect,CGRectMake(4,6,40,30)),@"surface-point crop uses display density once, not ContentScale twice");
    MailboxSample *movedCrop=packet(@(SCFrameStatusComplete),YES,NO,601);
    cropInfo=[cropInfo mutableCopy];cropInfo[SCStreamFrameInfoDirtyRects]=@[];cropInfo[SCStreamFrameInfoContentRect]=@{@"X":@3,@"Y":@2,@"Width":@20,@"Height":@15};movedCrop.attachments=@[cropInfo];
    deliverPacket(s,movedCrop);drainOne();
    check(s.installs==installed+1&&s.phase==601,@"dirty-empty Complete with changed content crop installs the new geometry");
    check(CGRectEqualToRect(s.contentRect,CGRectMake(6,4,40,30)),@"new crop is paired with its new pixel buffer");
    installed=s.installs;deliverPacket(s,movedCrop);drainOne();
    check(s.installs==installed,@"identical dirty-empty pixel and crop geometry keeps the existing picture");
    MailboxSample *badCrop=packet(@(SCFrameStatusComplete),YES,NO,602);
    NSMutableDictionary *badInfo=[cropInfo mutableCopy];badInfo[SCStreamFrameInfoContentRect]=@{@"X":@20,@"Y":@2,@"Width":@20,@"Height":@15};badCrop.attachments=@[badInfo];
    deliverPacket(s,badCrop);
    check(!s.captureMailbox.currentImageAvailable,@"out-of-raster crop immediately revokes capture input before the main drain");drainOne();
    check(s.installs==installed&&s.phase==601&&CGRectEqualToRect(s.contentRect,CGRectMake(6,4,40,30)),@"invalid incoming geometry never replaces the retained pixel/crop pair");
    deliverPacket(s,packet(@(SCFrameStatusIdle),NO,NO,0));
    check(!s.captureMailbox.currentImageAvailable,@"Idle cannot revive invalid crop metadata");
    deliverPacket(s,movedCrop);drainOne();
    check(s.captureMailbox.currentImageAvailable&&s.installs==installed+1,@"valid dirty-empty Complete repairs geometry revocation by publication");
    for(id malformed in @[@YES,@0,@(-1),@(INFINITY),NSNull.null]){
        badInfo=[cropInfo mutableCopy];badInfo[SCStreamFrameInfoScaleFactor]=malformed;badCrop.attachments=@[badInfo];
        CGRect crop=CGRectNull;check(!DWRootCaptureCrop(badInfo,(__bridge CVPixelBufferRef)badCrop.image,&crop),@"invalid display scaling cannot create a crop");
    }
    badInfo=[cropInfo mutableCopy];[badInfo removeObjectForKey:SCStreamFrameInfoContentScale];
    CGRect crop=CGRectNull;check(!DWRootCaptureCrop(badInfo,(__bridge CVPixelBufferRef)badCrop.image,&crop),@"missing ContentScale is uncertain metadata");
    DWRootCaptureMailbox *croppedMailbox=s.captureMailbox;SCStream *croppedStream=s.stream;
    s.stream=(SCStream *)(id)[NSObject new];s.captureMailbox=[[DWRootCaptureMailbox alloc]initWithSource:s stream:s.stream];
    [croppedMailbox stream:croppedStream didOutputSampleBuffer:(__bridge CMSampleBufferRef)cropped ofType:SCStreamOutputTypeScreen];drainOne();
    check(CGRectEqualToRect(s.contentRect,CGRectMake(6,4,40,30))&&!s.captureMailbox.currentImageAvailable,@"retired stream cannot replace retained crop or authorize the new stream");
    [croppedMailbox cancel];
    resetSource(s);
    check(!DWCapturedInputAvailable(nil),@"missing capture cannot authorize input");
    printf("root capture mailbox: %lu checks passed (substituted samples; no native capture)\n",(unsigned long)checks);
    return 0;
}}
