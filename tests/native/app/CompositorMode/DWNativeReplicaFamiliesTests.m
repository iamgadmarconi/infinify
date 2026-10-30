// SPDX-License-Identifier: GPL-3.0-or-later
// Actual recovery/lifecycle code with in-memory streams, deterministic clocks
// and substituted identity reads. No capture, window, native getter or input.
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
#include <libproc.h>
#include <unistd.h>

static NSUInteger checks,notified;
static CFTimeInterval now=100,birthReadAdvance;
static BOOL birthMatches=YES,captureCallbacks,invalidCaptureSample;
static NSMutableArray<dispatch_block_t> *queued;
static NSMutableArray<NSDictionary *> *timers;
static void check(BOOL condition,NSString *message) {
    checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static CFTimeInterval recoveryClock(void) { return now; }
static dispatch_time_t recoveryTime(dispatch_time_t when,int64_t delta) {
    check(when==DISPATCH_TIME_NOW&&delta>=0&&delta<=(int64_t)(2*NSEC_PER_SEC),@"watchdog is bounded and includes queue delay");return (dispatch_time_t)delta;
}
static void recoveryAfter(dispatch_time_t delay,dispatch_queue_t queue,dispatch_block_t block) {
    (void)queue;[timers addObject:@{@"at":@(now+(double)delay/NSEC_PER_SEC),@"block":[block copy]}];
}
static void recoveryAsync(dispatch_queue_t queue,dispatch_block_t block) { (void)queue;[queued addObject:[block copy]]; }
static int recoveryProcess(int pid,int flavor,uint64_t argument,void *buffer,int size) {
    check(pid==123&&flavor==PROC_PIDTBSDINFO&&!argument&&size==sizeof(struct proc_bsdinfo),@"only declared identity is read");
    now+=birthReadAdvance;struct proc_bsdinfo *process=buffer;memset(process,0,sizeof(*process));
    process->pbi_uid=getuid();process->pbi_start_tvsec=birthMatches?100:101;process->pbi_start_tvusec=20;return size;
}
static CFArrayRef recoveryWindows(CGWindowListOption options,CGWindowID window) {
    if(captureCallbacks){check(options==kCGWindowListOptionIncludingWindow&&window==43,@"capture metadata reads only the declared child");
        NSDictionary *bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(106,106,66,20)));
        return CFRetain((__bridge CFArrayRef)@[@{(id)kCGWindowNumber:@43,(id)kCGWindowOwnerPID:@123,(id)kCGWindowBounds:bounds}]);}
    (void)options;(void)window;check(NO,@"headless recovery must not enumerate windows");return NULL;
}
static bool recoveryPermission(void) { check(NO,@"headless recovery must not query permissions");return false; }
#define CACurrentMediaTime recoveryClock
#define dispatch_time recoveryTime
#define dispatch_after recoveryAfter
#define dispatch_async recoveryAsync
#define proc_pidinfo recoveryProcess
#define CGWindowListCopyWindowInfo recoveryWindows
#define CGPreflightScreenCaptureAccess recoveryPermission
#import "DWNativeReplicaFamilies.m"
#import "DWNativeReplicaFamilies+Recovery.m"
#import "DWNativeReplicaFamilies+Ordering.m"
#import "DWReplicaMember.m"
#import "DWReplicaRecovery.m"
#import "DWReplicaOrder.m"
#undef CACurrentMediaTime
#undef dispatch_time
#undef dispatch_after
#undef dispatch_async
#undef proc_pidinfo
#undef CGWindowListCopyWindowInfo
#undef CGPreflightScreenCaptureAccess

NSDictionary *DWNativeWindowFamily(NSDictionary *identity,NSString *__autoreleasing *why) {
    (void)identity;(void)why;check(NO,@"headless recovery must not read native families");return nil;
}
BOOL DWNativeWindowBelongsToRoot(NSDictionary *member,NSDictionary *root) {
    if(captureCallbacks)return [member[@"wid"]isEqual:@43]&&[root[@"wid"]isEqual:@42]&&[member[@"pid"]isEqual:root[@"pid"]];
    (void)member;(void)root;check(NO,@"headless recovery must not read native parentage");return NO;
}
bool DWNativeBounds(uint32_t wid,CGRect *out) {
    if(captureCallbacks){check(wid==42||wid==43,@"capture validates only declared root/child bounds");*out=wid==42?CGRectMake(100,100,320,232):CGRectMake(106,106,66,20);return true;}
    (void)wid;(void)out;check(NO,@"headless recovery must not read native bounds");return false;
}

// Only the generic retained image holder is substituted; recovery and stream
// membership, ordering, deadlines and callbacks above are the production code.
@implementation DWCanvasAttachment
@synthesize buffer=_buffer;
- (instancetype)init { if((self=[super init]))_contentRect=CGRectNull;return self; }
- (void)setBuffer:(CVPixelBufferRef)buffer { if(buffer)CVPixelBufferRetain(buffer);if(_buffer)CVPixelBufferRelease(_buffer);_buffer=buffer; }
- (CVPixelBufferRef)buffer { return _buffer; }
- (void)dealloc { if(_buffer)CVPixelBufferRelease(_buffer); }
@end

