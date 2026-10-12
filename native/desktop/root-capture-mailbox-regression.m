// SPDX-License-Identifier: GPL-3.0-or-later
// Actual root mailbox and source acceptance methods, extracted from main.m by
// the runner. Only sample storage, image installation and asynchronous dispatch
// are substituted. No SCStream, AppKit window, native input or capture is made.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#include <math.h>
#include <stdint.h>

@class LiveSource,Router;
#include "root-capture-mailbox-interface.inc"

@interface MailboxImage : NSObject
@property size_t width,height;
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
@property BOOL detached,composited,restarted,rejectInstall;
@property NSString *error;
@property NSObject *synth;
@property NSNumber *logical;
@property NSDictionary *identity;
@property Router *router;
@property NSUInteger delivered,skipped,installs,phase;
@property MailboxImage *installedImage;
@property(readonly) CVPixelBufferRef pixels;
@property(copy) dispatch_block_t duringInstall;
- (BOOL)acceptCapturedSample:(CMSampleBufferRef)sample stream:(SCStream *)stream received:(NSUInteger)received forceInstall:(BOOL)force;
- (BOOL)installSample:(CMSampleBufferRef)sample;
@end

static NSDictionary *asDict(id value) { return [value isKindOfClass:NSDictionary.class]?value:nil; }
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

@implementation LiveSource
- (CVPixelBufferRef)pixels { return (__bridge CVPixelBufferRef)self.installedImage; }
#include "root-capture-source-acceptance.inc"
- (BOOL)installSample:(CMSampleBufferRef)sample {
    if(self.rejectInstall)return NO;
    MailboxSample *packet=(__bridge MailboxSample *)sample;
    self.installedImage=packet.image;self.phase=packet.phase;self.installs++;self.restarted=NO;
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
    if(image){sample.image=[MailboxImage new];sample.image.width=64;sample.image.height=48;}
    NSMutableDictionary *info=[NSMutableDictionary dictionary];if(status)info[SCStreamFrameInfoStatus]=status;
    info[SCStreamFrameInfoDirtyRects]=dirty?@[@1]:@[];sample.attachments=@[info];return sample;
}
static void deliverPacket(LiveSource *source,MailboxSample *sample) {
    [source.captureMailbox stream:source.stream didOutputSampleBuffer:(__bridge CMSampleBufferRef)sample ofType:SCStreamOutputTypeScreen];
}
static void drainOne(void) {
    check(jobs.count==1,@"one coalesced main drain");dispatch_block_t job=jobs.firstObject;[jobs removeObjectAtIndex:0];job();
}
static LiveSource *source(BOOL diagnostics) {
    LiveSource *result=[LiveSource new];result.composited=YES;result.restarted=YES;
    result.stream=(SCStream *)(id)[NSObject new];
    result.captureMailbox=[[DWRootCaptureMailbox alloc]initWithSource:result stream:result.stream diagnostics:diagnostics];return result;
}
static void publish(LiveSource *source,NSUInteger phase) {
    deliverPacket(source,packet(@(SCFrameStatusComplete),YES,YES,phase));drainOne();
    check(source.captureMailbox.currentImageAvailable,@"Complete becomes available after actual publication");
}
static void resetSource(LiveSource *source) { [source.captureMailbox cancel];while(jobs.count)drainOne(); }

int main(void) {@autoreleasepool {
    jobs=[NSMutableArray array];LiveSource *s=source(NO);
    check(!s.captureMailbox.currentImageAvailable,@"new stream has no published image");
    check(!DWCapturedInputAvailable(s),@"new composited capture cannot authorize synthetic input");
    check(s.captureMailbox.diagnosticSnapshot==nil,@"default diagnostics stay disabled");
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
    s.stream=(SCStream *)(id)[NSObject new];s.captureMailbox=[[DWRootCaptureMailbox alloc]initWithSource:s stream:s.stream diagnostics:YES];
    drainOne();check(s.installs==installed&&!old.currentImageAvailable&&!s.captureMailbox.currentImageAvailable,@"late old drain cannot publish into a replaced proxy");
    publish(s,201);[old stream:original didOutputSampleBuffer:(__bridge CMSampleBufferRef)packet(@(SCFrameStatusSuspended),NO,NO,0) ofType:SCStreamOutputTypeScreen];
    check(s.captureMailbox.currentImageAvailable&&jobs.count==0,@"old-stream revocation cannot affect replacement mailbox");
    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,202));installed=s.installs;[s.captureMailbox cancel];
    check(!s.captureMailbox.currentImageAvailable,@"cancel immediately revokes");drainOne();
    check(s.installs==installed&&!s.captureMailbox.currentImageAvailable,@"cancelled queued image never publishes");
    deliverPacket(s,packet(@(SCFrameStatusComplete),YES,YES,203));check(jobs.count==0,@"cancelled callback does not dispatch");
    resetSource(s);

    s=source(YES);[s.captureMailbox stream:s.stream startCompleted:YES];publish(s,300);
    NSDictionary *report=s.captureMailbox.diagnosticSnapshot;
    check([report[@"start_completed"]boolValue]&&[report[@"start_succeeded"]boolValue]&&[report[@"image_available"]boolValue],@"opt-in snapshot reports publication separately from start completion");
    deliverPacket(s,packet(@(SCFrameStatusSuspended),NO,NO,301));report=s.captureMailbox.diagnosticSnapshot;
    check(![report[@"image_available"]boolValue]&&[report[@"callback_sequence"]unsignedLongLongValue]>[report[@"published_callback_sequence"]unsignedLongLongValue],@"diagnostic receipt distinguishes retained publication from newer revocation");
    resetSource(s);check(jobs.count==0,@"all deferred work is reaped");
    s=source(NO);publish(s,400);s.synth=[NSObject new];
    check(!DWCapturedInputAvailable(s),@"synthetic load pixels cannot authorize app input");s.synth=nil;resetSource(s);
    s=[LiveSource new];s.composited=NO;
    check(DWCapturedInputAvailable(s),@"distinct AV fixture renderer keeps its existing binding admission path");
    s.synth=[NSObject new];check(!DWCapturedInputAvailable(s),@"AV renderer cannot use synthetic pixels for app input");
    check(!DWCapturedInputAvailable(nil),@"missing capture cannot authorize input");
    printf("root capture mailbox: %lu checks passed (substituted samples; no native capture)\n",(unsigned long)checks);
    return 0;
}}
