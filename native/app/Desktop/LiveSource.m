// SPDX-License-Identifier: GPL-3.0-or-later
// One managed window: its capture stream, picture, native identity and per-window native state.
#import "LiveSource.h"
@implementation LiveSource
- (instancetype)init { if((self=[super init]))_contentRect=CGRectNull;return self; }
- (void)invalidateNativeButtons { self.nativeButtonsRevision++;self.nativeButtons=nil;self.nativeButtonsMoveCandidate=nil;self.nativeButtonsNext=0; }
@synthesize stream=_stream;
@synthesize detached=_detached;
- (void)setDetached:(BOOL)detached {
    NSAssert(NSThread.isMainThread,@"Capture retirement is main-only");
    if(detached)[_captureMailbox cancel];_detached=detached;
}
- (void)setStream:(SCStream *)stream {
    NSAssert(NSThread.isMainThread,@"Capture streams are main-only");
    if(_stream==stream)return;
    [_captureMailbox cancel];
    if(_captureMailbox&&_stream)[_stream removeStreamOutput:_captureMailbox type:SCStreamOutputTypeScreen error:nil];
    _captureMailbox=nil;_stream=stream;DWCaptureConfigurationReset(&_captureConfiguration);
}
- (BOOL)captureUpdating { return _captureConfiguration.pending; }
- (uint64_t)beginCaptureConfiguration:(SCStreamConfiguration *)configuration {
    return DWCaptureConfigurationBegin(&_captureConfiguration,CGSizeMake(configuration.width,configuration.height),configuration.minimumFrameInterval);
}
- (BOOL)completeCaptureConfiguration:(uint64_t)serial success:(BOOL)success {
    return DWCaptureConfigurationComplete(&_captureConfiguration,serial,success);
}
static BOOL recoverableCaptureError(NSError *error) {
    if(![error.domain isEqual:SCStreamErrorDomain])return NO;
    switch(error.code){
        case SCStreamErrorFailedToStart:case SCStreamErrorFailedApplicationConnectionInvalid:
        case SCStreamErrorFailedApplicationConnectionInterrupted:case SCStreamErrorFailedNoMatchingApplicationContext:
        case SCStreamErrorAttemptToStartStreamState:case SCStreamErrorAttemptToStopStreamState:
        case SCStreamErrorAttemptToUpdateFilterState:case SCStreamErrorAttemptToConfigState:
        case SCStreamErrorInternalError:case SCStreamErrorNoWindowList:case SCStreamErrorNoDisplayList:
        case SCStreamErrorNoCaptureSource:case SCStreamErrorSystemStoppedStream:return YES;
        default:return NO; // A user stop/declined permission is never retried.
    }
}
- (void)captureFailed:(NSError *)error {
    [self.captureMailbox cancel];
    self.error=error.localizedDescription?:@"Capture failed";DWCaptureConfigurationReset(&_captureConfiguration);
    self.captureRecovering=recoverableCaptureError(error);
    if(self.captureRecovering){self.captureFailures=MIN(self.captureFailures+1,8u);self.captureRetryAt=CACurrentMediaTime()+MIN(30.,.25*exp2(self.captureFailures-1));}
    else self.captureRetryAt=0;
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { dispatch_async(dispatch_get_main_queue(),^{if(stream!=self.stream||self.detached)return;self.stream=nil;[self captureFailed:error];}); }
- (BOOL)acceptCapturedSample:(CMSampleBufferRef)sample stream:(SCStream *)stream received:(NSUInteger)received forceInstall:(BOOL)force {
    NSAssert(NSThread.isMainThread,@"Capture installation is main-only");
    if(stream!=self.stream)return NO;
    if(self.detached||self.error||!CMSampleBufferIsValid(sample)||!CMSampleBufferGetImageBuffer(sample))return NO;
    self.delivered+=received;
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(!a||!CFArrayGetCount(a))return NO;
    NSDictionary *info=DWTyped((__bridge id)CFArrayGetValueAtIndex(a,0),NSDictionary.class);if(!info)return NO;
    if(![info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]||[info[SCStreamFrameInfoStatus]integerValue]!=SCFrameStatusComplete)return NO;
    CGRect crop=CGRectNull;
    if(!DWRootCaptureCrop(info,CMSampleBufferGetImageBuffer(sample),&crop))return NO;
    // A complete frame that says nothing in it changed is the picture already kept: installing it would redraw the scene for
    // nothing. One that does not say (no dirty rectangles at all) is installed, and so is any frame while no picture is kept,
    // the first of a stream just started or resized, and one whose size is not the kept picture's.
    NSArray *dirty=info[SCStreamFrameInfoDirtyRects];CVImageBufferRef image=CMSampleBufferGetImageBuffer(sample);
    if(!force&&self.pixels&&!self.restarted&&CGRectEqualToRect(crop,self.contentRect)&&CVPixelBufferGetWidth(image)==CVPixelBufferGetWidth(self.pixels)&&CVPixelBufferGetHeight(image)==CVPixelBufferGetHeight(self.pixels)&&[dirty isKindOfClass:NSArray.class]&&!dirty.count){self.skipped++;return YES;}
    return [self installSample:sample];
}
- (BOOL)installSample:(CMSampleBufferRef)sample {
    if(!sample||!CMSampleBufferIsValid(sample))return NO;
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);CGRect crop=CGRectNull;
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    NSDictionary *info=attachments&&CFArrayGetCount(attachments)==1?DWTyped((__bridge id)CFArrayGetValueAtIndex(attachments,0),NSDictionary.class):nil;
    if(!DWRootCaptureCrop(info,pixels,&crop))return NO;
    return [self installPixels:pixels contentRect:crop];
}
- (BOOL)installPixels:(CVPixelBufferRef)pixels {
    return [self installPixels:pixels contentRect:CGRectNull];
}
- (BOOL)installPixels:(CVPixelBufferRef)pixels contentRect:(CGRect)crop {
    if(!pixels)return NO;
    CGSize previous=self.buffer;self.buffer=CGSizeMake(CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels));
    if(!CGSizeEqualToSize(previous,self.buffer)&&getenv("INFINIFY_DEBUG"))fprintf(stderr,"capture: window=%s pixels=%.0fx%.0f\n",self.logical.stringValue.UTF8String,self.buffer.width,self.buffer.height);
    CVPixelBufferRetain(pixels);if(self.pixels)CVPixelBufferRelease(self.pixels);self.pixels=pixels;self.contentRect=crop;
    self.frames++;self.accepted++;self.restarted=NO;self.captureFailures=0;self.captureRecovering=NO;self.captureRetryAt=0;if(self.presented)self.presented();return YES;
}
- (void)clearSample {if(self.pixels){CVPixelBufferRelease(self.pixels);self.pixels=NULL;}self.contentRect=CGRectNull;}
- (void)dealloc { [_captureMailbox cancel];if(_pixels)CVPixelBufferRelease(_pixels);if(_router.eventSource)CFRelease(_router.eventSource); }
@end