@interface RecoveryStream : NSObject
@property(copy) void (^completion)(NSError *);
@property NSUInteger stopped,removed;
@end
@implementation RecoveryStream
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion { self.completion=completion; }
- (BOOL)removeStreamOutput:(id<SCStreamOutput>)output type:(SCStreamOutputType)type error:(NSError *__autoreleasing *)error {
    (void)error;check(output&&type==SCStreamOutputTypeScreen,@"retire removes this exact screen output");self.removed++;return YES;
}
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion { self.stopped++;completion(nil); }
@end
static void drain(void) {
    while(queued.count){dispatch_block_t block=queued.firstObject;[queued removeObjectAtIndex:0];block();}
}
static void advance(CFTimeInterval target) {
    check(target>=now,@"fixture clock is monotonic");now=target;
    for(NSDictionary *timer in timers.copy)if([timer[@"at"]doubleValue]<=now){[timers removeObject:timer];dispatch_block_t block=timer[@"block"];block();}
    drain();
}
static NSDictionary *identity(uint32_t wid) { return @{@"pid":@123,@"birth_sec":@100,@"birth_usec":@20,@"wid":@(wid)}; }
static NSDictionary *rect(CGRect bounds) { return @{@"origin":@{@"x":@(bounds.origin.x),@"y":@(bounds.origin.y)},@"size":@{@"width":@(bounds.size.width),@"height":@(bounds.size.height)}}; }
static NSDictionary *site(CGRect screen,CGRect viewport,double margin) { return @{@"screen_rect":rect(screen),@"viewport":rect(viewport),@"pixel_margin":@(margin)}; }
static NSDictionary *root(void) { return @{@"window":@7,@"identity":identity(42),@"generation":@3,@"native_bounds":rect(CGRectMake(100,100,320,232)),@"density":@2,@"capture":@YES,@"capture_sites":@[site(CGRectMake(100,100,320,232),CGRectMake(0,0,1920,1080),1)],@"capture_all":@NO}; }
static CGRect childBounds(void) { return CGRectMake(106,106,66,20); }
static NSDictionary *plan(uint32_t wid) { return @{@"identity":identity(wid),@"native_bounds":rect(childBounds())}; }
static DWNativeReplicaFamilies *provider(void) {
    DWNativeReplicaFamilies *owner=[[DWNativeReplicaFamilies alloc]initWithChanged:^(NSNumber *window){check([window isEqual:@7],@"callback names its logical root");notified++;}];
    owner.roots=@{@7:root()};return owner;
}
static DWReplicaMember *attemptFor(DWNativeReplicaFamilies *owner,NSNumber *logical,uint32_t wid,NSUInteger *starting) {
    DWReplicaRecovery *record=[owner admitRecovery:identity(wid) root:owner.roots[logical] bounds:childBounds() starting:starting];if(!record)return nil;
    DWReplicaMember *member=[DWReplicaMember new];member.owner=owner;member.root=owner.roots[logical];member.identity=identity(wid);
    member.bounds=childBounds();member.rootBounds=DWRectFromJSON(member.root[@"native_bounds"]);member.lastVisible=now;member.image=[DWCanvasAttachment new];member.image.key=[@(wid)stringValue];
    member.stream=(SCStream *)[RecoveryStream new];record.attempt=member;[owner.coldAttempts addObject:member];
    owner.members[logical]=[(owner.members[logical]?:@[]) arrayByAddingObject:member];return member;
}
static DWReplicaMember *attempt(DWNativeReplicaFamilies *owner,uint32_t wid,NSUInteger *starting) { return attemptFor(owner,@7,wid,starting); }
static NSDictionary *logicalRoot(NSNumber *logical) { NSMutableDictionary *value=[root()mutableCopy];value[@"window"]=logical;value[@"identity"]=identity(42+logical.unsignedIntValue*100);return value; }
static void started(DWReplicaMember *member) { RecoveryStream *stream=(RecoveryStream *)member.stream;[member start];stream.completion(nil);drain();check(member.started,@"current start completion marks only its attempt"); }
static void validImage(DWReplicaMember *member) {
    CVPixelBufferRef pixels=NULL;check(CVPixelBufferCreate(kCFAllocatorDefault,2,2,kCVPixelFormatType_32BGRA,NULL,&pixels)==kCVReturnSuccess,@"allocate an in-memory image");
    member.image.buffer=pixels;member.hadImage=YES;atomic_store(&member->publishedSequence,atomic_fetch_add(&member->callbackSequence,1)+1);
    CVPixelBufferRelease(pixels);[member.owner memberBecameDrawable:member];
}
static void callback(DWReplicaMember *member,SCStream *stream,id status,BOOL image,BOOL dirty) {
    static uint64_t timestamp;CMSampleBufferRef sample=NULL;
    if(image){
        CVPixelBufferRef pixels=NULL;CMVideoFormatDescriptionRef format=NULL;
        check(CVPixelBufferCreate(kCFAllocatorDefault,66,20,kCVPixelFormatType_32BGRA,NULL,&pixels)==kCVReturnSuccess,@"allocate callback pixels");
        check(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,pixels,&format)==noErr,@"describe callback pixels");
        CMSampleTimingInfo timing={.duration=kCMTimeInvalid,.presentationTimeStamp=CMTimeMake(++timestamp,60),.decodeTimeStamp=kCMTimeInvalid};
        check(CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,pixels,format,&timing,&sample)==noErr,@"construct complete callback");
        CFRelease(format);CVPixelBufferRelease(pixels);
    }else check(CMSampleBufferCreate(kCFAllocatorDefault,NULL,true,NULL,NULL,NULL,1,0,NULL,0,NULL,&sample)==noErr,@"construct status-only callback");
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,YES);check(attachments&&CFArrayGetCount(attachments)==1,@"callback has one metadata dictionary");
    NSMutableDictionary *info=(__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(attachments,0);
    if(status)info[SCStreamFrameInfoStatus]=status;
    info[SCStreamFrameInfoDirtyRects]=dirty?@[@1]:@[];info[SCStreamFrameInfoDisplayTime]=@(++timestamp);
    info[SCStreamFrameInfoScaleFactor]=@1;info[SCStreamFrameInfoContentScale]=@1;
    info[SCStreamFrameInfoScreenRect]=CFBridgingRelease(CGRectCreateDictionaryRepresentation(childBounds()));
    info[SCStreamFrameInfoContentRect]=CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(0,0,66,20)));
    if(invalidCaptureSample)CMSampleBufferInvalidate(sample);
    [member stream:stream didOutputSampleBuffer:sample ofType:SCStreamOutputTypeScreen];CFRelease(sample);
}
int main(void) {@autoreleasepool {
    check(NSThread.isMainThread,@"lifecycle owner is main-thread only");queued=[NSMutableArray array];timers=[NSMutableArray array];
    captureCallbacks=YES;DWNativeReplicaFamilies *captures=provider();NSUInteger captureStarts=0;
    DWReplicaMember *captured=attempt(captures,43,&captureStarts);started(captured);
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);
    check(![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"received Complete needs main publication before child input");drain();
    check([captures attachments:@7].count==1&&[captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"published child authorizes its exact hit");
    callback(captured,captured.stream,@(SCFrameStatusIdle),NO,NO);
    check(!queued.count&&[captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"image-less Idle preserves a current child without work");
    callback(captured,captured.stream,@(SCFrameStatusSuspended),NO,NO);
    check(![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"image-less suspension immediately revokes child input");
    check(![captures contains:@7 identity:captured.identity generation:@3 bounds:captured.bounds]&&![captures attachments:@7].count,@"revocation also gates retained target validation and cached drawing");drain();
    check(!captured.image.buffer&&atomic_load(&captured->alive),@"suspension withdraws pixels without retiring or retrying the stream");
    callback(captured,captured.stream,@(SCFrameStatusIdle),YES,NO);
    check(!queued.count&&![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"Idle with pixels cannot revive suspended capture");
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,NO);
    check(![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"new Complete receipt cannot revive before publication");drain();
    check(captured.image.buffer&&[captures attachments:@7].count==1,@"post-revocation dirty-empty Complete installs usable child pixels");
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);
    callback(captured,captured.stream,@(SCFrameStatusBlank),NO,NO);drain();
    check(!captured.image.buffer&&![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"queued pre-Blank Complete cannot publish stale pixels or revive input");
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,NO);drain();
    check([captures hit:@7 key:@"43" local:CGPointMake(8,8)]!=nil,@"only a later published Complete repairs revocation after a queued stale frame");
    invalidCaptureSample=YES;callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);invalidCaptureSample=NO;
    check(![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"invalid sample revokes despite apparent Complete metadata");drain();
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);drain();
    callback(captured,captured.stream,@(SCFrameStatusComplete),NO,NO);
    check(![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"Complete without pixels revokes");drain();
    for(id status in @[@(SCFrameStatusStarted),@(SCFrameStatusStopped),@99,@YES,@0.5,NSNull.null]){
        callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);drain();
        callback(captured,captured.stream,status==NSNull.null?nil:status,NO,NO);
        check(![captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"unavailable or invalid child status revokes immediately");drain();
    }
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);drain();
    SCStream *unrelated=(SCStream *)[RecoveryStream new];callback(captured,unrelated,@(SCFrameStatusSuspended),NO,NO);
    check(!queued.count&&[captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"another stream's callback cannot revoke current child");
    NSError *stoppedError=[NSError errorWithDomain:@"capture-policy" code:1 userInfo:nil];
    [captured stream:unrelated didStopWithError:stoppedError];
    check(!queued.count&&[captures hit:@7 key:@"43" local:CGPointMake(8,8)],@"another stream's stop error cannot revoke current child");
    callback(captured,captured.stream,@(SCFrameStatusSuspended),NO,NO);
    for(unsigned i=0;i<20;i++)callback(captured,captured.stream,@(SCFrameStatusBlank),NO,NO);
    check(queued.count==1,@"repeated unavailable callbacks coalesce one withdrawal");drain();
    advance(captured.firstFrameDeadline);check(atomic_load(&captured->alive)&&!captured.failure,@"first-image watchdog does not restart a previously published suspended stream");
    SCStream *retiredStream=captured.stream;callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);[captures reset];drain();
    callback(captured,retiredStream,@(SCFrameStatusComplete),YES,YES);
    check(!queued.count,@"retired stream callbacks schedule no publication");
    check(!captured.image.buffer&&!captures.members.count,@"retirement invalidates an already queued Complete");
    captures=provider();captureStarts=0;captured=attempt(captures,43,&captureStarts);started(captured);
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);drain();
    NSUInteger imageGeneration=captured.image.generation;
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);
    [captured stream:captured.stream didStopWithError:stoppedError];
    check(![captures hit:@7 key:@"43" local:CGPointMake(8,8)]&&![captures contains:@7 identity:captured.identity generation:@3 bounds:captured.bounds]&&![captures attachments:@7].count,@"stop error revokes pixels and input before main failure runs");
    check(queued.count==2,@"stop error leaves only earlier publication and lifecycle failure queued");
    dispatch_block_t earlierComplete=queued.firstObject;[queued removeObjectAtIndex:0];earlierComplete();
    check(captured.image.generation==imageGeneration&&![captured imageAvailable],@"queued Complete cannot publish after a definitive stop error");
    callback(captured,captured.stream,@(SCFrameStatusComplete),YES,YES);
    check(queued.count==1,@"new samples from a stopped stream cannot schedule publication");drain();
    check(!atomic_load(&captured->alive)&&captured.failure&&!captured.image.buffer,@"stop error still retires through normal failure accounting");
    [captures reset];drain();captureCallbacks=NO;now=100;[timers removeAllObjects];
    DWNativeReplicaFamilies *owner=provider();NSUInteger starting=0;
    DWReplicaMember *first=attempt(owner,43,&starting);check(first&&starting==1,@"a new binding consumes the same bounded start allowance");RecoveryStream *stream=(RecoveryStream *)first.stream;
    [first start];check(first.startDeadline==102&&!first.firstFrameDeadline,@"start deadline precedes the separate first-image deadline");advance(101.999);
    check(atomic_load(&first->alive),@"no premature start timeout");advance(102);
    DWReplicaRecovery *record=owner.recoveries[@7][@43];
    check(!atomic_load(&first->alive)&&[first.failure containsString:@"start timed out"]&&stream.stopped==1&&stream.removed==1,@"missing start completion retires exactly once");
    check(record.failures==1&&record.notBefore>102.5&&record.notBefore<=102.75,@"first failure installs bounded jittered backoff");
    NSUInteger epoch=owner.epoch;stream.completion(nil);drain();
    check(!first.started&&owner.epoch==epoch,@"late successful start cannot resurrect a failed attempt");
    check(!attempt(owner,43,&starting),@"recovery waits for its exact backoff deadline");
    NSMutableDictionary *density=[root()mutableCopy];density[@"density"]=@1;owner.roots=@{@7:density};
    check(!attempt(owner,43,&starting)&&owner.recoveries[@7][@43]==record,@"capture density changes preserve failed history");

    advance(record.notBefore);starting=0;DWReplicaMember *second=attempt(owner,43,&starting);check(second&&starting==1,@"due retry consumes one turn allowance");
    started(second);advance(second.firstFrameDeadline);
    check(!atomic_load(&second->alive)&&[second.failure containsString:@"no valid image"]&&record.failures==2,@"successful start without a callback also expires");
    check(record.notBefore>now+1&&record.notBefore<=now+1.25,@"consecutive first-frame failure increases backoff");
    advance(record.notBefore);starting=0;DWReplicaMember *third=attempt(owner,43,&starting);started(third);
    CMSampleBufferRef sample=NULL;check(CMSampleBufferCreate(kCFAllocatorDefault,NULL,true,NULL,NULL,NULL,0,0,NULL,0,NULL,&sample)==noErr,@"construct callback without image data");
    [third stream:third.stream didOutputSampleBuffer:sample ofType:SCStreamOutputTypeScreen];CFRelease(sample);
    check(atomic_load(&third->received)&&!third.image.buffer,@"an unusable callback is distinguished from no callback");advance(third.firstFrameDeadline);
    check(!atomic_load(&third->alive)&&record.failures==3,@"unusable callbacks do not satisfy the valid-image deadline");

    advance(record.notBefore);starting=0;DWReplicaMember *healthy=attempt(owner,43,&starting);started(healthy);validImage(healthy);
    check(record.failures==0&&!record.notBefore,@"first validated image resets consecutive failure history");
    advance(healthy.firstFrameDeadline);check(atomic_load(&healthy->alive)&&healthy.image.buffer,@"valid current image survives its first-frame watchdog");
    epoch=owner.epoch;[owner memberFailed:third];[third expireFirstFrame];
    check(owner.epoch==epoch&&!record.failures&&record.attempt==healthy,@"old exact-WID attempts cannot alter replacement state");
    [owner attachments:@7];[healthy fail:@"fixture configuration failure" code:"configuration_failed" error:0];
    check(!healthy.image.buffer&&![owner attachments:@7].count&&![owner hit:@7 key:@"43" local:CGPointMake(8,8)],@"failure withdraws pixels, cached attachments and child hits");
    check(record.failures==1,@"a later failure starts again at the first backoff");

    DWNativeReplicaFamilies *slowOwner=provider();NSUInteger slowRetries=0;DWReplicaMember *slow=attempt(slowOwner,43,&slowRetries);RecoveryStream *slowStream=(RecoveryStream *)slow.stream;
    [slow start];CFTimeInterval began=now;advance(began+1.99);slowStream.completion(nil);drain();
    check(slow.started&&slow.firstFrameDeadline==now+2,@"late successful start receives a full separate first-image budget");
    advance(began+2.01);check(atomic_load(&slow->alive),@"expired start watchdog does not shorten the image deadline");
    advance(slow.firstFrameDeadline);check(!atomic_load(&slow->alive),@"late successful start still has a bounded image wait");
    [slowOwner reset];slowOwner=provider();slowRetries=0;slow=attempt(slowOwner,43,&slowRetries);slowStream=(RecoveryStream *)slow.stream;
    [slow start];began=now;slowStream.completion(nil);now+=.4;drain();
    check(slow.firstFrameDeadline==began+2,@"first-image deadline includes start completion's main-queue wait");
    validImage(slow);advance(slow.firstFrameDeadline);check(atomic_load(&slow->alive),@"valid first image cancels timeout effect after queued completion");[slowOwner reset];

    [owner reset];owner=provider();starting=0;DWReplicaMember *one=attempt(owner,43,&starting),*two=attempt(owner,44,&starting);
    check(one&&two&&!attempt(owner,45,&starting),@"two initial starts exhaust the same cohort budget as retries");
    starting=0;check(!attempt(owner,45,&starting),@"another cohort cannot exceed two cold attempts for one root");
    for(DWReplicaMember *member in @[one,two])[member fail:@"fixture failure" code:"start_failed" error:0];advance(now+1);starting=0;
    DWReplicaRecovery *waiting=[owner recovery:identity(45) root:root() bounds:childBounds()];waiting.failures=1;waiting.notBefore=now;
    check([owner admitRecovery:identity(43) root:root() bounds:childBounds() starting:&starting]!=nil,@"first due retry admitted");
    check([owner admitRecovery:identity(44) root:root() bounds:childBounds() starting:&starting]!=nil,@"second due retry admitted");
    check(![owner admitRecovery:identity(45) root:root() bounds:childBounds() starting:&starting]&&starting==2,@"third retry waits for another completed observation");
    check(![owner admitRecovery:identity(46) root:root() bounds:childBounds() starting:&starting]&&starting==2,@"fresh WID replacement cannot bypass a spent cohort allowance");
    check(familyRecoveryDelay(identity(43),1)!=familyRecoveryDelay(identity(44),1),@"different bindings are staggered");
    for(NSUInteger failures=1;failures<=20;failures++){CFTimeInterval delay=familyRecoveryDelay(identity(43),failures);check(delay>.5&&delay<=30,@"retry delay remains bounded");}
    check(familyRecoveryDelay(identity(43),7)!=familyRecoveryDelay(identity(44),7),@"jitter survives the retry ceiling");

    record=owner.recoveries[@7][@43];NSUInteger count=owner.recoveries[@7].count;
    [owner acceptRecoveryCohort:@[] root:root() sampledAt:nil];[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now-.101)];[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now+1)];
    check(owner.recoveries[@7].count==count&&record.failures==1,@"missing, stale or future membership cannot forget failed history");
    birthMatches=NO;[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now)];birthMatches=YES;
    check(owner.recoveries[@7].count==count,@"reused process birth cannot prune history");
    birthReadAdvance=.101;[owner acceptRecoveryCohort:@[] root:root() sampledAt:@(now)];birthReadAdvance=0;
    check(owner.recoveries[@7].count==count,@"freshness includes the main-thread birth read");
    [owner acceptRecoveryCohort:@[plan(43)] root:root() sampledAt:@(now-.01)];
    check(owner.recoveries[@7].count==1&&owner.recoveries[@7][@43]==record&&record.failures==1,@"fresh complete cohort prunes absent members and preserves matching history");
    [owner invalidatePID:0 discardRecovery:NO];check(owner.recoveries[@7][@43]==record,@"stalled observation retires streams but retains backoff");
    [owner invalidatePID:123];check(!owner.recoveries.count,@"explicit process/session invalidation discards history");

    owner=provider();starting=0;one=attempt(owner,43,&starting);[one fail:@"fixture failure" code:"start_failed" error:0];record=owner.recoveries[@7][@43];
    CGRect changed=childBounds();changed.size.width++;
    check([owner recovery:identity(43) root:root() bounds:changed]!=record,@"freshly validated native size replacement resets old binding history");
    record=owner.recoveries[@7][@43];NSMutableDictionary *reused=[identity(43)mutableCopy];reused[@"birth_usec"]=@21;
    check([owner recovery:reused root:root() bounds:changed]!=record,@"same WID in another process birth is a distinct binding");
    owner.requestPending=YES;NSMutableDictionary *generation=[root()mutableCopy];generation[@"generation"]=@4;[owner describe:@[generation] rate:120];
    check(!owner.recoveries.count,@"root generation change retires old negative history");
    starting=0;check([owner admitRecovery:identity(43) root:generation bounds:changed starting:&starting]!=nil,@"new generation is eligible independently");
    NSMutableDictionary *hidden=[generation mutableCopy];hidden[@"capture"]=@NO;[owner describe:@[hidden] rate:120];
    check(!owner.recoveries.count,@"capture admission loss retires history");

    owner=provider();starting=0;
    for(uint32_t wid=100;wid<164;wid++)check([owner recovery:identity(wid) root:root() bounds:childBounds()]!=nil,@"bounded family record admitted");
    check(![owner recovery:identity(164) root:root() bounds:childBounds()]&&owner.recoveries[@7].count==64,@"stale unpruned families cannot grow negative history indefinitely");
    [owner acceptRecoveryCohort:@[plan(163)] root:root() sampledAt:@(now)];
    check(owner.recoveries[@7].count==1&&[owner recovery:identity(164) root:root() bounds:childBounds()]!=nil,@"fresh absence frees bounded history slots");

    [owner reset];owner=provider();owner.changed=^(NSNumber *logical){check(logical.unsignedIntValue>=7&&logical.unsignedIntValue<=20,@"budget callback stays in declared roots");};
    owner.roots=@{@7:logicalRoot(@7),@8:logicalRoot(@8),@9:logicalRoot(@9)};starting=0;
    DWReplicaMember *a=attemptFor(owner,@7,743,&starting),*b=attemptFor(owner,@8,843,&starting);
    check(a&&b&&!attemptFor(owner,@9,943,&starting),@"distinct roots share the two-start cohort bound");
    starting=0;DWReplicaMember *c=attemptFor(owner,@7,744,&starting),*d=attemptFor(owner,@8,844,&starting);
    check(c&&d&&owner.coldAttempts.count==4,@"two cohorts can occupy four cold slots across roots");
    starting=0;check(!attemptFor(owner,@9,943,&starting)&&!starting,@"new root cannot bypass the live global cold bound");
    validImage(a);DWReplicaMember *e=attemptFor(owner,@9,943,&starting);
    check(e&&a.image.buffer&&atomic_load(&a->alive),@"first valid image frees capacity without retiring the healthy stream");
    [b retire];DWReplicaMember *f=attemptFor(owner,@9,944,&starting);
    check(f&&owner.coldAttempts.count==4,@"retirement immediately frees its weak cold slot");
    starting=0;check(!attemptFor(owner,@9,945,&starting),@"fresh member identities still respect root saturation");
    [owner reset];check(!owner.coldAttempts.count&&!owner.admissionRoots.count,@"reset clears cold attempts and scheduling history");

    // Churn may replace every other WID, but cannot move a persistent waiting
    // retry behind the tail forever. No stream is started in this policy check.
    owner=provider();[owner acceptRecoveryCohort:@[plan(43)] root:root() sampledAt:@(now)];
    record=owner.recoveries[@7][@43];record.failures=1;record.notBefore=now+4;uint64_t ticket=record.waiting;
    for(unsigned wave=0;wave<6;wave++){
        NSArray *plans=@[plan(43),plan(1000+wave)];[owner acceptRecoveryCohort:plans root:root() sampledAt:@(now)];
        starting=0;DWReplicaMember *chosen=nil;
        for(NSDictionary *candidate in [owner admissionPlans:plans root:root()]){chosen=attempt(owner,[candidate[@"identity"][@"wid"]unsignedIntValue],&starting);if(chosen)break;}
        check(chosen!=nil,@"eligible waiting work progresses during continuous WID churn");
        if(now<record.notBefore)check([chosen.identity[@"wid"]unsignedIntValue]==1000+wave&&record.waiting==ticket,@"backoff waits retain their FIFO place while a new child starts");
        else {check([chosen.identity[@"wid"]isEqual:@43],@"due persistent retry is selected ahead of newer replacement WIDs");[chosen retire];break;}
        [chosen retire];advance(now+1);
    }
    check(record.waiting>ticket,@"the admitted retry rotates behind other waiting children");[owner reset];

    owner=provider();NSMutableDictionary *many=[NSMutableDictionary dictionary];for(unsigned logical=7;logical<=12;logical++)many[@(logical)]=logicalRoot(@(logical));owner.roots=many.copy;
    NSArray *order=[owner admissionRootOrder];starting=0;
    one=attemptFor(owner,order[0],701,&starting);two=attemptFor(owner,order[1],801,&starting);[one retire];[two retire];
    many[@13]=logicalRoot(@13);owner.roots=many.copy;order=[owner admissionRootOrder];
    check([order[0]isEqual:@9]&&[order[1]isEqual:@10]&&[order.lastObject isEqual:@13],@"new logical roots join after persistent waiting roots");
    starting=0;one=attemptFor(owner,order[0],901,&starting);two=attemptFor(owner,order[1],1001,&starting);[one retire];[two retire];
    many[@14]=logicalRoot(@14);owner.roots=many.copy;order=[owner admissionRootOrder];
    check([order[0]isEqual:@11]&&[order[1]isEqual:@12]&&[order.lastObject isEqual:@14],@"root rotation reaches earlier waiters despite increasing new roots");
    // Suppress only this multi-root fixture's callback assertion on teardown.
    owner.changed=^(NSNumber *logical){(void)logical;};[owner reset];

    owner=provider();starting=0;__weak DWReplicaMember *released;
    @autoreleasepool {DWReplicaMember *retired=attempt(owner,43,&starting);released=retired;[retired start];[retired retire];[owner.members removeAllObjects];}
    check(!released,@"watchdog and start completion do not retain a retired attempt");
    DWReplicaMember *replacement=attempt(owner,43,&starting);started(replacement);validImage(replacement);advance(now+2);
    check(atomic_load(&replacement->alive)&&replacement.image.buffer,@"old weak watchdog cannot retire same-binding replacement");
    [owner reset];check(!owner.recoveries.count&&!owner.roots.count&&!owner.members.count,@"reset withdraws all capture/recovery state");

    // Visibility suppresses only capture. Native audit membership, immutable
    // identity epochs, current order and negative recovery history stay intact.
    NSMutableDictionary *demand=[root()mutableCopy];CGRect viewport=CGRectMake(0,0,400,400);
    demand[@"capture_sites"]=@[site(CGRectMake(1000,1000,320,232),viewport,1)];
    check(!familyIntersectsCapture(demand,childBounds()),@"a child proven beyond every actual view starts no stream");
    demand[@"capture_sites"]=@[site(CGRectMake(1000,1000,320,232),viewport,1),site(CGRectMake(100,100,160,116),viewport,.5)];
    check(familyIntersectsCapture(demand,childBounds()),@"a smaller independent second view retains its visible child");
    demand[@"capture_sites"]=@[site(CGRectMake(-320,100,320,232),viewport,1)];
    check(familyIntersectsCapture(demand,CGRectMake(421,106,10,10)),@"a family-only placement captures a child protruding from a wholly offscreen root");
    demand[@"capture_sites"]=@[site(CGRectMake(100,100,160,464),viewport,.5)];
    check(familyIntersectsCapture(demand,CGRectMake(600,106,100,20)),@"nonuniform root projection retains a partially visible child");
    check(!familyIntersectsCapture(demand,CGRectMake(702,106,100,20)),@"nonuniform projection outside the padded viewport is suppressed");
    demand[@"capture_sites"]=@[site(CGRectMake(394.75,100,320,232),viewport,1)];
    check(familyIntersectsCapture(demand,childBounds()),@"a subpixel raster fringe beyond the nominal edge is retained");
    demand[@"capture_sites"]=@[site(CGRectMake(396,100,320,232),viewport,1)];
    check(!familyIntersectsCapture(demand,childBounds()),@"a proven gap beyond the raster margin is suppressed");
    demand[@"capture_sites"]=@[];check(!familyIntersectsCapture(demand,childBounds()),@"an explicit empty view set requests no new capture");
    demand[@"capture_all"]=@YES;check(familyIntersectsCapture(demand,childBounds()),@"geometry/opening animation conservatively retains the family");
    demand[@"capture"]=@NO;check(!familyIntersectsCapture(demand,childBounds()),@"capture loss remains authoritative even during animation");
    demand[@"capture"]=@YES;demand[@"capture_all"]=@NO;demand[@"capture_sites"]=@[@{@"screen_rect":NSNull.null}];
    check(familyIntersectsCapture(demand,childBounds()),@"unknown projection cannot prove absence");
    [demand removeObjectForKey:@"capture_sites"];check(familyIntersectsCapture(demand,childBounds()),@"missing required sites conservatively retain capture");
    demand[@"capture_sites"]=@[];[demand removeObjectForKey:@"capture_all"];check(familyIntersectsCapture(demand,childBounds()),@"unknown animation state cannot prove absence");demand[@"capture_all"]=@NO;
    demand[@"capture_sites"]=@[site(CGRectMake(1e308,1e308,1e308,1e308),viewport,1)];
    check(familyIntersectsCapture(demand,childBounds()),@"overflow geometry cannot prove absence");

    owner=provider();owner.rate=120;owner.requestPending=YES;owner.reading=YES;owner.nextRead=now+.5;starting=0;
    one=attempt(owner,43,&starting);two=attempt(owner,44,&starting);two.bounds=CGRectMake(200,106,66,20);owner.recoveries[@7][@44].bounds=two.bounds;validImage(one);validImage(two);
    RecoveryStream *invisibleStream=(RecoveryStream *)two.stream;
    NSArray *allPlans=@[plan(43),@{@"identity":identity(44),@"native_bounds":rect(two.bounds)}];
    NSDictionary *audited=@{@"window":@7,@"identity":root()[@"identity"],@"generation":@3,@"native_bounds":root()[@"native_bounds"],@"members":allPlans};owner.descriptions=@{@7:audited};
    DWReplicaOrder *nativeOrder=[DWReplicaOrder new];nativeOrder.root=root();nativeOrder.rank=@2;nativeOrder.members=@[one,two];nativeOrder.ranks=@{@"43":@0,@"44":@1};
    owner.ordering=@{@7:nativeOrder};owner.orderingEpoch=owner.epoch;owner.orderingObservation=1;
    epoch=owner.epoch;NSUInteger observation=owner.requestSequence;CFTimeInterval nextRead=owner.nextRead;
    NSDictionary *requested=owner.roots;demand=[root()mutableCopy];demand[@"capture_sites"]=@[site(CGRectMake(1000,1000,320,232),viewport,1)];
    [owner describe:@[demand] rate:120];
    check(owner.epoch==epoch&&owner.reading&&owner.requestPending&&owner.requestSequence==observation&&owner.nextRead==nextRead,@"camera demand leaves the in-flight audit and observation schedule intact");
    check(familyCohortMatches(owner.roots,requested),@"a same-binding audit completion accepts changed viewport demand");
    check([owner capturePlans:@[plan(45)] root:demand].count==0,@"a new off-view member is not admitted during existing children's grace");
    check([owner capturePlans:allPlans root:demand].count==2,@"brief off-view movement preserves exact installed streams");
    CFTimeInterval hiddenAt=now;advance(hiddenAt+1.99);[owner describe:@[demand] rate:120];
    check(atomic_load(&one->alive)&&atomic_load(&two->alive),@"no stream churn just before the two-second grace ends");
    NSMutableDictionary *oneSite=[demand mutableCopy];oneSite[@"capture_sites"]=@[site(CGRectMake(388,100,320,232),viewport,1)];
    [owner describe:@[oneSite] rate:120];
    advance(hiddenAt+2.01);[owner describe:@[oneSite] rate:120];
    check(atomic_load(&one->alive)&&!atomic_load(&two->alive)&&invisibleStream.stopped==1,@"only the persistently invisible exact child stops");
    check([owner.members[@7]isEqual:@[one]]&&[owner attachments:@7].count==1,@"capture pruning removes only the expired attachment");
    check(owner.descriptions[@7]==audited&&[audited[@"members"]count]==2&&owner.recoveries[@7].count==2,@"full audit membership and recovery history survive capture pruning");
    check(owner.orderingObservation==1&&[owner.ordering[@7].members isEqual:@[one]]&&[owner.ordering[@7].ranks isEqual:@{@"43":@0}],@"retained child keeps the audited native ordering subset");
    check(owner.epoch==epoch&&owner.reading&&familyCohortMatches(owner.roots,requested),@"expired demand still cannot invalidate a pending native audit");
    check([owner capturePlans:allPlans root:oneSite].count==1,@"late reconciliation uses the latest demanded subset, not the request's old sites");
    owner.nextRead=now+1;[owner describe:@[root()] rate:120];
    check(owner.nextRead==0&&owner.epoch==epoch&&owner.reading&&owner.requestPending,@"known child reentry wakes a fresh audit without invalidating the pending one");
    check([owner capturePlans:allPlans root:root()].count==2,@"a returning visible child becomes eligible on the existing observation path");
    owner.nextRead=now+1;nextRead=owner.nextRead;
    NSMutableDictionary *visibleMotion=[root()mutableCopy];visibleMotion[@"capture_sites"]=@[site(CGRectMake(101,101,320,232),viewport,1)];
    [owner describe:@[visibleMotion] rate:120];
    check(owner.nextRead==nextRead&&owner.epoch==epoch&&owner.reading,@"ordinary motion with a still-visible missing member cannot repeatedly wake discovery");
    DWReplicaRecovery *retainedRecovery=owner.recoveries[@7][@44];retainedRecovery.failures=1;retainedRecovery.notBefore=now+4;
    [owner describe:@[demand] rate:120];owner.nextRead=now+1;[owner describe:@[root()] rate:120];
    check(owner.nextRead==0&&owner.recoveries[@7][@44]==retainedRecovery&&retainedRecovery.failures==1&&retainedRecovery.notBefore==now+4,@"another visibility edge preserves exact failure history and backoff");
    [owner reset];drain();
    check(notified>0&&!queued.count,@"mutations notified and all queued completions drained");
    printf("PASS: %lu family capture recovery checks (headless substituted lifecycle only)\n",(unsigned long)checks);return 0;
}}
