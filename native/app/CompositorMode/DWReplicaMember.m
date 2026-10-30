// SPDX-License-Identifier: GPL-3.0-or-later
// DWReplicaMember implementation and the capture lifecycle trace.
// Split from native/desktop/native-replica-family.m at 37b27b1, moved verbatim.
#import "DWNativeReplicaFamilies+Private.h"
// Explicit diagnostic only: bounded lifecycle records, never titles, pixels or
// unrestricted error text. It does not change capture or validation decisions.
void familyTrace(DWReplicaMember *member,const char *event,const char *reason,NSInteger error) {
    static BOOL enabled;static dispatch_once_t once;static NSUInteger records;
    dispatch_once(&once,^{const char *value=getenv("INFINIFY_DEBUG_FAMILIES");enabled=value&&!strcmp(value,"1");});
    if(!enabled||records>=4096)return;
    records++;
    fprintf(stderr,"family_capture: event=%s window=%llu root=%u member=%u pid=%d generation=%llu density=%.5f rate=%ld reason=%s native_error=%ld\n",
        event,[member.root[@"window"]unsignedLongLongValue],[member.root[@"identity"][@"wid"]unsignedIntValue],
        [member.identity[@"wid"]unsignedIntValue],[member.identity[@"pid"]intValue],[member.root[@"generation"]unsignedLongLongValue],
        member.density,(long)member.rate,reason,(long)error);
    if(records==4096)fputs("family_capture: event=log_limit\n",stderr);
}
@implementation DWReplicaMember
- (instancetype)init {
    if((self=[super init])){atomic_init(&alive,YES);atomic_init(&pending,NO);atomic_init(&received,NO);atomic_init(&stopped,NO);atomic_init(&withdrawalPending,NO);
        atomic_init(&callbackSequence,0);atomic_init(&publishedSequence,0);atomic_init(&unavailableSequence,0);}
    return self;
}
- (BOOL)imageAvailable { return atomic_load(&alive)&&!atomic_load(&stopped)&&atomic_load(&publishedSequence)>atomic_load(&unavailableSequence); }
- (void)retire {
    if(atomic_load(&alive))familyTrace(self,"retire","none",0);
    atomic_store(&alive,NO);self.image.buffer=NULL;[self.owner.coldAttempts removeObject:self];
    SCStream *stream=self.stream;if(!stream)return;self.stream=nil;
    [stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
    [stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;}];
}
- (void)fail:(NSString *)failure code:(const char *)code error:(NSInteger)error {
    if(!atomic_load(&alive))return;familyTrace(self,"fail",code,error);self.failure=failure;[self retire];
    [self.owner memberFailed:self];
}
- (void)start {
    // Preserve the existing two-second start bound. A successful start gets its
    // own two seconds for a valid first image, counted before its main-queue
    // handoff. Neither delayed closure keeps a retired attempt alive.
    self.startDeadline=CACurrentMediaTime()+2;__weak DWReplicaMember *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak expireStart];});
    [self.stream startCaptureWithCompletionHandler:^(NSError *failure){CFTimeInterval completed=CACurrentMediaTime();dispatch_async(dispatch_get_main_queue(),^{
        DWReplicaMember *started=weak;if(!started||!atomic_load(&started->alive))return;
        if(failure)[started fail:failure.localizedDescription code:"start_failed" error:failure.code];
        else{started.started=YES;familyTrace(started,"started","none",0);started.firstFrameDeadline=completed+2;
            if(!started.hadImage)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(0,started.firstFrameDeadline-CACurrentMediaTime())*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weak expireFirstFrame];});
        }
    });}];
}
- (void)expireStart {
    if(atomic_load(&alive)&&!self.started&&CACurrentMediaTime()>=self.startDeadline)
        [self fail:@"Family capture start timed out" code:"start_timeout" error:0];
}
- (void)expireFirstFrame {
    if(!atomic_load(&alive)||!self.started||CACurrentMediaTime()<self.firstFrameDeadline)return;
    if(!self.hadImage)[self fail:@"Family capture produced no valid image within two seconds"
        code:atomic_load(&received)?"first_frame_timeout_no_valid_frame":"first_frame_timeout_no_callback" error:0];
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if(!atomic_load(&alive)||stream!=self.stream)return;
    // The delegate need not run on the serial sample queue. Revoke immediately
    // without changing that queue's sequence or bypassing main's failure path.
    if(atomic_exchange(&stopped,YES))return;
    dispatch_async(dispatch_get_main_queue(),^{if(stream==self.stream)[self fail:error.localizedDescription?:@"Family capture stopped" code:"stream_stopped" error:error.code];});
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if(!atomic_load(&alive)||atomic_load(&stopped)||stream!=self.stream||type!=SCStreamOutputTypeScreen)return;
    atomic_store(&received,YES);
    BOOL valid=CMSampleBufferIsValid(sample);CVPixelBufferRef pixels=valid?CMSampleBufferGetImageBuffer(sample):NULL;
    CFArrayRef attachments=valid?CMSampleBufferGetSampleAttachmentsArray(sample,NO):NULL;
    id value=attachments&&CFArrayGetCount(attachments)==1?(__bridge id)CFArrayGetValueAtIndex(attachments,0):nil;
    NSDictionary *info=[value isKindOfClass:NSDictionary.class]?value:nil;id status=info[SCStreamFrameInfoStatus];
    BOOL known=valid&&frameNumber(status)&&floor([status doubleValue])==[status doubleValue]
        &&[status doubleValue]>=SCFrameStatusComplete&&[status doubleValue]<=SCFrameStatusStopped;
    // This member's serial sample queue defines callback order. Availability is
    // atomic so a status-only callback revokes input before main can run. Idle
    // preserves a published image, but never repairs a previous revocation.
    uint64_t sequence=atomic_load(&callbackSequence);if(sequence!=UINT64_MAX)sequence++;
    atomic_store(&callbackSequence,sequence);
    BOOL complete=known&&[status integerValue]==SCFrameStatusComplete&&pixels;
    if(sequence==UINT64_MAX||!known||(!complete&&[status integerValue]!=SCFrameStatusIdle)){
        uint64_t previous=atomic_exchange(&unavailableSequence,sequence);
        if(atomic_load(&publishedSequence)>previous&&!atomic_exchange(&withdrawalPending,YES)){
            dispatch_async(dispatch_get_main_queue(),^{
                if(atomic_load(&self->alive)&&stream==self.stream&&![self imageAvailable]&&self.image.buffer){
                    self.image.buffer=NULL;[self.owner memberBecameUnavailable:self];
                }
                atomic_store(&self->withdrawalPending,NO);
            });
        }
        return;
    }
    if(!complete)return;
    BOOL expected=NO;if(!atomic_compare_exchange_strong(&pending,&expected,YES))return;
    CGRect rootNow=CGRectZero,ownNow=CGRectZero;
    BOOL current=DWNativeWindowBelongsToRoot(self.identity,self.root[@"identity"])
        &&DWNativeBounds([self.root[@"identity"][@"wid"]unsignedIntValue],&rootNow)
        &&DWNativeBounds([self.identity[@"wid"]unsignedIntValue],&ownNow)
        &&CGRectEqualToRect(rootNow,self.rootBounds)&&CGRectEqualToRect(ownNow,self.bounds);
    if(!current){dispatch_async(dispatch_get_main_queue(),^{atomic_store(&self->pending,NO);[self fail:@"Native family changed during capture" code:"membership_changed" error:0];});return;}
    CGRect crop=CGRectNull;uint64_t timestamp=0;
    if(!familyPixels(info,pixels,self.identity,self.bounds,self.frameTime,&crop,&timestamp)){dispatch_async(dispatch_get_main_queue(),^{atomic_store(&self->pending,NO);[self fail:@"Family capture metadata does not match its window" code:"frame_metadata_mismatch" error:0];});return;}
    self.frameTime=timestamp;
    NSArray *dirty=info[SCStreamFrameInfoDirtyRects];BOOL unchanged=[dirty isKindOfClass:NSArray.class]&&!dirty.count;
    CVPixelBufferRetain(pixels);
    dispatch_async(dispatch_get_main_queue(),^{
        if(atomic_load(&self->alive)&&!atomic_load(&self->stopped)&&stream==self.stream&&sequence>atomic_load(&self->unavailableSequence)
            &&familyBinding(self.owner.roots[self.root[@"window"]],self.root)){
            CVPixelBufferRef old=self.image.buffer;
            BOOL newlyAvailable=![self imageAvailable];
            BOOL changed=!unchanged||!old||newlyAvailable||!CGRectEqualToRect(self.image.contentRect,crop)||CVPixelBufferGetWidth(old)!=CVPixelBufferGetWidth(pixels)||CVPixelBufferGetHeight(old)!=CVPixelBufferGetHeight(pixels);
            if(changed){
                self.image.buffer=pixels;self.image.contentRect=crop;self.image.generation++;
            }
            self.hadImage=YES;atomic_store(&self->publishedSequence,sequence);
            // A later status may arrive while the main queue installs pixels.
            // Its revocation must win even over this successful publication.
            if(![self imageAvailable]){self.image.buffer=NULL;[self.owner memberBecameUnavailable:self];}
            else if(!old||newlyAvailable){familyTrace(self,"first_frame","none",0);[self.owner memberBecameDrawable:self];}
            else if(changed)[self.owner changedWindow:self.root[@"window"]];
        }
        CVPixelBufferRelease(pixels);atomic_store(&self->pending,NO);
    });
}
@end
