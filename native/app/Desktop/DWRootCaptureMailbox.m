// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// The worker-to-main mailbox of one root capture stream.
#import "DWRootCaptureMailbox.h"
#include <os/lock.h>
#import "LiveSource.h"
@implementation DWRootCaptureMailbox {
    __weak LiveSource *_source;
    __weak SCStream *_stream;
    os_unfair_lock _lock;
    CMSampleBufferRef _pending;
    BOOL _scheduled,_cancelled,_complete,_changed;
    uint64_t _callbackSequence,_pendingSequence,_publishedSequence,_unavailableSequence;
    NSUInteger _received;
}
- (instancetype)initWithSource:(LiveSource *)source stream:(SCStream *)stream {
    if((self=[super init])){_source=source;_stream=stream;_lock=OS_UNFAIR_LOCK_INIT;
        dispatch_queue_attr_t attributes=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0);
        attributes=dispatch_queue_attr_make_with_autorelease_frequency(attributes,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        _queue=dispatch_queue_create("org.infinify.root-capture",attributes);}
    return self;
}
- (BOOL)currentImageAvailable {
    NSAssert(NSThread.isMainThread,@"Capture availability is main-only");
    LiveSource *source=_source;SCStream *stream=_stream;
    if(!source||!stream||source.captureMailbox!=self||source.stream!=stream||source.detached||source.error)return NO;
    os_unfair_lock_lock(&_lock);BOOL available=!_cancelled&&_publishedSequence>_unavailableSequence;os_unfair_lock_unlock(&_lock);
    return available;
}
// Only the current stream's callback order matters. Idle preserves a published
// usable image; it cannot revive a revoked one. A new Complete needs publication,
// not just receipt, before the image can authorize an ownership request again.
- (uint64_t)observeAvailabilityLocked:(BOOL)valid image:(BOOL)image info:(NSDictionary *)info {
    uint64_t sequence=_callbackSequence==UINT64_MAX?UINT64_MAX:++_callbackSequence;
    NSNumber *status=[info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]?info[SCStreamFrameInfoStatus]:nil;
    BOOL known=valid&&status&&CFGetTypeID((__bridge CFTypeRef)status)!=CFBooleanGetTypeID()
        &&isfinite(status.doubleValue)&&floor(status.doubleValue)==status.doubleValue
        &&status.doubleValue>=SCFrameStatusComplete&&status.doubleValue<=SCFrameStatusStopped;
    if(sequence==UINT64_MAX||!known||(status.integerValue!=SCFrameStatusIdle&&!(status.integerValue==SCFrameStatusComplete&&image)))
        _unavailableSequence=sequence;
    return sequence;
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if(type!=SCStreamOutputTypeScreen)return;
    BOOL valid=CMSampleBufferIsValid(sample),hasImage=valid&&CMSampleBufferGetImageBuffer(sample)!=NULL;
    CFArrayRef attachments=valid?CMSampleBufferGetSampleAttachmentsArray(sample,NO):NULL;
    NSDictionary *info=attachments&&CFArrayGetCount(attachments)?DWTyped((__bridge id)CFArrayGetValueAtIndex(attachments,0),NSDictionary.class):nil;
    if(!valid||!hasImage){
        os_unfair_lock_lock(&_lock);
        if(!_cancelled&&_stream==stream)[self observeAvailabilityLocked:valid image:hasImage info:info];
        os_unfair_lock_unlock(&_lock);
        return;
    }
    BOOL complete=[info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]&&[info[SCStreamFrameInfoStatus]integerValue]==SCFrameStatusComplete;
    NSArray *dirty=info[SCStreamFrameInfoDirtyRects];BOOL changed=complete&&(![dirty isKindOfClass:NSArray.class]||dirty.count);
    CMSampleBufferRef replaced=NULL;
    os_unfair_lock_lock(&_lock);
    if(_cancelled||_stream!=stream){os_unfair_lock_unlock(&_lock);return;}
    CGRect crop=CGRectNull;
    BOOL geometry=!complete||DWRootCaptureCrop(info,CMSampleBufferGetImageBuffer(sample),&crop);
    uint64_t sequence=[self observeAvailabilityLocked:valid&&geometry image:hasImage info:info];
    _received++;
    // An idle/incomplete callback cannot evict a complete picture. Dirty-empty
    // means unchanged from its predecessor, which may itself be coalesced here.
    if(!_pending||complete||!_complete){
        if(_pending&&complete&&_complete){CVPixelBufferRef before=CMSampleBufferGetImageBuffer(_pending),after=CMSampleBufferGetImageBuffer(sample);
            changed|=CVPixelBufferGetWidth(before)!=CVPixelBufferGetWidth(after)||CVPixelBufferGetHeight(before)!=CVPixelBufferGetHeight(after);}
        replaced=_pending;_pending=(CMSampleBufferRef)CFRetain(sample);_pendingSequence=sequence;_complete=complete;_changed|=changed;
    }
    BOOL schedule=!_scheduled;_scheduled=YES;
    os_unfair_lock_unlock(&_lock);
    if(replaced)CFRelease(replaced);
    if(schedule)dispatch_async(dispatch_get_main_queue(),^{[self drain];});
}
- (void)drain {
    os_unfair_lock_lock(&_lock);
    CMSampleBufferRef sample=_pending;_pending=NULL;uint64_t sequence=_pendingSequence;_pendingSequence=0;
    NSUInteger received=_received;BOOL complete=_complete,changed=_changed||_publishedSequence<=_unavailableSequence;
    _received=0;_complete=NO;_changed=NO;BOOL cancelled=_cancelled;
    os_unfair_lock_unlock(&_lock);
    // The proxy is also the stream generation: a late old drain can neither
    // publish into nor remove a newer proxy's pending picture.
    LiveSource *source=_source;SCStream *stream=_stream;
    BOOL forward=sample&&!cancelled&&source.captureMailbox==self&&stream&&source.stream==stream&&!source.detached&&!source.error;
    BOOL published=forward&&[source acceptCapturedSample:sample stream:stream received:received forceInstall:changed];
    if(sample)CFRelease(sample);
    os_unfair_lock_lock(&_lock);
    if(published&&complete&&!_cancelled&&_stream==stream&&source.captureMailbox==self&&source.stream==stream
        &&!source.detached&&!source.error)_publishedSequence=MAX(_publishedSequence,sequence);
    BOOL again=!_cancelled&&_pending;if(!again)_scheduled=NO;
    os_unfair_lock_unlock(&_lock);
    // Keep the scheduled flag through installation, even if it enters a nested
    // run loop. At most one drain runs or waits, plus one pending latest sample.
    if(again)dispatch_async(dispatch_get_main_queue(),^{[self drain];});
}
- (void)cancel {
    os_unfair_lock_lock(&_lock);_cancelled=YES;CMSampleBufferRef sample=_pending;_pending=NULL;_pendingSequence=0;_received=0;_complete=NO;_changed=NO;os_unfair_lock_unlock(&_lock);
    if(sample)CFRelease(sample);
}
- (void)dealloc {if(_pending)CFRelease(_pending);}
@end
