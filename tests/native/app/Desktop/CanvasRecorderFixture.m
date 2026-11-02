// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only probe for tests/e2e/capture-stale-frame.sh: records one window (Infinify's canvas panel, by window number) with
// ScreenCaptureKit at one pixel per point and up to 60 frames a second, for a fixed time. For every complete frame it writes
// one JSON line: the presentation time (host clock, the same as CLOCK_UPTIME_RAW), and the bounding box and pixel count of
// pure red and of pure blue pixels (the stale-frame fixture's two markers); every frame is also saved as frame-N.png. It
// changes nothing: no window, input, setting or capture of anything but the named window.
//
//   CanvasRecorderFixture WINDOW_NUMBER SECONDS OUTPUT_DIR
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <time.h>

@interface DWCanvasRecorder : NSObject <SCStreamOutput>
@property NSString *directory;
@property NSUInteger frames;
@property FILE *index;
@property dispatch_queue_t writer;
@end
@implementation DWCanvasRecorder
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream;if(type!=SCStreamOutputTypeScreen||!CMSampleBufferIsValid(sample))return;
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);if(!attachments||!CFArrayGetCount(attachments))return;
    NSDictionary *info=(__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments,0);
    if([info[SCStreamFrameInfoStatus]integerValue]!=SCFrameStatusComplete)return;
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);if(!pixels)return;
    double pts=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
    CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
    size_t w=CVPixelBufferGetWidth(pixels),h=CVPixelBufferGetHeight(pixels),stride=CVPixelBufferGetBytesPerRow(pixels);const uint8_t *base=CVPixelBufferGetBaseAddress(pixels);
    long box[2][5]={{LONG_MAX,LONG_MAX,-1,-1,0},{LONG_MAX,LONG_MAX,-1,-1,0}};
    for(size_t y=0;y<h;y++){const uint8_t *row=base+y*stride;
        for(size_t x=0;x<w;x++){uint8_t b=row[4*x],g=row[4*x+1],r=row[4*x+2];int k=r>200&&g<70&&b<70?0:b>200&&r<70&&g<70?1:-1;if(k<0)continue;
            long *m=box[k];if((long)x<m[0])m[0]=(long)x;if((long)y<m[1])m[1]=(long)y;if((long)x>m[2])m[2]=(long)x;if((long)y>m[3])m[3]=(long)y;m[4]++;}}
    NSData *copy=[NSData dataWithBytes:base length:stride*h];CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
    NSUInteger n=self.frames++;
    fprintf(self.index,"{\"n\":%lu,\"pts\":%.6f,\"width\":%zu,\"height\":%zu,\"red\":[%ld,%ld,%ld,%ld,%ld],\"blue\":[%ld,%ld,%ld,%ld,%ld]}\n",(unsigned long)n,pts,w,h,
        box[0][4]?box[0][0]:-1,box[0][4]?box[0][1]:-1,box[0][2],box[0][3],box[0][4],box[1][4]?box[1][0]:-1,box[1][4]?box[1][1]:-1,box[1][2],box[1][3],box[1][4]);fflush(self.index);
    NSString *path=[self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%lu.png",(unsigned long)n]];
    dispatch_async(self.writer,^{
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)copy);
        CGImageRef image=CGImageCreate(w,h,8,32,stride,space,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,NO,kCGRenderingIntentDefault);
        CGImageDestinationRef out=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],(__bridge CFStringRef)UTTypePNG.identifier,1,NULL);
        if(out&&image){CGImageDestinationAddImage(out,image,NULL);CGImageDestinationFinalize(out);}
        if(out)CFRelease(out);if(image)CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(space);
    });
}
@end

static double monotonic(void) { struct timespec t;clock_gettime(CLOCK_UPTIME_RAW,&t);return t.tv_sec+t.tv_nsec/1e9; }

int main(int argc,char **argv) { @autoreleasepool {
    long number=argc==4?strtol(argv[1],NULL,10):0;double seconds=argc==4?strtod(argv[2],NULL):0;
    if(argc!=4||number<=0||!(seconds>0&&seconds<=30)){fprintf(stderr,"usage: CanvasRecorderFixture WINDOW_NUMBER SECONDS OUTPUT_DIR\n");return 2;}
    [NSApplication sharedApplication];
    __block SCWindow *target=nil;__block NSError *failure=nil;dispatch_semaphore_t listed=dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *error){
        failure=error;for(SCWindow *window in content.windows)if((long)window.windowID==number)target=window;dispatch_semaphore_signal(listed);}];
    if(dispatch_semaphore_wait(listed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))||!target){fprintf(stderr,"window %ld is not shareable: %s\n",number,failure.localizedDescription.UTF8String?:"not listed");return 1;}
    DWCanvasRecorder *recorder=[DWCanvasRecorder new];recorder.directory=@(argv[3]);recorder.writer=dispatch_queue_create("org.infinify.canvas-recorder.png",DISPATCH_QUEUE_SERIAL);
    recorder.index=fopen([recorder.directory stringByAppendingPathComponent:@"frames.jsonl"].fileSystemRepresentation,"w");if(!recorder.index){perror("frames.jsonl");return 1;}
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)target.frame.size.width;config.height=(size_t)target.frame.size.height;
    config.minimumFrameInterval=CMTimeMake(1,60);config.pixelFormat=kCVPixelFormatType_32BGRA;config.showsCursor=NO;config.colorSpaceName=kCGColorSpaceSRGB;config.queueDepth=8;
    SCStream *stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:target] configuration:config delegate:nil];
    dispatch_queue_t frames=dispatch_queue_create("org.infinify.canvas-recorder.frames",DISPATCH_QUEUE_SERIAL);
    if(![stream addStreamOutput:recorder type:SCStreamOutputTypeScreen sampleHandlerQueue:frames error:&failure]){fprintf(stderr,"stream output: %s\n",failure.localizedDescription.UTF8String);return 1;}
    __block BOOL started=NO;dispatch_semaphore_t began=dispatch_semaphore_create(0);
    [stream startCaptureWithCompletionHandler:^(NSError *error){failure=error;started=error==nil;dispatch_semaphore_signal(began);}];
    if(dispatch_semaphore_wait(began,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))||!started){fprintf(stderr,"capture did not start: %s\n",failure.localizedDescription.UTF8String?:"timeout");return 1;}
    printf("RECORDING %ld %gx%g t=%.6f\n",number,target.frame.size.width,target.frame.size.height,monotonic());fflush(stdout);
    [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    dispatch_semaphore_t stopped=dispatch_semaphore_create(0);[stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_semaphore_signal(stopped);}];
    dispatch_semaphore_wait(stopped,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));
    dispatch_sync(frames,^{});dispatch_sync(recorder.writer,^{});fclose(recorder.index);
    printf("DONE %lu frames t=%.6f\n",(unsigned long)recorder.frames,monotonic());fflush(stdout);return 0;
} }
